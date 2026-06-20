#!/usr/bin/env bash
# Stage D-1b-1: key plumbing. Widen the hook (pk_hash + old_trx_id), extract clustered PK +
# prior DB_TRX_ID at the call site, filter to MODIFY-op. Body stays count-only; verify keys are
# row-unique (pk_buckets_seen >> 1). Idempotent.
exec > /mnt/c/Users/USER/build_d1b1.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; TRX="$INNO/trx/trx0rec.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"

echo "=== copy updated facade + strip CR from patch ==="
cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
cp "$SRCREPO/d1b1_patch.pl" /tmp/d1b1_patch.pl
sed -i 's/\r$//' /tmp/d1b1_patch.pl

echo "=== ensure CMakeLists source + include patches (idempotent) ==="
grep -q 'accel/accel_hook.cc' "$INNO/CMakeLists.txt" || sed -i 's#^  trx/trx0rec.cc#  trx/trx0rec.cc\n  accel/accel_hook.cc#' "$INNO/CMakeLists.txt"
grep -q 'accel_hook.h' "$TRX" || sed -i 's@#include "trx0rec.h"@#include "trx0rec.h"\n#include "accel_hook.h"@' "$TRX"

echo "=== replace D-1a call with D-1b-1 PK-extracting block (idempotent) ==="
if grep -q 'accel_pk' "$TRX"; then echo "already D-1b-1"; else
  perl -0777 -i -p /tmp/d1b1_patch.pl "$TRX"
fi
echo "=== fix rec_get_nth_field signature (index first) [idempotent] ==="
grep -q 'rec_get_nth_field(index, rec, offsets, accel_i' "$TRX" || sed -i 's#rec_get_nth_field(rec, offsets, accel_i, &accel_len)#rec_get_nth_field(index, rec, offsets, accel_i, \&accel_len)#' "$TRX"
echo "--- call site now: ---"; grep -n 'accel_pk\|accel_on_undo\|rec_get_nth_field' "$TRX"

echo "=== incremental build (mysqld) ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d1b1_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== BUILD ERRORS ==="; grep -iE 'error:' /mnt/c/Users/USER/d1b1_build.log | head -30; echo ABORT; exit 1; fi

echo "=== start mysqld + churn ==="
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" 2>&1 | tail -1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 \
  > /mnt/c/Users/USER/d1b1_mysqld.log 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT VERSION();" || { echo NOTREADY; tail -30 /mnt/c/Users/USER/d1b1_mysqld.log; exit 1; }
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
echo "--- churn 60s ---"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=60 --rand-type=pareto run 2>&1 | grep -E 'transactions:|queries:'
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 3; pkill -9 -f "$MYSQLD" 2>/dev/null

echo "=== KEY-PLUMBING EVIDENCE ([accel] lines: pk_buckets_seen should be >> 1) ==="
grep -E '\[accel\]' /mnt/c/Users/USER/d1b1_mysqld.log | tail -8
echo "=== DONE ==="
