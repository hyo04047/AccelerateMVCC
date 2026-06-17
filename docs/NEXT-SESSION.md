# 다음 세션 핸드오프 — Step 1a-ii부터 시작

> **새 세션은 이 파일을 가장 먼저 읽으세요.** 이전 대화 없이 그대로 이어가기 위한 핸드오프.
> 배경·설계근거 → [design-gc.md](design-gc.md) / 상태·로드맵 → [README.md](README.md) / 이력 → [progress-log.md](progress-log.md) / 이슈 → [findings.md](findings.md)
> 작성: 2026-06-18

---

## 0. 30초 요약
- **프로젝트**: 디스크 DBMS(InnoDB) MVCC를 가속하는 in-memory 인덱스(Kuku hash → epoch 기반 interval list of undo metadata pointers) + deadzone GC. InnoDB undo는 안 건드리고 메타데이터 포인터만 들고 compact 유지.
- **완료**: A(빌드 부활) ✅ · B(단일스레드 정확성: snapshot/deadzone/GC sweep/search + correctness 테스트) ✅ · 동시성 **1a-i**(per-traversal EBR 프리미티브 구현·ASan/TSan 검증) ✅
- **다음 = Step 1a-ii**: 검증된 EBR을 **GC·search에 통합**(단일 unlinker, 동시 reader 안전).
- **결정은 다 끝났다(재논의 금지)** → §3. **작업 방식: 작게 + 중간 체크포인트**(한 번에 몰아서 X, 사용자가 개입할 틈을 줄 것).

---

## 1. 환경 & 빌드/테스트 레시피 (그대로 따라하면 됨)
- **WSL2 Ubuntu 26.04, root로 운용**(sudo 불필요). 소스: `/mnt/c/Users/USER/projects/AccelerateMVCC`. 빌드 디렉토리: WSL 홈 `~/acc-build`.
- ⚠️ **PowerShell→wsl로 복잡한 bash 인라인을 넘기면 따옴표·`{}`·리다이렉트가 깨진다.** 반드시 **스크립트 파일로 작성** 후:
  `wsl -d Ubuntu -u root -e bash /mnt/c/Users/USER/<script>.sh` 로 실행하고, **출력은 스크립트 안에서 `exec > /mnt/c/.../log 2>&1`로 파일에 받아 Read**.
- **Release 빌드/테스트**:
  - `cmake -S /mnt/c/Users/USER/projects/AccelerateMVCC -B ~/acc-build -DCMAKE_BUILD_TYPE=Release`
  - `cmake --build ~/acc-build -j$(nproc)`
  - `~/acc-build/test_with_google --gtest_filter='MvccVisibility.*:GcDeadzone.*:GcEndToEnd.*'`
- **ASan**: configure에 `-DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS="-fsanitize=address -fno-omit-frame-pointer -g" -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address"`, 실행 시 `ASAN_OPTIONS=detect_leaks=0`(구조상 의도된 누수 있음 — UAF만 본다).
- **TSan**: 위에서 `address`→`thread`. (ASan·TSan 동시 불가, 별도 빌드 디렉토리.)
- **EBR 단독 타깃**(kuku/mvcc 의존 없어 빠름): `--target ebr_test` → `~/acc-build-xxx/ebr_test`.
- gcc 15.2 / cmake 4.2. 알려진 무해 경고: googletest `cmake_minimum_required` deprecation, FetchContent CMP0135.

---

## 2. Step 1a-ii 구현 계획 (구체적으로 — 이대로 하면 됨)

**목표**: GC가 dead epoch을 inline `delete`하는 대신 **EBR로 retire**, search 순회를 **`Guard`로 보호**, BG/주기적 **`reclaim()`**. → 동시 reader가 GC가 미는 노드를 안전하게 읽음. (이번엔 **단일 unlinker** = GC 한 스레드. 다중 unlinker+marked pointer는 1b.)

**파일별 변경**:
1. `include/epoch_table.h`
   - `#include "epoch_reclaimer.h"`. `Epoch_table`에 멤버 `EpochReclaimer reclaimer_;` + 접근자 `EpochReclaimer& reclaimer() { return reclaimer_; }`.
   - `garbage_collect`의 Phase 2: `delete epochNode; delete dead;` → `reclaimer_.retire([epochNode]{ delete epochNode; }); reclaimer_.retire([dead]{ delete dead; });`. empty table-node의 `delete first_node` / `delete node`도 retire로.
   - `garbage_collect` 진입부(warm-up return 전·후 위치는 무방)에서 `reclaimer_.reclaim();` 호출(이전에 retire된 것 중 안전한 것 free).
