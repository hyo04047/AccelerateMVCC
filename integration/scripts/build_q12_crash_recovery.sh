#!/usr/bin/env bash
# Phase-3 dev-complete gate (audit dev_complete_must #1 / ⓣ17): crash-recovery + ephemeral-cache rebuild.
# The WHOLE ACID-safety story rests on the accel cache being non-authoritative + EPHEMERAL: on restart
# accel_init() constructs a FRESH empty Accelerate_mvcc and it repopulates from new undo via the drainer;
# InnoDB's own crash recovery rolls back transactions that were in-flight at the crash. This has literally
# never been exercised. Here we: populate under mode-2 (verify-serve) + GC, leave an UNCOMMITTED insert
# in-flight, kill -9 mysqld mid-churn, restart (crash recovery runs), assert (a) the in-flight insert was
# rolled back, and (b) a fresh mode-2 verify-serve workload over the rebuilt cache has construct_BAD=0
# (every served answer is byte-equal to the vanilla undo walk -- a rolled-back / wrong version is never
# served). Rebuilds mysqld first so it carries the current accel sources (incl. the Step 1+2 hardening).
#
# Repro: build_q12_crash_recovery.sh   (mysqld tree must already be at row0vers 4d-2; build_d4d2.sh installs it)
set -u
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; VERS="$INNO/row/row0vers.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
RESULTS=/mnt/c/Users/USER/projects/AccelerateMVCC/integration/results
exec > "$RESULTS/q12_crash_recovery.log" 2>&1
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
Q(){ "$MYSQL" --no-defaults -uroot -S "$SOCK" "$@"; }
mkdir -p "$RESULTS"

echo "=== copy accel sources + rebuild mysqld (picks up repo/include Step 1+2 edits via recompile) ==="
cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
grep -q 'D-4 4d-2' "$VERS" || { echo "ERROR: row0vers not at 4d-2 -- run build_d4d2.sh first"; exit 1; }
# Force accelerateMVCC.cpp to recompile so the edited repo/include headers are guaranteed picked up.
touch "/mnt/c/Users/USER/projects/AccelerateMVCC/include/accelerateMVCC.cpp"
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > "$RESULTS/q12_build.log" 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== BUILD ERRORS ==="; grep -iE 'error:|undefined reference' "$RESULTS/q12_build.log" | head -40; exit 1; fi

MLOG1="$RESULTS/q12_boot1_mysqld.log"
MLOG2="$RESULTS/q12_restart_mysqld.log"
COMMON=(--no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE"
        --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin
        --mysql-native-password=ON --innodb-buffer-pool-size=2G --innodb-flush-log-at-trx-commit=1)
wait_up(){ for i in $(seq 1 120); do Q -e "SELECT 1" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }

echo ""; echo "############## BOOT 1 (populate + in-flight uncommitted insert, mode-2 + GC) ##############"
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
ACCEL_AUTHORITATIVE=2 ACCEL_GC=1 "$MYSQLD" "${COMMON[@]}" > "$MLOG1" 2>&1 &
wait_up || { echo "ERROR: boot1 did not come up"; tail -20 "$MLOG1"; exit 1; }
Q -e "DROP DATABASE IF EXISTS sbtest; CREATE DATABASE sbtest; CREATE USER IF NOT EXISTS 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
# committed baseline: a sentinel row id we will INSERT (uncommitted) below must NOT exist after recovery.
echo "--- pre-crash: sentinel row 999999 count (expect 0) ---"; Q -N -e "SELECT COUNT(*) FROM sbtest.sbtest1 WHERE id=999999"

# Hold an UNCOMMITTED INSERT of a sentinel row open in a background session (never commits). A new id avoids
# any row-lock contention with the churn (which only touches id 1..1000). Crash recovery must roll it back.
( Q sbtest <<'SQL'
START TRANSACTION;
INSERT INTO sbtest1 (id, k, c, pad) VALUES (999999, 424242, 'crashtest-uncommitted', 'crashpad');
SELECT SLEEP(120);
SQL
) > "$RESULTS/q12_inflight.log" 2>&1 &
sleep 1
echo "--- in-flight session sees its own uncommitted row (expect 1) ---"
Q sbtest -N -e "START TRANSACTION; SELECT COUNT(*) FROM sbtest1 WHERE id=999999; COMMIT;"  # other session: expect 0 (RR, not visible)

