#!/usr/bin/env bash
# D-5 ⑤a-2 step 1: lifecycle scaffolding for the integration deadzone-GC driver.
# accel_hook.cc now starts a SEPARATE leaf-domain GC driver thread (g_gc / gc_loop) in accel_init and,
# critically, stops+joins it in accel_shutdown BEFORE delete g_accel (review must-fix 1). The GC body is
# EMPTY in this step (just sleeps) -- this run only proves: (a) it builds + links into mysqld, (b) the GC
# thread starts alongside the drainer + the shadow consult, (c) shutdown is CLEAN and does NOT hang
# (g_gc joins promptly on g_gc_stop). No sweeping yet; serve OFF (auth_mode=0). Only accel_hook.cc changed,
# so row0vers.cc is left at its current (diag6) patch level -- not touched here.
exec > /mnt/c/Users/USER/build_d5_a2s1.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
MLOG=/mnt/c/Users/USER/d5_a2s1_mysqld.log

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
rm -f "$INNO/include/active_view_registry.h"   # resolved via -I repo/include (avoid a duplicate copy)

echo "=== rebuild mysqld (incremental: accel_hook.cc only) ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d5_a2s1_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d5_a2s1_build.log | head -40; exit 1; fi

pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
echo "=== short churn (drainer + GC thread + shadow consult coexist) ==="
sysbench oltp_read_write $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
sysbench oltp_read_write $C --tables=1 --table-size=1000 --threads=8 --time=10 --rand-type=uniform run > /mnt/c/Users/USER/d5_a2s1_churn.log 2>&1
grep -E 'transactions:' /mnt/c/Users/USER/d5_a2s1_churn.log

echo "=== clean shutdown test (must NOT hang on the GC join) ==="
t0=$(date +%s)
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null
# Give accel_shutdown time to stop+join the GC + drainer and exit. If the GC join deadlocked, mysqld
# stays alive and the [accel] shutdown line never prints.
for i in $(seq 1 20); do pgrep -f "$MYSQLD" >/dev/null 2>&1 || break; sleep 1; done
t1=$(date +%s)
if pgrep -f "$MYSQLD" >/dev/null 2>&1; then
  echo "SHUTDOWN HANG: mysqld still alive $((t1-t0))s after SHUTDOWN -> GC join likely deadlocked"
  pkill -9 -f "$MYSQLD" 2>/dev/null
else
  echo "shutdown clean in ~$((t1-t0))s"
fi

echo "=== [accel] lifecycle lines (init must show drainer started; shutdown must print = clean) ==="
grep -E '\[accel\] init:|\[accel\] shutdown:|\[accel\] consult:' "$MLOG"
echo "=== DONE ==="
