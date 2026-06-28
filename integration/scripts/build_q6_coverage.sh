#!/usr/bin/env bash
# Phase 2 / ⓝ6 coverage + SAFETY on LOB / off-page / virtual / >512B rows. These are excluded at capture
# (trx0rec.cc: img_len=0 when rec_offs_any_extern || n_v_cols>0; the hook also drops images > ACCEL_IMG_MAX
# =512) -> stored locator-only -> consult MISS_INELIGIBLE -> vanilla walk. Confirms: coverage collapses on
# these rows BUT construct_BAD=0 (never a wrong / partial-image serve). Off-page LOB is the subtle case --
# its main record (LOB pointer ~20B) can be <512B, so without the rec_offs_any_extern gate the cache could
# serve a row missing its LOB. 4 variants: small control (sysbench), big in-page (>512B), off-page LOB
# (LONGTEXT 20KB), virtual column. 64M BP, GC off. See docs/phase2-q3-llt.md ⓝ6.
#
# Prereq: row0vers at 4d-2 (build_d4d2.sh).
exec > /mnt/c/Users/USER/q6_coverage.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

boot(){  # $1=auth_mode
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=$1 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=64M --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > /mnt/c/Users/USER/q6_${2}_mysqld.log 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
}

sysbench_run(){  # $1=variant(small|big)  $2=tag  -- sysbench churn (mode 1)
  local VAR="$1" tag="$2"; boot 1 "$tag"
  Q -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare >/dev/null 2>&1
  [ "$VAR" = "big" ] && Q sbtest -e "ALTER TABLE sbtest1 ADD COLUMN payload VARCHAR(2000); UPDATE sbtest1 SET payload=REPEAT('x',1500);"
  ( "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET profiling=1;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT SUM(k+LENGTH(c)) FROM sbtest1;
SELECT SLEEP(40);
SELECT SUM(k+LENGTH(c)) FROM sbtest1;
COMMIT;
SHOW PROFILES;
SQL
  ) > /mnt/c/Users/USER/q6_${tag}_scan.log 2>&1 &
  local SNAP=$!; sleep 2
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=36 --rand-type=pareto run >/dev/null 2>&1
  wait $SNAP; Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  printf "%-12s | " "$tag"; grep -E '\[accel\] consult:' /mnt/c/Users/USER/q6_${tag}_mysqld.log | head -1
}

proc_run(){  # $1=variant(lob|virtual)  $2=tag  -- custom table + stored-proc churn (mode 2 verify-serve)
  local VAR="$1" tag="$2"; boot 2 "$tag"
  Q -e "DROP DATABASE IF EXISTS db; CREATE DATABASE db;"
  if [ "$VAR" = "lob" ]; then
    Q db -e "CREATE TABLE t (id INT PRIMARY KEY, k BIGINT, body LONGTEXT) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;"
    Q db -e "INSERT INTO t SELECT seq,0,REPEAT('x',20000) FROM (WITH RECURSIVE s(seq) AS (SELECT 1 UNION ALL SELECT seq+1 FROM s WHERE seq<1000) SELECT seq FROM s) q;"
  else
    Q db -e "CREATE TABLE t (id INT PRIMARY KEY, k BIGINT, kv BIGINT AS (k*2) VIRTUAL, KEY(kv)) ENGINE=InnoDB;"
    Q db -e "INSERT INTO t(id,k) SELECT seq,0 FROM (WITH RECURSIVE s(seq) AS (SELECT 1 UNION ALL SELECT seq+1 FROM s WHERE seq<1000) SELECT seq FROM s) q;"
  fi
  "$MYSQL" --no-defaults -uroot -S "$SOCK" db <<'PROC'
DELIMITER //
CREATE PROCEDURE hammer(IN secs INT)
BEGIN
  DECLARE endt DATETIME DEFAULT (NOW() + INTERVAL secs SECOND);
  WHILE NOW() < endt DO
    UPDATE t SET k=k+1 WHERE id = 1 + FLOOR(RAND()*1000);
  END WHILE;
END //
DELIMITER ;
PROC
  ( "$MYSQL" --no-defaults -uroot -S "$SOCK" db <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT SUM(k) FROM t; SELECT SLEEP(34); SELECT SUM(k) FROM t; COMMIT;
SQL
  ) > /mnt/c/Users/USER/q6_${tag}_scan.log 2>&1 &
  local SNAP=$!; sleep 2
  for w in 1 2 3 4; do ( Q db -e "CALL hammer(30)" >/dev/null 2>&1 ) & done
  wait $SNAP; Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  printf "%-12s | " "$tag"; grep -E '\[accel\] consult:' /mnt/c/Users/USER/q6_${tag}_mysqld.log | head -1
}

echo "=== ⓝ6 coverage + safety (64M, GC off): expect excluded rows ineligible 100% + construct_BAD=0 ==="
sysbench_run small ctrl_small
sysbench_run big   big_inpage
proc_run     lob   offpage_lob
proc_run     virtual virtual_col
echo "=== DONE ==="
