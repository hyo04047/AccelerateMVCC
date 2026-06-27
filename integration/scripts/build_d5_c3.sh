#!/usr/bin/env bash
# D-5 C3-b: the 1-in-N walk-audit tripwire for mode-1 serve-only. mode-1 normally serves the cache and SKIPS
# the walk (no in-run self-check). The audit samples 1-in-N mode-1 HITs: for a sampled HIT it does NOT skip
# the walk -- it falls through so the existing 4d-1 shadow byte-compare runs (accel_note_construct), and it
# serves the VANILLA answer (observe-only). Non-sampled HITs serve the cache + skip the walk (the perf path).
# This script patches row0vers.cc (4d-2 -> C3) and runs three gates:
#   A. NORMAL  (mode-1 + GC + AUDIT_N): construct_BAD==0 (audit clean) AND audited>0 AND served>0.
#   B. NEG CTRL(force a cross-row serve via PK collision + NO_FULL_PK): construct_BAD>0 (the audit TRIPS).
#   C. REFUSE  (mode-1 + AUDIT_N=0): "REFUSING mode-1 ... downgrading to shadow" AND served==0.
exec > /mnt/c/Users/USER/build_d5_c3.log 2>&1
SRCREPO="/mnt/c/Users/USER/projects/AccelerateMVCC/integration/innodb"
MS="$HOME/mysql-server"; INNO="$MS/storage/innobase"; VERS="$INNO/row/row0vers.cc"
BUILD="$HOME/mysql-build"; BIN="$BUILD/runtime_output_directory"
MYSQLD="$BIN/mysqld"; MYSQL="$BIN/mysql"; DATA="$HOME/mysql-data"; SOCK="$HOME/mysql.sock"; PORT=3309; SHARE="$BUILD/share"
C="--db-driver=mysql --mysql-host=127.0.0.1 --mysql-port=$PORT --mysql-user=sb --mysql-password=sb --mysql-db=sbtest"

cp "$SRCREPO/accel_hook.h" "$INNO/include/accel_hook.h"
cp "$SRCREPO/accel_ring.h" "$INNO/include/accel_ring.h"
cp "$SRCREPO/accel_hook.cc" "$INNO/accel/accel_hook.cc"

echo "=== preconditions (row0vers must be at 4d-2) ==="
grep -q 'D-4 4d-2' "$VERS" || { echo "ERROR: row0vers not at 4d-2 -- run build_d4d2.sh first"; exit 1; }

echo "=== row0vers.cc: 4d-2 -> C3 (gate the mode-1 serve on !accel_audit; idempotent) ==="
python3 - "$VERS" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
if 'D-5 C3-b' in s:
    print("row0vers already C3-b"); sys.exit(0)
gate='''  if (accel_authoritative_mode() == 1 && accel_oc == 0 && accel_clen > accel_cextra &&
      index->table->n_v_cols == 0) {'''
i=s.find(gate)
if i<0: print("ERROR: mode-1 serve gate not found"); sys.exit(2)
new='''  /* D-5 C3-b walk-audit: 1-in-N mode-1 HITs are AUDITED -- do NOT skip the walk; fall through so the
     in-loop shadow byte-compare runs against vanilla's walked answer (observe-only: serve vanilla). The
     decision must precede the serve gate; accel_audit_should() advances the sample clock only on mode-1 HITs. */
  int accel_audit = (accel_authoritative_mode() == 1 && accel_oc == 0) ? accel_audit_should() : 0;
  if (accel_authoritative_mode() == 1 && accel_oc == 0 && accel_clen > accel_cextra &&
      index->table->n_v_cols == 0 && !accel_audit) {'''
s=s.replace(gate,new,1)
open(p,'w').write(s); print("row0vers: C3-b (mode-1 serve gated on !accel_audit) installed")
PYEOF
grep -n 'D-5 C3-b' "$VERS"

