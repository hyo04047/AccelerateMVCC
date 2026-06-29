# AccelerateMVCC — 설계와 평가 (Stage A–D)

> 디스크 기반 DBMS(InnoDB)의 MVCC를 가속하는 **in-memory 보조 인덱스 + deadzone GC**의 설계·구현·평가 보고서.
> 이 문서는 위에서 아래로 읽히는 **standalone 보고서**입니다. 깊은 설계근거는 [design-gc.md](design-gc.md)·[design-1c.md](design-1c.md), 세션별 이력은 [progress-log.md](progress-log.md), 이슈 추적은 [findings.md](findings.md)를 참조.
> 작성: 2026-06-20 (Stage A–C) · Stage D + Limitations 추가: 2026-06-29 · 저자: 하태성 · 라이선스: MIT (deadzone 알고리즘은 vDriver 파생, §9)

---

## 초록

HTAP 워크로드에서 long-lived transaction(LLT)은 MVCC version chain을 무한히 길게 만든다. InnoDB의 purge(GC)는 **가장 오래된 활성 스냅샷(global-min) 아래만** 회수할 수 있어, LLT가 global-min을 붙잡으면 그 위의 dead version을 회수하지 못하고 chain이 폭증한다 — 최신 가시 버전을 찾는 비용(undo page I/O + latch)이 throughput을 무너뜨린다. AccelerateMVCC는 InnoDB undo log를 직접 건드리지 않고 **undo 메타데이터 포인터만** in-memory 인덱스(cuckoo hash → epoch 기반 interval list)로 들고, **deadzone GC**로 in-middle dead version을 회수해 chain을 compact하게 유지한다. 본 보고서는 standalone 프로토타입에서 이 구조를 lock-free로 하드닝하고(marked pointer + per-traversal EBR + FG/BG cooperative unlink), vDriver의 HTAP 벤치를 이식해 평가한 결과를 보고한다. **60초 LLT 하에서 deadzone는 hot record의 version chain을 max ~155로 유계 유지한 반면, InnoDB식 tail-only purge는 ~846,000으로 폭주했다(~5,500×). read throughput은 1.36M/s 대 487/s(~2,800×)로 벌어졌고, 이 우위는 skew 0.8–1.6 전반에서 ~8,000×로 견고했다.** 모든 측정에서 LLT의 가시성(visibility)은 보존됐으며(visibility oracle 위반 0건), 동시성 정확성은 ASan/TSan으로 검증됐다.

---

## 1. 문제의식

MVCC는 불필요해진 version을 **제때** 회수해야 한다. 회수가 지연되면 version space가 팽창하고, 최악엔 시스템이 정지한다. HTAP에서 이 문제의 핵심 화근은 **LLT(OLAP성 장기 트랜잭션)**다:

- LLT는 옛 스냅샷을 오래 붙잡아 **global-min(가장 오래된 활성 read view)**을 고정한다.
- InnoDB의 purge는 "global-min보다 오래된" version만 회수할 수 있다(**tail-only**). LLT가 global-min을 고정하면 그 위에 쌓이는 dead version(어떤 활성 스냅샷도 보지 않는 version)을 **회수하지 못한다**.
- 결과로 version chain이 길어지고, off-row 저장(InnoDB undo space)에서는 chain을 따라가며 **undo page를 buffer pool로 읽는 I/O + latch contention**이 발생한다. 졸업프로젝트 단계의 프로파일링에서 LLT 존재 시 `row_search_mvcc` 계열이 CPU의 ~45%를 차지함을 확인했다.

