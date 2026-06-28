#!/usr/bin/env bash
# Phase 2 / ⓝ5: build a full mysqld with AddressSanitizer (-DWITH_ASAN=ON) and STRESS the integration path
# under it -- hook-under-latch || off-latch drainer || consult || held analytic reader (serve) || deadzone
# GC || clean teardown -- then scan the server log for any ASan report. Until now sanitizer evidence was
# standalone only; this is the gold-standard integration check. Result: CLEAN (no UAF/overflow/SEGV), with
# 251k consults served construct_BAD=0 and GC reclaiming, so the gate is not hollow. mysql CLIENT reuses the
# existing non-ASan build (protocol-compatible). See docs/phase2-q3-llt.md ⓝ5.
#
# Prereq: row0vers at 4d-2 (build_d4d2.sh) + the accel sources in the InnoDB tree.
set -u
SRC=$HOME/mysql-server; B=$HOME/mysql-build-asan
BIN="$B/runtime_output_directory"; MYSQLD="$BIN/mysqld"
MYSQL="$HOME/mysql-build/runtime_output_directory/mysql"
DATA="$HOME/mysql-data-asan"; SOCK="$HOME/mysql-asan.sock"; PORT=3310; SHARE="$B/share"
MLOG=/mnt/c/Users/USER/asan_mysqld.log
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
export ASAN_OPTIONS="detect_leaks=0:abort_on_error=0:halt_on_error=0:print_stats=0:handle_segv=1:detect_stack_use_after_return=1"

if [ ! -x "$MYSQLD" ]; then
  echo "=== build ASan mysqld (one-time, ~15m) ==="
  cmake -S "$SRC" -B "$B" -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_C_COMPILER=/usr/bin/gcc-13 -DCMAKE_CXX_COMPILER=/usr/bin/g++-13 \
    -DWITH_BOOST=/root/mysql-boost -DDOWNLOAD_BOOST=1 -DWITH_UNIT_TESTS=0 -DWITH_ASAN=ON
  cmake --build "$B" --target mysqld -j"$(nproc)" || { echo "ASan build FAILED"; exit 1; }
fi

pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$B" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
ACCEL_GC=1 ACCEL_AUTHORITATIVE=2 ACCEL_AUDIT_N=1024 "$MYSQLD" --no-defaults --user=root --basedir="$B" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=64M --innodb-flush-log-at-trx-commit=0 --innodb-purge-threads=4 > "$MLOG" 2>&1 &
for i in $(seq 1 180); do Q -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
Q -e "SELECT 1" >/dev/null 2>&1 || { echo "ASan mysqld failed to start"; tail -30 "$MLOG"; exit 1; }
Q -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench oltp_read_write $C --tables=1 --table-size=1000 prepare >/dev/null 2>&1
( Q sbtest <<'SQL'
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION WITH CONSISTENT SNAPSHOT;
SELECT SUM(k+LENGTH(c)) FROM sbtest1; SELECT SLEEP(8);
SELECT SUM(k+LENGTH(c)) FROM sbtest1; SELECT SLEEP(8);
SELECT SUM(k+LENGTH(c)) FROM sbtest1; SELECT SLEEP(8);
SELECT SUM(k+LENGTH(c)) FROM sbtest1; SELECT SLEEP(8);
SELECT SUM(k+LENGTH(c)) FROM sbtest1; COMMIT;
SQL
) >/dev/null 2>&1 &
HELD=$!; sleep 1
sysbench oltp_read_write $C --tables=1 --table-size=1000 --threads=8 --time=44 --rand-type=pareto run >/dev/null 2>&1 &
CH=$!
sysbench oltp_read_only $C --tables=1 --table-size=1000 --threads=4 --time=44 --rand-type=pareto --skip-trx=off run >/dev/null 2>&1 &
RD=$!
wait $CH; wait $RD; wait $HELD
Q -e "SHUTDOWN;" 2>/dev/null; sleep 8; pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2
echo "--- [accel] consult ---"; grep -E '\[accel\] consult:' "$MLOG" | tail -1
echo "--- [accel] gc ---"; grep -E '\[accel\] gc: enabled' "$MLOG" | tail -1
if grep -qE 'AddressSanitizer|use-after-free|heap-buffer-overflow|SEGV|runtime error' "$MLOG"; then
  echo "!!! ASAN FINDINGS:"; grep -nE 'AddressSanitizer|use-after-free|buffer-overflow|SEGV|runtime error|SUMMARY:' "$MLOG" | head -40
else
  echo "CLEAN -- no AddressSanitizer reports."
fi
echo "=== DONE ==="
