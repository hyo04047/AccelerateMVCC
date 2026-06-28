#!/usr/bin/env bash
# Phase 2 correctness breadth (part of ⓝ4): composite PK, string PK, secondary-index reads. The cache keys on
# FNV(full-PK bytes) from the first n_unique fields (row0vers.cc), validated so far only on a single INT PK.
# Gate: consult HIT > 0 AND construct_BAD=0 (byte-correct under mode-2 verify-serve) for (a) a 2-column
# composite PK, (b) a VARCHAR string PK, (c) rows reached via a SECONDARY index. LIGHT config (4G resident,
# 10s churn) -- a correctness check needs no deep chains / small BP. See docs/phase2-q3-llt.md.
exec > /mnt/c/Users/USER/q7_keys.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }

boot(){ pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=2 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$1" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done; }

run(){  # $1=variant  $2=tag
  local VAR="$1" tag="$2"; local MLOG=/mnt/c/Users/USER/q7_${tag}_mysqld.log; local SLOG=/mnt/c/Users/USER/q7_${tag}_scan.log
  boot "$MLOG"; Q -e "DROP DATABASE IF EXISTS db; CREATE DATABASE db;"
  if [ "$VAR" = "composite" ]; then
    Q db -e "CREATE TABLE t (a INT, b INT, k BIGINT, sec INT, PRIMARY KEY(a,b), KEY(sec)) ENGINE=InnoDB;"
    Q db -e "INSERT INTO t SELECT seq,seq,0,seq FROM (WITH RECURSIVE s(seq) AS (SELECT 1 UNION ALL SELECT seq+1 FROM s WHERE seq<1000) SELECT seq FROM s) q;"
    "$MYSQL" --no-defaults -uroot -S "$SOCK" db <<'PROC'
DELIMITER //
CREATE PROCEDURE hammer(IN secs INT)
BEGIN DECLARE e DATETIME DEFAULT (NOW()+INTERVAL secs SECOND); DECLARE r INT;
  WHILE NOW()<e DO SET r=1+FLOOR(RAND()*1000); UPDATE t SET k=k+1 WHERE a=r AND b=r; END WHILE; END //
DELIMITER ;
PROC
    ( "$MYSQL" --no-defaults -uroot -S "$SOCK" db <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ; SET SESSION max_execution_time=25000;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT 'clustered' tag, SUM(k) s FROM t;
SELECT 'secondary' tag, SUM(k) s FROM t FORCE INDEX(sec) WHERE sec > 0;
SELECT SLEEP(12);
SELECT 'clustered2' tag, SUM(k) s FROM t;
SELECT 'secondary2' tag, SUM(k) s FROM t FORCE INDEX(sec) WHERE sec > 0;
COMMIT;
SQL
    ) > "$SLOG" 2>&1 &
  else
    Q db -e "CREATE TABLE t (id VARCHAR(40) PRIMARY KEY, k BIGINT) ENGINE=InnoDB;"
    Q db -e "INSERT INTO t SELECT CONCAT('key-',LPAD(seq,8,'0')),0 FROM (WITH RECURSIVE s(seq) AS (SELECT 1 UNION ALL SELECT seq+1 FROM s WHERE seq<1000) SELECT seq FROM s) q;"
    "$MYSQL" --no-defaults -uroot -S "$SOCK" db <<'PROC'
DELIMITER //
CREATE PROCEDURE hammer(IN secs INT)
BEGIN DECLARE e DATETIME DEFAULT (NOW()+INTERVAL secs SECOND);
  WHILE NOW()<e DO UPDATE t SET k=k+1 WHERE id=CONCAT('key-',LPAD(1+FLOOR(RAND()*1000),8,'0')); END WHILE; END //
DELIMITER ;
PROC
    ( "$MYSQL" --no-defaults -uroot -S "$SOCK" db <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ; SET SESSION max_execution_time=25000;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT 'scan' tag, SUM(k) s FROM t; SELECT SLEEP(12); SELECT 'scan2' tag, SUM(k) s FROM t; COMMIT;
SQL
    ) > "$SLOG" 2>&1 &
  fi
  local SNAP=$!; sleep 2
  for w in 1 2 3 4; do ( Q db -e "CALL hammer(10)" >/dev/null 2>&1 ) & done
  wait $SNAP; Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  printf "%-14s | " "$tag"; grep -E '\[accel\] consult:' "$MLOG" | head -1
}

echo "=== Phase 2 keys breadth (4G, mode-2): HIT>0 AND construct_BAD=0 ==="
run composite composite_pk
run stringpk  string_pk
echo "=== DONE ==="
