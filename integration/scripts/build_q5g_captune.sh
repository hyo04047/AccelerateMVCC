#!/usr/bin/env bash
# 64M-only GC-on q5 recovery attempt: does a lower ACCEL_DRAIN_CAP reduce the noncontig chain-sever
# (the cause of the 64M HIT collapse under GC on) and recover the effective speedup? mode0 = cap-independent
# vanilla baseline; mode1 tried at drain-cap 500 and 200 (lower than the 1000 that gave 1.3x/HIT 0-65%).
set -u
N="${1:-3}"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
RESULTS=/mnt/c/Users/USER/projects/AccelerateMVCC/integration/results
CSV="$RESULTS/q5g_captune.csv"; LOG="$RESULTS/q5g_captune_run.log"
exec > "$LOG" 2>&1
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
RDS(){ Q -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
mkdir -p "$RESULTS"
echo "iter,mode,cap,deep1_lat_s,phys_reads,hit,hit_pct,noncontig,construct_BAD,served" > "$CSV"

run_one(){  # $1=mode $2=cap $3=iter
  local MODE="$1" CAP="$2" iter="$3"; local tag="m${MODE}_cap${CAP}_i${iter}"
  local MLOG="$RESULTS/q5gct_${tag}_mysqld.log"; local SLOG="$RESULTS/q5gct_${tag}_scan.log"
  echo ""; echo "########## $tag ##########"
  pkill -9 -x mysqld 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=$MODE ACCEL_GC=1 ACCEL_DRAIN_CAP=$CAP "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=64M --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
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
COMMIT;
SELECT '=== PROFILES ==='; SHOW PROFILES;
SQL
  ) > "$SLOG" 2>&1 &
  local SNAP=$!; sleep 2
  sysbench oltp_write_only $C --tables=1 --table-size=1000 --threads=8 --time=44 --rand-type=pareto run > "$RESULTS/q5gct_${tag}_churn.log" 2>&1 &
  local CH=$!
  wait $CH; local R1=$(RDS); wait $SNAP; local R2=$(RDS)
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -x mysqld 2>/dev/null
  local LAT=$(grep -A60 'PROFILES' "$SLOG" | awk '/scan_deep1/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/){print $i; exit}}')
  [ -z "$LAT" ] && LAT="NA"; local PHYS=$((R2-R1))
  local CONS=$(grep -E '\[accel\] consult:' "$MLOG" | head -1)
  local HIT=$(echo "$CONS" | grep -oE 'hit=[0-9]+' | grep -oE '[0-9]+')
  local CALLS=$(echo "$CONS" | grep -oE 'calls=[0-9]+' | grep -oE '[0-9]+')
  local NC=$(echo "$CONS" | grep -oE 'noncontig=[0-9]+' | grep -oE '[0-9]+')
  local BAD=$(echo "$CONS" | grep -oE 'construct_BAD=[0-9]+' | grep -oE '[0-9]+')
  local SRV=$(echo "$CONS" | grep -oE 'served=[0-9]+' | grep -oE '[0-9]+')
  : "${HIT:=NA}" "${CALLS:=NA}" "${NC:=NA}" "${BAD:=NA}" "${SRV:=NA}"
  local HP="NA"; [ "$HIT" != "NA" ] && [ "$CALLS" != "NA" ] && [ "$CALLS" -gt 0 ] 2>/dev/null && HP=$(awk "BEGIN{printf \"%.1f\",100*$HIT/$CALLS}")
  echo "$iter,$MODE,$CAP,$LAT,$PHYS,$HIT,$HP,$NC,$BAD,$SRV" >> "$CSV"
  echo ">> $tag : deep1=${LAT}s phys=$PHYS HIT%=$HP noncontig=$NC construct_BAD=$BAD served=$SRV"
}

echo "=== q5 GC-ON 64M drain-cap recovery sweep. N=$N ==="; date
for i in $(seq 1 $N); do run_one 0 1000 $i; done   # vanilla baseline (cap irrelevant to mode0)
for i in $(seq 1 $N); do run_one 1 500  $i; done
for i in $(seq 1 $N); do run_one 1 200  $i; done
echo ""; echo "=== RAW CSV ==="; cat "$CSV"
stat(){ local m="$1" c="$2"; local v=$(awk -F, -v m="$m" -v c="$c" '$2==m && $3==c && $4!="NA"{print $4}' "$CSV" | sort -n)
  [ -z "$v" ] && { echo "(no data)"; return; }
  echo "$v" | awk '{a[NR]=$1} END{n=NR; med=(n%2)?a[(n+1)/2]:(a[n/2]+a[n/2+1])/2; printf "median=%.4f n=%d",med,n}'
  local nc=$(awk -F, -v m="$m" -v c="$c" '$2==m && $3==c{s+=$8;n++} END{printf "%.0f",(n?s/n:0)}' "$CSV")
  local bad=$(awk -F, -v m="$m" -v c="$c" '$2==m && $3==c{s+=$9} END{print s+0}' "$CSV"); printf " avg_noncontig=%s construct_BAD=%s\n" "$nc" "$bad"; }
echo ""; echo "=== SUMMARY (64M, GC on) ==="
printf "mode0 vanilla        : "; stat 0 1000
printf "mode1 serve cap=500  : "; stat 1 500
printf "mode1 serve cap=200  : "; stat 1 200
echo "cap=1000 was median 3.14s / HIT 0-65% / noncontig high. Recovery = lower cap -> less noncontig -> HIT up -> speedup up."
echo "=== DONE ==="; date
