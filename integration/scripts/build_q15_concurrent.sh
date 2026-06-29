#!/usr/bin/env bash
# Phase-3 pre-flight (confirm dev-complete under the DoD's literal config): the ⑥ held-read payoff and
# ⑤ memory bound were every prior time measured with churn PAUSED before the deep scan (build_d6 does
# `wait $CH` first). This runs the deep analytic scans WHILE OLTP churn is still active -- the real
# concurrent-HTAP regime the DoD asked for -- so GC reclaim runs continuously during the read (the
# chain-sever risk fires live, not as one post-hoc storm). Question answered: does serve stay fast AND
# correct under concurrent churn? mode 0 = vanilla walk, mode 1 = serve-only (drain-cap=1000 stabilizer),
# mode 2 = verify-serve (construct_BAD=0 under concurrency). Latency = SHOW PROFILES Duration (per-stmt,
# clean even under load). Physical-read delta is CONFOUNDED by concurrent churn -> reported but not the
# headline; latency is. See docs/phase2-q3-llt.md + design-D5-gc §12/§13.2.
exec > /mnt/c/Users/USER/${Q15LOG:-q15_concurrent}.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
RDS(){ Q -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

run(){
  local BP="$1"; local MODE="$2"; local CAP="$3"; local tag="bp${BP}_m${MODE}"
  local MLOG=/mnt/c/Users/USER/q15_${tag}_mysqld.log
  local SLOG=/mnt/c/Users/USER/q15_${tag}_scan.log
  echo ""; echo "########## BP=$BP MODE=$MODE DRAIN_CAP=$CAP ($tag) -- deep scans CONCURRENT with churn ##########"
  pkill -9 -x mysqld 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_GC=${ACCEL_GC:-0} ACCEL_AUTHORITATIVE=$MODE ACCEL_DRAIN_CAP=$CAP "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=$BP --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 --innodb-redo-log-capacity=8G > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  Q -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
  Q -e "SELECT COUNT(*) FROM sbtest.sbtest1" >/dev/null
  # snapshot session: warm scan, SLEEP(25) while churn deepens chains, then 3 deep scans that run WHILE
  # churn is STILL ACTIVE (churn runs 50s; deep scans land at ~t27-30, churn ends ~t52). No `wait $CH`.
  ( "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET profiling=1; SET profiling_history_size=50;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT 'scan_warm' tag, SUM(k+LENGTH(c)+LENGTH(pad)) s FROM sbtest1;
SELECT SLEEP(25);
SELECT 'scan_deep1' tag, SUM(k+LENGTH(c)+LENGTH(pad)) s FROM sbtest1;
SELECT 'scan_deep2' tag, SUM(k+LENGTH(c)+LENGTH(pad)) s FROM sbtest1;
SELECT 'scan_deep3' tag, SUM(k+LENGTH(c)+LENGTH(pad)) s FROM sbtest1;
COMMIT;
SELECT '=== PROFILES ==='; SHOW PROFILES;
SQL
  ) > "$SLOG" 2>&1 &
  local SNAP=$!
  sleep 2
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=50 --rand-type=pareto run > /mnt/c/Users/USER/q15_${tag}_churn.log 2>&1 &
  local CH=$!
  local R1=$(RDS)
  wait $SNAP                      # deep scans complete (churn STILL running underneath them)
  local R2=$(RDS)
  Q -e "SHOW ENGINE INNODB STATUS\G" | grep -i 'History list length'
  kill $CH 2>/dev/null; wait $CH 2>/dev/null
  echo "--- scan SUMs (all identical within run = snapshot invariant held under concurrency) ---"
  grep -E 'scan_(warm|deep)' "$SLOG"
  echo "--- per-scan latency (SHOW PROFILES Duration, sec) -- deep scans were CONCURRENT with churn ---"
  grep -A60 'PROFILES' "$SLOG" | grep -E 'scan_warm|scan_deep'
  echo "physical-read delta during concurrent window (R2-R1, CONFOUNDED by churn) = $((R2-R1))"
  echo "--- churn tps (ran throughout the deep scans) ---"; grep -E 'transactions:' /mnt/c/Users/USER/q15_${tag}_churn.log
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -x mysqld 2>/dev/null
  echo "--- [accel] ($tag): consult line = HIT/MISS + construct_BAD; gc line = retire evidence ---"
  grep -E '\[accel\] consult:|\[accel\] gc' "$MLOG" | tail -3
}

echo "=== Phase-3 confirm: ⑥/⑤ under CONCURRENT churn. Gate (mode 2) construct_BAD=0; headline = mode-1 deep latency stays flat ==="
run 64M 0 0       # vanilla walk under concurrency (the slow baseline)
run 64M 1 1000    # serve-only under concurrency, drain-cap=1000 (the headline)
run 64M 2 1000    # verify-serve under concurrency -> construct_BAD=0 correctness gate
run 4G  1 1000    # large-BP serve under concurrency (CPU-bound regime)
echo ""; echo "=== ALL DONE ==="
