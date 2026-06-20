# 다음 세션 핸드오프 — Stage C 완료 + 보고서 + Stage D-0(InnoDB baseline) 완료, 다음은 D-1

> **새 세션은 이 파일을 가장 먼저 읽으세요.** 이전 대화 없이 그대로 이어가기 위한 핸드오프.
> 배경·설계근거 → [design-gc.md](design-gc.md)(§11 = stage C 결과)·[design-1c.md](design-1c.md) / **Stage D 설계·D-0 결과 → [design-D.md](design-D.md)** / 통합 보고서 → [REPORT.md](REPORT.md) / 상태·로드맵 → [README.md](README.md) / 이력 → [progress-log.md](progress-log.md) / 이슈 → [findings.md](findings.md)
> 갱신: 2026-06-21 (세션 4, **Stage C + 보고서 + D-0 완료** 후)

---

## ⏩ 재개 레시피 (새 세션은 이 순서로)
1. **맥락 복원**: 이 파일(§0→§D) → [design-D.md](design-D.md)(D 설계 + §7 D-0 baseline) → 필요 시 [progress-log.md](progress-log.md) 최신 2개 엔트리.
2. **검증(맹신 금지)**: `git log --oneline -8` + `git status` 확인 → (코어가 안 바뀌었으면) §1로 **20 correctness green** 1회 → **D-0 baseline 재현/이어가기**(§D 레시피).
3. **보고 후 시작**: 위 결과 짧게 보고 → **다음 = D-1**(accelerator를 InnoDB에 링크 + populate hook) 진행. ⚠️ D-1+는 InnoDB 소스 수술 = multi-session, 작게+체크포인트.
- 작업 방식: **작게 + 중간 체크포인트** / 설명은 **알고리즘·설계 레벨**(함수·코드명 덤프 X, 단 표준 용어는 영어 그대로). **성능이 목적 — correctness는 전제, no-crash가 아니라 visibility로 검증.**
- **프로젝트 성격**: 원래 2023 졸프였으나 지금은 **개인 프로젝트**(졸업용 아님). 단 성공 시 **논문급 보고서**(개인 이력/포폴용) 목표 — 가볍게 가지 말 것, 엄밀함 유지.

---

## D. Stage D 진행 (현재 위치 — D-0 ✅, 다음 = D-1)
> 1차 목표 A+B+C는 완료(보고서 [REPORT.md](REPORT.md)). 지금은 최종 D(InnoDB 실통합) PoC 진행 중. 설계·D-0 결과 상세는 [design-D.md](design-D.md).
- **결정 잠금**: MySQL **8.4.10 LTS** + **scoped PoC**(consult hook 1경로 + 측정) + **gcc-13**(gcc15 빌드 리스크 회피).
- **MySQL 빌드/실행 레시피**(WSL, 레포 밖 스크립트 재사용):
  - 소스 `~/mysql-server`(8.4 shallow clone), 빌드 `~/mysql-build`(RelWithDebInfo/gcc-13/ninja, ~11분). 재빌드: `build_d0b.sh`.
  - 기동 주의: root 운용 → mysqld에 **`--user=root`** 필수, source build → **`--lc-messages-dir=$HOME/mysql-build/share`**(언어 하위폴더의 부모), `--mysql-native-password=ON`(sysbench 인증). 데이터 `~/mysql-data`, 소켓 `~/mysql.sock`, 포트 3309.
  - baseline 재현/측정: `build_d0d.sh`(mysqld 기동 → OLTP churn + held-snapshot analytic scan latency). mysqld는 **한 스크립트 안에서만 살아있게**(wsl 호출 간 persist 안 됨).
- **D-0 baseline 결과**(= D가 이길 대상): held snapshot 하 1000행 analytic scan latency **0.7ms→1,355ms(~1,900×)** as OLTP churn deepens chains; history list 360→2.07M. **비교 지표 = held-snapshot analytic read latency vs churn**(throughput-only는 in-memory/단시간엔 신호 없음).
- **hook 지점**(MySQL 8.4 소스 확인됨): consult(D-2) = `storage/innobase/row/row0vers.cc:1249 row_vers_build_for_consistent_read`(row0sel.cc·row0pread.cc에서 호출), populate(D-1) = `storage/innobase/trx/trx0rec.cc:2117 trx_undo_report_row_operation`.
- **다음 = D-1**: accelerator(우리 in-memory 인덱스)를 InnoDB 빌드에 **정적 라이브러리로 링크** + **populate hook**(undo create 시 메타데이터 insert, read 경로는 아직 미사용). 검증 = 기능 회귀 0 + accelerator 적재 확인 + 오버헤드. 그 다음 D-2(consult)·D-3(deadzone↔trx_sys)·D-4(측정). [design-D.md](design-D.md) §4.

---

