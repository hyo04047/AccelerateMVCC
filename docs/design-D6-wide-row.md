# design-D6 — wide-row / 512B-cap 완화 (cache scope 확장)

상태: **설계 (세션13)**. 현재 캐시 scope = small-row OLTP(≤512B, off-page LOB·virtual 제외)는
의도된 한계(REPORT §6 Limitations). 본 문서는 그 한계를 두 부분으로 분해하고, **안전한 부분은 현재
프로젝트에서 구현**하고, **correctness-critical한 부분(off-page LOB)은 엄밀한 안전성 분석 + 적대적
리뷰가 필요한 별도 스테이지**임을 논증한다. (review-quality 기준: 심사 제출은 아니나 심사 통과 기준으로 작성.)

## 1. 현재 제외 메커니즘 (코드 사실)

캐시에서 빠지는 행은 **서로 독립인 두 게이트**로 결정된다:

1. **off-page / virtual 게이트** — `trx0rec.cc` 캡처 지점(vendored diff):
   `accel_img_len = (rec_offs_any_extern(offsets) || index->table->n_v_cols > 0) ? 0 : rec_offs_size(offsets)`.
   → extern(off-page LOB) 필드가 하나라도 있거나 virtual column이 있으면 `img_len=0`.
2. **크기 cap 게이트** — `accel_hook.cc::accel_on_undo`:
   `if (img_len > 0 && img_len <= accel::ACCEL_IMG_MAX) memcpy` (`ACCEL_IMG_MAX=512`, `accel_ring.h`).
   → 물리 레코드가 512B를 넘으면 `img_len=0`.

`img_len=0` → consult가 그 버전을 MISS_INELIGIBLE → **vanilla full walk**(틀린 답 없음, 가속 없음).

핵심 관찰: **두 게이트는 직교한다.** 어떤 행은 extern이 전혀 없는데도(전부 in-page) 512B를 넘어서
②에서만 빠진다(넓은 in-page row — 다수 INT/VARCHAR 컬럼 합이 512B 초과, off-page LOB 아님).

## 2. 분해: 안전한 부분 vs correctness-critical 부분

### (A) wide in-page row — **안전, 현재 프로젝트에서 구현**
extern·virtual이 없는데 단지 >512B인 행. 물리 레코드 **전체가 in-page**이므로, 캡처가 이미 하는
"전체 물리 레코드 byte-복사"가 그대로 byte-identical하다. ②의 cap만 올리면 안전하게 커버된다.
correctness 변화 없음(기존 4d-prep의 합성 증명·construct_BAD=0 논리가 그대로 적용 — 더 긴 in-page
레코드일 뿐, 같은 standalone record class).

**비용 = ring 슬롯 메모리.** `UndoRec.img[ACCEL_IMG_MAX]`는 trivially-copyable POD(under-latch
alloc-free 복사 불변식, `accel_ring.h`)라 **fixed-size**다. ring = `Ring<1u<<16>` = 65536 슬롯.
슬롯 ≈ scalars(~76B) + `pk[256]` + `img[cap]`. 따라서 ring 메모리 ≈ `65536 × (~340 + cap)`:

| ACCEL_IMG_MAX | 슬롯 ≈ | ring ≈ | 커버 |
|---|---|---|---|
| 512 (현재) | ~852B | ~56MB | ≤512B in-page |
| 1024 | ~1.36KB | ~89MB | ≤1KB in-page |
| 2048 | ~2.4KB | ~156MB | ≤2KB in-page |
| 8126 (16KB page 최대 in-page) | ~8.5KB | ~550MB | 모든 in-page |

→ full in-page 커버(8KB)는 ring ~550MB로 과다. **moderate cap(1–2KB)** 가 현실 운영점(대부분의
wide OLTP row 커버, ring ~90–150MB). 노드 image는 heap(`img_len` 가변)이라 cap이 상한일 뿐 평균 비용은
실제 행 크기에 비례. **설계: `ACCEL_IMG_MAX`를 env-configurable(`ACCEL_IMG_MAX`)로, 기본은 보수적으로
유지하되 운영자가 hot 테이블 행폭에 맞게 상향.** cap이 크면 ring N을 줄이는 역-tradeoff도 가능(N×cap 일정).

