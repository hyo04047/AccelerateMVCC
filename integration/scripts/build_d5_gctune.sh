#!/usr/bin/env bash
# D-5 GC-tuning MEASUREMENT: does capping the dummy-drain (ACCEL_DRAIN_CAP) stabilize the ⑥ held-reader payoff?
# The 1/4 degrade (design-D5-gc §12.2) is the small-BP dummy-drain reclaim STORM (~510k in one burst) severing
# the held reader's chain in one shot. Capping the drain per cycle spreads it -> the chain is cut gradually ->
# the held reader can finish its deep scan before the cut completes. A/B the lean ⑥ scenario (held reader +
# churn, 64M, mode-1+GC), N runs each at cap=0 (off) vs cap=5000, comparing: deep-scan latency (hold ~4.7s vs
# degrade ~90s) + hit/chase_break + construct_BAD (must stay 0) + dummy_pending (the retained-orphan MEMORY cost).
exec > /mnt/c/Users/USER/build_d5_gctune.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
echo "=== rebuild mysqld (drain-cap) ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d5_gctune_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d5_gctune_build.log | head -40; exit 1; fi

run(){  # $1=cap  $2=iter
  local cap="$1"; local it="$2"; local tag="cap${cap}_${it}"
  local MLOG=/mnt/c/Users/USER/d5_gctune_${tag}_mysqld.log; local SLOG=/mnt/c/Users/USER/d5_gctune_${tag}_scan.log
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=1 ACCEL_GC=1 ACCEL_AUDIT_N=1024 ACCEL_DRAIN_CAP=$cap "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=64M --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  Q -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1 >/dev/null
  ( "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET profiling=1; SET profiling_history_size=50;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT 'scan_warm' tag, SUM(k+LENGTH(c)+LENGTH(pad)) s FROM sbtest1;
SELECT SLEEP(30);
SELECT 'scan_deep1' tag, SUM(k+LENGTH(c)+LENGTH(pad)) s FROM sbtest1;
COMMIT;
SELECT '=== PROFILES ==='; SHOW PROFILES;
SQL
  ) > "$SLOG" 2>&1 &
  local SNAP=$!
  sleep 2
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=28 --rand-type=pareto run > /mnt/c/Users/USER/d5_gctune_${tag}_churn.log 2>&1 &
  local CH=$!
  wait $CH; wait $SNAP
  local LAT=$(grep -A60 'PROFILES' "$SLOG" | grep -E 'scan_deep1' | awk '{print $2}' | head -1)
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  local CONS=$(grep -E '\[accel\] consult:' "$MLOG" | head -1 | sed -E 's/.*hit=([0-9]+).*construct_BAD=([0-9]+).*/hit=\1 construct_BAD=\2/')
  local SPLIT=$(grep -E 'noncontig split' "$MLOG" | head -1 | sed -E 's/.*chase_break=([0-9]+).*/chase_break=\1/')
  local FG=$(grep -E '\[accel\] fg-alpha:' "$MLOG" | head -1 | sed -E 's/.*drain_cap=([0-9]+) dummy_pending=([0-9]+)/drain_cap=\1 dummy_pending=\2/')
  local GC=$(grep -E '\[accel\] gc: enabled' "$MLOG" | head -1 | sed -E 's/.*retired\{total=([0-9]+) windowed=([0-9]+) dummy=([0-9]+)\}.*/retired_total=\1 windowed=\2 dummy=\3/')
  printf "cap=%-6s it=%s  latency=%ss  %s %s | %s | %s\n" "$cap" "$it" "$LAT" "$CONS" "$SPLIT" "$GC" "$FG"
}

echo ""; echo "=== A/B: lean ⑥ (held reader + churn, 64M, mode-1+GC), 4 runs each: cap=0 (off) vs cap=5000 ==="
echo "--- cap=0 (uncapped = baseline storm) ---"
for it in 1 2 3 4; do run 0 $it; done
echo "--- cap=5000 (spread the storm) ---"
for it in 1 2 3 4; do run 5000 $it; done
echo ""; echo "=== DONE (compare: degrade frequency [latency ~90s] + construct_BAD=0 always + dummy_pending = memory cost) ==="
