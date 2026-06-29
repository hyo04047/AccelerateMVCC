# design-D8 — memory bound & capacity sizing (cold-key 스코핑 결정)

상태: **결정 (세션13, Phase 3 gate ③)**. "memory ∝ live-transaction window" 주장의 **정확한 범위**를 못 박고,
cold-key(이동하는 working set) 처리를 결정한다. 결정: **진짜 LRU eviction은 NO-GO(세션12 21-에이전트 리뷰)이므로
구현하지 않고, 주장을 "configured 용량 N 안에서"로 스코프**한다 + sizing 가이드 제공. 근거 측정: ⓝ9(세션11,
`build_q10_coldkey.sh`). 관련: REPORT §6, open-items §0f/ⓝ9.

## 1. 메모리 모델 — 두 항(term)

총 캐시 메모리 = **(A) version 메모리** + **(B) per-key floor**. 두 항은 서로 다른 축이라 분리해 주장해야 정직하다.

**(A) version 메모리 — GC-bounded, ∝ live-transaction window.**
deadzone GC(⑤)가 in-middle dead 버전을 회수하므로, 보존되는 version 수는 **활성 트랜잭션 window**에 비례하고
dataset 크기와 무관하다. 실측(ⓠ3, `build_q3_*`): write-heavy OLTP + held LLT + 동시 HTAP 하에서 캐시 보존
**bounded ~6–9k versions(LLT 시간에 거의 flat)**, InnoDB HLL은 선형 증가 → 비율이 LLT 나이에 선형(20×/40×/63×).
이게 프로젝트의 핵심 메모리 주장이고, **그 범위는 (A)에 한정**된다.

**(B) per-key floor — O(distinct keys admitted), GC-independent, 회수 안 됨.**
admit된 distinct key마다 다음이 프로세스 동안 회수되지 않는다: ① `interval_list_header`(headers_created만 증가) ②
Kuku 슬롯(erase 없음) ③ pinned head epoch_node + 그 undo_entry image(GC가 head 안 건드림 — wrapper_prunable
head-skip) ④ 메모이즈된 ConsultCache(churn 시 교체되나 key당 1개 보존). 측정상 **~72 B/key**(+ head epoch 버전).
즉 (B) = O(admit된 distinct keys) × ~72B. **GC로 줄지 않는 별도 가산항.**

## 2. 용량 bound — (B)는 Kuku 용량 N에서 cap

admit되는 key 수는 **Kuku 용량 N(현 `kuku_log2=16` = 65,536 bin)** 을 넘을 수 없다. 초과 시 **graceful
non-admission**(첫 insert 실패에 `kuku_full_` 세팅·실패 header 미삭제[failed cuckoo path가 슬롯에 ptr publish
가능→delete=UAF라 leak이 안전장치]·초과 key는 vanilla fallback). 실측(ⓝ9): 용량 아래 plateau(40k key→headers
40,534), 초과서도 **graceful**(200k key→headers 43,432 plateau·dropped 1.75M·**construct_BAD=0·crash 없음**).
`versions_dropped`는 `live_versions`에서 제외해 (A) 주장이 (B) 초과에 오염되지 않게 했다(용량 아래선 dropped=0 → ⓠ3 불변).
∴ **(B) ≤ N × ~72B로 cap**(현 N=65,536 → 약 4.6MB 상한).

## 3. 결정 (cold-key 스코핑)

- **주장 범위**: "compactness ∝ live-transaction working set"은 **(A)에 대해, 그리고 working set이 용량 N에 들어가는
  한** defensible. dataset 전체가 아니라 **configured 용량 N 안의 working set**으로 명시한다.
- **이동하는(shifting) working set**(hot→cold 교체가 N을 초과)에는 진짜 LRU eviction(Kuku erase + EBR)이 필요하나
  **NO-GO**: 세션12 21-에이전트 적대 리뷰가 pre-Guard header UAF·non-atomic 슬롯·multi-writer Kuku·header↔version
  수명 결합으로 **cost≫payoff** 판정. → **구현하지 않고 스코프로 처리**(사용자 합의). 초과분은 vanilla fallback이라
  correctness는 불변(construct_BAD=0), 단 그 key는 가속 없음.
- One-shot GC(dataset-proportional 메모리) 대비 우위는 **이 스코프 안에서** 성립 — 정직하게 그 경계를 논문에 명시.

## 4. sizing 가이드 (운영자)

- **kuku_log2 ≥ ceil(log2( 기대 hot distinct keys / 목표 load factor ))**. 관측 load factor ~0.66(200k 시도서
  43,432 admit). 안전하게 hot set의 ~1.5배 bin을 잡아라.
- **메모리 비용**: (B) 상한 = N × ~72B. 예: `kuku_log2=16`→65,536 bin≈4.6MB · `=18`→262k≈18MB · `=20`→1.05M≈72MB.
  hot working set이 수십만 key면 18–20이 적정. (A)는 별도로 ∝window.
- **점검**: `headers_created`가 N의 load-factor 한계에서 plateau하면(=`kuku_full_`) 용량 부족 신호 → kuku_log2 상향.

## 5. 논문용 정직한 메모리 주장 (문안)

> 캐시 메모리 = **O(live-transaction window)** version 항(deadzone GC로 bounded, dataset 무관) **+ O(min(distinct
> hot keys, 용량 N))** per-key 항(~72B/key, GC-무관, N에서 cap). 따라서 "compactness ∝ live-transaction window"는
> working set이 configured 용량 N에 드는 한 성립하며, 초과 key는 non-admission으로 **정확성을 보존한 채**(vanilla
> fallback) 가속만 포기한다. 이동하는 working set을 N 너머로 추적하는 LRU eviction은 lock-free 안전성 비용이
> payoff를 초과해(별도 적대 리뷰) **향후 구현 주제**로 남긴다(연구 방향 아님 — 구현 확장).

## 6. 요약

| 항 | 비례 | GC | cap |
|---|---|---|---|
| (A) version | live-txn window | bounded(회수됨) | — |
| (B) per-key floor | admit된 distinct keys | 무관(회수 안 됨) | Kuku 용량 N(~72B/key) |

**결정: eviction 미구현(NO-GO 재확인), 주장을 "용량 N 안 working set"으로 스코프 + sizing 가이드. 초과는 vanilla
fallback(construct_BAD=0). gate ③ 해결.**
