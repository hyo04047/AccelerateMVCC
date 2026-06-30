#!/usr/bin/env bash
# Phase 3 gate ① (error bars) for the ⓠ3 in-middle MEMORY ratio -- the ⑤ deadzone headline: the cache's
# live_versions stays BOUNDED (deadzone GC) while InnoDB's History List Length grows ~linearly with the LLT
# window, so the ratio grows ~linearly with LLT age (single-run was 20/40/63x @ 15/30/60s). Re-runs the
# build_q3_realistic.sh config (realistic full-table: table-size=1000, pareto, 256M BP, GC on + retention
# reporter, 8 HTAP readers + a held LLT) N times per LLT duration -> ratio median + min/max. A readers=0
# CONTROL (no HTAP gap -> no in-middle reclaim -> ratio ~1x) anchors that the win is entirely the gap.
# Raw mysqld logs + CSV land in integration/results/ (gate ②). docs/phase2-q3-llt.md.
# mysqld must be pre-built with the retention reporter compiled into accel_hook.cc (current accel sources).
#
# Usage: build_q3_multirun.sh [N]   (default 5).
set -u
N="${1:-5}"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
RESULTS=/mnt/c/Users/USER/projects/AccelerateMVCC/integration/results
CSV="$RESULTS/q3_realistic.csv"
LOG="$RESULTS/q3_realistic_run.log"
exec > "$LOG" 2>&1
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

mkdir -p "$RESULTS"
echo "iter,llt_s,readers,innodb_hll,cache_live_versions,ratio,chain_max" > "$CSV"

run_one(){  # $1=llt_dur  $2=readers  $3=iter
  local dur="$1" rdr="$2" iter="$3"; local tag="llt${dur}_r${rdr}_i${iter}"
  local MLOG="$RESULTS/q3_${tag}_mysqld.log"
  echo ""; echo "########## $tag (N=$N) ##########"
  pkill -9 -x mysqld 2>/dev/null; sleep 3; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_GC=1 ACCEL_RETENTION_MS=1000 ACCEL_RETENTION_CAP=2000 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=256M --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  Q -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare >/dev/null 2>&1
  # held LLT: pins the purge floor (low begin id) so the in-middle gap above it can form
  ( "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest <<SQL
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT SUM(k+LENGTH(c)) FROM sbtest1;
SELECT SLEEP($((dur+4)));
COMMIT;
SQL
  ) > /dev/null 2>&1 &
  local SNAP=$!
  sleep 2
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=$dur --rand-type=pareto run >/dev/null 2>&1 &
  local CH=$!
  local RD=""
  if [ "$rdr" -gt 0 ]; then   # HTAP readers hold high-begin-id read views = the upper edge of the in-middle gap
    sysbench oltp_read_only $C --tables=1 --table-size=1000 --threads=$rdr --time=$dur --rand-type=pareto --skip-trx=off run >/dev/null 2>&1 &
    RD=$!
  fi
  sleep $((dur-2))
  local HLL=$(Q -e "SHOW ENGINE INNODB STATUS\G" | grep -i 'History list length' | grep -oE '[0-9]+' | head -1)
  wait $CH; [ -n "$RD" ] && wait $RD; wait $SNAP
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 5; pkill -9 -x mysqld 2>/dev/null; sleep 1
  # peak over the run: chain max= and live_versions= from the retention reporter lines
  local PEAK=$(grep -E '\[accel\] retention:' "$MLOG" | awk '{for(i=1;i<=NF;i++){if($i~/^max=/){v=substr($i,5)+0;if(v>mx)mx=v} if($i~/^live_versions=/){l=substr($i,15)+0;if(l>ml)ml=l}}} END{printf "%d %d",mx,ml}')
  local CMAX=$(echo $PEAK | awk '{print $1}'); local LIVEV=$(echo $PEAK | awk '{print $2}')
  : "${HLL:=NA}"; [ -z "$LIVEV" ] && LIVEV=NA; [ -z "$CMAX" ] && CMAX=NA
  local RATIO="NA"
  if [ "$LIVEV" != "NA" ] && [ "$HLL" != "NA" ]; then
    if [ "$LIVEV" -gt 0 ] 2>/dev/null; then RATIO=$(awk "BEGIN{printf \"%.1f\", $HLL/$LIVEV}"); fi
  fi
  echo "$iter,$dur,$rdr,$HLL,$LIVEV,$RATIO,$CMAX" >> "$CSV"
  printf ">> %s | InnoDB_HLL=%-9s cache_live_versions=%-9s RATIO=%-6s chain=%-6s\n" "$tag" "$HLL" "$LIVEV" "${RATIO}x" "$CMAX"
}

echo "=== ⓠ3 REALISTIC MULTI-RUN (table-size=1000, pareto, 256M BP, GC on): ratio = InnoDB HLL / cache live_versions. N=$N ==="
date
for i in $(seq 1 2);  do run_one 30 0 $i; done                       # readers=0 control (no gap -> ratio ~1x)
for dur in 15 30 60; do for i in $(seq 1 $N); do run_one $dur 8 $i; done; done

echo ""; echo "=== RAW CSV ($CSV) ==="; cat "$CSV"

stat(){  # $1=llt $2=rdr  -> over ratio column (field 6)
  local d="$1" r="$2"
  local vals=$(awk -F, -v d="$d" -v r="$r" '$2==d && $3==r && $6!="NA"{print $6}' "$CSV" | sort -n)
  [ -z "$vals" ] && { echo "(no data)"; return; }
  echo "$vals" | awk '{a[NR]=$1} END{ n=NR; mn=a[1]; mx=a[n]; med=(n%2)? a[(n+1)/2] : (a[n/2]+a[n/2+1])/2; printf "min=%.1f median=%.1f max=%.1f n=%d\n", mn, med, mx, n }'
}
echo ""; echo "=== SUMMARY (ratio = InnoDB HLL / cache live_versions) ==="
printf "control llt=30 rdr=0 (no gap) : "; stat 30 0
printf "headline llt=15 rdr=8         : "; stat 15 8
printf "headline llt=30 rdr=8         : "; stat 30 8
printf "headline llt=60 rdr=8         : "; stat 60 8
echo ""
echo "Expect: control ~1x (no in-middle reclaim); headline ratio grows ~linearly with LLT (was 20/40/63x single-run)."
echo "cache live_versions should stay bounded (~6-9k) across LLT durations; HLL grows linearly with dur."
echo "=== DONE ==="; date
