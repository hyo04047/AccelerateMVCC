# AccelerateMVCC

> An in-memory acceleration index that speeds up MVCC version-chain lookups in disk-based DBMSs (InnoDB / MySQL).
> 디스크 기반 DBMS의 MVCC version-chain 탐색을 가속하는 인메모리 보조 인덱스.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![C++](https://img.shields.io/badge/C%2B%2B-17%2F20-00599C.svg)
![Build](https://img.shields.io/badge/build-CMake-064F8C.svg)
![Status](https://img.shields.io/badge/status-stages%20A--D%20done%2C%20Phase%203%20(paper)-blue.svg)

## Motivation

In HTAP workloads, a long-lived transaction forces InnoDB's MVCC to walk increasingly long version chains (undo-log chains), pulling many undo-log pages into the buffer pool. Profiling shows `row_search_mvcc` and related functions consuming **~45% of CPU** under such conditions — with I/O cost, buffer-pool pollution, and GC contention as the main symptoms.

**AccelerateMVCC** keeps only the *metadata* of each version (space / page / offset pointers) plus a small row image in a compact in-memory structure, so the correct visible version can be located quickly instead of traversing a long on-disk undo chain. The deadzone *in-middle* reclaim is derived from **vDriver (SIGMOD '20, "Long-lived Transactions Made Less Harmful")**; DIVA (VLDB '22) is the related interval-tree / chain-bound work, adapted here to an in-memory setting.

## Architecture

```mermaid
flowchart LR
  R["record (table_id, index)"] --> K["Cuckoo Hash · Kuku"]
  K -->|"value = header ptr"| H["interval_list_header"]
  H --> E["epoch_node chain"]
  E --> U["undo_entry<br/>(trx_id, space/page/offset)"]
  TM["Trx_manager<br/>active list"] --> DZ["deadzone"]
  E -. "insert" .-> ET["Epoch_table"]
  DZ --> ET
  ET -. "GC / pruning" .-> E
```

| Component | Role |
|---|---|
| Cuckoo Hash (Kuku) | record → version-chain header, O(1) |
| interval_list / epoch_node | epoch-bucketed chain of undo-entry metadata |
| Trx_manager | transaction ids + active-transaction snapshot (read view) |
| Epoch_table | epoch indexing + deadzone-based interval GC (Steam-style) |

## Status & Roadmap

Reviving a 2023 graduate project (solo, 2026).

- **A. Build revival** — compiles & runs on WSL2 / gcc / cmake *(done ✅)*
- **B. Prototype correctness** — GC, deadzone, lock-free hardening, correctness tests *(done ✅)*
- **C. Experiments** — HTAP / long-transaction benchmarks vs. baseline *(done ✅)*
- **D. MySQL/InnoDB integration** — populate → consult → authoritative serve → read-latency payoff;
  deadzone GC on; safe serve; workload breadth (composite/string PK, secondary index, savepoint, safe
  LOB exclusion, full-mysqld ASan) *(done ✅ — every served answer is byte-equal to the vanilla undo walk)*
- **Phase 3 (in progress)** — multi-run/error-bar data, InnoDB patch vendoring, the paper (Korean + English).

See [`docs/`](docs/) for the living status report, design docs, and the open-items tracker.

## Repository layout

```
include/         core in-memory structure (hash, interval list, trx manager, epoch table)
Kuku/            Microsoft Kuku (cuckoo hashing) dependency
main.cpp         demo entry point
google_test.cpp  benchmarks / tests (GoogleTest)
docs/            status report, findings, progress log
```

## Building

C++17/20 + CMake. Build instructions are being reworked as part of build revival — see [`docs/README.md`](docs/README.md).

## Background

Started as a 2023 university graduation project by **Taeseong Ha (하태성)**; revived in 2026 as a solo personal project to finish it.

## Acknowledgements

Uses [Microsoft Kuku](https://github.com/microsoft/Kuku) for cuckoo hashing (MIT).

## License

[MIT](LICENSE)
