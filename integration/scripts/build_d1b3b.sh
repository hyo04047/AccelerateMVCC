#!/usr/bin/env bash
# Stage D-1b-3b: drainer does the real single-consumer insert into the AccelerateMVCC index.
# (1) re-verify 20 correctness tests (ctor gained a kuku_log2 param, default unchanged).
# (2) rebuild mysqld + churn: chains must actually populate (live_epoch_buckets>0), drained==enq.
set +e
exec > /mnt/c/Users/USER/build_d1b3b.log 2>&1
REPO="/mnt/c/Users/USER/projects/AccelerateMVCC"; SRCREPO="$REPO/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
FILTER='MvccVisibility.*:GcDeadzone.*:GcEndToEnd.*:GcEbrIntegration.*:GcSharedDescriptor.*:GcRetireOnce.*:GcBackstopDrain.*:GcFgUnlink.*:GcScale.*'
JOBS=$(nproc)

echo "=== (1) correctness regression (Release, ctor change) ==="
cmake -S "$REPO" -B "$HOME/acc-build" -DCMAKE_BUILD_TYPE=Release > /tmp/d1b3b_cfg.log 2>&1; echo "cfg rc=$?"
cmake --build "$HOME/acc-build" --target test_with_google -j"$JOBS" > /tmp/d1b3b_ctbuild.log 2>&1
echo "test build rc=$?"
"$HOME/acc-build/test_with_google" --gtest_filter="$FILTER" 2>&1 | grep -E '\[  (PASSED|FAILED)  \]|FAILED '

echo "=== (2) copy facade + rebuild mysqld ==="
cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
cmake --build "$BUILD" --target mysqld -j"$JOBS" > /mnt/c/Users/USER/d1b3b_build.log 2>&1
brc=$?; echo "mysqld build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== BUILD ERRORS ==="; grep -iE 'error:' /mnt/c/Users/USER/d1b3b_build.log | head -25; echo ABORT; exit 1; fi

echo "=== boot + churn (drainer now inserts for real) ==="
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" 2>&1 | tail -1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 \
  > /mnt/c/Users/USER/d1b3b_mysqld.log 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT VERSION();" || { echo NOTREADY; tail -30 /mnt/c/Users/USER/d1b3b_mysqld.log; exit 1; }
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
echo "--- churn 40s ---"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=40 --rand-type=pareto run 2>&1 | grep -E 'transactions:|queries:'
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null

echo "=== [accel] EVIDENCE (live_epoch_buckets>0 = chains populated; drained==enq) ==="
grep -E '\[accel\]' /mnt/c/Users/USER/d1b3b_mysqld.log
echo "=== DONE ==="
