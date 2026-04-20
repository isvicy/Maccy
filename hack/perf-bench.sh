#!/usr/bin/env bash
# Time the three benchmark queries against a temp copy of Maccy's Storage.sqlite.
# Captures the absolute floor of perf (Core Data wrapping cost is on top).
#
# Usage: hack/perf-bench.sh [path/to/Storage.sqlite]
# Defaults to the dev container.

set -euo pipefail

SRC="${1:-$HOME/Library/Containers/org.p0deje.Maccy.dev/Data/Library/Application Support/Maccy/Storage.sqlite}"
if [[ ! -f "$SRC" ]]; then
  echo "no Storage.sqlite at $SRC" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
cp "$SRC" "$TMP/db.sqlite"
DB="$TMP/db.sqlite"

ROWS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM ZHISTORYITEM;")
HAS_FTS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE name='ZHISTORYITEM_fts';")

echo "Source: $SRC"
echo "Rows:   $ROWS"
echo "FTS:    $([[ $HAS_FTS -gt 0 ]] && echo 'present' || echo 'absent (Phase 3 not applied)')"
echo "---"

bench() {
  local label="$1" sql="$2"
  local start_ms end_ms elapsed
  start_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
  sqlite3 "$DB" "$sql" > /dev/null
  end_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
  elapsed=$((end_ms - start_ms))
  printf "%-30s  %5d ms\n" "$label" "$elapsed"
}

# Run 3x each, take min — first run can include page-cache warmup.
bench_min() {
  local label="$1" sql="$2"
  local best=999999
  for _ in 1 2 3; do
    local start_ms end_ms elapsed
    start_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
    sqlite3 "$DB" "$sql" > /dev/null
    end_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
    elapsed=$((end_ms - start_ms))
    (( elapsed < best )) && best=$elapsed
  done
  printf "%-40s  %5d ms (min of 3)\n" "$label" "$best"
}

echo ""
echo "== launch sim (most-recent 200 unpinned) =="
bench_min "fetch + sort by lastCopiedAt DESC LIMIT 200" \
  "SELECT * FROM ZHISTORYITEM WHERE ZPIN IS NULL ORDER BY ZLASTCOPIEDAT DESC LIMIT 200"

echo ""
echo "== predicate search (LIKE on ZTITLE) =="
for q in "generate" "error" "北京" "https" "function"; do
  bench_min "  query='$q'" \
    "SELECT * FROM ZHISTORYITEM WHERE ZTITLE LIKE '%$q%' ORDER BY ZLASTCOPIEDAT DESC LIMIT 500"
done

echo ""
echo "== full content scan (LIKE on ZHISTORYITEMCONTENT.ZVALUE) =="
echo "(this is what Phase 3 FTS replaces — same semantic, full text)"
for q in "generate" "北京"; do
  bench_min "  query='$q'" \
    "SELECT i.* FROM ZHISTORYITEM i JOIN ZHISTORYITEMCONTENT c ON c.ZITEM=i.Z_PK
     WHERE CAST(c.ZVALUE AS TEXT) LIKE '%$q%' ORDER BY i.ZLASTCOPIEDAT DESC LIMIT 500"
done

if [[ $HAS_FTS -gt 0 ]]; then
  echo ""
  echo "== FTS5 search =="
  for q in "generate" "error" "北京" "https" "function"; do
    bench_min "  query='$q'" \
      "SELECT i.* FROM ZHISTORYITEM i JOIN ZHISTORYITEM_fts f ON f.rowid=i.Z_PK
       WHERE ZHISTORYITEM_fts MATCH '$q' ORDER BY rank LIMIT 500"
  done
fi