## 0. 30초 요약
- **프로젝트**: 디스크 DBMS(InnoDB) MVCC 가속용 in-memory 인덱스(Kuku hash → epoch 기반 interval list of undo 메타데이터 포인터) + deadzone GC. InnoDB undo는 안 건드리고 메타데이터 포인터만 compact 유지. **궁극 목적 = InnoDB HTAP/LLT 성능 향상.**
- **완료**: A ✅ · B ✅ · 동시성 1a·1b·1c ✅ · **Stage C ✅ (HTAP/long-txn 벤치, 1차 목표 A+B+C 결과물)**.
- **Stage C 헤드라인**(60s LLT, 6w/6r/1llt): **deadzone hot-chain max 155 vs tail-only(InnoDB식 purge) 845,977 (~5,500×)**, retire 22.4M vs 277, read throughput **1.36M/s vs 487/s (~2,800×)**. skew 0.8/1.2/1.6 전반 견고(~8,000×). FG cooperative unlink는 read-path +30%. 전 run **LLT visibility OK(inconsistencies=0)** + ASan/TSan clean. 상세 [design-gc.md](design-gc.md) §11.
- **현재**: 보고서([REPORT.md](REPORT.md)) 완료, **Stage D 진행 중 — D-0(vanilla baseline) ✅, 다음 = D-1**(위 §D). 1차 목표 A+B+C 달성, D는 최종(PoC).

---

## 1. 환경 & 빌드/테스트 레시피 (그대로 따라하면 됨)
- **WSL2 Ubuntu 26.04, root 운용**. 소스: `/mnt/c/Users/USER/projects/AccelerateMVCC`. 빌드: WSL 홈 `~/acc-build`(Release)·`~/acc-build-asan`·`~/acc-build-tsan`. gcc 15.2 / cmake 4.2 / 16코어.
- ⚠️ **PowerShell→wsl로 복잡한 bash 인라인 X**(따옴표·`$()` 깨짐). **스크립트 파일**로 쓰고 (예시 `/mnt/c/Users/USER/build_test_*.sh`·`stage_c_bench` 재현용 `build_test_c2.sh`·`build_test_c3.sh` 남아있음) `exec > /mnt/c/.../log 2>&1`로 받아 Read. **wsl 호출은 PowerShell 툴에서**. ⚠️ **백그라운드 detached(`nohup &`)는 WSL VM teardown으로 죽을 수 있음 → 긴 빌드는 포그라운드(블로킹) wsl 호출로.** CRLF 주의: 스크립트 실행 전 `sed -i 's/\r$//'`.
- **correctness(20개)**: `cmake -S <src> -B ~/acc-build -DCMAKE_BUILD_TYPE=Release` → `--target test_with_google` → 필터 `'MvccVisibility.*:GcDeadzone.*:GcEndToEnd.*:GcEbrIntegration.*:GcSharedDescriptor.*:GcRetireOnce.*:GcBackstopDrain.*:GcFgUnlink.*:GcScale.*'`. ASan: `-DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS="-fsanitize=address -fno-omit-frame-pointer -g" -DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address"` + `ASAN_OPTIONS=detect_leaks=0`(구조상 의도된 누수). TSan: address→thread. (재사용: `build_test_1c6.sh`.)
- **Stage C 벤치**: `--target stage_c_bench`. key=value 인자: `records writers readers llt dur zipf sample_ms sample_keys llt_key seed fg tail warmup_ms csv`. **헤드라인 재현**(60s LLT): `stage_c_bench records=1000 writers=6 readers=6 llt=1 dur=60 sample_ms=500 sample_keys=8 tail=0 fg=1 csv=...`(deadzone) vs `tail=1`(InnoDB baseline) vs `fg=0`(BG-only). **controlled threading 필수**(writers+readers+llt+sampler+GC ≤ 코어, 아니면 chain length가 스케줄링 노이즈에 지배됨 — §3). 재현 스크립트 `build_test_c2.sh`(헤드라인)·`build_test_c3.sh`(correctness 회귀 + skew sweep).
- 동시성 디버깅: hang은 `timeout -s KILL N <bin>`(124/137=hang). gdb 설치됨. ASan 바이너리 `stdbuf` X.

---

