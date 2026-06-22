#!/usr/bin/env bash
# D-4 4d-1: HOIST the consult above the version walk (still SHADOW -- do not serve yet). Key the cache
# by the LIVE TOP rec's PK (identical across a clustered row's versions for non-key updates) instead
# of the walked old version's PK, and prove this top-site consult still HITs and its image still equals
# vanilla's walked *old_vers (construct proof). This de-risks the consult RELOCATION on its own, before
# 4d-2 flips the actual walk-skip serve. Gate: construct_BAD=0, construct_ok==hit, hit not regressed
# (~13000 like 4d-prep). If top-PK extraction were wrong, hit would drop or construct_BAD would rise.
exec > /mnt/c/Users/USER/build_d4d1.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; TRX="$INNO/trx/trx0rec.cc"; VERS="$INNO/row/row0vers.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
MLOG=/mnt/c/Users/USER/d4d1_mysqld.log
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"

echo "=== trx0rec.cc: full physical record + extra size must already be present (from 4d-prep) ==="
if grep -q 'rec_offs_extra_size(offsets)' "$TRX"; then echo "trx0rec full-rec OK"; else
  echo "ERROR: trx0rec is not at full-rec capture -- run build_d4d_prep.sh first"; exit 1; fi

echo "=== read0types accessors must already be present (from 4b-3b) ==="
if grep -q 'ids_data' "$INNO/include/read0types.h"; then echo "read0types accessors OK"; else
  echo "ERROR: read0types accessors missing -- run build_d4b3b.sh first"; exit 1; fi

echo "=== row0vers.cc: hoist consult to the top + shadow compare in the loop (idempotent) ==="
python3 - "$VERS" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
if 'D-4 4d-1' in s:
    print("row0vers already 4d-1"); sys.exit(0)
# 1) hoist the consult ABOVE the walk loop: insert right after the live-writer line.
marker='trx_id_t accel_live_writer = trx_id;  /* D-4 4b-3b: live row last writer */'
i=s.find(marker)
if i<0: print("ERROR: live_writer marker not found"); sys.exit(2)
top_block='''
  /* D-4 4d-1: hoist the consult ABOVE the walk -- fetch the cached image now, keyed by the LIVE TOP
     rec's PK (identical across a clustered row's versions for non-key updates). Still SHADOW: we do
     NOT serve; the loop below still returns vanilla's walked *old_vers. We only prove this top-site
     consult HITs and its image equals vanilla, de-risking the relocation before 4d-2 flips the serve. */
  uint64_t accel_pk = 1469598103934665603ULL;
  unsigned char accel_pkbuf[256]; ulint accel_pklen = 0; bool accel_pk_ok = true;
  {
    const ulint accel_nuk = dict_index_get_n_unique(index);
    for (ulint accel_i = 0; accel_i < accel_nuk; accel_i++) {
      ulint accel_len; const byte *accel_f = rec_get_nth_field(index, rec, *offsets, accel_i, &accel_len);
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
  }
  unsigned char accel_cbuf[512]; unsigned int accel_clen = 0, accel_cextra = 0;
  int accel_oc = accel_consult_fetch(index->table->id, accel_pk, accel_pkbuf, accel_pklen,
                    view->up_limit_id(), view->low_limit_id(), view->view_creator_trx_id(),
                    view->ids_data(), view->ids_size(), accel_live_writer,
                    index->table->current_row_version, accel_cbuf, sizeof(accel_cbuf),
                    &accel_clen, &accel_cextra);'''
s=s[:i+len(marker)]+top_block+s[i+len(marker):]
# 2) replace the in-loop 4d-prep block (which re-extracted PK from prev_version and consulted there)
#    with a compare-ONLY block that uses the top-fetched image.
anchor='{  /* D-4 4d-prep SHADOW'
j=s.find(anchor)
if j<0: print("ERROR: 4d-prep block not found"); sys.exit(3)
depth=0; k=j
while k<len(s):
    if s[k]=='{': depth+=1
    elif s[k]=='}':
        depth-=1
        if depth==0: break
    k+=1
block=s[j:k+1]
new='''{  /* D-4 4d-1 SHADOW: compare the TOP-consulted cache image to vanilla's walked *old_vers. */
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
open(p,'w').write(s); print("row0vers: 4d-1 (consult hoisted to top, shadow compare) installed")
PYEOF
echo "--- sanity: top consult + compare both present ---"
grep -n 'D-4 4d-1' "$VERS"

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d4d1_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d4d1_build.log | head -40; exit 1; fi

echo "=== boot + held-snapshot reader || churn (standard sbtest, no DDL) ==="
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=30 --rand-type=pareto run > /mnt/c/Users/USER/d4d1_churn.log 2>&1 &
CH=$!
{ echo "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;"; echo "START TRANSACTION;"; echo "SELECT COUNT(*) FROM sbtest1;";
  for i in $(seq 1 13); do echo "DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) FROM sbtest1;"; done; echo "COMMIT;"; } \
  | "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest > /mnt/c/Users/USER/d4d1_reader.log 2>&1 &
RD=$!
wait $CH; wait $RD
grep -E 'transactions:' /mnt/c/Users/USER/d4d1_churn.log
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "=== [accel] (4d-1 gate: construct_BAD=0 AND construct_ok==hit AND hit ~13000 = top-PK consult correct) ==="
grep -E '\[accel\]' "$MLOG"
echo "=== DONE ==="
