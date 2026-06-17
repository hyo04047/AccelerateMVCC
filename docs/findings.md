# 포렌식 & 이슈 트래커

> 코드·git·문서 정독으로 파악한 현재 상태. 빌드 환경이 없어 **정적 분석(정독)** 기반이며, 빌드 후 재현·검증한다.
> 최초 작성: 2026-06-18

## 브랜치 현황

원격 브랜치 4개 (마지막 커밋일):

| 브랜치 | 마지막 | 비고 |
|---|---|---|
| `origin/feat/deadzone-detector` | 2023-07-28 | **최신 WIP.** master+3커밋 |
| `origin/master` | 2023-07-27 | PR #3 머지까지 |
| `origin/revert-1-feat/epochlist` | 2023-07-26 | epochlist 되돌림 |
| `origin/feat/epochlist` | 2023-07-02 | lock-free list 시도(되돌려짐) |

`feat/deadzone-detector`가 master 대비 한 일 (3커밋: `b873083` fix insert → `b8a1b78` fix gc → `9266416` insert logic):
- `accelerateMVCC.cpp`: insert 3곳의 `//epoch_table->insert(epoch);` **주석 해제** → epoch_table(GC)을 interval list에 실제 연결.
- `epoch_table.h`: `insert()`의 인덱싱을 `epoch_num / EPOCH_TABLE_SIZE` → `epoch_num % EPOCH_TABLE_SIZE`로 수정.

이것이 졸프 문서 2023-07-09의 "epoch 노드를 어디에 저장할지(indirect table)" 고민의 구현이며, **미완 중단**.

## 이슈 트래커

심각도: 🔴 빌드 블로커 / 🟠 정확성 / 🟡 위생·미완

| # | 위치 | 이슈 | 심각도 | 상태 |
|---|---|---|---|---|
| 1 | [CMakeLists.txt:3](../CMakeLists.txt) | `cmake_minimum_required(VERSION 3.1Threads::Threads4)` — 손상된 버전 문자열(잘못된 find/replace 흔적). configure 즉시 실패 | 🔴 | 미해결 |
| 2 | [CMakeLists.txt:47,80](../CMakeLists.txt) | kuku 링크 경로가 Windows Debug 하드코딩(`Kuku/build/lib/Debug/kuku-2.1.lib`). 해당 파일 부재 + 리눅스에서 무효 → Kuku를 소스에서 빌드·링크하도록 변경 필요 | 🔴 | 미해결 |
| 3 | [main.cpp:3](../main.cpp), [CMakeLists.txt:19-20](../CMakeLists.txt) | include/파일명 **대소문자 불일치**: 실제 파일 `accelerateMVCC.h`인데 `accelerateMvcc.h`로 참조. Windows는 통과하나 **리눅스(케이스 민감)에서 빌드 실패** | 🔴 | 미해결 |
| 4 | [epoch_table.h:85-95](../include/epoch_table.h) | `deadzone` 생성자가 인자 `oldest_low_limit_id`를 **멤버에 저장하지 않음** → `can_pruning`에서 미초기화 값 사용 | 🟠 | 미해결 |
| 5 | [epoch_table.h:241,261](../include/epoch_table.h) | GC 순회 루프 조건 `node != last_node \|\| node != nullptr` 가 **항상 참** → 무한루프 / use-after-free 위험 (`&&` 의도 추정) | 🟠 | 미해결 |
| 6 | [epoch_table.h:200-297](../include/epoch_table.h) | `garbage_collect`가 항상 `false` 반환(주석: "완성되면 true로"). 2-phase GC(LLT 이동 / 처리) 미완 | 🟡 | 미해결 |
| 7 | [trxManager.h:34](../include/trxManager.h) | `trx_t` 복사 생성자가 `active_trx_list` 미복사(사용자 본인 TODO 주석 존재). snapshot 중첩 처리 의도 불명확 | 🟠 | 미해결 |
| 8 | [trxManager.h:57-63](../include/trxManager.h) | `startWriteTrx`는 active_trx_list snapshot을 설정하지 않음(`startTrx`는 설정) → write trx의 read view 비어 있음 | 🟠 | 미해결 |
| 9 | [accelerateMVCC.cpp](../include/accelerateMVCC.cpp) | master에서 `epoch_table->insert` 주석처리 → GC와 interval list **단절**. `feat/deadzone-detector` 병합으로 해소 예정 | 🟡 | 브랜치에 수정본 존재 |
| 10 | [google_test.cpp](../google_test.cpp) | **정확성 테스트 부재**: AccelerateMVCC 관련 테스트는 insert 타이밍 벤치 + `ASSERT_EQ(true,true)` 뿐. search/GC/deadzone 검증 0건 | 🟠 | 미해결 |
| 11 | `build/`, `Kuku/build/` | CMake 빌드 산출물이 git에 커밋됨 → `.gitignore` + 추적 해제 필요 | 🟡 | 미해결 |

