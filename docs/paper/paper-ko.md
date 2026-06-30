# AccelerateMVCC: 디스크 기반 DBMS의 MVCC 버전 읽기를 가속하는 superset-안전 derived-served 인메모리 인덱스

**하태성 (Taeseong Ha)**

> 상태: **draft (Phase 3, 2026-06-30)**. 한글본. 영문본은 본 초안 확정 후 번역. 심사 제출본은 아니나
> review-quality를 기준으로 한다. 근거 데이터·재현 스크립트는 레포 `integration/results/`·`integration/scripts/`,
> 설계 근거는 `docs/design-*.md`, 측정 상세는 `docs/phase2-q3-llt.md`·`docs/phase3-tpcc.md`에 있다.

---

## Abstract

HTAP(Hybrid Transactional/Analytical Processing) 워크로드에서 long-lived transaction(LLT)은 오래된 read view를
쥔 채 InnoDB의 purge를 막아 MVCC version chain(undo-log chain)을 점점 길게 만든다. 그 스냅샷 아래의 분석 읽기는
긴 undo chain을 거꾸로 되짚으며 다수의 undo page를 buffer pool로 끌어오고, buffer pool이 작을수록 **undo I/O
절벽**을 맞는다(held deep read 0.8 s @4 GB → 123 s @64 MB). 프로파일링상 `row_search_mvcc` 계열이 이 조건에서
약 45 %의 CPU를 차지한다.

본 논문은 각 버전의 메타데이터와 소형 in-page 행 image를 compact한 인메모리 구조에 보관해, 긴 on-disk undo
walk 대신 스냅샷에 가시적인 버전을 곧바로 찾아 **서빙(serve)** 하는 derived·ephemeral·비권위(non-authoritative)
캐시 **AccelerateMVCC**를 제시한다. 캐시가 위치만 알려주는 것이 아니라 결과 레코드를 직접 서빙하므로,
version 회수(reclaim)가 과하면 곧 틀린 버전을 서빙하는 문제가 된다. 이를 구조적으로 배제하기 위해 회수 경계인
deadzone을 활성 read-view들의 **conservative superset**으로 유지하여, 과회수를 "틀린 서빙"이 아니라 "캐시 MISS →
정확한 vanilla walk"라는 성능-only 사건으로 환원한다. 이 **no-wrong-serve 불변식**을 네 겹의 firewall로 semi-formal
하게 논증한다.

InnoDB 8.4.10에 정적 통합하여 평가한 결과, (1) held 분석 read의 latency가 buffer pool 크기와 무관하게 평탄해지고
(64 MB에서 vanilla 대비 ~290× 중앙값, 단 일부 run은 GC chain-sever로 정확한 walk에 degrade), (2) 캐시 메모리는
live-transaction window에 비례해 유계이며 데이터셋 크기와 무관하고(InnoDB History List Length 대비 LLT 나이에
선형으로 19.5×/40.5×/81.9× @15/30/60 s), (3) 서빙된 모든 답이 vanilla undo walk와 byte 동일하다(전 측정
construct_BAD=0). 표준 TPC-C 벤치마크에서도 서빙 정확성, 용량 기반 sizing 법칙, 그리고 캐시가 효과를 내는 regime
경계(undo-I/O-bound vs base-I/O-bound)를 정직하게 실증한다.

---

## 목차 (작성 골격)

1. **Introduction** — 문제(HTAP LLT undo 절벽), 기존 접근의 공백(버전저장소 소유 vs 비권위 서빙), 본 접근과 기여.
2. **Background & Motivation** — InnoDB MVCC·undo chain·read view·purge, undo I/O 절벽의 정량화, vDriver/DIVA 계보.
3. **Design** — Kuku cuckoo hash → epoch interval-list version chain → lineage walk(roll_ptr/changes_visible 미러)
   → deadzone GC(read-view cuts), 그리고 **superset-안전 정리**와 no-wrong-serve 불변식(F1–F4).
4. **Implementation** — InnoDB 8.4.10 통합: populate(latch 하 lock-free ring)→off-latch single-consumer drainer→
   consult→authoritative serve(mode-2 verify / mode-1 serve-only + 4-layer firewall), lock-free·EBR.
5. **Evaluation** — ⑥ read-latency payoff, ⑤ memory bound, effective speedup, 동시-HTAP, 표준 TPC-C, 워크로드 폭·
   correctness·sanitizer. 전부 multi-run error-bar, construct_BAD=0.
6. **Related Work** — vWeaver·vDriver·DIVA, buffer pool, 인메모리 DB와의 위상 차이.
7. **Limitations & Discussion** — in-page row scope(off-page LOB 제외), 용량 bound(eviction 미구현), 효과 regime,
   TSan residual, semi-formal(미-기계검증).
8. **Conclusion** — 기여 요약과 향후 방향(다른 엔진/isolation·분산 MVCC·persistent memory·형식검증).

---

## 1. Introduction

### 1.1 문제: HTAP에서 long-lived transaction이 만드는 undo 읽기 비용

디스크 기반 DBMS의 MVCC(Multi-Version Concurrency Control)는 갱신 시 이전 버전을 undo log에 남기고, 읽기
트랜잭션은 자신의 read view에 맞는 버전을 undo chain을 거슬러 재구성한다. 정상적인 OLTP에서는 commit된 과거 버전을
purge가 주기적으로 회수하므로 chain이 짧게 유지된다. 그러나 HTAP 워크로드에서 분석 질의처럼 **오래 사는 읽기
트랜잭션(LLT)** 이 하나라도 존재하면, 그 트랜잭션이 쥔 오래된 read view가 purge의 진행을 막는다(purge는 가장
오래된 활성 view보다 과거만 회수할 수 있다). 그 결과 version chain은 LLT가 사는 동안 계속 길어진다.

