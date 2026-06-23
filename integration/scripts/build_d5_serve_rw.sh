#!/usr/bin/env bash
# D-5 serve re-confirm on oltp_read_write (the workload that exposed the cross-generation leak), now on
# top of the lineage-walk consult. Re-run the 4d-2 serve modes with the held-snapshot reader SUM oracle:
#   ACCEL_AUTHORITATIVE=2 verify-serve: walk + byte-compare, then serve the cache rec. Gate: construct_BAD=0,
#                                       construct_ok==hit, served==hit (every served answer == vanilla).
#   ACCEL_AUTHORITATIVE=1 serve-only:   build *old_vers from cache, SKIP the walk. Gate: served==hit,
#                                       reader SUMs all identical (snapshot invariant) AND == mode-2 SUM.
# mysqld already at 4d-2 + lineage walk (built by build_d5_diag6.sh); this only re-runs the serve modes.
exec > /mnt/c/Users/USER/build_d5_serve_rw.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; VERS="$INNO/row/row0vers.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
rm -f "$INNO/include/active_view_registry.h"
grep -q 'D-4 4d-2' "$VERS" || { echo "ERROR: row0vers not at 4d-2"; exit 1; }

echo "=== rebuild mysqld (lineage walk + 4d-2 serve already present; incremental) ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d5_serve_rw_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d5_serve_rw_build.log | head -40; exit 1; fi

run_one () {
  local mode="$1"; local tag="$2"
  local MLOG=/mnt/c/Users/USER/d5_serve_rw_${tag}_mysqld.log
  echo ""; echo "############## RUN: ACCEL_AUTHORITATIVE=$mode ($tag) on oltp_read_write ##############"
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  ACCEL_AUTHORITATIVE=$mode "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_read_write $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
  sysbench oltp_read_write $C --tables=1 --table-size=1000 --threads=16 --time=22 --rand-type=uniform run > /mnt/c/Users/USER/d5_serve_rw_${tag}_churn.log 2>&1 &
  local CH=$!
  { echo "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;"; echo "START TRANSACTION;"; echo "SELECT COUNT(*) FROM sbtest1;";
    for i in $(seq 1 9); do echo "DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;"; done; echo "COMMIT;"; } \
    | "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest > /mnt/c/Users/USER/d5_serve_rw_${tag}_reader.log 2>&1 &
  local RD=$!
  wait $CH; wait $RD
  grep -E 'transactions:' /mnt/c/Users/USER/d5_serve_rw_${tag}_churn.log
  echo "--- held-snapshot reader SUMs (must ALL be identical = snapshot invariant) ---"
  grep -E '^[0-9]+$' /mnt/c/Users/USER/d5_serve_rw_${tag}_reader.log | sort | uniq -c
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  echo "--- [accel] ($tag) ---"
  grep -E 'consult:|construct_BAD detail|view-registry' "$MLOG"
}

run_one 2 m2
run_one 1 m1
echo ""; echo "=== DONE (m2: construct_BAD=0 & served==hit; m1: served==hit & SUM==m2 SUM) ==="
