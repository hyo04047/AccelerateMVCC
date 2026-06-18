# 진행 로그

진행 상황을 세션별로 기록. 최신이 위.

---

## 2026-06-18 — 세션 2: EBR 통합 (Step 1a-ii) ✅ + read-view 평탄화 fix

**구현(1a-ii) ✅**: 검증된 per-traversal EBR을 GC·search에 통합. GC가 prune한 노드를 inline `delete` 대신 `EpochReclaimer`로 **retire**(epoch_node + 내부 wrapper/table-node), `search`의 interval-list 순회를 **`Guard`**로 보호, `garbage_collect` 진입부에서 **`reclaim`**. 단일 unlinker(=GC 한 스레드)·EBR 단일 producer 전제 유지. 커밋 `e1a45c4`.

**도중 발견·해결: read-view 무한중첩 hang (정공법 평탄화)** — `trx_t.active_trx_list`가 `std::vector<trx_t>`(값) 재귀라, 스냅샷이 다른 트랜잭션의 스냅샷을 통째 복사 → 중첩이 세대마다 누적. 단일 활성 트랜잭션(B단계까지의 모든 테스트)에선 스냅샷이 비어 무해했으나, **동시 트랜잭션이 겹치면 `copy_active_trx_list()`가 무한 폭발 → hang**(gdb로 전 스레드가 재귀 `vector<trx_t>` 복사에 200+ 프레임 갇힘 확인). ASan은 메모리 오류 0건(크래시 아님) → hang 확정. deadzone는 read-view에서 2단계(활성 trx + 각자의 활성 id)만 소비하므로 **read-view를 평탄한 `std::vector<uint64_t>`로** 교체(`active_trx_ids`), 복사 O(N)·비재귀. EBR 통합의 **선행조건**. 커밋 `0797855`. (이 hang은 EBR과 무관한 트랜잭션 레이어 결함이었고, EBR은 죄 없음.)

**검증**: 신규 `GcEbrIntegration.SingleThread` + `ConcurrentReaders`(writer 1=GC + reader 4, guarded search 루프) — Release + **ASan(UAF 0) + TSan(race 0) 클린**, 기존 6개 포함 총 8개 통과. 도구: gdb 설치(WSL, 스택 덤프로 hang 원인 규명).

**커밋 분리**: `0797855`(평탄화 fix) → `e1a45c4`(EBR 통합). 성격이 달라 이력상 분리. push는 미실행.

**다음**: Step 1b — 동시 unlink 일관성용 **marked pointer**(Harris) → 다중 unlinker/협조적 FG unlink 가능하게(현재는 단일 unlinker 한정).

---

## 2026-06-18 — 세션 1 (이어서): 동시성 설계 정렬 + EBR 프리미티브

**방향**: 다음은 **동시성 하드닝**(lock-free epoch-list가 멀티스레드 전제였음). 구현 전 논문·설계를 1차 자료로 정렬.

**논의·확정 (요지, 상세 [design-gc.md](design-gc.md))**:
- FG/BG GC = FG 협조 unlink→trash, BG reclaim (6·7월 deck 원문 확인).
- lock-free 리스트에서 단일 CAS로도 노드 유실 가능(Herlihy&Shavit "Problem" 슬라이드 — 강의 C++) → 동시 unlink엔 **marked pointer** 필요.
- reclamation grace: **per-transaction(active-list) 폐기 → per-traversal EBR**. (per-transaction은 LLT가 회수를 막아 deadzone 취지를 깸. 논리=deadzone / 물리=EBR, 시간척도 다름.)
- deadzone = vDriver **Theorem 3.1** 충실; `can_pruning` = vDriver `IsInDeadZone`(`xmin>left && xmax<right`) **동일 공식**(코드 레벨 확정). epoch=vDriver segment. provenance=**vDriver 파생** 확정.
- 개선 latitude 수용(tight min/max 경계, hot/cold/LLT 분류 등 후속 후보).

**구현(1a 첫 조각) ✅**: per-traversal EBR 프리미티브 [`include/epoch_reclaimer.h`](../include/epoch_reclaimer.h) + `ebr_test`(8-reader 스트레스) — **ASan(UAF 0)/TSan(race 0) 클린.** 커밋 250838a.

**논문**: vDriver(LLT) 직접 정독 완료(문제의식+알고리즘). DIVA + One-shot GC는 백그라운드 워크플로 정독 중(→ design-gc §9 종합 추가 예정).

**stage C 자산**: vDriver repo HTAP 하니스(Zipfian skew 업데이트 + 60s long reader + chain-length CDF) = C단계 워크로드 템플릿(design-gc §10).

**다음**: Step 1a-ii 통합(GC `delete`→`retire` / search `Guard` / BG `reclaim`).

---

## 2026-06-18 — 세션 1 (이어서): 프로토타입 완성 (B단계) ✅ 단일스레드

**분석(멀티에이전트 워크플로)**: DIVA·One-shot GC 논문 정독 + vDriver 출처 조사(웹) + 우리 GC 코드 포렌식 → 라인 단위 수정 설계. (종합 에이전트의 "epoch 50 mutation 스킵" 제안은 검토 중 오류로 판명 → early-return 윈도잉 보존.)

