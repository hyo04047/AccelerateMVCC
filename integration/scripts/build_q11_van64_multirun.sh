#!/usr/bin/env bash
# Phase 3 §3b: strengthen the ⑥ headline denominator. The 64M serve arm is already N=8 (median 0.454s,
# gate ①); the 64M VANILLA baseline was only N=3 (median 132.1s, 102-133 spread). Re-measure 64M vanilla
# (mode 0 walk) at N=6 with the same q11 ship config (GC on, drain-cap 1000, churn-paused held deep read)
# so the 290x = median(vanilla)/median(serve) has a firmer numerator. Raw logs + CSV -> results/ (gate ②).
# Usage: build_q11_van64_multirun.sh [N]  (default 6). mysqld must be pre-built.
set -u
N="${1:-6}"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
RESULTS=/mnt/c/Users/USER/projects/AccelerateMVCC/integration/results
CSV="$RESULTS/q11_van64.csv"; LOG="$RESULTS/q11_van64_run.log"
exec > "$LOG" 2>&1
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
RDS(){ Q -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
mkdir -p "$RESULTS"
echo "iter,bp,mode,deep1_lat_s,phys_reads" > "$CSV"

run_one(){  # $1=iter
  local iter="$1"; local tag="bp64M_m0_i${iter}"
  local MLOG="$RESULTS/q11v_${tag}_mysqld.log"; local SLOG="$RESULTS/q11v_${tag}_scan.log"
  echo ""; echo "########## $tag (N=$N) ##########"
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=0 ACCEL_GC=1 ACCEL_DRAIN_CAP=1000 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=64M --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
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
COMMIT;
SELECT '=== PROFILES ==='; SHOW PROFILES;
SQL
  ) > "$SLOG" 2>&1 &
  local SNAP=$!
  sleep 2
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=44 --rand-type=pareto run > "$RESULTS/q11v_${tag}_churn.log" 2>&1 &
  local CH=$!
  wait $CH; local R1=$(RDS); wait $SNAP; local R2=$(RDS)
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  local LAT=$(grep -A60 'PROFILES' "$SLOG" | awk '/scan_deep1/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/){print $i; exit}}')
  [ -z "$LAT" ] && LAT="NA"; local PHYS=$((R2-R1))
  echo "$iter,64M,0,$LAT,$PHYS" >> "$CSV"
  echo ">> $tag : deep1_lat=${LAT}s phys=$PHYS"
}

echo "=== ⑥ 64M VANILLA baseline N=$N (q11 ship config, GC on) ==="; date
for i in $(seq 1 $N); do run_one $i; done
echo ""; echo "=== RAW CSV ==="; cat "$CSV"
vals=$(awk -F, '$3==0 && $4!="NA"{print $4}' "$CSV" | sort -n)
echo ""; echo "=== SUMMARY (64M vanilla deep read latency) ==="
echo "$vals" | awk '{a[NR]=$1} END{n=NR; mn=a[1]; mx=a[n]; med=(n%2)?a[(n+1)/2]:(a[n/2]+a[n/2+1])/2; printf "min=%.3f median=%.3f max=%.3f n=%d\n",mn,med,mx,n}'
echo "Prior N=3 median 132.1s (102-133). Serve N=8 median 0.454s -> 290x = median(vanilla)/0.454."
echo "=== DONE ==="; date
