# Open items / deferred goals / threats-to-validity (전수 감사, 2026-06-23 세션 8)

> 목적: 여러 세션에 걸쳐 "optional / best-effort / deferred / residual / future-work / 최종검증 별도 /
> document-the-residual / scope-to-X"로 표시돼 **조용히 넘어간 항목을 전부** 한 곳에 박아, 성능/정확성
> 목표가 데이터가 아니라 재분류로 사라지지 않게 한다. **북극성 = 성능**(correctness는 전제).
> 출처: 9-에이전트 전수 감사(8 sweeper + synthesizer). 각 항목은 실제 파일에 근거(파일·section·line).
> **분류**: ⓠ 조용히 버려질 위험이 있는 목표 / ⓝ 논문 전 필요 / ⓣ 명시 추적(future work 가능) / ⓞ 진짜 optional.

## 0. 한 줄 진단
⑥ 성능 payoff는 **GC-OFF 전제** 위에 있고, ⑤ bounded-memory는 **통합에서 한 번도 미실증**(GC 미기동). 측정된 성능
기여(FG cooperative +30%)가 "optional"로 강등돼 계획에서 빠짐. 메모리 무한성장 구멍 2개가 "fix later/문서화"로
방치. 정확성·커버리지는 **쉬운 단일-lineage 워크로드에서만** 측정. **논문 draft·분산(multi-run) 데이터는 어디에도
없음**(모든 latency가 단일 수치).

## 0b. 세션 9 갱신 (2026-06-27) — ⑤a-2(GC ON) + 5-2b serve(C1·C2) + ⑥ GC-on 재측
> ⑤a-2(GC ON)를 적대적 리뷰(54 agents, design-D5-gc §9) 후 5-step 완료(커밋 `b83adb2`~`beeefc8`).
> 이어서 5-2b(serve under GC)를 리뷰(44 agents, §10) 후 C1(안전망 오라클)+C2(mode-2 verify-serve 정확)
> 완료, ⑥ payoff가 GC-on서 생존 실증(커밋 `bc3003c`~`b2d8e55`). 전부 push. 아래 항목 상태가 바뀜.

**닫힘(CLOSED):**
- ⓝ1 [blocker] GC가 통합서 한 번도 안 돎 → **GC ON·실제 sweep**(retired 68만, windowed 우세). 캐시 더는 무한성장 X.
- ⓝ10 EPOCH_SIZE blind 상수 / sparse id → **epoch를 InnoDB id space에 normalize**(base-relative)로 해소, 부팅 storm도 제거.
- ⓣ12 deadzone clock·superset 미러가 wired-but-미소비 → **소비됨**(cuts-driven GC가 registry snapshot으로 구동).

**대부분 닫힘(MOSTLY — 잔여 명시):**
- ⓝ8 overflow-floor never-reset → **pool을 4096으로 sizing**(design §6 허용)해 realistic concurrency서 overflow 미발생(floor=none@64thr). 잔여: 지속 >4096 동시 view면 over-protect(메모리만, 안전); racy single-scalar reset은 의도적 미구현.
- ⓝ5 통합 ASan/TSan 미실행 → **drainer‖consult‖cuts-GC를 ASan/TSan clean**(focused harness, 통합과 동일 race 표면). 잔여: full-mysqld ASan(gold-standard)·LOB/FTS/spatial.
- ⓝ13 view-reuse ADD-on-open 완결성 → GC-on shadow서 open_calls==published·construct_BAD=0 확인. 잔여: serve(5-2b).

**진행/부분 닫힘(세션 9 이어서):**
- ⓝ2 / ⓝ3 / ⓝ15 serve+GC correctness, M2 wrong-serve oracle → **5-2b 진행**: C1(interior-over-prune 오라클 strict+inverted, `correctness_test.cpp`; superseded_ts inversion[surface C]이 conservative 실증) ✅ · C2(mode-2 verify-serve가 GC 위에서 construct_BAD=0, oltp_read_write 32thr 49만 served) ✅. **남음 = C3**(mode-1 serve-only 출하 = gc_generation 2번째 방화벽 + walk-audit 샘플링) · savepoint edge(ⓝ15) · full-mysqld ASan.
- ⓠ4 ⑥를 GC-on서 재측 → **부분 ✅**: held-reader deep read가 GC-on서 생존(64M 98s→0.45s ~190×, hit 2000/2000, SUM 정답). in-middle 회수는 활성 뷰 ≥2개여야 hole이라 단일 held-reader는 체인 intact. **남음**: multi-reader in-middle(GC가 실제 in-middle 회수하며 serve와 상호작용 = ⑤b가 빛나는 곳) · oltp_read_write/동시 HTAP latency.

