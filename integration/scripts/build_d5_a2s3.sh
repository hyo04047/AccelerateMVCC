#!/usr/bin/env bash
# D-5 ⑤a-2 step 3: epoch numbering normalized to the InnoDB id space (base = first inserted version's trx).
# Goal: epochs now start near 0 and land in the bucket ring, so the AMORTIZED windowed sweep engages
# (step 2 was 100% dummy drain). Gate: GC on (ACCEL_GC=1) -> retired{windowed} > 0 (the dangerous bucket
# sweep path actually runs), construct_BAD=0 (shadow correct under GC), shutdown clean. serve OFF.
exec > /mnt/c/Users/USER/build_d5_a2s3.log 2>&1
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
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d5_a2s3_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d5_a2s3_build.log | head -40; exit 1; fi

MLOG=/mnt/c/Users/USER/d5_a2s3_mysqld.log
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
ACCEL_GC=1 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench oltp_read_write $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
echo "=== GC ON: 40s oltp_read_write ==="
sysbench oltp_read_write $C --tables=1 --table-size=1000 --threads=8 --time=40 --rand-type=uniform run 2>&1 | grep -E 'transactions:'
t0=$(date +%s); "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null
for i in $(seq 1 25); do pgrep -f "$MYSQLD" >/dev/null 2>&1 || break; sleep 1; done
t1=$(date +%s)
if pgrep -f "$MYSQLD" >/dev/null 2>&1; then echo "SHUTDOWN HANG"; pkill -9 -f "$MYSQLD" 2>/dev/null; else echo "shutdown clean ~$((t1-t0))s"; fi

echo "--- [accel] gc progress (windowed should climb off 0) ---"
grep -E '\[accel\] gc: cycles=' "$MLOG" | tail -8
echo "--- [accel] final consult + gc ---"
grep -E '\[accel\] consult:|\[accel\] gc: enabled' "$MLOG"
echo "=== DONE (gate: windowed>0, construct_BAD=0, shutdown clean) ==="
