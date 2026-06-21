// Licensed under the MIT license.
#pragma once


#include <cstdint>
#include <atomic>
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

    struct UndoLogEntryNode {
        uint64_t trxId;

        uint64_t spaceId;
        uint64_t pageId;
        uint64_t offset;

        std::atomic<UndoLogEntryNode *> nextUndoLogEntry = nullptr;

        UndoLogEntryNode(uint64_t trxId, uint64_t spaceId, uint64_t pageId, uint64_t offset);
    };


    struct EpochNode {
        uint64_t epochNumber;

        std::atomic<UndoLogEntryNode *> startUndoLogEntry = nullptr;
        std::atomic<UndoLogEntryNode *> endUndoLogEntry = nullptr;
        std::atomic<EpochNode *> nextEpoch = nullptr;

        explicit EpochNode(uint64_t epochNumber);
    };

    struct undo_entry_node {
        uint64_t trx_id;
        uint64_t space_id;
        uint64_t page_id;
        uint64_t offset;
        std::atomic<undo_entry_node *> next_entry;
        // D-4: cached full-row image of the version this entry locates. Set ONCE at insert (the
        // single drainer is the sole mutator), heap-owned, and freed in the dtor -- which runs
        // when the owning epoch_node is EBR-retired (delete e in epoch_table.h::retire_epoch_once),
        // so the image shares the node's lifetime exactly (no leak, no UAF). img_len==0 means no
        // image (row over cap / ineligible) -> consult must full-walk that version.
        uint32_t img_len = 0;
        unsigned char *img = nullptr;

        undo_entry_node(uint64_t trx_id, uint64_t space_id, uint64_t page_id, uint64_t offset)
                : trx_id(trx_id), space_id(space_id), page_id(page_id), offset(offset)
        {
            next_entry.store(nullptr);
        }
        ~undo_entry_node() { delete[] img; }  // nullptr-safe; frees the image with the node
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

    void update_epoch_node(epoch_node *epoch, uint64_t epoch_num, uint64_t trx_id, undo_entry_node *undo_entry,
                           epoch_node *next);

    struct interval_list_header {
        uint64_t next_epoch_num;
        MarkedPtr<epoch_node> next;   // forward chain head (never marked: the header is not a deletable node)

        interval_list_header()
                : next_epoch_num(0), next()
        {
        }
    };


} // namespace mvcc
#endif /* node_h */