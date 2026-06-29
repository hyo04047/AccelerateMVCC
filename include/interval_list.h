// Licensed under the MIT license.
#pragma once


#include <cstdint>
#include <atomic>
#include <vector>
#include <unordered_map>
#include "marked_ptr.h"

#ifndef node_h
#define node_h
namespace mvcc {

    struct interval_list_header;   // forward decl: epoch_node carries a back-pointer to it

    // Stage 1c retire-once state claim for an epoch_node. Reachable from TWO lists (the
    // record's version chain + a wrapper in the epoch_table bucket list), so it must be
    // freed exactly once and only after it is unreachable from both. Whoever splices it
    // out of the version chain CAS-claims LIVE->CHAIN_DETACHED and stops; only the BG GC
    // (the sole wrapper unlinker) retires it, gated by state.exchange(RETIRED).
    enum EpochState : uint8_t { EPOCH_LIVE = 0, EPOCH_CHAIN_DETACHED = 1, EPOCH_RETIRED = 2 };

    struct undo_entry_node {
        // D-4 (4b-0): split the single trx_id into the two distinct ids InnoDB visibility needs.
        //   version_trx_id = the VERSION's creator = old DB_TRX_ID (the begin-ts of the version this
        //     entry locates). This is the visibility key judged by changes_visible -- NOT the writer.
        //   writer_trx_id  = the trx that OVERWROTE this version (= trx->id at the populate hook =
        //     the next-newer version's creator). Needed by the contiguity primitive (4b-2) and the
        //     purge gate. In the standalone prototype both equal the inserted trx_id (default).
        uint64_t version_trx_id;
        uint64_t writer_trx_id;
        uint64_t space_id;
        uint64_t page_id;
        uint64_t offset;
        std::atomic<undo_entry_node *> next_entry;
        // D-5 lineage predecessor = the node this version's value overwrote (the next-older version on the
        // row's lineage). The single drainer receives a row's versions in commit (= roll_ptr) order, so the
        // node inserted immediately before this one FOR THIS KEY is exactly that predecessor; insert() sets
        // it once, before the node is published.
        // NOTE (GC-on): consult does NOT chase roll_pred -- the back-edge is GC-UNSAFE (it keeps pointing at
        // a predecessor a PRIOR GC cycle already freed -> UAF; design-D5-gc §11 + the session-12 re-review
        // confirmed the C3 gc_generation gate cannot rescue it). consult uses the GC-safe ⑤b-lite memoized
        // live-chain map instead. roll_pred / newest_node are MAINTAINED but UNREAD (kept from the historical
        // fast path; candidates for removal). nullptr = oldest cached version (chain bottom).
        undo_entry_node *roll_pred = nullptr;
        // D-4: cached full-row image of the version this entry locates. Set ONCE at insert (the
        // single drainer is the sole mutator), heap-owned, and freed in the dtor -- which runs
        // when the owning epoch_node is EBR-retired (delete e in epoch_table.h::retire_epoch_once),
        // so the image shares the node's lifetime exactly (no leak, no UAF). img_len==0 means no
        // image (row over cap / ineligible) -> consult must full-walk that version.
        uint32_t img_len = 0;
        unsigned char *img = nullptr;
        // D-4 (4b-1): full clustered-PK identity bytes (length-prefixed fields), the AUTHORITY a
        // consult memcmp-compares to reject pk_hash collisions (pk_len==0 -> identity unknown ->
        // MISS). delete_mark = REC_INFO_DELETED_FLAG of this version (carried separately because the
        // data-payload image excludes the record header). Both heap-owned / set-once / freed in dtor.
        uint32_t pk_len = 0;
        unsigned char *pk = nullptr;
        uint8_t delete_mark = 0;
        // D-4 4d: img is the FULL physical record (header+data); extra_len = header size, so the
        // data origin (a servable rec_t) is at img + extra_len. Lets consult hand back a record the
        // read path can parse with rec_get_offsets.
        uint32_t extra_len = 0;

        undo_entry_node(uint64_t version_trx_id, uint64_t space_id, uint64_t page_id, uint64_t offset,
                        uint64_t writer_trx_id)
                : version_trx_id(version_trx_id), writer_trx_id(writer_trx_id),
                  space_id(space_id), page_id(page_id), offset(offset)
        {
            next_entry.store(nullptr);
        }
        ~undo_entry_node() { delete[] img; delete[] pk; }  // nullptr-safe; frees image + PK with the node
    };

