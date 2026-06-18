// Licensed under the MIT license.
#pragma once


#include <cstdint>
#include <atomic>
#include "marked_ptr.h"

#ifndef node_h
#define node_h
namespace mvcc {

    struct interval_list_header;   // forward decl: epoch_node carries a back-pointer to it

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

        undo_entry_node(uint64_t trx_id, uint64_t space_id, uint64_t page_id, uint64_t offset)
                : trx_id(trx_id), space_id(space_id), page_id(page_id), offset(offset) 
        {
            next_entry.store(nullptr);
        }
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