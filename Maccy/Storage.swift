import Foundation
import SQLite3
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  private let url = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")

  init() {
    var config = ModelConfiguration(url: url)

    #if DEBUG
    if CommandLine.arguments.contains("enable-testing") {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }

    // Phase 3 FTS5 sidecar disabled: the trigger-driven mirror was
    // suspected of causing _thereIsNoSadnessLikeTheDeathOfOptimism crashes
    // on app activation (Core Data optimistic lock during save). Search.swift
    // uses the Phase 2 predicate path against `title`, so the FTS index
    // isn't queried anyway. Dead weight — disabled here, FTSIndex class
    // kept around in case we revisit with a different sync strategy.
    // FTSIndex.shared.bootstrap()
  }
}

/// Sidecar FTS5 index over `ZHISTORYITEM_fts`, maintained by SQL triggers.
///
/// Architecture:
/// - The FTS5 virtual table and three SQL triggers are installed once via a
///   sibling SQLite connection (Core Data already opens the same file in WAL
///   mode, so multi-connection coexistence is safe).
/// - The triggers mirror inserts/updates/deletes from
///   `ZHISTORYITEMCONTENT` (where the actual text BLOB lives) into
///   `ZHISTORYITEM_fts` automatically on each Core Data save. No Swift code
///   in the hot path.
/// - A second trigger on `ZHISTORYITEM` deletes catches the cascade that
///   wipes a parent row before its content rows have a chance to fire their
///   own triggers (depending on cascade order).
/// - On first launch (or after a manual rebuild) the index is backfilled
///   from existing `ZHISTORYITEMCONTENT` rows.
///
/// Search returns matched `firstCopiedAt` dates; the caller turns those into
/// SwiftData fetches via `#Predicate { dates.contains($0.firstCopiedAt) }`.
/// We use `firstCopiedAt` as the SwiftData-side join key because it's
/// immutable, unique enough in practice (date down to microseconds), and
/// already a typed field on the model. Rowids stay opaque.
@MainActor
final class FTSIndex {
  static let shared = FTSIndex()

  private var db: OpaquePointer?
  private let url: URL
  private let schemaVersion = 1

  private init() {
    self.url = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")
  }

  /// Install schema (idempotent). Backfill if newly created.
  /// Call once after `Storage.shared.container` is constructed.
  func bootstrap() {
    guard FileManager.default.fileExists(atPath: url.path) else {
      // Storage.sqlite hasn't been created yet (first ever launch). The first
      // save by Core Data will create it; we'll bootstrap on next app launch.
      return
    }

    var rc = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil)
    guard rc == SQLITE_OK else {
      log("open failed rc=\(rc) (\(String(cString: sqlite3_errstr(rc))))")
      return
    }
    // 1s busy timeout is plenty — Core Data writes are short.
    sqlite3_busy_timeout(db, 1000)

    let installed = currentSchemaVersion()
    if installed >= schemaVersion {
      // Already installed; nothing to do.
      return
    }

    log("installing FTS schema v\(schemaVersion) (was v\(installed))")
    do {
      try exec("BEGIN")
      try exec(Self.schemaSQL)
      try exec("INSERT INTO ZHISTORYITEM_fts_version(version) VALUES (\(schemaVersion))")
      try exec("COMMIT")
    } catch {
      _ = try? exec("ROLLBACK")
      log("install failed: \(error)")
      return
    }