**여전히 열림(STILL OPEN):**
- ⓠ1 ~0.16s fast consult → **⑤b-lite ✅ 완료**(2026-06-27, design-D5-gc §11). 리뷰(34 agents)로 원래 back-edge chase NO-GO(UAF 재오픈·드레이너 WAF·multi-reader서 chase 끊김) 판정 후 **GO=⑤b-lite**(map walk link table을 header에 메모이즈; GC retire가 free 전 cache clear=안전; node_count로 freshness; publish는 build 중 insert 미발생 시만=churn EBR flood 방지). 검증: standalone Release36/ASan25/TSan25 · C2 mode-2 construct_BAD=0(421k served) · **⑥ 64M held-reader deep2(reuse) 0.45s→0.22s ~2× (~470× vs vanilla 104s)·hit 2000/2000·SUM 정답**. **back-edge chase 폐기**(0.16s 위해 16 must-fix·UAF 질 이유 없음). 잔여: 첫 스캔은 빌드 비용(reuse만 빠름=단일-reader regime, multi-reader선 rebuild=map walk). ⓠ2 FG +30%는 별개 roadmap(perf 후퇴 아니면 채택).
- ⓝ9 cold-key 미회수(진짜 unbounded) → 구현 or 문서화.
- ⓠ3 write-heavy+LLT로 in-middle 이득 생존 / ⓠ5 22% MISS effective speedup / ⓝ6 LOB / ⓝ11 signal-B sweep → **Phase 2**.
- ⓝ14 REPORT Limitations / ⓣ10 패치 vendor / multi-run·error-bar / 논문 한글+영문 → **Phase 3**.

## 0c. 세션 10 갱신 (2026-06-28) — C3(mode-1 출하) 완료 + ⑥ chain-sever 특성화 + GC-쪽 완성을 FG+BG로 deferral
> C3(mode-1 serve-only 안전 출하)를 적대 리뷰(42 agents)→C3-a(gc_generation 2nd firewall + 오라클)→C3-b(1-in-N
> walk-audit)→C3-c(soak+ship gate)로 진행. ⑥ 재측에서 chain-sever 발견·특성화·healing NO-GO. design-D5-gc §10.1·§12.

**닫힘(CLOSED):**
- **C3 mode-1 SAFE serve ✅** — gc_generation 2nd firewall(race detector, GC retire 때 bump·consult가 Guard-open snapshot+HIT 전 recheck, mode-1 한정) + 1-in-N walk-audit(observe-only, N=0이면 mode-1 거부) + 4-layer 분업 명시(link-gap·C1 oracle·audit·gen-gate). standalone Release38/ASan27/TSan27, integration construct_BAD=0(oltp_read_write mode-1 45만 served·audit 1.45만 전부 vanilla 일치·강제 divergence는 audit trip). 커밋 `6025021`(C3-a)·`3b21003`(C3-b).
- **ⓣ4 session-7 잔여 newer / gen-gate GC-on 재확인** → C3-a 오라클 + integration construct_BAD=0로 닫힘.

**특성화·문서화(PERF-only, 버그 아님):**
- **⑥ chain-sever 긴장 확정·특성화·deferral** — GC가 navigation 경로(중간 dead 버전)를 회수하면 lineage 재구성 chase가 끊겨(chase_break, 계측 split로 확정 861/862·GC dummy-drain 486k) consult MISS→walk. **construct_BAD=0 항상**(PERF-only, 절대 틀린 답 X). 특성화(4 run): **3/4 hold(~4.7s ~19×) / 1/4 degrade(~90s walk), reclaim storm과 상관, 항상 정답.** 설계 탐색(22)→GC-side link-healing 추천→적대 리뷰(32) **NO_GO**(⑤b 긴장을 perf-collapse[안전]→correctness-race[위험]로 악화, WAF 안전변형은 ⑤b-lite로 수렴). **결정: GC-쪽 완성을 FG+BG GC 스테이지로 deferral**(체인-sever는 GC-쪽 긴장이고 FG cooperative reclaim이 reclaim dynamics를 바꿈 → 한 묶음으로 완성). 유일 sanctioned 경로 = GC-clear-tolerant memoized-lineage(⑤b-lite 진화형, live state 유도, chased mutable graph 금지). design-D5-gc §12. 진단계측 유지(`ACCEL_GEN_GATE` 토글·`gcrace`·noncontig split).

