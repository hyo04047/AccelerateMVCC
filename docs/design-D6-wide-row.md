# design-D6 — wide-row / 512B-cap 완화 (cache scope 확장)

상태: **(A) 구현·실증 완료 / (B) Limitation으로 명시 (세션13)**. 캐시 scope 한계(REPORT §6)를 두 부분으로
분해: **(A) wide in-page row**(>512B지만 extern/virtual 없음)는 in-page=byte-identical이라 **안전 → cap을
build-overridable로 만들고 `build_q16_widerow.sh`로 HIT+construct_BAD=0 실증(완료)**; **(B) off-page LOB**는
LOB가 MVCC하 자체 버전을 가져 cached reference 추적이 wrong-serve 위험이라 **scope Limitation으로 명시**(구현
확장 주제이지 별도 연구 방향 아님; 미구현). (review-quality 기준: 심사 제출은 아니나 심사 통과 기준으로 작성.)

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

**구현 (안전, 단 multi-point — 한 상수만 바꾸면 안 됨):**
- `accel_ring.h` `ACCEL_IMG_MAX`를 **build-overridable**(`-DACCEL_IMG_MAX_BYTES`)로. POD 슬롯은 컴파일타임
  크기라 상한은 컴파일타임 — shipped 기본은 512로 두어 **메모리 회귀 0**, wide-row는 build-time opt-in.
- ⚠️ **serve 버퍼도 lockstep**: `row0vers.cc`의 consult 호출은 `unsigned char accel_cbuf[512]`를 쓰고
  `out_cap=sizeof(accel_cbuf)`를 넘긴다. consult serve 경로는 `best->img_len > out_cap`이면 MISS이므로,
  `ACCEL_IMG_MAX`만 올리고 `accel_cbuf`/`out_cap`을 그대로 두면 **wide row가 캐시엔 들어가도 서빙은 안 됨**
  (out_cap에서 MISS). 따라서 `accel_cbuf`(+out_cap)를 cap과 함께 키워야 한다(이상적으론 `ACCEL_IMG_MAX`에
  묶인 named 상수로). node image(heap, `img_len` 가변)는 자동.
- trx0rec ① 게이트는 그대로(extern·virtual 여전히 제외).
- **검증(`build_q16_widerow.sh`):** ~1.35KB all-in-page row(PK+3×VARCHAR(450), TEXT/BLOB 없음→extern 없음)에서
  cap=2048 빌드 → mode-2 verify-serve **HIT>0 & construct_BAD=0**; cap=512 대조 → ineligible-MISS. 끝에 기본
  512로 복원-재빌드. 기존 small-row 회귀 없음.

### (B) off-page LOB row — **correctness-critical → scope Limitation (구현 확장 주제, 별도 연구 아님)**
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

판정: (B)는 **현재 프로젝트의 in-page scope를 넘어서는 correctness-critical 확장**이다. ⑤/serve의
"over-prune은 MISS로만 degrade(safe)" 불변식과 달리, LOB locator는 **틀린 서빙**을 낼 수 있는 새 표면을
연다. 그러나 이는 **구현 확장/스코프 주제이지 별도 논문이 될 "향후 연구 방향"이 아니다** — 따라서 논문엔
**scope Limitation으로 정직히 명시**한다(현 scope = in-page row; off-page LOB 서빙은 LOB-version-safe 재구성
or purge 시 MISS-degrade가 선결인 미지원 확장; LOB-heavy analytic이 캐시가 가장 필요한 지점인데 현 scope 밖).
full LOB 커버를 원하면 프로젝트 관행(design → 적대적 리뷰 → 구현)대로 한 스테이지로 진행할 수 있으나, small/
in-page scope가 이런 derived 캐시의 흔하고 방어 가능한 경계라 **현 결정 = Limitation으로 남김**(사용자 합의).

## 3. 요약 / 다음
- **(A) wide in-page**: 안전 → **구현·실증 완료**(`accel_ring.h` cap build-overridable[기본 512=회귀0] +
  `accel_cbuf`/out_cap lockstep; `build_q16_widerow.sh`서 ~1.35KB 행 cap=2048 HIT 1000/1000·construct_BAD=0,
  cap=512 대조 ineligible). cliff/flatness 메커니즘 동일, construct_BAD=0 불변.
- **(B) off-page LOB**: correctness-critical(LOB versioning wrong-serve) → **scope Limitation으로 명시**(미구현).
  구현 확장 주제이지 향후-연구 방향 아님. full 커버 시 LOB-version 안전성(일치 증명 or MISS-degrade) + 적대적
  리뷰가 한 스테이지로 선결.
- 논문 반영: small/in-page = 의도된 scope, **wide in-page = 확장 완료**, off-page LOB = 정직한 Limitation.
  (진짜 향후 연구는 다른 엔진/isolation/분산 MVCC/형식검증 등 연구 방향 — REPORT §8.)
