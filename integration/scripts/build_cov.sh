#!/usr/bin/env bash
# D-4 coverage measurement (shadow mode, NO rebuild -- reuses the current mysqld). Answers: on the
# standard HTAP analytic-pain workload, what fraction of the expensive deep reads does the cache
# HIT, and is that robust under write stress / a small buffer pool (the motivating I/O-bound case)?
# Coverage = hit_match / calls. hit_MISMATCH must stay 0. Reuses the held-snapshot-reader || churn
# harness; varies (buffer pool size, writer threads). NO 4d needed -- shadow counters give coverage.
exec > /mnt/c/Users/USER/build_cov.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
MLOG=/mnt/c/Users/USER/cov_mysqld.log
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

boot() {  # $1 = buffer pool size
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=$1 --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
}
run() {  # $1 = churn threads
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=$1 --time=30 --rand-type=pareto run > /mnt/c/Users/USER/cov_churn.log 2>&1 &
  local CH=$!
  { echo "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;"; echo "START TRANSACTION;";
    echo "SELECT COUNT(*) FROM sbtest1;";
    for i in $(seq 1 13); do echo "DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) FROM sbtest1;"; done;
    echo "COMMIT;"; } | "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest > /mnt/c/Users/USER/cov_reader.log 2>&1 &
  local RD=$!
  wait $CH; wait $RD
  grep -E 'transactions:' /mnt/c/Users/USER/cov_churn.log
}
finish() { "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  echo ">>> $1"; grep -E '\[accel\] consult|\[accel\] shutdown' "$MLOG"; }

echo "########## (1) coverage baseline: 4G BP, 8 writers ##########"
boot "4G"; run 8;  finish "COV-1 4G/8w"
echo "########## (2) write stress: 4G BP, 32 writers (ring drop / drainer lag?) ##########"
boot "4G"; run 32; finish "COV-2 4G/32w"
echo "########## (3) small BP: 256M, 8 writers (I/O-bound motivating case) ##########"
boot "256M"; run 8; finish "COV-3 256M/8w"
echo "=== DONE ==="