    struct epoch_node {
        uint64_t epoch_num;
        uint64_t min_trx_id;
        uint64_t max_trx_id;
        uint64_t count;
        undo_entry_node *first_entry;
        std::atomic<undo_entry_node *> last_entry;
        // Forward chain (Harris marked pointer): readers/inserters/GC traverse this.
        // The low mark bit means "this epoch is logically deleted (dead)". No `prev`:
        // the list is forward-only; GC finds a predecessor by scanning from `header`.
        MarkedPtr<epoch_node> next;
        // Back-pointer to this record's interval-list head (set by insert). GC reaches
        // epoch_nodes via the epoch_table, not the kuku header, so it needs this to
        // splice out a head epoch (CAS header->next) and to anchor the forward scan.
        interval_list_header *header;
        // Stage 1c retire-once claim (LIVE -> CHAIN_DETACHED -> RETIRED); default-init so
        // both ctors below get EPOCH_LIVE without listing it. See EpochState above.
        std::atomic<uint8_t> state{EPOCH_LIVE};
        // Stage 1c-4 fix (tight bounds): the begin-ts of the next-newer version that supersedes
        // this epoch's newest version (= the min_trx_id of the epoch prepended after this one).
        // Set once, when this epoch is demoted from head; UINT64_MAX while still the head (not
        // yet superseded => never dead). The deadzone check uses this ACTUAL xmax instead of the
        // nominal epoch boundary, so a version a reader/LLT still needs is not over-pruned
        // (faithful to vDriver SegIsInDeadZone; design-gc 8.1, now a correctness necessity).
        std::atomic<uint64_t> superseded_ts{~uint64_t(0)};

        epoch_node(uint64_t epoch_num, uint64_t trx_id, undo_entry_node *undo_entry, epoch_node *next)
                : epoch_num(epoch_num), min_trx_id(trx_id), max_trx_id(trx_id), count(1),
                  first_entry(undo_entry), last_entry(undo_entry), next(next), header(nullptr)
        {
        }

        epoch_node()
                : epoch_num(0), min_trx_id(0), max_trx_id(0), count(0),
                  first_entry(nullptr), last_entry(nullptr), next(), header(nullptr)
        {
        }

    };

    // marked_ptr.h contract: MarkedPtr<epoch_node> packs a 1-bit Harris mark into epoch_node::next's low
    // bit (interval_list_header::next too), so epoch_node must be >=2 aligned. Asserted here at the wiring
    // site -- alignof(epoch_node) is unavailable inside the struct's own body. uint64_t members give
    // alignof 8; this catches a future all-narrow-members reorder that would break the mark bit.
    static_assert(alignof(epoch_node) >= 2, "MarkedPtr<epoch_node> requires alignof(epoch_node) >= 2");

    void update_epoch_node(epoch_node *epoch, uint64_t epoch_num, uint64_t trx_id, undo_entry_node *undo_entry,
                           epoch_node *next);

    // D-5 ⑤b-lite: a memoized consult link table, published immutably on the header and reused while the
    // key's chain is unchanged. Built exactly like the consult's Pass 1 (writer_trx_id -> the version that
    // writer overwrote, on the FULL-PK-matching live chain; ambiguous = two distinct predecessors for one
    // writer). Reuse is valid iff built_node_count == header->node_count (no new insert) AND the GC retire
    // path has not cleared it (a retire of this key sets it null) AND the same PK + mode -- then the cache's
    // nodes are exactly the live chain, all pinned by the reader's EBR Guard. The GC clears the cache
    // BEFORE freeing any node, so a reader that loaded a non-null cache loaded it before that retire.
    struct ConsultLink { uint64_t version; undo_entry_node *node; bool ambiguous; };
    struct ConsultCache {
        uint64_t built_node_count = 0;
        // D-5: the key's gc_generation when this table was built. Reuse additionally requires this to be
        // unchanged, so a GC retire (which clears consult_cache AND bumps gc_generation in the same
        // detach_and_retire_epoch chokepoint) can never be silently reused -- making reuse self-validating
        // instead of resting only on the implicit "retire clears the cache before freeing nodes" ordering.
        uint64_t built_gc_generation = 0;
        bool require_full_pk = true;
        bool any_pk_match = false;
        std::vector<unsigned char> pk;
        std::unordered_map<uint64_t, ConsultLink> link;
    };

    struct interval_list_header {
        uint64_t next_epoch_num;
        MarkedPtr<epoch_node> next;   // forward chain head (never marked: the header is not a deletable node)