**FG+BG GC 스테이지 ✅ 완료 (design-D5-gc §13):**
- 설계 탐색(22+17 agents): **β(sever 살아남는 navigation 구조)는 guardrail 안에서 구조적 불가** 재확인(healing의 재탕). GO=α+GC-tuning.
- **α(FG cooperative reclaim 통합) = 측정상 이득 0** — consult Pass-1에 splice 이식(serve-safe·construct_BAD=0·standalone Release39/ASan28/TSan28), 3 config A/B(+0.9%/+0.06%/-0.6% 노이즈). consult가 OLTP 비용의 무시할 fraction·BG가 체인 짧게 유지. Stage-C +30%는 read-only microbench 아티팩트. ablation knob(default off)로 보존.
- **GC-tuning drain-cap = ⑥ stabilizer(스테이지 실수확)** — dummy-drain storm이 sever 주범. `ACCEL_DRAIN_CAP`로 per-cycle reclaim cap. 곡선(30+ run): cap=0 2/8·5000 1/8·**1000 0/6·500 0/6 degrade**(construct_BAD=0 전부). 메모리(dummy_pending)는 cap 무관 hold ~380k·∝window(30s 380k→60s 755k=⑤ 유지). **⑥를 fragile(1/4)→stable로.** ⑥-serving 권장 `ACCEL_DRAIN_CAP≈1000`(default 0 유지).
- 커밋 `71f0cfd`(α)·`1f92ea2`(drain-cap+테스트하드닝). standalone 39 5/5 안정(flaky 3개 fix).

**다음 = Phase 2(워크로드 폭·LOB·write-heavy+LLT in-middle·savepoint) → Phase 3(패치 vendor·Limitations·multi-run·논문 한글+영문).** ⑤b 0.16s는 안전 틀(memoized-lineage)에서만, 별 우선순위 아님(0.22s reuse 이미 있음).

## 0d. 세션 11 갱신 (2026-06-28) — Phase 2 착수: ⓠ3(in-middle 헤드라인 실 InnoDB 생존) CLOSED
> Phase 2의 최우선 ⓠ3를 통합 mysqld에서 측정. read-only retention reporter(`accel_hook.cc`, env `ACCEL_RETENTION_MS`,
> 기본 off=중립) + 깨끗한 version-단위 카운터(`entries_retired`)를 추가. 상세 데이터·방법론 [phase2-q3-llt.md](phase2-q3-llt.md).

**닫힘(CLOSED):**
- **ⓠ3 in-middle 헤드라인이 실 InnoDB에서 생존·확정** — write-heavy OLTP + held LLT + 동시 HTAP 리더 하에서 캐시 live_versions는 bounded(~6–9k), InnoDB HLL은 LLT 시간에 선형 증가 → **비율이 LLT 나이에 선형 성장: 20×/40×/63×@15/30/60s**(realistic full-table). pinned hot-set도 10×/21×/42×. **5-3 후퇴 트리거 안 됨.** 승리는 동시 read-view 리더가 만드는 gap을 요구(리더0 대조군=0.9× 승리 0). magnitude는 프로토타입 5500×(고-rate 마이크로벤치)와 다르나 메커니즘·scaling·gap 요건 동일(실 InnoDB OLTP rate가 정함).
- **ⓠ3 부산물**: ① in-process tail-only 캐시 모드(`ACCEL_TAIL_ONLY`)는 throughput을 ~5× 떨어뜨려(시간에 따라 악화) apples-to-apples baseline 부적합 → **실 InnoDB HLL을 baseline으로**(더 정직). ② metric 단위 교훈: `drained−epochs_retired`는 version과 epoch를 섞어 승리를 ~2×로 가렸음 → `drained−entries_retired`(version 단위)로 63× 회복.
- **ⓠ5(22% MISS effective speedup) CLOSED — 긍정 해소** — held analytic reader(캐시의 실 타깃)는 write-heavy+delete/insert churn에서도 **HIT ~99.8–100%**(held snapshot이 churn 전이라 reader는 원본 행만 필요=캐시됨; 22% MISS는 head 근처 *짧은 reader*의 workload-wide 수치로 캐시 불필요 대상). effective speedup: resident ~3×, **I/O-bound(64M) ~34×**(undo I/O 23,783→352), construct_BAD=0 전부. oltp_read_write workload-wide HIT도 78%→94%(세션8 수정). 재현 `build_q5_writeonly.sh`. 상세 phase2-q3-llt.md ⓠ5 섹션.

