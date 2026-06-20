// Licensed under the MIT license.
//
// Stage C HTAP/long-txn benchmark harness (port of the vDriver Figure-12 workload to our
// standalone in-memory accelerator -- design-gc.md Sec.10). Mixes:
//   * writers       : Zipfian-skewed updates (few hot records -> long chains),
//   * readers       : OLTP point-reads (same Zipf skew); their guarded searches perform the
//                     O(1) FG cooperative unlink of dead non-head epochs they pass,
//   * llt           : long-lived reader(s) holding ONE snapshot for the whole run while issuing
//                     many SHORT searches (per-traversal Guard each -> never starves reclaim).
//                     This is where the deadzone earns its keep: a tail-only GC stalls on the
//                     LLT-pinned global-min and the hot chain explodes, while in-middle deadzone
//                     pruning keeps it bounded. The LLT also VERIFIES visibility (its visible
//                     version must never change) -- correctness by visibility, not no-crash.
//   * sampler       : Guard-safe version-chain-length samples over time -> CSV -> CDF.
//
// IMPORTANT (methodology, learned in C-1a): hot-chain length is governed by BG-GC scheduling
// when the box is oversubscribed. Keep (writers+readers+llt+sampler+GC) <= cores, or chain
// length measures the scheduler, not the algorithm.
//
// Args are key=value (any order), e.g.:
//   stage_c_bench records=1000 writers=6 readers=6 llt=1 dur=60 zipf=1.2 \
//                 sample_ms=250 sample_keys=8 llt_key=0 csv=out.csv
//   records(1000) writers(6) readers(6) llt(0) dur(5.0) zipf(1.2)
//   sample_ms(250) sample_keys(16) llt_key(0) seed(200) csv(stage_c_samples.csv)

#include "include/accelerateMVCC.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <string>
#include <thread>
#include <vector>
#include <algorithm>

using mvcc::Accelerate_mvcc;
using mvcc::trx_t;
using steady = std::chrono::steady_clock;

// Zipfian sampler over ranks [0, N): P(rank=k) proportional to 1/(k+1)^s. Rank 0 is the
// hottest, mapped to record index 0, so the hot records are the low indices (easy to track).
// Precompute the CDF once (read-only, shared); each thread draws a uniform and binary-searches.
struct Zipf {
    std::vector<double> cdf;
    explicit Zipf(uint64_t n, double s) {
        cdf.resize(n);
        double acc = 0.0;
        for (uint64_t k = 0; k < n; ++k) {
            acc += 1.0 / std::pow(double(k + 1), s);
            cdf[k] = acc;
        }
        double total = acc;
        for (auto& c : cdf) c /= total;  // normalize to [0,1]
    }
    uint64_t sample(std::mt19937_64& rng) const {
        double u = std::uniform_real_distribution<double>(0.0, 1.0)(rng);
        auto it = std::lower_bound(cdf.begin(), cdf.end(), u);
        uint64_t idx = uint64_t(it - cdf.begin());
        return idx < cdf.size() ? idx : cdf.size() - 1;
    }
};

static size_t pct(const std::vector<size_t>& sorted, double p) {
    if (sorted.empty()) return 0;
    size_t i = size_t(p / 100.0 * double(sorted.size() - 1) + 0.5);
    return sorted[i];
}

// key=value argument lookup.
static std::string arg_str(int argc, char** argv, const char* key, const std::string& def) {
    std::string pfx = std::string(key) + "=";
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a.rfind(pfx, 0) == 0) return a.substr(pfx.size());
    }
    return def;
}
static double arg_num(int argc, char** argv, const char* key, double def) {
    std::string v = arg_str(argc, argv, key, "");
    return v.empty() ? def : std::strtod(v.c_str(), nullptr);
}

