#!/usr/bin/env bash
# D-5: re-measure the step-6 payoff under the LINEAGE-WALK consult. The proven ~0.16s flat serve-only
# latency was measured with the OLD max-visible consult; the walk now builds a per-call writer->predecessor
# link table over the (deep, ~1800) chain. Measure ONLY mode 1 (serve-only) at the two extremes 4G
# (CPU-bound, undo resident) and 64M (undo-I/O-bound) -- the vanilla mode-0 baseline is unchanged (it does
# not use consult). Gate: serve-only latency stays ~flat and far below the D-0 walk (4G 0.80s, 64M 123s);
# if the per-call map regresses deep latency materially, switch the walk to an O(C) ordered cursor.
exec > /mnt/c/Users/USER/build_d5_d6_walk.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
RDS(){ Q -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

run(){
  local BP="$1"; local MODE="$2"; local tag="bp${BP}_m${MODE}"
  local MLOG=/mnt/c/Users/USER/d5d6_${tag}_mysqld.log; local SLOG=/mnt/c/Users/USER/d5d6_${tag}_scan.log
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
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=44 --rand-type=pareto run > /mnt/c/Users/USER/d5d6_${tag}_churn.log 2>&1 &
  local CH=$!
  wait $CH; local R1=$(RDS); wait $SNAP; local R2=$(RDS)
  echo "--- scan SUMs (identical = snapshot invariant) ---"; grep -E 'scan_(warm|deep)' "$SLOG"
  echo "--- per-scan latency (SHOW PROFILES Duration s) ---"; grep -A60 'PROFILES' "$SLOG" | grep -E 'scan_warm|scan_deep'
  echo "PHYSICAL reads during deep-scan window (R2-R1) = $((R2-R1))"
  Q -e "SHOW ENGINE INNODB STATUS\G" | grep -i 'History list length'
  grep -E 'transactions:' /mnt/c/Users/USER/d5d6_${tag}_churn.log
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  echo "--- [accel] consult ($tag) ---"; grep -E 'consult:' "$MLOG"
}

run 4G 1
run 64M 1
echo ""; echo "=== DONE (serve-only deep-scan Duration should stay ~0.16s flat, far below D-0 0.8s/123s) ==="
