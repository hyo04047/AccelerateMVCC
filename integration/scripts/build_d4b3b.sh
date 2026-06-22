#!/usr/bin/env bash
# D-4 increment 4b-3b: wire the SHADOW consult into the InnoDB consistent-read version-build site
# and byte-compare our cached image vs vanilla's rebuilt *old_vers (result unused). Adds ReadView
# accessors (read0types.h), and two row0vers.cc probes: stash the live row's last writer at the top,
# and run accel_consult_shadow after vanilla rebuilt the visible version. A held-snapshot reader
# re-scans during churn to actually FIRE consistent-read version builds. Gate: hit_MISMATCH=0.
exec > /mnt/c/Users/USER/build_d4b3b.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"
TRX="$INNO/trx/trx0rec.cc"; VERS="$INNO/row/row0vers.cc"; RVH="$INNO/include/read0types.h"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"

echo "=== copy facade (shadow consult + counters) + ring into the tree ==="
cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"

echo "=== patch read0types.h: add ReadView accessors for the shadow (idempotent) ==="
python3 - "$RVH" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
if 'view_creator_trx_id' in s:
    print("read0types: already patched"); sys.exit(0)
anchor='trx_id_t low_limit_id() const { return (m_low_limit_id); }'
i=s.find(anchor)
if i<0: print("ERROR: low_limit_id anchor not found"); sys.exit(2)
ins=anchor+'''

  /* D-4 4b-3b: read-only accessors for the shadow consult (PoC). */
  trx_id_t up_limit_id() const { return (m_up_limit_id); }
  trx_id_t view_creator_trx_id() const { return (m_creator_trx_id); }
  const trx_id_t *ids_data() const { return (m_ids.data()); }
  ulint ids_size() const { return (m_ids.size()); }'''
s=s[:i]+ins+s[i+len(anchor):]
open(p,'w').write(s); print("read0types: accessors added")
PYEOF

echo "=== patch row0vers.cc: include + top live-writer stash + bottom shadow probe (idempotent) ==="
python3 - "$VERS" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
if 'accel_consult_shadow' in s:
    print("row0vers: already patched"); sys.exit(0)
# 1) include accel_hook.h after the first #include
j=s.find('#include')
nl=s.find('\n', j)
s=s[:nl+1]+'#include "accel_hook.h"  /* D-4 4b-3b shadow */\n'+s[nl+1:]
# 2) stash the live row's last writer right after the TOP read of the top rec's trx id
top='trx_id = row_get_rec_trx_id(rec, index, *offsets);'
k=s.find(top)
if k<0: print("ERROR: top row_get_rec_trx_id(rec,...) not found"); sys.exit(2)
s=s[:k+len(top)]+'\n  trx_id_t accel_live_writer = trx_id;  /* D-4 4b-3b: live row last writer */'+s[k+len(top):]
# 3) the shadow probe after vanilla copies the visible version into in_heap
anchor='*old_vers = rec_copy(buf, prev_version, *offsets);\n      rec_offs_make_valid(*old_vers, index, *offsets);'
cnt=s.count(anchor)
if cnt!=1: print("ERROR: rec_copy anchor count=%d (want 1)"%cnt); sys.exit(2)
block=anchor+'''

      {  /* D-4 4b-3b SHADOW: compare our cache vs this rebuilt visible version (result unused). */
        uint64_t accel_pk = 1469598103934665603ULL;
        unsigned char accel_pkbuf[256];   /* must match accel::ACCEL_PK_MAX */
        ulint accel_pklen = 0; bool accel_pk_ok = true;
        const ulint accel_nuk = dict_index_get_n_unique(index);
        for (ulint accel_i = 0; accel_i < accel_nuk; accel_i++) {
          ulint accel_len;
          const byte *accel_f = rec_get_nth_field(index, prev_version, *offsets, accel_i, &accel_len);
          if (accel_len == UNIV_SQL_NULL) accel_len = 0;
          for (ulint accel_b = 0; accel_b < accel_len; accel_b++)
            accel_pk = (accel_pk ^ accel_f[accel_b]) * 1099511628211ULL;
          accel_pk = (accel_pk ^ accel_len) * 1099511628211ULL;
          if (accel_pk_ok && accel_pklen + 2 + accel_len <= sizeof(accel_pkbuf)) {
            accel_pkbuf[accel_pklen++] = (unsigned char)(accel_len & 0xFF);
            accel_pkbuf[accel_pklen++] = (unsigned char)((accel_len >> 8) & 0xFF);
            for (ulint accel_c = 0; accel_c < accel_len; accel_c++)
              accel_pkbuf[accel_pklen++] = accel_f[accel_c];
          } else { accel_pk_ok = false; }
        }
        if (!accel_pk_ok) accel_pklen = 0;
        accel_consult_shadow(index->table->id, accel_pk, accel_pkbuf, accel_pklen,
                             view->up_limit_id(), view->low_limit_id(), view->view_creator_trx_id(),
                             view->ids_data(), view->ids_size(), accel_live_writer,
                             reinterpret_cast<const unsigned char*>(*old_vers),
                             rec_offs_data_size(*offsets));
      }'''
s=s.replace(anchor, block, 1)
open(p,'w').write(s); print("row0vers: include + stash + shadow probe added")
PYEOF
echo "--- row0vers probe check ---"; grep -n 'accel_consult_shadow\|accel_live_writer' "$VERS" | head

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d4b3b_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d4b3b_build.log | head -40; exit 1; fi

echo "=== boot ==="
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" 2>&1 | tail -1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > /mnt/c/Users/USER/d4b3b_mysqld.log 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1

echo "=== held-snapshot reader (re-scans under one RR snapshot) || churn (creates old versions) ==="
# churn in the background: 8 threads update non-indexed column -> new versions the reader can't see
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=30 --rand-type=pareto run > /mnt/c/Users/USER/d4b3b_churn.log 2>&1 &
CHURN=$!
# reader: ONE repeatable-read transaction, initial scan opens the snapshot, then re-scan every 2s.
# Each re-scan reconstructs the snapshot-visible (older) version of every row churn has changed since
# -> row_vers_build_for_consistent_read fires -> accel_consult_shadow fires.
{
  echo "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;"
  echo "START TRANSACTION;"
  echo "SELECT COUNT(*) FROM sbtest1;"
  for i in $(seq 1 13); do echo "DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) FROM sbtest1;"; done
  echo "COMMIT;"
} | "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest > /mnt/c/Users/USER/d4b3b_reader.log 2>&1 &
READER=$!
wait $CHURN; wait $READER
grep -E 'transactions:' /mnt/c/Users/USER/d4b3b_churn.log
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "=== [accel] (4b-3b gate: hit_MISMATCH=0 with hit_match>0; enq==drained, dropped=0) ==="
grep -E '\[accel\]' /mnt/c/Users/USER/d4b3b_mysqld.log
echo "=== DONE ==="
