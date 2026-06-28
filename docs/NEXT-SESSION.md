# 재개 가이드 (Handoff)

> 새 세션이 이전 대화 없이 그대로 이어가기 위한 **실무 가이드**. 프로젝트 개요·아키텍처·로드맵은
> [README.md](README.md), 남은 작업의 상세 트래커는 [open-items.md](open-items.md), 세션별 서사는
> [progress-log.md](progress-log.md), 설계 근거는 `design-*.md`에 있습니다.
>
> 최종 갱신: **2026-06-28** (세션 10 — C3 mode-1 안전 출하 + ⑥ chain-sever 특성화 + GC-쪽 완성 deferral)

## 현재 위치 (한눈에)
- **1차 목표 A+B+C 완료**, **최종 D 완료** (populate → consult → authoritative serve → ⑥ 성능 payoff).
- **⑤a-2 완료** — deadzone GC가 통합 mysqld 안에서 실제로 돈다(pushed InnoDB clock + active-view registry,
  amortized windowed sweep, construct_BAD=0·race/UAF 0·메모리 유계). **5-2b C1·C2 완료**(mode-2 verify-serve가
  GC 위에서 정확, 49만 served construct_BAD=0).
- **C3(mode-1 serve-only 안전 출하) 완료** — gc_generation 2nd firewall(race detector·mode-1 한정) +
  1-in-N walk-audit(observe-only·N=0이면 거부) + 4-layer 분업. construct_BAD=0 도처. 커밋 `6025021`·`3b21003`.
  상세 design-D5-gc §10.1.
- **⑥ chain-sever → drain-cap으로 안정화 (FG+BG 스테이지 완료, design-D5-gc §13)** — GC storm이 navigation
  경로 회수 시 consult가 MISS→정답 walk로 degrade(construct_BAD=0 항상)였으나, **GC-tuning drain-cap이 ⑥를
  stable로**: cap=0 2/8 → **cap≤1000 0/6 degrade**(30+ run·construct_BAD=0·메모리 ∝window=⑤ 유지). ⑥-serving
  권장 `ACCEL_DRAIN_CAP≈1000`(default 0). **β(navigation 구조)는 구조적 불가 재확인, α(FG reclaim 통합)는 측정상
  이득 0**(consult가 OLTP 비용의 무시할 fraction). 커밋 `71f0cfd`·`1f92ea2`, standalone 39 5/5 안정.
- **다음 = Phase 2**(워크로드 폭: write-heavy+LLT in-middle 이득·LOB·savepoint·22% MISS effective speedup)
  → Phase 3(InnoDB 패치 vendor·REPORT Limitations·multi-run/error-bar·논문 한글+영문). 상세 [open-items.md](open-items.md) §0c.

## 새 세션 시작 절차
1. **맥락**: [README.md](README.md) §현황 → [open-items.md](open-items.md) §0b(남은 작업) → 필요 시
   [progress-log.md](progress-log.md) 최신 엔트리.
2. **검증(맹신 금지)**: `git log --oneline -5` + `git status`(clean) → standalone `build_d5_walk_std.sh`로
   **36 green** 1회 → 필요 시 `build_d5_walk_san.sh`(ASan/TSan 25).
3. **작업 방식**: 작게 + 중간 체크포인트(brief→사인→재진입). correctness-critical 큰 단계는 **적대적
   설계 리뷰 먼저**(⑤a-2·5-2b가 그렇게 진행됨). 답변은 한국어 존댓말·동작 레벨(symbol 덤프 X), technical
   용어는 영어. **성능이 목적, correctness는 전제.**

## 빌드 & 테스트 레시피
**환경**: WSL2 Ubuntu, root 운용. 소스 `/mnt/c/Users/USER/projects/AccelerateMVCC`. standalone 빌드는 WSL
홈 `~/acc-build*`, MySQL 소스/빌드는 `~/mysql-server`(8.4.10)/`~/mysql-build`(gcc-13). PowerShell→wsl로
복잡한 bash 인라인은 따옴표가 깨지니 **스크립트 파일**로 실행하고 출력은 `/mnt/c` 로그로 받아 읽을 것.
긴 빌드는 포그라운드(블로킹)로.

**standalone** (정확성 + 동시성, 36 tests):
- Release: `build_d5_walk_std.sh` — `correctness_test.cpp`의 `Consult.*`(serve 오라클 포함)+전체 스위트.
- ASan/TSan: `build_d5_walk_san.sh` — UAF/leak/race 0.
- 둘 다 레포 밖 `/mnt/c/Users/USER/`에 있음(편의 스크립트).

**integration** (통합 mysqld, `integration/scripts/`):
- 패치 적용 = `accel_hook.{h,cc}` + `accel_ring.h`를 `~/mysql-server/storage/innobase`로 복사 후
  `cmake --build ~/mysql-build --target mysqld`(증분). accel 헤더는 `-I repo/include`로 해결.
- mysqld 기동 주의: `--user=root`, `--lc-messages-dir=$BUILD/share`, `--mysql-native-password=ON`.
- **런타임 토글(env)**: `ACCEL_GC=1`(deadzone GC 켜기, 기본 off) · `ACCEL_AUTHORITATIVE=2`(verify-serve =
  walk+byte-compare 후 서빙) `=1`(serve-only, walk skip) `=0`(shadow, 기본).
- 재현 스크립트: `build_d5_a2s{1,2,3,5}.sh`(⑤a-2 단계별) · `build_d5_c2.sh`(serve mode-2 under GC) ·
  `build_d5_d6_gc.sh`(⑥ payoff under GC) · `build_d6.sh`(원본 ⑥, GC-off) · `build_d5_diag*.sh`(진단).

## 로드맵 (다음 작업)
[open-items.md](open-items.md)가 마스터 트래커. 요약:
- **⑤b** — serve 깊은-읽기 latency 0.45s→0.16s (GC-safe back-edge; **FG cooperative reclaim과 같은
  트랙** — reader‖GC chain-pointer 표면이 같음).
- **C3** — mode-1(빠른 serve) 출하 hardening: gc_generation 2번째 방화벽 + walk-audit 샘플링.
- **multi-reader in-middle 측정** — 동시 reader 다수일 때 GC의 in-middle 회수(메모리 이득)와 serve 상호작용.
- **Phase 2** — 워크로드 폭(LOB·write-heavy+LLT in-middle 이득·savepoint) · FG +30% 채택 측정.
- **Phase 3** — InnoDB 패치 vendor · REPORT Limitations · multi-run/error-bar · **논문 한글본+영문본**.
