// Licensed under the MIT license.

#include "accelerateMVCC.h"
#include "read_view_mirror.h"  // D-4 (4a): exact InnoDB ReadView::changes_visible mirror
#include <unordered_map>       // D-5 (5-2 prep): GC-safe live-chain lineage walk builds a writer->pred table
#include <memory>              // D-5 ⑤b-lite: unique_ptr owns a non-published (raced) consult-cache build

mvcc::Accelerate_mvcc::Accelerate_mvcc(uint64_t record_count, uint32_t kuku_log2) {
    constexpr uint64_t max_value = ~0ULL;
    // Cuckoo table sized to (1 << kuku_log2) bins (default 1024; InnoDB integration uses 65536
    // so the dynamic key space does not overflow into silent cuckoo-insert failure).
    this->kuku_table = new kuku::KukuTable((1u << kuku_log2), (1 << 10), 2, kuku::make_random_item(), 100,
                                           kuku::make_item(max_value, max_value));
    // kukuTable = new kuku::KukuTable((1 << 16), (1 << 10), 2, kuku::make_zero_item(), 100, kuku::make_random_item());
    this->trxManger = new Trx_manager(record_count);

    this->epoch_table = new Epoch_table();

    for (int i = 0; i < record_count; i++) {
        kuku::item_type item = kuku::make_item(1, i);

        // value is header node pointer address for epoch-based interval linked list
        auto *header = new interval_list_header();


        auto value = reinterpret_cast<std::uint64_t>(header);

        // we can get header address from value
        // interval_list_header* header = reinterpret_cast<interval_list_header*>(value);

        kuku::set_value(value, item);
        if (!kuku_table->insert(item)) {
            std::cout << "record number : " << i << "is not inserted" << std::endl;
        }
    }
}


