// pagerank_paper1_improved_3_atomic.cpp
//
// identical to pagerank_paper1_improved_3.cpp in every way except the accumulator
// is forced to the atomic global acc[] path regardless of memory footprint.
//
// used in test 3 to isolate the cost of atomics vs thread-local arrays.
// the adaptive version in improved_3 would choose local arrays at low thread counts
// (where they fit in l3), so without this forced variant you can't see the raw
// atomic cost at those same thread counts.

#include "graph_loader.h"
#include <omp.h>
#include <cmath>
#include <iostream>
#include <iomanip>
#include <vector>
#include <algorithm>
#include <numeric>

static constexpr double D         = 0.85;
static constexpr double THRESHOLD = 1e-10;
static constexpr int    MAX_ITER  = 200;
static constexpr int    K_MULT    = 4;
static constexpr long long L3_BYTES = 20LL * 1024 * 1024;

struct PartEdge { int src, dst; };

struct Partition {
    int vStart, vEnd;
    std::vector<PartEdge> edgeList;
};

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <graph_file>\n";
        return 1;
    }

    int nthreads = omp_get_max_threads();
    std::cout << "Threads: " << nthreads << "\n";

    int n = 0;
    auto edges = loadEdgeList(argv[1], n);
    COO g = buildCOO(edges, n);
    edges.clear(); edges.shrink_to_fit();

    std::cout << "Vertices: " << g.n << "  Edges: " << g.m << "\n";

    // dbg vertex reordering: renumber vertices by in-degree descending so hub nodes
    // cluster at the front of all arrays and receive spatially coherent scatter writes
    Timer tDBG; tDBG.start();
    std::vector<int> indeg(n, 0);
    for (auto& e : g.edges)
        indeg[e.dst]++;

    std::vector<int> perm(n);
    std::iota(perm.begin(), perm.end(), 0);
    std::sort(perm.begin(), perm.end(),
              [&](int a, int b){ return indeg[a] > indeg[b]; });

    std::vector<int> inv(n);
    for (int i = 0; i < n; i++) inv[perm[i]] = i;

    for (auto& e : g.edges) {
        e.src = inv[e.src];
        e.dst = inv[e.dst];
    }

    std::vector<int> newOutdeg(n, 0);
    for (auto& e : g.edges) newOutdeg[e.src]++;
    g.outdeg = std::move(newOutdeg);

    inv.clear();   inv.shrink_to_fit();
    indeg.clear(); indeg.shrink_to_fit();
    double msDBG = tDBG.elapsedMs();

    std::cout << "DBG reordering applied (in-degree descending)\n";

    // edge-balanced partitioning: partition boundaries chosen by edge count so each
    // thread gets roughly equal scatter work (fixes hub-node load imbalance)
    Timer tPart; tPart.start();
    std::vector<long long> cumEdges(n + 1, 0);
    for (int v = 0; v < n; v++)
        cumEdges[v + 1] = cumEdges[v] + g.outdeg[v];

    int m_cache = computePartitionSize(nthreads);
    double avg_deg = (n > 0) ? (double)g.m / n : 1.0;
    long long max_edges_per_part = (long long)(avg_deg * m_cache * 2);
    if (max_edges_per_part < 1) max_edges_per_part = 1;
    int k = (int)((g.m + max_edges_per_part - 1) / max_edges_per_part);
    k = std::max(k, nthreads * K_MULT);
    k = std::min(k, n);
    if (k < 1) k = 1;

    long long target = (g.m + k - 1) / k;

    std::vector<int> vBounds(k + 1);
    vBounds[0] = 0;
    for (int p = 1; p < k; p++) {
        long long want = (long long)p * target;
        int lo = vBounds[p - 1], hi = n;
        while (lo < hi) {
            int mid = lo + (hi - lo) / 2;
            if (cumEdges[mid] < want) lo = mid + 1;
            else hi = mid;
        }
        vBounds[p] = std::max(lo, vBounds[p - 1] + 1);
        if (vBounds[p] > n) vBounds[p] = n;
    }
    vBounds[k] = n;

    std::vector<Partition> parts(k);
    for (int p = 0; p < k; p++) {
        parts[p].vStart = vBounds[p];
        parts[p].vEnd   = vBounds[p + 1];
    }

    std::vector<int> vertexToPart(n);
    for (int p = 0; p < k; p++)
        for (int v = parts[p].vStart; v < parts[p].vEnd; v++)
            vertexToPart[v] = p;

    for (auto& e : g.edges)
        parts[vertexToPart[e.src]].edgeList.push_back({e.src, e.dst});
    g.edges.clear(); g.edges.shrink_to_fit();

    {
        int orig_k = (n + m_cache - 1) / m_cache;
        std::vector<long long> origEdges(orig_k, 0);
        for (int v = 0; v < n; v++) origEdges[v / m_cache] += g.outdeg[v];
        long long orig_min = *std::min_element(origEdges.begin(), origEdges.end());
        long long orig_max = *std::max_element(origEdges.begin(), origEdges.end());

        long long new_min = (long long)parts[0].edgeList.size();
        long long new_max = new_min;
        for (int p = 1; p < k; p++) {
            long long sz = (long long)parts[p].edgeList.size();
            new_min = std::min(new_min, sz);
            new_max = std::max(new_max, sz);
        }

        std::cout << "Partitioning comparison:\n";
        std::cout << "  Original (vertex-balanced): k=" << orig_k
                  << "  min_edges=" << orig_min
                  << "  max_edges=" << orig_max
                  << "  imbalance=" << std::fixed << std::setprecision(2)
                  << (orig_min > 0 ? (double)orig_max / orig_min : 0.0) << "x\n";
        std::cout << "  Improved (edge-balanced):   k=" << k
                  << "  min_edges=" << new_min
                  << "  max_edges=" << new_max
                  << "  imbalance=" << std::fixed << std::setprecision(2)
                  << (new_min > 0 ? (double)new_max / new_min : 0.0) << "x\n";
        std::cout << std::defaultfloat << std::setprecision(6);
    }

    // sort edge lists by dst (once before the loop) for sequential scatter writes
    #pragma omp parallel for schedule(dynamic, 1)
    for (int p = 0; p < k; p++) {
        std::sort(parts[p].edgeList.begin(), parts[p].edgeList.end(),
                  [](const PartEdge& a, const PartEdge& b){ return a.dst < b.dst; });
    }

    // longest-job-first: heavy partitions go first so threads stay busy at the tail
    std::sort(parts.begin(), parts.end(),
              [](const Partition& a, const Partition& b){
                  return a.edgeList.size() > b.edgeList.size();
              });
    double msPart = tPart.elapsedMs();

    std::cout << std::fixed << std::setprecision(2);
    std::cout << "Preprocess-DBG: "       << msDBG             << " ms\n";
    std::cout << "Preprocess-Partition: " << msPart            << " ms\n";
    std::cout << "Preprocess-Total: "     << (msDBG + msPart)  << " ms\n";
    std::cout << std::defaultfloat << std::setprecision(6);

    std::vector<double> pr(n, 1.0 / n);

    // forced atomic: always use the global acc[] path, never the thread-local arrays.
    // localAccBytes is kept for logging consistency with the adaptive variant.
    long long localAccBytes = (long long)nthreads * n * sizeof(double);
    bool useLocalAcc = false;

    std::vector<double> localAcc; // unused — forced atomic mode
    std::vector<double> acc;

    acc.assign(n, 0.0);
    std::cout << "Accumulator: forced-atomic (mode 3 always)\n";

    std::vector<double> contrib(n, 0.0);

    double teleport = (1.0 - D) / n;

    Timer t; t.start();
    int finalIter = 0;
    double totalScatterMs = 0.0;

    for (int iter = 0; iter < MAX_ITER; iter++) {
        finalIter = iter + 1;

        double dangling = 0.0;
        #pragma omp parallel for reduction(+:dangling) schedule(static)
        for (int u = 0; u < n; u++)
            if (g.outdeg[u] == 0) dangling += pr[u];
        double dang_contrib = D * dangling / n;

        // precompute contribution per source vertex to avoid per-edge division
        #pragma omp parallel for schedule(static)
        for (int u = 0; u < n; u++) {
            int deg = g.outdeg[u];
            contrib[u] = (deg > 0) ? D * pr[u] / deg : 0.0;
        }

        Timer tScatter; tScatter.start();
        if (useLocalAcc) {
            // this branch is never taken in the forced-atomic variant
            #pragma omp parallel for schedule(guided) num_threads(nthreads)
            for (int p = 0; p < k; p++) {
                int tid = omp_get_thread_num();
                double* myAcc = localAcc.data() + (long long)tid * n;
                for (auto& e : parts[p].edgeList)
                    myAcc[e.dst] += contrib[e.src];
            }
        } else {
            #pragma omp parallel for schedule(guided) num_threads(nthreads)
            for (int p = 0; p < k; p++) {
                for (auto& e : parts[p].edgeList) {
                    #pragma omp atomic
                    acc[e.dst] += contrib[e.src];
                }
            }
        }
        totalScatterMs += tScatter.elapsedMs();

        double err = 0.0;
        if (useLocalAcc) {
            #pragma omp parallel for reduction(+:err) schedule(static) num_threads(nthreads)
            for (int v = 0; v < n; v++) {
                double total = 0.0;
                for (int t2 = 0; t2 < nthreads; t2++) {
                    long long idx = (long long)t2 * n + v;
                    total += localAcc[idx];
                    localAcc[idx] = 0.0;
                }
                double newpr = teleport + dang_contrib + total;
                err += std::fabs(newpr - pr[v]);
                pr[v] = newpr;
            }
        } else {
            #pragma omp parallel for reduction(+:err) schedule(static) num_threads(nthreads)
            for (int v = 0; v < n; v++) {
                double newpr = teleport + dang_contrib + acc[v];
                err += std::fabs(newpr - pr[v]);
                pr[v]  = newpr;
                acc[v] = 0.0;
            }
        }

        if (err < THRESHOLD) break;
    }

    double elapsed = t.elapsedMs();

    double edgeBytes = (double)g.m * 2 * sizeof(int);
    double prBytes   = 2.0 * n * sizeof(double);
    double totalGB   = (edgeBytes + prBytes) * finalIter / 1e9;
    double bwGBs     = totalGB / (elapsed / 1000.0);

    double sum = std::accumulate(pr.begin(), pr.end(), 0.0);
    for (auto& x : pr) x /= sum;

    // undo the dbg renumbering before printing
    std::vector<double> original_pr(n);
    for (int i = 0; i < n; i++)
        original_pr[perm[i]] = pr[i];

    for (int v = 0; v < n; v++)
        std::cout << "node " << v << "  PR=" << original_pr[v] << "\n";

    std::cout << "\n=== Paper1 Improved v3 (+ DBG reordering) ===\n";
    std::cout << "Threads: " << nthreads << "\n";
    std::cout << "Iterations: " << finalIter << "\n";
    std::cout << "Time: " << elapsed << " ms\n";
    std::cout << std::fixed << std::setprecision(2);
    std::cout << "Avg-Scatter-Per-Iter: " << (totalScatterMs / finalIter) << " ms\n";
    std::cout << std::defaultfloat << std::setprecision(6);
    std::cout << "Est. memory bandwidth: " << bwGBs << " GB/s\n";

    return 0;
}
