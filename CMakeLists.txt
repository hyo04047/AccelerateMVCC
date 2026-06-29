# CMakeList.txt : CMake project for AccelerateMVCC, include source and define
# project specific logic here.
cmake_minimum_required(VERSION 3.16)

# Enable Hot Reload for MSVC compilers if supported.
if (POLICY CMP0141)
  cmake_policy(SET CMP0141 NEW)
  set(CMAKE_MSVC_DEBUG_INFORMATION_FORMAT "$<IF:$<AND:$<C_COMPILER_ID:MSVC>,$<CXX_COMPILER_ID:MSVC>>,$<$<CONFIG:Debug,RelWithDebInfo>:EditAndContinue>,$<$<CONFIG:Debug,RelWithDebInfo>:ProgramDatabase>>")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(THREADS_PREFER_PTHREAD_FLAG ON)

project ("AccelerateMVCC")

# Build the vendored Kuku cuckoo-hash library from source (provides target Kuku::kuku,
# including transitive include dirs for kuku/*.h and the generated config.h)
add_subdirectory(Kuku)

# Common source files
set(COMMON_SOURCES
  "include/accelerateMVCC.h"
  "include/accelerateMVCC.cpp"
  "include/trxManager.cpp"
  "include/interval_list.h"
  "include/interval_list.cpp"
  "include/common.h"
  "include/epoch_table.h"
  "include/epoch_table.cpp"
)
# Compile OUR core sources with -Wall -Wextra to surface latent warnings (sign-compare in the deadzone
# index math, maybe-uninitialized in the Harris CAS loops, etc.) -- the cheapest defect signal, which the
# integration build globally disables with -w on these same files. Vendored Kuku / gtest keep their defaults.
set_source_files_properties(
  include/accelerateMVCC.cpp
  include/interval_list.cpp
  include/epoch_table.cpp
  PROPERTIES COMPILE_OPTIONS "-Wall;-Wextra")

# Add source to this project's executable.
add_executable (AccelerateMVCC
  "main.cpp"
  ${COMMON_SOURCES}
 )

 find_package(Threads REQUIRED)

# Add the directory containing kuku/kuku.h and kuku/common.h to the include directories
target_include_directories(AccelerateMVCC
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/Kuku/src
)

if (CMAKE_VERSION VERSION_GREATER 3.12)
  set_property(TARGET AccelerateMVCC PROPERTY CXX_STANDARD 20)
endif()

# Link the Kuku library (built from source) and threads
target_link_libraries(AccelerateMVCC
  PRIVATE
  Kuku::kuku
  Threads::Threads
)

# TODO: Add tests and install targets if needed.
include(FetchContent)
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/03597a01ee50ed33e9dfd640b249b4be3799d395.zip
)
# For Windows: Prevent overriding the parent project's compiler/linker settings
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

enable_testing()

add_executable(
  test_with_google
  "google_test.cpp"
  "correctness_test.cpp"
  ${COMMON_SOURCES}
)

# Add the directory containing kuku/kuku.h and kuku/common.h to the include directories
target_include_directories(test_with_google
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/Kuku/src
)

if (CMAKE_VERSION VERSION_GREATER 3.12)
  set_property(TARGET AccelerateMVCC PROPERTY CXX_STANDARD 20)
endif()

# Link the Kuku library, GoogleTest, and threads
target_link_libraries(
  test_with_google
  PRIVATE
  Kuku::kuku
  GTest::gtest_main
  Threads::Threads
)

include(GoogleTest)
gtest_discover_tests(test_with_google)

# Standalone test for the EBR reclamation primitive (header-only, no kuku/mvcc
# deps -> fast to rebuild under ASan/TSan).
add_executable(ebr_test "epoch_reclaimer_test.cpp")
target_include_directories(ebr_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(ebr_test PRIVATE GTest::gtest_main Threads::Threads)

# Standalone test for the marked-pointer (Harris) helper (stage 1b increment 0).
# Header-only (kuku-free) -> fast to rebuild under ASan/TSan.
add_executable(marked_ptr_test "marked_ptr_test.cpp")
target_include_directories(marked_ptr_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(marked_ptr_test PRIVATE GTest::gtest_main Threads::Threads)

# Stage D: standalone stress test for the bounded MPMC ring (lock-free populate-hook primitive).
# Header-only / kuku-free / no gtest -> fast to rebuild under ASan/TSan.
add_executable(accel_ring_test "accel_ring_test.cpp")
target_include_directories(accel_ring_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(accel_ring_test PRIVATE Threads::Threads)

# Stage C HTAP/long-txn benchmark harness (Zipfian writers + chain-length sampler).
# Links the same core sources as the main executable; no gtest dependency.
add_executable(stage_c_bench
  "stage_c_bench.cpp"
  ${COMMON_SOURCES}
)
target_include_directories(stage_c_bench
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/Kuku/src
)
if (CMAKE_VERSION VERSION_GREATER 3.12)
  set_property(TARGET stage_c_bench PROPERTY CXX_STANDARD 20)
endif()
target_link_libraries(stage_c_bench
  PRIVATE
  Kuku::kuku
  Threads::Threads
)