#!/usr/bin/env bash
# Phase 3 gate ① (error bars) for the CONCURRENT-HTAP ⑥/⑤ regime (DoD literal config).
# Unlike q11 (which does `wait $CH` so churn is PAUSED before the deep scan), here the held-snapshot deep
# analytic scans run WHILE the OLTP churn is still active -- so GC reclaim runs continuously during the
# read and the chain-sever risk fires live, not as one post-hoc storm. Re-runs each config N times at the
# SHIP setting (GC on, ACCEL_DRAIN_CAP=1000) and captures per-run deep-scan latency -> median + min/max +
# a degrade rate. mode 0 = vanilla walk baseline; mode 1 = serve-only (headline); mode 2 = verify-serve
# (walk+byte-compare, construct_BAD=0 correctness gate under concurrency). deep1 is the headline metric
# (fully concurrent with churn for the fast serve path). Physical-read delta is confounded by concurrent
# churn so it is NOT recorded; latency (SHOW PROFILES Duration, clean per-stmt under load) is. Raw per-run
# mysqld/scan/churn logs + a CSV land in integration/results/ (gate ②). See build_q11_d6_multirun.sh for
# the churn-paused variant. docs/phase2-q3-llt.md, design-D5-gc §12/§13.2.
#
# Usage: build_q15_multirun.sh [N_serve_64M]   (default 8). mysqld must be pre-built (current accel sources).
set -u
N="${1:-8}"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
RESULTS=/mnt/c/Users/USER/projects/AccelerateMVCC/integration/results
CSV="$RESULTS/q15_concurrent.csv"
LOG="$RESULTS/q15_concurrent_run.log"
exec > "$LOG" 2>&1
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

mkdir -p "$RESULTS"
echo "iter,bp,mode,cap,deep1_lat_s,deep2_lat_s,deep3_lat_s,churn_tps,consult_calls,hit,noncontig,construct_BAD,served,degraded" > "$CSV"

# one fresh-boot run with deep scans CONCURRENT to churn -> appends one CSV row
run_one(){
  local BP="$1" MODE="$2" iter="$3" CAP="$4"
  local tag="bp${BP}_m${MODE}_cap${CAP}_i${iter}"
  local MLOG="$RESULTS/q15_${tag}_mysqld.log"
  local SLOG="$RESULTS/q15_${tag}_scan.log"
  local CHLOG="$RESULTS/q15_${tag}_churn.log"
  echo ""; echo "########## $tag (N=$N) -- deep scans CONCURRENT with churn ##########"
  pkill -9 -x mysqld 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_GC=1 ACCEL_AUTHORITATIVE=$MODE ACCEL_DRAIN_CAP=$CAP "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=$BP --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 --innodb-redo-log-capacity=8G > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  Q -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare >/dev/null 2>&1
  Q -e "SELECT COUNT(*) FROM sbtest.sbtest1" >/dev/null
  # snapshot session: warm scan, SLEEP(25) while churn deepens chains, then 3 deep scans that run WHILE
  # churn is STILL ACTIVE (churn runs 50s; deep1 lands ~t27). No `wait $CH` before the scans.
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
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=50 --rand-type=pareto run > "$CHLOG" 2>&1 &
  local CH=$!
  wait $SNAP                      # deep scans complete (churn STILL running underneath the early ones)
  kill $CH 2>/dev/null; wait $CH 2>/dev/null
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -x mysqld 2>/dev/null

  # latency: first float on each scan_deepN line under PROFILES (= Duration; Query_ID and SUM are ints)
  local LAT1=$(grep -A60 'PROFILES' "$SLOG" | awk '/scan_deep1/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/){print $i; exit}}')
  local LAT2=$(grep -A60 'PROFILES' "$SLOG" | awk '/scan_deep2/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/){print $i; exit}}')
  local LAT3=$(grep -A60 'PROFILES' "$SLOG" | awk '/scan_deep3/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/){print $i; exit}}')
  [ -z "$LAT1" ] && LAT1="NA"; [ -z "$LAT2" ] && LAT2="NA"; [ -z "$LAT3" ] && LAT3="NA"
  local TPS=$(grep -E 'transactions:' "$CHLOG" | grep -oE '\([0-9.]+ per' | grep -oE '[0-9.]+' | head -1)
  : "${TPS:=NA}"
  local CONS=$(grep -E '\[accel\] consult:' "$MLOG" | tail -1)
  local CALLS=$(echo "$CONS" | grep -oE 'calls=[0-9]+'        | grep -oE '[0-9]+')
  local HIT=$(echo "$CONS"   | grep -oE 'hit=[0-9]+'          | grep -oE '[0-9]+')
  local NC=$(echo "$CONS"    | grep -oE 'noncontig=[0-9]+'    | grep -oE '[0-9]+')
  local BAD=$(echo "$CONS"   | grep -oE 'construct_BAD=[0-9]+'| grep -oE '[0-9]+')
  local SRV=$(echo "$CONS"   | grep -oE 'served=[0-9]+'       | grep -oE '[0-9]+')
  : "${CALLS:=NA}" "${HIT:=NA}" "${NC:=NA}" "${BAD:=NA}" "${SRV:=NA}"
  # degrade flag (only meaningful for mode-1 serve): a serve run whose deep1 took the slow walk (>2s)
  local DEG=0
  if [ "$LAT1" != "NA" ]; then DEG=$(awk -v l="$LAT1" 'BEGIN{print (l>2.0)?1:0}'); fi
  echo "$iter,$BP,$MODE,$CAP,$LAT1,$LAT2,$LAT3,$TPS,$CALLS,$HIT,$NC,$BAD,$SRV,$DEG" >> "$CSV"
  echo ">> $tag : deep1=${LAT1}s deep2=${LAT2}s deep3=${LAT3}s tps=$TPS hit=$HIT noncontig=$NC construct_BAD=$BAD served=$SRV degraded=$DEG"
  echo "   consult: $CONS"
  echo "   scan SUMs (snapshot invariant, should be identical within a run):"; grep -E "scan_(warm|deep[0-9])\b" "$SLOG" | grep -vi 'profiles\|select'
}

