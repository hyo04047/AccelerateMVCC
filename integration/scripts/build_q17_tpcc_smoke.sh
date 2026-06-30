#!/usr/bin/env bash
# ④ CH-benCHmark / TPC-C -- step 1-2 SMOKE (toolchain + coverage + correctness, NOT the latency measurement).
# Question: does the accelerator populate from + serve BYTE-CORRECTLY on the standard TPC-C dataset under the
# real TPC-C transaction mix? Loads TPC-C via sysbench-tpcc, runs the TPC-C mix (8 threads) concurrently with
# a held analytic deep scan over STOCK (the heavily-updated, in-page-eligible table) + a CUSTOMER scan (wide /
# off-page c_data -> expected ineligible). mode-2 verify-serve (walk + byte-compare): construct_BAD MUST be 0.
# Reports the consult coverage breakdown (HIT vs ineligible) so we can see which TPC-C tables the cache covers.
# 4G resident, GC off (isolate correctness from the ⑥ chain-sever). The multi-run latency harness comes next.
#
# Usage: build_q17_tpcc_smoke.sh [scale]   (default 2 warehouses). mysqld pre-built with current accel sources.
set -u
SCALE="${1:-2}"
TPCC=/root/sysbench-tpcc
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
RESULTS=/mnt/c/Users/USER/projects/AccelerateMVCC/integration/results
LOG="$RESULTS/q17_tpcc_smoke.log"; MLOG="$RESULTS/q17_tpcc_mysqld.log"; SLOG="$RESULTS/q17_tpcc_scan.log"; CHLOG="$RESULTS/q17_tpcc_churn.log"
exec > "$LOG" 2>&1
mkdir -p "$RESULTS"
cd "$TPCC"   # sysbench-tpcc's require("tpcc_common") needs the tpcc dir as cwd; all other paths here are absolute
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=tpcc"

echo "=== ④ TPC-C SMOKE (scale=$SCALE warehouses, mode-2 verify-serve, 4G resident, GC off) ==="; date
pkill -9 -x mysqld 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
ACCEL_GC=0 ACCEL_AUTHORITATIVE=2 ACCEL_KUKU_LOG2=${KUKU:-16} "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 --innodb-redo-log-capacity=8G > "$MLOG" 2>&1 &
for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
Q -e "DROP DATABASE IF EXISTS tpcc; CREATE DATABASE tpcc; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"

echo "--- loading TPC-C (scale=$SCALE) ---"
sysbench "$TPCC/tpcc.lua" $C --threads=4 --scale=$SCALE --tables=1 prepare 2>&1 | tail -3
echo "--- row counts (eligibility-relevant tables) ---"
Q -e "SELECT 'stock' t, COUNT(*) n FROM tpcc.stock1 UNION ALL SELECT 'customer', COUNT(*) FROM tpcc.customer1 UNION ALL SELECT 'order_line', COUNT(*) FROM tpcc.order_line1 UNION ALL SELECT 'orders', COUNT(*) FROM tpcc.orders1"
echo "--- is customer.c_data stored off-page? (avg length) ---"
Q -e "SELECT AVG(LENGTH(c_data)) avg_c_data_len, MAX(LENGTH(c_data)) max_len FROM tpcc.customer1"

# held analytic snapshot: warm, SLEEP(25) while TPC-C churns, then deep scans over STOCK (eligible) + CUSTOMER (wide)
( "$MYSQL" --no-defaults -uroot -S "$SOCK" tpcc <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET profiling=1; SET profiling_history_size=50;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT 'scan_warm' tag, SUM(s_quantity) s FROM stock1;
SELECT SLEEP(25);
SELECT 'scan_deep_stock' tag, SUM(s_quantity+s_ytd+s_order_cnt+s_remote_cnt) s FROM stock1;
SELECT 'scan_deep_cust'  tag, SUM(c_balance+c_ytd_payment) s FROM customer1;
SELECT 'scan_deep_oline' tag, SUM(ol_amount+ol_quantity) s FROM order_line1;
COMMIT;
SELECT '=== PROFILES ==='; SHOW PROFILES;
SQL
) > "$SLOG" 2>&1 &
SNAP=$!
sleep 2
echo "--- running TPC-C mix (8 threads, 50s) concurrent with the held scans ---"
sysbench "$TPCC/tpcc.lua" $C --threads=8 --time=50 --scale=$SCALE --tables=1 run > "$CHLOG" 2>&1 &
CH=$!
wait $SNAP
kill $CH 2>/dev/null; wait $CH 2>/dev/null
Q -e "SHOW ENGINE INNODB STATUS\G" | grep -i 'History list length'
Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -x mysqld 2>/dev/null

echo ""; echo "--- held-scan SUMs + per-scan latency (Duration) ---"
grep -E 'scan_(warm|deep)' "$SLOG" | grep -viE 'profiles|select'
grep -A60 'PROFILES' "$SLOG" | grep -E 'scan_warm|scan_deep'
echo ""; echo "--- TPC-C churn tps ---"; grep -E 'transactions:' "$CHLOG"
echo ""; echo "--- [accel] coverage + correctness (consult breakdown; ineligible = wide/off-page rows -> vanilla) ---"
grep -E '\[accel\] consult:' "$MLOG" | tail -2
echo "--- [accel] drained (populate from TPC-C churn) ---"
grep -E '\[accel\].*(drained|enq)' "$MLOG" | tail -2
echo ""; echo "GATE: construct_BAD must be 0. Expect HITs on stock/order_line (eligible), ineligible on customer (wide c_data)."
echo "=== DONE ==="; date
