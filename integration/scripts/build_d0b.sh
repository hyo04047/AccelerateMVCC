#!/usr/bin/env bash
# Stage D-0b: configure + build vanilla MySQL 8.4 (gcc-13, RelWithDebInfo, ninja).
exec > /mnt/c/Users/USER/build_d0b.log 2>&1
apt-get install -y ninja-build 2>&1 | tail -1
SRC="$HOME/mysql-server"
BUILD="$HOME/mysql-build"
BOOST="$HOME/mysql-boost"
rm -rf "$BUILD"; mkdir -p "$BUILD"; cd "$BUILD" || exit 1
echo "=== configure (gcc-13, RelWithDebInfo, ninja) ==="
cmake "$SRC" -GNinja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER=gcc-13 -DCMAKE_CXX_COMPILER=g++-13 \
  -DDOWNLOAD_BOOST=1 -DWITH_BOOST="$BOOST" \
  -DWITH_UNIT_TESTS=0 -DWITH_ROUTER=0 \
  -DCMAKE_INSTALL_PREFIX="$HOME/mysql-inst" \
  > /mnt/c/Users/USER/d0b_configure.log 2>&1
crc=$?; echo "configure rc=$crc"; tail -6 /mnt/c/Users/USER/d0b_configure.log
if [ $crc -ne 0 ]; then echo "=== CONFIGURE ERRORS ==="; grep -iE 'error|CMake Error' /mnt/c/Users/USER/d0b_configure.log | head -20; echo "ABORT"; exit 1; fi
echo "=== build (ninja, -j$(nproc)) ==="
/usr/bin/time -v ninja > /mnt/c/Users/USER/d0b_build.log 2>&1
brc=$?; echo "build rc=$brc"
echo "--- error lines (if any) ---"; grep -iE 'error:' /mnt/c/Users/USER/d0b_build.log | head -25
echo "--- build time ---"; grep -E 'Elapsed \(wall|Maximum resident' /mnt/c/Users/USER/d0b_build.log
echo "=== mysqld artifact ==="
ls -la "$BUILD/runtime_output_directory/mysqld" 2>/dev/null
"$BUILD/runtime_output_directory/mysqld" --version 2>&1 || echo "mysqld --version FAILED"
echo "=== DONE ==="
