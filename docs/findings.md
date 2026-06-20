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
| 13 | [trxManager.h](../include/trxManager.h) | **read-view 무한중첩 hang**: `trx_t.active_trx_list`가 `vector<trx_t>`(값) 재귀 → 동시 트랜잭션이 겹치면 스냅샷 복사가 세대마다 폭발해 `copy_active_trx_list()`가 끝나지 않음(동시성 테스트 hang). B단계 #7 수정(복사 보존)이 재귀를 활성화. 단일 활성 트랜잭션에선 무해해 그동안 잠복 | 🟠 | ✅ 1a-ii 해결 |

## 테스트 현황
- Kuku 라이브러리 자체 테스트(common/table/locfunc/value)는 다수 존재, 정상으로 보임.
- AccelerateMVCC: `initalize`, `1M dummy read`, 그리고 record=1/3/10 × thread=1/5/10 × {vector, interval list, +lock, +trx_manager, +gc} 조합의 **insert 처리량 벤치**가 대부분. 결과는 timing 출력일 뿐 정답 검증 아님.

## 실험/결과 현황
- 졸프 문서의 측정 수치는 전부 **baseline InnoDB 진단용**(문제 존재 입증)이었음. **Stage C(2026-06-20)에서 제안 구조의 비교 결과 산출 완료** — 아래 참조.
- 계획되었던 환경: sysbench worker(OLTP) + Client(OLAP long-txn) 병렬 = HTAP, `perf` 연동. standalone 단계에선 vDriver 하니스를 프로토타입으로 이식(`stage_c_bench.cpp`), baseline은 프로토타입 내 tail-only GC 모드로 모델링(실 sysbench/MySQL은 Stage D).

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

## 동시성 하드닝 — EBR 통합(1a-ii) 해결 내역 — 2026-06-18
검증된 per-traversal EBR(`epoch_reclaimer.h`, 1a-i)을 GC·search에 통합하고, 동시 reader 하에서 ASan/TSan으로 검증.
- ✅ **EBR 통합**: GC prune 시 `delete`→`reclaimer_.retire()`(epoch_node + wrapper/table-node), `search` 순회를 `EpochReclaimer::Guard`로 보호, `garbage_collect` 진입부 `reclaim()`. 동시 reader가 GC가 미는 노드를 안전하게 읽음(논리=deadzone / 물리=EBR). 커밋 `e1a45c4`.
- ✅ **#13 read-view 평탄화**: `trx_t`의 read-view를 재귀 `vector<trx_t>` → 평탄 `vector<uint64_t> active_trx_ids`로. deadzone 소비부(`generate_dead_zone`/`can_pruning`/`get_dead_up_limit_id`)와 `search_operation`·`GcDeadzone` 테스트를 평탄 id로 갱신. 커밋 `0797855`. **이 hang이 동시성을 막던 진짜 벽**이었고 EBR과 무관(트랜잭션 레이어 결함). gdb 스택 덤프로 원인 규명.

**테스트**: `GcEbrIntegration.SingleThread`(retire/reclaim 배선) + `ConcurrentReaders`(writer 1=GC + reader 4 guarded search) — Release/ASan/TSan 전부 클린(총 8개). 진단 도구 gdb를 WSL에 설치.

## Step 1b 완료 + 적대적 코드 리뷰 — 2026-06-18
marked-pointer(Harris) 양 리스트 + 다중-producer EBR + 전용 BG GC 스레드 → multi-writer‖BG GC‖readers Release/ASan(UAF 0)/TSan(race 0)/hang 0 검증(9개 테스트). 증분 0–5 (`0e98a4c`~`b15d60e`).

**적대적 코드 리뷰**(워크플로 57에이전트: 5관점 attack → finding별 독립 verify → 종합; 51발견 중 28 false-positive 기각): 핵심 설계는 검증 경로에서 건전 확인. 확정 잠복결함 8건 중 **7건 수정**(커밋 `49f28b7`) — ① EBR `my_slot` 256+스레드 aliasing에 interim assert ② dummy-head ctor 99개 누수 hoist ③ `Epoch_table::insert`를 EBR Guard로(table_node swap‖느린 inserter UAF 창) ④ BG GC cadence를 PERIOD별 catch-up으로(boundary 영구 skip 방지) ⑤ `min_reservation` seq_cst load(ordering gap) ⑥ `start_background_gc` 예외안전 ⑦ `run_gc_once` BG 중복 가드.

