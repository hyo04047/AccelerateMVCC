#!/usr/bin/env bash
# ④ CH-benCHmark / TPC-C -- step 3b LATENCY (serve speedup on a held analytic query over the standard TPC-C
# dataset, at adequate cache sizing). Companion to build_q17_tpcc_smoke.sh (which established TPC-C serve
# correctness construct_BAD=0 + the D8 coverage-vs-sizing curve: HIT 16%@kuku16 -> 64%@kuku21). Here we run a
# held REPEATABLE-READ snapshot doing a deep aggregation over STOCK (the heavily-churned, in-page-eligible
# table) while the TPC-C mix churns, mode 0 (vanilla walk) vs mode 1 (serve), BP sweep, N runs -> per-BP
# speedup = median(m0)/median(m1). kuku_log2=21 (covers scale=2's ~920k working set). GC off (isolate from
# the ⑥ chain-sever). To avoid reloading TPC-C every run (~1.5 min each), the dataset is loaded ONCE into a
# pristine datadir and each run restores a fresh copy (~seconds) -> every run starts from the same state.
#
# Usage: build_q17_tpcc_latency.sh [N] [scale] [kuku_log2]   (defaults: N=3, scale=2, kuku=21).
set -u
N="${1:-3}"; SCALE="${2:-2}"; KUKU="${3:-21}"
TPCC=/root/sysbench-tpcc
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; PRISTINE="$HOME/tpcc-pristine-data"
SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
RESULTS=/mnt/c/Users/USER/projects/AccelerateMVCC/integration/results
CSV="$RESULTS/q17_tpcc_latency.csv"; LOG="$RESULTS/q17_tpcc_latency_run.log"
exec > "$LOG" 2>&1
mkdir -p "$RESULTS"; cd "$TPCC"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
RDS(){ Q -N -e "SELECT VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Innodb_buffer_pool_reads'"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=tpcc"

echo "=== ④ TPC-C LATENCY (scale=$SCALE, kuku_log2=$KUKU, GC off): held STOCK deep read, vanilla vs serve, BP sweep. N=$N ==="; date

# ---- phase 0: load TPC-C ONCE into a pristine datadir, clean shutdown, keep a copy to restore per run ----
echo "--- loading pristine TPC-C (scale=$SCALE) once ---"
pkill -9 -x mysqld 2>/dev/null; sleep 2; rm -rf "$DATA" "$PRISTINE"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 --innodb-redo-log-capacity=8G >/dev/null 2>&1 &
for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
Q -e "DROP DATABASE IF EXISTS tpcc; CREATE DATABASE tpcc; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench "$TPCC/tpcc.lua" $C --threads=4 --scale=$SCALE --tables=1 prepare 2>&1 | tail -1
Q -e "SELECT CONCAT('pristine stock rows=', COUNT(*)) FROM tpcc.stock1"
Q -e "SHUTDOWN;" 2>/dev/null; sleep 5; pkill -9 -x mysqld 2>/dev/null; sleep 1
cp -a "$DATA" "$PRISTINE"; echo "pristine snapshot saved ($(du -sh "$PRISTINE" | cut -f1))"

echo "iter,bp,mode,deep_stock_lat_s,deep_oline_lat_s,phys_reads,consult_calls,hit,hit_pct,construct_BAD,served,hll" > "$CSV"

run_one(){  # $1=BP  $2=mode  $3=iter
  local BP="$1" MODE="$2" iter="$3"; local tag="bp${BP}_m${MODE}_i${iter}"
  local MLOG="$RESULTS/q17lat_${tag}_mysqld.log"; local SLOG="$RESULTS/q17lat_${tag}_scan.log"
  echo ""; echo "########## $tag (kuku=$KUKU, N=$N) ##########"
  pkill -9 -x mysqld 2>/dev/null; sleep 2; rm -rf "$DATA"; cp -a "$PRISTINE" "$DATA"   # restore fresh TPC-C
  ACCEL_GC=0 ACCEL_AUTHORITATIVE=$MODE ACCEL_KUKU_LOG2=$KUKU "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=$BP --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 --innodb-redo-log-capacity=8G > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  # held analytic snapshot: warm STOCK, SLEEP(25) while TPC-C churns, then deep STOCK + ORDER_LINE scans
  ( "$MYSQL" --no-defaults -uroot -S "$SOCK" tpcc <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET profiling=1; SET profiling_history_size=50;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT 'scan_warm' tag, SUM(s_quantity) s FROM stock1;
SELECT SLEEP(25);
SELECT 'scan_deep_stock' tag, SUM(s_quantity+s_ytd+s_order_cnt+s_remote_cnt) s FROM stock1;
SELECT 'scan_deep_oline' tag, SUM(ol_amount+ol_quantity) s FROM order_line1;
COMMIT;
SELECT '=== PROFILES ==='; SHOW PROFILES;
SQL
  ) > "$SLOG" 2>&1 &
  local SNAP=$!
  sleep 2
  sysbench "$TPCC/tpcc.lua" $C --threads=8 --time=50 --scale=$SCALE --tables=1 run > "$RESULTS/q17lat_${tag}_churn.log" 2>&1 &
  local CH=$!
  local R1=$(RDS)
  wait $SNAP
  local R2=$(RDS)
  local HLL=$(Q -e "SHOW ENGINE INNODB STATUS\G" | grep -i 'History list length' | grep -oE '[0-9]+' | head -1)
  kill $CH 2>/dev/null; wait $CH 2>/dev/null
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -x mysqld 2>/dev/null
  local LS=$(grep -A60 'PROFILES' "$SLOG" | awk '/scan_deep_stock/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/){print $i; exit}}')
  local LO=$(grep -A60 'PROFILES' "$SLOG" | awk '/scan_deep_oline/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+$/){print $i; exit}}')
  [ -z "$LS" ] && LS="NA"; [ -z "$LO" ] && LO="NA"
  local PHYS=$((R2-R1))
  local CONS=$(grep -E '\[accel\] consult:' "$MLOG" | tail -1)
  local CALLS=$(echo "$CONS" | grep -oE 'calls=[0-9]+'        | grep -oE '[0-9]+')
  local HIT=$(echo "$CONS"   | grep -oE 'hit=[0-9]+'          | grep -oE '[0-9]+')
  local BAD=$(echo "$CONS"   | grep -oE 'construct_BAD=[0-9]+'| grep -oE '[0-9]+')
  local SRV=$(echo "$CONS"   | grep -oE 'served=[0-9]+'       | grep -oE '[0-9]+')
  : "${CALLS:=NA}" "${HIT:=NA}" "${BAD:=NA}" "${SRV:=NA}" "${HLL:=NA}"
  local HITPCT="NA"
  if [ "$HIT" != "NA" ] && [ "$CALLS" != "NA" ]; then
    if [ "$CALLS" -gt 0 ] 2>/dev/null; then HITPCT=$(awk "BEGIN{printf \"%.1f\", 100*$HIT/$CALLS}"); fi
  fi
  echo "$iter,$BP,$MODE,$LS,$LO,$PHYS,$CALLS,$HIT,$HITPCT,$BAD,$SRV,$HLL" >> "$CSV"
  printf ">> %s | deep_stock=%-10s deep_oline=%-10s phys=%-8s HIT%%=%-6s construct_BAD=%-3s served=%-8s\n" "$tag" "${LS}s" "${LO}s" "$PHYS" "$HITPCT" "$BAD" "$SRV"
}

for BP in 4G 64M; do
  for i in $(seq 1 $N); do run_one $BP 0 $i; done
  for i in $(seq 1 $N); do run_one $BP 1 $i; done
done
rm -rf "$PRISTINE"

echo ""; echo "=== RAW CSV ($CSV) ==="; cat "$CSV"
med(){ local bp="$1" md="$2"; local v=$(awk -F, -v b="$bp" -v m="$md" '$2==b && $3==m && $4!="NA"{print $4}' "$CSV" | sort -n); [ -z "$v" ] && { echo NA; return; }; echo "$v" | awk '{a[NR]=$1} END{n=NR; printf "%.6f", (n%2)?a[(n+1)/2]:(a[n/2]+a[n/2+1])/2}'; }
statline(){ local bp="$1" md="$2"; local v=$(awk -F, -v b="$bp" -v m="$md" '$2==b && $3==m && $4!="NA"{print $4}' "$CSV" | sort -n); [ -z "$v" ] && { echo "(no data)"; return; }; echo "$v" | awk '{a[NR]=$1} END{n=NR; printf "min=%.4f median=%.4f max=%.4f n=%d", a[1], (n%2)?a[(n+1)/2]:(a[n/2]+a[n/2+1])/2, a[n], n}'; local bad=$(awk -F, -v b="$bp" -v m="$md" '$2==b && $3==m{s+=$10} END{print s+0}' "$CSV"); printf " construct_BAD_total=%s\n" "$bad"; }
echo ""; echo "=== SUMMARY (deep STOCK latency s; speedup = median(m0)/median(m1)) ==="
for BP in 4G 64M; do
  printf "BP=%-4s mode0 (vanilla): "; statline $BP 0
  printf "BP=%-4s mode1 (serve)  : "; statline $BP 1
  m0=$(med $BP 0); m1=$(med $BP 1)
  if [ "$m0" != "NA" ] && [ "$m1" != "NA" ]; then awk -v a="$m0" -v b="$m1" -v bp="$BP" 'BEGIN{ if(b>0) printf "  -> BP=%s speedup = %.4f / %.4f = %.1fx\n\n", bp, a, b, a/b }'; fi
done
echo "Note: TPC-C HIT ~64% (kuku=$KUKU) so the serve speedup is coverage-diluted vs sbtest ~100% (honest)."
echo "=== DONE ==="; date