    backfill()
  }

  /// Rebuild the FTS index from scratch. Use after schema corruption.
  func rebuild() {
    do {
      try exec("BEGIN")
      try exec("DELETE FROM ZHISTORYITEM_fts")
      try exec("COMMIT")
    } catch {
      _ = try? exec("ROLLBACK")
      log("rebuild reset failed: \(error)")
      return
    }
    backfill()
  }

  /// Search FTS for `query`, return matched `firstCopiedAt` timestamps in
  /// FTS rank order (best match first). The caller turns these into a
  /// SwiftData fetch.
  func search(_ query: String, limit: Int = 500) -> [Date] {
    guard !query.isEmpty, db != nil else { return [] }

    // FTS5 phrase query: wrap in double-quotes so user input doesn't
    // accidentally hit FTS operator syntax (AND / OR / NEAR / "-").
    // Escape any double-quotes in the input by doubling them.
    let safe = "\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""

    // Sort by lastCopiedAt DESC (recency), not BM25 rank. For a clipboard
    // history popup the user expects "the most recent thing I copied that
    // matches my query" first — they're rarely looking for the most
    // textually-relevant match.
    let sql = """
      SELECT zhi.ZFIRSTCOPIEDAT
      FROM ZHISTORYITEM zhi
      JOIN ZHISTORYITEM_fts ON ZHISTORYITEM_fts.rowid = zhi.Z_PK
      WHERE ZHISTORYITEM_fts MATCH ?
      ORDER BY zhi.ZLASTCOPIEDAT DESC
      LIMIT ?
    """

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      log("search prepare failed: \(String(cString: sqlite3_errmsg(db)))")
      return []
    }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_text(stmt, 1, safe, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    sqlite3_bind_int(stmt, 2, Int32(limit))

    // ZFIRSTCOPIEDAT is REAL, seconds since 2001-01-01 (Apple reference date).
    let appleEpoch = Date(timeIntervalSinceReferenceDate: 0)
    var dates: [Date] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      let secs = sqlite3_column_double(stmt, 0)
      dates.append(appleEpoch.addingTimeInterval(secs))
    }
    return dates
  }

  // MARK: - private

  private func currentSchemaVersion() -> Int {
    var stmt: OpaquePointer?
    let sql = "SELECT MAX(version) FROM ZHISTORYITEM_fts_version"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
    defer { sqlite3_finalize(stmt) }
    if sqlite3_step(stmt) == SQLITE_ROW {
      return Int(sqlite3_column_int(stmt, 0))
    }
    return 0
  }

  private func backfill() {
    log("backfilling FTS from existing ZHISTORYITEMCONTENT rows…")
    let sql = """
      INSERT INTO ZHISTORYITEM_fts(rowid, body)
      SELECT ZITEM, CAST(ZVALUE AS TEXT)
      FROM ZHISTORYITEMCONTENT
      WHERE ZTYPE = 'public.utf8-plain-text'
        AND ZVALUE IS NOT NULL
        AND length(ZVALUE) > 0
    """
    do {
      try exec("BEGIN")
      try exec(sql)
      try exec("COMMIT")
    } catch {
      _ = try? exec("ROLLBACK")
      log("backfill failed: \(error)")
      return
    }

    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ZHISTORYITEM_fts", -1, &stmt, nil)
    sqlite3_step(stmt)
    let count = sqlite3_column_int(stmt, 0)
    sqlite3_finalize(stmt)
    log("backfill complete: \(count) rows indexed")
  }

  private func exec(_ sql: String) throws {
    var err: UnsafeMutablePointer<CChar>?
    let rc = sqlite3_exec(db, sql, nil, nil, &err)
    if rc != SQLITE_OK {
      let msg = err.map { String(cString: $0) } ?? "rc=\(rc)"
      sqlite3_free(err)
      throw FTSError.exec(msg)
    }
  }

  private func log(_ msg: String) {
    print("[FTSIndex] \(msg)")
  }

  enum FTSError: Error { case exec(String) }

  // Schema as a single multi-statement script.
  // - ZHISTORYITEM_fts:    the trigram-tokenized FTS5 table. trigram supports
  //                        substring search and CJK out of the box.
  // - ZHISTORYITEM_fts_version: bookkeeping so re-runs are idempotent.
  // - zhic_ai / zhic_ad / zhic_au: maintain on insert/delete/update of
  //                                ZHISTORYITEMCONTENT rows for the plain-text
  //                                pasteboard type. ZVALUE is BLOB, so we cast
  //                                to TEXT for FTS.
  // - zhi_ad: catch the parent-side delete in case cascade timing means the
  //           child trigger doesn't fire first.
  private static let schemaSQL = """
    CREATE TABLE IF NOT EXISTS ZHISTORYITEM_fts_version (
      version INTEGER NOT NULL
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS ZHISTORYITEM_fts USING fts5(
      body,
      tokenize='trigram'
    );
    CREATE TRIGGER IF NOT EXISTS zhic_ai
      AFTER INSERT ON ZHISTORYITEMCONTENT
      WHEN NEW.ZTYPE = 'public.utf8-plain-text' AND NEW.ZVALUE IS NOT NULL
    BEGIN
      INSERT INTO ZHISTORYITEM_fts(rowid, body)
        VALUES (NEW.ZITEM, CAST(NEW.ZVALUE AS TEXT));
    END;
    CREATE TRIGGER IF NOT EXISTS zhic_ad
      AFTER DELETE ON ZHISTORYITEMCONTENT
      WHEN OLD.ZTYPE = 'public.utf8-plain-text'
    BEGIN
      DELETE FROM ZHISTORYITEM_fts WHERE rowid = OLD.ZITEM;
    END;
    CREATE TRIGGER IF NOT EXISTS zhic_au
      AFTER UPDATE ON ZHISTORYITEMCONTENT
      WHEN NEW.ZTYPE = 'public.utf8-plain-text'
    BEGIN
      DELETE FROM ZHISTORYITEM_fts WHERE rowid = OLD.ZITEM;
      INSERT INTO ZHISTORYITEM_fts(rowid, body)
        VALUES (NEW.ZITEM, CAST(NEW.ZVALUE AS TEXT));
    END;
    CREATE TRIGGER IF NOT EXISTS zhi_ad
      AFTER DELETE ON ZHISTORYITEM
    BEGIN
      DELETE FROM ZHISTORYITEM_fts WHERE rowid = OLD.Z_PK;
    END;
    """
}