**🔴 stage C 전 필수(보류 3건) — 전부 1c에서 해소 ✅** (상세 [progress-log](progress-log.md)·[design-1c.md](design-1c.md)):
- **#1 EBR slot lease ✅ (1c-0)**: creation-order round-robin → per-thread 슬롯 lease(전역 풀, thread 종료 시 반납 → *동시생존* 스레드 기준) + pool 고갈 시 보수적 seq_cst overflow pin. churn 517 / 동시 272→overflow 16 테스트.
- **#2 dummy-overflow consumer ✅ (1c-3)**: dummy-overflow를 single-head Treiber stack으로 리팩터 + BG drain(dead orphan은 retire[소유권 transfer], live는 re-queue). full-bucket backstop도 같이.
- **#5 cold-record dead head ✅ — dissolved by 1c-4 tight bounds**: head는 record의 **현재 값**이라 `superseded_ts=∞` → tight bounds에서 절대 dead 아님 = prune 대상이 아예 없음(보존이 맞음, 누수 아님). 원래 "dead head"는 nominal over-pruning이 살아있는 head를 dead로 오판한 artifact였고 1c-4가 그 오판을 제거. head-prune vs append 동시성 문제도 같이 사라짐. (잔여 long_live_epochs 성장은 perf — 1c-6.) 테스트 `GcDeadzone.HeadEpochIsNeverPruned`.

**1a-ii 단계 제약(의도)**: 단일 unlinker(=GC 한 스레드)만 retire/reclaim(EBR 단일 producer). reader는 GC를 트리거하는 `start_read_trx` 대신 `start_trx`를 써 단일 producer 전제를 지킴. 다중 unlinker/협조적 FG unlink는 **1b(marked pointer, Harris)**.

## Stage C (HTAP/long-txn 벤치) — 2026-06-20 (세션 4)
하니스 `stage_c_bench.cpp` 이식 + 결과 산출. 상세 결과·표는 [design-gc.md](design-gc.md) §11, 서사는 [progress-log.md](progress-log.md) 세션 4. 핵심 발견·수정:

| # | 이슈/발견 | 심각도 | 상태 |
|---|---|---|---|
| 14 | **BG GC stop 무응답**: `start_background_gc`의 boundary catch-up for-loop가 `gc_stop_`을 안 봄 → tail-only처럼 거의 prune 안 되는(backlog 폭증) 워크로드에서 `stop_background_gc().join()`이 밀린 boundary를 다 drain하려다 사실상 무한 대기. catch-up 매 iteration에 stop 확인하도록 수정(종료 중 남은 drain 포기 안전). **실제 shutdown robustness 버그** — 유지. | 🟠 | ✅ 수정(C-3) |
| 15 | **chain length가 no-LLT에선 BG-GC 스케줄링/CPU에 지배됨**(알고리즘 신호 아님): 스레드>코어면 BG GC 굶어 일시 폭주. → 방법론: controlled threading(스레드≤코어), warm-up 제외(`warmup_ms`), Guard-safe 샘플러(`chain_length_guarded`). deadzone 우위는 **LLT 시나리오 고유**(no-LLT는 BG만으로도 유계). | 🟡 | ✅ 방법론 반영 |
| 16 | (가설 정정) "OLTP reader가 FG unlink로 hot 체인 단축"은 **no-LLT에선 무효**(BG만으로 이미 짧음). reader/FG의 가치는 ① multi-unlinker correctness(ASan/TSan clean), ② **LLT 하** read-path chain 단축(+30% read tput). | — | ✅ 데이터로 확인 |

**결과 요지**(design-gc §11): 60s LLT 하 **deadzone hot-chain max 155 vs tail-only(InnoDB식) 846k(~5,500×)**, retire 22.4M vs 277, read tput 1.36M/s vs 487/s(~2,800×). skew 0.8/1.2/1.6 전반 우위 ~8,000× 견고. 전 run LLT visibility OK(inconsistencies=0), 토글 경로 ASan/TSan clean, 20 correctness 회귀 green. 새 실험 토글: `set_gc_tail_only`(baseline), `set_fg_unlink_enabled`(FG 축).
