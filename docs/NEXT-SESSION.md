# 다음 세션 핸드오프 — Step 1b 진행 중 (단일-writer 완료, 다음=증분 5 다중 writer)

> **새 세션은 이 파일을 가장 먼저 읽으세요.** 이전 대화 없이 그대로 이어가기 위한 핸드오프.
> 배경·설계근거 → [design-gc.md](design-gc.md) / 상태·로드맵 → [README.md](README.md) / 이력 → [progress-log.md](progress-log.md) / 이슈 → [findings.md](findings.md)
> 갱신: 2026-06-18 (세션 2, Step 1b 설계 패스 + 증분 0·1 완료 후)

---

## 0. 30초 요약
- **프로젝트**: 디스크 DBMS(InnoDB) MVCC를 가속하는 in-memory 인덱스(Kuku hash → epoch 기반 interval list of undo metadata pointers) + deadzone GC. InnoDB undo는 안 건드리고 메타데이터 포인터만 들고 compact 유지.
- **완료**: A ✅ · B ✅ · 1a-i ✅ · 1a-ii ✅ · **1b 증분 0·1·2·3·4 ✅** — marked-pointer 양 리스트 + 다중-producer EBR + **전용 BG GC 스레드**(동시 BG GC ‖ 단일 writer ‖ readers, ASan/TSan/hang 0 검증). **단일-writer 1b 동시성 완료.**
- **다음 = Step 1b 증분 5(다중 writer lock-free 하드닝)**: insert head-link CAS-재시도 + insert/GC Guard + append 재검증 + count/min/max 원자화 + GC splice CAS. 끝나면 완전한 1b. (또는 단일-writer로 1b 완료 간주 — 범위 결정.) §2 참조.
- **GC는 단일 BG 액터(전용 스레드)** 로 — "동시 GC"는 인라인 트리거 부작용이지 설계가 아님. FG 협조 unlink는 1c(additive).
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

## 2. Step 1b 계획 — 설계 패스 완료(세션2), 결정 확정 / 증분 0·1 완료, 증분 2부터

> 설계 패스(병렬 하자드 매핑 + 적대적 검증 3관점) 완료. 아래 순서·결정은 **사용자 확인 끝남**. 구현은 작은 증분 + 매 증분 체크포인트.

**확정 설계(왜)** — 세 축 분리: 논리(어느 버전이 dead)=deadzone / 물리 회수 안전=EBR(1a-ii 완료) / 물리 unlink 일관성=**marked pointer(Harris)**.
- "동시 GC"는 프로토타입이 GC를 트랜잭션 스레드에서 **인라인 트리거**(`trx_id % 2500==0`)하던 **부작용**이지 설계가 아님. → GC를 **단일 BG GC 액터(전용 스레드)**로 만들고 인라인 트리거 제거. 스레드 하나라 동시 GC 없음 → **GC lock 불필요**. (InnoDB purge / vDriver Cutter와 같은 정석.)
- marked pointer의 역할 = 그 단일 BG GC의 unlink를 **동시 lock-free insert/read**로부터 안전하게(insert는 head에 끼고, reader는 순회 중). **hot path(read·insert)는 lock-free 유지.**
- **GC는 epoch_table 경유로 노드를 잡아 레코드 `header`에 못 닿음** → head epoch prune 시 `header->next` dangling(기존 잠복버그). 해결: **epoch_node에 `header` 역포인터** 추가, unlink를 header 기준으로(head는 `header->next` CAS).
- FG 협조 unlink(reader도 거듦)는 **1c**로 분리 = marked-pointer 토대 위 **additive**(BG는 reclaim+backstop sweep로 남음, teardown 아님). reader는 자기 read-view만 들어 dead 판정 불가 → 1c는 **공유 deadzone 디스크립터**가 선결.

