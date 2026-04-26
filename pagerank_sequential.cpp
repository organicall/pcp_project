// pagerank_naive_csr.cpp
//
// Naive CSR-based sequential PageRank.
//
// This replicates the "Base Sequential" / PageRank Pipeline Benchmark that
// Zhou et al. (Paper 1) compare against and claim 12–19× speedup over.
//
// ── What makes this "naive" ──────────────────────────────────────────────────
//
//  1. PULL model over a TRANSPOSED (incoming-edge) CSR.
//     For each destination vertex v, walk all predecessors u (i.e. all vertices
//     that have an edge u → v) and accumulate pr[u] / outdeg[u].
//     Predecessors are NOT sorted by any locality-friendly ordering, so reads
//     of pr[u] are random across the entire pr[] array — guaranteed cache misses
//     for large graphs.
//
//  2. No partitioning, no destination sorting, no acc[] buffer.
//     Every iteration walks the full transposed edge list with random pr[] reads.
//     This is O(|E|) random DRAM reads per iteration.
//
//  3. Division inside the innermost loop.
//     pr[u] / outdeg[u] is recomputed for every edge, every iteration.
//     No precomputed contrib[] array.
//
//  4. new_pr[] double-buffered — the paper's benchmark style.
//     A second vector new_pr[] is written and then swapped with pr[].
//     This avoids the single-pass acc[]+reset trick in our optimised sequential,
//     at the cost of one extra O(n) write per iteration.
//
// ── Why this is slower than pagerank_sequential.cpp ─────────────────────────
//
//  pagerank_sequential.cpp uses:
//   • COO scatter (push): acc[e.dst] += contrib[e.src]  — sequential dst writes
//     when edges are sorted by dst (Theorem III.1 layout).
//   • A flat acc[] array zeroed in the same gather pass — no second buffer.
//   • Edges pre-sorted by destination — exploits hardware prefetcher on acc[].
//
//  This naive version has none of those. It matches what the paper calls
//  "Base Sequential" and is the correct apples-to-apples denominator for
//  the paper's claimed speedups.
//
// ── Convergence ──────────────────────────────────────────────────────────────
//  L∞ norm < 1e-10, max 200 iterations — identical to all other implementations
//  so iteration counts are directly comparable.
//  Dangling-node mass is redistributed uniformly (same formula as all others).
//
// ── Build ─────────────────────────────────────────────────────────────────────
//  g++ -O3 -march=native -std=c++17 -o pagerank_naive_csr pagerank_naive_csr.cpp
//
// ── Run ───────────────────────────────────────────────────────────────────────
//  ./pagerank_naive_csr <graph_file>

#include "graph_loader.h"
#include <cmath>
#include <iostream>
#include <vector>
#include <numeric>
#include <algorithm>

