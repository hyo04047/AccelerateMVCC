#!/usr/bin/env bash
# D-5 diag3: confirm the construct_BAD cause is the WRITE-MIX PER TRANSACTION (not the read mix, not a
# single op). oltp_write_only does index_update + non_index_update + delete + insert in ONE transaction
# (no selects). tables=1. If construct_BAD>0 here, the bug is in consult's handling of version chains
# produced by a transaction that modifies rows multiple ways (multiple versions / same writer / delete+
# insert interleave) -- single-op workloads (one modification per txn) never build such chains. serve
# OFF; no rebuild.
exec > /mnt/c/Users/USER/build_d5_diag3.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
MLOG=/mnt/c/Users/USER/d5_diag3_mysqld.log

pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench oltp_write_only $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
( "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT COUNT(*) FROM sbtest1;
DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;
DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;
DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;
DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;
COMMIT;
SQL
) > /mnt/c/Users/USER/d5_diag3_reader.log 2>&1 &
RD=$!
sleep 1
sysbench oltp_write_only $C --tables=1 --table-size=1000 --threads=16 --time=16 --rand-type=uniform run > /mnt/c/Users/USER/d5_diag3_churn.log 2>&1
wait $RD
grep -E 'transactions:' /mnt/c/Users/USER/d5_diag3_churn.log
echo "--- held-reader SUMs (identical = snapshot invariant) ---"; grep -E '^[0-9]+$' /mnt/c/Users/USER/d5_diag3_reader.log | sort | uniq -c
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "--- [accel] consult (write_only) ---"; grep -E 'consult:' "$MLOG"
echo "=== DONE ==="
