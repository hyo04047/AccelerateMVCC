#!/usr/bin/env bash
# Stage D-1b-3a: compile + link the real AccelerateMVCC index (+ Kuku) into innobase/mysqld.
# accel_hook now includes accelerateMVCC.h and constructs a global instance (record_count=0,
# BG GC NOT started). consume() stays count-only -- this increment only proves build/link/boot.
exec > /mnt/c/Users/USER/build_d1b3a.log 2>&1
REPO="/mnt/c/Users/USER/projects/AccelerateMVCC"
SRCREPO="$REPO/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; CML="$INNO/CMakeLists.txt"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"

echo "=== copy facade + ring into MySQL tree ==="
cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"

echo "=== verify prior patches present ==="
grep -q 'accel/accel_hook.cc' "$CML" && echo "cmake accel_hook src OK" || echo "WARN missing accel_hook src"
grep -q 'accel_on_undo' "$INNO/trx/trx0rec.cc" && echo "trx0rec hook OK" || echo "WARN trx0rec hook missing"
grep -q 'accel_init();' "$INNO/srv/srv0start.cc" && echo "srv lifecycle OK" || echo "WARN srv lifecycle missing"

echo "=== patch CMakeLists: add accelerator + kuku sources [idempotent] ==="
if grep -q 'accelerateMVCC.cpp' "$CML"; then echo "sources already added"; else
  sed -i "s@^  accel/accel_hook.cc@  accel/accel_hook.cc\n  $REPO/include/accelerateMVCC.cpp\n  $REPO/include/interval_list.cpp\n  $REPO/include/epoch_table.cpp\n  $REPO/include/trxManager.cpp\n  $REPO/Kuku/src/kuku/kuku.cpp@" "$CML"
fi
grep -n 'accelerateMVCC.cpp\|kuku/kuku.cpp' "$CML"

echo "=== append include dirs + -w on our sources [idempotent] ==="
if grep -q 'ACCEL_INTEGRATION_BLOCK' "$CML"; then echo "include block already present"; else
cat >> "$CML" <<EOF

# ACCEL_INTEGRATION_BLOCK (Stage D-1b-3a)
target_include_directories(innobase PRIVATE
  $REPO/include
  $REPO/Kuku/src
  $HOME/acc-build/Kuku/src)
set_source_files_properties(
  $REPO/include/accelerateMVCC.cpp
  $REPO/include/interval_list.cpp
  $REPO/include/epoch_table.cpp
  $REPO/include/trxManager.cpp
  $INNO/accel/accel_hook.cc
  PROPERTIES COMPILE_OPTIONS "-Wall;-Wextra")
set_source_files_properties(
  $REPO/Kuku/src/kuku/kuku.cpp
  PROPERTIES COMPILE_OPTIONS "-w")
EOF
fi
tail -16 "$CML"

echo "=== add Kuku blake2 C sources [idempotent] ==="
if grep -q 'blake2xb.c' "$CML"; then echo "blake2 already added"; else
  sed -i "s@^  $REPO/Kuku/src/kuku/kuku.cpp@  $REPO/Kuku/src/kuku/kuku.cpp\n  $REPO/Kuku/src/kuku/internal/blake2b.c\n  $REPO/Kuku/src/kuku/internal/blake2xb.c@" "$CML"
fi
grep -n 'blake2' "$CML"
if grep -q 'ACCEL_BLAKE2_W' "$CML"; then echo "blake2 -w already present"; else
cat >> "$CML" <<EOF

# ACCEL_BLAKE2_W (Stage D-1b-3a)
set_source_files_properties(
  $REPO/Kuku/src/kuku/internal/blake2b.c
  $REPO/Kuku/src/kuku/internal/blake2xb.c
  PROPERTIES COMPILE_OPTIONS "-w")
EOF
fi

echo "=== reconfigure + build mysqld ==="
cmake -S "$MS" -B "$BUILD" > /mnt/c/Users/USER/d1b3a_cfg.log 2>&1; echo "cfg rc=$?"
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d1b3a_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== BUILD ERRORS ==="; grep -iE 'error:|Error' /mnt/c/Users/USER/d1b3a_build.log | head -40; echo ABORT; exit 1; fi

echo "=== boot + churn (accelerator constructed, consume count-only) ==="
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" 2>&1 | tail -1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 \
  > /mnt/c/Users/USER/d1b3a_mysqld.log 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT VERSION();" || { echo NOTREADY; tail -30 /mnt/c/Users/USER/d1b3a_mysqld.log; exit 1; }
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
echo "--- churn 30s ---"
sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=30 --rand-type=pareto run 2>&1 | grep -E 'transactions:|queries:'
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null

echo "=== [accel] EVIDENCE (accelerator constructed + drainer + clean shutdown) ==="
grep -E '\[accel\]' /mnt/c/Users/USER/d1b3a_mysqld.log
echo "=== DONE ==="
