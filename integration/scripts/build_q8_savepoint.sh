#!/usr/bin/env bash
# Phase 2 / ⓝ15 savepoint-rollback safety: a change made after a SAVEPOINT and undone by ROLLBACK TO
# SAVEPOINT was never committed, but its undo record was captured by the accel hook before the rollback.
# Gate: construct_BAD=0 (consult never serves that rolled-back version to a held reader -- it serves the
# correct committed version or conservatively MISSes to the vanilla walk). Churn = txns that commit a +1 to
# one row but ROLLBACK TO SAVEPOINT a +1000 to another. 4G resident, mode-2 verify-serve, GC off.
# See docs/phase2-q3-llt.md.
exec > /mnt/c/Users/USER/q8_savepoint.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
MLOG=/mnt/c/Users/USER/q8_mysqld.log; SLOG=/mnt/c/Users/USER/q8_scan.log
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
ACCEL_AUTHORITATIVE=2 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
Q -e "DROP DATABASE IF EXISTS db; CREATE DATABASE db;"
Q db -e "CREATE TABLE t (id INT PRIMARY KEY, k BIGINT) ENGINE=InnoDB;"
Q db -e "INSERT INTO t SELECT seq,0 FROM (WITH RECURSIVE s(seq) AS (SELECT 1 UNION ALL SELECT seq+1 FROM s WHERE seq<1000) SELECT seq FROM s) q;"
"$MYSQL" --no-defaults -uroot -S "$SOCK" db <<'PROC'
DELIMITER //
CREATE PROCEDURE hammer(IN secs INT)
BEGIN DECLARE e DATETIME DEFAULT (NOW()+INTERVAL secs SECOND); DECLARE r1 INT; DECLARE r2 INT;
  WHILE NOW()<e DO
    SET r1=1+FLOOR(RAND()*1000); SET r2=1+FLOOR(RAND()*1000);
    START TRANSACTION;
    UPDATE t SET k=k+1 WHERE id=r1;
    SAVEPOINT sp;
    UPDATE t SET k=k+1000 WHERE id=r2;
    ROLLBACK TO SAVEPOINT sp;
    COMMIT;
  END WHILE; END //
DELIMITER ;
PROC
( "$MYSQL" --no-defaults -uroot -S "$SOCK" db <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ; SET SESSION max_execution_time=25000;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT 'warm' tag, SUM(k) s, MAX(k) mx FROM t;
SELECT SLEEP(12);
SELECT 'deep' tag, SUM(k) s, MAX(k) mx FROM t;
COMMIT;
SQL
) > "$SLOG" 2>&1 &
SNAP=$!; sleep 2
for w in 1 2 3 4; do ( Q db -e "CALL hammer(10)" >/dev/null 2>&1 ) & done
wait $SNAP
echo "--- ground truth (live): any k>=1000 = a rolled-back change leaked ---"
Q db -e "SELECT MAX(k) max_k, SUM(k>=1000) rows_with_leak FROM t;"
Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "--- held reader (mx must be < 1000) ---"; grep -E '\b(warm|deep)\b' "$SLOG" | sed 's/^/  /'
echo "--- gate: construct_BAD=0 ---"; grep -E '\[accel\] consult:' "$MLOG" | sed 's/^/  /'
echo "=== DONE ==="