echo "=== rebuild mysqld ==="
cmake --build "$BUILD" --target mysqld -j"$(nproc)" > /mnt/c/Users/USER/d5_c3_build.log 2>&1
brc=$?; echo "build rc=$brc"
if [ $brc -ne 0 ]; then echo "=== ERRORS ==="; grep -iE 'error:|undefined reference' /mnt/c/Users/USER/d5_c3_build.log | head -40; exit 1; fi

run_one() {  # $1=label  $2=threads  $3=time  $4...=extra env (KEY=VAL)
  local label="$1"; local threads="$2"; local time="$3"; shift 3
  local MLOG=/mnt/c/Users/USER/d5_c3_$label.log
  pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2
  echo ""; echo "--- RUN $label: oltp_read_write threads=$threads time=$time env: $* ---"
  env "$@" "$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
    --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
    --max-connections=512 --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > "$MLOG" 2>&1 &
  for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
  sysbench oltp_read_write $C --tables=4 --table-size=2000 --threads=$threads --time=$time --rand-type=uniform run 2>&1 | grep -E 'transactions:'
  "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null
  for i in $(seq 1 25); do pgrep -f "$MYSQLD" >/dev/null 2>&1 || break; sleep 1; done
  if pgrep -f "$MYSQLD" >/dev/null 2>&1; then echo "  SHUTDOWN HANG"; pkill -9 -f "$MYSQLD" 2>/dev/null; else echo "  shutdown clean"; fi
  grep -E '\[accel\] consult:|\[accel\] audit:|\[accel\] gc: enabled|REFUSING mode-1' "$MLOG"
}

# fresh datadir + prepare once.
pkill -9 -f "$MYSQLD" 2>/dev/null; sleep 2; rm -rf "$DATA"; mkdir -p "$DATA"
"$MYSQLD" --no-defaults --user=root --initialize-insecure --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" >/dev/null 2>&1
"$MYSQLD" --no-defaults --user=root --basedir="$BUILD" --datadir="$DATA" --lc-messages-dir="$SHARE" \
  --socket="$SOCK" --port=$PORT --bind-address=127.0.0.1 --mysqlx=0 --skip-log-bin --mysql-native-password=ON \
  --innodb-buffer-pool-size=4G --innodb-flush-log-at-trx-commit=0 > /mnt/c/Users/USER/d5_c3_init.log 2>&1 &
for i in $(seq 1 90); do "$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SELECT 1" >/dev/null 2>&1 && break; sleep 1; done
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "CREATE DATABASE sbtest; CREATE USER 'sb'@'%' IDENTIFIED WITH mysql_native_password BY 'sb'; GRANT ALL ON *.* TO 'sb'@'%';"
sysbench oltp_read_write $C --tables=4 --table-size=2000 prepare 2>&1 | tail -1
"$MYSQL" --no-defaults -uroot -S "$SOCK" -e "SHUTDOWN;" 2>/dev/null; sleep 3; pkill -9 -f "$MYSQLD" 2>/dev/null

echo ""; echo "=== A. NORMAL: mode-1 + GC + audit (gate: construct_BAD=0, audited>0, served>0, retire windowed+dummy>0) ==="
run_one A_normal 32 30 ACCEL_AUTHORITATIVE=1 ACCEL_GC=1 ACCEL_AUDIT_N=32
echo ""; echo "=== B. NEG CONTROL: force cross-row serve (4-bit PK mask + NO_FULL_PK), audit must TRIP (construct_BAD>0) ==="
run_one B_negctl 16 20 ACCEL_AUTHORITATIVE=1 ACCEL_GC=1 ACCEL_AUDIT_N=2 ACCEL_PK_MASK_BITS=4 ACCEL_NO_FULL_PK=1
echo ""; echo "=== C. REFUSE: mode-1 + AUDIT_N=0 must downgrade to shadow (served=0, REFUSING log) ==="
run_one C_refuse 8 15 ACCEL_AUTHORITATIVE=1 ACCEL_GC=1 ACCEL_AUDIT_N=0
echo ""; echo "=== DONE ==="
