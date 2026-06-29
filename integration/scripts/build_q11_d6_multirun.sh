#!/usr/bin/env bash
# Phase 3 gate ① (variance/error-bars) + ② (raw-log archival) for the ⑥ held-read serve payoff.
# Re-runs the build_d5_d6_gc.sh harness N times at the SHIP setting (mode-1 serve-only, GC on,
# ACCEL_DRAIN_CAP=1000 = the ⑥ stabilizer, design-D5-gc §13.2), capturing per-run latency so the
# single-run "~190x" headline becomes median + min/max + a degrade count. The 64M arm is the headline
# (non-deterministic: chain-sever degrades some runs to the correct vanilla walk); 4G is the resident
# stability check. mode-0 (vanilla walk) is the baseline denominator. Raw per-run mysqld/scan logs +
# a CSV land in integration/results/ so the repo can reproduce the tables (Phase 3 gate ②).
#
# Usage: build_q11_d6_multirun.sh [N_serve_64M]   (default 8). mysqld must already be built (current accel sources).
set -u
N="${1:-8}"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
RESULTS=/mnt/c/Users/USER/projects/AccelerateMVCC/integration/results
CSV="$RESULTS/q11_d6.csv"
LOG="$RESULTS/q11_d6_run.log"
exec > "$LOG" 2>&1
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
RDS(){ Q -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

mkdir -p "$RESULTS"
echo "iter,bp,mode,cap,deep1_lat_s,phys_reads,consult_calls,hit,noncontig,construct_BAD,served,degraded" > "$CSV"

# one fresh-boot measured run -> appends one CSV row
run_one(){
  local BP="$1" MODE="$2" iter="$3" CAP="$4"
  local tag="bp${BP}_m${MODE}_cap${CAP}_i${iter}"
  local MLOG="$RESULTS/d6_${tag}_mysqld.log"
  local SLOG="$RESULTS/d6_${tag}_scan.log"
  echo ""; echo "########## $tag (N=$N) ##########"
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=$MODE ACCEL_GC=1 ACCEL_DRAIN_CAP=$CAP "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=$BP --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  Q -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare >/dev/null 2>&1
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
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=44 --rand-type=pareto run > "$RESULTS/d6_${tag}_churn.log" 2>&1 &
  local CH=$!
  wait $CH; local R1=$(RDS); wait $SNAP; local R2=$(RDS)
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null

  # --- robust latency: first float on the scan_deep1 PROFILES line (= Duration; SUM is an int, Query_ID is an int) ---
  local LAT=$(grep -A60 'PROFILES' "$SLOG" | awk '/scan_deep1/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/){print $i; exit}}')
  [ -z "$LAT" ] && LAT="NA"
  local PHYS=$((R2-R1))
  local CONS=$(grep -E '\[accel\] consult:' "$MLOG" | tail -1)
  local CALLS=$(echo "$CONS" | grep -oE 'calls=[0-9]+'        | grep -oE '[0-9]+')
  local HIT=$(echo "$CONS"   | grep -oE 'hit=[0-9]+'          | grep -oE '[0-9]+')
  local NC=$(echo "$CONS"    | grep -oE 'noncontig=[0-9]+'    | grep -oE '[0-9]+')
  local BAD=$(echo "$CONS"   | grep -oE 'construct_BAD=[0-9]+'| grep -oE '[0-9]+')
  local SRV=$(echo "$CONS"   | grep -oE 'served=[0-9]+'       | grep -oE '[0-9]+')
  : "${CALLS:=NA}" "${HIT:=NA}" "${NC:=NA}" "${BAD:=NA}" "${SRV:=NA}"
  # degrade flag: a serve run whose deep read took the slow vanilla walk (> 2s) instead of the ~0.16s served path
  local DEG=0
  if [ "$LAT" != "NA" ]; then DEG=$(awk -v l="$LAT" 'BEGIN{print (l>2.0)?1:0}'); fi
  echo "$iter,$BP,$MODE,$CAP,$LAT,$PHYS,$CALLS,$HIT,$NC,$BAD,$SRV,$DEG" >> "$CSV"
  echo ">> $tag : deep1_lat=${LAT}s phys=$PHYS hit=$HIT noncontig=$NC construct_BAD=$BAD served=$SRV degraded=$DEG"
  echo "   consult: $CONS"
}

echo "=== ⑥ MULTI-RUN (ship setting: mode-1 serve, GC on, DRAIN_CAP=1000). N(serve,64M)=$N ==="
date

# 64M headline: vanilla baseline x3, serve x N
for i in $(seq 1 3);  do run_one 64M 0 $i 1000; done
for i in $(seq 1 $N); do run_one 64M 1 $i 1000; done
# 4G resident stability: vanilla x2, serve x3
for i in $(seq 1 2);  do run_one 4G 0 $i 1000; done
for i in $(seq 1 3);  do run_one 4G 1 $i 1000; done

echo ""; echo "=== RAW CSV ($CSV) ==="; cat "$CSV"

# --- min / median / max per (bp,mode) + degrade count, using sort -n (mawk-safe) ---
stat(){  # $1=bp $2=mode  -> prints "min median max n degraded"
  local bp="$1" md="$2"
  local vals=$(awk -F, -v b="$bp" -v m="$md" '$2==b && $3==m && $5!="NA"{print $5}' "$CSV" | sort -n)
  [ -z "$vals" ] && { echo "(no data)"; return; }
  echo "$vals" | awk '{a[NR]=$1} END{
    n=NR; mn=a[1]; mx=a[n];
    med=(n%2)? a[(n+1)/2] : (a[n/2]+a[n/2+1])/2;
    printf "min=%.4f median=%.4f max=%.4f n=%d", mn, med, mx, n }'
  local deg=$(awk -F, -v b="$bp" -v m="$md" '$2==b && $3==m{s+=$12} END{print s+0}' "$CSV")
  printf " degraded=%s\n" "$deg"
}
echo ""; echo "=== SUMMARY (latency s) ==="
printf "64M mode0 (vanilla walk) : "; stat 64M 0
printf "64M mode1 (serve, headline): "; stat 64M 1
printf "4G  mode0 (vanilla walk) : "; stat 4G 0
printf "4G  mode1 (serve)        : "; stat 4G 1
echo ""
echo "ratio(64M) = median(64M m0) / median(64M m1) ; ratio(4G) likewise. construct_BAD must be 0 in every row."
echo "=== DONE ==="; date
