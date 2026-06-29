#!/usr/bin/env bash
# Phase 3 pre-flight (correctness surface): ADVERSARIAL savepoint rollback. Harder than q8: the rolled-back
# intermediate version is on the SAME row a held reader can see (q8 rolled back a different row), and three
# held readers take staggered snapshots so some land mid-churn. Each writer txn commits +1 to row r but
# rolls back a +1000000 to the SAME row r via ROLLBACK TO SAVEPOINT -- the accel hook captured that
# rolled-back pre-image. A WRONG serve would surface as a reader (or the committed table) observing a value
# carrying the +1000000 component (>= 1000000; legitimate +1 accumulation stays far below). Gates:
# construct_BAD=0 AND every held reader's MAX(k) < 1000000 AND committed MAX(k) < 1000000. 4G, mode-2.
# See docs/phase2-q3-llt.md and docs/design-D4b-shadow.md S8 (savepoint split residual).
exec > /mnt/c/Users/USER/q14_savepoint.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
MLOG=/mnt/c/Users/USER/q14_mysqld.log
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
ACCEL_AUTHORITATIVE=2 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 --innodb-redo-log-capacity=8G > "$MLOG" 2>&1 &
for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
Q -e "DROP DATABASE IF EXISTS db; CREATE DATABASE db;"
Q db -e "CREATE TABLE t (id INT PRIMARY KEY, k BIGINT) ENGINE=InnoDB;"
Q db -e "INSERT INTO t SELECT seq,0 FROM (WITH RECURSIVE s(seq) AS (SELECT 1 UNION ALL SELECT seq+1 FROM s WHERE seq<1000) SELECT seq FROM s) q;"
"$MYSQL" --no-defaults -uroot -S "$SOCK" db <<'PROC'
DELIMITER //
CREATE PROCEDURE hammer(IN secs INT)
BEGIN DECLARE e DATETIME DEFAULT (NOW()+INTERVAL secs SECOND); DECLARE r INT;
  WHILE NOW()<e DO
    SET r=1+FLOOR(RAND()*1000);
    START TRANSACTION;
    UPDATE t SET k=k+1 WHERE id=r;          -- committed effect
    SAVEPOINT sp;
    UPDATE t SET k=k+1000000 WHERE id=r;     -- SAME row; rolled back -> must never be served
    ROLLBACK TO SAVEPOINT sp;
    COMMIT;
  END WHILE; END //
DELIMITER ;
PROC
reader(){  # $1=tag $2=predelay
  ( sleep "$2"; "$MYSQL" --no-defaults -uroot -S "$SOCK" db <<SQL
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ; SET SESSION max_execution_time=25000;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT '$1-warm' tag, MAX(k) mx FROM t;
SELECT SLEEP(8);
SELECT '$1-deep' tag, MAX(k) mx FROM t;
COMMIT;
SQL
  ) > /mnt/c/Users/USER/q14_${1}.log 2>&1 & }
# three staggered held readers (snapshots at t=0, t=3, t=6 into the churn)
reader r0 0; P0=$!; reader r1 3; P1=$!; reader r2 6; P2=$!
sleep 1
HP=""; for w in 1 2 3 4; do ( Q db -e "CALL hammer(12)" >/dev/null 2>&1 ) & HP="$HP $!"; done
wait $P0 $P1 $P2 $HP   # specific pids only -- a bare `wait` would also block on the mysqld bg job
echo "--- ground truth (committed live): MAX(k) must be < 1000000 (no rolled-back +1000000 leaked) ---"
Q db -e "SELECT MAX(k) max_k, SUM(k>=1000000) rows_with_leak FROM t;"
Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "--- held readers (every mx must be < 1000000) ---"
for r in r0 r1 r2; do grep -E "\b${r}-(warm|deep)\b" /mnt/c/Users/USER/q14_${r}.log | sed 's/^/  /'; done
echo "--- gate ---"
LINE=$(grep -E '\[accel\] consult:' "$MLOG" | tail -1); echo "  $LINE"
BAD=$(echo "$LINE" | grep -oE 'construct_BAD=[0-9]+' | grep -oE '[0-9]+')
if [ "$BAD" = "0" ]; then echo "  GATE: PASS (construct_BAD=0)"; else echo "  GATE: *** FAIL construct_BAD=$BAD ***"; fi
echo "=== DONE ==="