**진행/부분(세션 11):**
- ⓠ4(⑥ realistic) 부분 보강 — held-reader 체인 깊이 flat(~90 epochs) 재확인. 동시 HTAP latency 별도.

**다음 = Phase 2 잔여(LOB ⓝ6 · oltp_read_write 22% MISS ⓠ5 · savepoint ⓝ15 · secondary-index/composite-PK · full-mysqld ASan/TSan ⓝ5) → Phase 3(논문).**

---

## ⓠ 조용히 버려질 위험이 있는 목표 (최우선 — 사용자 핵심 우려)

1. **consult ~0.16s fast-path이 GC-on에서 ~0.4s 회귀(또는 UAF)** — `accelerateMVCC.cpp:317-354`(단일 Guard가
   roll_pred chase 전체를 덮으나 주석은 드레이너만 논함, GC free는 미논의) + `interval_list.h:58`(raw roll_pred) +
   `design-D5-gc.md §2`(stale: O(C) 재설계 전 모델). **⑥ 헤드라인이 이 chase에 통째로 의존**, 현재 안전한 건 GC-off라서뿐.
   → **⑤b**: GC-safe fast consult(GC-nulls-back-edge) 구현 + ASan/TSan-under-GC + ⑥ GC-on 재측(0.16s 유지 확인).
   design-D5-gc §2 pillar 2를 roll_pred 모델로 갱신.
2. **FG cooperative reclaim(signal C) — 측정된 +30% read를 "optional"로 강등, 5-x 계획에 없음** —
   `design-D5-gc.md §3 C / §7`(증분 없음); Stage-C 결과 `REPORT.md §4.4`(read tput +30%, p50 15 vs 41).
   in-middle 체인 단축의 유일한 O(1) 경로. → **명시 결정**: signal C를 통합에 스케줄해 +30% 재현, **또는** 논문이
   "통합은 BG-only로 출하, Stage-C FG 이득 미포함"을 명시. 침묵으로 버리지 말 것. **(2026-06-27 사용자: 이건 '결정' 항목이 아니라 ROADMAP 항목 — perf 후퇴가 아닌 한 FG를 통합에 넣는다. ⑤b/FG+BG 트랙과 함께 진행; 유일한 gate는 "perf 후퇴 없음".)**
3. **[CLOSED 세션 11] 5-3의 사전 인가된 후퇴: "in-middle hole 밀도 부족하면 tail-only로 축소하고 LLT-claim 포기"** —
   `design-D5-gc.md §7 5-3`. 프로젝트 **중심 헤드라인**이 여기서 붕괴 가능했음. → **실 InnoDB write-heavy OLTP+LLT+HTAP에서
   측정 완료: 붕괴 아니라 생존.** 캐시 bounded·InnoDB HLL 선형 증가·비율 LLT에 선형(20×/40×/63×@15/30/60s), gap(동시 리더)
   요건 확인. 후퇴 트리거 안 됨. 상세 [phase2-q3-llt.md](phase2-q3-llt.md), §0d.
4. **⑥ read-latency가 단 1개 좁은 워크로드(oltp_update_non_index, 1테이블 1000행, churn 중단 후 측정)에서만** —
   `build_d6.sh`. 문서 스스로 "쉬운 단일-lineage" 케이스라 명시. realistic mixed(oltp_read_write, 동시 HTAP)에서
   ⑥ latency 미측정. Stage-D DoD는 "동시 sysbench HTAP vs vanilla"였음. → oltp_read_write(+동시 OLTP) ⑥ 재측.
5. **[CLOSED 세션 11] consult HIT율이 oltp_read_write서 78%로 하락 — 22% delete+reinsert MISS** —
   `design-D4b-shadow.md §15.6 잔여①`. → **측정 완료: 캐시 타깃인 held analytic reader는 HIT ~99.8–100%**(22%는
   head 근처 짧은 reader의 workload-wide 수치=캐시 불필요 대상). effective speedup resident ~3×·I/O-bound(64M) ~34×·
   construct_BAD=0. workload-wide도 94%(세션8 수정). 상세 phase2-q3-llt.md ⓠ5, §0d.

---

## ⓝ 논문 전 필요 (claim 뒷받침)

1. **[blocker] ⑤ GC가 통합에서 한 번도 안 돌아 'bounded working-set memory' 전체 미실증** — `accel_hook.cc`(BG GC
   NOT started); 5-2/5-2b/5-3 전부 미착수. 캐시는 설계상 무한 성장 중. **메모리 절반은 측정된 결과로서 아직 존재하지 않음.**
