#!/usr/bin/env bash
# D-5 GC-tuning dial CURVE: cap=5000 cut degrade 2/8 -> 1/8 but did not eliminate it. A LOWER cap reclaims the
# storm more slowly (gentler sever) -> should hold more, at more retained memory. Probe cap=1000 (x6) and
# cap=500 (x6) to find whether a clean-stabilization point exists + the memory cost there. construct_BAD must
# stay 0. mysqld already built with the drain-cap.
exec > /mnt/c/Users/USER/build_d5_gctune3.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
declare -A DEG

run(){  # $1=cap  $2=tag
  local cap="$1"; local tag="$2"
  local MLOG=/mnt/c/Users/USER/d5_gt3_${tag}_mysqld.log; local SLOG=/mnt/c/Users/USER/d5_gt3_${tag}_scan.log
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
SELECT '=== PROFILES ===' tag; SHOW PROFILES;
SQL
  ) > "$SLOG" 2>&1 &
  local SNAP=$!
  sleep 2
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=28 --rand-type=pareto run > /mnt/c/Users/USER/d5_gt3_${tag}_churn.log 2>&1 &
  local CH=$!
  wait $CH; wait $SNAP
  local LAT=$(grep -A60 'PROFILES' "$SLOG" | grep -E 'scan_deep1' | awk '{print $2}' | head -1)
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  local CB=$(grep -E 'noncontig split' "$MLOG" | head -1 | sed -E 's/.*chase_break=([0-9]+).*/\1/')
  local BAD=$(grep -E '\[accel\] consult:' "$MLOG" | head -1 | sed -E 's/.*construct_BAD=([0-9]+).*/\1/')
  local DP=$(grep -E '\[accel\] fg-alpha:' "$MLOG" | head -1 | sed -E 's/.*dummy_pending=([0-9]+)/\1/')
  local deg="HOLD"; awk "BEGIN{exit !($LAT>20)}" && deg="DEGRADE"
  [ "$deg" = "DEGRADE" ] && DEG[$cap]=$(( ${DEG[$cap]:-0} + 1 ))
  printf "cap=%-5s %-8s latency=%ss chase_break=%s construct_BAD=%s dummy_pending=%s\n" "$cap" "$deg" "$LAT" "$CB" "$BAD" "$DP"
}

echo "=== cap=1000 x6 ==="; for i in 1 2 3 4 5 6; do run 1000 c1k_$i; done
echo "=== cap=500 x6 ==="; for i in 1 2 3 4 5 6; do run 500 c05_$i; done
echo ""
echo "=== SUMMARY degrades: cap=1000=${DEG[1000]:-0}/6  cap=500=${DEG[500]:-0}/6 (vs earlier cap=0=2/8, cap=5000=1/8) ==="
