#!/usr/bin/env bash
# D-5 GC-tuning FIRM-UP: characterize the drain-cap dial. (a) degrade-frequency: 8 runs each at cap=0 vs
# cap=5000 (lean ⑥, 64M, mode-1+GC) -- does the cap reliably drop the storm-driven degrade? (b) the
# memory-vs-stability curve: dummy_pending (retained orphans) per run + 2 long-hold (60s) cap=5000 runs to
# see if the retained memory grows with the held window. construct_BAD must be 0 in EVERY run. mysqld already
# built with the drain-cap (build_d5_gctune.sh); this only runs.
exec > /mnt/c/Users/USER/build_d5_gctune2.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
DEG_0=0; DEG_5k=0

run(){  # $1=cap  $2=sleep  $3=tag
  local cap="$1"; local slp="$2"; local tag="$3"
  local MLOG=/mnt/c/Users/USER/d5_gt2_${tag}_mysqld.log; local SLOG=/mnt/c/Users/USER/d5_gt2_${tag}_scan.log
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=1 ACCEL_GC=1 ACCEL_AUDIT_N=1024 ACCEL_DRAIN_CAP=$cap "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=64M --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  Q -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1 >/dev/null
  ( "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest <<SQL
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET profiling=1; SET profiling_history_size=50;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT 'scan_warm' tag, SUM(k+LENGTH(c)+LENGTH(pad)) s FROM sbtest1;
SELECT SLEEP($slp);
SELECT 'scan_deep1' tag, SUM(k+LENGTH(c)+LENGTH(pad)) s FROM sbtest1;
COMMIT;
SELECT '=== PROFILES ===' tag; SHOW PROFILES;
SQL
  ) > "$SLOG" 2>&1 &
  local SNAP=$!
  sleep 2
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=$((slp-2)) --rand-type=pareto run > /mnt/c/Users/USER/d5_gt2_${tag}_churn.log 2>&1 &
  local CH=$!
  wait $CH; wait $SNAP
  local LAT=$(grep -A60 'PROFILES' "$SLOG" | grep -E 'scan_deep1' | awk '{print $2}' | head -1)
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  local CB=$(grep -E 'noncontig split' "$MLOG" | head -1 | sed -E 's/.*chase_break=([0-9]+).*/\1/')
  local BAD=$(grep -E '\[accel\] consult:' "$MLOG" | head -1 | sed -E 's/.*construct_BAD=([0-9]+).*/\1/')
  local DP=$(grep -E '\[accel\] fg-alpha:' "$MLOG" | head -1 | sed -E 's/.*dummy_pending=([0-9]+)/\1/')
  local DR=$(grep -E '\[accel\] gc: enabled' "$MLOG" | head -1 | sed -E 's/.*retired\{total=([0-9]+).*dummy=([0-9]+)\}.*/tot=\1 dummy=\2/')
  local deg="HOLD"; awk "BEGIN{exit !($LAT>20)}" && deg="DEGRADE"
  [ "$deg" = "DEGRADE" ] && { [ "$cap" = "0" ] && DEG_0=$((DEG_0+1)); [ "$cap" = "5000" ] && DEG_5k=$((DEG_5k+1)); }
  printf "cap=%-5s sleep=%-3s %-8s latency=%ss chase_break=%s construct_BAD=%s | retired %s dummy_pending=%s\n" \
         "$cap" "$slp" "$deg" "$LAT" "$CB" "$BAD" "$DR" "$DP"
}

echo "=== (a) degrade frequency: cap=0 x8 vs cap=5000 x8 (30s hold) ==="
echo "--- cap=0 ---"; for i in 1 2 3 4 5 6 7 8; do run 0 30 c0_$i; done
echo "--- cap=5000 ---"; for i in 1 2 3 4 5 6 7 8; do run 5000 30 c5k_$i; done
echo "=== (b) memory growth: cap=5000 long hold (60s) x2 -- does dummy_pending grow with the window? ==="
for i in 1 2; do run 5000 60 c5k_long_$i; done
echo ""
echo "=== SUMMARY: cap=0 degrades=$DEG_0/8   cap=5000 degrades=$DEG_5k/8   (construct_BAD must be 0 everywhere) ==="
