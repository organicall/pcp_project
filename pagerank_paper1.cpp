// pagerank_paper1.cpp
//
// parallel pagerank based on zhou et al. (ieee 2017).
//
// the core idea: divide vertices into cache-sized partitions so each thread's
// working set fits in l2. sort each partition's edge list by destination so
// scatter writes are sequential within a partition — this turns O(|E|) random
// dram writes into O(k^2) random writes where k << |E|. (theorem iii.1)
//
// accumulation uses per-destination-partition message lists (msgList[q]) instead
// of a single global atomic array. gather reads each msgList[q] sequentially —
// one partition per thread with no sharing. scatter still needs atomics because
// multiple source partitions can write to the same msgList[q] concurrently.

#include "graph_loader.h"
#include <omp.h>
#include <cmath>
#include <iostream>
#include <vector>
#include <algorithm>
#include <numeric>

static constexpr double D         = 0.85;
static constexpr double THRESHOLD = 1e-10;
static constexpr int    MAX_ITER  = 200;

struct PartEdge { int src, dst; };

struct Partition {
    int vStart, vEnd;
    std::vector<PartEdge> edgeList; // sorted by dst once before the iteration loop
};

int main(int argc, char* argv[]) {
    if (argc < 2) {
        std::cerr << "Usage: " << argv[0] << " <graph_file>\n";
        return 1;
    }

    int nthreads = omp_get_max_threads();

    int n = 0;
    auto edges = loadEdgeList(argv[1], n);
    COO g = buildCOO(edges, n);
    edges.clear(); edges.shrink_to_fit();

    std::cout << "Vertices: " << g.n << "  Edges: " << g.m << "\n";

    // choose partition size so vertex data fits in l2 per core (section iii-c)
    int m = computePartitionSize(nthreads);
    int k = (n + m - 1) / m;
    std::cout << "Partition size m=" << m << "  partitions k=" << k << "\n";

    // each partition owns vertices [p*m, (p+1)*m) and all edges whose src falls there
    std::vector<Partition> parts(k);
    for (int p = 0; p < k; p++) {
        parts[p].vStart = p * m;
        parts[p].vEnd   = std::min((p + 1) * m, n);
    }
    for (auto& e : g.edges)
        parts[e.src / m].edgeList.push_back({e.src, e.dst});
    g.edges.clear(); g.edges.shrink_to_fit();

    // sort each partition's edges by destination — done once, before any iterations.
    // this is what makes scatter writes sequential within a partition (theorem iii.1).
    #pragma omp parallel for schedule(dynamic, 1)
    for (int p = 0; p < k; p++) {
        std::sort(parts[p].edgeList.begin(), parts[p].edgeList.end(),
                  [](const PartEdge& a, const PartEdge& b){
                      return a.dst < b.dst; });
    }

    // msgList[q] is a dense accumulator for destination partition q.
    // gather reads it sequentially (one thread per partition, no atomics needed).
    // scatter writes to it with atomics because multiple source partitions
    // can target the same destination partition concurrently.
    std::vector<std::vector<double>> msgList(k);
    for (int q = 0; q < k; q++)
        msgList[q].assign(parts[q].vEnd - parts[q].vStart, 0.0);

    std::vector<double> pr(n, 1.0 / n);
    double teleport = (1.0 - D) / n;

    Timer t; t.start();
    int finalIter = 0;

    for (int iter = 0; iter < MAX_ITER; iter++) {
        finalIter = iter + 1;

        // sum up pr values of dangling nodes (no outgoing edges) once per iteration,
        // then spread their mass uniformly across all vertices during gather
        double dangling = 0.0;
        #pragma omp parallel for reduction(+:dangling) schedule(static)
        for (int u = 0; u < n; u++)
            if (g.outdeg[u] == 0) dangling += pr[u];
        double dang_contrib = D * dangling / n;

        // scatter: push contributions from each source partition into msgList[q].
        // edges are sorted by dst so writes to msgList[q][lv] step forward in memory.
        // the atomic is unavoidable here — two partitions p1, p2 can have edges to the
        // same destination partition q and run on different threads simultaneously.
        #pragma omp parallel for schedule(dynamic, std::max(1, k / nthreads)) \
                num_threads(nthreads)
        for (int p = 0; p < k; p++) {
            for (auto& e : parts[p].edgeList) {
                int deg = g.outdeg[e.src];
                if (deg == 0) continue;
                double val = D * pr[e.src] / deg;
                int q  = e.dst / m;
                int lv = e.dst - parts[q].vStart;
                #pragma omp atomic
                msgList[q][lv] += val;
            }
        }

        // gather: each thread owns one destination partition — no sharing, no atomics.
        // reads msgList[q] sequentially, computes new pr, checks convergence, resets the slot.
        double err = 0.0;
        #pragma omp parallel for reduction(max:err) \
                schedule(dynamic, std::max(1, k / nthreads)) num_threads(nthreads)
        for (int q = 0; q < k; q++) {
            int qStart = parts[q].vStart;
            int qEnd   = parts[q].vEnd;
            for (int v = qStart; v < qEnd; v++) {
                int lv         = v - qStart;
                double newpr   = teleport + dang_contrib + msgList[q][lv];
                double delta   = std::fabs(newpr - pr[v]);
                if (delta > err) err = delta;
                pr[v]          = newpr;
                msgList[q][lv] = 0.0; // reset here avoids a separate zeroing pass
            }
        }

        if (err < THRESHOLD) break;
    }

    double elapsed = t.elapsedMs();

    // rough bandwidth estimate: edge reads + pr reads/writes per iteration
    double edgeBytes = (double)g.m * 2 * sizeof(int);
    double prBytes   = 2.0 * n * sizeof(double);
    double totalGB   = (edgeBytes + prBytes) * finalIter / 1e9;
    double bwGBs     = totalGB / (elapsed / 1000.0);

    // rescale so values sum to exactly 1.0
    double sum = std::accumulate(pr.begin(), pr.end(), 0.0);
    for (auto& x : pr) x /= sum;

    for (int v = 0; v < n; v++)
        std::cout << "node " << v << "  PR=" << pr[v] << "\n";

    std::cout << "\n=== Paper1 Parallel PageRank ===\n";
    std::cout << "Iterations: " << finalIter << "\n";
    std::cout << "Time: " << elapsed << " ms\n";
    std::cout << "Est. memory bandwidth: " << bwGBs << " GB/s\n";

    return 0;
}
