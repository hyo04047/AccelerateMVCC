#!/usr/bin/env bash
# Stage D-1b-2b: wire the MPMC ring + off-latch drainer + lifecycle into mysqld. Hook enqueues;
# drainer pops+counts (no real insert yet). Verify drainer runs, drained==enq, clean shutdown.
exec > /mnt/c/Users/USER/build_d1b2b.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; TRX="$INNO/trx/trx0rec.cc"; SRVS="$INNO/srv/srv0start.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"

echo "=== copy facade + ring into MySQL tree ==="
cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"

echo "=== ensure prior patches (CMakeLists src, trx0rec include+call) [idempotent] ==="
grep -q 'accel/accel_hook.cc' "$INNO/CMakeLists.txt" || sed -i 's#^  trx/trx0rec.cc#  trx/trx0rec.cc\n  accel/accel_hook.cc#' "$INNO/CMakeLists.txt"
grep -q 'accel_hook.h' "$TRX" || echo "WARN trx0rec include missing"

echo "=== patch srv0start.cc (include + accel_init + accel_shutdown) [idempotent] ==="
grep -q 'accel_hook.h' "$SRVS" || sed -i '/#include "srv0start.h"/a #include "accel_hook.h"' "$SRVS"
grep -q 'accel_init();' "$SRVS" || sed -i '/ulonglong{log_get_lsn/a\  accel_init();' "$SRVS"
grep -q 'accel_shutdown();' "$SRVS" || sed -i '/^void srv_shutdown() {/a\  accel_shutdown();' "$SRVS"
echo "--- srv0start.cc hooks: ---"; grep -n 'accel_hook.h\|accel_init();\|accel_shutdown();' "$SRVS"

echo "=== incremental build (mysqld) ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d1b2b_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== BUILD ERRORS ==="; grep -iE 'error:' /mnt/c/Users/USER/d1b2b_build.log | head -30; echo ABORT; exit 1; fi

echo "=== start mysqld (expect [accel] init) + multi-conn churn ==="
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" 2>&1 | tail -1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 \
  > /mnt/c/Users/USER/d1b2b_mysqld.log 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT VERSION();" || { echo NOTREADY; tail -30 /mnt/c/Users/USER/d1b2b_mysqld.log; exit 1; }
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
echo "--- churn 60s (8 threads, different rows -> concurrent producers) ---"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=60 --rand-type=pareto run 2>&1 | grep -E 'transactions:|queries:'
echo "--- shutdown (expect [accel] shutdown with drained==enq) ---"
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null

echo "=== [accel] EVIDENCE (init / drained / shutdown) ==="
grep -E '\[accel\]' /mnt/c/Users/USER/d1b2b_mysqld.log
echo "=== DONE ==="
