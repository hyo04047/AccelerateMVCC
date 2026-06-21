#!/usr/bin/env bash
# D-4 increment 4b-1: full-PK identity bytes + delete-mark + DATA-payload image window (M1).
# Copies the updated facade/ring into the tree, rewrites the trx0rec.cc accel call-site block to the
# 4b-1 form (idempotent via brace-matching: builds a length-prefixed full-PK buffer, captures the
# delete-mark, and switches the image length from rec_offs_size to rec_offs_data_size), rebuilds
# mysqld, and runs a churn. PK flows ring->node when [accel] shows last_pk_len>0 and enq==drained.
exec > /mnt/c/Users/USER/build_d4b1.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; TRX="$INNO/trx/trx0rec.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"

echo "=== copy facade + ring (with PK slot) into the tree ==="
cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"

echo "=== rewrite the trx0rec.cc accel call-site block to 4b-1 (idempotent) ==="
python3 - "$TRX" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
if 'accel_pklen' in src:
    print("already 4b-1 (accel_pklen present) -> skip rewrite")
    sys.exit(0)
anchor = 'if (op_type == TRX_UNDO_MODIFY_OP && rec != nullptr) {'
i = src.find(anchor)
if i < 0:
    print("ERROR: accel call-site anchor not found"); sys.exit(2)
# find the matching close brace for the block opened at the anchor's '{'
depth = 0; j = src.find('{', i); k = j
while k < len(src):
    c = src[k]
    if c == '{': depth += 1
    elif c == '}':
        depth -= 1
        if depth == 0: break
    k += 1
block_end = k + 1  # inclusive of the closing '}'
indent = ''
ls = src.rfind('\n', 0, i)
indent = src[ls+1:i]  # leading whitespace before the 'if'
new_block = '''if (op_type == TRX_UNDO_MODIFY_OP && rec != nullptr) {
        /* D-4 4b-1: pk_hash bucket hint (FNV-1a) + full-PK identity bytes (length-prefixed so
           distinct field splits cannot alias) + delete-mark + DATA-payload image
           (rec_offs_data_size, NOT rec_offs_size which over-reads extra_size past the row, M1). */
        uint64_t accel_pk = 1469598103934665603ULL;
        unsigned char accel_pkbuf[256];   /* must match accel::ACCEL_PK_MAX */
        ulint accel_pklen = 0;
        bool accel_pk_ok = true;
        const ulint accel_nuk = dict_index_get_n_unique(index);
        for (ulint accel_i = 0; accel_i < accel_nuk; accel_i++) {
          ulint accel_len;
          const byte *accel_f = rec_get_nth_field(index, rec, offsets, accel_i, &accel_len);
          if (accel_len == UNIV_SQL_NULL) accel_len = 0;
          for (ulint accel_b = 0; accel_b < accel_len; accel_b++)
            accel_pk = (accel_pk ^ accel_f[accel_b]) * 1099511628211ULL;
          accel_pk = (accel_pk ^ accel_len) * 1099511628211ULL;
          if (accel_pk_ok && accel_pklen + 2 + accel_len <= sizeof(accel_pkbuf)) {
            accel_pkbuf[accel_pklen++] = (unsigned char)(accel_len & 0xFF);
            accel_pkbuf[accel_pklen++] = (unsigned char)((accel_len >> 8) & 0xFF);
            for (ulint accel_c = 0; accel_c < accel_len; accel_c++)
              accel_pkbuf[accel_pklen++] = accel_f[accel_c];
          } else {
            accel_pk_ok = false;   /* PK over cap -> no identity bytes -> consult MISS */
          }
        }
        if (!accel_pk_ok) accel_pklen = 0;
        ulint accel_img_len = rec_offs_data_size(offsets);
        ulint accel_del = rec_get_deleted_flag(rec, rec_offs_comp(offsets)) ? 1 : 0;
        accel_on_undo(index->table->id, accel_pk, trx->id,
                      row_get_rec_trx_id(rec, index, offsets),
                      undo_ptr->rseg->space_id, page_no, offset, op_type,
                      reinterpret_cast<const unsigned char*>(rec), accel_img_len,
                      accel_pkbuf, accel_pklen, accel_del);
      }'''
src = src[:i] + new_block + src[block_end:]
open(path, 'w').write(src)
print("rewrote accel call-site block to 4b-1")
PYEOF
echo "--- call site now ---"; grep -n 'accel_pklen\|accel_img_len\|rec_offs_data_size\|accel_del\|accel_on_undo' "$TRX" | head

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d4b1_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d4b1_build.log | head -40; exit 1; fi

echo "=== boot + churn ==="
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" 2>&1 | tail -1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > /mnt/c/Users/USER/d4b1_mysqld.log 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=30 --rand-type=pareto run 2>&1 | grep -E 'transactions:'
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "=== [accel] (4b-1: expect enq==drained, dropped=0, last_pk_len>0 = PK flows ring->node) ==="
grep -E '\[accel\]' /mnt/c/Users/USER/d4b1_mysqld.log
echo "=== DONE ==="