// this will be used when implementing to mysql source code.
bool mvcc::Accelerate_mvcc::insert(uint64_t table_id, uint64_t index,
                                   uint64_t version_trx_id, uint64_t space_id, uint64_t page_id, uint64_t offset,
                                   const unsigned char *img, uint32_t img_len, uint64_t writer_trx_id,
                                   const unsigned char *pk, uint32_t pk_len, uint8_t delete_mark,
                                   uint32_t extra_len) {
    kuku::item_type item = kuku::make_item(table_id, index);

    // D-4 (4b-0): writer_trx_id==0 means "standalone: the writer IS the version's own creator".
    // Everything below (epoch placement, deadzone min/max/superseded bounds) is in the VERSION
    // domain (version_trx_id = old DB_TRX_ID), since that is what readers judge visibility against.
    const uint64_t wtrx = writer_trx_id ? writer_trx_id : version_trx_id;
    auto *undo_entry = new undo_entry_node(version_trx_id, space_id, page_id, offset, wtrx);
    // D-4: copy the captured full-row image into the node (heap-owned, freed with the node). Short
    // loop avoids a <cstring> dependency; img_len is small (<= ACCEL_IMG_MAX). Single drainer is the
    // sole mutator, so this set-once write needs no synchronization beyond the node's publication.
    if (img != nullptr && img_len > 0) {
        undo_entry->img = new unsigned char[img_len];
        for (uint32_t i = 0; i < img_len; ++i) undo_entry->img[i] = img[i];
        undo_entry->img_len = img_len;
    }
    // D-4 (4b-1): copy the full-PK identity bytes (collision authority for consult) and carry the
    // delete-mark. Heap-owned like img, freed with the node; absent PK (pk_len==0) stays locator-only.
    if (pk != nullptr && pk_len > 0) {
        undo_entry->pk = new unsigned char[pk_len];
        for (uint32_t i = 0; i < pk_len; ++i) undo_entry->pk[i] = pk[i];
        undo_entry->pk_len = pk_len;
    }
    undo_entry->delete_mark = delete_mark;
    undo_entry->extra_len = extra_len;   // D-4 4d: header size within img (full physical rec)
    uint64_t epoch_num = epoch_of(version_trx_id);  // D-5 ⑤a-2 step 3: base-relative (standalone base=0 == get_epoch_num)

    kuku::QueryResult query = kuku_table->query(item);
    if (query.found()) {
        uint64_t value;
        if (query.in_stash()) {
            item = kuku_table->stash(query.location());
            value = kuku::get_value(item);
        } else {
            item = kuku_table->table(query.location());
            value = kuku::get_value(item);
        }
        auto *header = reinterpret_cast<interval_list_header *>(value);
        if (header->next.ptr() == nullptr) {
            auto* epoch = new epoch_node();
            update_epoch_node(epoch, epoch_num, version_trx_id, undo_entry, nullptr);
            epoch->header = header;

            header->next_epoch_num = epoch_num;
            header->next.store(epoch, false);

            epoch_table->insert(epoch);
            undo_entry->roll_pred = header->newest_node.load(std::memory_order_relaxed);  // D-5: prior newest = this version's roll_ptr predecessor
            header->newest_node.store(undo_entry, std::memory_order_release);
            header->node_count.fetch_add(1, std::memory_order_relaxed);
            header->note_newest(version_trx_id, wtrx);   // D-4 4b-2: contiguity bookkeeping
        }
        else if (header->next_epoch_num < epoch_num) {
            // create new epoch and prepend it at the head
            epoch_node *old_head = header->next.ptr();
            auto *epoch = new epoch_node();
            update_epoch_node(epoch, epoch_num, version_trx_id, undo_entry, old_head);
            epoch->header = header;

            // The previous head is now superseded by this new version: record its tight xmax
            // (stage 1c-4 fix) so the deadzone check no longer over-prunes it. trx_id is a
            // conservative bound for the new epoch's first version (a later smaller append would
            // only supersede it sooner, which keeps v_end larger -> under-prune, never over).
            if (old_head != nullptr)
                old_head->superseded_ts.store(version_trx_id, std::memory_order_release);

            header->next_epoch_num = epoch_num;
            header->next.store(epoch, false);

            epoch_table->insert(epoch);
            undo_entry->roll_pred = header->newest_node.load(std::memory_order_relaxed);  // D-5: prior newest = this version's roll_ptr predecessor
            header->newest_node.store(undo_entry, std::memory_order_release);
            header->node_count.fetch_add(1, std::memory_order_relaxed);
            header->note_newest(version_trx_id, wtrx);   // D-4 4b-2: contiguity bookkeeping
        } else {
            // insert undo log entry to existing epoch
            epoch_node *epoch = header->next.ptr();
            epoch->count++;
            undo_entry_node *last_entry = epoch->last_entry.load();
            if (version_trx_id < epoch->min_trx_id) {
                epoch->min_trx_id = version_trx_id;
            }
            if (version_trx_id > epoch->max_trx_id) {
                epoch->max_trx_id = version_trx_id;
            }
            last_entry->next_entry.store(undo_entry);
            epoch->last_entry.store(undo_entry);
            undo_entry->roll_pred = header->newest_node.load(std::memory_order_relaxed);  // D-5: prior newest = this version's roll_ptr predecessor
            header->newest_node.store(undo_entry, std::memory_order_release);
            header->node_count.fetch_add(1, std::memory_order_relaxed);
            header->note_newest(version_trx_id, wtrx);   // D-4 4b-2: contiguity bookkeeping
        }
    } else {
        auto *epoch = new epoch_node(epoch_num, version_trx_id, undo_entry, nullptr);
        auto *header = new interval_list_header();
        epoch->header = header;
        header->next_epoch_num = epoch_num;
        header->next.store(epoch, false);
        auto value = reinterpret_cast<std::uint64_t>(header);

        kuku::set_value(value, item);

        epoch_table->insert(epoch);
        undo_entry->roll_pred = header->newest_node.load(std::memory_order_relaxed);  // D-5: nullptr (first version for this new header)
        header->newest_node.store(undo_entry, std::memory_order_release);
        header->node_count.fetch_add(1, std::memory_order_relaxed);
        header->note_newest(version_trx_id, wtrx);   // D-4 4b-2: contiguity bookkeeping
        return kuku_table->insert(item);
    }

    return false;
}

