import AppKit
import Foundation
import SwiftData

class Search {
  struct SearchResult: Equatable {
    var object: HistoryItemDecorator
    var ranges: [Range<String.Index>] = []
  }

  // Maximum matches to surface in the popup. Past this, the user is better
  // off refining their query.
  private let resultLimit = 500

  // SwiftData predicate search against `title`, sorted by lastCopiedAt DESC,
  // capped at `resultLimit`. SQL LIKE under the hood — handles substring,
  // CJK, and any query length. ~22 ms at 27k items in our bench.
  //
  // Phase 3's FTS5 path is left in place infrastructurally (Storage installs
  // it on launch, triggers maintain it on plain-text content writes) but is
  // not queried here. Reason: SwiftData's dedup-on-copy path can leave new
  // HistoryItems with empty `contents` arrays — only the title is set on
  // the new row, and the content rows from the de-duplicated old item don't
  // reliably reattach. Items with no content never enter the FTS index, so
  // the FTS path silently misses them. Predicate search on `title` hits
  // those items because the title is always populated by HistoryItem.generateTitle.
  //
  // The FTS infra stays installed (no perceptible cost) so that, if/when
  // Maccy's dedup path is fixed upstream or we add a fallback that derives
  // FTS body from title, we can re-enable the FTS query path with one edit.
  //
  // Decorators are reused from `existingDecorators` where possible to
  // preserve transient state (image cache, applicationImage, pin shortcuts).
  @MainActor
  func search(string: String, in existingDecorators: [HistoryItemDecorator]) -> [SearchResult] {
    guard !string.isEmpty else {
      return existingDecorators.map { SearchResult(object: $0) }
    }

    let predicate = #Predicate<HistoryItem> { $0.title.localizedStandardContains(string) }
    var desc = FetchDescriptor<HistoryItem>(
      predicate: predicate,
      sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
    )
    desc.fetchLimit = resultLimit
    guard let items = try? Storage.shared.context.fetch(desc) else { return [] }

    let decoratorsByItem = Dictionary(grouping: existingDecorators, by: \.item)
      .compactMapValues(\.first)
    return items.map { item in
      let decorator = decoratorsByItem[item] ?? HistoryItemDecorator(item)
      return SearchResult(object: decorator, ranges: rangeOf(string, in: decorator.title))
    }
  }

  // First case- and diacritic-insensitive match of `query` in `title`.
  // Used to drive the highlight in the popup row.
  private func rangeOf(_ query: String, in title: String) -> [Range<String.Index>] {
    if let r = title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
      return [r]
    }
    return []
  }
}
