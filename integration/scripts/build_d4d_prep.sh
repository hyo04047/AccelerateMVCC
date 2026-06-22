#!/usr/bin/env bash
# D-4 4d-prep: prove the AUTHORITATIVE record construction in SHADOW (do not serve yet). Capture the
# FULL physical record (header+data) + its extra (header) size; at the read site fetch the cached
# image, build a rec_t from it (rec_get_offsets), and prove it equals vanilla's rebuilt *old_vers
# (data bytes + delete flag + valid offsets). Walk still runs and InnoDB still returns its own answer
# -> risk 0. Gate: construct_BAD=0 and construct_ok == hit. Next session flips the walk-skip switch.
exec > /mnt/c/Users/USER/build_d4d_prep.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; TRX="$INNO/trx/trx0rec.cc"; VERS="$INNO/row/row0vers.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
MLOG=/mnt/c/Users/USER/d4dprep_mysqld.log
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"

echo "=== trx0rec.cc: capture FULL physical record + extra size (idempotent) ==="
if grep -q 'rec_offs_extra_size(offsets)' "$TRX"; then echo "trx0rec already full-rec"; else
  sed -i 's#ulint accel_img_len = (rec_offs_any_extern(offsets) || index->table->n_v_cols > 0) ? 0 : rec_offs_data_size(offsets);#ulint accel_extra = rec_offs_extra_size(offsets);\n        ulint accel_img_len = (rec_offs_any_extern(offsets) || index->table->n_v_cols > 0) ? 0 : rec_offs_size(offsets);  /* D-4 4d: full physical record */#' "$TRX"
  sed -i 's#reinterpret_cast<const unsigned char\*>(rec), accel_img_len,#reinterpret_cast<const unsigned char*>(rec) - accel_extra, accel_img_len,#' "$TRX"
  sed -i 's#accel_pkbuf, accel_pklen, accel_del);#accel_pkbuf, accel_pklen, accel_del, accel_extra);#' "$TRX"
fi
grep -n 'accel_extra\|accel_img_len =' "$TRX" | head

echo "=== row0vers.cc: replace shadow block with fetch + rec construction proof (idempotent) ==="
python3 - "$VERS" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
if 'accel_consult_fetch' in s:
    print("row0vers already 4d-prep"); sys.exit(0)
anchor='{  /* D-4 4b-3b SHADOW'
i=s.find(anchor)
if i<0: print("ERROR: shadow block not found"); sys.exit(2)
depth=0; k=i
while k<len(s):
    if s[k]=='{': depth+=1
    elif s[k]=='}':
        depth-=1
        if depth==0: break
    k+=1
block=s[i:k+1]
new='''{  /* D-4 4d-prep SHADOW: fetch the cached image, build a rec_t, prove it == vanilla *old_vers. */
        uint64_t accel_pk = 1469598103934665603ULL;
        unsigned char accel_pkbuf[256]; ulint accel_pklen = 0; bool accel_pk_ok = true;
        const ulint accel_nuk = dict_index_get_n_unique(index);
        for (ulint accel_i = 0; accel_i < accel_nuk; accel_i++) {
          ulint accel_len; const byte *accel_f = rec_get_nth_field(index, prev_version, *offsets, accel_i, &accel_len);
          if (accel_len == UNIV_SQL_NULL) accel_len = 0;
          for (ulint accel_b = 0; accel_b < accel_len; accel_b++) accel_pk = (accel_pk ^ accel_f[accel_b]) * 1099511628211ULL;
          accel_pk = (accel_pk ^ accel_len) * 1099511628211ULL;
          if (accel_pk_ok && accel_pklen + 2 + accel_len <= sizeof(accel_pkbuf)) {
            accel_pkbuf[accel_pklen++] = (unsigned char)(accel_len & 0xFF);
            accel_pkbuf[accel_pklen++] = (unsigned char)((accel_len >> 8) & 0xFF);
            for (ulint accel_c = 0; accel_c < accel_len; accel_c++) accel_pkbuf[accel_pklen++] = accel_f[accel_c];
          } else { accel_pk_ok = false; }
        }
        if (!accel_pk_ok) accel_pklen = 0;
        unsigned char accel_cbuf[512]; unsigned int accel_clen = 0, accel_cextra = 0;
        int accel_oc = accel_consult_fetch(index->table->id, accel_pk, accel_pkbuf, accel_pklen,
                          view->up_limit_id(), view->low_limit_id(), view->view_creator_trx_id(),
                          view->ids_data(), view->ids_size(), accel_live_writer,
                          index->table->current_row_version, accel_cbuf, sizeof(accel_cbuf),
                          &accel_clen, &accel_cextra);
        if (accel_oc == 0 && accel_clen > accel_cextra) {
          mem_heap_t *accel_h = mem_heap_create(256, UT_LOCATION_HERE);
          rec_t *accel_crec = reinterpret_cast<rec_t*>(accel_cbuf + accel_cextra);
          ulint *accel_co = rec_get_offsets(accel_crec, index, nullptr, ULINT_UNDEFINED, UT_LOCATION_HERE, &accel_h);
          ulint accel_comp = rec_offs_comp(*offsets);
          int accel_match = (rec_offs_data_size(accel_co) == rec_offs_data_size(*offsets)
                && memcmp(accel_crec, *old_vers, rec_offs_data_size(*offsets)) == 0
                && (rec_get_deleted_flag(accel_crec, accel_comp) ? 1 : 0)
                   == (rec_get_deleted_flag(*old_vers, accel_comp) ? 1 : 0)) ? 1 : 0;
          accel_note_construct(accel_match);
          mem_heap_free(accel_h);
        }
      }'''
s=s.replace(block, new, 1)
open(p,'w').write(s); print("row0vers: fetch + construction proof installed")
PYEOF
grep -n 'accel_consult_fetch\|accel_note_construct' "$VERS" | head

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d4dprep_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d4dprep_build.log | head -40; exit 1; fi

echo "=== boot + held-snapshot reader || churn (standard sbtest, no DDL) ==="
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=30 --rand-type=pareto run > /mnt/c/Users/USER/d4dprep_churn.log 2>&1 &
CH=$!
{ echo "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;"; echo "START TRANSACTION;"; echo "SELECT COUNT(*) FROM sbtest1;";
  for i in $(seq 1 13); do echo "DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) FROM sbtest1;"; done; echo "COMMIT;"; } \
  | "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest > /mnt/c/Users/USER/d4dprep_reader.log 2>&1 &
RD=$!
wait $CH; wait $RD
grep -E 'transactions:' /mnt/c/Users/USER/d4dprep_churn.log
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "=== [accel] (4d-prep gate: construct_BAD=0 AND construct_ok==hit) ==="
grep -E '\[accel\]' "$MLOG"
echo "=== DONE ==="