bool mvcc::Accelerate_mvcc::search(uint64_t table_id, uint64_t index,
                                   uint64_t trx_id, uint64_t &space_id, uint64_t &page_id, uint64_t &offset,
                                   std::vector<uint64_t> active_trx_list) {
    kuku::item_type item = kuku::make_item(table_id, index);
    uint64_t epoch_num = get_epoch_num(trx_id);
    kuku::QueryResult query = kuku_table->query(item);

    // if there is no undo log of the record, return false
    if (!query.found()) {
        return false;
    }


    /*Phase 1 : get address of header node*/
    uint64_t value;

    if (query.in_stash()) {
        item = kuku_table->stash(query.location());
        value = kuku::get_value(item);
    } else {
        item = kuku_table->table(query.location());
        value = kuku::get_value(item);
    }

    //get address of header node of interval list
    auto *header = reinterpret_cast<interval_list_header *>(value);


    /*Phase 2 : find the LATEST version visible to this read view.
      Visible == changes_visible(version key) per the InnoDB ReadView mirror (D-4 4a).
      Among visible versions we want the greatest version key (latest committed). The
      chain is newest-epoch-first but oldest-entry-first within an epoch, so we
      scan all candidates and keep the maximum rather than returning the first. */
    // D-4 (4a): replace the ad-hoc "trx_id < snapshot && not active" predicate with an EXACT
    // mirror of InnoDB's ReadView::changes_visible. Derive the read-view limits from this
    // prototype's (trx_id, active list): low-water = smallest active id (or trx_id when none),
    // high-water = trx_id (a read-only reader sees nothing >= its own snapshot id), creator =
    // trx_id (read-only -> never matches a version key). m_ids must be sorted for the binary
    // search; active_trx_list is a by-value copy, so sorting it here is local. The judged key is
    // the version's creator (undo_entry->version_trx_id = old DB_TRX_ID in the InnoDB integration).
    std::sort(active_trx_list.begin(), active_trx_list.end());
    const uint64_t rv_up_limit = active_trx_list.empty() ? trx_id : active_trx_list.front();
    // EBR reservation: from here until return we dereference epoch_node /
    // undo_entry pointers that GC may concurrently unlink+retire. The Guard
    // pins reclamation for this traversal's span so GC cannot free them under us.
    EpochReclaimer::Guard guard(epoch_table->reclaimer());
    // Stage 1c: load the shared published deadzone ONCE for this traversal, under the same
    // Guard that pins epoch_nodes (so the descriptor is pinned too -- BG may retire it while
    // we hold it). 1c-1 JUDGES deadness against it but does NOT act; cooperative unlink
    // lands in 1c-4. nullptr (warm-up / not yet published) -> judge nothing, never block.
    Epoch_table::deadzone *dz = epoch_table->published_deadzone();
    // Stage C-2: when FG cooperative unlink is disabled, we still traverse + help-splice marked
    // nodes below, but do not INITIATE new prunes (isolates the FG path's contribution).
    bool fg_on = fg_unlink_enabled_.load(std::memory_order_relaxed);
    bool found = false;
    uint64_t best_trx_id = 0;
    // pred_next = the forward word of the last KEPT predecessor (header, or the last unmarked
    // non-pruned epoch). It anchors the best-effort O(1) cooperative unlink (1c-4). Starts at
    // the header; pred_next == &header->next means "we are at the head" (never pruned).
    MarkedPtr<epoch_node> *pred_next = &header->next;
    epoch_node *epoch = header->next.ptr();

    while (epoch != nullptr) {
        // Load the forward word once: ptr = successor, mark = "this epoch is dead".
        uintptr_t w = epoch->next.load();
        epoch_node *succ = MarkedPtr<epoch_node>::ptr_of(w);
        if (MarkedPtr<epoch_node>::mark_of(w)) {
            // Already logically deleted: best-effort help-splice it out (Harris helping), then
            // skip its (invisible) versions. CAS only succeeds through an UNMARKED pred still
            // pointing at us, so it is multi-unlinker safe; on failure leave it for the BG
            // backstop. Do NOT advance pred (a marked node is not a valid predecessor).
            uintptr_t exp = MarkedPtr<epoch_node>::pack(epoch, false);
            pred_next->cas(exp, MarkedPtr<epoch_node>::pack(succ, false));
            epoch = succ;
            continue;
        }
        // 1c-4 cooperative unlink: a dead NON-HEAD epoch is pruned just like BG would -- mark it
        // (so every reader skips it henceforth) + best-effort O(1) splice via pred. retire stays
        // BG-only (BG retires it via the descriptor-dead wrapper sweep / backstop). The HEAD is
        // NEVER pruned (head-skip; pred_next == &header->next), so it is always scanned below --
        // a reader's visible-latest version lives in the head and must never be skipped.
        if (fg_on && dz != nullptr && pred_next != &header->next &&
            epoch_table->can_prune_epoch(epoch, dz)) {
            coop_dead_seen_.fetch_add(1, std::memory_order_relaxed);
            epoch->next.set_mark(succ);                  // logical delete (idempotent; may fail if next moved)
            // Re-read epoch->next: once it is MARKED its pointer is frozen, so splice to that
            // re-read successor -- never the pre-mark `succ` (a concurrent unlinker may have
            // changed epoch->next between the load above and here, which would make set_mark fail
            // and the old `succ` stale; splicing it would drop a live node / resurrect a detached
            // one). If set_mark did not take, just advance without splicing.
            uintptr_t mw = epoch->next.load();
            if (MarkedPtr<epoch_node>::mark_of(mw)) {
                epoch_node *msucc = MarkedPtr<epoch_node>::ptr_of(mw);
                uintptr_t exp = MarkedPtr<epoch_node>::pack(epoch, false);
                pred_next->cas(exp, MarkedPtr<epoch_node>::pack(msucc, false));  // best-effort, no retry
                epoch = msucc;
            } else {
                epoch = MarkedPtr<epoch_node>::ptr_of(mw);   // next moved w/o mark -> advance, no splice
            }
            continue;                                    // pruned: skip scan, do NOT advance pred
        }
        // Kept epoch (the head, or a live/not-yet-dead epoch): scan its versions for visibility
        // if it is at or below our snapshot's epoch.
        if (epoch->epoch_num <= epoch_num) {
            for (undo_entry_node *undo_entry = epoch->first_entry;
                 undo_entry != nullptr;
                 undo_entry = undo_entry->next_entry.load()) {
                if (changes_visible(undo_entry->version_trx_id, rv_up_limit, trx_id, trx_id,
                                    active_trx_list)) {
                    if (!found || undo_entry->version_trx_id > best_trx_id) {
                        found = true;
                        best_trx_id = undo_entry->version_trx_id;
                        space_id = undo_entry->space_id;
                        page_id = undo_entry->page_id;
                        offset = undo_entry->offset;
                    }
                }
            }
        }
        pred_next = &epoch->next;   // kept -> advance pred over it
        epoch = succ;
    }

    return found;
}


