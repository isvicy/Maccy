# Handoff — Maccy performance fork

State of work on this fork as of the last session, so a fresh Claude Code
session (on this host or another) can resume without re-deriving context.

## Why this fork exists

Personal patch of [Maccy](https://github.com/p0deje/Maccy) to bring its UX up
to par with [Paste.app](https://pasteapp.io) at 30k+ clipboard items. Will not
be shipped upstream — local use only on the user's macOS 26 Tahoe machines.
Driving symptom: the Paste app's search broke (a regression in v6.3.x's
"Power Search" rewrite), so the user migrated to Maccy and now wants Maccy to
not get sluggish past ~5k items.

## Where things live

| Thing | Location |
|---|---|
| This fork (working tree) | `~/github/Maccy` |
| Active branch | `design/paste-like-performance` |
| User fork remote | `git@github.com:isvicy/Maccy.git` |
| Upstream remote | `origin = https://github.com/p0deje/Maccy.git` (read-only; no push intended) |
| Design doc | `docs/perf-redesign.md` — full diagnosis, three-phase plan, verification stack |
| Production Maccy data (Setapp) | `~/Library/Containers/org.p0deje.Maccy-setapp/Data/Library/Application Support/Maccy/Storage.sqlite` (do not touch) |
| Dev Maccy data | `~/Library/Containers/org.p0deje.Maccy.dev/Data/Library/Application Support/Maccy/Storage.sqlite` |
| Paste source data | `~/Library/Application Support/com.wiheads.paste-setapp/{db,index}.sqlite` |
| Paste→Maccy migration script | `hack/migrate-from-paste.py` |
| Build script | `hack/build-dev.sh [--install]` |
| Perf bench | `hack/perf-bench.sh` |

## Locked decisions

1. **Single rewrite, no upstream PR.** Local fork only.
2. **macOS 26 Tahoe only.** Latest SwiftData / FTS5 APIs are fair game.
3. **No iCloud / CloudKit sync.**
4. **Drop fuzzy / regexp / mixed search modes** and the `Fuse` package dependency.
5. **Multi-selection / paste stack** continue to work over the loaded window only.
6. **Test corpus = full Paste history (~28k items)** seeded into the dev container.
7. **`Maccy-dev.app` bundle** with id `org.p0deje.Maccy.dev` lives at `/Applications/Maccy-dev.app`, isolated from the production Setapp install.

## Status

All implementation tasks completed and accepted by the user. Branch
`design/paste-like-performance` sits ahead of `origin/master` with the
following commits (after a final cleanup pass before push):

```
Foundation: design doc, handoff, dev tooling, migration script
Phase 1: lazy load History with windowed pagination
Phase 2: SwiftData predicate search, drop fuzzy/regexp/mixed
Phase 3: FTS5 trigram sidecar (infra; query path uses Phase 2)
Clamp .cursor popup origin to the visible screen frame
```

## What actually shipped

- **Phase 1 — lazy load** as designed: window of 200 unpinned + all pinned at
  launch, `loadMore()` on scroll trailing-edge.
- **Phase 2 — predicate search + drop fuzzy/regexp/mixed** as designed.
- **Phase 3 — FTS5 trigram sidecar** as designed (Storage.swift hosts
  FTSIndex, triggers maintain the table on plain-text content writes), but
  the *query* path was reverted to Phase 2 predicate search after acceptance
  testing surfaced a SwiftData dedup edge case: when the user copies a
  duplicate, the new HistoryItem can land with `contents == []` because the
  cascade-delete of the old item takes its content rows with it before the
  Swift code reattaches them. Items with no content rows are correctly not
  indexed by the FTS triggers, so they silently disappear from FTS results
  even though their title is set. Title-based predicate search hits them
  fine. The FTS infrastructure stays installed but unread — re-enabling is
  one line in `Search.swift` once dedup is fixed upstream or we add a
  title-derived FTS body fallback.
- **Bonus: popup origin clamping.** Upstream Maccy positioned the popup
  with no screen-bounds check; cursor near the bottom edge → clipped popup.
  Fixed in `PopupPosition.swift`.

Everything tested against the migrated 27,928-item Paste corpus in the
isolated `org.p0deje.Maccy.dev` container.

## Resume on a new host

In order:

1. **Get the source.** `git clone git@github.com:isvicy/Maccy.git ~/github/Maccy && cd ~/github/Maccy && git checkout design/paste-like-performance`
2. **Verify Xcode works.** `xcodebuild -version && xcodebuild -list -project ~/github/Maccy/Maccy.xcodeproj`. If it fails with a plugin error, run `sudo xcodebuild -runFirstLaunch`.
3. **Re-migrate Paste data.** Each host has its own Paste history. On the new host:
   - Confirm Paste is installed and has data: `ls ~/Library/Application\ Support/com.wiheads.paste-setapp/index.sqlite`
   - Build dev: `./hack/build-dev.sh --install`
   - Open `Maccy-dev.app` once to create the sandbox container, then quit it.
   - Set retention: `defaults write org.p0deje.Maccy.dev historySize -int 30000` (or higher).
   - Run migration: `python3 hack/migrate-from-paste.py` (defaults to dev container, all items).
4. **Read `docs/perf-redesign.md`** end to end before touching code. The verification stack (Layer A through E) is required for every phase, not optional.

## Memory entries saved

A project-scope memory entry under `~/.claude/projects/.../memory/` flags this
work to future sessions on this host. The entry references this handoff doc
as the source of truth — keep this doc current as you progress, the memory
entry just points at it.