**구현 (안전, 작음):**
- `accel_ring.h` `ACCEL_IMG_MAX`를 컴파일-상수에서 (런타임 cap은 enqueue 시 비교값으로) 분리하거나,
  최소한 상수를 상향. POD 슬롯은 컴파일타임 크기라 **상한은 컴파일타임**(env로는 "그 이하"만 조절 가능).
  → 실용: 컴파일타임 `ACCEL_IMG_MAX`를 (예) 2048로 올리고, 런타임 env로 "실제 적용 cap ≤ 컴파일타임"을
  조절(메모리 회귀 없이 보수적 기본 유지).
- trx0rec ① 게이트는 그대로(extern·virtual 여전히 제외).
- **검증:** `build_q6_coverage.sh` 변형 — wide in-page row(예: 다수 컬럼으로 ~1.5KB, off-page 아님)에서
  mode-2 verify-serve **HIT>0 & construct_BAD=0**. 기존 small-row HIT 100% 회귀 없음.

### (B) off-page LOB row — **correctness-critical, 별도 스테이지(또는 future-work)**
extern 필드(off-page LOB)가 있는 행. "in-page prefix + off-page LOB locator" 스케치:
HIT 시 in-page prefix를 캐시에서, 각 extern 필드는 LOB reference(space_id, page_no)를 따라 LOB 페이지에서
읽어 행을 합성.

**왜 위험한가 (wrong-serve 표면, 이게 핵심):** InnoDB LOB는 **자체 버전이 있다**(8.0+ LOB는 부분 갱신·
LOB undo 보유). held-snapshot reader가 보아야 할 *옛* 행 버전의 LOB는, 그 버전의 LOB reference가 가리키는
LOB 페이지의 **현재 내용이 아니라 그 시점 버전**이다. cached reference를 naive하게 (space_id,page_no)로
따라가면:
- LOB 페이지가 그 사이 **갱신**되었으면 → 더 새 LOB 내용을 읽어 **틀린 행 합성**(wrong serve).
- LOB 페이지가 **purge/재사용**되었으면 → 엉뚱한 데이터.
즉 off-page LOB의 올바른 버전 복원은 정확히 **LOB undo를 적용**해야 하는데, 그건 캐시가 건너뛰려는 바로
그 작업이다. 따라서 단순 locator 서빙은 byte-identical을 **보장하지 못한다** — small-row에서 성립했던
"전체 물리 레코드 byte-복사 = 안전" 불변식이 깨진다.

**안전하게 하려면 둘 중 하나:**
1. LOB 본문까지 캡처 → compact-cache 설계 위배(대형 LOB를 메모리에 복제), scope 폭증.
2. cached LOB reference가 가리키는 LOB 버전이 vanilla가 이 행 버전에 대해 읽을 LOB 버전과 **동일함을
   증명**하고, 그렇지 않으면(LOB 페이지 purge/version 불일치) **MISS로 degrade**. 이는 LOB versioning/
   LOB undo 가시성 분석 + 적대적 안전 리뷰(small-row serve-safety audit에 준하는)를 요구한다.

판정: (B)는 **현재 프로젝트의 small-row scope를 넘어서는 correctness-critical 확장**이다. ⑤/serve의
"over-prune은 MISS로만 degrade(safe)" 불변식과 달리, LOB locator는 **틀린 서빙**을 낼 수 있는 새 표면을
연다. 프로젝트 관행(correctness-critical 기능 = design → 적대적 리뷰 → 구현)상 (B)는 **별도 스테이지**로
다뤄야 하며, 안전성(2번)이 증명되기 전에는 논문의 **future-work(향후 연구)**로 엄밀히 기술한다(스케치 +
LOB-version wrong-serve 위험 + degrade-to-MISS 요건 명시). LOB-heavy analytic이 캐시가 가장 필요한
지점(big-row deep read)임도 정직히 한계로 남긴다.

## 3. 요약 / 다음
- **(A) wide in-page (≤moderate cap)**: 안전 → 현재 프로젝트에서 구현(cap 상향 + env + coverage 테스트).
  cliff/flatness 메커니즘 동일, construct_BAD=0 불변.
- **(B) off-page LOB**: correctness-critical(LOB versioning wrong-serve) → 별도 스테이지/future-work,
  안전성 증명(LOB-version 일치 or MISS-degrade) + 적대적 리뷰 선결.
- 논문 Limitations/Future-work에 이 분해를 그대로 반영(small-row = 의도된 scope, wide in-page = 확장됨,
  off-page LOB = 정직한 한계 + 안전 설계 조건).