## 2. Stage C — 완료 기록 (증분 C-0~C-3)
> **Stage C는 끝났다.** 상세는 [progress-log.md](progress-log.md) 세션 4·[design-gc.md](design-gc.md) §11. 요지:
- **하니스**(`stage_c_bench.cpp`): vDriver Figure-12 워크로드 이식 — Zipfian writer + OLTP point-reader(같은 skew) + 60s LLT(snapshot 길게·EBR Guard는 search당 짧게) + Guard-safe chain 샘플러(CSV). 신규 accessor `chain_length_guarded`(라이브 샘플링용, Guard판). 실험 토글: `set_gc_tail_only`(baseline = `can_pruning`을 zone 0만 = InnoDB tail purge), `set_fg_unlink_enabled`(FG 축, search의 prune-initiate 토글).
- **증분**: C-0(골격)→C-1a(OLTP reader, **가설 정정**: no-LLT에선 BG만으로 유계라 reader 기여 X)→C-1b(60s LLT, visibility oracle)→C-2(헤드라인 3-run)→C-3(skew sweep robustness).
- **부수 수정**: BG GC stop-responsiveness(catch-up 루프가 `gc_stop_` 확인 — tail-only backlog에서 join 무한대기 버그) — findings #14. 20 correctness 회귀 green 확인.
- **결과**(§0 헤드라인 + design-gc §11 표): deadzone가 LLT 하 in-middle reclaim으로 chain 유계(max ~155), tail-only는 폭주(~846k), read tput ~2,800× 우위. FG는 read-path +30%. correctness는 visibility로 검증.

---

## 3. 결정 잠금 (재논의 금지 — 근거는 design-gc.md §11 / design-1c.md)
- **Stage C baseline = 프로토타입 내 tail-only GC 모드**(`set_gc_tail_only`). standalone이라 실 InnoDB 대신 InnoDB purge(global-min 아래만 회수)를 모델링. 실 MySQL+sysbench 비교는 **Stage D** 영역.
- **측정 방법론**(필수): ① controlled threading(스레드 ≤ 코어) — 아니면 chain length가 BG-GC 스케줄링에 지배됨(알고리즘 신호 아님). ② warm-up 제외(`warmup_ms`, GC warm-up early-return이 짧은 런 오염). ③ Guard-safe 샘플러. ④ **deadzone/FG 신호는 LLT 시나리오 고유**(no-LLT는 BG-only로도 유계라 비교 무의미).
- **correctness = visibility로 검증**(no-crash 아님): LLT visibility oracle(자기 visible version 불변) + conservation(detached==retired) + ASan/TSan.
- (1c에서 잠금) deadzone = vDriver Theorem 3.1, tight bounds(`[min_trx_id, superseded_ts]`), GC = 단일 BG 액터, hot path lock-free + marked pointer + per-traversal EBR. provenance = vDriver 파생(PostgreSQL License 표기).

## 4. 후속/평가 후보 (지금 건드리지 말 것)
- design-gc §9.3: list→DIVA interval tree(LLT 하 chain을 log로 bound), tagged-pointer reclamation, hot/cold/LLT classification, multi-granularity 노드.
- 잔여 perf 미세(1c): cold record head wrapper가 bucket 유지 → long_live_epochs가 live-bucket 수만큼 유지(correctness 아님).
- Stage C 확장(원하면): read latency 분포(현재는 throughput), epoch 수/EPOCH_SIZE knob 영향, CDF 차트를 보고서 figure로.

## 5. 현재 repo 상태
- branch **master**, working tree **clean**, **origin/master까지 push 완료**. **최신 커밋 = Stage C** (feat: 벤치+토글+GC fix / docs: 결과+핸드오프). `git log --oneline -8`로 확인.
- Stage C 신규/변경: `stage_c_bench.cpp`(신규 벤치), `include/accelerateMVCC.h`(`chain_length_guarded`·`set_fg_unlink_enabled`·`set_gc_tail_only`·GC stop-fix), `include/accelerateMVCC.cpp`(search FG 토글), `include/epoch_table.h`(`set_gc_tail_only`+`can_pruning` tail-only 제한), `CMakeLists.txt`(`stage_c_bench` 타깃). docs: README·progress-log·findings·design-gc(§11)·이 파일.
- **레포 밖 자산**(WSL/Windows, git 추적 X): `/mnt/c/Users/USER/build_test_c*.sh`·`sweep_c3.sh`·`cdf.sh`·`stage_c_*.csv`·`*.log`. 재현 시 재사용.

## 6. 로드맵 위치 — 1차 목표 A+B+C 달성, 다음은 D(최종) 또는 보고서
A ✅ → B ✅ → 동시성(1a ✅→1b ✅→1c ✅) → **C ✅(HTAP/long-txn 벤치)** → 보고서 ✅ → **D(InnoDB 통합) 진행 중: D-0 ✅ → D-1 다음**(위 §D / [design-D.md](design-D.md) §4).
- **D 자산/방향**(design-gc §6 vDriver 매핑): 실제 InnoDB 소스에 가속 인덱스 연결(trx_sys active list, undo 메타데이터 포인터), sysbench HTAP로 vanilla MySQL 대비 측정. 규모 큼 — 착수 전 사용자와 범위 합의.
- **보고서 방향**: A~C를 논문급으로(문제→설계(vDriver 계보)→동시성 하드닝→Stage C 결과/CDF). 차트·표는 design-gc §11 + 생성한 CDF figure 재사용.
- **다음 세션은 D vs 보고서 중 무엇부터 할지 사용자에게 물어볼 것.**