static constexpr double D         = 0.85;
static constexpr double THRESHOLD = 1e-10;
static constexpr int    MAX_ITER  = 200;

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <graph_file>\n";
        return 1;
    }

    // ── Load raw edge list ────────────────────────────────────────────────────
    int n = 0;
    auto edges = loadEdgeList(argv[1], n);

    std::cout << "Vertices: " << n << "  Edges: " << (long long)edges.size() << "\n";

    // ── Build outgoing-edge CSR (needed only for outdeg[]) ───────────────────
    // We use graph_loader's buildCSR which stores out-neighbours in row[]/col[].
    // outdeg[u] = number of outgoing edges from u — needed for the PR formula.
    // We keep out.outdeg[] and immediately release the col[] array to save RAM.
    CSR out = buildCSR(edges, n);
    out.col.clear();
    out.col.shrink_to_fit();
    out.row.clear();
    out.row.shrink_to_fit();

    // ── Build incoming-edge (transposed) CSR manually ────────────────────────
    // in_row[v]   = start index in in_col[] of v's predecessors
    // in_row[v+1] = one-past-end index
    // in_col[i]   = a predecessor u such that edge u → v exists
    //
    // Algorithm:
    //   Pass 1: count in-degree of every vertex.
    //   Pass 2: compute prefix-sum row offsets.
    //   Pass 3: scatter each edge (u → v) into in_col[] at position in_row[v].
    //
    // Crucially, in_col[] is filled in ARRIVAL ORDER — no sorting by any
    // locality criterion. This is the key source of random memory access:
    // pr[in_col[i]] jumps unpredictably across the pr[] array on every edge.

    std::vector<long long> in_row(n + 1, 0);

    // Pass 1: in-degree count stored temporarily in in_row[v+1]
    for (auto& e : edges)
        in_row[e.dst + 1]++;

    // Pass 2: prefix sum → row offsets
    for (int v = 0; v < n; v++)
        in_row[v + 1] += in_row[v];

    long long m = in_row[n];   // == total edge count

    // Pass 3: fill in_col[] — predecessors in unsorted (arrival) order.
    std::vector<int> in_col(m);
    {
        // pos[] is a mutable copy of in_row[] used as write cursors.
        // Declared in its own scope so it is freed immediately after use.
        std::vector<long long> pos(in_row.begin(), in_row.end());
        for (auto& e : edges)
            in_col[pos[e.dst]++] = e.src;
    }

    // Raw edge list no longer needed — free it before the iteration loop.
    edges.clear();
    edges.shrink_to_fit();

    std::cout << "Transposed CSR built (incoming-edge, unsorted predecessors)\n";

    // ── PageRank initialisation ───────────────────────────────────────────────
    std::vector<double> pr(n, 1.0 / n);
    std::vector<double> new_pr(n, 0.0);   // double-buffer: paper's benchmark style

    double teleport = (1.0 - D) / n;

    // ── Iteration loop ────────────────────────────────────────────────────────
    Timer t; t.start();
    int finalIter = 0;

    for (int iter = 0; iter < MAX_ITER; iter++) {
        finalIter = iter + 1;

        // ── Dangling-node mass ────────────────────────────────────────────────
        // Vertices with outdeg == 0 would leak probability mass. Redistribute
        // their total mass uniformly across all vertices (same formula as all
        // other implementations for a fair iteration-count comparison).
        double dangling = 0.0;
        for (int u = 0; u < n; u++)
            if (out.outdeg[u] == 0) dangling += pr[u];
        double dang_contrib = D * dangling / n;

        // ── Pull gather (naive) ───────────────────────────────────────────────
        // For each vertex v, sum contributions from all predecessors u.
        //
        // Memory access pattern — this is what the paper eliminates:
        //
        //   in_row[v], in_row[v+1]  — sequential, prefetcher-friendly (good)
        //   in_col[i]               — sequential scan (good)
        //   pr[u]                   — u = in_col[i], RANDOM jump → L3/DRAM miss
        //   out.outdeg[u]           — same random u, second miss per edge
        //
        // For a graph with |E| = 5 M edges and n = 916 K vertices (web-Google),
        // pr[] is ~7 MB — fits in L3 only marginally. With random access the
        // effective bandwidth is limited by TLB and cache-line utilisation, not
        // by raw DRAM bandwidth. Each 64-byte cache line fetched for pr[u] is
        // used for only 8 bytes (one double), giving ≤12.5% utilisation.
        //
        // The paper's partitioned + sorted layout converts these random reads
        // into sequential scans within each partition, recovering full cache-line
        // utilisation and 3× higher sustained bandwidth.

        for (int v = 0; v < n; v++) {
            double sum = 0.0;
            for (long long i = in_row[v]; i < in_row[v + 1]; i++) {
                int u   = in_col[i];
                int deg = out.outdeg[u];
                if (deg > 0)
                    sum += pr[u] / deg;   // division in innermost loop — no precomputed contrib[]
            }
            new_pr[v] = teleport + dang_contrib + D * sum;
        }

        // ── Convergence check ─────────────────────────────────────────────────
        double err = 0.0;
        for (int v = 0; v < n; v++) {
            double delta = std::fabs(new_pr[v] - pr[v]);
            if (delta > err) err = delta;
        }

        // O(1) pointer swap — no element copy.
        std::swap(pr, new_pr);

        if (err < THRESHOLD) break;
    }

    double elapsed = t.elapsedMs();

    // ── Normalize ─────────────────────────────────────────────────────────────
    double sum = std::accumulate(pr.begin(), pr.end(), 0.0);
    for (auto& x : pr) x /= sum;

    // ── Output: one line per vertex (required by verify_correctness.py) ───────
    for (int v = 0; v < n; v++)
        std::cout << "node " << v << "  PR=" << pr[v] << "\n";

    std::cout << "\n=== Naive CSR Sequential PageRank ===\n";
    std::cout << "Iterations: " << finalIter << "\n";
    std::cout << "Time: " << elapsed << " ms\n";

    return 0;
}