// D-4 (4b-3): shadow consult. Picks the cached version a reader with this read view should see,
// proves it is the true visible boundary (full-PK identity + InnoDB changes_visible + contiguity to
// the live row), and reports the outcome. Read-only over the index (no unlink/retire); the EBR Guard
// spans the whole probe INCLUDING the image copy into the caller's buffer (so a concurrent evictor
// cannot free the node mid-copy -- review M2). It never mutates the structure and never returns a
// pointer into node memory.
mvcc::Accelerate_mvcc::ConsultOutcome
mvcc::Accelerate_mvcc::consult(uint64_t table_id, uint64_t pk_hash,
                               const unsigned char *pk, uint32_t pk_len,
                               uint64_t up_limit_id, uint64_t low_limit_id, uint64_t creator_trx_id,
                               const uint64_t *m_ids, std::size_t m_ids_n,
                               uint64_t live_top_writer,
                               unsigned char *out_img, uint32_t out_cap, uint32_t *out_len,
                               bool require_full_pk, uint64_t live_schema_epoch, uint32_t *out_extra,
                               bool enforce_gc_gen) {
    // D-4 4c-2: instant-DDL safety. live_schema_epoch = the READER's table current_row_version. If
    // that table has had any instant ADD/DROP COLUMN (>0), a cached raw-byte image may decode wrong
    // under the changed layout, so we do not trust the cache for this table at all -> MISS (the table
    // loses acceleration; instant DDL is rare). Conservative but correct: a post-DDL reader always
    // MISSes; a pre-DDL reader (era 0, the common case) is unaffected. ~0 is a test-only sentinel
    // (negative control) that disables the gate. The image was captured at the version's own era, but
    // since a reader reconstructs against the CURRENT layout, the reader's era is the safe signal.
    if (live_schema_epoch != ~uint64_t(0) && live_schema_epoch != 0)
        return ConsultOutcome::MISS_INELIGIBLE;
    kuku::item_type item = kuku::make_item(table_id, pk_hash);
    kuku::QueryResult query = kuku_table->query(item);
    if (!query.found()) return ConsultOutcome::MISS_ABSENT;

    uint64_t value = query.in_stash()
        ? kuku::get_value(kuku_table->stash(query.location()))
        : kuku::get_value(kuku_table->table(query.location()));
    auto *header = reinterpret_cast<interval_list_header *>(value);

    // Pin reclamation for this whole probe (the image copy below must happen under it -- M2).
    EpochReclaimer::Guard guard(epoch_table->reclaimer());

    // D-5 C3 (mode-1 2nd firewall): snapshot the per-key GC generation under the Guard. If a GC retire of
    // this key bumps it before we return HIT, the live chain (and any memoized cache we read) may have been
    // concurrently pruned mid-probe -> we re-check at the HIT site and MISS instead of serving. Covers BOTH
    // the fresh-build and the 5b-lite reuse paths uniformly (the snapshot precedes the consult_cache load
    // below; the reload precedes the HIT return). enforce_gc_gen is set only in mode-1 (serve-only), which
    // has no per-row walk-compare; mode-2/shadow leave it off (the walk-compare is their 2nd firewall).
    const uint64_t gen0 = header->gc_generation.load(std::memory_order_acquire);
    if (test_bump_gen_mid_consult_.load(std::memory_order_relaxed))
        header->gc_generation.fetch_add(1, std::memory_order_release);  // test seam: simulate a racing retire

    // D-5 (5-2 prep): GC-SAFE LINEAGE WALK via the LIVE chain. consult builds a writer->predecessor
    // link table by traversing ONLY the live links (header->next epochs + first_entry/next_entry) under
    // the Guard, then chases that table. This is the version that is SAFE once GC turns on: a node is
    // UNLINKED from the live chain before it is retired, and retire stamps a fresh epoch, so a Guard-
    // protected live traversal never reaches an unlinked/freed node. (The faster O(depth) chase over the
    // per-node roll_pred back-pointers -- commit f07a2f7, ~0.16s -- is NOT GC-safe: roll_pred keeps
    // pointing at a predecessor after GC frees it, so the chase can deref freed memory; a 16-agent
    // review confirmed the UAF. roll_pred / newest_node / node_count are still maintained by insert()
    // for the planned GC-safe fast consult, ⑤b, but MUST NOT be chased here while GC reclaims nodes.
    // See docs/open-items.md ⓠ1.) Cost: O(chain) per call (~0.4s on the deep held-snapshot reader vs
    // ~0.16s for the back-pointer chase); the BP-independent flatness / cliff removal is unchanged.
    const uint64_t head_writer = header->contiguous_head_writer.load(std::memory_order_acquire);
    const uint64_t node_count = header->node_count.load(std::memory_order_acquire);

    // D-5 ⑤b-lite: the writer -> predecessor link table is MEMOIZED on the header. Reuse the published
    // table iff the key's chain is unchanged since it was built -- built_node_count == node_count (no new
    // insert) AND it is still non-null (the GC retire path clears it before freeing any node of this key)
    // AND same PK + mode -- in which case the cached nodes are exactly the current live chain, every one
    // pinned by this consult's EBR Guard. Otherwise (re)build it the same way Pass 1 always did, publish it
    // (exchange) and EBR-retire the old. The cache holds the SAME table the live-chain walk builds, so the
    // four firewalls (full-PK filter, ambiguity, contiguity gate below, link-gap break) are inherited.
    std::unique_ptr<ConsultCache> scratch;   // owns a non-published (insert-raced) build until consult returns
    ConsultCache *c = header->consult_cache.load(std::memory_order_acquire);
    bool reuse = c != nullptr && c->built_node_count == node_count && c->require_full_pk == require_full_pk;
    if (reuse && require_full_pk) {
        reuse = (c->pk.size() == pk_len);
        for (uint32_t i = 0; reuse && i < pk_len; ++i)
            if (c->pk[i] != pk[i]) reuse = false;
    }
    const std::unordered_map<uint64_t, ConsultLink> *linkp;
    bool any_pk_match;
    bool any_visible = false;
    if (reuse) {
        linkp = &c->link;
        any_pk_match = c->any_pk_match;
    } else {
        // (Re)build the link table on the live chain (the predecessor a writer overwrote; version==writer
        // intermediates excluded; version MAY exceed writer under id-inversion so we test version!=writer;
        // >=2 distinct predecessors for one writer = ambiguous -> any chase through it MISSes).
        ConsultCache *nc = new ConsultCache();
        nc->built_node_count = node_count;
        nc->require_full_pk = require_full_pk;
        if (require_full_pk && pk != nullptr && pk_len > 0) nc->pk.assign(pk, pk + pk_len);
        bool apm = false;
        for (epoch_node *epoch = header->next.ptr(); epoch != nullptr; ) {
            uintptr_t w = epoch->next.load();
            epoch_node *succ = MarkedPtr<epoch_node>::ptr_of(w);
            if (!MarkedPtr<epoch_node>::mark_of(w)) {   // skip logically-deleted epochs
                for (undo_entry_node *u = epoch->first_entry; u != nullptr; u = u->next_entry.load()) {
                    if (require_full_pk) {              // full-PK identity (pk_hash is only a bucket hint)
                        if (u->pk_len == 0 || u->pk_len != pk_len) continue;
                        bool pk_eq = true;
                        for (uint32_t i = 0; i < pk_len; ++i)
                            if (u->pk[i] != pk[i]) { pk_eq = false; break; }
                        if (!pk_eq) continue;
                    }
                    apm = true;
                    if (changes_visible(u->version_trx_id, up_limit_id, low_limit_id, creator_trx_id,
                                        m_ids, m_ids_n))
                        any_visible = true;
                    if (u->version_trx_id != u->writer_trx_id) {
                        auto it = nc->link.find(u->writer_trx_id);
                        if (it == nc->link.end())
                            nc->link.emplace(u->writer_trx_id, ConsultLink{u->version_trx_id, u, false});
                        else if (it->second.version != u->version_trx_id)
                            it->second.ambiguous = true;
                    }
                }
            }
            epoch = succ;
        }
        nc->any_pk_match = apm;
        linkp = &nc->link;
        any_pk_match = apm;
        // Publish ONLY if no insert raced our build (node_count still == the value we keyed on): then the
        // table is current and a later static-chain consult (held snapshot) can reuse it. Under churn the
        // node_count advances during the build, so we do NOT publish -- a per-call publish would be
        // instantly stale and would flood EBR with cache retires, starving the GC. Not-published builds are
        // consult-local (freed at return via `scratch`); on publish the header owns the cache and the
        // superseded one is EBR-retired (a concurrent consult may still read it under its Guard).
        if (header->node_count.load(std::memory_order_acquire) == node_count) {
            ConsultCache *old = header->consult_cache.exchange(nc, std::memory_order_acq_rel);
            if (old != nullptr) epoch_table->reclaimer().retire([old] { delete old; });
        } else {
            scratch.reset(nc);
        }
    }

    if (!any_pk_match) return ConsultOutcome::MISS_ABSENT;
    // Contiguity precondition (complementary cross-generation suppressor): the gap-free run must reach the
    // live row's last writer, else we cannot trust the cache -> MISS.
    if (head_writer != live_top_writer) return ConsultOutcome::MISS_NONCONTIG;

    // Pass 2: chase the (cached or freshly-built) link table from the live top, exactly as vanilla follows
    // roll_ptr -- step to each writer's predecessor and return the first changes_visible. id-EQUALITY links
    // handle inversions; absent/ambiguous -> break. Bounded by the link count (acyclic chain).
    undo_entry_node *best = nullptr;
    uint64_t target = live_top_writer;
    for (size_t hop = 0; hop <= linkp->size(); ++hop) {
        auto it = linkp->find(target);
        if (it == linkp->end() || it->second.ambiguous) break;
        undo_entry_node *e = it->second.node;
        if (changes_visible(e->version_trx_id, up_limit_id, low_limit_id, creator_trx_id, m_ids, m_ids_n)) {
            best = e; break;
        }
        target = e->version_trx_id;
    }

    // best==nullptr: a safe MISS (full walk), never a guess. The build path computed any_visible (it scans
    // every entry) to split NOVISIBLE vs NONCONTIG; the reuse path skips that scan -> conservative NONCONTIG.
    if (best == nullptr)
        return (reuse || any_visible) ? ConsultOutcome::MISS_NONCONTIG : ConsultOutcome::MISS_NOVISIBLE;

    // D-5 C3 (mode-1 2nd firewall): if a GC retire of this key raced our probe (generation moved since the
    // Guard-open snapshot), the chain/cache we just walked may have been pruned mid-flight -> do NOT serve;
    // MISS to the InnoDB walk. Reuses MISS_NONCONTIG ("cache not trustworthy, fall back"), which the caller
    // already routes to the full walk exactly like a contiguity miss. Mode-2/shadow (enforce_gc_gen=false)
    // are unaffected -- their per-row walk-compare is the independent 2nd firewall.
    if (enforce_gc_gen && header->gc_generation.load(std::memory_order_acquire) != gen0)
        return ConsultOutcome::MISS_NONCONTIG;

    if (out_img != nullptr) {
        if (best->img_len == 0 || best->img_len > out_cap) return ConsultOutcome::MISS_INELIGIBLE;
        for (uint32_t i = 0; i < best->img_len; ++i) out_img[i] = best->img[i];  // copy UNDER the Guard
        if (out_len != nullptr) *out_len = best->img_len;
        if (out_extra != nullptr) *out_extra = best->extra_len;
    }
    return ConsultOutcome::HIT;
}