2. **[blocker] M2 interior-over-prune wrong-serve oracle 미구축; serve+GC 동시 미검증** — `design-D5-gc §6 M2 / §7 5-2b`.
   GC+serve에서 중간-과회수가 fallback 없이 틀린 older image 서빙(유일한 비-perf-only 과회수). serve는 그래서 OFF 유지 중.
   → directed oracle(known-live view 누락 → wrong-HIT 검출) 구축 + adjacency 재검증/contiguity 무효화.
3. **serve(ACCEL_AUTHORITATIVE) 기본 OFF; perf를 내는 mode-1의 GC-on correctness 미검증** — 출하 기본은 speedup 0(shadow).
4. **serve correctness가 sysbench 2종에서만 입증 — 새 워크로드마다 새 결함 발견 이력**(oltp_read_write서 construct_BAD=18625
   터짐). FTS/spatial/partition/composite-PK/secondary-index/savepoint 미검증.
5. **최종검증 매트릭스(LOB/FTS/spatial/큰 비-resident 테이블/full mysqld ASan+TSan) 매 세션 약속·미실행** — **현재 모든
   sanitizer 증거는 standalone뿐**; 통합 경로(드레이너‖consult‖동시 reader‖미래 GC)는 ASan/TSan 한 번도 안 돔.
6. **LOB/off-page/virtual-column/>512B payload 행 캐싱 제외 — LOB/text-heavy HTAP(실 타깃)서 커버리지 붕괴, 미측정** —
   `accel_ring.h ACCEL_IMG_MAX=512`. coverage ~100%는 sbtest(INT/CHAR)에서만.
7. **Stage-C 헤드라인(~5500×)은 프로토타입 내 self-modeled tail-only 모드, 실 InnoDB purge 아님** — 실 InnoDB 메모리/체인
   비교는 ⑤(GC-off). → 통합은 read-latency(⑥)만 증명, 메모리/체인 우위는 실 InnoDB서 미증명.
8. **[memory 무한성장] overflow reservation floor가 monotone-down·never reset → >256 reader가 reclaim 영구 pin** —
   `active_view_registry.h:133-148`, `epoch_reclaimer.h`. fix(count 0이면 reset / MAX>max_connections) 미적용.
9. **[memory 무한성장] cold-key header + Kuku slot 영구 미회수 → O(distinct keys) 성장** — `design-D5-gc §6`.
   "memory ∝ live-txn window, not dataset"(One-shot-GC 대비 차별점)와 직접 모순. Kuku erase + head-skip 완화 필요.
10. **EPOCH_SIZE=100 등 blind 상수 — sparse 실 DB_TRX_ID에선 head-prepend가 per-version 발화, epoch batching 무력화** —
    `common.h:9-10`. rank-map 재척도(5-1로 이연, 5-2 미착수라 사실상 미적용).
11. **signal B publish 비용(B-vs-D 결정) 1개 thread count에서만 측정** — 32/64/128 sweep + view_open 발화율 미측정(§8 open Q).
12. **floor-vs-mirror reconciliation(live view가 floor 아래로 떨어져 retire되는 window 없음) 구성상 주장만, ASan/TSan
    동시-purge stress 미실행.** push-buffer seqlock·generate_dead_zone sort/assert도 must-fix 미적용.
13. **view-reuse ADD-on-open 완결성(superset 정리의 경험적 다리, hit_MISMATCH=0 under GC) 미입증** — GC-on(5-2) 필요.
14. **REPORT.md가 Stage C에 frozen, Stage-D Limitations/Threats 섹션 없음** — 보고서만 읽으면 위 리스크를 전혀 모름.
15. **savepoint-rollback false-HIT가 serve서 미봉합** — contiguity가 MISS 못 시킴; pre-4d committed-only/re-anchor 게이트
    미확정. shadow byte-compare가 잡지만 serve는 net 없음.

---

## ⓣ 명시 추적 (실재하나 추적하면 future work 가능)

