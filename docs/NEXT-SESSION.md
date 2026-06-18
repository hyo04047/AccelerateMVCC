# 다음 세션 핸드오프 — Step 1b부터 시작

> **새 세션은 이 파일을 가장 먼저 읽으세요.** 이전 대화 없이 그대로 이어가기 위한 핸드오프.
> 배경·설계근거 → [design-gc.md](design-gc.md) / 상태·로드맵 → [README.md](README.md) / 이력 → [progress-log.md](progress-log.md) / 이슈 → [findings.md](findings.md)
> 갱신: 2026-06-18 (세션 2, Step 1a-ii 완료 후)

---

## 0. 30초 요약
- **프로젝트**: 디스크 DBMS(InnoDB) MVCC를 가속하는 in-memory 인덱스(Kuku hash → epoch 기반 interval list of undo metadata pointers) + deadzone GC. InnoDB undo는 안 건드리고 메타데이터 포인터만 들고 compact 유지.
- **완료**: A(빌드 부활) ✅ · B(단일스레드 정확성) ✅ · 동시성 **1a-i**(per-traversal EBR 프리미티브·ASan/TSan) ✅ · **1a-ii**(EBR을 GC·search에 통합 + read-view 평탄화 fix, 동시 reader ASan/TSan 클린) ✅
- **다음 = Step 1b**: 동시 unlink 일관성용 **marked pointer**(Harris) → 다중 unlinker/협조적 FG unlink. (현재는 GC 단일 unlinker 한정.)
- **결정은 다 끝났다(재논의 금지)** → §3. **작업 방식: 작게 + 중간 체크포인트**(한 번에 몰아서 X, 사용자가 개입할 틈을 줄 것). **설명은 알고리즘/설계/구현 레이어로**(함수·코드 이름 나열 X — 사용자 요청).

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
- **동시성 디버깅 교훈(세션2)**: hang vs 크래시 구분은 `timeout -s KILL N <bin>; echo $?`(124=hang). 행 상태 스택은 **gdb 설치됨**(`gdb -p <pid> -batch -ex 'thread apply all bt'`). ⚠️ **ASan 바이너리에 `stdbuf`(LD_PRELOAD) 쓰지 말 것** — "ASan runtime does not come first" 에러. ASan/TSan 리포트는 stderr라 `2>&1`로 받고, 리포트가 0건이면 메모리 오류/레이스 아님(→ hang 의심).

---

## 2. Step 1b 계획 (다음 — 먼저 짧은 설계 패스 필요)

> 1a-ii와 달리 1b는 라인 단위까지 사전확정돼 있지 않음. **구현 전 설계 패스 먼저 하고 사용자 확인** 받을 것.

**목표(알고리즘)**: 동시 **unlink 일관성**을 위한 **marked pointer(Harris linked list)**. 현재는 unlinker가 GC 한 스레드뿐이라 단일 CAS unlink가 안전하지만, **다중 unlinker(협조적 FG unlink) 또는 insert↔GC 동시 변형**에선 단일 CAS가 동시 삽입 노드를 유실시킴 → 노드의 next에 **mark 비트**를 세워 논리삭제(CAS) 후 물리 unlink(CAS), 순회자는 marked 노드를 skip/help. (근거: design-gc §, Herlihy&Shavit.)

**설계(왜·무엇)**:
- 논리=deadzone(어느 버전이 죽었나) / 물리 안전=EBR(이미 1a-ii 통합) / **물리 일관성=marked pointer(1b)** — 세 축이 분리됨.
- 대상 포인터: interval-list `epoch_node.next`(reader가 순회) 및/또는 epoch_table wrapper 리스트. mark 비트는 포인터 하위 비트 packing 또는 `atomic<tagged_ptr>`.

**구현 스케치(높은 수준)**:
1. unlink를 2단계로: (a) 대상 노드 next에 mark CAS(논리삭제) → (b) 앞 노드 next를 대상의 next로 CAS(물리 분리, 실패 시 재시도/도움).
2. `search` 순회가 marked 노드를 만나면 건너뛰고(가능하면 help-unlink), 그 다음에야 EBR `retire`.
3. **선결 의존성**: EBR `retire/reclaim`은 현재 **단일 producer**(`epoch_reclaimer.h` 주석 참조). 다중 unlinker가 retire하려면 **lock-free retire 큐(다중 producer)**가 필요 → 1b 범위에 포함.

**검증**: `GcEbrIntegration.ConcurrentReaders`를 **다중 writer/unlinker**로 확장(현재는 writer 1). ASan(UAF 0)+TSan(race 0)+무한루프/유실 없음(`timeout` 가드). 기존 8개 유지.

**완료 기준(DoD)**: 설계 확인 → 구현 → 위 검증 통과 → 커밋(분리) → **멈추고 보고**.

### (참고) 1a-ii에서 한 일 — 이미 완료, 재작업 불필요
- GC `delete`→`reclaimer_.retire()`(epoch_node+wrapper/table-node), `search` 순회 `EpochReclaimer::Guard`, `garbage_collect` 진입부 `reclaim()`. `Epoch_table`에 `reclaimer_` 멤버+`reclaimer()` 접근자.
- **read-view 평탄화**(선행 fix): `trx_t.active_trx_list`(재귀 `vector<trx_t>`) → `active_trx_ids`(`vector<uint64_t>`). 동시 트랜잭션 hang의 원인이었음. deadzone 소비부/`search_operation`/`GcDeadzone` 테스트가 평탄 id 사용.
- reader는 `start_trx`/`commit_trx` 사용(`start_read_trx`는 내부에서 GC 트리거 → 단일 producer 전제 깨짐, 주의).

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
- branch **master**, HEAD **e1a45c4**(1a-ii EBR 통합), working tree **clean**. **로컬 2커밋 미push**: `0797855`(read-view 평탄화) → `e1a45c4`(EBR 통합). 원격 push는 사용자 확인 후.
- 핵심 파일: `include/epoch_table.h`(GC/deadzone + EBR retire/reclaim) · `include/accelerateMVCC.cpp`(insert/search + EBR Guard) · `include/trxManager.h`(trx/평탄 read-view) · `include/interval_list.h`(epoch_node) · `include/epoch_reclaimer.h`(**EBR, 검증·통합됨**) · `correctness_test.cpp`(GcEbrIntegration 포함) · `epoch_reclaimer_test.cpp` · `CMakeLists.txt`.
- 빌드 산출물·`build/`·`.claude/`는 gitignore됨. WSL에 `~/acc-build`(Release)·`~/acc-build-asan`·`~/acc-build-tsan` 캐시 존재. gdb 설치됨.

## 6. 로드맵 위치
A ✅ → B ✅ → **동시성 하드닝(1a-i ✅ → 1a-ii ✅ → 1b marked pointer(여기/다음) → 1c 멀티스레드 테스트 녹색화)** → C(HTAP/long-txn 벤치, vDriver Zipfian+60s LLT 하니스 이식, chain-length CDF) → (최종) D(InnoDB 통합). 1차 목표 A+B+C, 최종 +D.
