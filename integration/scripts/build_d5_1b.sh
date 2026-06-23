#!/usr/bin/env bash
# D-5 5-1b: wire the active read-view registry (signal B) into InnoDB's read-view lifecycle, GC still
# OFF, and MEASURE the publish cost. MVCC::view_open pushes {low_limit_id, up_limit_id} to the leaf-
# domain registry (both the reuse fast-path and the mutex path, piggybacking the trx_sys mutex it
# already holds); MVCC::view_close best-effort unpublishes. Run OLTP with ACCEL_PUBLISH=1 vs =0 and
# compare throughput -- the open question from the cheap-collection research (does the per-view_open
# publish regress OLTP?). Nothing consumes the registry yet (deadzone/serve = 5-1c+), so this is pure
# wiring + cost.
exec > /mnt/c/Users/USER/build_d5_1b.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
REPOINC="/mnt/c/Users/USER/projects/AccelerateMVCC/include"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; READ="$INNO/read/read0read.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
cp "$REPOINC/active_view_registry.h" "$INNO/include/active_view_registry.h"   # D-5: header accel_hook.cc includes

echo "=== read0read.cc: push view_open/view_close to the registry (idempotent) ==="
python3 - "$READ" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
if 'accel_publish_view_open' in s:
    print("read0read already wired"); sys.exit(0)
# 1) include the leaf-domain facade
s=s.replace('#include "srv0srv.h"\n#include "trx0sys.h"\n',
            '#include "srv0srv.h"\n#include "trx0sys.h"\n#include "accel_hook.h"  // D-5 5-1b\n', 1)
# 2) reuse fast-path: publish before the early return (mutex-free path; lock-free push is fine)
reuse_a='      if (view->m_low_limit_id == trx_sys_get_next_trx_id_or_no()) {\n        return;\n      } else {'
reuse_b='''      if (view->m_low_limit_id == trx_sys_get_next_trx_id_or_no()) {
        accel_publish_view_open(view->low_limit_id(), view->up_limit_id());  /* D-5 5-1b */
        return;
      } else {'''
assert reuse_a in s, "reuse fast-path anchor not found"
s=s.replace(reuse_a, reuse_b, 1)
# 3) mutex path: publish right after the view is spliced into m_views (piggyback the held mutex)
s=s.replace('    UT_LIST_ADD_FIRST(m_views, view);\n',
            '    UT_LIST_ADD_FIRST(m_views, view);\n\n    accel_publish_view_open(view->low_limit_id(), view->up_limit_id());  /* D-5 5-1b: piggyback the mutex */\n', 1)
# 4) view_close: best-effort unpublish at the top (covers both AC-NL-RO and full-close paths)
close_a='void MVCC::view_close(ReadView *&view, bool own_mutex) {\n  uintptr_t p = reinterpret_cast<uintptr_t>(view);'
close_b='void MVCC::view_close(ReadView *&view, bool own_mutex) {\n  accel_publish_view_close();  /* D-5 5-1b: best-effort unpublish */\n  uintptr_t p = reinterpret_cast<uintptr_t>(view);'
assert close_a in s, "view_close anchor not found"
s=s.replace(close_a, close_b, 1)
open(p,'w').write(s); print("read0read: view_open(reuse+mutex) + view_close push installed")
PYEOF
grep -n 'accel_publish_view' "$READ"

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d5_1b_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d5_1b_build.log | head -40; exit 1; fi

run_oltp () {
  local pub="$1"; local tag="$2"
  local MLOG=/mnt/c/Users/USER/d5_1b_${tag}_mysqld.log
  echo ""; echo "############## ACCEL_PUBLISH=$pub ($tag) ##############"
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_PUBLISH=$pub "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_read_write $C --tables=4 --table-size=10000 prepare 2>&1 | tail -1
  # warm + two timed runs at high concurrency (view_open-heavy) -> report tps
  for rep in 1 2; do
    sysbench oltp_read_write $C --tables=4 --table-size=10000 --threads=32 --time=30 --rand-type=uniform run 2>&1 \
      | grep -E 'transactions:|queries:' | sed "s/^/[$tag rep$rep] /"
  done
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  echo "--- [accel] ($tag) ---"; grep -E 'view-registry|init:' "$MLOG"
}

run_oltp 1 pub_on
run_oltp 0 pub_off
echo ""; echo "=== DONE (compare pub_on vs pub_off tps) ==="
