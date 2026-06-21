#!/usr/bin/env bash
# D-4 increment ②: capture the overwritten row's image at the populate hook and carry it through
# the ring. Copies the updated facade + image-slot ring into the tree, patches the call site to
# pass (rec, rec_offs_size) as the image, rebuilds mysqld, and runs a churn to confirm the image
# flows through (drainer still ignores img in this increment -> drained==enq means it passed).
exec > /mnt/c/Users/USER/build_d2img.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; TRX="$INNO/trx/trx0rec.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"

echo "=== copy facade + image-slot ring into the tree ==="
cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"

echo "=== patch call site to pass the row image (idempotent on accel_img_len) ==="
if grep -q 'accel_img_len' "$TRX"; then
  echo "already image-call"
else
  sed -i 's#^        accel_on_undo(index->table->id, accel_pk, trx->id,#        ulint accel_img_len = rec_offs_size(offsets);\n        accel_on_undo(index->table->id, accel_pk, trx->id,#' "$TRX"
  sed -i 's#                      undo_ptr->rseg->space_id, page_no, offset, op_type);#                      undo_ptr->rseg->space_id, page_no, offset, op_type,\n                      reinterpret_cast<const unsigned char*>(rec), accel_img_len);#' "$TRX"
fi
echo "--- call site now ---"; grep -n 'accel_img_len\|accel_on_undo\|rec_offs_size(offsets)' "$TRX" | head

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d2img_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d2img_build.log | head -30; exit 1; fi

echo "=== boot + churn ==="
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" 2>&1 | tail -1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > /mnt/c/Users/USER/d2img_mysqld.log 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=30 --rand-type=pareto run 2>&1 | grep -E 'transactions:'
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "=== [accel] (image flows through the ring now; drainer still ignores img -> expect drained==enq, dropped small) ==="
grep -E '\[accel\]' /mnt/c/Users/USER/d2img_mysqld.log
echo "=== DONE ==="