        // D-4 (4b-2): contiguity bookkeeping. Lets a consult prove the cached versions form an
        // unbroken run from a candidate up to the live row, so it can trust the cache (HIT) or
        // otherwise fall back to a full walk (MISS) -- never serve a guess. Maintained by the single
        // drainer (sole mutator), read by concurrent consults, hence atomic (release/acquire).
        //   contiguous_head_writer       = the overwriter of the newest cached version IF the
        //     gap-free run reaches it (0 = no versions yet). A consult REQUIRES this to equal the
        //     live row's last writer (proof the cache reaches the head); otherwise MISS. This is the
        //     enforced contiguity firewall (read by consult).
        //   contiguous_suffix_min_version = the oldest version in the current gap-free run. NOTE: this
        //     is VESTIGIAL bookkeeping -- note_newest maintains it (its change marks a restart) but the
        //     shipped consult does NOT read it as a positive gate. A hole below a candidate is caught
        //     instead by the link-gap: the writer->predecessor chase runs off the missing link and
        //     returns MISS_NONCONTIG. So the enforced firewalls are: full-PK identity, contiguity
        //     (head_writer), link-gap (chase break -> MISS), and the changes_visible mirror.
        // Per-key updates arrive in version order (the row's X-lock serializes writers, the FIFO ring
        // preserves it), so the ONLY source of a hole is a ring drop, caught by the linkage break in
        // note_newest below.
        std::atomic<uint64_t> contiguous_head_writer{0};
        std::atomic<uint64_t> contiguous_suffix_min_version{0};

        // D-5: newest_node + the per-key node count. SUPERSEDED: newest_node (with undo_entry_node::
        // roll_pred) was the GC-UNSAFE back-edge chase start -- consult NO LONGER reads it (see the
        // roll_pred NOTE above; ⑤b-lite uses the GC-safe memoized live-chain map instead). newest_node/
        // roll_pred are still maintained by insert but are removal candidates. node_count IS read by
        // consult, but ONLY as the ⑤b-lite reuse change-detector: built_node_count==node_count means no
        // insert raced since the cache was built. It is a MONOTONIC insert counter (never decremented on
        // GC retire), so it is NOT a live-version count and NOT the chase hop cap (the shipped chase
        // hop-caps on the link-table size). Single drainer = sole writer.
        std::atomic<undo_entry_node *> newest_node{nullptr};
        std::atomic<uint64_t> node_count{0};

        // D-5 ⑤b-lite: memoized consult link table for this key (see ConsultCache). Published via exchange
        // (release) on (re)build, reused while node_count is unmoved + PK/mode match, cleared (exchange null
        // + EBR-retire) by the GC retire path before freeing any node of this key. nullptr = not built/stale.
        std::atomic<ConsultCache *> consult_cache{nullptr};

        // D-5 C3: per-key GC generation counter -- the mode-1 serve-only 2nd firewall. Bumped (release)
        // by the GC retire path (epoch_table.h detach_and_retire_epoch, the SOLE chokepoint both the
        // windowed sweep and the orphan drain funnel through) right after it clears consult_cache and
        // before it schedules the node free. consult, when enforce_gc_gen is set (mode-1 only), snapshots
        // this (acquire) right after taking its EBR Guard and re-loads it (acquire) before returning HIT;
        // a change means a GC retire RACED this consult on this key -> MISS (-> InnoDB walk = correct).
        // SCOPE (design-D5-gc.md §10): this detects a retire that RACES the consult (TOCTOU on the
        // cache/chain); it does NOT detect an over-prune completed in a PRIOR GC cycle. Steady-state R1
        // (superseded_ts under-estimation on inverted links) is closed structurally by the C1 inverted-
        // superseded oracle and sampled at runtime by the walk-audit; R2 (same-writer cross-gen) by the
        // ambiguity guard + audit. A green gen-gate is NOT, by itself, "R1/R2 closed".
        std::atomic<uint64_t> gc_generation{0};
        ~interval_list_header() { delete consult_cache.load(std::memory_order_relaxed); }

        // Called by the drainer right after it links the NEWEST version for this key (version =
        // that version's creator, writer = the trx that overwrote it). If this version is the one the
        // current head expected next (its writer), the gap-free run extends; otherwise (first version,
        // or a dropped one broke the chain) the run restarts at this version.
        void note_newest(uint64_t version, uint64_t writer) {
            uint64_t cur = contiguous_head_writer.load(std::memory_order_acquire);
            if (cur != 0 && version == cur) {
                contiguous_head_writer.store(writer, std::memory_order_release);          // extend
            } else {
                contiguous_suffix_min_version.store(version, std::memory_order_release);   // restart
                contiguous_head_writer.store(writer, std::memory_order_release);
            }
        }

        interval_list_header()
                : next_epoch_num(0), next()
        {
        }
    };


} // namespace mvcc
#endif /* node_h */