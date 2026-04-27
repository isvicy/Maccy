import AppKit
import Defaults

// swiftlint:disable identifier_name
// swiftlint:disable type_name
class Sorter {
  enum By: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
    case lastCopiedAt
    case firstCopiedAt
    case numberOfCopies

    var id: Self { self }

    var description: String {
      switch self {
      case .lastCopiedAt:
        return NSLocalizedString("LastCopiedAt", tableName: "StorageSettings", comment: "")
      case .firstCopiedAt:
        return NSLocalizedString("FirstCopiedAt", tableName: "StorageSettings", comment: "")
      case .numberOfCopies:
        return NSLocalizedString("NumberOfCopies", tableName: "StorageSettings", comment: "")
      }
    }
  }

  func sort(_ items: [HistoryItem], by: By = Defaults[.sortBy]) -> [HistoryItem] {
    return items
      .sorted(by: { return bySortingAlgorithm($0, $1, by) })
      .sorted(by: byPinned)
  }

  // Binary search for the index at which `item` should be inserted into
  // `array` to keep `array` sorted under the same comparator used by
  // `sort(_:by:)`. `array` must already be sorted under that comparator.
  // O(log N) — replaces the full re-sort previously done on every add/bump,
  // which was O(N log N) over the loaded window and grew expensive as the
  // user extended the window via loadMore.
  func insertionIndex(
    for item: HistoryItem,
    in array: [HistoryItem],
    by: By = Defaults[.sortBy]
  ) -> Int {
    insertionIndex(for: item, count: array.count, by: by) { array[$0] }
  }

  // Same as above for decorator arrays — avoids materialising a parallel
  // [HistoryItem] just to drive the search.
  func insertionIndex(
    for item: HistoryItem,
    in array: [HistoryItemDecorator],
    by: By = Defaults[.sortBy]
  ) -> Int {
    insertionIndex(for: item, count: array.count, by: by) { array[$0].item }
  }

  private func insertionIndex(
    for item: HistoryItem,
    count: Int,
    by: By,
    itemAt: (Int) -> HistoryItem
  ) -> Int {
    var lo = 0
    var hi = count
    while lo < hi {
      let mid = (lo + hi) / 2
      if shouldComeBefore(item, itemAt(mid), by: by) {
        hi = mid
      } else {
        lo = mid + 1
      }
    }
    return lo
  }

  // Combined ordering: pin status (matches byPinned) first, then the chosen
  // sort criterion. Returns true iff `lhs` should appear before `rhs`.
  private func shouldComeBefore(_ lhs: HistoryItem, _ rhs: HistoryItem, by: By) -> Bool {
    if byPinned(lhs, rhs) { return true }
    if byPinned(rhs, lhs) { return false }
    return bySortingAlgorithm(lhs, rhs, by)
  }

  private func bySortingAlgorithm(_ lhs: HistoryItem, _ rhs: HistoryItem, _ by: By) -> Bool {
    switch by {
    case .firstCopiedAt:
      return lhs.firstCopiedAt > rhs.firstCopiedAt
    case .numberOfCopies:
      return lhs.numberOfCopies > rhs.numberOfCopies
    default:
      return lhs.lastCopiedAt > rhs.lastCopiedAt
    }
  }

  private func byPinned(_ lhs: HistoryItem, _ rhs: HistoryItem) -> Bool {
    if Defaults[.pinTo] == .bottom {
      return (lhs.pin == nil) && (rhs.pin != nil)
    } else {
      return (lhs.pin != nil) && (rhs.pin == nil)
    }
  }
}
// swiftlint:enable identifier_name
// swiftlint:enable type_name
