#!/usr/bin/env bash
# D-5 diag5: classify the RESIDUAL wrong-version construct_BAD (after the tie-break fix) by direction.
# older = consult served an OLDER version than vanilla (cache behind: drainer-lag / contiguity-gate
# leak). newer = served a NEWER version (visibility-mirror disagreement). This decides the residual
# fix. serve OFF. Rebuilds with the tie-break fix already in accelerateMVCC.cpp.
exec > /mnt/c/Users/USER/build_d5_diag5.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; VERS="$INNO/row/row0vers.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
MLOG=/mnt/c/Users/USER/d5_diag5_mysqld.log

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
rm -f "$INNO/include/active_view_registry.h"

echo "=== row0vers.cc: add older/newer direction to the bad-trx diag (idempotent) ==="
grep -q 'accel_note_bad_trx' "$VERS" || { echo "ERROR: run build_d5_diag4.sh first"; exit 1; }
python3 - "$VERS" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
if 'accel_note_bad_dir' in s:
    print("row0vers already has bad-dir diag"); sys.exit(0)
a='            accel_note_bad_trx(accel_ct == accel_vt ? 1 : 0);'
b='''            accel_note_bad_trx(accel_ct == accel_vt ? 1 : 0);
            if (accel_ct != accel_vt) accel_note_bad_dir(accel_ct < accel_vt ? 1 : 0);'''
assert a in s, "accel_note_bad_trx anchor not found"
s=s.replace(a,b,1)
open(p,'w').write(s); print("row0vers: bad-dir diag installed")
PYEOF
grep -n 'accel_note_bad_dir' "$VERS"

echo "=== rebuild mysqld (with tie-break fix) ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d5_diag5_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d5_diag5_build.log | head -40; exit 1; fi

pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench oltp_read_write $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
sysbench oltp_read_write $C --tables=1 --table-size=1000 --threads=16 --time=20 --rand-type=uniform run > /mnt/c/Users/USER/d5_diag5_churn.log 2>&1
grep -E 'transactions:' /mnt/c/Users/USER/d5_diag5_churn.log
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "=== [accel] (residual: older=cache behind/lag, newer=visibility disagreement) ==="
grep -E 'consult:|construct_BAD detail' "$MLOG"
echo "=== DONE ==="
