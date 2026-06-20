#!/usr/bin/env bash
# Stage D-1a: wire the accelerator populate hook into InnoDB (count-only), rebuild mysqld,
# and prove the hook fires from real undo creation. Idempotent patches.
exec > /mnt/c/Users/USER/build_d1a.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"

echo "=== copy facade into MySQL tree ==="
mkdir -p "$INNO/accel"
cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
ls -la "$INNO/include/accel_hook.h" "$INNO/accel/accel_hook.cc"

echo "=== patch CMakeLists (add source) [idempotent] ==="
if grep -q 'accel/accel_hook.cc' "$INNO/CMakeLists.txt"; then echo "already added"; else
  sed -i 's#^  trx/trx0rec.cc#  trx/trx0rec.cc\n  accel/accel_hook.cc#' "$INNO/CMakeLists.txt"
fi
grep -n 'accel/accel_hook.cc' "$INNO/CMakeLists.txt"

echo "=== patch trx0rec.cc (include) [idempotent] ==="
TRX="$INNO/trx/trx0rec.cc"
if grep -q 'accel_hook.h' "$TRX"; then echo "include already present"; else
  sed -i 's@#include "trx0rec.h"@#include "trx0rec.h"\n#include "accel_hook.h"@' "$TRX"
fi
grep -n '#include "accel_hook.h"' "$TRX" || { echo "INCLUDE PATCH FAILED (no trx0rec.h anchor?)"; grep -n '#include' "$TRX" | head; }

echo "=== patch trx0rec.cc (hook call on success path) [idempotent] ==="
if grep -q 'accel_on_undo' "$TRX"; then echo "call already present"; else
  perl -0777 -i -pe 's/\Qundo_ptr->rseg->space_id, page_no, offset);\E\n(\s*)return \(DB_SUCCESS\);/undo_ptr->rseg->space_id, page_no, offset);\n      accel_on_undo(index->table->id, trx->id, undo_ptr->rseg->space_id, page_no, offset, op_type);\n${1}return (DB_SUCCESS);/' "$TRX"
fi
grep -n 'accel_on_undo' "$TRX" || echo "CALL PATCH FAILED"

echo "=== incremental build (mysqld) ==="
/usr/bin/time -v cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d1a_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== BUILD ERRORS ==="; grep -iE 'error:' /mnt/c/Users/USER/d1a_build.log | head -25; echo ABORT; exit 1; fi
grep -E 'Elapsed \(wall' /mnt/c/Users/USER/d1a_build.log

echo "=== start mysqld + churn to fire the hook ==="
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" 2>&1 | tail -1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 \
  > /mnt/c/Users/USER/d1a_mysqld.log 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT VERSION();" || { echo NOTREADY; tail -30 /mnt/c/Users/USER/d1a_mysqld.log; exit 1; }
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
echo "--- churn 60s ---"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=60 --rand-type=pareto run 2>&1 | grep -E 'transactions:|queries:'
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 3; pkill -9 -f "$MYSQLD" 2>/dev/null

echo "=== HOOK EVIDENCE ([accel] lines from mysqld error log) ==="
grep -E '\[accel\]' /mnt/c/Users/USER/d1a_mysqld.log | tail -10
echo "=== DONE ==="
