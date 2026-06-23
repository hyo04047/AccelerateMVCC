#!/usr/bin/env bash
# D-5 diag: isolate which oltp_read_write operation makes the 4d consult HIT mismatch vanilla
# (construct_BAD>0). Same harness as the known-good 4d runs (--tables=1 --table-size=1000, held-
# snapshot deep reader triggering consult), but churn with ONE operation type at a time. serve OFF
# (auth_mode=0) -> shadow only, no wrong answer served; we read construct_ok/BAD per op. No rebuild:
# the mysqld is already at 4d-2 + 5-1c-2. Control = oltp_update_non_index (expect BAD=0, as in 4d/6).
exec > /mnt/c/Users/USER/build_d5_diag.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

run_op () {
  local wl="$1"; local tag="$2"
  local MLOG=/mnt/c/Users/USER/d5_diag_${tag}_mysqld.log
  echo ""; echo "############## OP: $wl ($tag) ##############"
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench "$wl" $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
  # held-snapshot deep reader (triggers consult on the version walk) || single-op churn
  ( "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT COUNT(*) FROM sbtest1;
SELECT SLEEP(2);
DO SLEEP(0); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;
DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;
DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;
DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;
DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;
COMMIT;
SQL
  ) > /mnt/c/Users/USER/d5_diag_${tag}_reader.log 2>&1 &
  local RD=$!
  sleep 1
  sysbench "$wl" $C --tables=1 --table-size=1000 --threads=8 --time=20 --rand-type=pareto run > /mnt/c/Users/USER/d5_diag_${tag}_churn.log 2>&1
  wait $RD
  grep -E 'transactions:' /mnt/c/Users/USER/d5_diag_${tag}_churn.log
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  echo "--- [accel] consult ($tag) ---"; grep -E 'consult:' "$MLOG"
}

run_op oltp_update_non_index non_index   # control: expect construct_BAD=0
run_op oltp_update_index     idx_update   # index column k update (secondary index maintained)
run_op oltp_delete           del_insert   # delete-mark + re-insert (delete-marked versions)
echo ""; echo "=== DONE (which op makes construct_BAD>0?) ==="
