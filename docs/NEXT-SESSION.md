# 재개 가이드 (Handoff)

> 새 세션이 이전 대화 없이 그대로 이어가기 위한 **실무 가이드**. 프로젝트 개요·아키텍처·로드맵은
> [README.md](README.md), 남은 작업의 상세 트래커는 [open-items.md](open-items.md), 세션별 서사는
> [progress-log.md](progress-log.md), 설계 근거는 `design-*.md`에 있습니다.
>
> 최종 갱신: **2026-06-27** (세션 9 — ⑤a-2 GC-on + 5-2b serve(C1·C2) + ⑥ GC-on 재측 완료)

## 현재 위치 (한눈에)
- **1차 목표 A+B+C 완료**, **최종 D 완료** (populate → consult → authoritative serve → ⑥ 성능 payoff).
- **⑤a-2 완료** — deadzone GC가 통합 mysqld 안에서 실제로 돈다: pushed InnoDB clock + active-view
  registry로 구동, amortized windowed sweep, 정확(construct_BAD=0)·race/UAF 0·메모리 유계.
- **5-2b 진행 중 — serve를 GC 위에서 켜는 단계.** C1(안전망 오라클) + C2(mode-2 verify-serve가 GC 위에서
  정확, 49만 레코드 서빙 construct_BAD=0) 완료. **⑥ payoff가 GC-on에서도 생존**(64M deep read 98s→0.45s).
- **다음 = ⑤b**(serve latency 0.45s→0.16s, FG+BG 트랙) **/ C3**(mode-1 출하 hardening). 상세는
  [open-items.md](open-items.md) §0b "여전히 열림".

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
