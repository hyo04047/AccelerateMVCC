#!/usr/bin/env bash
# D-5 ⑤a-2 step 5 (review must-fix 3): memory bound under many connections. The active-view registry
# pool is now 4096 (was 256), so the overflow path -- whose conservative floor never resets -- is not
# taken at realistic connection counts. Run a connection-heavy churn (64 threads) with GC ON and check:
#   - view-registry floor=none (overflow NOT engaged: live views << pool)
#   - GC keeps reclaiming (retired total grows large), live_buckets bounded (memory not pinned/growing)
#   - construct_BAD=0 (shadow correct under GC at high concurrency), shutdown clean.
exec > /mnt/c/Users/USER/build_d5_a2s5.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
rm -f "$INNO/include/active_view_registry.h"

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d5_a2s5_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d5_a2s5_build.log | head -40; exit 1; fi

MLOG=/mnt/c/Users/USER/d5_a2s5_mysqld.log
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
ACCEL_GC=1 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --max-connections=512 --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench oltp_read_write $C --tables=4 --table-size=2000 prepare 2>&1 | tail -1
echo "=== GC ON: 64-thread oltp_read_write 30s (connection-heavy) ==="
sysbench oltp_read_write $C --tables=4 --table-size=2000 --threads=64 --time=30 --rand-type=uniform run 2>&1 | grep -E 'transactions:'
t0=$(date +%s); "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null
for i in $(seq 1 25); do pgrep -f "$MYSQLD" >/dev/null 2>&1 || break; sleep 1; done
t1=$(date +%s)
if pgrep -f "$MYSQLD" >/dev/null 2>&1; then echo "SHUTDOWN HANG"; pkill -9 -f "$MYSQLD" 2>/dev/null; else echo "shutdown clean ~$((t1-t0))s"; fi

echo "--- [accel] gc progress ---"
grep -E '\[accel\] gc: cycles=' "$MLOG" | tail -5
echo "--- [accel] final consult + gc + view-registry (floor must be none) ---"
grep -E '\[accel\] consult:|\[accel\] gc: enabled|\[accel\] view-registry' "$MLOG"
echo "=== DONE (gate: floor=none, retired total>0, construct_BAD=0, shutdown clean) ==="