1. NUM_DEADZONE=50 clamp → >50 동시 view면 highest-id 중간 holes silent drop(under-reclaim, 실 HTAP 부하서). M1(힙오버플로)은 DONE.
2. head-prune 영구 비활성 + 1c-5 head-prepend CAS 미구현(plain store) → 모든 키의 최신 버전 비-회수; release서 안전은 "head-prune 비활성" 관례뿐(assert는 NDEBUG서 컴파일아웃).
3. serve mode-1 자가검증 불가 — correctness가 SUM 일치 + 별도 mode-2로 transitive(같은 run per-row 증명 아님).
4. session-7 잔여 ~0.26% "newer" construct_BAD은 serve OFF로만 닫힘; O(C) chase GC-off서 0 확인했으나 GC-on 재확인 필요.
5. reinsert false-link(리뷰 A7)·same-trx tie-break는 **경험적(construct_BAD=0)으로만** 닫힘, 구조적 증명 아님.
6. oltp_read_write delete+reinsert full-PK FNV byte-identity(populate↔consult) — cross-gen 오염의 근원, 78% HIT의 이유.
7. instant-DDL: 거친 whole-table 게이트; cross-era byte-risk negative control은 "best-effort"(결정적 아님).
8. FG cooperative 토글 기본 ON이나 "Stage C-2 ablation isolator"로 기술 — 출하 컴포넌트인지 ablation knob인지 모호.
9. Stage-C 헤드라인은 controlled threading(스레드≤코어) 필요 — oversubscribe(실서버 상시)서 약함, 벤치 제약으로 우회.
10. InnoDB 소스 패치(row0vers/read0types/trx0rec)가 레포 밖 빌드스크립트로만 적용, vendor 안 됨 → 레포만으로 재현/감사 불가. 적대적-리뷰 종합본도 레포 밖.
11. changes_visible 미러가 check_trx_id_sanity 생략 — release 동치 "주장"만, vanilla와 differential 테스트 없음.
12. deadzone GC clock·superset 미러는 wired+shadow-verified이나 **미소비**(5-2가 연결해야 함).
13. ring drop-on-full = silent populate 손실 → 그 키 MISS. 모든 run dropped=0이나 **ring overflow가 한 번도 안 터진** 부하에서만.
14. coverage "BP-무관/작은 BP 견고(dropped=0)"가 stressor(ring overflow) 미발화 3점에서만.
15. ACCEL_PK_MAX cap 초과 PK는 silent MISS — INT PK에서만 검증(wide/composite/string PK 미검증).
16. trx_sys mutex hold-time / begin-commit p99(signal B의 "near-zero hot cost" 입증 지표) 5-3 약속·미측정.
17. crash-recovery / ephemeral-cache 재구축(ACID 안전의 전제) 한 번도 미실행.
18. garbage_collect cadence TODO + dummy-list 의도적 누수(ASan detect_leaks=0이라 **누수 전수 미검증**) + cold-record head wrapper bucket 유지.

---

## ⓞ 진짜 optional (claim 무관, 올바르게 scoped)
- signal D(거친 epoch-bucket flags, B 회귀 시만) · DIVA interval tree(체인 log bound) · tagged-pointer reclamation ·
  version sifting/multi-granularity(tight-bound은 1c-4서 이미 landed) · epoch-count knob/compaction trigger ·
  instant-DDL 게이트 거칢(의도) · virtual-column 제외(의도) · mysqld 강제충돌 음성대조 vacuous(오프라인 대체됨) ·
  consult 시그니처의 test-only 파라미터(default-safe) · read0types accessor "PoC patch" · Kuku LocFuncTests.Randomness
  self-test 실패(기능 무해) · stale findings #7/#10 · stale d1b1_patch.pl.

---

## ⚠️ sweeper가 놓쳤을 수 있는 곳 (추가 점검 대상)
- progress-log.md 301줄 line-by-line(초기 증분 deferral이 design 문서에 미전파).
- design-D §0/§4 Stage-D DoD vs ⑥ 실측(⑥-latency 외에 silent rescope된 DoD 항목 가능 — 동시 HTAP, 60s LLT).
- accel_hook 종료 순서 vs in-flight consult(teardown-vs-consult window, 통합 ASan/TSan 미실행).
- epoch_reclaimer retire/Guard 전문을 roll_pred multi-hop chase에 직접 대조(0.16s-under-GC가 이 메커니즘에 의존).
- 빌드 플래그: 우리 소스 `-w`로 **모든 경고 억제**(통합), standalone detect_leaks=0.
- trxManager가 통합서 GC 입력에 vacuously-passing assertion 만드는지 end-to-end.
- **논문(한글+영문) draft 부재 + 분산/multi-run/error-bar 데이터 전무**(모든 수치 단일값) — Evaluation 섹션의 baseline·ablation·error bar 요구와의 격차.
