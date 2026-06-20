#!/usr/bin/env bash
# Stage D-0d (refined baseline): analytic read latency under a HELD snapshot while OLTP churns
# hot rows. Each scan walks clustered version chains back to the snapshot -> latency should grow
# as chains deepen. This is the cost the consult hook (D-2) will attack.
exec > /mnt/c/Users/USER/build_d0d.log 2>&1
BASE="$HOME/mysql-build"; BIN="$BASE/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309
SHARE="$BASE/share"
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BASE" --datadir="$DATA" --lc-messages-dir="$SHARE" 2>&1 | tail -2
"$MYSQLD" --no-defaults --user=root --basedir="$BASE" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 \
  > /mnt/c/Users/USER/d0d_mysqld.log 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT VERSION();" || { echo NOTREADY; tail -30 /mnt/c/Users/USER/d0d_mysqld.log; exit 1; }
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"

C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
WL="oltp_update_non_index"
sysbench $WL $C --tables=1 --table-size=1000 prepare 2>&1 | tail -2

echo "=== start OLTP churn (oltp_update_non_index, pareto, 8thr, 75s) in background ==="
sysbench $WL $C --tables=1 --table-size=1000 --threads=8 --time=75 --rand-type=pareto run > /mnt/c/Users/USER/d0d_oltp.log 2>&1 &
OLTP=$!
sleep 1

# Analytic session: hold ONE snapshot, scan every ~6s for ~60s; print per-scan latency (us).
SQL="SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ; START TRANSACTION WITH CONSISTENT SNAPSHOT;"
for i in $(seq 0 10); do
  SQL="$SQL SET @t:=NOW(6); SELECT SUM(LENGTH(c)) INTO @x FROM sbtest1; SELECT CONCAT('SCAN ',$i,' us=',TIMESTAMPDIFF(MICROSECOND,@t,NOW(6))); DO SLEEP(6);"
done
SQL="$SQL COMMIT;"
echo "=== analytic full-scan latency under held snapshot (scan 0 = chains short ... scan 10 = deep) ==="
echo "$SQL" | "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest 2>&1 | grep -E 'SCAN [0-9]+ us='
echo "=== history list length (end) ==="
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHOW ENGINE INNODB STATUS\G" | grep -i "History list length"
wait $OLTP
echo "=== OLTP churn summary ==="; grep -E 'transactions:|queries:' /mnt/c/Users/USER/d0d_oltp.log
echo "=== shutdown ==="; "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 3; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "=== DONE ==="
