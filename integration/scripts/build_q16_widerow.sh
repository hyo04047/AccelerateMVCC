#!/usr/bin/env bash
# Phase-3 pre-flight (design-D6 (A): wide in-page row caching). Today ACCEL_IMG_MAX=512 excludes rows that
# are >512B but entirely IN-PAGE (no extern LOB, no virtual cols) -- yet those capture byte-identically, so
# raising the cap is SAFE. This rebuilds mysqld with ACCEL_IMG_MAX_BYTES=2048 (build-time opt-in; shipped
# default stays 512) and proves a ~1.4KB all-in-page row now HITs the cache with construct_BAD=0 under
# mode-2 verify-serve. CONTROL: the same workload at the default 512 cap MISSes (ineligible) those rows.
# Restores the live tree to the default cap + rebuilds back at the end. See docs/design-D6-wide-row.md.
exec > /mnt/c/Users/USER/q16_widerow.log 2>&1
REPO=/mnt/c/Users/USER/projects/AccelerateMVCC
INNO=/root/mysql-server/storage/innobase
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }

rebuild(){ # $1 = cap bytes
  cp "$REPO/integration/innodb/accel_ring.h" "$INNO/include/accel_ring.h"
  sed -i "s/#define ACCEL_IMG_MAX_BYTES 512/#define ACCEL_IMG_MAX_BYTES $1/" "$INNO/include/accel_ring.h"
  # The serve buffer (accel_cbuf) + out_cap in row0vers.cc gate the SERVED image size, so they must be
  # raised in lockstep with the cache cap -- otherwise a wide row is cached but consult MISSes on out_cap.
  sed -i "s/unsigned char accel_cbuf\[[0-9]*\]/unsigned char accel_cbuf[$1]/" "$INNO/row/row0vers.cc"
  echo "=== rebuild mysqld with ACCEL_IMG_MAX_BYTES=$1 + accel_cbuf[$1] ==="
  grep -n 'define ACCEL_IMG_MAX_BYTES' "$INNO/include/accel_ring.h"
  grep -n 'accel_cbuf\[' "$INNO/row/row0vers.cc" | head -1
  touch "$INNO/accel/accel_hook.cc" "$REPO/include/accelerateMVCC.cpp" "$INNO/row/row0vers.cc"
  cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/q16_build_$1.log 2>&1
  echo "build rc=$?"; grep -c 'error:' /mnt/c/Users/USER/q16_build_$1.log
}

# wide all-in-page row: PK + 3 x VARCHAR(450) ~= 1.35KB, NO TEXT/BLOB (so no off-page extern), no virtual.
testrun(){ # $1 = tag (expectation in name)
  local tag="$1"; local MLOG=/mnt/c/Users/USER/q16_${tag}_mysqld.log; local SLOG=/mnt/c/Users/USER/q16_${tag}_scan.log
  echo ""; echo "########## $tag ##########"
  pkill -9 -x mysqld 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=2 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 --innodb-redo-log-capacity=8G > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  Q -e "DROP DATABASE IF EXISTS db; CREATE DATABASE db;"
  Q db -e "CREATE TABLE t (id INT PRIMARY KEY, k BIGINT, a VARCHAR(450), b VARCHAR(450), c VARCHAR(450)) ENGINE=InnoDB ROW_FORMAT=DYNAMIC;"
  Q db -e "INSERT INTO t SELECT seq,0,REPEAT('a',450),REPEAT('b',450),REPEAT('c',450) FROM (WITH RECURSIVE s(seq) AS (SELECT 1 UNION ALL SELECT seq+1 FROM s WHERE seq<1000) SELECT seq FROM s) q;"
  Q db -e "SELECT AVG(LENGTH(a)+LENGTH(b)+LENGTH(c)) approx_row_payload FROM t;"
  "$MYSQL" --no-defaults -uroot -S "$SOCK" db <<'PROC'
DELIMITER //
CREATE PROCEDURE hammer(IN secs INT)
BEGIN DECLARE e DATETIME DEFAULT (NOW()+INTERVAL secs SECOND); DECLARE r INT;
  WHILE NOW()<e DO SET r=1+FLOOR(RAND()*1000); UPDATE t SET k=k+1 WHERE id=r; END WHILE; END //
DELIMITER ;
PROC
  ( "$MYSQL" --no-defaults -uroot -S "$SOCK" db <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ; SET SESSION max_execution_time=25000;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT 'warm' tag, SUM(k+LENGTH(a)+LENGTH(b)+LENGTH(c)) s FROM t;
SELECT SLEEP(12);
SELECT 'deep' tag, SUM(k+LENGTH(a)+LENGTH(b)+LENGTH(c)) s FROM t;
COMMIT;
SQL
  ) > "$SLOG" 2>&1 &
  local SNAP=$!; sleep 2
  local hp=""; for w in 1 2 3 4; do ( Q db -e "CALL hammer(9)" >/dev/null 2>&1 ) & hp="$hp $!"; done
  wait $SNAP
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -x mysqld 2>/dev/null; wait $hp 2>/dev/null
  grep -E '\b(warm|deep)\b' "$SLOG" | sed 's/^/  reader: /'
  local LINE; LINE=$(grep -E '\[accel\] consult:' "$MLOG" | tail -1); echo "  $LINE"
  local BAD HIT INE; BAD=$(echo "$LINE"|grep -oE 'construct_BAD=[0-9]+'|grep -oE '[0-9]+'); HIT=$(echo "$LINE"|grep -oE 'hit=[0-9]+'|grep -oE '[0-9]+'); INE=$(echo "$LINE"|grep -oE 'ineligible=[0-9]+'|grep -oE '[0-9]+')
  echo "  => hit=$HIT ineligible=$INE construct_BAD=$BAD"
}

echo "=== design-D6 (A): wide in-page (~1.35KB) row caching. Gate: cap=2048 -> HIT>0 & construct_BAD=0; cap=512 control -> ineligible ==="
rebuild 512
testrun control_cap512_expect_ineligible
rebuild 2048
testrun raised_cap2048_expect_hit
echo ""; echo "=== restore shipped default cap (512) ==="
rebuild 512
echo "=== DONE ==="
