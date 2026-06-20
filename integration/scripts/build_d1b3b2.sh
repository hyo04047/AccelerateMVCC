#!/usr/bin/env bash
# D-1b-3b re-verify: log chain_length (the right metric) to confirm the index is populated.
exec > /mnt/c/Users/USER/build_d1b3b2.log 2>&1
REPO="/mnt/c/Users/USER/projects/AccelerateMVCC"; SRCREPO="$REPO/integration/innodb"
INNO="$HOME/mysql-server/storage/innobase"; BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d1b3b2_build.log 2>&1
brc=$?; echo "mysqld build rc=$brc"
if [ $brc -ne 0 ]; then grep -iE 'error:' /mnt/c/Users/USER/d1b3b2_build.log | head -20; exit 1; fi
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" 2>&1 | tail -1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > /mnt/c/Users/USER/d1b3b2_mysqld.log 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
echo "--- churn 40s ---"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=40 --rand-type=pareto run 2>&1 | grep -E 'transactions:'
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "=== [accel] EVIDENCE (cur_key_chain_len>0 = index populated) ==="
grep -E '\[accel\]' /mnt/c/Users/USER/d1b3b2_mysqld.log
echo "=== DONE ==="