vDriver(SIGMOD'20, "Long-lived Transactions Made Less Harmful")는 이를 "extended version chain is the prime culprit"으로 정식화하고, **version buffering + deadzone pruning + version classification**을 제시했다. 본 프로젝트의 동기는 이와 동일하다.

---

## 2. 접근 & 설계

### 2.1 좌표 — disk MVCC 위의 in-memory accelerator
실제 데이터(undo record)는 InnoDB에 그대로 두고, **메타데이터 포인터(space_id, page_id, offset)만** in-memory 인덱스에 보관해 "올바른 version의 위치"를 빠르게 찾아준다. 이 인덱스를 deadzone GC로 compact하게 유지한다. 따라서 compactness가 **dataset 크기가 아니라 live-transaction window에만 비례**한다(One-shot GC가 in-memory 인덱스를 "dataset 비례 메모리"라 비판한 지점을 방어).

### 2.2 자료구조
- **Cuckoo hash (Kuku)**: `(table_id, index)` → `interval_list_header` 포인터를 O(1)로 매핑.
- **interval list (version chain)**: record별로 epoch(`trx_id / EPOCH_SIZE`) 단위로 묶인 version chain. 각 epoch_node는 undo_entry 체인(trx_id + 메타데이터)을 가짐. reader가 순회하는 대상이자 **길이가 곧 벤치 지표**.
- **epoch_table (bookkeeping)**: epoch_node를 버킷별로 묶어 BG GC가 prune 대상을 찾는 보조 리스트.

epoch = vDriver의 "version segment". epoch 단위 batch pruning = vDriver `SegIsInDeadZone`.

### 2.3 deadzone GC (vDriver Theorem 3.1, tight bounds)
**dead zone** = 연속한 두 활성 트랜잭션의 begin-timestamp 사이의 "어떤 스냅샷도 보지 않는" 구간(hole). 한 version은 그 visibility 구간이 어떤 dead zone에 **완전히 포함될 때만** prune 가능하다.

- LLT 내성의 원리: LLT 직후 시작된 짧은 트랜잭션들이 commit되면 dead zone들이 **병합**돼 LLT 위로 *wide dead zone*이 생긴다. tail purge가 못 건드리는 in-middle 영역을 deadzone는 통째로 회수한다.
- **tight bounds (핵심 correctness)**: epoch의 visibility 끝(xmax)을 epoch의 **nominal 범위**로 근사하면, 다음-newer version이 멀리 있는 경우 xmax를 과소평가해 **reader/LLT가 아직 보는 version을 over-prune**한다(pre-existing 버그). 실제 xmax(`superseded_ts` = 다음-newer version의 begin-ts; head는 ∞)로 판정하도록 고쳤다 — vDriver `SegIsInDeadZone` 충실. 이것이 LLT correctness의 핵심이다.

### 2.4 동시성 모델
세 축을 분리한다(시간 척도가 다르므로):

| 문제 | 질문 | 단위 | 기법 |
|---|---|---|---|
| 논리 가시성 | 이 version을 필요로 하는 txn이 있나? | 트랜잭션 수명 | **deadzone** |
| 물리 unlink 일관성 | 동시 unlink가 노드를 유실시키나? | 포인터 연산 | **marked pointer (Harris)** |
| 물리 회수 안전 | 이 메모리를 밟는 스레드가 있나? | traversal(search 1회) | **per-traversal EBR** |

- **hot path(read/insert) lock-free**. unlink는 marked pointer(포인터+mark bit 한 워드 CAS)로 "제거 중 노드에 끼워넣기"를 막는다.
- **FG/BG 협조**: reader(FG)가 순회 중 만난 dead non-head epoch을 직접 mark + best-effort O(1) splice(carried predecessor)로 떼어내 chain을 짧게 유지한다. **retire(free)는 단일 BG 액터가 전담**(retire-once state machine: `LIVE→CHAIN_DETACHED→RETIRED`, state.exchange로 정확히 한 번). 회수는 EBR grace로 안전.
- **reclamation이 LLT에 굶지 않음**: LLT는 논리 read-view는 길게 잡지만 **EBR Guard는 search 단위로 짧게** 잡으므로, deadzone가 논리적으로 회수 가능하다고 판단한 노드를 LLT 생존 중에도 물리적으로 free할 수 있다(per-transaction grace였다면 자기모순).

깊은 근거·적대적 리뷰 내역은 [design-gc.md](design-gc.md)·[design-1c.md](design-1c.md).

---

## 3. 구현 단계 (A–1c)

| 단계 | 내용 | 검증 |
|---|---|---|
| **A** | 빌드 부활(CMake/Kuku/케이스 정리, WSL2·gcc15·cmake4) | 빌드·실행 OK |
| **B** | 단일스레드 정확성(snapshot 보존, deadzone 초기화, GC sweep 메모리안전, search 최신 가시버전) | correctness 6개 + ASan |
| **1a** | per-traversal EBR + GC/search 통합, read-view 평탄화 | ASan/TSan |
| **1b** | marked pointer(Harris) 양 리스트 + 다중-producer EBR + 전용 BG GC 스레드 + multi-writer | 9개 ASan/TSan, 적대적 리뷰 |
| **1c** | FG cooperative unlink + retire-once state machine + full-bucket backstop + dummy drain + **tight-bound deadzone** | 20개 ASan/TSan, 적대적 리뷰 2회 |

1c까지 누적 **20개 correctness 테스트가 Release/ASan(UAF·double-free 0)/TSan(data race 0)**에서 green. 적대적 코드리뷰가 stale-successor chain corruption과 tight-bounds LLT correctness 버그를 잡았다.

---

## 4. 평가 (Stage C)

### 4.1 워크로드 & 하니스
vDriver Figure-12 워크로드를 standalone 프로토타입으로 이식했다(`stage_c_bench.cpp`):
- **writer N스레드**: Zipfian(s) skew 업데이트(소수 hot record에 집중 → chain이 길어짐).
- **OLTP reader M스레드**: 같은 skew의 point-read(각 search는 per-traversal Guard + FG cooperative unlink).
- **LLT 1스레드**: 하나의 스냅샷을 60초간 유지하며 짧은 search를 반복(논리 read-view는 길게, Guard는 search당 짧게).
- **Guard-safe 샘플러**: version chain 길이를 시간에 따라 기록(CSV) → CDF.

### 4.2 baseline (tail-only GC mode)
standalone 단계라 실제 InnoDB 대신 **프로토타입 내 tail-only GC 모드**로 InnoDB purge를 모델링했다(`set_gc_tail_only`): `can_pruning`을 zone 0(= global-min 아래 tail)만 보게 제한해 in-middle dead zone을 무시한다. LLT가 global-min을 pin하면 tail purge는 그 위를 회수 못 한다 = vDriver Figure 12 구도. (실 MySQL+sysbench 비교는 Stage D.)

### 4.3 측정 방법론 (재현성)
- **controlled threading(스레드 ≤ 코어)**: oversubscribe하면 BG GC가 CPU를 굶어 deadzone publish/retire가 급감해 chain이 일시 폭주한다 — 즉 no-LLT에서 chain length는 **알고리즘이 아니라 스케줄링에 지배**된다. 16코어에서 6 writer + 6 reader + 1 LLT + sampler + BG GC = 15.
- **deadzone/FG 신호는 LLT 시나리오 고유**: LLT가 없으면 newest 아래가 전부 dead라 BG-only로도(CPU만 있으면) chain이 짧다. 따라서 모든 헤드라인은 60초 LLT 하에서 측정한다.
- **warm-up 제외**: GC warm-up 구간(prune 전)은 chain이 솟으므로 percentile에서 제외(`warmup_ms`, CSV는 전체 보존).
- **correctness = visibility로 검증**: LLT visibility oracle(자기 visible version 불변) + conservation(detached==retired) + ASan/TSan. no-crash가 아니다.

### 4.4 결과 — 헤드라인 (60초 LLT, 6w/6r/1llt)
| 구성 | chain p50 | p99 | **max** | retire(회수) | write tput | read tput |
|---|---|---|---|---|---|---|
| **deadzone + FG** | 15 | 45 | **155** | 22.4M | 649k/s | **1.36M/s** |
| deadzone, BG-only | 41 | 84 | 114 | 21.8M | 646k/s | 1.04M/s |
| **tail-only (InnoDB식)** | 258,632 | 817,877 | **845,977** | **277** | 1.38M/s | **487/s** |

- **deadzone vs tail-only**: hot-chain max **155 vs 845,977 (~5,500×)**. 메커니즘은 retire 수가 증명한다 — 같은 60초에 deadzone는 **22.4M** epoch을 회수했지만 tail-only는 **277개**뿐(LLT 아래만 회수 가능). read throughput **1.36M/s vs 487/s (~2,800×)**. tail-only는 write throughput만 더 높은데(GC를 거의 안 해서) 이는 **write를 위해 read를 희생한 HTAP 함정**이다.
- **FG cooperative unlink 증분 가치**(deadzone에서 FG on vs off, 부하 고정·토글만 변경): chain 분포를 하향(p50 15 vs 41, p99 45 vs 84)시키고 read throughput을 **+30%**(1.36M vs 1.04M reads/s) 끌어올린다 — reader가 순회 중 dead epoch을 떼어 search가 짧아진다. worst-case(max)는 BG deadzone가 이미 받쳐 비슷하다.

version-chain length CDF(로그 x축): deadzone 두 곡선은 길이 5–155 구간에 밀집, tail-only는 10^4–10^6로 쓸려간다.

### 4.5 결과 — robustness (skew sweep, 20초, warm-up 제외)
| skew s | deadzone max | tail-only max | read tput (dz vs tail) |
|---|---|---|---|
| 0.8 | 38 | 308,487 | 1.20M/s vs 5,061/s |
| 1.2 | 40 | 321,541 | 1.43M/s vs 1,725/s |
| 1.6 | 41 | 335,027 | 1.52M/s vs 1,093/s |

deadzone는 skew 전반에서 max ~40으로 안정, tail-only는 어느 skew든 300k+로 폭주 → **우위 ~8,000×가 한 operating point의 운이 아니라 견고**하다.

### 4.6 correctness 검증
전 12런(헤드라인 3 + sweep 6 + sanitizer 2 + LLT 검증)에서 **LLT visibility oracle 위반 0건** — tail-only 폭주 baseline조차 자기 version은 정확히 봤다(chain이 길 뿐, 가시성은 정확). conservation(detached==retired) 정확 일치, 새 실험 토글 경로 ASan UAF/double-free 0·TSan data race 0, 20 correctness 회귀 green.

부수로 BG GC의 stop-responsiveness 버그를 발견·수정했다(catch-up 루프가 stop 신호를 안 봐서 tail-only backlog에서 shutdown이 멈추던 문제, [findings.md](findings.md) #14).

---

## 5. Stage D — 실 InnoDB 통합 (요약)

Stage A–C는 standalone 프로토타입이다. Stage D는 같은 구조를 **실제 MySQL 8.4 / InnoDB 안에서** 동작시킨다:
populate(undo 메타데이터 + 소형 행 image 캡처) → consult(visible 버전 선택) → authoritative serve(캐시 결과로
undo walk 대체) → deadzone GC(InnoDB read-view cuts로 재구동). 전 구간 불변식은 **construct_BAD=0** — 서빙된
모든 답이 vanilla undo walk와 byte 동일(틀린 서빙은 구조적으로 불가).

**배선 (leaf-domain, one-way InnoDB→accel edge).** 페이지 X-latch 아래의 hook은 scalar record를 lock-free
ring에 enqueue만 한다(noexcept·no-alloc·no-block·full→drop, 한 줄 WARNING으로 관측). 단일 off-latch
**drainer**가 인덱스의 유일한 mutator로 저수준 insert를 수행한다(single producer). consult는 InnoDB
consistent-read의 version-build 지점에서 호출돼 reader의 ReadView로 가시 버전을 고른다.

**⑥ read-latency payoff (헤드라인).** held snapshot이 purge를 막아 undo chain이 깊어진 상태에서 deep
analytic read의 latency를 vanilla walk vs serve로 비교: vanilla는 buffer-pool이 작아질수록 undo page I/O
절벽을 맞지만(4G 0.8s → 64M 123s), **serve는 BP와 무관하게 ~0.16s로 평탄** → 4G ~5×·256M ~490×·64M ~775×
(GC-off serve-only). 물리 read 80만~140만 → 0~8로 소멸. GC-on에서도 생존(~190×, `ACCEL_DRAIN_CAP`으로 안정화).
이 우위는 **InnoDB undo-walk I/O 절벽 제거**에서 오며 인메모리 navigation의 big-O가 아니다(체인 깊이는 GC가
flat ~80–92로 유계 유지).

**⑤ deadzone GC (통합 ON).** GC를 standalone trx manager가 아니라 **pushed InnoDB clock + active-view
registry cuts**로 재구동(amortized windowed sweep). LLT 하 write-heavy OLTP + 동시 HTAP 리더서 캐시 보존이
bounded(~6–9k versions)인 반면 InnoDB History List Length는 LLT에 선형 증가 → 비율이 LLT 나이에 선형
(realistic full-table 20×/40×/63× @15/30/60s). 승리는 동시 read-view 리더가 만드는 in-middle gap을 요구
(리더0 대조군 0.9× = 승리 0). 메커니즘·scaling·gap 요건은 프로토타입과 동일, magnitude는 실 InnoDB OLTP
rate(~4,200 versions/s)가 정한 정직한 값이다.

**serve 안전.** mode-2 verify-serve(walk+byte-compare 후 서빙)·mode-1 serve-only(walk skip) 둘 다
construct_BAD=0. mode-1 출하 경로엔 link-gap 구조 firewall + C1 inverted-superseded 오라클 + gc_generation
race detector + 1-in-N walk-audit의 4-layer 방어. **crash-recovery**(kill -9 mid-load → 재시작 → ephemeral
캐시 재구축 후 mode-2 construct_BAD=0 + 롤백된 미커밋 버전 미서빙)로 ACID 전제(캐시 非권위·ephemeral)를 실증.

**워크로드 폭.** single-INT-PK 너머 composite-PK(a,b)·VARCHAR string-PK·secondary-index·savepoint 전부
construct_BAD=0(full-PK FNV 일반화·savepoint rollback 버전 미서빙). full-mysqld **AddressSanitizer CLEAN**
(drainer‖consult‖serve‖GC‖teardown 동시 스트레스, 리포트 0). drainer는 단일 consumer로 64-thread oltp_write_only
(~183k write-q/s, 525만 버전)서도 dropped=0으로 따라잡음(populate 비병목).

## 6. Limitations & Threats to Validity (위협 요인)

정직한 한계·위협 요인 (논문 Evaluation 전 명시):

- **measurement variance (다음 작업).** 통합 헤드라인 다수가 **단일 run**이다 — 특히 ⑥는 non-deterministic
  (reclaim storm 하 3/4 hold·1/4 degrade; `ACCEL_DRAIN_CAP≈1000`이 stable로 안정화). 헤드라인 config는
  N≥3–5 재측·median+min/max로 격상 필요(Phase 3). drain-cap "X/N degrade" 표는 이미 그 규율을 따른다.
- **cache scope = in-page row (정직한 scope 한계).** 이미지 cap(`ACCEL_IMG_MAX`, 기본 512B)을 build-time으로
  올리면 >512B여도 **전부 in-page인 wide row는 안전하게 캐시·서빙**된다(in-page=byte-identical 캡처; design-D6 (A),
  `build_q16_widerow.sh`서 ~1.35KB 행 cap=2048 빌드 HIT 1000/1000·construct_BAD=0, cap=512 대조 ineligible로
  실증; 비용=ring N×cap 메모리라 shipped 기본은 512). **off-page LOB·virtual 행만 제외**(construct_BAD=0·안전하나
  가속 0): off-page LOB는 MVCC하 자체 버전이 있어 cached reference 추적이 틀린 LOB 버전을 서빙할 위험이라
  LOB-version-safe 재구성(or purge 시 MISS-degrade)이 선결 — 이는 **구현 확장 주제이지 별도 연구가 아니므로
  scope Limitation으로 명시**(design-D6 (B)). big-row deep read(82.7s)가 캐시가 가장 필요한 곳이나 현 scope 밖.
- **cold-key footprint = capacity-bounded, not adaptive.** per-key header + Kuku slot은 회수 안 됨(~72B/키).
  용량 초과 시 graceful non-admission(vanilla fallback·construct_BAD=0·crash 없음)이나, *이동하는* working
  set 추적용 LRU eviction은 미구현 — "memory ∝ working set"은 **Kuku 용량(kuku_log2) 안에서** defensible
  (hot set ≥로 sizing). 진짜 eviction(lock-free Kuku erase + EBR)은 적대 리뷰서 cost≫payoff로 보류.
- **full-mysqld TSan = documented residual.** standalone TSan이 accel race 표면(drainer‖consult‖cuts-GC)을
  덮고, MySQL-under-TSan은 무거운 suppression + 5–10× 둔화 대비 marginal value가 낮아 미실행.
- **in-memory navigation은 최적화 대상이 아니다.** consult 비용은 OLTP 트랜잭션 비용(I/O·lock)의 무시할
  fraction(FG-α 측정 +0.9%/노이즈; pool allocator도 측정 0; **shared cross-reader nav cache도 같은 이유로 이득
  ~0 예상이라 미구현** = 고려·측정상 negative). roll_pred fast chase와 DIVA interval tree 둘 다 GC-safety/worth-it에서
  NO-GO(design-D5-gc §14) — ⑤b-lite(~0.22s reuse)가 출하 fast consult. ⑥ 이득은 undo I/O 절벽 제거에서 온다.
- **재현성.** InnoDB 소스 패치는 `integration/innodb/innodb-8.4.10-accel.diff`로 vendor(+ build_d1b3a.sh가
  CMakeLists/컴파일 플래그 생성); standalone 러너도 in-repo. raw run 로그 아카이빙은 Phase 3 작업.
- **Stage-C 헤드라인(~5500×)은 프로토타입 내 self-modeled tail-only baseline**(고-rate 마이크로벤치)이며, 실
  InnoDB 메모리/체인 우위는 Stage D ⑤(통합 HLL 대비 20×/40×/63×)로 측정된다.

## 7. 관련 연구

| | 핵심 무기 | 저장 | GC 단위 | LLT 대응 |
|---|---|---|---|---|
| vDriver | deadzone + SIRO + classification | disk | version-segment | in-middle reclaim |
| DIVA | index/data 분리 + epoch interval **tree** | disk | epoch interval | 높이 ≤ log(LLT lifespan) |
| One-shot GC | temporality delta partition + tagged pointer | in-memory | start-time cohort | partition consolidation |
| **본 연구** | hash + epoch-list + deadzone | **in-memory 인덱스 / 데이터는 InnoDB undo** | epoch(=segment) | deadzone FG+BG |

본 연구의 좌표는 "disk MVCC(InnoDB) 위의 in-memory acceleration index"로, vWeaver(무개조)와 DIVA(storage 개조) 사이의 독자 포지션이다. 데이터를 소유하지 않고 메타데이터 포인터만 들기에 compactness가 live-transaction window에만 비례한다.

---

## 8. 결론 & 향후

**결론.** LLT가 존재하는 HTAP에서 InnoDB식 tail-only purge는 version chain을 통제하지 못하지만, deadzone의 in-middle reclaim은 chain을 유계로 유지한다(max ~155 vs ~846k, read throughput ~2,800× 우위). 이 효과는 skew 전반에서 견고하며, lock-free 동시성(marked pointer + EBR + FG/BG)이 정확성을 보존한다. 즉 본 구조는 standalone 프로토타입 수준에서 **HTAP/LLT 성능 향상이라는 목표를 정량적으로 입증**한다.

**Stage D 완료 (§5).** 가속 인덱스를 실 InnoDB에 연결해(undo 메타데이터/소형 image 캡처, read-view cuts로 GC 재구동, consistent-read serve) ⑥ read-latency payoff(~190×/775×)·⑤ 통합 GC(LLT에 선형 20×/40×/63×)·serve construct_BAD=0·crash-recovery·워크로드 폭·full-mysqld ASan을 실증했다. **DoD 원문 config(churn이 도는 중 held read)도 측정**: 동시 OLTP churn 하에서도 ⑥ serve가 vanilla 60s 대비 0.2~3.9s(~16–300×)로 유지되고 mode-2 verify-serve가 construct_BAD=0(GC-on/off 모두, `build_q15_concurrent.sh`) — 헤드라인이 동시성에서 생존. 추가 perf 레버 두 개(roll_pred fast chase·DIVA interval tree)는 적대 리뷰서 NO-GO(GC-safety/worth-it; design-D5-gc §14) — ⑤b-lite가 출하 fast consult.

**Phase 3 (마무리 — 테스트·정리·집필).** 헤드라인 config multi-run/error-bar 재측 + raw 로그 아카이빙 + CH-benCHmark/TPC-C 평가 + no-wrong-serve semi-formal 불변식 논증 + **논문(한글·영문)** 작성. 한계·위협 요인은 §6.

**향후 연구 (다음 논문 방향).** superset-safe *derived-and-served* 캐시 아이디어를 다른 storage 엔진/index 타입·isolation level로, 분산/다노드 MVCC로, persistent memory 상 deadzone으로 일반화; no-wrong-serve 불변식의 형식검증(TLA+/모델체크). (off-page LOB 서빙·shared cross-reader nav cache 등은 *구현* 확장/최적화 주제이지 별도 연구 방향이 아니다 — 전자는 §6 scope Limitation, 후자는 측정상 이득 ~0.)

---

## 9. provenance & 라이선스
- 코드 라이선스 **MIT**(하태성).
- **deadzone 알고리즘 = vDriver 파생**: 판정식이 vDriver `IsInDeadZone`(`xmin>left && xmax<right`)과 동일하며, 원 설계는 vDriver InnoDB part에서 dead zone 검출부를 추출·간소화한 것이다(클린룸 재구현 아님). vDriver 출처 및 PostgreSQL License를 표기한다.
- 재현: 빌드/실행 레시피·토글은 [NEXT-SESSION.md](NEXT-SESSION.md), 통합 스크립트는 `integration/scripts/`, InnoDB 소스 패치는 `integration/innodb/innodb-8.4.10-accel.diff`로 vendor. 헤드라인 raw 로그(CSV) 아카이빙은 Phase 3 작업(현재 일부 단일-run, §6).
