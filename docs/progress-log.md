# 진행 로그

진행 상황을 세션별로 기록. 최신이 위.

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
