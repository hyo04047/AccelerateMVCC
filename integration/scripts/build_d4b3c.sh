#!/usr/bin/env bash
# D-4 increment 4b-3c: adversarial shadow matrix. Rebuilds mysqld with the 4b-3c test toggles, then
# runs the held-snapshot-reader-during-churn harness under four scenarios, each a fresh boot:
#   (A) 60s LLT        -> deep chains; gate hit_MISMATCH=0
#   (B) rollback churn -> rolled-back versions must never be served wrong; gate hit_MISMATCH=0
#   (C) forced pk_hash collision, full-PK ON  -> full-PK defends; gate hit_MISMATCH=0
#   (D) forced collision, full-PK OFF (NEG CONTROL) -> must show hit_MISMATCH>0 (proves the test bites)
# Requires build_d4b3b.sh to have applied the row0vers/read0types patches (idempotent; still present).
exec > /mnt/c/Users/USER/build_d4b3c.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
MLOG=/mnt/c/Users/USER/d4b3c_mysqld.log
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"
echo "=== rebuild mysqld (consult require_full_pk + facade toggles) ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d4b3c_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d4b3c_build.log | head -40; exit 1; fi

boot() {  # $1 = env assignments (e.g. "ACCEL_PK_MASK_BITS=6")
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
  "$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
  env $1 "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 prepare 2>&1 | tail -1
}
hs_reader_churn() {  # $1 = churn seconds, $2 = reader rescans
  sysbench oltp_update_non_index $C --tables=1 --table-size=1000 --threads=8 --time=$1 --rand-type=pareto run > /mnt/c/Users/USER/d4b3c_churn.log 2>&1 &
  local CH=$!
  { echo "SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;"; echo "START TRANSACTION;";
    echo "SELECT COUNT(*) FROM sbtest1;";
    for i in $(seq 1 $2); do echo "DO SLEEP(2); SELECT SUM(k + LENGTH(c) + LENGTH(pad)) FROM sbtest1;"; done;
    echo "COMMIT;"; } | "$MYSQL" --no-defaults -uroot -S "$SOCK" sbtest > /mnt/c/Users/USER/d4b3c_reader.log 2>&1 &
  local RD=$!
  wait $CH; wait $RD
}
finish() {  # $1 = label
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 4; pkill -9 -f "$MYSQLD" 2>/dev/null
  echo ">>> SCENARIO $1"; grep -E '\[accel\] consult|\[accel\] shutdown' "$MLOG"
}

echo "############ (A) 60s LLT ############"
boot ""; hs_reader_churn 60 30; finish "A-60s-LLT"

echo "############ (B) rollback churn ############"
boot ""
# rolled-back updates (one session, deterministic ids) concurrent with committed churn + reader
{ echo "USE sbtest;"; for i in $(seq 1 1500); do echo "BEGIN; UPDATE sbtest1 SET k=k+1 WHERE id=$(( (i*7) % 1000 + 1 )); ROLLBACK;"; done; } | "$MYSQL" --no-defaults -uroot -S "$SOCK" > /mnt/c/Users/USER/d4b3c_rollback.log 2>&1 &
RB=$!
hs_reader_churn 30 14
wait $RB
finish "B-rollback"

echo "############ (C) forced collision, full-PK ON ############"
boot "ACCEL_PK_MASK_BITS=6"; hs_reader_churn 30 14; finish "C-collision-fullPK-ON"

echo "############ (D) forced collision, full-PK OFF (NEGATIVE CONTROL) ############"
boot "ACCEL_PK_MASK_BITS=6 ACCEL_NO_FULL_PK=1"; hs_reader_churn 30 14; finish "D-collision-fullPK-OFF-negctl"
echo "=== DONE ==="
