#!/usr/bin/env bash
# D-4 4d-2: the AUTHORITATIVE serve switch. On a consult HIT, serve a rec_t built from the cached image
# in place of the undo-walked version. Two env-gated modes (default 0=off/shadow):
#   ACCEL_AUTHORITATIVE=2  verify-serve: still walk to rebuild vanilla, byte-compare, then serve the
#                          cache-built rec. Proves every SERVED answer == vanilla. Gate: construct_BAD=0,
#                          construct_ok==hit, served==hit. (Correctness, no walk-skip.)
#   ACCEL_AUTHORITATIVE=1  serve-only: build *old_vers from cache and SKIP the walk. Gate: served==hit,
#                          reader completes, snapshot SUMs self-consistent. (The perf path; the D-0
#                          curve flattening itself is measured later in step 6.)
# Serving is gated on n_v_cols==0 (virtual-column rows are never cached, 4c-1) and, in mode 2, on the
# byte-compare matching (mismatch -> keep vanilla -> never a wrong row).
exec > /mnt/c/Users/USER/build_d4d2.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; TRX="$INNO/trx/trx0rec.cc"; VERS="$INNO/row/row0vers.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"

echo "=== preconditions (4d-1 must be installed) ==="
grep -q 'D-4 4d-1' "$VERS" || { echo "ERROR: row0vers not at 4d-1 -- run build_d4d1.sh first"; exit 1; }

echo "=== row0vers.cc: 4d-1 -> 4d-2 (serve-only gate at top + verify-serve in loop, idempotent) ==="
python3 - "$VERS" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
if 'D-4 4d-2' in s:
    print("row0vers already 4d-2"); sys.exit(0)
# 1) serve-only (mode 1): insert right after the hoisted top consult call.
key='&accel_clen, &accel_cextra);'
i=s.find(key)
if i<0: print("ERROR: top consult call not found"); sys.exit(2)
ins=i+len(key)
serve_gate='''
  /* D-4 4d-2 serve-only (mode 1): on HIT build *old_vers from the cached image and SKIP the walk
     (the perf path). Gated on n_v_cols==0 (virtual-column rows are never cached, 4c-1, so the skipped
     walk had no vrow to fill). MISS or mode!=1 -> fall through to the vanilla walk below. */
  if (accel_authoritative_mode() == 1 && accel_oc == 0 && accel_clen > accel_cextra &&
      index->table->n_v_cols == 0) {
    byte *accel_s = static_cast<byte *>(mem_heap_alloc(in_heap, accel_clen));
    memcpy(accel_s, accel_cbuf, accel_clen);
    *old_vers = accel_s + accel_cextra;
    *offsets = rec_get_offsets(*old_vers, index, *offsets, ULINT_UNDEFINED, UT_LOCATION_HERE, offset_heap);
    rec_offs_make_valid(*old_vers, index, *offsets);
    accel_note_serve();
    return DB_SUCCESS;
  }'''
s=s[:ins]+serve_gate+s[ins:]
# 2) verify-serve (mode 2): after the construct compare, replace *old_vers with the cache rec.
key2='accel_note_construct(accel_match);'
j=s.find(key2)
if j<0: print("ERROR: construct note not found"); sys.exit(3)
ins2=j+len(key2)
mode2='''
          /* D-4 4d-2 verify-serve (mode 2): byte-equality just proven, so replace *old_vers with the
             cache-built record -- exercises the serve path AND re-checks every served answer. Only when
             matched (mismatch -> keep vanilla, never a wrong row) and n_v_cols==0. */
          if (accel_authoritative_mode() == 2 && accel_match && index->table->n_v_cols == 0) {
            byte *accel_s2 = static_cast<byte *>(mem_heap_alloc(in_heap, accel_clen));
            memcpy(accel_s2, accel_cbuf, accel_clen);
            *old_vers = accel_s2 + accel_cextra;
            *offsets = rec_get_offsets(*old_vers, index, *offsets, ULINT_UNDEFINED, UT_LOCATION_HERE, offset_heap);
            rec_offs_make_valid(*old_vers, index, *offsets);
            accel_note_serve();
          }'''
s=s[:ins2]+mode2+s[ins2:]
open(p,'w').write(s); print("row0vers: 4d-2 (serve-only + verify-serve) installed")
PYEOF
grep -n 'D-4 4d-2' "$VERS"

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d4d2_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d4d2_build.log | head -40; exit 1; fi

run_one () {
  local mode="$1"; local tag="$2"
  local MLOG=/mnt/c/Users/USER/d4d2_${tag}_mysqld.log
  echo ""; echo "############## RUN: ACCEL_AUTHORITATIVE=$mode ($tag) ##############"
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=$mode "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=30 --rand-type=pareto run > /mnt/c/Users/USER/d4d2_${tag}_churn.log 2>&1 &
  local CH=$!
  { echo "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;"; echo "START TRANSACTION;"; echo "SELECT COUNT(*) FROM sbtest1;";
    for i in $(seq 1 13); do echo "DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;"; done; echo "COMMIT;"; } \
    | "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest > /mnt/c/Users/USER/d4d2_${tag}_reader.log 2>&1 &
  local RD=$!
  wait $CH; wait $RD
  grep -E 'transactions:' /mnt/c/Users/USER/d4d2_${tag}_churn.log
  echo "--- held-snapshot reader SUMs (must ALL be identical = snapshot invariant) ---"
  grep -E '^[0-9]+$' /mnt/c/Users/USER/d4d2_${tag}_reader.log | sort | uniq -c
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  echo "--- [accel] ($tag) ---"
  grep -E '\[accel\]' "$MLOG"
}

# mode 2 first (correctness gate: construct_BAD=0, construct_ok==hit, served==hit), then mode 1 (serve-only).
run_one 2 m2
run_one 1 m1
echo ""; echo "=== DONE ==="
