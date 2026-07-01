#!/usr/bin/env bash
# Phase 3 Tier-3 §3b: GC-on memory bound AND serve speedup, coexisting in ONE run.
# The reviewers noted §5.3 (memory, GC on) and §5.4/§5.5 (speedup, GC off) were measured separately.
# This harness runs the ⑥ held-read serve payoff WITH the deadzone GC on AND the retention reporter on,
# so a single run reports, together: (i) held-deep-read latency (mode-1 serve vs mode-0 vanilla walk),
# (ii) the cache's bounded live_versions, and (iii) construct_BAD=0. Built on build_q11_d6_multirun.sh
# (latency) + build_q3_multirun.sh (retention reporter). Raw logs + CSV -> integration/results/ (gate ②).
#
# Usage: build_q18_gc_coexist.sh [N_serve]   (default 3). mysqld must already be built (current accel sources).
set -u
N="${1:-3}"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
RESULTS=/mnt/c/Users/USER/projects/AccelerateMVCC/integration/results
CSV="$RESULTS/q18_gc_coexist.csv"
LOG="$RESULTS/q18_gc_coexist_run.log"
exec > "$LOG" 2>&1
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
RDS(){ Q -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

mkdir -p "$RESULTS"
echo "iter,bp,mode,deep1_lat_s,phys_reads,innodb_hll,cache_live_versions,consult_calls,hit,construct_BAD,served" > "$CSV"

run_one(){
  local BP="$1" MODE="$2" iter="$3"
  local tag="bp${BP}_m${MODE}_i${iter}"
  local MLOG="$RESULTS/q18_${tag}_mysqld.log"
  local SLOG="$RESULTS/q18_${tag}_scan.log"
  echo ""; echo "########## $tag (N=$N) ##########"
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  # GC on + serve mode + retention reporter on (the coexistence knobs) + drain-cap 1000 (⑥ stabilizer)
  ACCEL_AUTHORITATIVE=$MODE ACCEL_GC=1 ACCEL_DRAIN_CAP=1000 ACCEL_RETENTION_MS=1000 ACCEL_RETENTION_CAP=2000 \
    "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
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
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=44 --rand-type=pareto run > "$RESULTS/q18_${tag}_churn.log" 2>&1 &
  local CH=$!
  # concurrent HTAP readers hold high-begin-id (recent) read views = the UPPER edge of the in-middle gap;
  # GC reclaims the gap between the old held LLT floor and these recent views -> bounded live_versions.
  sysbench oltp_read_only $C --tables=1 --table-size=1000 --threads=8 --time=44 --rand-type=pareto --skip-trx=off run > "$RESULTS/q18_${tag}_htap.log" 2>&1 &
  local RD=$!
  wait $CH; local R1=$(RDS)
  local HLL=$(Q -e "SHOW ENGINE INNODB STATUS\G" | grep -i 'History list length' | grep -oE '[0-9]+' | head -1)
  wait $RD; wait $SNAP; local R2=$(RDS)
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null

  local LAT=$(grep -A60 'PROFILES' "$SLOG" | awk '/scan_deep1/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/){print $i; exit}}')
  [ -z "$LAT" ] && LAT="NA"
  local PHYS=$((R2-R1))
  # peak live_versions over the run from the retention reporter
  local LIVEV=$(grep -E '\[accel\] retention:' "$MLOG" | awk '{for(i=1;i<=NF;i++){if($i~/^live_versions=/){l=substr($i,15)+0;if(l>ml)ml=l}}} END{print ml+0}')
  [ -z "$LIVEV" ] && LIVEV=NA
  local CONS=$(grep -E '\[accel\] consult:' "$MLOG" | tail -1)
  local CALLS=$(echo "$CONS" | grep -oE 'calls=[0-9]+'         | grep -oE '[0-9]+')
  local HIT=$(echo "$CONS"   | grep -oE 'hit=[0-9]+'           | grep -oE '[0-9]+')
  local BAD=$(echo "$CONS"   | grep -oE 'construct_BAD=[0-9]+' | grep -oE '[0-9]+')
  local SRV=$(echo "$CONS"   | grep -oE 'served=[0-9]+'        | grep -oE '[0-9]+')
  : "${HLL:=NA}" "${CALLS:=NA}" "${HIT:=NA}" "${BAD:=NA}" "${SRV:=NA}"
  echo "$iter,$BP,$MODE,$LAT,$PHYS,$HLL,$LIVEV,$CALLS,$HIT,$BAD,$SRV" >> "$CSV"
  echo ">> $tag : deep1_lat=${LAT}s phys=$PHYS HLL=$HLL live_versions=$LIVEV hit=$HIT construct_BAD=$BAD served=$SRV"
}

echo "=== ⓠ3b GC-ON COEXISTENCE (serve latency + bounded live_versions in one GC-on run). N(serve)=$N ==="
date
for i in $(seq 1 2);  do run_one 64M 0 $i; done   # 64M vanilla baseline
for i in $(seq 1 $N); do run_one 64M 1 $i; done   # 64M serve (GC on) -- headline coexistence
for i in $(seq 1 2);  do run_one 4G  0 $i; done   # 4G vanilla
for i in $(seq 1 $N); do run_one 4G  1 $i; done   # 4G serve (GC on)

echo ""; echo "=== RAW CSV ($CSV) ==="; cat "$CSV"
stat(){  # $1=bp $2=mode field=$3
  local bp="$1" md="$2" f="$3"
  local vals=$(awk -F, -v b="$bp" -v m="$md" -v f="$f" '$2==b && $3==m && $f!="NA"{print $f}' "$CSV" | sort -n)
  [ -z "$vals" ] && { echo "(no data)"; return; }
  echo "$vals" | awk '{a[NR]=$1} END{n=NR; med=(n%2)?a[(n+1)/2]:(a[n/2]+a[n/2+1])/2; printf "min=%.4f median=%.4f max=%.4f n=%d\n",a[1],med,a[n],n}'
}
echo ""; echo "=== SUMMARY ==="
printf "64M mode0 latency : "; stat 64M 0 4
printf "64M mode1 latency : "; stat 64M 1 4
printf "64M mode1 live_versions : "; stat 64M 1 7
printf "4G  mode1 latency : "; stat 4G 1 4
printf "4G  mode1 live_versions : "; stat 4G 1 7
echo ""
echo "Coexistence claim: under GC ON, mode-1 serve stays fast (median latency << mode-0 vanilla) WHILE"
echo "cache live_versions stays bounded, and construct_BAD=0 in every row."
echo "=== DONE ==="; date
