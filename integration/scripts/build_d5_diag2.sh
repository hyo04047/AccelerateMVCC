#!/usr/bin/env bash
# D-5 diag2: isolate the construct_BAD cause to TABLE COUNT. Same workload (oltp_read_write) and size
# (table-size=1000), vary ONLY --tables (1 vs 4). Hypothesis: with >1 table the cache mixes table_ids
# and consult HITs a same-PK row from the WRONG table (cross-table collision -> wrong data -> BAD). A
# held-snapshot reader scans sbtest1; churn hits all tables. serve OFF. No rebuild.
exec > /mnt/c/Users/USER/build_d5_diag2.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

run_tabs () {
  local nt="$1"; local tag="$2"
  local MLOG=/mnt/c/Users/USER/d5_diag2_${tag}_mysqld.log
  echo ""; echo "############## tables=$nt ($tag) ##############"
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_read_write $C --tables=$nt --table-size=1000 prepare 2>&1 | tail -1
  ( "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT COUNT(*) FROM sbtest1;
DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;
DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;
DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;
DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;
DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;
COMMIT;
SQL
  ) > /mnt/c/Users/USER/d5_diag2_${tag}_reader.log 2>&1 &
  local RD=$!
  sleep 1
  sysbench oltp_read_write $C --tables=$nt --table-size=1000 --threads=16 --time=20 --rand-type=uniform run > /mnt/c/Users/USER/d5_diag2_${tag}_churn.log 2>&1
  wait $RD
  grep -E 'transactions:' /mnt/c/Users/USER/d5_diag2_${tag}_churn.log
  echo "--- held-reader SUMs (should all be identical = snapshot invariant) ---"
  grep -E '^[0-9]+$' /mnt/c/Users/USER/d5_diag2_${tag}_reader.log | sort | uniq -c
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  echo "--- [accel] consult ($tag) ---"; grep -E 'consult:' "$MLOG"
}

run_tabs 1 one_table    # expect construct_BAD=0
run_tabs 4 four_tables  # expect construct_BAD>0 if cross-table collision is the cause
echo ""; echo "=== DONE (tables=1 BAD vs tables=4 BAD) ==="
