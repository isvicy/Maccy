// swiftlint:disable file_length
import AppKit.NSRunningApplication
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import Settings
import SwiftData

@Observable
class History: ItemsContainer { // swiftlint:disable:this type_body_length
  static let shared = History()
  let logger = Logger(label: "org.p0deje.Maccy")

  var items: [HistoryItemDecorator] = []
  var pasteStack: PasteStack?

  var pinnedItems: [HistoryItemDecorator] { items.filter(\.isPinned) }
  var unpinnedItems: [HistoryItemDecorator] { items.filter(\.isUnpinned) }

  var searchQuery: String = "" {
    didSet {
      // Phase 2: search now hits SwiftData directly across the full on-disk
      // store. Throttler is gone — DB query is fast enough that throttling
      // costs more (latency) than it saves (CPU).
      Task { @MainActor in
        let results = self.search.search(string: self.searchQuery, in: self.all)
        self.updateItems(results)

        if self.searchQuery.isEmpty {
          AppState.shared.navigator.select(item: self.unpinnedItems.first)
        } else {
          AppState.shared.navigator.highlightFirst()
        }

        AppState.shared.popup.needsResize = true
      }
    }
  }

  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else {
      return nil
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)

    guard HistoryItemAction(modifierFlags) != .unknown else {
      return nil
    }

    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
  }

  private let search = Search()
  private let sorter = Sorter()

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]

  // The distinction between `all` and `items` is the following:
  // - `all` stores history items materialised into memory: pinned + the loaded window
  //   of unpinned. The window grows via `loadMore()` as the user scrolls.
  // - `items` stores only visible history items, updated during a search.
  @ObservationIgnored
  var all: [HistoryItemDecorator] = []

  // Phase 1 — lazy load. Fetch one page at a time as the user scrolls.
  // Initial load = pinned + first pageSize unpinned. Older items materialise on demand.
  private let pageSize = 200

  // Total unpinned count on disk (refreshed on load / add / delete). Used to detect
  // when loadMore() has nothing left to fetch.
  @ObservationIgnored
  private var totalUnpinnedOnDisk = 0

  // Count of unpinned items currently in `all`. Always ≤ totalUnpinnedOnDisk.
  @ObservationIgnored
  private var loadedUnpinnedCount = 0

  // True iff there are more unpinned items on disk than currently in `all`.
  var hasMoreToLoad: Bool { loadedUnpinnedCount < totalUnpinnedOnDisk }

  // Reentrancy guard for loadMore — onAppear of trailing rows can fire several
  // times before the in-flight fetch completes.
  @ObservationIgnored
  private var isLoadingMore = false

  init() {
    Task {
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        updateShortcuts()
      }
    }

    Task {
      for await _ in Defaults.updates(.sortBy, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.pinTo, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        for item in items {
          await updateTitle(item: item, title: item.item.generateTitle())
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        for item in items {
          await item.cleanupImages()
        }
      }
    }
  }

  @MainActor
  func load() async throws {
    // Pinned items: fetch all (small N, drives the top-bar pin section).
    let pinnedDesc = FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.pin != nil })
    let pinned = try Storage.shared.context.fetch(pinnedDesc)

    // Unpinned items: fetch only the first page, sorted by lastCopiedAt DESC at the SQL layer.
    var unpinnedDesc = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin == nil },
      sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
    )
    unpinnedDesc.fetchLimit = pageSize
    let unpinned = try Storage.shared.context.fetch(unpinnedDesc)

    // Total unpinned count for loadMore() bookkeeping. Cheap on macOS 15 — uses COUNT(*).
    totalUnpinnedOnDisk = (try? Storage.shared.context.fetchCount(
      FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.pin == nil })
    )) ?? unpinned.count
    loadedUnpinnedCount = unpinned.count

    // Sorter still owns the pin-vs-unpinned ordering policy (top vs bottom, etc).
    all = sorter.sort(pinned + unpinned).map { HistoryItemDecorator($0) }
    items = all

    limitHistorySizeOnDisk(to: Defaults[.size])

    updateShortcuts()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  // Append the next page of unpinned items to the loaded window.
  // Triggered by HistoryListView when the trailing-edge row appears.
  @MainActor
  func loadMore() async {
    guard hasMoreToLoad, !isLoadingMore else { return }
    isLoadingMore = true
    defer { isLoadingMore = false }

    var desc = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin == nil },
      sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
    )
    desc.fetchLimit = pageSize
    desc.fetchOffset = loadedUnpinnedCount
    guard let next = try? Storage.shared.context.fetch(desc), !next.isEmpty else { return }

    let decorators = next.map { HistoryItemDecorator($0) }
    all.append(contentsOf: decorators)
    loadedUnpinnedCount += next.count

    // If no active search, mirror to visible items immediately. Otherwise the
    // search filter will pick the new items up on its next refresh.
    if searchQuery.isEmpty {
      items = all
    }
    updateUnpinnedShortcuts()
  }

  // Evict items beyond maxSize from the on-disk store *and* from the loaded window.
  // Replaces the old `limitHistorySize`, which only operated on the in-memory `all` array.
  @MainActor
  private func limitHistorySizeOnDisk(to maxSize: Int) {
    guard totalUnpinnedOnDisk > maxSize else { return }
    var desc = FetchDescriptor<HistoryItem>(
      predicate: #Predicate { $0.pin == nil },
      sortBy: [SortDescriptor(\.lastCopiedAt, order: .reverse)]
    )
    desc.fetchOffset = maxSize
    guard let toEvict = try? Storage.shared.context.fetch(desc), !toEvict.isEmpty else { return }
    for item in toEvict {
      if let dec = all.first(where: { $0.item == item }) {
        delete(dec)
      } else {
        // Not in loaded window; delete directly from store.
        Storage.shared.context.delete(item)
      }
    }
    try? Storage.shared.context.save()
    totalUnpinnedOnDisk = (try? Storage.shared.context.fetchCount(
      FetchDescriptor<HistoryItem>(predicate: #Predicate { $0.pin == nil })
    )) ?? totalUnpinnedOnDisk
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    logger.info("Inserting item with id '\(item.title)'")
    Storage.shared.context.insert(item)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
  }

  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator {
    if #available(macOS 15.0, *) {
      try? History.shared.insertIntoStorage(item)
    } else {
      // On macOS 14 the history item needs to be inserted into storage directly after creating it.
      // It was already inserted after creation in Clipboard.swift
    }

    var removedItemIndex: Int?
    if let existingHistoryItem = findSimilarItem(item) {
      if isModified(item) == nil {
        item.contents = existingHistoryItem.contents
      }
      item.firstCopiedAt = existingHistoryItem.firstCopiedAt
      item.numberOfCopies += existingHistoryItem.numberOfCopies
      item.pin = existingHistoryItem.pin
      item.title = existingHistoryItem.title
      if !item.fromMaccy {
        item.application = existingHistoryItem.application
      }
      logger.info("Removing duplicate item '\(item.title)'")
      Storage.shared.context.delete(existingHistoryItem)
      removedItemIndex = all.firstIndex(where: { $0.item == existingHistoryItem })
      if let removedItemIndex {
        all.remove(at: removedItemIndex)
      }
    } else {
      Task {
        Notifier.notify(body: item.title, sound: .write)
      }
    }

    // Phase 1: count bookkeeping. Eviction happens at load() only, not per
    // add() — running delete()+save() inside add()'s save chain causes Core
    // Data optimistic-lock crashes (NSManagedObjectContext._thereIsNoSadness…).
    // The trade-off is the on-disk count can drift slightly past historySize
    // between launches; the next load() trims it back.
    if removedItemIndex == nil && item.pin == nil {
      totalUnpinnedOnDisk += 1
    }

    sessionLog[Clipboard.shared.changeCount] = item

    var itemDecorator: HistoryItemDecorator
    if let pin = item.pin {
      itemDecorator = HistoryItemDecorator(item, shortcuts: KeyShortcut.create(character: pin))
      // Keep pins in the same place.
      if let removedItemIndex {
        all.insert(itemDecorator, at: removedItemIndex)
      }
    } else {
      itemDecorator = HistoryItemDecorator(item)

      let sortedItems = sorter.sort(all.map(\.item) + [item])
      if let index = sortedItems.firstIndex(of: item) {
        all.insert(itemDecorator, at: index)
      }
      // Net new unpinned item now in `all`. (Duplicate replacement net-zero.)
      if removedItemIndex == nil {
        loadedUnpinnedCount += 1
      }

      items = all
      updateUnpinnedShortcuts()
      AppState.shared.popup.needsResize = true
    }

    return itemDecorator
  }

  @MainActor
  private func withLogging(_ msg: String, _ block: () throws -> Void) rethrows {
    func dataCounts() -> String {
      let historyItemCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>())
      let historyContentCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItemContent>())
      return "HistoryItem=\(historyItemCount ?? 0) HistoryItemContent=\(historyContentCount ?? 0)"
    }

    logger.info("\(msg) Before: \(dataCounts())")
    try? block()
    logger.info("\(msg) After: \(dataCounts())")
  }

  @MainActor
  func clear() {
    withLogging("Clearing history") {
      all.forEach { item in
        if item.isUnpinned {
          cleanup(item)
        }
      }
      all.removeAll(where: \.isUnpinned)
      sessionLog.removeValues { $0.pin == nil }
      items = all
      totalUnpinnedOnDisk = 0
      loadedUnpinnedCount = 0

      try? Storage.shared.context.transaction {
        try? Storage.shared.context.delete(
          model: HistoryItem.self,
          where: #Predicate { $0.pin == nil }
        )
        try? Storage.shared.context.delete(
          model: HistoryItemContent.self,
          where: #Predicate { $0.item?.pin == nil }
        )
      }
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func clearAll() {
    withLogging("Clearing all history") {
      all.forEach { item in
        cleanup(item)
      }
      all.removeAll()
      sessionLog.removeAll()
      items = all
      totalUnpinnedOnDisk = 0
      loadedUnpinnedCount = 0

      try? Storage.shared.context.delete(model: HistoryItem.self)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func delete(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    let wasUnpinnedAndLoaded = item.isUnpinned && all.contains(where: { $0 == item })

    cleanup(item)
    withLogging("Removing history item") {
      Storage.shared.context.delete(item.item)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    all.removeAll { $0 == item }
    items.removeAll { $0 == item }
    sessionLog.removeValues { $0 == item.item }

    if wasUnpinnedAndLoaded {
      loadedUnpinnedCount -= 1
      totalUnpinnedOnDisk -= 1
    } else if item.isUnpinned {
      totalUnpinnedOnDisk -= 1
    }

    updateUnpinnedShortcuts()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func cleanup(_ item: HistoryItemDecorator) {
    item.cleanupImages()
  }

  private func currentModifierFlags() -> NSEvent.ModifierFlags {
    return NSApp.currentEvent?.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function]) ?? []
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?) {
    guard let item else {
      return
    }

    let modifierFlags = currentModifierFlags()

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      if Defaults[.pasteByDefault] {
        Clipboard.shared.paste()
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  @MainActor
  func startPasteStack(selection: inout Selection<HistoryItemDecorator>) {
    guard AppState.shared.multiSelectionEnabled else { return }
    guard let item = selection.first else { return }
    PasteStack.initializeIfNeeded()

    let modifierFlags = currentModifierFlags()

    let stack = PasteStack(items: selection.items, modifierFlags: modifierFlags)
    pasteStack = stack

    logger.info("Initialising PasteStack with \(stack.items.count) items")
    logger.info("Copying \(item.item.title) from PasteStack")

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  func handlePasteStack() {
    guard let stack = pasteStack else {
      return
    }

    guard let pasted = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("PasteStack pasted \(pasted.item.title)")

    stack.items.removeFirst()

    guard let item = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("Copying \(item.item.title) from PasteStack. \(stack.items.count) items remaining in stack.")

    Task {
      if stack.modifierFlags.isEmpty {
        await Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      } else {
        switch HistoryItemAction(stack.modifierFlags) {
        case .copy:
          await Clipboard.shared.copy(item.item)
        case .paste:
          await Clipboard.shared.copy(item.item)
        case .pasteWithoutFormatting:
          await Clipboard.shared.copy(item.item, removeFormatting: true)
        case .unknown:
          return
        }
      }
    }
  }

  func interruptPasteStack() {
    guard pasteStack != nil else {
      return
    }
    logger.info("Interrupting PasteStack")
    pasteStack = nil
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    item.togglePin()

    let sortedItems = sorter.sort(all.map(\.item))
    if let currentIndex = all.firstIndex(of: item),
       let newIndex = sortedItems.firstIndex(of: item.item) {
      all.remove(at: currentIndex)
      all.insert(item, at: newIndex)
    }

    items = all

    searchQuery = ""
    updateUnpinnedShortcuts()
    if item.isUnpinned {
      AppState.shared.navigator.scrollTarget = item.id
    }
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    let descriptor = FetchDescriptor<HistoryItem>()
    if let all = try? Storage.shared.context.fetch(descriptor) {
      let duplicates = all.filter({ $0 == item || $0.supersedes(item) })
      if duplicates.count > 1 {
        return duplicates.first(where: { $0 != item })
      } else {
        return isModified(item)
      }
    }

    return item
  }

  private func isModified(_ item: HistoryItem) -> HistoryItem? {
    if let modified = item.modified, sessionLog.keys.contains(modified) {
      return sessionLog[modified]
    }

    return nil
  }

  private func updateItems(_ newItems: [Search.SearchResult]) {
    items = newItems.map { result in
      let item = result.object
      item.highlight(searchQuery, result.ranges)

      return item
    }

    updateUnpinnedShortcuts()
  }

  private func updateShortcuts() {
    for item in pinnedItems {
      if let pin = item.item.pin {
        item.shortcuts = KeyShortcut.create(character: pin)
      }
    }

    updateUnpinnedShortcuts()
  }

  @MainActor
  private func updateTitle(item: HistoryItemDecorator, title: String) {
    item.title = title
    item.item.title = title
  }

  private func updateUnpinnedShortcuts() {
    let visibleUnpinnedItems = unpinnedItems.filter(\.isVisible)
    for item in visibleUnpinnedItems {
      item.shortcuts = []
    }

    var index = 1
    for item in visibleUnpinnedItems.prefix(9) {
      item.shortcuts = KeyShortcut.create(character: String(index))
      index += 1
    }
  }
}
