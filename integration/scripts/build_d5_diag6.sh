#!/usr/bin/env bash
# D-5 diag6: split the RESIDUAL "newer" wrong-version construct_BAD by its root cause, in ONE bit.
# At each newer case (consult chose a version with a LARGER trx_id than vanilla), ask the LIVE view
# itself whether consult's chosen version (ct) is visible, and whether ct is in the view's active set:
#   vanilla_sees(ct)=1  => ct is genuinely visible but NOT on vanilla's undo chain for this row
#                          => the cache holds a cross-generation version (e.g. delete+reinsert same PK).
#   vanilla_sees(ct)=0  => consult was fed DIFFERENT view limits than vanilla actually uses
#                          => a view-input extraction bug (the mirror is byte-exact, so inputs differ).
# Also dumps the first ~40 cases (ct/vt/up/low/creator/ct_in_mids/vanilla_sees) for the concrete pattern.
# serve OFF (auth_mode=0) -> shadow only, no wrong answer served. Same harness as diag4/diag5.
exec > /mnt/c/Users/USER/build_d5_diag6.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; VERS="$INNO/row/row0vers.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
MLOG=/mnt/c/Users/USER/d5_diag6_mysqld.log

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
rm -f "$INNO/include/active_view_registry.h"   # resolved via -I repo/include (avoid duplicate copy)

echo "=== row0vers.cc: on a NEWER construct_BAD, ask the live view about ct (idempotent) ==="
grep -q 'accel_note_bad_dir' "$VERS" || { echo "ERROR: run build_d5_diag5.sh first (bad-dir diag missing)"; exit 1; }
python3 - "$VERS" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
if 'accel_note_newer_detail' in s:
    print("row0vers already has diag6 newer-detail"); sys.exit(0)
a='            if (accel_ct != accel_vt) accel_note_bad_dir(accel_ct < accel_vt ? 1 : 0);'
b=a + '''
            if (accel_ct > accel_vt) {  /* D-5 diag6: the systematic NEWER wrong-version set */
              bool accel_vsees = view->changes_visible(accel_ct, index->table->name);
              int accel_ct_in = 0;
              const trx_id_t *accel_mi = view->ids_data();
              auto accel_mn = view->ids_size();
              for (decltype(accel_mn) accel_q = 0; accel_q < accel_mn; accel_q++)
                if (accel_mi[accel_q] == accel_ct) { accel_ct_in = 1; break; }
              accel_note_newer_detail((uint64_t)accel_ct, (uint64_t)accel_vt,
                  (uint64_t)view->up_limit_id(), (uint64_t)view->low_limit_id(),
                  (uint64_t)view->view_creator_trx_id(), accel_ct_in, accel_vsees ? 1 : 0);
            }'''
assert a in s, "bad-dir anchor not found"
s=s.replace(a,b,1)
open(p,'w').write(s); print("row0vers: diag6 newer-detail installed")
PYEOF
grep -n 'accel_note_newer_detail' "$VERS"

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d5_diag6_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d5_diag6_build.log | head -40; exit 1; fi

pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench oltp_read_write $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
sysbench oltp_read_write $C --tables=1 --table-size=1000 --threads=16 --time=20 --rand-type=uniform run > /mnt/c/Users/USER/d5_diag6_churn.log 2>&1
grep -E 'transactions:' /mnt/c/Users/USER/d5_diag6_churn.log
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "=== [accel] summary + newer split + first cases ==="
grep -E 'consult:|construct_BAD detail|newer split' "$MLOG"
echo "--- first newer cases (ct=consult chose, vt=vanilla chose) ---"
grep -E 'newer#' "$MLOG" | head -40
echo "=== DONE (vanilla_sees dominant => cross-generation cache; vanilla_hides dominant => input mismatch) ==="
