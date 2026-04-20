# Maccy Performance Redesign — Paste-like UX at 30k+ Items

## Goal

Make the popup snappy at 30k+ history items and search return results in <50ms,
matching the experience of [Paste.app](https://pasteapp.io). Current ceiling is
~5k items before launch latency and per-keystroke search lag become noticeable.

## Scope and Constraints (locked decisions)

- **Local fork only.** This work lives on the `design/paste-like-performance`
  branch and is never published as an upstream PR. We can break things upstream
  doesn't tolerate.
- **Single-user target.** macOS 26 Tahoe (Darwin 25) only — no macOS 14
  back-compat. Latest SwiftData / FTS5 APIs are fair game.
- **No iCloud / CloudKit sync.** FTS index is local and does not need to round
  trip across devices.
- **Drop the legacy search modes.** Fuzzy, regexp, and mixed are removed
  entirely along with the `Fuse` package dependency. FTS5 trigram tokenizer
  covers the "I remember a substring" case better, and `MATCH` syntax handles
  AND / OR / NEAR / phrase for power use.
- **Multi-selection and paste stack** keep working over the loaded window only.
  Selecting across thousands of rows is not a real workflow; the loaded window
  always starts with the most-recent items.
- **All three phases ship together** as one local rewrite. Staging would just
  create churn we'd undo before testing.

## Diagnosis

Three bottlenecks, all in user-visible paths:

### B1. Eager full-table load on launch

`Maccy/Observables/History.swift:104-118` — `load()` runs:

```swift
let descriptor = FetchDescriptor<HistoryItem>()      // no fetchLimit, no batchSize
let results = try Storage.shared.context.fetch(descriptor)
all = sorter.sort(results).map { HistoryItemDecorator($0) }
items = all
```

For N items this is O(N) Core Data fetches + O(N) decorator allocations + an
O(N log N) Swift sort, all on the main thread before the popup paints. Measured
launch with 30k items: ~3–4 s of frozen UI.

### B2. In-memory linear search per keystroke

`Maccy/Search.swift:94-100`:

```swift
private func simpleSearch(string: String, within: [Searchable], options: ...) -> [SearchResult] {
  return within.compactMap { simpleSearch(for: string, in: $0.title, of: $0, options: options) }
}
```

Throttled to 200 ms (`History.swift:57`), but still walks the entire decorator
array per refresh. At 30k items × ~50 µs per `String.range(of:)` ≈ 1.5 s of CPU
per search. UI stays responsive thanks to throttling but results visibly trail.

### B3. Search matches only `title`, not full content

`HistoryItem.generateTitle()` truncates to 1 000 chars
(`Maccy/Models/HistoryItem.swift:97`). Anything past char 1 000 in a long copy
is invisible to search. (User-reported symptom: copying a 5k-char snippet, then
searching for a unique word near the end, finds nothing.)

### What rendering does *right*

`Maccy/Views/MultipleSelectionListView.swift:9-15` already uses `LazyVStack` +
`ForEach`. Scrolling itself is virtualized — the popup window only materialises
visible rows. **The bottleneck is data loading, not rendering.**

## How Paste does it

Inferred from on-disk layout (`~/Library/Application Support/com.wiheads.paste-setapp/`):

- `db.sqlite` (333 MB) — main Core Data store with full content blobs.
- `index.sqlite` (158 MB) — separate FTS5 search index, mirrors text.
- Popup almost certainly uses `NSCollectionView` with `prefetchDataSource`,
  loading only the visible window via SQL `LIMIT/OFFSET` or rowid range.
- Search is `MATCH` against FTS5 — sub-ms at 100k rows.

Trade-off: pays index size up-front (158 MB), gains O(log N) queries forever.

## Proposed Design — Three Phases

Phases are independent. Each is shippable on its own and incrementally closes
the gap to Paste's UX. Phase 1 is the quickest win; phase 3 is the architectural
upgrade.

---

### Phase 1 — Lazy initial load with windowed pagination

**Goal:** launch <100 ms regardless of total item count.

**Change:** `History.load()` fetches only the most-recent N unpinned items
(default 200) plus all pinned items. Older items materialise on demand when the
scroll position approaches the bottom of the loaded window.

**Schema:** none. Index `lastCopiedAt` for the sort.

```swift
// Maccy/Models/HistoryItem.swift
@Attribute(.indexed) var lastCopiedAt: Date = Date.now
```

**`History.swift` diff sketch:**

```swift
private let pageSize = 200
@ObservationIgnored private var loadedCount = 0
@ObservationIgnored private var totalCount = 0

@MainActor
func load() async throws {
  // pinned: always all (small N, drives the top-bar pin section)
  let pinnedDesc = FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.pin != nil })
  let pinned = try Storage.shared.context.fetch(pinnedDesc)

  // unpinned: only most-recent pageSize
  var unpinnedDesc = FetchDescriptor<HistoryItem>(
    predicate: #Predicate { $0.pin == nil },
    sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
  )
  unpinnedDesc.fetchLimit = pageSize
  let unpinned = try Storage.shared.context.fetch(unpinnedDesc)
  totalCount = (try? Storage.shared.context.fetchCount(
    FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.pin == nil })
  )) ?? 0
  loadedCount = unpinned.count

  all = sorter.sort(pinned + unpinned).map { HistoryItemDecorator($0) }
  items = all
  updateShortcuts()
  AppState.shared.popup.needsResize = true
}

@MainActor
func loadMore() async throws {
  guard loadedCount < totalCount else { return }
  var desc = FetchDescriptor<HistoryItem>(
    predicate: #Predicate { $0.pin == nil },
    sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
  )
  desc.fetchLimit = pageSize
  desc.fetchOffset = loadedCount
  let next = try Storage.shared.context.fetch(desc)
  let decorators = next.map { HistoryItemDecorator($0) }
  all.append(contentsOf: decorators)
  items = all  // SwiftUI re-renders via LazyVStack; only new visible rows materialise
  loadedCount += next.count
}
```

**Trigger for `loadMore`:** in `HistoryListView.swift`, attach `.onAppear` to the
last `HistoryItemView` in the LazyVStack:

```swift
HistoryItemView(...)
  .onAppear { if index >= unpinnedItems.count - 20 { Task { try? await appState.history.loadMore() } } }
```

**Search interaction:** while `searchQuery` is non-empty, search runs against
the loaded window only. Phase 2 fixes this; for phase 1, document the limitation
or temporarily fall back to full load when query is non-empty.

**Risk / cost:**
- `limitHistorySize` and `clear()` already operate on `all`. Need to ensure
  eviction queries the DB directly (not the loaded window).
- Pin shortcut assignment in `updateUnpinnedShortcuts` uses `unpinnedItems.prefix(9)` — still correct since the loaded window starts with the most recent.
- Estimated: ~120 LOC across 2 files.

---

### Phase 2 — Database-side search with predicate fetch

**Goal:** search responds in <50 ms at 30k items, no main-thread CPU burst.

**Change:** Replace `Search.search(string:within:)` with a SwiftData
`FetchDescriptor` predicate. Drop the throttle on simple search (the DB is fast
enough). Keep fuzzy/regexp/mixed paths in-memory but only over the loaded
window — those are exotic modes and the speed cost is acceptable.

```swift
// Maccy/Search.swift — new path
@MainActor
func dbSearch(query: String) -> [HistoryItem] {
  let predicate = #Predicate<HistoryItem> {
    $0.title.localizedStandardContains(query)
  }
  var desc = FetchDescriptor<HistoryItem>(
    predicate: predicate,
    sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
  )
  desc.fetchLimit = 500
  return (try? Storage.shared.context.fetch(desc)) ?? []
}
```

**Caveat:** `localizedStandardContains` lowers to SQL `LIKE '%query%'`.
**B-tree indexes can't be used for substring `LIKE`** — SQL still does a full
table scan, but in C inside SQLite, not in Swift over decorator wrappers. The
constant-factor win is ~50–100×; sub-50ms at 30k is realistic, sub-second at
1M. For Paste-class scaling we need phase 3.

**Updates to `History.swift`:** the `searchQuery.didSet` handler runs the DB
fetch instead of `search.search(string:within: all)`, then maps results into
the displayed `items` array. The `all` array stops being the search universe.

**Risk / cost:**
- Existing `Search.Mode` enum (exact / fuzzy / regexp / mixed) needs to stay —
  only `.exact` (the default) routes to DB. Others fall back to in-memory over
  the loaded window with a "expand to full history" button.
- `highlight(_:_:)` ranges become trickier — predicate fetch returns matches
  but not range info. Either re-run the match in Swift on the title (cheap
  for ≤500 results) or add a follow-up matcher.
- Estimated: ~80 LOC.

---

### Phase 3 — FTS5 full-content index

**Goal:** Paste-level scaling — sub-ms search at 100k+ items, search matches
**full content** (past the 1k title truncation), supports tokenizers (incl.
trigram for CJK/substring).

**Change:** Add an FTS5 virtual table maintained outside SwiftData's awareness.
Keep it in sync via raw SQL triggers installed once on container init.

**Schema (run once in `Storage.init` after `ModelContainer` creates the main
schema):**

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS ZHISTORYITEM_fts USING fts5(
  title, fulltext,
  content='ZHISTORYITEM',
  content_rowid='Z_PK',
  tokenize='trigram'  -- substring + CJK out of the box
);

CREATE TRIGGER IF NOT EXISTS ZHISTORYITEM_ai AFTER INSERT ON ZHISTORYITEM BEGIN
  INSERT INTO ZHISTORYITEM_fts(rowid, title, fulltext)
    VALUES (new.Z_PK, new.ZTITLE, '');  -- fulltext populated separately on save
END;

CREATE TRIGGER IF NOT EXISTS ZHISTORYITEM_ad AFTER DELETE ON ZHISTORYITEM BEGIN
  INSERT INTO ZHISTORYITEM_fts(ZHISTORYITEM_fts, rowid, title, fulltext)
    VALUES('delete', old.Z_PK, old.ZTITLE, '');
END;

CREATE TRIGGER IF NOT EXISTS ZHISTORYITEM_au AFTER UPDATE ON ZHISTORYITEM BEGIN
  INSERT INTO ZHISTORYITEM_fts(ZHISTORYITEM_fts, rowid, title, fulltext)
    VALUES('delete', old.Z_PK, old.ZTITLE, '');
  INSERT INTO ZHISTORYITEM_fts(rowid, title, fulltext)
    VALUES (new.Z_PK, new.ZTITLE, '');
END;
```

**Populating `fulltext`:** triggers can't reach the related `ZHISTORYITEMCONTENT`
blobs. Two options:

- **A.** On `Clipboard.copy` / wherever `HistoryItem.title` is generated, also
  derive `previewableText.shortened(to: 10_000)` and write it directly via raw
  SQL: `UPDATE ZHISTORYITEM_fts SET fulltext=? WHERE rowid=?`. Bypasses
  SwiftData; safe because the FTS table is separate from the model.
- **B.** Add a denormalised `searchText` column to `HistoryItem` and let the
  triggers index it. Cleaner but doubles storage of the text content.

Recommend **A** (Paste itself uses this pattern with separate `index.sqlite`).

**Search query:**

```swift
@MainActor
func ftsSearch(query: String) -> [HistoryItem] {
  let safe = query.replacingOccurrences(of: "\"", with: "\"\"")
  let sql = """
    SELECT Z_PK FROM ZHISTORYITEM_fts
    WHERE ZHISTORYITEM_fts MATCH ?
    ORDER BY rank LIMIT 500
  """
  let pks = rawQuery(sql, ["\"\(safe)\""])  // exact phrase or trigram match
  let desc = FetchDescriptor<HistoryItem>(predicate: #Predicate { pks.contains($0.persistentModelID) })
  return (try? Storage.shared.context.fetch(desc)) ?? []
}
```

(SwiftData's `persistentModelID` ↔ Core Data `Z_PK` mapping needs verification;
fallback is to store the Z_PK directly in a side dict.)

**Migration:** on first launch with the new code, populate FTS from existing
rows by iterating all HistoryItems and writing fulltext (one-time cost,
~30s for 30k items, run async with a progress indicator).

**Risk / cost:**
- Raw SQL inside SwiftData is supported (the underlying SQLite handle is
  reachable via `ModelContext.container.executeQuery(...)` on macOS 15+, or by
  opening a sibling `sqlite3` connection to the same file in WAL mode for older
  versions). Needs careful concurrency: SwiftData and our raw conn must agree
  on transactions.
- FTS5 trigram index roughly doubles DB size (~2× the title+content bytes).
  At 30k items with 1k avg title that's ~60 MB extra — negligible.
- Schema migration must be guarded by a version key in `Z_METADATA` so we don't
  rebuild the FTS on every launch.
- Estimated: ~250 LOC + new file `Maccy/FTSIndex.swift`.

---

## Effort Summary

| Phase | LOC | User-visible win |
|---|---|---|
| 1. Lazy load | ~120 | Launch instant at any size |
| 2. Predicate search + drop legacy modes | ~80 (added) − ~70 (removed) | Search 50-100× faster, simpler codebase |
| 3. FTS5 index | ~250 | Full-content search; sub-ms at 1M |

Combined: ~450 LOC net change across `History.swift`, `Search.swift`,
`Storage.swift`, `HistoryListView.swift`, `HistoryItem.swift`, plus a new
`Maccy/FTSIndex.swift` and `MaccyTests/` additions.

## Verification Stack

Every change loops through these layers automatically before I declare a phase
done. The user only re-enters the loop at Layer E.

### Layer A — Build (per edit, ~10 s)

```bash
xcodebuild -project Maccy.xcodeproj -scheme Maccy -configuration Debug \
  -derivedDataPath build/dd build
```

Catches type errors, missing imports, predicate-syntax mistakes, deprecated
APIs. SwiftLint runs as a build phase already.

### Layer B — Unit tests (per feature, seconds)

Add to `MaccyTests/`:

| Test | Asserts |
|---|---|
| `HistoryLoadTests.testInitialFetchLimit` | `load()` returns ≤ pageSize unpinned + all pinned |
| `HistoryLoadTests.testLoadMoreAppends` | `loadMore()` appends next page in correct order |
| `HistoryLoadTests.testLimitHistorySizeQueriesDB` | Eviction queries DB, not the loaded window |
| `SearchTests.testPredicateMatchesTitle` | Insert known title, predicate fetch returns it |
| `SearchTests.testPredicateRespectsLastCopiedAtSort` | Results ordered by `lastCopiedAt` desc |
| `FTSIndexTests.testInsertSyncsFTS` | Insert HistoryItem → FTS rowcount += 1 |
| `FTSIndexTests.testDeleteSyncsFTS` | Delete HistoryItem → FTS rowcount -= 1 |
| `FTSIndexTests.testTrigramFindsCJK` | "我去北京" indexed, `MATCH '北京'` returns it |
| `FTSIndexTests.testFulltextBeyondTitleTruncation` | 5k-char content with unique token at char 4900 → `MATCH` finds it |
| `FTSIndexTests.testRebuildAfterCorruption` | Drop FTS table, relaunch, FTS rowcount restored |

Run via:
```bash
xcodebuild test -project Maccy.xcodeproj -scheme Maccy \
  -only-testing:MaccyTests/HistoryLoadTests \
  -only-testing:MaccyTests/SearchTests \
  -only-testing:MaccyTests/FTSIndexTests
```

### Layer C — Performance benchmark (per phase, 1-2 min)

Standalone Swift CLI at `hack/perf-bench.swift`:

1. Copies the dev `Storage.sqlite` to a tempfile (so neither dev nor live data
   is mutated).
2. Times three queries against the temp DB:
   - **Launch sim:** `SELECT * FROM ZHISTORYITEM WHERE ZPIN IS NULL ORDER BY ZLASTCOPIEDAT DESC LIMIT 200`
   - **Predicate search:** `SELECT * FROM ZHISTORYITEM WHERE ZTITLE LIKE ? ORDER BY ZLASTCOPIEDAT DESC LIMIT 500` with 5 sample queries (English short, English long, CJK, prefix, regex-bait)
   - **FTS search:** `SELECT * FROM ZHISTORYITEM_fts WHERE ZHISTORYITEM_fts MATCH ? ORDER BY rank LIMIT 500`
3. Prints `before/after` timings vs. baseline saved on first run.

Pass criteria at the **stress-test corpus** of 28 951 items (full Paste
history, see Layer D):

| Query | Pre (baseline) | Target |
|---|---|---|
| Launch sim | TBD | <50 ms |
| Predicate search | TBD | <200 ms |
| FTS search | n/a (no table) | <20 ms |

### Layer D — DB invariant + dev install (per phase, 10 s)

After Layers A-C pass:

1. Build artifact lands in `build/dd/Build/Products/Debug/Maccy-dev.app`.
2. Quit any running `Maccy-dev`, copy or `cp -R` to `/Applications/Maccy-dev.app`
   (or just launch from DerivedData; both are fine).
3. Launch with the dev container — `~/Library/Containers/org.p0deje.Maccy.dev/`,
   isolated from the user's Setapp Maccy at `org.p0deje.Maccy-setapp`.
4. Sleep 2 s, then run sqlite3 invariants against the dev DB:
   - FTS rowcount == HistoryItem rowcount (Phase 3)
   - `Z_PRIMARYKEY.Z_MAX` ≥ `MAX(Z_PK)` for both entities (always)
   - Pin count unchanged from pre-launch
   - One spot-check FTS query for a known string returns the expected row
5. Quit dev Maccy.

Any failure → revert the change, surface the diff to the user, do not proceed.

### Layer E — User acceptance (per phase, manual)

Only after A-D pass: ping the user to launch dev Maccy, exercise the popup
with real input (open, search, scroll, pin, paste-stack if used), confirm it
feels right. Single thumbs-up to advance to the next phase or, after Phase 3,
to swap dev → primary install.

## Test corpus

Dev Maccy is seeded once with the **full 28 951 Text/Link items from the user's
Paste history**, via an adapted `/tmp/maccy_migrate.py` (the same direct-SQL
injection technique we already validated on the 5 010-item migration into the
production Maccy container). This is the realistic stress test that synthetic
data can't match — actual content distribution, real CJK / English mix, real
title length distribution.

The dev container at `~/Library/Containers/org.p0deje.Maccy.dev/` is wiped
and reseeded if any phase needs to start from a clean baseline.
