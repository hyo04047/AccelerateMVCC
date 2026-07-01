#!/usr/bin/env bash
# Crossover: where does GC-on serve stop winning for the delete+reinsert (oltp_write_only) workload?
# Anchors already known: 256M works (~3.3x, HIT 99.8%), 64M breaks (HIT 0-65%). Fill 128M and 96M.
# GC on, drain-cap 500 (the more-stable cap), mode0 vanilla baseline vs mode1 serve, N per BP.
set -u
N="${1:-3}"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
RESULTS=/mnt/c/Users/USER/projects/AccelerateMVCC/integration/results
CSV="$RESULTS/q5g_bpcross.csv"; LOG="$RESULTS/q5g_bpcross_run.log"
exec > "$LOG" 2>&1
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
RDS(){ Q -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
mkdir -p "$RESULTS"
echo "iter,bp,mode,cap,deep1_lat_s,phys_reads,hit,hit_pct,noncontig,construct_BAD,served" > "$CSV"

run_one(){  # $1=BP $2=mode $3=iter
  local BP="$1" MODE="$2" iter="$3" CAP=500; local tag="bp${BP}_m${MODE}_i${iter}"
  local MLOG="$RESULTS/q5gx_${tag}_mysqld.log"; local SLOG="$RESULTS/q5gx_${tag}_scan.log"
  echo ""; echo "########## $tag ##########"
  pkill -9 -x mysqld 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=$MODE ACCEL_GC=1 ACCEL_DRAIN_CAP=$CAP "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
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
COMMIT;
SELECT '=== PROFILES ==='; SHOW PROFILES;
SQL
  ) > "$SLOG" 2>&1 &
  local SNAP=$!; sleep 2
  sysbench oltp_write_only $C --tables=1 --table-size=1000 --threads=8 --time=44 --rand-type=pareto run > "$RESULTS/q5gx_${tag}_churn.log" 2>&1 &
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
  echo "$iter,$BP,$MODE,$CAP,$LAT,$PHYS,$HIT,$HP,$NC,$BAD,$SRV" >> "$CSV"
  echo ">> $tag : deep1=${LAT}s phys=$PHYS HIT%=$HP noncontig=$NC construct_BAD=$BAD served=$SRV"
}

echo "=== q5 GC-ON BP crossover (128M, 96M; oltp_write_only, cap 500). N=$N ==="; date
for BP in 128M 96M; do
  for i in $(seq 1 $N); do run_one $BP 0 $i; done
  for i in $(seq 1 $N); do run_one $BP 1 $i; done
done
echo ""; echo "=== RAW CSV ==="; cat "$CSV"
stat(){ local b="$1" m="$2"; local v=$(awk -F, -v b="$b" -v m="$m" '$2==b && $3==m && $5!="NA"{print $5}' "$CSV" | sort -n)
  [ -z "$v" ] && { echo "(no data)"; return; }
  echo "$v" | awk '{a[NR]=$1} END{n=NR; med=(n%2)?a[(n+1)/2]:(a[n/2]+a[n/2+1])/2; printf "median=%.4f n=%d",med,n}'
  local hp=$(awk -F, -v b="$b" -v m="$m" '$2==b && $3==m{s+=$8;n++} END{printf "%.0f",(n?s/n:0)}' "$CSV")
  local bad=$(awk -F, -v b="$b" -v m="$m" '$2==b && $3==m{s+=$10} END{print s+0}' "$CSV"); printf " avg_HIT%%=%s construct_BAD=%s\n" "$hp" "$bad"; }
echo ""; echo "=== SUMMARY (GC on, cap 500) ==="
for BP in 128M 96M; do
  printf "BP=%-5s mode0 : " "$BP"; stat $BP 0
  printf "BP=%-5s mode1 : " "$BP"; stat $BP 1
  m0=$(awk -F, -v b="$BP" '$2==b && $3==0 && $5!="NA"{print $5}' "$CSV" | sort -n | awk '{a[NR]=$1}END{n=NR;print (n%2)?a[(n+1)/2]:(a[n/2]+a[n/2+1])/2}')
  m1=$(awk -F, -v b="$BP" '$2==b && $3==1 && $5!="NA"{print $5}' "$CSV" | sort -n | awk '{a[NR]=$1}END{n=NR;print (n%2)?a[(n+1)/2]:(a[n/2]+a[n/2+1])/2}')
  awk -v a="$m0" -v b="$m1" -v bp="$BP" 'BEGIN{if(b>0) printf "  -> BP=%s speedup = %.1fx\n", bp, a/b}'
done
echo "Anchors: 256M ~3.3x HIT99.8 (works), 64M 1.3-2.3x HIT0-88 (breaks). Crossover between."
echo "=== DONE ==="; date
