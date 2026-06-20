#!/usr/bin/env bash
# Stage D-0c: bring vanilla MySQL 8.4 up, run sysbench baseline (OLTP no-LLT vs OLTP + 60s LLT).
# mysqld lives only inside this script (persisted across the runs here), then shuts down.
exec > /mnt/c/Users/USER/build_d0c.log 2>&1
BASE="$HOME/mysql-build"; BIN="$BASE/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"
DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2
rm -rf "$DATA"; mkdir -p "$DATA"
SHARE="$BASE/share"
echo "errmsg check: $(ls "$SHARE/english/errmsg.sys" 2>&1)"

echo "=== initialize datadir ==="
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BASE" --datadir="$DATA" --lc-messages-dir="$SHARE" 2>&1 | tail -6

echo "=== start mysqld ==="
"$MYSQLD" --no-defaults --user=root --basedir="$BASE" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin \
  --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 \
  > /mnt/c/Users/USER/d0c_mysqld.log 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
if ! "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT VERSION();"; then echo "MYSQL NOT READY"; tail -30 /mnt/c/Users/USER/d0c_mysqld.log; exit 1; fi

echo "=== create db + sysbench user ==="
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"

C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
WL="oltp_read_write"
echo "=== sysbench version ==="; sysbench --version
echo "=== prepare (1 table x 1000 rows -> hot rows get long chains) ==="
sysbench $WL $C --tables=1 --table-size=1000 prepare 2>&1 | tail -4

run () { sysbench $WL $C --tables=1 --table-size=1000 --threads=8 --time=30 --rand-type=pareto --report-interval=0 run 2>&1 | grep -E 'transactions:|queries:|events/s|avg:|95th|sum:'; }

echo "=== BASELINE A: OLTP read_write, NO LLT ==="
run
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHOW ENGINE INNODB STATUS\G" | grep -i "History list length"

echo "=== BASELINE B: OLTP read_write + concurrent 60s LLT (consistent snapshot held) ==="
( "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ; START TRANSACTION WITH CONSISTENT SNAPSHOT; SELECT SLEEP(60); COMMIT;" ) &
LLT=$!
sleep 2
run
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHOW ENGINE INNODB STATUS\G" | grep -i "History list length"
wait $LLT

echo "=== shutdown ==="
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 3; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "=== DONE ==="