# churn to generate undo + populate the cache, then crash mid-flight (in-flight trx for recovery to roll back).
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=30 --rand-type=pareto run > "$RESULTS/q12_boot1_churn.log" 2>&1 &
CH=$!
sleep 8
echo "--- pre-crash [accel] populate evidence ---"; grep -E '\[accel\] drained=' "$MLOG1" | tail -1
echo "############## CRASH: kill -9 mysqld mid-churn ##############"
pkill -9 -f "$MYSQLD"; pkill -9 -f sysbench 2>/dev/null; wait $CH 2>/dev/null; sleep 3

echo ""; echo "############## RESTART (InnoDB crash recovery; SAME datadir, NO --initialize) ##############"
ACCEL_AUTHORITATIVE=2 ACCEL_GC=1 "$MYSQLD" "${COMMON[@]}" > "$MLOG2" 2>&1 &
wait_up || { echo "ERROR: restart did not come up (crash recovery failed?)"; tail -40 "$MLOG2"; exit 1; }
echo "--- crash recovery completed, server is up ---"
grep -iE 'crash recovery|rollback of|rolling back|Recovered|Starting|Apply batch completed' "$MLOG2" | head -20
echo "--- POST-RECOVERY: sentinel row 999999 count (MUST be 0 = uncommitted insert rolled back) ---"
ROLLED=$(Q -N -e "SELECT COUNT(*) FROM sbtest.sbtest1 WHERE id=999999")
echo "sentinel_count=$ROLLED  (0 = rolled back OK; 1 = LEAK)"
echo "--- table sanity (row count ~1000) ---"; Q -N -e "SELECT COUNT(*) FROM sbtest.sbtest1"

echo ""; echo "############## POST-RECOVERY mode-2 verify-serve workload (rebuilt ephemeral cache) ##############"
# held REPEATABLE-READ snapshot reader doing repeated deep SUMs while churn deepens chains -> consult HITs ->
# verify-serve byte-compares every HIT against the vanilla walk -> construct_BAD must be 0 on the rebuilt cache.
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=25 --rand-type=pareto run > "$RESULTS/q12_post_churn.log" 2>&1 &
CH2=$!
( echo "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;"; echo "START TRANSACTION;"; echo "SELECT COUNT(*) FROM sbtest1;";
  for i in $(seq 1 10); do echo "DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) AS s FROM sbtest1;"; done; echo "COMMIT;" ) \
  | Q sbtest > "$RESULTS/q12_post_reader.log" 2>&1 &
RD=$!
wait $CH2; wait $RD
echo "--- held-snapshot reader SUMs (must ALL be identical = snapshot invariant on rebuilt cache) ---"
grep -E '^[0-9]+$' "$RESULTS/q12_post_reader.log" | sort | uniq -c
Q -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null

echo ""; echo "=== [accel] consult on the RESTARTED (rebuilt-cache) server ==="
grep -E '\[accel\] consult:' "$MLOG2"
echo ""; echo "=== VERDICT ==="
BAD=$(grep -E '\[accel\] consult:' "$MLOG2" | grep -oE 'construct_BAD=[0-9]+' | grep -oE '[0-9]+' | tail -1)
SRV=$(grep -E '\[accel\] consult:' "$MLOG2" | grep -oE 'served=[0-9]+' | grep -oE '[0-9]+' | tail -1)
HIT=$(grep -E '\[accel\] consult:' "$MLOG2" | grep -oE 'hit=[0-9]+' | grep -oE '[0-9]+' | head -1)
echo "rolled_back_sentinel=$([ "${ROLLED:-1}" = "0" ] && echo PASS || echo FAIL)  rebuilt_cache_hit=${HIT:-?} served=${SRV:-?} construct_BAD=${BAD:-?}"
if [ "${ROLLED:-1}" = "0" ] && [ "${BAD:-1}" = "0" ]; then echo "RESULT: PASS (crash recovery + ephemeral rebuild safe: rollback honored, served==vanilla)"; else echo "RESULT: FAIL"; fi
echo "=== DONE ==="
