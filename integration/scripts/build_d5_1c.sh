#!/usr/bin/env bash
# D-5 5-1c-2: integration shadow for the active-view registry, GC still OFF. (a) Count EVERY
# MVCC::view_open at the top (before the reuse/mutex branch) and compare to the publish count -- if
# open_calls ~= published then no open path is missed (the superset's ADD-reliability: no live view is
# silently omitted). (b) Push a monotonic InnoDB clock (max view begin id) and confirm it advances (M4
# prep: the standalone GC clock never moves in-integration). Builds on 5-1b's view_open/close publish
# hooks (already in the tree). Nothing consumes the registry yet (deadzone build = generate_dead_zone_
# from_cuts, proven standalone in 5-1c-1; GC turns on in 5-2).
exec > /mnt/c/Users/USER/build_d5_1c.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
REPOINC="/mnt/c/Users/USER/projects/AccelerateMVCC/include"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; READ="$INNO/read/read0read.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
# active_view_registry.h is NOT vendored into the tree include: accel_hook.cc resolves it via
# -I repo/include (the SAME physical file epoch_table.h includes), else #pragma once sees two copies
# -> mvcc::ViewCut redefinition. Remove any stale copy a previous 5-1b run left behind.
rm -f "$INNO/include/active_view_registry.h"

echo "=== read0read.cc: precondition (5-1b publish hooks present) + add view_open-top counter (idempotent) ==="
grep -q 'accel_publish_view_open' "$READ" || { echo "ERROR: 5-1b publish hooks missing -- run build_d5_1b.sh first"; exit 1; }
python3 - "$READ" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
if 'accel_note_view_open' in s:
    print("read0read already has view_open-top counter"); sys.exit(0)
a='void MVCC::view_open(ReadView *&view, trx_t *trx) {\n  ut_ad(!srv_read_only_mode);'
b='void MVCC::view_open(ReadView *&view, trx_t *trx) {\n  ut_ad(!srv_read_only_mode);\n  accel_note_view_open();  /* D-5 5-1c: count every open path */'
assert a in s, "view_open top anchor not found"
s=s.replace(a,b,1)
open(p,'w').write(s); print("read0read: view_open-top counter installed")
PYEOF
grep -n 'accel_note_view_open' "$READ"

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d5_1c_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d5_1c_build.log | head -40; exit 1; fi

MLOG=/mnt/c/Users/USER/d5_1c_mysqld.log
echo "=== boot + OLTP churn (publish ON) ==="
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench oltp_read_write $C --tables=4 --table-size=10000 prepare 2>&1 | tail -1
# OLTP churn (each txn opens a read-view) + a concurrent held-snapshot reader (long-lived view).
sysbench oltp_read_write $C --tables=4 --table-size=10000 --threads=32 --time=25 --rand-type=uniform run > /mnt/c/Users/USER/d5_1c_oltp.log 2>&1 &
CH=$!
{ echo "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;"; echo "START TRANSACTION WITH CONSISTENT SNAPSHOT;";
  for i in $(seq 1 12); do echo "DO SLEEP(2); SELECT COUNT(*) FROM sbtest1;"; done; echo "COMMIT;"; } \
  | "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest > /mnt/c/Users/USER/d5_1c_reader.log 2>&1 &
RD=$!
wait $CH; wait $RD
grep -E 'transactions:' /mnt/c/Users/USER/d5_1c_oltp.log
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
echo "=== [accel] (gate: open_calls ~= published [no missed open path], clock advanced from 0) ==="
grep -E '\[accel\]' "$MLOG"
echo "=== DONE ==="