**deadzone 출처 판정**: 공개 DIVA repo 없음. deadzone 계보는 **vDriver(SIGMOD'20 = "Long-lived Transactions Made Less Harmful")**. 우리 코드는 알고리즘 **재구현**(복사 아님) → 라이선스 의무 없음, 보고서 인용은 vDriver로 정정 권장.

**수정**:
- snapshot 보존: `trx_t` 복사 생성자 + `startWriteTrx`가 read-view 기록
- deadzone: 생성자 `oldest_low_limit_id` 저장 + 빈 snapshot 가드
- GC sweep 메모리안전: 순회 종료조건, prune double-advance/`prev_node`, epoch 양방향 unlink, empty 판정, window underflow 가드
- `garbage_collect` 완료 시 `true`(warm-up early-return은 보존)
- insert↔GC 리스트 방향 통일: dummy=head + head-insert + `epoch_node_wrapper.next` 초기화
- `search`가 최신 가시버전 반환(기존 oldest 반환 버그 수정)

**검증**: 신규 `correctness_test.cpp` 6개(MvccVisibility·GcDeadzone·GcEndToEnd) 전부 통과 + **ASAN(use-after-free/overflow) 클린**. 기존 단일스레드 GC 테스트(`create_1M_dummy_read_transaction`, `*_with_gc`)도 통과(이전엔 크래시 위험).

**미룬 것**: 멀티스레드 GC 동시성(reclamation), 빈 snapshot fast-path, dummy-list 누수, Kuku `LocFuncTests.Randomness`.

**다음**: C단계(HTAP/long-txn 워크로드 baseline 대비 측정) 또는 멀티스레드 GC 동시성 하드닝.

---

## 2026-06-18 — 세션 1 (이어서): 빌드 부활 (A단계) ✅

**환경 구축**: WSL2 Ubuntu 26.04(배포는 `--no-launch`로 등록 후 root 운용) + build-essential / gcc 15.2 / cmake 4.2 / git.

**빌드 블로커 수정**
- CMake 버전 문자열 `3.1Threads::Threads4` → `3.16`
- include 대소문자(`accelerateMvcc`→`accelerateMVCC`) — main.cpp, CMakeLists (리눅스 케이스 민감)
- kuku 링크: Windows `.lib` 하드코딩 → `add_subdirectory(Kuku)` + `Kuku::kuku`(소스 빌드, transitive include)
- `trxManager.h`에 `<algorithm>` 추가(`std::remove`; gcc15 빌드 실패 해소)

**결과**: `cmake --build` 성공 → `AccelerateMVCC`(데모), `test_with_google`(gtest) 생성. 데모 실행 OK. 안전 테스트(GC 제외) 31개 중 **30 통과**.
- 베이스라인 insert 벤치(1M): vector 7ms / interval-list 53–73ms (record 1·3·10), vector+lock 10ms.
- **알려진 이슈**: `LocFuncTests.Randomness`(Kuku 자체 테스트) 실패 — 동일 seed의 두 LocFunc 결과 불일치(gcc15/Kuku 재현성 추정). KukuTable query/populate/fill·우리 insert는 정상이라 기능 무영향. B에서 점검.

**빌드 레시피**(WSL): `cmake -S /mnt/c/Users/USER/projects/AccelerateMVCC -B ~/acc-build -DCMAKE_BUILD_TYPE=Release && cmake --build ~/acc-build -j`

**다음**: B단계 — GC/deadzone 버그 수정 + insert/search/GC 정확성 테스트.

---

## 2026-06-18 — 세션 1 (이어서): 오픈소스 독립 레포 전환

**한 일**
- fork였던 저장소를 **독립 standalone 레포로 전환**. GitHub는 자동 detach 미지원 → 기존 fork를 임시 이름으로 rename → 같은 이름으로 새 비-fork 레포 생성 → `master`·`feat/deadzone-detector` push.
- 오픈소스 정비: MIT LICENSE(하태성), 루트 README(badges·아키텍처·로드맵), 저장소 설명, topic 12개.
- `docs/`를 master에 병합(루트에서 바로 보이도록).
- 결과: `isFork=false`, default=master, MIT 인식, public.

**비고**
- **단독 프로젝트로 정리**: 기존 fork 저장소 삭제, LICENSE·README·docs에서 공동작업자 표기 제거(하태성 단독). 코드는 향후 전면 재작성 예정.
- 코드 이력 손실 없음(epochlist 실험은 master 히스토리에 merge→revert로 포함).

---

## 2026-06-18 — 세션 1: 재개 & 현황 파악

**한 일**
- 3년 전(마지막 2023-07) 중단된 저장소를 GitHub에서 가져와 4개 브랜치 분석.
- 코드 전체 정독 + Google Drive `AccelerateMVCC` 졸프 설계 문서(159KB) 분석 → 문제·아키텍처·중단 지점 파악.
- 빌드 환경 점검: 이 PC에 **WSL/MSVC/g++/cmake 모두 미설치**, 현재 셸 비관리자.
- 문서 토대 작성: `docs/README.md`, `docs/findings.md`, `docs/progress-log.md`.
- 프로젝트 메모리 기록.

**결정**
- 범위: 1차 **A+B+C**, 최종 **A+B+C+D**. 진행하며 문서/리포트 정리.
- 개발 환경: **WSL2(Ubuntu)** — C/D가 리눅스 전용이므로 처음부터 리눅스로.

**발견(빌드 블로커)**: CMake 버전 문자열 손상, kuku 경로 하드코딩, include 대소문자 불일치(리눅스 실패). → findings #1~#3.

**다음 할 일**
1. (사용자) 관리자 PowerShell에서 `wsl --install` → 재부팅 → Ubuntu 사용자 설정.
2. (Claude) WSL에서 `build-essential cmake git` 설치 → CMake/include/kuku 링크 정리(A) → 컴파일 & 기존 벤치 실행.
3. 이후 B(병합·버그수정·정확성 테스트)로 진행.
