// Licensed under the MIT license.

#include "accelerateMVCC.h"

mvcc::Accelerate_mvcc::Accelerate_mvcc(uint64_t record_count) {
    constexpr uint64_t max_value = ~0ULL;
    // if you are willing to test large number of elements, you have to change table size : (1 << 10) + 1 to (1 << 16)
    this->kuku_table = new kuku::KukuTable((1 << 10), (1 << 10), 2, kuku::make_random_item(), 100,
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
                                   uint64_t trx_id, uint64_t space_id, uint64_t page_id, uint64_t offset) {
    kuku::item_type item = kuku::make_item(table_id, index);

    auto *undo_entry = new undo_entry_node(trx_id, space_id, page_id, offset);
    uint64_t epoch_num = get_epoch_num(trx_id);

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
        if (header->next.load() == nullptr) {
            auto* epoch = new epoch_node();
            update_epoch_node(epoch, epoch_num, trx_id, undo_entry, nullptr);

            header->next_epoch_num = epoch_num;
            header->next.store(epoch);

            epoch_table->insert(epoch);
        }
        else if (header->next_epoch_num < epoch_num) {
            // create new epoch and insert it to header

            // concurrency control btw inserting and gc operation
            auto *epoch = new epoch_node();
            header->next.load()->prev.store(epoch);
            try {
                update_epoch_node(epoch, epoch_num, trx_id, undo_entry, header->next.load());
            }
            catch (std::exception& e) {
                update_epoch_node(epoch, epoch_num, trx_id, undo_entry, nullptr);
            }

            header->next_epoch_num = epoch_num;
            header->next.store(epoch);

            epoch_table->insert(epoch);
        } else {
            // insert undo log entry to existing epoch
            epoch_node *epoch = header->next.load();
            epoch->count++;
            undo_entry_node *last_entry = epoch->last_entry.load();
            if (trx_id < epoch->min_trx_id) {
                epoch->min_trx_id = trx_id;
            }
            if (trx_id > epoch->max_trx_id) {
                epoch->max_trx_id = trx_id;
            }
            last_entry->next_entry.store(undo_entry);
            epoch->last_entry.store(undo_entry);
        }
    } else {
        auto *epoch = new epoch_node(epoch_num, trx_id, undo_entry, nullptr);
        auto *header = new interval_list_header();
        header->next_epoch_num = epoch_num;
        header->next.store(epoch);
        auto value = reinterpret_cast<std::uint64_t>(header);

        kuku::set_value(value, item);

        epoch_table->insert(epoch);
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
      Visible == undo_entry->trx_id < our trx_id AND not in our active_trx_list.
      Among visible versions we want the greatest trx_id (latest committed). The
      chain is newest-epoch-first but oldest-entry-first within an epoch, so we
      scan all candidates and keep the maximum rather than returning the first. */
    bool found = false;
    uint64_t best_trx_id = 0;
    epoch_node *epoch = header->next.load();

    while (epoch != nullptr) {
        // skip epochs entirely newer than ours
        if (epoch->epoch_num > epoch_num) {
            epoch = epoch->next.load();
            continue;
        }
        for (undo_entry_node *undo_entry = epoch->first_entry;
             undo_entry != nullptr;
             undo_entry = undo_entry->next_entry.load()) {
            if (undo_entry->trx_id < trx_id &&
                std::find(active_trx_list.begin(), active_trx_list.end(), undo_entry->trx_id) ==
                    active_trx_list.end()) {
                if (!found || undo_entry->trx_id > best_trx_id) {
                    found = true;
                    best_trx_id = undo_entry->trx_id;
                    space_id = undo_entry->space_id;
                    page_id = undo_entry->page_id;
                    offset = undo_entry->offset;
                }
            }
        }
        epoch = epoch->next.load();
    }

    return found;
}


