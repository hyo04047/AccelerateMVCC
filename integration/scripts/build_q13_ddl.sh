#!/usr/bin/env bash
# Phase 3 pre-flight (correctness surface): DDL straddle. The instant-DDL gate keys on the reader's
# table->current_row_version; rebuild/TRUNCATE create a NEW InnoDB table_id so the cache (keyed by
# table_id) is naturally isolated. This converts "asserted safe" into "construct_BAD=0 measured" across
# three DDL forms: (1) INSTANT ADD COLUMN (gate must MISS -> ineligible), (2) rebuild ALTER ... FORCE
# (new table_id -> fresh cache, HIT correct), (3) TRUNCATE (new table_id). Universal gate in EVERY
# variant: construct_BAD=0 (the cache never serves an old-layout/old-generation row). 4G resident,
# mode-2 verify-serve. See docs/phase2-q3-llt.md.
exec > /mnt/c/Users/USER/q13_ddl.log 2>&1
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }

boot(){ pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=2 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 --innodb-redo-log-capacity=8G > "$1" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done; }

mkproc(){
"$MYSQL" --no-defaults -uroot -S "$SOCK" db <<'PROC'
DELIMITER //
CREATE PROCEDURE hammer(IN secs INT)
BEGIN DECLARE e DATETIME DEFAULT (NOW()+INTERVAL secs SECOND); DECLARE r INT;
  WHILE NOW()<e DO SET r=1+FLOOR(RAND()*1000); UPDATE t SET k=k+1 WHERE id=r; END WHILE; END //
DELIMITER ;
PROC
}

run(){  # $1=kind  $2=tag
  local KIND="$1" tag="$2"; local MLOG=/mnt/c/Users/USER/q13_${tag}_mysqld.log; local SLOG=/mnt/c/Users/USER/q13_${tag}_scan.log
  boot "$MLOG"
  Q -e "DROP DATABASE IF EXISTS db; CREATE DATABASE db;"
  Q db -e "CREATE TABLE t (id INT PRIMARY KEY, k BIGINT) ENGINE=InnoDB;"
  Q db -e "INSERT INTO t SELECT seq,0 FROM (WITH RECURSIVE s(seq) AS (SELECT 1 UNION ALL SELECT seq+1 FROM s WHERE seq<1000) SELECT seq FROM s) q;"
  mkproc
  # phase 1: LIGHT seed churn to populate cache under the ORIGINAL table object (kept light so the
  # pre-reader write burst cannot saturate redo and stall new connections -- the reader connects next).
  local sp=""; for w in 1 2; do ( Q db -e "CALL hammer(2)" >/dev/null 2>&1 ) & sp="$sp $!"; done; wait $sp
  # apply the straddling DDL
  case "$KIND" in
    instant)  Q db -e "ALTER TABLE t ADD COLUMN c INT DEFAULT 0, ALGORITHM=INSTANT;" ;;
    rebuild)  Q db -e "ALTER TABLE t FORCE, ALGORITHM=COPY;" ;;
    truncate) Q db -e "TRUNCATE TABLE t;"
              Q db -e "INSERT INTO t SELECT seq,0 FROM (WITH RECURSIVE s(seq) AS (SELECT 1 UNION ALL SELECT seq+1 FROM s WHERE seq<1000) SELECT seq FROM s) q;" ;;
  esac
  Q db -e "SELECT table_id, name FROM information_schema.innodb_tables WHERE name='db/t';" 2>/dev/null
  # phase 2: held reader (snapshot AFTER the DDL) + concurrent post-DDL churn, mode-2 verify-serve
  ( "$MYSQL" --no-defaults -uroot -S "$SOCK" db <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ; SET SESSION max_execution_time=25000;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT 'warm' tag, SUM(k) s FROM t;
SELECT SLEEP(12);
SELECT 'deep' tag, SUM(k) s FROM t;
COMMIT;
SQL
  ) > "$SLOG" 2>&1 &
  local SNAP=$!; sleep 2
  for w in 1 2 3 4; do ( Q db -e "CALL hammer(9)" >/dev/null 2>&1 ) & done
  wait $SNAP
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  echo "===== variant: $tag ($KIND) ====="
  grep -E '\b(warm|deep)\b' "$SLOG" | sed 's/^/  reader: /'
  local LINE; LINE=$(grep -E '\[accel\] consult:' "$MLOG" | tail -1)
  echo "  $LINE"
  local BAD; BAD=$(echo "$LINE" | grep -oE 'construct_BAD=[0-9]+' | grep -oE '[0-9]+')
  if [ "$BAD" = "0" ]; then echo "  GATE: PASS (construct_BAD=0)"; else echo "  GATE: *** FAIL construct_BAD=$BAD ***"; fi
}

echo "=== Phase 3 pre-flight: DDL straddle (4G, mode-2). Gate = construct_BAD=0 in every variant ==="
run instant  instant_addcol
run rebuild  rebuild_force
run truncate truncate_recreate
echo "=== DONE ==="
