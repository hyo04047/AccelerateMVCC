#!/usr/bin/env bash
# D-4 increment 4c-2 (FINAL, simple gate): instant-DDL safety via a coarse CONSULT-SIDE gate. consult
# is given the READER's table current_row_version (live_schema_epoch); if it is >0 (the table has had
# an instant ADD/DROP COLUMN) the cache is not trusted for that table -> MISS -> full walk. No
# per-entry tag (the diagnosis showed current_row_version-at-capture is the wrong signal: consult sees
# the reader-era value). Verified by doing the instant DROP FIRST, then a post-ALTER reader: that
# table's deep reads MISS (gate fires), a normal table still HITs, hit_MISMATCH=0.
exec > /mnt/c/Users/USER/build_d4c2.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; TRX="$INNO/trx/trx0rec.cc"; VERS="$INNO/row/row0vers.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
MLOG=/mnt/c/Users/USER/d4c2_mysqld.log
Q() { "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"

echo "=== trx0rec.cc: REVERT the per-entry schema arg (accel_on_undo no longer takes it) ==="
sed -i 's#accel_pkbuf, accel_pklen, accel_del, index->table->current_row_version);#accel_pkbuf, accel_pklen, accel_del);#' "$TRX"
echo "=== row0vers.cc: ensure live current_row_version is passed to accel_consult_shadow (idempotent) ==="
if grep -q 'accel_live_writer, index->table->current_row_version,' "$VERS"; then echo "row0vers already passes live schema"; else
  sed -i 's#view->ids_data(), view->ids_size(), accel_live_writer,#view->ids_data(), view->ids_size(), accel_live_writer, index->table->current_row_version,#' "$VERS"
fi
grep -n 'current_row_version' "$TRX" "$VERS" | head

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d4c2_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d4c2_build.log | head -40; exit 1; fi

boot() {  # $1 = env
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  env $1 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  Q <<'SQL'
CREATE DATABASE accdb; USE accdb;
CREATE TABLE t_norm (id INT PRIMARY KEY, k INT, c CHAR(50)) ENGINE=InnoDB;
CREATE TABLE t_alt  (id INT PRIMARY KEY, k INT, c CHAR(50)) ENGINE=InnoDB;
INSERT INTO t_norm (id,k,c) WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<500) SELECT n,n,REPEAT('a',50) FROM s;
INSERT INTO t_alt  (id,k,c) WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<500) SELECT n,n,REPEAT('a',50) FROM s;
SQL
}
churn() { { echo "USE accdb;"; for i in $(seq 1 1500); do r=$((i % 500 + 1)); echo "UPDATE t_norm SET k=k+1 WHERE id=$r; UPDATE t_alt SET k=k+1 WHERE id=$r;"; done; } | Q >/dev/null 2>&1; }
scenario() {  # $1 = env, $2 = label
  boot "$1"
  Q -e "USE accdb; ALTER TABLE t_alt DROP COLUMN c, ALGORITHM=INSTANT;" 2>&1 | tail -1   # instant DDL FIRST -> t_alt current_row_version=1
  # reader STARTS AFTER the ALTER -> its t_alt table view has current_row_version=1 -> gate should fire
  { echo "USE accdb;"; echo "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;"; echo "START TRANSACTION;";
    echo "SELECT COUNT(*) FROM t_norm; SELECT COUNT(*) FROM t_alt;";
    for i in $(seq 1 14); do echo "DO SLEEP(2); SELECT SUM(k+LENGTH(c)) FROM t_norm; SELECT SUM(id+k) FROM t_alt;"; done;
    echo "COMMIT;"; } | Q > /mnt/c/Users/USER/d4c2_reader.log 2>&1 &
  local RD=$!
  sleep 3
  churn
  wait $RD
  Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  echo ">>> SCENARIO $2"; grep -E '\[accel\] consult|\[accel\] shutdown' "$MLOG"
}

echo "############ (E) instant-DDL table, schema gate ON ############"
scenario "" "E-gate-ON (expect t_alt deep reads -> miss_ineligible, t_norm -> hit_match, MISMATCH=0)"
echo "############ (F) schema gate OFF (ACCEL_NO_SCHEMA_CHECK=1) ############"
scenario "ACCEL_NO_SCHEMA_CHECK=1" "F-gate-OFF (t_alt consults proceed; same-era so likely match -- negative control is best-effort)"
echo "=== DONE ==="
