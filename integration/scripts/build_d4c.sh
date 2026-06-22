#!/usr/bin/env bash
# D-4 increment 4c-1: populate-side caching EXCLUSION gates. At the trx0rec.cc capture site, set the
# image length to 0 (locator-only -> consult MISS) when the row has off-page LOB (rec_offs_any_extern:
# the cached clustered rec holds only a 20-byte LOB ref whose pages purge/update can move/free) OR the
# table has virtual/generated columns (n_v_cols>0: their values are recomputed at read time, not in
# the clustered rec). Verified with a LOB table + a virtual-column table + a normal table under a
# held-snapshot reader: the special rows MISS (excluded), the normal table stays hit_MISMATCH=0.
exec > /mnt/c/Users/USER/build_d4c.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; TRX="$INNO/trx/trx0rec.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
MLOG=/mnt/c/Users/USER/d4c_mysqld.log

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"

echo "=== patch trx0rec.cc: LOB/virtual exclusion at capture (idempotent) ==="
if grep -q 'rec_offs_any_extern(offsets) || index->table->n_v_cols' "$TRX"; then
  echo "already 4c-gated"
else
  sed -i 's#ulint accel_img_len = rec_offs_data_size(offsets);#ulint accel_img_len = (rec_offs_any_extern(offsets) || index->table->n_v_cols > 0) ? 0 : rec_offs_data_size(offsets);  /* D-4 4c-1: exclude off-page LOB / virtual-column rows */#' "$TRX"
fi
grep -n 'accel_img_len =' "$TRX" | head

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d4c_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d4c_build.log | head -40; exit 1; fi

echo "=== boot ==="
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done

echo "=== create + populate normal / LOB / virtual tables (500 rows each) ==="
"$MYSQL" --no-defaults -uroot -S "$SOCK" <<'SQL'
CREATE DATABASE accdb;
USE accdb;
CREATE TABLE t_norm (id INT PRIMARY KEY, k INT, c CHAR(120)) ENGINE=InnoDB;
CREATE TABLE t_lob  (id INT PRIMARY KEY, k INT, body LONGTEXT) ENGINE=InnoDB;
CREATE TABLE t_virt (id INT PRIMARY KEY, a INT, b INT GENERATED ALWAYS AS (a*2) VIRTUAL) ENGINE=InnoDB;
INSERT INTO t_norm (id,k,c)    WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<500) SELECT n,n,REPEAT('a',120) FROM s;
INSERT INTO t_lob  (id,k,body) WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<500) SELECT n,n,REPEAT('x',5000) FROM s;
INSERT INTO t_virt (id,a)      WITH RECURSIVE s(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM s WHERE n<500) SELECT n,n FROM s;
SQL

echo "=== held-snapshot reader (scans all 3) || committed churn on all 3 ==="
# churn: committed updates on each table -> versions the reader's snapshot can't see
{ echo "USE accdb;"; for i in $(seq 1 2500); do r=$(( i % 500 + 1 ));
    echo "UPDATE t_norm SET k=k+1 WHERE id=$r; UPDATE t_lob SET k=k+1 WHERE id=$r; UPDATE t_virt SET a=a+1 WHERE id=$r;";
  done; } | "$MYSQL" --no-defaults -uroot -S "$SOCK" > /mnt/c/Users/USER/d4c_churn.log 2>&1 &
CH=$!
{ echo "USE accdb;"; echo "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;"; echo "START TRANSACTION;";
  echo "SELECT COUNT(*) FROM t_norm; SELECT COUNT(*) FROM t_lob; SELECT COUNT(*) FROM t_virt;";
  for i in $(seq 1 12); do echo "DO SLEEP(2); SELECT SUM(k+LENGTH(c)) FROM t_norm; SELECT SUM(k+LENGTH(body)) FROM t_lob; SELECT SUM(a+b) FROM t_virt;"; done;
  echo "COMMIT;"; } | "$MYSQL" --no-defaults -uroot -S "$SOCK" > /mnt/c/Users/USER/d4c_reader.log 2>&1 &
RD=$!
wait $CH; wait $RD
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "=== [accel] (4c-1: hit_MISMATCH=0; hit_match>0 from t_norm; miss_ineligible>0 from LOB/virtual) ==="
grep -E '\[accel\] consult|\[accel\] shutdown' "$MLOG"
echo "=== DONE ==="