echo "=== q15 CONCURRENT-HTAP MULTI-RUN (deep scans WHILE churn active; GC on; ship setting). N(serve,64M)=$N ==="
date
for i in $(seq 1 3);  do run_one 64M 0 $i 1000; done   # vanilla walk baseline (concurrent)
for i in $(seq 1 $N); do run_one 64M 1 $i 1000; done   # serve-only headline (concurrent)
for i in $(seq 1 3);  do run_one 64M 2 $i 1000; done   # verify-serve construct_BAD=0 gate (concurrent)
for i in $(seq 1 3);  do run_one 4G  1 $i 1000; done   # large-BP serve (concurrent)

echo ""; echo "=== RAW CSV ($CSV) ==="; cat "$CSV"

# --- min / median / max per (bp,mode) + degrade + construct_BAD total, using sort -n (mawk-safe) ---
stat(){  # $1=bp $2=mode  -> prints "min median max n degraded construct_BAD_total"
  local bp="$1" md="$2"
  local vals=$(awk -F, -v b="$bp" -v m="$md" '$2==b && $3==m && $5!="NA"{print $5}' "$CSV" | sort -n)
  [ -z "$vals" ] && { echo "(no data)"; return; }
  echo "$vals" | awk '{a[NR]=$1} END{
    n=NR; mn=a[1]; mx=a[n];
    med=(n%2)? a[(n+1)/2] : (a[n/2]+a[n/2+1])/2;
    printf "min=%.4f median=%.4f max=%.4f n=%d", mn, med, mx, n }'
  local deg=$(awk -F, -v b="$bp" -v m="$md" '$2==b && $3==m{s+=$14} END{print s+0}' "$CSV")
  local bad=$(awk -F, -v b="$bp" -v m="$md" '$2==b && $3==m{s+=$12} END{print s+0}' "$CSV")
  printf " degraded=%s construct_BAD_total=%s\n" "$deg" "$bad"
}
echo ""; echo "=== SUMMARY (deep1 latency s; degraded meaningful only for mode-1) ==="
printf "64M mode0 (vanilla walk)      : "; stat 64M 0
printf "64M mode1 (serve, headline)   : "; stat 64M 1
printf "64M mode2 (verify-serve gate) : "; stat 64M 2
printf "4G  mode1 (serve)             : "; stat 4G 1
echo ""
echo "ratio(64M) = median(64M m0) / median(64M m1). construct_BAD must be 0 in EVERY row (esp. mode-2 gate)."
echo "=== DONE ==="; date