2. `include/accelerateMVCC.cpp`
   - `search()`의 Phase 2 순회 직전에 `EpochReclaimer::Guard g(epoch_table->reclaimer());` (순회 동안 epoch_node 포인터를 잡으므로 guard가 그 구간을 덮어야 함). `search_operation`은 `search`를 호출하므로 그쪽만 감싸면 됨.
   - (1a-ii는 search reader만 guard. insert의 concurrent 보호는 1b.)
3. `correctness_test.cpp` — 신규 테스트:
   - `GcEbrIntegration.SingleThread`: insert_trx 다수(예 10만) → GC가 retire/reclaim, 끝나고 `search` 정상 + 크래시 없음.
   - `GcEbrIntegration.ConcurrentReaders`: **writer 1스레드**(insert_trx, 유일한 GC unlinker) + **reader N스레드**(guarded `search` 루프). **ASan(UAF 0) + TSan(race 0)**. 이게 EBR 통합의 핵심 검증(동시 reader가 GC free로부터 보호되는지).
   - 기존 `MvccVisibility/GcDeadzone/GcEndToEnd` + 단일스레드 GC 테스트 전부 여전히 통과해야 함.

**주의/함정**:
- EBR `retire/reclaim`은 **단일 producer 가정**(현재). 그래서 1a-ii 테스트는 **writer(=GC) 1스레드**로 유지. 멀티 writer 동시 GC는 1b(다중 producer retire + marked pointer 필요).
- single-thread 테스트에선 GC·search가 안 겹쳐 reclaim이 즉시 다 됨 — EBR의 진짜 이득(동시 reader 보호)은 `ConcurrentReaders` 테스트로 본다.
- guard 범위: epoch_node/undo_entry를 deref하는 전체 순회를 덮을 것(early return 경로 포함 — RAII라 자동).

**완료 기준(DoD)**: 위 테스트 통과 + ASan/TSan 클린 + 기존 테스트 통과 → 커밋 → **멈추고 사용자에게 보고**.

---

## 3. 결정 잠금 (재논의 금지 — 근거는 design-gc.md)
- **deadzone = vDriver Theorem 3.1**. 우리 `can_pruning` = vDriver `IsInDeadZone`(`xmin>left && xmax<right`) 동일식. **epoch = vDriver version-segment**(epoch 단위 GC = Q4).
- **동시성 모델**: hot path(read/insert) **lock-free** / 동시 unlink 일관성 = **marked pointer**(Harris; 1b에서) / reclamation = **per-traversal EBR**(per-transaction active-list grace는 **LLT가 회수를 막아 deadzone 취지를 깸**→폐기) / **FG 협조 unlink + BG reclaim**. 논리=deadzone, 물리=EBR(시간척도 다름).
- **Q1** insert↔GC 리스트 방향 = dummy head + head-insert로 통일(완료). **Q2** 빈 snapshot=안 지움. **Q3** 단일스레드 정확성(B) → 동시성(현재). **Q4** epoch 단위.
- **GC warm-up**: epoch 25/50 early-return은 의도된 윈도잉(보존). "50 mutation 스킵"은 오류(기각).
- **provenance**: deadzone = **vDriver 파생**(vDriver_PostgreSQL `dead_zone.c`에서 추출, 정승연). 보고서엔 vDriver 출처/라이선스 표기.

## 4. 후속/평가 후보 (지금 건드리지 말 것)
- **tagged-pointer reclamation**(epoch id+tag, stale 착지 self-invalidate) — EBR 대안/보완. 1a-ii는 **검증된 EBR로** 가고, 이건 나중에 평가(design-gc §9.3).
- min/max 기반 tight segment 경계(§8.1), multi-granularity 노드, **(중장기) list→DIVA interval tree**(§9.3), 빈 snapshot fast-path, dummy-list 누수.

## 5. 현재 repo 상태
- branch **master**, HEAD **58463ca**(docs), working tree **clean**. 원격 push 완료.
- 핵심 파일: `include/epoch_table.h`(GC/deadzone) · `include/accelerateMVCC.cpp`(insert/search) · `include/trxManager.h`(trx/snapshot) · `include/interval_list.h`(epoch_node) · `include/epoch_reclaimer.h`(**EBR, 검증됨**) · `correctness_test.cpp` · `epoch_reclaimer_test.cpp` · `CMakeLists.txt`.
- 빌드 산출물·`build/`·`.claude/`는 gitignore됨. WSL에 `~/acc-build*` 빌드 캐시 존재.

## 6. 로드맵 위치
A ✅ → B ✅ → **동시성 하드닝(1a-i ✅ → 1a-ii(여기) → 1b marked pointer → 1c 멀티스레드 테스트 녹색화)** → C(HTAP/long-txn 벤치, vDriver Zipfian+60s LLT 하니스 이식, chain-length CDF) → (최종) D(InnoDB 통합). 1차 목표 A+B+C, 최종 +D.
