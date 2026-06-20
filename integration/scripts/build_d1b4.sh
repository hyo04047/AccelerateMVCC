#!/usr/bin/env bash
# Stage D-1b-4: verify the hardening static_asserts compile and mysqld still builds/boots/runs.
exec > /mnt/c/Users/USER/build_d1b4.log 2>&1
REPO="/mnt/c/Users/USER/projects/AccelerateMVCC"; SRCREPO="$REPO/integration/innodb"
INNO="$HOME/mysql-server/storage/innobase"; BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d1b4_build.log 2>&1
brc=$?; echo "mysqld build rc=$brc (static_asserts must compile)"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|static_assert|static assertion' /mnt/c/Users/USER/d1b4_build.log | head -20; exit 1; fi
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" 2>&1 | tail -1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > /mnt/c/Users/USER/d1b4_mysqld.log 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=20 --rand-type=pareto run 2>&1 | grep -E 'transactions:'
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "=== [accel] ==="; grep -E '\[accel\]' /mnt/c/Users/USER/d1b4_mysqld.log
echo "=== DONE ==="
