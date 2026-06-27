#!/usr/bin/env bash
# D-5 ⑥ re-measure UNDER GC-on: does the held-snapshot deep-read serve payoff survive the GC?
# Same harness as build_d6.sh (held REPEATABLE-READ snapshot; 8-thread churn deepens chains while the
# snapshot pins purge; deep scans AFTER churn; latency from SHOW PROFILES + physical reads), but mysqld
# runs with ACCEL_GC=1. Open question (theory): GC reclaims the IN-MIDDLE versions between the head and
# the held reader's version, which can SEVER the live chain the GC-safe lineage-walk consult needs to
# reach the (LLT-protected) held version -> consult MISS -> vanilla walk -> payoff degraded. This measures
# it. consult hit vs noncontig-MISS + GC retire are reported. (mysqld already built by build_d5_c2.sh.)
exec > /mnt/c/Users/USER/build_d5_d6_gc.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
RDS(){ Q -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

run(){
  local BP="$1"; local MODE="$2"; local tag="bp${BP}_m${MODE}_gc"
  local MLOG=/mnt/c/Users/USER/d6gc_${tag}_mysqld.log
  local SLOG=/mnt/c/Users/USER/d6gc_${tag}_scan.log
  echo ""; echo "########## BP=$BP MODE=$MODE GC=on ($tag) ##########"
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=$MODE ACCEL_GC=1 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
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
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=44 --rand-type=pareto run > /mnt/c/Users/USER/d6gc_${tag}_churn.log 2>&1 &
  local CH=$!
  wait $CH; local R1=$(RDS); wait $SNAP; local R2=$(RDS)
  echo "--- scan SUMs (identical = snapshot invariant held) ---"; grep -E 'scan_(warm|deep)' "$SLOG"
  echo "--- per-scan latency (SHOW PROFILES Duration s) ---"; grep -A60 'PROFILES' "$SLOG" | grep -E 'scan_warm|scan_deep'
  echo "PHYSICAL reads during deep-scan window (R2-R1) = $((R2-R1))"
  echo "--- churn tps ---"; grep -E 'transactions:' /mnt/c/Users/USER/d6gc_${tag}_churn.log
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  echo "--- [accel] consult + gc ($tag) ---"; grep -E 'consult:|gc: enabled' "$MLOG"
}

for BP in 64M 4G; do
  run $BP 0      # vanilla walk (baseline) under GC
  run $BP 1      # serve-only under GC -- does the payoff survive?
done
echo ""; echo "=== ALL DONE (compare m1 latency vs m0; consult hit vs noncontig tells if GC severed the chain) ==="