이때 같은 LLT 스냅샷 아래에서 깊은 분석 read를 수행하면, InnoDB는 각 행마다 길어진 undo chain을 top에서부터
순차적으로 되짚어 스냅샷에 가시적인 버전을 재구성해야 한다. 이 과정은 두 가지 비용을 낳는다. 첫째, 재구성을 위해
다수의 undo page를 읽어야 하는데, buffer pool이 작으면 이들이 디스크에서 반복적으로 적재되어 **undo I/O 절벽**이
발생한다. 둘째, 끌려온 undo page가 buffer pool을 오염시켜 동시 OLTP의 hit rate를 떨어뜨린다. 본 연구의 통합
환경에서 측정한 바로는, held 분석 read의 latency가 buffer pool 4 GB에서 약 0.8 s이던 것이 64 MB에서 약 123 s로
치솟으며(절벽), 이 조건에서 `row_search_mvcc` 및 관련 버전 재구성 경로가 CPU의 약 45 %를 차지한다.

이 비용은 알고리즘적으로 본질적인 것이 아니라 **저장 형태**에서 온다. 가시 버전을 찾는 데 필요한 정보(어느 버전이
스냅샷에 보이는가, 그 버전의 내용은 무엇인가)는 작지만, 그 정보가 디스크 undo log에 delta 형태로 흩어져 있어 매번
순차 재구성과 page I/O를 요구한다.

### 1.2 본 연구의 위치와 관련 연구

