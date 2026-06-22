#!/usr/bin/env bash
# Step 6: the perf PAYOFF. Held-snapshot analytic read latency, vanilla walk (mode 0) vs serve-only
# cache (mode 1), across buffer-pool sizes. D-0 showed this read is 0.49s @4G (CPU-bound, undo pages
# resident) and ~75s @64M (undo I/O-bound, pages evicted). 4d serve-only skips the walk entirely, so
# it should flatten the curve -- biggest win at small BP where the walk pays undo page I/O. Correctness
# is already proven (4d-2 verify-serve, construct_BAD=0); this measures latency only.
#
# Method: take ONE consistent snapshot, warm scan, sleep while 8-thread churn deepens the per-row
# version chains (the held snapshot pins purge, so the chains stay deep), then run deep scans AFTER
# churn stops (no concurrency) and read MySQL's own per-statement Duration from SHOW PROFILES, plus the
# physical undo page reads charged to the deep-scan window.
exec > /mnt/c/Users/USER/build_d6.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
RDS(){ Q -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

grep -q 'D-4 4d-2' "$HOME/mysql-server/storage/innobase/row/row0vers.cc" || { echo "ERROR: row0vers not at 4d-2 -- run build_d4d2.sh first"; exit 1; }

run(){
  local BP="$1"; local MODE="$2"; local tag="bp${BP}_m${MODE}"
  local MLOG=/mnt/c/Users/USER/d6_${tag}_mysqld.log
  local SLOG=/mnt/c/Users/USER/d6_${tag}_scan.log
  echo ""; echo "########## BP=$BP  MODE=$MODE ($tag) ##########"
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=$MODE "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=$BP --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  Q -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
  Q -e "SELECT COUNT(*) FROM sbtest.sbtest1" >/dev/null
  # snapshot session: warm scan, sleep 48s (covers the 44s churn that starts ~2s later), then 2 deep scans.
  ( "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET profiling=1; SET profiling_history_size=50;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT 'scan_warm' tag, SUM(k+LENGTH(c)+LENGTH(pad)) s FROM sbtest1;
SELECT SLEEP(48);
SELECT 'scan_deep1' tag, SUM(k+LENGTH(c)+LENGTH(pad)) s FROM sbtest1;
SELECT 'scan_deep2' tag, SUM(k+LENGTH(c)+LENGTH(pad)) s FROM sbtest1;
COMMIT;
SELECT '=== PROFILES ==='; SHOW PROFILES;
SQL
  ) > "$SLOG" 2>&1 &
  local SNAP=$!
  sleep 2
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=44 --rand-type=pareto run > /mnt/c/Users/USER/d6_${tag}_churn.log 2>&1 &
  local CH=$!
  wait $CH                       # churn done (~t46); snapshot still sleeping until ~t48
  local R1=$(RDS)                # physical reads BEFORE the deep scans (no churn now)
  wait $SNAP                     # deep scans complete
  local R2=$(RDS)
  echo "--- scan SUMs (all identical within run = snapshot invariant held) ---"
  grep -E 'scan_(warm|deep)' "$SLOG"
  echo "--- per-scan latency (SHOW PROFILES, Duration seconds) ---"
  grep -A60 'PROFILES' "$SLOG" | grep -E 'scan_warm|scan_deep'
  echo "PHYSICAL undo/page reads during deep-scan window (R2-R1) = $((R2-R1))"
  Q -e "SHOW ENGINE INNODB STATUS\G" | grep -i 'History list length'
  echo "--- churn tps ---"; grep -E 'transactions:' /mnt/c/Users/USER/d6_${tag}_churn.log
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  echo "--- [accel] consult ($tag) ---"; grep -E 'consult:' "$MLOG"
}

# CPU-bound (4G) -> mid (256M) -> undo-I/O-bound (64M). mode 0 = vanilla walk, mode 1 = serve-only.
for BP in 4G 256M 64M; do
  run $BP 0
  run $BP 1
done
echo ""; echo "=== ALL DONE ==="
