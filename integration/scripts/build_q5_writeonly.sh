#!/usr/bin/env bash
# Phase 2 / ⓠ5 effective speedup on a realistic write-heavy HTAP profile WITH the delete+reinsert MISS
# pattern. Churn = oltp_write_only (fast deep chains -> reaches the I/O-bound regime like ⑥, AND its
# delete+insert produces the cross-generation rows behind the "22% MISS" worry). Held analytic reader does
# the deep SUM; mode 0 = vanilla walk, mode 1 = serve (MISS rows still walk). BP sweep 4G/256M/64M. Reports
# the honest net speedup + consult HIT/MISS + physical undo reads. GC off (isolate from the ⑥ chain-sever).
# Result: the held reader HITs ~99.8-100% (the 22% MISS was short readers near the head, not this reader);
# ~3x resident, ~34x I/O-bound at 64M, construct_BAD=0. See docs/phase2-q3-llt.md ⓠ5.
#
# Prereq: row0vers at 4d-2 (build_d4d2.sh).
exec > /mnt/c/Users/USER/q5_writeonly.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
RDS(){ Q -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

run(){  # $1=BP  $2=mode
  local BP="$1" MODE="$2"; local tag="bp${BP}_m${MODE}"; local MLOG=/mnt/c/Users/USER/q5_${tag}_mysqld.log; local SLOG=/mnt/c/Users/USER/q5_${tag}_scan.log
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=$MODE "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=$BP --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  Q -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_write_only $C --tables=1 --table-size=1000 prepare >/dev/null 2>&1
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
  sysbench oltp_write_only $C --tables=1 --table-size=1000 --threads=8 --time=44 --rand-type=pareto run > /mnt/c/Users/USER/q5_${tag}_churn.log 2>&1 &
  local CH=$!
  wait $CH; local R1=$(RDS); wait $SNAP; local R2=$(RDS)
  Q -e "SHOW ENGINE INNODB STATUS\G" | grep -i 'History list length' > /tmp/q5hll.txt; local HLL=$(grep -oE '[0-9]+' /tmp/q5hll.txt | head -1)
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  local CONS=$(grep -E '\[accel\] consult:' "$MLOG" | head -1)
  local HIT=$(echo "$CONS" | grep -oE 'hit=[0-9]+' | grep -oE '[0-9]+'); local CALLS=$(echo "$CONS" | grep -oE 'calls=[0-9]+' | grep -oE '[0-9]+')
  local BAD=$(echo "$CONS" | grep -oE 'construct_BAD=[0-9]+' | grep -oE '[0-9]+'); local SERVED=$(echo "$CONS" | grep -oE 'served=[0-9]+' | grep -oE '[0-9]+')
  local LAT=$(grep -A60 'PROFILES' "$SLOG" | grep 'scan_deep1' | awk '{print $2}' | head -1)
  local HITPCT="n/a"; [ -n "$HIT" ] && [ -n "$CALLS" ] && [ "$CALLS" -gt 0 ] && HITPCT=$(awk "BEGIN{printf \"%.1f\", 100*$HIT/$CALLS}")
  printf "BP=%-5s mode=%s | deep1_lat=%-11s phys_reads=%-9s HIT%%=%-6s construct_BAD=%-3s served=%-8s HLL=%-9s\n" "$BP" "$MODE" "${LAT}s" "$((R2-R1))" "$HITPCT" "$BAD" "$SERVED" "$HLL"
}

echo "=== ⓠ5 effective speedup (oltp_write_only churn + held deep reader, GC off): mode0 vs mode1 per BP ==="
for BP in 4G 256M 64M; do run $BP 0; run $BP 1; done
echo "=== DONE ==="