본 연구는 LLT 하 version chain 비용이라는 문제의식을 공유하는 연구 흐름과 같은 맥락에 있으나, 그 연구들을
확장하거나 개선하려는 것이 아니라 **독립적으로 진행된 프로젝트**다. 관련 연구로 vDriver(SIGMOD '20)는 활성
read-view들 사이의 "dead zone"—어떤 활성 view에도 필요 없는 버전 구간—을 검출해 chain 중간(in-middle)에서
회수함으로써 purge가 LLT에 막혀 못 건드리는 구간까지 정리하고, DIVA(VLDB '22)는 interval-tree로 chain 길이를
로그로 bound한다. 본 연구의 **dead zone 검출은 vDriver의 것을 차용·적응**한 것이며(같은 연구실 지도 하에 도입),
이를 명시적으로 출처로 밝힌다. 그러나 그 외의 설계—lock-free 인메모리 version-chain 캐싱, InnoDB를 권위로 둔
derived-served 모델, 그리고 아래의 superset-안전 정리—는 **독립적으로 설계·구현**한 본 연구의 기여다.

관련 연구와의 본질적 차이는 *개선*이 아니라 **아키텍처 선택**에 있다. vDriver·DIVA를 비롯한 위 접근들은 버전
저장소 자체를 소유한다. 자신이 버전을 보관·제공하는 권위(authority)를 가지므로, dead zone을 다소 보수적으로/
공격적으로 잡더라도 그것은 회수 정책의 문제일 뿐 정확성을 깨지 않는다—저장소가 곧 진실이므로 "없으면 없는
것"이다.

본 연구는 InnoDB의 undo log를 **건드리지 않고**, 그로부터 derived된 보조 인덱스만 인메모리에 둔다. InnoDB가
여전히 권위이고 캐시는 비권위 사본이다. 이 구도에서 캐시가 단순히 "어느 버전을 보라"고 위치만 알려준다면
안전하지만(틀리면 InnoDB가 정답을 walk), 본 연구는 한 걸음 더 나아가 **재구성된 버전 레코드를 직접 서빙하여
undo walk 자체를 건너뛴다**(이것이 성능 이득의 원천이다). 이 순간 새로운 정확성 긴장이 생긴다: 캐시가 회수를
과하게 하면, InnoDB에는 멀쩡히 존재하는 가시 버전을 캐시는 더 오래된(틀린) 버전으로 서빙할 수 있다. 즉
**derived된 캐시가 결과를 서빙하는 순간, over-reclaim은 회수 정책의 문제가 아니라 틀린 답의 문제가 된다.**
저장소를 소유하는 설계에서 무해하던 "stale dead zone"이 여기서는 무해하지 않으며, 이 긴장의 해소가 §1.3의
핵심이다.

### 1.3 본 접근: superset-안전 derived-served 캐시

AccelerateMVCC는 각 행(clustered PK)에 대해 버전들의 메타데이터(undo 위치, writer trx-id)와 in-page 행 image를
compact한 lock-free 인메모리 version chain에 보관한다. 읽기 트랜잭션의 version-build 지점에서 캐시는 그 행의
lineage를 따라 스냅샷에 가시적인 첫 버전을 찾고, eligible하면 그 byte image를 **서빙하여 undo walk를 생략**한다.
메모리를 compact하게 유지하기 위해, 활성 read-view들로부터 dead zone을 만들어 in-middle 회수를 수행한다(vDriver의
패턴을 인메모리·서빙 설정에 맞게 적응).

핵심 통찰은 위 1.2의 긴장을 **구조적으로** 해소하는 데 있다. dead zone을 활성 read-view들의 **conservative
superset**으로 유지하면—즉 어떤 활성 view에 필요할 "수도" 있는 버전은 절대 회수 대상에 넣지 않으면—과회수로
인한 틀린 서빙이 원천 배제된다. 회수가 과하게 일어나도 그것은 캐시에서 해당 lineage 링크가 끊겨 consult가
MISS를 내고, 호출부가 InnoDB의 정확한 vanilla walk로 fallback하는 **성능-only 사건**으로 환원된다. 즉 캐시의
모든 실패(회수·drop·용량 초과·충돌)는 "느린 정답(vanilla walk)"으로 수렴하며, 틀린 답은 결과 공간에 존재하지
않는다. 우리는 이 **no-wrong-serve 불변식**을, HIT의 필요조건을 이루는 네 겹의 firewall(full-PK 동일성,
가시성 미러, lineage 연속성, image 충실도)로 분해하여 semi-formal하게 논증한다(§3).

이것이 본 연구의 고유한 기여다. **버전 저장소를 소유하지 않고 비권위로 서빙하는 derived 캐시에 특화된
superset-안전 정리**가, hot-mutex 없이도 안전한 in-middle 회수를 정당화한다.

### 1.4 기여

- **derived-served MVCC 캐시 모델과 no-wrong-serve 불변식.** InnoDB를 권위로 두고 그로부터 derived된 인메모리
  캐시가 재구성 결과를 직접 서빙하면서도 틀린 버전을 절대 서빙하지 않음을, 활성 view의 conservative superset이라는
  설계 불변식과 네 겹 firewall로 구조적으로 보장한다(§3, design-D7).
- **InnoDB 8.4.10으로의 실 통합.** page latch 하의 noexcept lock-free ring enqueue → off-latch 단일 consumer
  drainer(유일 mutator) → consistent-read 지점의 consult → authoritative serve(walk-skip)라는 leaf-domain
  단방향 통합으로, 트랜잭션 핫패스에 무시할 만한 비용만 더한다(§4).
- **multi-run error-bar 평가.** held 분석 read latency가 buffer pool 무관 평탄(64 MB ~290× 중앙값), 캐시 메모리가
  live-transaction window에 유계(LLT 나이에 선형 비율), effective speedup, 동시-HTAP까지 실 mysqld에서 측정하고,
  서빙된 모든 답이 byte 동일함을 전 측정에서 확인한다(construct_BAD=0)(§5).
- **표준 TPC-C에서의 정직한 scope·regime 실증.** 표준 HTAP 벤치마크에서 서빙 정확성, 용량 기반 coverage sizing
  법칙(HIT 16 %→64 %), 그리고 캐시가 효과를 내는 regime 경계(undo-I/O-bound에서 큰 이득, base-I/O-bound large-table
  스캔에서는 modest)를 명시한다(§5.5).

### 1.5 결과 요약

InnoDB 8.4.10 통합 평가에서 AccelerateMVCC는 held 분석 read의 undo I/O 절벽을 제거하여 64 MB buffer pool에서
vanilla 대비 약 290×(중앙값)의 latency 개선을 보인다. 단, 작은 buffer pool에서 GC가 navigation 버전을 실시간
회수할 때 약 1/4의 run은 정확한 vanilla walk로 degrade한다(여전히 정답, 성능-only). 캐시 메모리는 LLT 시간에
유계로 유지되어 InnoDB History List Length 대비 LLT 나이에 선형으로 우위가 커진다(19.5×/40.5×/81.9× @15/30/60 s).
전 측정에서 서빙된 답이 vanilla walk와 byte 동일하며(construct_BAD=0), 이는 composite/string PK·secondary index·
savepoint·crash recovery·표준 TPC-C까지 일반화된다. 본 논문은 캐시가 효과를 내는 정확한 조건—undo 재구성이
병목인 regime—까지 정직하게 경계 짓는다.

---

## 2. Background & Motivation

### 2.1 InnoDB의 MVCC와 버전 재구성

InnoDB는 행을 갱신할 때 clustered index 레코드를 제자리에서 덮어쓰되, 갱신 직전 이미지를 undo log에 기록하고
레코드 헤더의 roll_ptr이 그 undo 레코드를 가리키게 한다. 같은 행을 여러 번 갱신하면 undo 레코드들이 roll_ptr로
연결된 chain을 이루며, 가장 최근 갱신이 chain의 head(현재 레코드)이고 과거 버전들이 그 아래로 이어진다.

읽기 트랜잭션은 시작 시 read view를 한 번 확정한다. read view는 네 값으로 요약된다: `up_limit_id`(이 미만의
trx-id는 모두 보임), `low_limit_id`(이 이상은 모두 안 보임), `creator_trx_id`(자기 자신), 그리고 그 사이에서
아직 활성이던 트랜잭션 id들의 정렬된 집합 `m_ids`. 어떤 버전이 이 view에 가시적인지는 그 버전을 만든 trx-id를
`changes_visible` 술어로 판정한다: (①) id가 up_limit 미만이거나 creator면 가시, (②) id가 low_limit 이상이면
불가시, (③) m_ids가 비어 있고 사이값이면 가시, (④) 아니면 m_ids 이진 탐색으로 판정. 한 행에 대해 read view에
가시적인 버전은 head에서 내려가며 changes_visible이 처음 참이 되는 버전이고, 이는 유일하다.

문제는 그 버전을 **재구성**하는 비용이다. undo 레코드는 전체 이미지가 아니라 delta(바뀐 컬럼만)이므로, InnoDB는
head부터 roll_ptr을 따라 내려가며 각 undo delta를 순차 적용해 과거 이미지를 복원한다(`trx_undo_prev_version_build`).
즉 깊이 d의 가시 버전을 얻으려면 d개의 undo 레코드를 읽고 적용해야 한다.

### 2.2 Purge와 long-lived transaction

commit된 과거 버전은 어떤 활성 read view도 더는 볼 수 없게 되면 purge가 회수한다. 그러나 purge는 **가장 오래된
활성 view보다 과거**만 회수할 수 있다. HTAP에서 분석 질의 같은 long-lived transaction(LLT)이 오래된 view를 쥐고
있으면, purge의 회수 경계(floor)가 그 LLT에 고정되어 그 이후 commit된 버전들이 회수되지 못하고 쌓인다. version
chain은 LLT가 사는 동안 단조 증가하며, 이는 InnoDB의 History List Length(미회수 버전 수)로 관측된다.

### 2.3 undo I/O 절벽 (동기)

chain이 길어진 상태에서 LLT 스냅샷으로 깊은 분석 read를 수행하면, 각 행마다 §2.1의 순차 재구성이 길어진 chain
전체에 대해 일어난다. 이 비용은 buffer pool 크기에 민감하다. 본 연구의 통합 환경에서, 1000행 테이블에 write-heavy
churn을 가한 뒤 held 스냅샷으로 전체를 깊게 읽는 latency는 buffer pool 4 GB(테이블·undo resident)에서 약 0.8 s
였으나 64 MB(undo page를 디스크에서 반복 적재)에서 약 123 s로 치솟았다(약 150× 이상의 절벽). 이 조건에서
`row_search_mvcc` 및 버전 재구성 경로가 CPU의 약 45 %를 차지하고, 끌려온 undo page가 buffer pool을 오염시켜
동시 OLTP의 throughput까지 떨어뜨린다.

핵심 관찰은 이 비용이 **알고리즘이 아니라 저장 형태**에서 온다는 것이다. 가시 버전을 찾는 데 필요한 정보는 작지만
(어느 버전이 보이는가 + 그 내용), 그것이 디스크 undo에 delta로 흩어져 매번 순차 재구성과 page I/O를 강제한다.
재구성 결과를 한 번 만들어 compact하게 들고 있을 수 있다면, 큰 buffer pool에서는 재구성 CPU를, 작은 buffer
pool에서는 undo page I/O와 오염을 함께 없앨 수 있다. 이것이 본 연구의 출발점이다.

### 2.4 차용한 빌딩블록: vDriver의 deadzone (출처 명시)

위 인메모리 캐시를 compact하게 유지하려면 더는 필요 없는 버전을 회수해야 하는데, LLT가 purge를 막는 바로 그
상황에서는 tail-only 회수(가장 오래된 것부터)가 무력하다. vDriver(SIGMOD '20)는 활성 read-view들 사이의 **dead
zone**—연속한 두 활성 view 사이에 놓여 어떤 활성 view에도 필요 없는 버전 구간—을 검출해 chain **중간**에서
회수한다. 본 연구는 이 dead zone 검출을 인메모리 캐시의 회수에 **차용·적응**한다(같은 연구실 지도 하에 도입한
부분으로, 출처를 명시한다). 단 §1.2에서 짚었듯 vDriver는 버전 저장소를 소유하므로 dead zone이 다소 stale해도
무해하지만, 본 연구는 비권위로 **서빙**하므로 같은 회수를 그대로 쓰면 틀린 서빙을 낼 수 있다. 이 차이를 메우는
것이 §3.4의 superset-안전 정리다.

---

## 3. Design

### 3.1 개요: 자료구조와 흐름

AccelerateMVCC는 (table_id, clustered PK)를 키로 하는 인메모리 보조 인덱스다. 키 → 버전 chain header의 매핑은
Microsoft Kuku의 cuckoo hash로 O(1)에 둔다. 각 header는 그 행의 버전들을 담는 **epoch 단위 interval list**를
가리킨다. 각 버전 노드는 그 버전을 만든 writer trx-id, 직전 버전을 만든 trx-id(version_trx-id), undo 위치
메타데이터, 그리고 **소형 in-page 행 image**(전체 물리 레코드의 verbatim 복사, in-page·상한 이하)를 담는다.

런타임 흐름은 네 단계다. **populate**: InnoDB가 갱신 시 만든 undo 레코드를 캐시에 적재한다. **consult**: 읽기
트랜잭션의 버전 재구성 지점에서 캐시에 가시 버전을 질의한다. **serve**: HIT면 캐시의 image로 InnoDB의 walk를
대체한다. **GC**: deadzone 회수로 캐시를 compact하게 유지한다(InnoDB 통합 지점은 §4).

### 3.2 lineage 워크: 가시 버전 선택

consult는 InnoDB의 roll_ptr 워크를 **인메모리에서 미러**한다. reader가 찾는 행의 full-PK로 header를 찾고,
live-top writer(이미 latch된 현재 레코드의 trx-id)에서 시작해 버전 노드들의 writer→predecessor 링크를 따라
내려간다. 이 링크는 "한 버전의 version_trx-id가 그 직전 버전의 writer trx-id와 같다"는 id-동일성으로 잇는다
(vanilla의 roll_ptr 인접성과 동형). 각 노드에서 changes_visible 술어(§2.1의 4분기를 byte-exact 복제)로 가시성을
판정해, head에서 내려가 **처음 가시적인 버전**을 고른다. 가시성 판정에 쓰는 read view 입력(up/low/creator/m_ids)은
InnoDB가 그 reader를 위해 쥔 값을 그대로 미러한다.

이 워크가 끊기거나(중간 링크 부재) 모호하면(한 writer에 서로 다른 두 predecessor = delete+reinsert 등 다른 세대
충돌) consult는 그 자리에서 멈추고 MISS를 반환한다. 따라서 consult가 고르는 버전은 항상 vanilla가 걷는 바로 그
lineage 위에 있으며, 다른 세대나 끊긴 chain의 버전이 아니다.

### 3.3 deadzone GC: 메모리를 live-transaction window에 유계로

캐시를 compact하게 유지하기 위해 활성 read-view들의 경계(cut)로부터 dead zone을 만들어 그 구간의 버전 노드를
회수한다. dead zone 구성은 두 소스를 합친다. (A) InnoDB purge_sys의 view를 공짜로 읽어 안전한 바닥을 얻고, (B)
InnoDB가 read view를 열 때 이미 쥔 trx_sys mutex에 편승해 그 view의 경계를 우리 leaf-domain lock-free registry에
미러한다(새 자물쇠 0). 이 cut들로부터 dead zone을 만들어 amortized windowed sweep으로 회수한다.

이 회수는 LLT와 최근 reader 사이의 **in-middle gap**—LLT가 purge floor를 고정한 그 위의, 어떤 활성 view에도
필요 없는 구간—을 정리한다. 이는 purge가 LLT에 막혀 못 건드리는 바로 그 구간이다. 그 결과 캐시가 보존하는 버전
수는 **활성 트랜잭션 window**에 비례하고 데이터셋 크기와 무관하다(§5.2 실측).

### 3.4 superset-안전 정리 (핵심 novelty)

§1.2·§2.4의 긴장—derived 캐시가 서빙하므로 over-reclaim이 틀린 서빙이 된다—을 본 연구는 **구조적으로** 배제한다.
핵심은 dead zone을 활성 read-view들의 **conservative superset**으로 유지하는 것이다. 즉 어떤 활성 view에 필요할
*수도* 있는 버전은 절대 회수 대상에 넣지 않는다(경계를 항상 안전한 쪽으로만 over-approximate).

이 불변식 하에서 한 버전 V와 한 read view 관점에서 회수가 일으킬 수 있는 결과는 둘뿐이다. (i) V가 어떤 활성
view에도 불필요하면 회수해도 무해하다. (ii) V가 어떤 활성 view에 필요하면, superset 정의상 V는 회수 대상에 결코
들어가지 않는다. 위험한 세 번째 경우—"필요한 V를 회수"—는 under-approximation에서만 생기는데 superset 유지가
그것을 원천 배제한다. 따라서 회수가 캐시 상에서 어떤 lineage 링크를 끊더라도, 그것은 그 reader에게 *불필요한*
버전을 지운 것이거나, 끊긴 자리에서 consult가 MISS를 내고 호출부가 vanilla walk로 가는 것이다. 어느 쪽도 틀린
서빙이 아니다. 즉 **superset 유지 하에서 모든 over-reclaim은 perf-only(MISS→walk)이며, 회수가 정확성을 깨는
경로는 존재하지 않는다.**

이 정리가 본 연구의 핵심 기여다. 버전 저장소를 소유하는 vDriver/DIVA류에서는 dead zone이 stale해도 무해하므로
이런 정리가 필요 없지만, 비권위로 서빙하는 derived 캐시에서는 over-prune이 곧 틀린 서빙이므로 정확성을 위해
superset이 필수다. 그리고 superset은 새 자물쇠 없이(§3.3의 A+B로) 유지되므로 hot-mutex 없는 안전한 in-middle
회수를 정당화한다.

### 3.5 no-wrong-serve 불변식: 네 겹 firewall

§3.4가 회수의 안전을 보장한다면, 서빙 경로 전체의 안전은 HIT의 필요조건을 이루는 네 겹 firewall로 보장된다.
consult가 HIT를 내려면 다음이 모두 성립해야 하며, 하나라도 깨지면 MISS를 반환해 vanilla walk로 보낸다.

- **F1 (full-PK 동일성).** Kuku 해시는 버킷 hint일 뿐 권위가 아니다. 후보 노드는 reader의 full-PK 바이트와
  memcmp로 일치해야 후보가 된다(production에서 강제). → cuckoo 충돌로 다른 행이 섞일 수 없다.
- **F2 (가시성 미러).** 후보의 가시성은 InnoDB changes_visible의 4분기를 byte-exact 복제한 미러로 판정한다. ④의
  전제인 m_ids 오름차순 정렬은 consult 진입부에서 검사해 미정렬이면 MISS(fail-closed). → 캐시가 가시로 고르는
  버전 = InnoDB 규칙이 가시로 고르는 버전.
- **F3 (lineage 연속성).** HIT는 캐시의 gap-free run이 live-top까지 닿음(contiguity)과 §3.2의 끊김 없는 lineage
  워크를 요구한다. ring drop이나 다른 세대 충돌로 링크가 끊기거나 모호하면 MISS. → 고른 버전은 vanilla가 걷는
  그 lineage 위에 있고 끊긴/다른 세대 버전이 아니다.
- **F4 (image 충실도).** 서빙 바이트는 write 시점에 leaf X-latch 하에서 캡처한 전체 물리 레코드의 verbatim
  복사다. 캐시의 full-rec를 InnoDB 파서로 파싱한 결과가 vanilla 재구성본과 data·delete flag·offsets 동일함을
  사전 검증했다. off-page LOB·virtual column·상한 초과 행은 img_len=0으로 MISS_INELIGIBLE. → 서빙 record는
  vanilla 재구성본의 byte-동일 대체물이며 부분/truncated image는 서빙되지 않는다.

이 넷이 모두 성립하는 HIT는 §3.2의 lineage 유일성과 결합하여 "서빙한 byte = vanilla가 walk했을 byte"를 함의하고,
넷 중 하나라도 깨진 비-HIT은 전부 vanilla walk(정답)로 간다. 따라서 serve 결과는 (HIT=증명상 정답) 또는
(MISS=vanilla 정답) 둘 중 하나이며, **틀린 행은 결과 공간에 도달 불가능하다.** 이 논증은 semi-formal hand
argument이며(기계검증은 향후 과제, §7), 통합 평가에서 mode-2 verify-serve가 매 서빙마다 vanilla walk와 byte를
대조함으로써 경험적으로도 뒷받침된다(전 측정 construct_BAD=0).

### 3.6 동시성 모델

핫패스(읽기·삽입)는 lock-free다. 노드 unlink의 일관성은 marked pointer(Harris)로, 안전한 메모리 회수는
per-traversal EBR(Epoch-Based Reclamation)로 보장한다. 적재는 단일 off-latch drainer가 인덱스의 유일한 mutator
이므로(single producer) 같은 행의 버전은 commit 순서대로 head에 append-only로 쌓이고, GC는 별도 leaf-domain
스레드로 head epoch을 건드리지 않아 drainer의 append와 disjoint하다.

서빙의 메모리 안전은 EBR Guard가 consult의 첫 deref 이전에 취해져 image를 caller 버퍼로 복사하는 시점까지
span하여 보장된다—회수는 unlink 후 더 높은 epoch을 stamp하므로 Guard-보호 traversal은 freed 노드에 도달하지
않는다. 서빙 record는 caller 버퍼로 복사되어 facade 밖으로 raw 포인터가 나가지 않는다. walk-skip으로 자가검증이
없는 mode-1(serve-only) 출하 경로에는 회수와 probe의 race를 잡는 gc_generation 2차 방화벽과 1-in-N walk-audit를
추가하여 §3.5의 구조적 firewall을 보강한다.

---

## 4. Implementation

### 4.1 InnoDB 통합 지점

AccelerateMVCC를 InnoDB 8.4.10에 정적 링크하고 세 지점에 hook을 둔다. **populate**는 갱신이 undo 레코드를 남기는
지점(`trx0rec.cc`의 undo report)에서 그 레코드의 메타데이터와 행 image를 캐시로 보낸다. **consult**는 consistent
read가 가시 버전을 재구성하는 지점(`row0vers.cc`의 `row_vers_build_for_consistent_read`)에서 캐시에 질의한다.
**GC**는 trx_sys의 read-view 정보를 읽어 deadzone을 구동한다. 통합은 InnoDB→accel 한 방향 edge만 가지며(accel은
InnoDB 상태를 변경하지 않는다) accel은 leaf domain에 머문다.

### 4.2 latch 하 enqueue + off-latch single-consumer drainer

populate hook은 page X-latch 아래에서 호출되므로, 그 자리에서 캐시 자료구조를 직접 건드리면 latch 하 malloc·
blocking·thread-unsafe 문제가 생긴다. 이를 피해 hook은 레코드(스칼라 메타데이터 + 상한 이하 image)를 lock-free
MPMC ring에 **enqueue만** 한다—noexcept·무할당·무블로킹이며 ring이 차면 그 항목을 drop한다(해당 키는 이후 consult
MISS → vanilla). ring에서 꺼내 실제 인덱스에 적재하는 것은 단일 off-latch **drainer** 스레드로, 이것이 인덱스의
유일한 mutator다(single producer 불변식). 따라서 같은 행의 버전은 latch가 직렬화한 commit 순서대로 head에
append-only로 쌓인다.

### 4.3 서빙 모드와 토글

serve는 세 모드를 환경 변수로 선택한다. **mode-0(shadow, 기본)**: consult는 돌지만 서빙하지 않는다(평상 동작
불변). **mode-2(verify-serve)**: HIT마다 vanilla walk를 수행해 byte 대조 후 일치할 때만 캐시 record로 교체한다—
매 서빙을 런타임에 재검증하므로 correctness gate로 쓴다. **mode-1(serve-only, 출하 perf 경로)**: walk를 건너뛰고
캐시 record를 반환한다. mode-1은 자가검증이 없으므로 §3.5의 구조적 firewall에 더해 gc_generation 2차 방화벽과
1-in-N walk-audit(표본적으로 vanilla와 대조, 불일치 시 trip)로 보강한다. deadzone GC, drain-cap(⑥ 안정화), 이미지
cap, cuckoo 용량(`kuku_log2`)도 환경 변수로 조절한다.

### 4.4 vendoring

레포 단독 재현을 위해 수정한 upstream InnoDB 5개 파일(consistent-read 지점·undo report·view open·생명주기 등)을
`integration/innodb/innodb-8.4.10-accel.diff`로, accel 소스 일체를 `integration/innodb/`·`include/`로 vendor한다.
빌드는 accel 소스를 innobase에 컴파일·링크하고 측정 스크립트는 `integration/scripts/`에 둔다.

---

## 5. Evaluation

### 5.1 측정 설정과 방법론

평가는 MySQL 8.4.10(gcc-13)에 AccelerateMVCC를 통합한 mysqld에서 수행한다. 중심 지표는 **held-snapshot 분석 read
latency**다—write-heavy OLTP churn 위에서 read view를 쥔 분석 read가 깊어진 chain을 되짚는 비용으로, throughput-only
지표는 단시간·in-memory에서 신호가 약하기 때문이다. 모든 측정의 보편 정확성 gate는 **construct_BAD=0**(mode-2
verify-serve가 서빙한 답이 vanilla walk와 byte 동일)이다. 헤드라인 config는 단일 run이 아니라 N회 재측해 중앙값과
min/max, degrade율을 보고한다(raw 로그·CSV는 `integration/results/`에 아카이브).

### 5.2 ⑥ held-read serve payoff (헤드라인)

held 분석 read를 vanilla walk(mode-0)와 serve(mode-1, GC on·drain-cap)로 비교한다. churn을 멈춘 뒤 측정(N=16):

| BP | vanilla walk 중앙값 | serve 중앙값 | speedup | degrade |
|---|---|---|---|---|
| 64 MB (I/O-bound) | 132.1 s | 0.454 s | **~290×** | 2/8 |
| 4 GB (resident) | 1.106 s | 0.462 s | ~2.4× | 0 |

64 MB에서 serve는 vanilla 대비 약 290×(중앙값) 빠르고, 메커니즘은 undo I/O 제거다(물리 read가 vanilla ~1.4 M →
serve ~4 k). 단 8회 serve run 중 2회는 GC가 navigation 버전을 실시간 회수하는 chain-sever로 latency가 87–121 s로
degrade했다—이때 consult는 MISS를 내고 정확한 vanilla walk로 fallback하므로 **construct_BAD=0이 유지**되는 성능-only
사건이다(degrade율은 drain-cap으로 ~1/4에 안정화). 4 GB(resident)는 undo I/O가 없어 재구성 CPU만 절약되어 이득이
~2.4×로 작다. 동시 HTAP regime(churn이 도는 중 read, DoD 원문 config, N=17)에서는 serve가 ~18×(중앙값)이고,
**mode-2 verify-serve가 동시 GC 회수 하에서도 construct_BAD=0**(약 9,000 served byte-동일)이다—동시성 하 절대
latency가 churn-paused보다 높은 것은 작은 buffer pool에서 churn 스레드가 base-table page를 두고 경합하기 때문이다.

### 5.3 ⑤ 메모리 bound

LLT + 동시 HTAP reader 하에서 캐시 보존 버전 수(live_versions)와 InnoDB History List Length(HLL)를 비교한다
(realistic full-table, N=5):

| LLT | InnoDB HLL | 캐시 live_versions | 비율 |
|---|---|---|---|
| reader 0 (대조군, gap 없음) | ~700 k | ~750 k | **0.9×** |
| 15 s | ~123–142 k | ~6.8–7.0 k | **19.5×** |
| 30 s | ~238–286 k | ~6.9–7.2 k | **40.5×** |
| 60 s | ~571–611 k | ~7.0–7.2 k | **81.9×** |

캐시 live_versions는 LLT 시간과 무관하게 ~7 k로 유계인 반면 InnoDB HLL은 LLT에 선형 증가하므로 비율이 LLT 나이에
선형으로 커진다(전 15 run 불변). reader 0 대조군은 0.9×로, in-middle gap이 없으면 캐시가 InnoDB를 추종한다—우위는
전적으로 동시 read-view reader가 만드는 gap에서 온다(§3.3). 이는 "메모리 ∝ live-transaction window, 데이터셋 무관"
이라는 ⑤의 성질을 통합에서 실증한 것이다.

### 5.4 effective speedup

캐시의 실 타깃인 held 분석 reader가 write-heavy + delete/insert churn(MISS 유발 패턴)에서도 효과를 내는지 측정한다
(GC off, N=3):

| BP | vanilla 중앙값 | serve 중앙값 | speedup | held reader HIT |
|---|---|---|---|---|
| 4 GB | 0.283 s | 0.097 s | ~2.9× | 99.3–99.8 % |
| 256 MB | 0.264 s | 0.095 s | ~2.8× | 99.5–99.9 % |
| 64 MB | 4.25 s | 0.147 s | **~29×** | 99.5–99.8 % |

held 분석 reader는 delete+reinsert churn에서도 HIT가 99.5 % 이상이다—그 reader의 일관 스냅샷은 churn 이전이라 원본
버전만 필요하고 그것이 캐시되어 있기 때문이다(과거 보고된 "22 % MISS"는 chain head 근처의 짧은 reader로, 캐시가
가속 대상으로 삼지 않는 모집단이었다). I/O-bound(64 MB)에서 undo read가 25–33 k → ~450으로 줄며 ~29×다.

### 5.5 표준 벤치마크: TPC-C

표준 HTAP 벤치마크(sysbench-tpcc, scale=2, ~920 k 행)의 실 TPC-C 트랜잭션 mix 위에서 held STOCK 분석 read를
측정한다. **정확성**은 표준 데이터셋에서도 유지된다: mode-2 verify-serve로 160,713개 served가 byte-동일,
construct_BAD=0(composite PK 전부 일반화).

**coverage는 용량에 비례한다.** TPC-C working set(~920 k)이 기본 cuckoo 용량(`kuku_log2=16`, ~43 k 키)을 크게 넘어
held-scan HIT가 ~16 %에 그치나, 용량을 working set에 맞추면(`kuku_log2=21`, ~1.4 M) 64 %로 오른다—§7의 용량
bound(design-D8)가 표준 벤치에서 sizing knob으로 작동함을 보인다(sizing 무관 construct_BAD=0). customer 테이블의
c_data(~400자, off-page)는 §3.5 F4·§7의 in-page scope로 ineligible 처리된다.

**latency speedup은 modest하다**(`kuku_log2=21`, ~64 % HIT, N=3):

| BP | vanilla 중앙값 | serve 중앙값 | speedup | 물리 read (m0/m1) |
|---|---|---|---|---|
| 4 GB | 0.322 s | 0.253 s | ~1.3× | ~4.3 k / ~4.4 k |
| 64 MB | 1.272 s | 0.899 s | **~1.4×** | ~248 k / ~245 k |

sbtest(§5.2·§5.4의 ~29×–290×)와 달리 ~1.4×에 그치는 이유는 물리 read가 mode-0≈mode-1(~245 k)임이 직접 보여준다:
큰 TPC-C 테이블(stock 200 k 행 ≫ 64 MB)의 **base-table page I/O가 지배**하므로 serve가 undo 재구성(CPU + undo I/O)을
~64 % HIT 행에 대해 없애도 **base-table I/O floor는 못 없앤다**. 즉 이득은 주로 재구성 CPU 절약(resident 4 GB에서도
1.3×로 보임)이다. 이는 결함이 아니라 캐시의 효과 regime을 정직하게 경계 짓는다(§7).

### 5.6 워크로드 폭과 sanitizer

서빙 정확성은 single-INT-PK를 넘어 일반화된다(전부 construct_BAD=0): 2-컬럼 composite PK, VARCHAR string PK,
secondary-index 경로 read, savepoint rollback(롤백된 미커밋 버전 미서빙), kill -9 mid-load 후 ephemeral 캐시
재구축(crash recovery). 메모리 안전은 standalone sanitizer(UAF/leak/race 0)에 더해, full-mysqld AddressSanitizer가
drainer‖consult‖serve‖GC‖teardown 동시 스트레스에서 리포트 0으로 clean하다(full-mysqld TSan은 documented
residual, §7).

---

## 6. Related Work

### 6.1 LLT 하 version chain 회수 (관련 연구실 흐름)

본 연구는 LLT 하 version chain 폭증이라는 문제의식을 공유하는 연구 흐름과 같은 맥락에 있다(§1.2). vDriver
(SIGMOD '20)는 활성 read-view들 사이의 dead zone을 검출해 chain 중간에서 회수하고, DIVA(VLDB '22)는 interval
tree로 chain 길이를 로그로 bound하며, vWeaver 또한 같은 주제군에 속한다. 본 연구의 dead zone 검출은 vDriver에서
차용·적응한 것으로 출처를 명시하며(§2.4), 그 외 설계는 독립적으로 진행했다. 본 연구와 이들의 본질적 차이는 개선
여부가 아니라 **아키텍처 위상**이다: 이들은 버전 저장소를 소유하여 stale dead zone이 무해하지만, 본 연구는
InnoDB를 권위로 둔 채 비권위로 **서빙**하므로 over-prune이 곧 틀린 서빙이 되고, 이를 막는 superset-안전 정리
(§3.4)가 owned-store 설계에는 불필요한 본 연구 고유의 요소다.

### 6.2 buffer pool 및 캐싱과의 위상 차이

buffer pool은 디스크 page를 캐싱하지만 가시 버전을 얻으려면 그 page들로 undo chain을 **매번 재구성**해야 한다.
AccelerateMVCC는 page가 아니라 **재구성 결과**(가시 버전 image)를 캐싱해 재구성을 0회로 만든다—같은 메모리로 다른
위상의 이득을 낸다(특히 작은 buffer pool에서 undo I/O와 오염 제거). 이 캐시는 ACID의 권위가 아니다: committed 과거
버전은 immutable하고, isolation은 changes_visible 재현 + (mode-2) InnoDB 최종 대조로 보장하며, uncommitted·rollback
버전은 서빙하지 않는다. 즉 buffer pool과 같은 위상의 derived·ephemeral 캐시이지 in-memory DBMS로의 전환이 아니다.

### 6.3 in-memory 버전 저장과 lock-free 자료구조

H-Store/HyPer 등 in-memory MVCC 시스템은 버전을 메모리에 두되 저장소의 권위를 가진다. 본 연구는 disk-based DBMS의
권위를 유지한 채 보조 인덱스만 인메모리에 두는 점에서 다르다. lock-free 측면에서는 marked pointer(Harris) list와
EBR을 핫패스 read·회수에 적용했다(§3.6).

---

## 7. Limitations & Discussion

### 7.1 캐시 scope = in-page row

행 image는 상한(기본 512 B) 이하의 **in-page** 레코드만 캡처한다. 이 cap을 build-time으로 올리면 512 B를 넘어도
전부 in-page인 wide row는 안전하게 서빙되나(in-page는 byte-동일 캡처), **off-page LOB·virtual column 행은 제외**
된다(construct_BAD=0으로 안전하나 가속 0). off-page LOB는 MVCC 하 자체 버전을 가져 cached reference 추적이 틀린
LOB 버전을 서빙할 위험이 있어 LOB-version-safe 재구성이 선결이며, 이는 구현 확장 주제이지 본 연구의 scope 한계로
명시한다. 표준 TPC-C의 customer가 이 경우다(§5.5).

### 7.2 용량 bound와 eviction 미구현

캐시 메모리는 두 항이다: (A) version 항은 deadzone GC로 live-transaction window에 유계이고 데이터셋과 무관하며,
(B) per-key floor 항은 admit된 distinct key 수에 비례한다(~72 B/key, GC 무관). (B)는 cuckoo 용량 N에서 cap되고
초과 시 graceful non-admission(vanilla fallback, construct_BAD=0)으로 처리된다. 따라서 "메모리 ∝ working set"은
**working set이 용량 N에 드는 한** 성립하며 N은 sizing 공식으로 운영자가 정한다(§5.5에서 TPC-C로 실증). *이동하는*
working set을 N 너머로 추적하는 LRU eviction은 lock-free 안전성 비용이 payoff를 초과해 미구현으로 두고 scope로
처리한다.

### 7.3 효과 regime: undo-I/O-bound vs base-I/O-bound

§5.5가 보였듯 캐시의 큰 이득(~29×–290×)은 **undo 재구성/undo I/O가 병목**일 때 난다—hot하고 buffer pool에 resident
한 (소형) 테이블 또는 hot subset의 깊은 chain. cold large-table 분석 스캔은 base-table page I/O가 지배하므로 serve가
재구성 CPU만 절약해 ~1.3–1.4×에 그친다(여전히 byte-정확). 본 연구의 헤드라인 HTAP 시나리오(hot working set 위 held
분석 reader)는 전자 regime에 속한다. 이 경계는 결함이 아니라 캐시의 적용 조건을 정직하게 규정한 것이다.

### 7.4 정확성 논증의 한계

§3.5의 no-wrong-serve 불변식은 코드에 근거한 semi-formal hand argument이며 기계검증된 것은 아니다. 통합 평가의
mode-2 verify-serve가 매 서빙을 vanilla와 대조해 경험적으로 뒷받침하나(전 측정 construct_BAD=0), TLA+ 등으로 consult
상태기계와 GC 상호작용을 형식검증하는 것은 향후 과제다. full-mysqld TSan 또한 documented residual로 남긴다
(standalone TSan이 accel race 표면을 덮음).

---

## 8. Conclusion

본 논문은 디스크 기반 DBMS의 MVCC 버전 읽기 비용—특히 HTAP에서 LLT가 만드는 undo I/O 절벽—을, InnoDB를 권위로 둔
채 그로부터 derived된 인메모리 캐시가 재구성 결과를 직접 **서빙**하여 제거하는 AccelerateMVCC를 제시했다. derived
캐시가 서빙하는 순간 생기는 정확성 긴장(over-reclaim = 틀린 서빙)을, dead zone을 활성 view의 conservative superset
으로 유지하는 **superset-안전 정리**와 네 겹 firewall로 구조적으로 배제하여 모든 캐시 실패를 "느린 정답(vanilla
walk)"으로 수렴시켰다. InnoDB 8.4.10 통합 평가에서 held 분석 read latency가 buffer pool 무관 평탄(64 MB ~290×)
해지고, 캐시 메모리가 live-transaction window에 유계이며, 서빙된 모든 답이 vanilla와 byte 동일함(전 측정
construct_BAD=0)을 표준 TPC-C까지 확인했다. 동시에 캐시가 효과를 내는 regime(undo-I/O-bound)을 정직하게 경계
지었다.

향후 방향으로 superset-안전 derived-served 캐시를 다른 storage 엔진·index·isolation level, 분산 MVCC, persistent
memory로 일반화하는 것과, no-wrong-serve 불변식의 형식검증(TLA+)을 남긴다.
