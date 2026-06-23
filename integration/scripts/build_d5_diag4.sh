#!/usr/bin/env bash
# D-5 diag4: classify the construct_BAD found under oltp_read_write. On a shadow construct mismatch,
# compare the cache rec's DB_TRX_ID to vanilla's *old_vers DB_TRX_ID: trx_same => consult picked the
# RIGHT version but the bytes differ (capture/byte issue); trx_diff => consult picked the WRONG version
# (a version-selection / contiguity-gate leak). This one bit decides the bug class. serve OFF.
exec > /mnt/c/Users/USER/build_d5_diag4.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; VERS="$INNO/row/row0vers.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
MLOG=/mnt/c/Users/USER/d5_diag4_mysqld.log

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
rm -f "$INNO/include/active_view_registry.h"

echo "=== row0vers.cc: on construct_BAD, compare cache vs vanilla DB_TRX_ID (idempotent) ==="
python3 - "$VERS" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
if 'accel_note_bad_trx' in s:
    print("row0vers already has bad-trx diag"); sys.exit(0)
a='          accel_note_construct(accel_match);'
b='''          accel_note_construct(accel_match);
          if (!accel_match) {
            trx_id_t accel_ct = row_get_rec_trx_id(accel_crec, index, accel_co);
            trx_id_t accel_vt = row_get_rec_trx_id(*old_vers, index, *offsets);
            accel_note_bad_trx(accel_ct == accel_vt ? 1 : 0);
          }'''
assert a in s, "accel_note_construct anchor not found"
s=s.replace(a,b,1)
open(p,'w').write(s); print("row0vers: bad-trx diag installed")
PYEOF
grep -n 'accel_note_bad_trx' "$VERS"

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d5_diag4_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d5_diag4_build.log | head -40; exit 1; fi

pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench oltp_read_write $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
sysbench oltp_read_write $C --tables=1 --table-size=1000 --threads=16 --time=18 --rand-type=uniform run > /mnt/c/Users/USER/d5_diag4_churn.log 2>&1
grep -E 'transactions:' /mnt/c/Users/USER/d5_diag4_churn.log
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "=== [accel] (trx_diff = WRONG version picked; trx_same = right version, wrong bytes) ==="
grep -E 'consult:|construct_BAD detail' "$MLOG"
echo "=== DONE ==="
