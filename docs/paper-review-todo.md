# Paper: third-party review + remaining TODO (session-15 handoff)

> 새 세션 재개 지점. 논문(`docs/paper/paper-en.md` = canonical, `paper-ko.md` = 참고/번역투) 작업의 현 상태와
> 남은 일을 담는다. **읽는 순서: 이 문서 → `docs/paper/paper-en.md` → (vDriver 빌드면) 아래 §3.** 측정 실행
> 인프라(WSL·setsid·pkill 함정 등)는 메모리 `acceleratemvcc-integration-run-infra` 참조.

## 1. 현 상태 (2026-06-30)

- 논문 영문 원판 `paper-en.md` **§1–§8 + figure 5종 완성**(Fig1 아키텍처·Fig2 superset·Fig3 cliff·Fig4 memory·Fig5
  TPC-C). 한글 `paper-ko.md`는 §1–§8 초안이나 **번역투라 참고용**(영문 확정 후 자연스럽게 재생성 예정).
- **3자 리뷰 패널(6 에이전트, 5 관점) 완료** → verdict **"Major revision (accept-able core)"**. 5명이 독립적으로
  같은 4개를 지적: (1) vDriver/DIVA 대비 실측 baseline 부재, (2) References 0개, (3) §3.4 정리 under-specified +
  novel-vs-borrowed 흐림, (4) 헤드라인 fragile(290× = 1k행·starved BP regime, TPC-C 1.4×로 붕괴; median이 25%
  degrade tail 숨김; N=16↔2/8 모순 등).
- **리비전 라운드 1 = Tier 1+2(새 측정 불필요한 전부) 반영·커밋·push**(`da50c9f`). 아래 §2.

## 2. 반영 완료 (리비전 라운드 1, `da50c9f`)

- N=16→serve N=8/vanilla N=3 per-cell · Fig3 곡선=single-run ≈775×/≈290× median 분리 · single vs 멀티런 숫자 flag ·
  construct_BAD 정의 · "DoD"→concurrent-HTAP · ⑤/⑥ 마커 제거 · §5.4 "22% miss" dangling 수정.
- **References 섹션 [1]–[8]** + inline citation 전환(⚠️ vDriver/DIVA/vWeaver 정확 서지 = "to confirm", 사용자가
  같은 연구실이라 확인 필요). vDriver=Kim et al., *Long-lived Transactions Made Less Harmful*, SIGMOD 2020.
- **§3.4 재작성**: superset 전제(registry ADD happens-before·lazy close·overflow floor) 가설 명시 + conservative
  right-edge(next view up_limit·seqlock) + **novel=serving-reduction(boundary 아님)** 으로 재프레이밍. §3.4가 F3의
  *전제*임 명시. mode-1 soundness(gen-gate/audit=detector) 명확화. setup table(§5.1, Ryzen 9800X3D·~30GB·NVMe·RR)
  + single-platform threat. vWeaver 특성화 + engine-modification spectrum + significance 단락. degrade tail 정직화
  (median 290× vs mean ~26s). eviction 완화. "standard TPC-C" 과장 완화(single STOCK aggregation). control 0.9× footnote.

## 3. 남은 일 = Tier 3 (새 측정 필요) — 우선순위순

### 3a. ⭐ vDriver head-to-head (최대 임팩트, 사용자 핵심 요청)
- **코드 있음**: github.com/hyu-scslab/vDriver (한양대 SCSLab). **이미 `/root/vDriver`에 clone됨(1.1GB, WSL 잔존)**.
  MySQL **8.0.17** fork(`/root/vDriver/mysql/mysql-server-8.0`, 842MB) + 그들 sysbench(`mysql/sysbench`) + 벤치
  스크립트(`mysql/script/run_init.py`·`run_11.py`·`calc_chain.py`, metric=version chain length CDF=우리 ⑤ 대응).
- **빌드 레시피**(그들 것): `cd /root/vDriver/mysql/mysql-server-8.0; bash cmake_local.sh; bash make_local.sh`
  (in-source·`DOWNLOAD_BOOST=1`·Release·port 3306). 그 후 `cd ../script; python3 run_init.py; python3 run_11.py`.
- ⚠️ **정석 Docker(Ubuntu 16.04) 경로 막힘**(이 WSL에 docker 미설치). **gcc-13 native 빌드가 유일 경로**이고
  **8.0.17(2019) vs gcc-13(2023) 4–5년 갭이라 컴파일 패치 여러 개 필요할 가능성 높음**(boost ~1.69 포함 깨질 수
  있음). **timebox로 시도**: cmake configure→make 첫 에러 wave 보고 patchable면 진행, wall이면 fallback.
- **fallback(C)**: vDriver 발표 수치(`/root/vDriver/vdriver_techreport.pdf` / SIGMOD'20) chain-length를 인용 +
  "same-hardware head-to-head는 toolchain 갭으로 precluded" 방법론 노트. (정직·약하나 가능.)
- **대안(B)**: WSL에 `apt install docker.io` + dockerd 띄워 Ubuntu 16.04 컨테이너 빌드(가장 안정적이나 dockerd
  셋업 불확실).
- **비교 측정(빌드 성공 시)**: vDriver MySQL vs 우리 AccelerateMVCC를 같은 held-read 벤치(q11식: write churn + held
  deep read, BP sweep)에 → latency(vDriver는 짧아진 chain walk vs 우리 serve-skip)·chain-length/memory 비교.
  버전 차이(8.0.17 vs 8.4.10)는 documented confound.

### 3b. 가벼운 측정 (확실한 win, vDriver와 독립 — 먼저 해도 됨)
- **GC-on memory+speedup 공존**: 현재 §5.3(memory)=GC-on, §5.4/5.5(speedup)=GC-off로 분리됨. GC-on 한 run에서
  live_versions(메모리 bound)와 held-read latency를 같이 보고. 새 스크립트 `build_q18_*` 한 개. ~30분.
- **64M vanilla baseline N≥5**: 현 N=3(102–133s spread). q11 vanilla만 N=5–8로 재측해 헤드라인 분모 강화.
- **중간 hot-table 실험**: 290×(1k행)와 1.4×(TPC-C large)사이 곡선 채우기 — 큰 테이블의 hot·BP-resident·deep-versioned
  subset에 held read. 설계 필요.
- **CH-benCHmark 쿼리 shape**: 현 STOCK 집계 하나 → Q1/Q6/Q12 추가로 regime 경계를 쿼리 모양별로.

### 3c. 비-측정 잔여
- **References 정확 서지 확정**(vDriver/DIVA/vWeaver) — 사용자가 같은 연구실이라 알 것.
- **한글 참고판 재생성**(영문 확정 후 자연스러운 한국어로).
- **(선택) LaTeX 조판(PDF)**.

## 4. 진행 방식
사용자 합의: Tier 3를 **점진적으로 할 수 있는 만큼**(당장 다 X). 추천 순서 = **3a vDriver 빌드 timeboxed 시도**(되면
최고, wall이면 3a-fallback C) + **3b 가벼운 측정 병행**. 빌드-heavy는 setsid 패턴(메모리 인프라 노트)으로.
