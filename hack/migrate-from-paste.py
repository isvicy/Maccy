#!/usr/bin/env python3
"""Migrate Text/Link items from Paste to a Maccy SwiftData store via direct SQL.

Usage:
  hack/migrate-from-paste.py [--target PATH] [--limit N]

  --target PATH   Path to Maccy's Storage.sqlite. Defaults to the
                  org.p0deje.Maccy.dev container (the dev build).
  --limit N       Take the most recent N Text/Link items. 0 = all.
                  Defaults to 0 (full corpus).

The script:
  - aborts if the target Maccy process is alive (Core Data WAL lock)
  - timestamps a backup of Storage.sqlite (and -wal/-shm if present)
  - dedups by content; keeps the newest timestamp; pinboard items always included
  - inserts into ZHISTORYITEM + ZHISTORYITEMCONTENT, then bumps Z_PRIMARYKEY counters
"""
import argparse
import shutil
import sqlite3
import subprocess
import sys
from datetime import datetime
from pathlib import Path

HOME = Path.home()
PASTE_IDX = HOME / "Library/Application Support/com.wiheads.paste-setapp/index.sqlite"
PASTE_DB = HOME / "Library/Application Support/com.wiheads.paste-setapp/db.sqlite"
DEFAULT_TARGET = HOME / "Library/Containers/org.p0deje.Maccy.dev/Data/Library/Application Support/Maccy/Storage.sqlite"

BUNDLE_MAP = {
    "kitty": "net.kovidgoyal.kitty",
    "Arc": "company.thebrowser.Browser",
    "loginwindow": "com.apple.loginwindow",
    "Feishu": "com.electron.lark",
    "Ghostty": "com.mitchellh.ghostty",
    "Terminal": "com.apple.Terminal",
    "OrbStack": "dev.kdrag0n.MacVirt",
    "UserNotificationCenter": "com.apple.UserNotificationCenter",
    "Google Chrome": "com.google.Chrome",
    "Telegram": "ru.keepcoder.Telegram",
    "钉钉": "com.alibaba.DingTalkMac",
    "Xcode": "com.apple.dt.Xcode",
    "Zed": "dev.zed.Zed",
    "Obsidian": "md.obsidian",
    "Finder": "com.apple.finder",
}

APPLE_EPOCH_OFFSET = 978307200  # 2001-01-01 UTC in unix seconds


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", type=Path, default=DEFAULT_TARGET)
    ap.add_argument("--limit", type=int, default=0, help="0 = all items")
    args = ap.parse_args()

    target = args.target
    if not target.exists():
        sys.exit(f"ABORT: target Storage.sqlite not found at {target}\n"
                 f"Launch the corresponding Maccy build at least once to create the container.")

    # Refuse if any process holds an open file handle to the target — Core Data WAL lock.
    # (Multiple Maccy installs with different bundle ids each have their own Storage.sqlite,
    # so we check the specific target rather than blanket-killing all Maccy processes.)
    lsof = subprocess.run(["lsof", str(target)], capture_output=True, text=True)
    if lsof.stdout.strip():
        sys.exit(f"ABORT: target {target} is locked:\n{lsof.stdout}\nQuit the holder process first.")

    # Backup target + sidecar files.
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    backups = []
    for ext in ("", "-wal", "-shm"):
        src = target.parent / (target.name + ext)
        if src.exists():
            dst = src.with_name(src.name + f".bak.{ts}")
            shutil.copy2(src, dst)
            backups.append(str(dst))
    print("Backups:")
    for b in backups:
        print(f"  {b}")

    # Pinboard items first (joined to index for the actual text).
    con_db = sqlite3.connect(f"file:{PASTE_DB}?mode=ro", uri=True)
    con_db.execute("ATTACH ? AS idx", (str(PASTE_IDX),))
    pinboard_rows = con_db.execute("""
      SELECT x.content, x.timestamp, x.app, l.ZNAME
      FROM ZITEMENTITY i
      JOIN ZLISTENTITY l ON i.ZLIST = l.Z_PK
      JOIN idx.items x ON x.id = i.ZIDENTIFIER
      WHERE l.ZRAWTYPE = 2
        AND x.type IN ('Text','Link')
        AND length(x.content) > 0
      ORDER BY i.ZTIMESTAMP DESC
    """).fetchall()
    con_db.close()
    print(f"\nPinboard items: {len(pinboard_rows)}")

    # Recent items; --limit 0 means take all.
    con_idx = sqlite3.connect(f"file:{PASTE_IDX}?mode=ro", uri=True)
    sql = """
      SELECT content, timestamp, app
      FROM items
      WHERE type IN ('Text','Link') AND length(content) > 0
      ORDER BY timestamp DESC
    """
    if args.limit > 0:
        sql += f" LIMIT {args.limit}"
    recent = con_idx.execute(sql).fetchall()
    con_idx.close()
    label = f"top {args.limit}" if args.limit > 0 else "all"
    print(f"Recent items ({label}): {len(recent)}")

    # Dedup by content; pinboard wins, but use newest timestamp.
    seen = {}  # content -> [ts, app, pin_letter, board_name]
    for content, ts_, app, board_name in pinboard_rows:
        seen[content] = [ts_, app, None, board_name]
    for content, ts_, app in recent:
        if content in seen:
            if ts_ > seen[content][0]:
                seen[content][0] = ts_
                seen[content][1] = app
        else:
            seen[content] = [ts_, app, None, None]

    print(f"Total unique entries to insert: {len(seen)}")

    con_m = sqlite3.connect(str(target))
    cur = con_m.cursor()
    max_item_pk = cur.execute("SELECT COALESCE(MAX(Z_PK), 0) FROM ZHISTORYITEM").fetchone()[0]
    max_content_pk = cur.execute("SELECT COALESCE(MAX(Z_PK), 0) FROM ZHISTORYITEMCONTENT").fetchone()[0]
    print(f"\nStarting Z_PK: item={max_item_pk}, content={max_content_pk}")

    cur.execute("BEGIN")
    try:
        for content, (ts_, app, pin_letter, _) in seen.items():
            max_item_pk += 1
            max_content_pk += 1
            apple_ts = ts_ - APPLE_EPOCH_OFFSET
            bundle = BUNDLE_MAP.get(app)
            title = content[:100]
            cur.execute(
                "INSERT INTO ZHISTORYITEM "
                "(Z_PK, Z_ENT, Z_OPT, ZNUMBEROFCOPIES, ZFIRSTCOPIEDAT, ZLASTCOPIEDAT, ZAPPLICATION, ZPIN, ZTITLE) "
                "VALUES (?, 1, 1, 1, ?, ?, ?, ?, ?)",
                (max_item_pk, apple_ts, apple_ts, bundle, pin_letter, title)
            )
            cur.execute(
                "INSERT INTO ZHISTORYITEMCONTENT "
                "(Z_PK, Z_ENT, Z_OPT, ZITEM, ZTYPE, ZVALUE) "
                "VALUES (?, 2, 1, ?, 'public.utf8-plain-text', ?)",
                (max_content_pk, max_item_pk, content.encode('utf-8'))
            )

        cur.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_NAME = 'HistoryItem'", (max_item_pk,))
        cur.execute("UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_NAME = 'HistoryItemContent'", (max_content_pk,))
        con_m.commit()
        print(f"Final Z_PK: item={max_item_pk}, content={max_content_pk}")
    except Exception as e:
        con_m.rollback()
        print(f"FAILED, rolled back: {e}", file=sys.stderr)
        raise
    finally:
        con_m.close()

    print("\nMigration complete.")


if __name__ == "__main__":
    main()
