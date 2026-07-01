#!/usr/bin/env bash
# Phase 3 Tier-3 §3b: the ⓠ5 effective-speedup workload re-run with GC ON (the reviewer noted §5.4's
# effective speedup was measured GC off, so it could be a GC-off artifact). Same as build_q5_multirun.sh
# (oltp_write_only delete+reinsert churn + a single held analytic reader, BP sweep 4G/256M/64M, mode 0 walk
# vs mode 1 serve) but with ACCEL_GC=1 + ACCEL_DRAIN_CAP=1000. A single held reader is the only active view,
# so the deadzone is tail-only (no in-middle gap) and the reader's navigation chain stays intact -> serve
# should NOT chain-sever and the ~29x/~2.8x speedup should survive GC on. construct_BAD must stay 0.
# Raw logs + CSV -> integration/results/ (gate ②). docs/phase2-q3-llt.md ⓠ5.
#
# Usage: build_q5_gcon.sh [N]   (default 3). mysqld must be pre-built (current accel sources).
set -u
N="${1:-3}"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
RESULTS=/mnt/c/Users/USER/projects/AccelerateMVCC/integration/results
CSV="$RESULTS/q5_gcon.csv"
LOG="$RESULTS/q5_gcon_run.log"
exec > "$LOG" 2>&1
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
RDS(){ Q -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

mkdir -p "$RESULTS"
echo "iter,bp,mode,deep1_lat_s,phys_reads,consult_calls,hit,hit_pct,construct_BAD,served,innodb_hll" > "$CSV"

run_one(){  # $1=BP  $2=mode  $3=iter
  local BP="$1" MODE="$2" iter="$3"; local tag="bp${BP}_m${MODE}_i${iter}"
  local MLOG="$RESULTS/q5g_${tag}_mysqld.log"; local SLOG="$RESULTS/q5g_${tag}_scan.log"
  echo ""; echo "########## $tag (N=$N) ##########"
  pkill -9 -x mysqld 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=$MODE ACCEL_GC=1 ACCEL_DRAIN_CAP=1000 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
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
  sysbench oltp_write_only $C --tables=1 --table-size=1000 --threads=8 --time=44 --rand-type=pareto run > "$RESULTS/q5g_${tag}_churn.log" 2>&1 &
  local CH=$!
  wait $CH; local R1=$(RDS); wait $SNAP; local R2=$(RDS)
  local HLL=$(Q -e "SHOW ENGINE INNODB STATUS\G" | grep -i 'History list length' | grep -oE '[0-9]+' | head -1)
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -x mysqld 2>/dev/null
  local LAT=$(grep -A60 'PROFILES' "$SLOG" | awk '/scan_deep1/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/){print $i; exit}}')
  [ -z "$LAT" ] && LAT="NA"
  local PHYS=$((R2-R1))
  local CONS=$(grep -E '\[accel\] consult:' "$MLOG" | head -1)
  local CALLS=$(echo "$CONS" | grep -oE 'calls=[0-9]+' | grep -oE '[0-9]+')
  local HIT=$(echo "$CONS" | grep -oE 'hit=[0-9]+' | grep -oE '[0-9]+')
  local BAD=$(echo "$CONS" | grep -oE 'construct_BAD=[0-9]+' | grep -oE '[0-9]+')
  local SRV=$(echo "$CONS" | grep -oE 'served=[0-9]+' | grep -oE '[0-9]+')
  : "${CALLS:=NA}" "${HIT:=NA}" "${BAD:=NA}" "${SRV:=NA}" "${HLL:=NA}"
  local HITPCT="NA"
  if [ "$HIT" != "NA" ] && [ "$CALLS" != "NA" ]; then
    if [ "$CALLS" -gt 0 ] 2>/dev/null; then HITPCT=$(awk "BEGIN{printf \"%.1f\", 100*$HIT/$CALLS}"); fi
  fi
  echo "$iter,$BP,$MODE,$LAT,$PHYS,$CALLS,$HIT,$HITPCT,$BAD,$SRV,$HLL" >> "$CSV"
  printf ">> %s | deep1=%-10s phys=%-9s HIT%%=%-6s construct_BAD=%-3s served=%-8s HLL=%s\n" "$tag" "${LAT}s" "$PHYS" "$HITPCT" "$BAD" "$SRV" "$HLL"
}

echo "=== ⓠ5 effective-speedup MULTI-RUN, GC ON (drain-cap 1000): oltp_write_only churn + held deep reader. N=$N ==="
date
for BP in 4G 256M 64M; do
  for i in $(seq 1 $N); do run_one $BP 0 $i; done
  for i in $(seq 1 $N); do run_one $BP 1 $i; done
done

echo ""; echo "=== RAW CSV ($CSV) ==="; cat "$CSV"

med(){ local bp="$1" md="$2"; local vals=$(awk -F, -v b="$bp" -v m="$md" '$2==b && $3==m && $4!="NA"{print $4}' "$CSV" | sort -n)
  [ -z "$vals" ] && { echo "NA"; return; }
  echo "$vals" | awk '{a[NR]=$1} END{ n=NR; med=(n%2)? a[(n+1)/2] : (a[n/2]+a[n/2+1])/2; printf "%.6f", med }'; }
statline(){ local bp="$1" md="$2"; local vals=$(awk -F, -v b="$bp" -v m="$md" '$2==b && $3==m && $4!="NA"{print $4}' "$CSV" | sort -n)
  [ -z "$vals" ] && { echo "(no data)"; return; }
  echo "$vals" | awk '{a[NR]=$1} END{ n=NR; mn=a[1]; mx=a[n]; med=(n%2)? a[(n+1)/2] : (a[n/2]+a[n/2+1])/2; printf "min=%.4f median=%.4f max=%.4f n=%d", mn, med, mx, n }'
  local bad=$(awk -F, -v b="$bp" -v m="$md" '$2==b && $3==m{s+=$9} END{print s+0}' "$CSV"); printf " construct_BAD_total=%s\n" "$bad"; }
echo ""; echo "=== SUMMARY (deep1 latency s; speedup = median(m0)/median(m1)); GC ON ==="
for BP in 4G 256M 64M; do
  printf "BP=%-5s mode0 (vanilla): "; statline $BP 0
  printf "BP=%-5s mode1 (serve)  : "; statline $BP 1
  m0=$(med $BP 0); m1=$(med $BP 1)
  if [ "$m0" != "NA" ] && [ "$m1" != "NA" ]; then
    awk -v a="$m0" -v b="$m1" -v bp="$BP" 'BEGIN{ if(b>0) printf "  -> BP=%s speedup = %.4f / %.4f = %.1fx\n\n", bp, a, b, a/b; else print "  -> NA\n" }'
  fi
done
echo "GC ON, single held reader -> tail-only deadzone (no in-middle sever); expect speedup to survive vs the"
echo "GC-off q5 (~2.9x/2.8x/~29x @ 4G/256M/64M) with construct_BAD=0 in every row."
echo "=== DONE ==="; date