**증분 순서(각 커밋 분리, 매번 ASan/TSan 또는 단일스레드 회귀 green)**:
- **0 ✅** marked-pointer 헬퍼 `include/marked_ptr.h`(pack/ptr_of/mark_of/cas/set_mark) + 정렬 static_assert + 단위테스트 `marked_ptr_test.cpp` (커밋 `0e98a4c`)
- **1 ✅** 다중-producer EBR retire(lock-free Treiber 스택) + try-lock 단일소비자 reclaim(consumer-local survivors) + 다중-producer 스트레스 테스트 (커밋 `63ef424`)
- **2 ✅**(`ecd46a4`) 인터벌 리스트 Harris 전환: epoch_node에 `header` 역포인터(insert가 설정) + head-prune 시 `header->next` store(dangling 잠복버그 수리, GC가 header에서 forward-scan으로 predecessor 찾음 — `prev` 완전 제거, forward-only); `epoch_node.next`/`interval_list_header.next`를 `MarkedPtr`로; GC unlink mark→splice; **search가 marked epoch skip**; undo 체인 **단일 deleter**(누수 해소); `update_epoch_node` plain store로 단순화. 8개 회귀 Release/ASan green.
- **3 ✅**(`c7993cd`) wrapper 리스트(epoch_table) Harris 전환: `epoch_node_wrapper.next` `MarkedPtr` + GC wrapper splice mark→store + insert head-insert MarkedPtr CAS. 8개 회귀 Release/ASan/**TSan**(reader-search‖GC-unlink) green.
- **4 ✅**(`9fcac82`) **전용 BG GC 스레드**(`Accelerate_mvcc`가 `start/stop_background_gc`로 수명관리, dtor join; 옛 inline 트리거와 같은 trx-id 케이던스) + `insert_trx`/`start_read_trx`/`dummy_read_trx`의 **인라인 GC 트리거 제거**(단일 GC 액터 → "동시 GC" 부작용 소멸) + `run_gc_once()`(결정적 단일스레드용). **GC가 head epoch을 skip** → 단일 writer에서 insert‖GC가 disjoint word만 만져 insert-side 하드닝 불필요(wrapper 리스트는 insert=현재 버킷/GC=long_live 버킷이라 애초 disjoint). 테스트: `ConcurrentReaders`=BG GC‖1 writer‖4 readers, `GcEndToEnd.*` BG GC 켬, `SingleThread`=run_gc_once. 8개 Release(hang 없음)/ASan(UAF 0)/TSan(race 0) green. → **단일-writer 1b 동시성 검증 완료.**
- **5 (다음) = 다중 writer lock-free 하드닝** (이게 끝나야 "insert lock-free" 완전한 1b): 여러 writer가 동시에 insert해도 안전하도록 — insert head-link CAS-재시도 + insert/GC **EBR Guard** + "기존 epoch에 undo 추가" 경로 쓰기 전 epoch 살아있나 **재검증** + `count/min/max` **원자화** + `next_epoch_num` head-CAS 재시도 **커플링** + GC head-prune 재개(header->next CAS) + GC splice store→**CAS**. 테스트: 다중 writer ‖ BG GC ‖ readers, 같은 레코드, ASan/TSan/진행성. (적대적 검증 §의 필수사항이 전부 여기로.) ※ 단일-writer로 충분하다고 보면 1b를 inc4에서 완료로 간주하고 다중 writer를 후속(평가단계)으로 미루는 것도 가능 — 범위 결정 사항.

**1b 밖(1c 선결로 미룸)**: `my_slot()` 257번째 스레드 aliasing, empty-table-node reclaim TOCTOU sealing — FG-by-readers가 스레드 수 늘릴 때 필요.

**1b 밖(1c 선결로 미룸)**: `my_slot()` 257번째 스레드 aliasing, empty-table-node reclaim TOCTOU sealing — FG-by-readers가 스레드 수 늘릴 때 필요.

### (참고) 1a-ii에서 한 일 — 완료, 재작업 불필요
- GC `delete`→`reclaimer_.retire()`, `search` 순회 `EpochReclaimer::Guard`, `garbage_collect` 진입부 `reclaim()`. `Epoch_table`에 `reclaimer_`+`reclaimer()`.
- **read-view 평탄화**: `trx_t.active_trx_list`(재귀 `vector<trx_t>`) → `active_trx_ids`(`vector<uint64_t>`). 동시 트랜잭션 hang의 원인. deadzone 소비부/`search_operation`/`GcDeadzone` 테스트가 평탄 id 사용.
- reader는 `start_trx`/`commit_trx` 사용(`start_read_trx`는 GC 트리거).

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
- branch **master**, HEAD **= 1b 증분 4 (`9fcac82`) + 이 docs 커밋**, working tree **clean**. 원격(origin/master)은 `c4b474d`까지 → **로컬 미push**: inc0 `0e98a4c` · inc1 `63ef424` · docs `d6d2616` · inc2 `ecd46a4` · inc3 `c7993cd` · docs `de63973` · inc4 `9fcac82` (+ docs). push는 사용자 확인 후.
- 신규 파일: `include/marked_ptr.h`, `marked_ptr_test.cpp`(+CMake 타깃). `epoch_node`: `prev` 제거·`header` 추가·`next` `MarkedPtr`. `epoch_node_wrapper.next` `MarkedPtr`. `Accelerate_mvcc`: `gc_thread_`/`start_background_gc`/`stop_background_gc`/`run_gc_once`/dtor.
- 핵심 파일: `include/epoch_table.h`(GC/deadzone + EBR retire/reclaim) · `include/accelerateMVCC.cpp`(insert/search + EBR Guard) · `include/trxManager.h`(trx/평탄 read-view) · `include/interval_list.h`(epoch_node) · `include/epoch_reclaimer.h`(**EBR, 검증·통합됨**) · `correctness_test.cpp`(GcEbrIntegration 포함) · `epoch_reclaimer_test.cpp` · `CMakeLists.txt`.
- 빌드 산출물·`build/`·`.claude/`는 gitignore됨. WSL에 `~/acc-build`(Release)·`~/acc-build-asan`·`~/acc-build-tsan` 캐시 존재. gdb 설치됨.

## 6. 로드맵 위치
A ✅ → B ✅ → **동시성 하드닝(1a-i ✅ → 1a-ii ✅ → 1b marked pointer(여기/다음) → 1c 멀티스레드 테스트 녹색화)** → C(HTAP/long-txn 벤치, vDriver Zipfian+60s LLT 하니스 이식, chain-length CDF) → (최종) D(InnoDB 통합). 1차 목표 A+B+C, 최종 +D.