int main(int argc, char** argv) {
    uint64_t    record_count = (uint64_t)arg_num(argc, argv, "records", 1000);
    unsigned    n_writers    = (unsigned)arg_num(argc, argv, "writers", 6);
    unsigned    n_readers    = (unsigned)arg_num(argc, argv, "readers", 6);
    unsigned    n_llt        = (unsigned)arg_num(argc, argv, "llt", 0);
    double      duration_sec = arg_num(argc, argv, "dur", 5.0);
    double      zipf_s       = arg_num(argc, argv, "zipf", 1.2);
    long        sample_ms    = (long)arg_num(argc, argv, "sample_ms", 250);
    uint64_t    sample_keys  = (uint64_t)arg_num(argc, argv, "sample_keys", 16);
    uint64_t    llt_key      = (uint64_t)arg_num(argc, argv, "llt_key", 0);
    uint64_t    seed_n       = (uint64_t)arg_num(argc, argv, "seed", 200);
    bool        fg_on        = arg_num(argc, argv, "fg", 1) != 0.0;     // FG cooperative unlink
    bool        tail_only    = arg_num(argc, argv, "tail", 0) != 0.0;   // tail-only GC baseline
    long        warmup_ms    = (long)arg_num(argc, argv, "warmup_ms", 3000);  // excluded from %iles
    std::string csv_path     = arg_str(argc, argv, "csv", "stage_c_samples.csv");

    const uint64_t HOT_KEYS = std::min(sample_keys, record_count);
    const char* gc_label = tail_only ? "tail-only(InnoDB)" : "deadzone";

    std::printf("=== Stage C bench ===\n");
    std::printf("records=%llu writers=%u readers=%u llt=%u dur=%.1fs zipf=%.2f "
                "sample_ms=%ld sample_keys=%llu llt_key=%llu gc=%s fg=%d warmup_ms=%ld\n",
                (unsigned long long)record_count, n_writers, n_readers, n_llt, duration_sec,
                zipf_s, sample_ms, (unsigned long long)HOT_KEYS, (unsigned long long)llt_key,
                gc_label, fg_on ? 1 : 0, warmup_ms);

    Accelerate_mvcc mvcc(record_count);
    mvcc.set_gc_tail_only(tail_only);       // experiment toggles: set before any concurrency
    mvcc.set_fg_unlink_enabled(fg_on);
    Zipf zipf(record_count, zipf_s);

    // Seed the LLT's record with committed versions BEFORE any concurrency, so the LLT has a
    // stable visible version to pin (single-threaded -> no GC/reader races during seeding).
    for (uint64_t i = 0; i < seed_n; ++i) mvcc.insert_trx(llt_key);

    mvcc.start_background_gc();

    std::atomic<bool> stop{false};
    std::atomic<long long> writes{0};
    std::atomic<long long> reads{0};

    auto t0 = steady::now();
    auto ms_since = [&](steady::time_point t) {
        return std::chrono::duration_cast<std::chrono::milliseconds>(t - t0).count();
    };

    // Writers: time-bounded Zipfian updates (each insert_trx == one committed version).
    std::vector<std::thread> ws;
    for (unsigned w = 0; w < n_writers; ++w) {
        ws.emplace_back([&, w] {
            std::mt19937_64 rng(0x9E3779B97F4A7C15ULL ^ (uint64_t(w) * 2654435761ULL));
            while (!stop.load(std::memory_order_acquire)) {
                mvcc.insert_trx(zipf.sample(rng));
                writes.fetch_add(1, std::memory_order_relaxed);
            }
        });
    }

    // OLTP point-readers: same Zipf skew, so they traverse the HOT chains and drive FG unlink.
    std::vector<std::thread> rs;
    for (unsigned r = 0; r < n_readers; ++r) {
        rs.emplace_back([&, r] {
            std::mt19937_64 rng(0xD1B54A32D192ED03ULL ^ (uint64_t(r) * 40503ULL + 1));
            while (!stop.load(std::memory_order_acquire)) {
                trx_t* trx = mvcc.start_read_trx();
                uint64_t s = 0, p = 0, o = 0;
                (void) mvcc.search_operation(1, zipf.sample(rng), trx, s, p, o);
                mvcc.end_read_trx(trx);
                reads.fetch_add(1, std::memory_order_relaxed);
            }
        });
    }

    // Long-lived reader(s): hold ONE read-view (snapshot) for the whole run, issue many SHORT
    // searches (fresh per-traversal Guard each -> never starves reclaim, design-gc Sec.4-F).
    // Visibility oracle: the LLT's visible version of llt_key must NEVER change while GC reclaims
    // everything above it (tight-bound deadzone keeps exactly what the LLT still needs).
    std::vector<std::thread> llts;
    std::atomic<long long> llt_searches{0};
    std::atomic<long long> llt_inconsistencies{0};
    std::atomic<int> llt_found0_flag{-1};
    for (unsigned l = 0; l < n_llt; ++l) {
        llts.emplace_back([&] {
            trx_t* trx = mvcc.start_read_trx();           // snapshot pinned for the whole run
            uint64_t s0 = 0, p0 = 0, o0 = 0;
            bool f0 = mvcc.search_operation(1, llt_key, trx, s0, p0, o0);
            llt_found0_flag.store(f0 ? 1 : 0, std::memory_order_relaxed);
            while (!stop.load(std::memory_order_acquire)) {
                uint64_t s = 0, p = 0, o = 0;
                bool f = mvcc.search_operation(1, llt_key, trx, s, p, o);   // fresh short Guard
                if (f != f0 || (f && s != s0))
                    llt_inconsistencies.fetch_add(1, std::memory_order_relaxed);
                llt_searches.fetch_add(1, std::memory_order_relaxed);
            }
            mvcc.end_read_trx(trx);
        });
    }

    // Single sampler thread (only it writes `samples`). Guard-safe accessor -> safe to walk live
    // chains while GC + writers + readers mutate them.
    struct Sample { long t_ms; uint64_t key; size_t len; };
    std::vector<Sample> samples;
    samples.reserve(size_t(duration_sec * 1000.0 / double(sample_ms) + 1) * HOT_KEYS + 16);
    std::thread sampler([&] {
        while (!stop.load(std::memory_order_acquire)) {
            long t = (long)ms_since(steady::now());
            for (uint64_t k = 0; k < HOT_KEYS; ++k)
                samples.push_back({t, k, mvcc.chain_length_guarded(1, k)});
            std::this_thread::sleep_for(std::chrono::milliseconds(sample_ms));
        }
    });

    std::this_thread::sleep_for(std::chrono::duration<double>(duration_sec));
    stop.store(true, std::memory_order_release);
    for (auto& t : ws) t.join();
    for (auto& t : rs) t.join();
    for (auto& t : llts) t.join();
    sampler.join();
    auto elapsed = std::chrono::duration<double>(steady::now() - t0).count();
    mvcc.stop_background_gc();

    // Write CSV (t_ms,key,chain_len) for the CDF.
    if (FILE* f = std::fopen(csv_path.c_str(), "w")) {
        std::fprintf(f, "t_ms,key,chain_len\n");
        for (const auto& s : samples)
            std::fprintf(f, "%ld,%llu,%zu\n", s.t_ms, (unsigned long long)s.key, s.len);
        std::fclose(f);
    } else {
        std::printf("WARN: could not open csv_path=%s\n", csv_path.c_str());
    }

    // Summary: throughput + steady-state chain-length distribution (warm-up excluded so the GC's
    // warm-up early-returns don't inflate the tail) + per-hot-key final length. The CSV keeps ALL
    // samples (with t_ms) so the full time series / CDF can still be rebuilt.
    std::vector<size_t> lens;
    lens.reserve(samples.size());
    for (const auto& s : samples) if (s.t_ms >= warmup_ms) lens.push_back(s.len);
    std::sort(lens.begin(), lens.end());

    std::printf("\n--- results ---\n");
    std::printf("elapsed=%.2fs writes=%lld throughput=%.0f updates/s\n",
                elapsed, writes.load(), double(writes.load()) / elapsed);
    std::printf("reads=%lld read_throughput=%.0f reads/s\n",
                reads.load(), double(reads.load()) / elapsed);
    if (n_llt > 0) {
        std::printf("LLT: found0=%d searches=%lld inconsistencies=%lld  (visibility %s)\n",
                    llt_found0_flag.load(), llt_searches.load(), llt_inconsistencies.load(),
                    llt_inconsistencies.load() == 0 ? "OK" : "BROKEN");
    }
    std::printf("samples=%zu (sampler ran %zu sweeps)\n",
                samples.size(), HOT_KEYS ? samples.size() / HOT_KEYS : 0);
    std::printf("chain_len (steady, n=%zu)  p50=%zu  p90=%zu  p99=%zu  max=%zu\n",
                lens.size(), pct(lens, 50), pct(lens, 90), pct(lens, 99),
                lens.empty() ? 0 : lens.back());

    std::printf("final chain_length per hot key: ");
    for (uint64_t k = 0; k < HOT_KEYS; ++k)
        std::printf("%llu:%zu ", (unsigned long long)k, mvcc.chain_length(1, k));
    std::printf("\n");

    std::printf("conservation detached=%llu retired=%llu  long_live_size=%zu\n",
                (unsigned long long)mvcc.epochs_detached(),
                (unsigned long long)mvcc.epochs_retired(),
                mvcc.long_live_size());
    std::printf("csv=%s\n", csv_path.c_str());
    std::printf("=== done ===\n");
    return 0;
}