## 테스트 현황
- Kuku 라이브러리 자체 테스트(common/table/locfunc/value)는 다수 존재, 정상으로 보임.
- AccelerateMVCC: `initalize`, `1M dummy read`, 그리고 record=1/3/10 × thread=1/5/10 × {vector, interval list, +lock, +trx_manager, +gc} 조합의 **insert 처리량 벤치**가 대부분. 결과는 timing 출력일 뿐 정답 검증 아님.

## 실험/결과 현황
- 졸프 문서의 측정 수치는 전부 **baseline InnoDB 진단용**(문제 존재 입증). 제안 구조 적용 후 비교 결과는 **없음**.
- 계획되었던 환경: sysbench worker(OLTP) + Client(OLAP long-txn) 병렬 = HTAP, `perf` 연동.

## 통합 현황
- standalone 프로토타입. InnoDB의 `trx_sys`에서 active list copy, undo log 메타데이터 포인터 보관 등 **InnoDB 의존은 설계상 가정**일 뿐 실제 통합 코드 없음.

## 빌드 부활(A) 해결 내역 — 2026-06-18
환경: WSL2 Ubuntu 26.04 / gcc 15.2 / cmake 4.2 에서 빌드·실행 성공.
- ✅ #1 CMake 버전 문자열 → `3.16`
- ✅ #2 kuku 링크 → `add_subdirectory(Kuku)` + `Kuku::kuku`(소스 빌드, transitive include)
- ✅ #3 include 대소문자 정정 (main.cpp, CMakeLists)
- ✅ (신규 #12) `trxManager.h`에 `<algorithm>` 누락 → 추가 (gcc15에서 `std::remove` 미해결로 빌드 실패하던 것)
- ✅ #11 build 산출물 추적 해제 + `.gitignore` 보강

**신규 known issue**: `LocFuncTests.Randomness`(Kuku 자체 테스트) 실패 — 동일 seed의 두 `LocFunc` 해시 결과 불일치. KukuTable populate/fill/query 및 우리 insert는 정상이라 실사용 무영향. 원인(gcc15/AES intrinsic/재현성)은 B에서 확인.

남은 정확성 이슈 **#4·#5·#6·#7·#8·#10**은 B단계에서 처리.

## 프로토타입 완성(B) 해결 내역 — 2026-06-18
DIVA/vDriver deadzone 모델을 멀티에이전트로 정독·분석한 뒤 snapshot·deadzone·GC·search 수정. 6개 정확성 테스트 + ASAN 검증.
- ✅ #7 `trx_t` 복사 생성자가 `active_trx_list` 보존 (snapshot이 실제 데이터를 갖도록)
- ✅ #8 `startWriteTrx`가 read-view snapshot 기록 (GC 트리거 경로)
- ✅ #4 `deadzone` 생성자 `oldest_low_limit_id` 저장 + 빈 snapshot 가드 (UB/throw 제거)
- ✅ #5 GC 순회 루프 조건 항상-참(`||`) → 정상 종료조건
- ✅ #6 prune 분기 double-advance / stale `prev_node` / 단방향 splice → 단일 전진 + 양방향 unlink
- ✅ GC empty table-node 판정 `first_node->next == nullptr` (stale `last_node` 제거)
- ✅ #6(return) `garbage_collect` 완료 시 `true` 반환, warm-up early-return(epoch 25/50)은 의도된 윈도잉이라 보존
- ✅ lagging window underflow 가드 추가
- ✅ **Q1** insert/GC 리스트 방향 통일: dummy=head 고정 + head-insert, `epoch_node_wrapper.next` nullptr 초기화
- ✅ (신규) `search`가 **최신 가시 버전**(snapshot 이하·비active 중 max trx_id) 반환 — 기존엔 가장 오래된 가시 버전을 반환하던 버그

**테스트** (`correctness_test.cpp`): MvccVisibility 2 / GcDeadzone 2 / GcEndToEnd 2 — 전부 통과, **ASAN(use-after-free·overflow) 클린**. 기존 단일스레드 GC 테스트(`create_1M_dummy_read_transaction`, `*_with_gc`)도 통과(이전엔 크래시 위험).

**deadzone 출처(provenance)**: vDriver 소스에서 **추출·간소화**(7월 deck "extract dead zone detecting part from vDriver InnoDB part", 정승연 담당). 판정식이 vDriver `IsInDeadZone`(`xmin>left && xmax<right`)과 **동일** → **vDriver 파생** 확정(클린룸 재구현 아님). vDriver 출처·라이선스(PostgreSQL License) 표기 권장. 공개 DIVA repo 없음. 상세 [design-gc.md](design-gc.md) §7.

**B에서 의도적으로 미룬 것**: 멀티스레드 GC 동시성(reclamation/RCU 부재 → `*multi_thread*_trx` 미실행), 빈 snapshot fast-path(Q2), dummy-list 누수, Kuku `LocFuncTests.Randomness`(라이브러리 자체 이슈).
