// pagerank_paper1_improved_3.cpp
//
// improved partitioned parallel pagerank — seven optimisations layered on top of
// zhou et al. (paper 1):
//
//   1. edge-balanced partitioning: partition boundaries chosen so each partition
//      owns roughly equal numbers of edges, not equal numbers of vertices.
//      fixes the load imbalance caused by high-degree hub nodes.
//
//   2. hybrid accumulator: uses thread-local flat arrays (no atomics) when the
//      total footprint fits in l3, falls back to a global atomic acc[] otherwise.
//      this scales correctly at both low and high thread counts.
//
//   3. longest-job-first ordering: partitions sorted by edge count descending
//      before the loop. heavy partitions start first so threads stay busy longer
//      at the tail of each scatter phase.
//
//   4. precomputed contributions: contrib[u] = D*pr[u]/outdeg[u] computed once
//      per iteration, eliminating per-edge division in the scatter inner loop.
//
//   5. scaled partition count: k >= nthreads * K_MULT to give guided scheduling
//      enough chunks to steal at high thread counts.
//
//   6. guided scheduling in scatter: chunks start large and shrink, reducing
//      scheduler overhead while keeping load balanced.
//
//   7. dbg vertex reordering: vertices renumbered by in-degree descending so hub
//      nodes cluster at the front of all arrays. thread-local accumulator slices
//      receive spatially coherent writes, keeping hot entries in l2.
//      (faldu et al., "a closer look at lightweight graph reordering", iiswc 2019)

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
static constexpr int    K_MULT    = 4;   // minimum partitions per thread — empirically chosen

// if nthreads * n * 8 bytes exceeds this, the local-acc footprint won't fit in l3
// and we fall back to atomic global acc[] to avoid thrashing
static constexpr long long L3_BYTES = 20LL * 1024 * 1024; // 20 MB

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

    // read this at runtime — hardcoding caused out-of-bounds writes in localAcc
    // when the benchmark ran with T=16 or T=32
    int nthreads = omp_get_max_threads();
    std::cout << "Threads: " << nthreads << "\n";

    int n = 0;
    auto edges = loadEdgeList(argv[1], n);
    COO g = buildCOO(edges, n);
    edges.clear(); edges.shrink_to_fit();

    std::cout << "Vertices: " << g.n << "  Edges: " << g.m << "\n";

    // dbg: degree-based grouping vertex reordering
    //
    // hub nodes (high in-degree) receive the most scatter writes. if their entries
    // in the thread-local accumulator land at scattered offsets, every write is a
    // cache miss. by renumbering vertices so the highest in-degree nodes get ids 0,1,2,...
    // their accumulator slots end up at the front of localAcc[], which stays warm
    // in l2 across the entire scatter phase.
    //
    // cost: one O(n log n) sort before any iterations. no change to the pr math.

    Timer tDBG; tDBG.start();

    // count in-degree for each vertex
    std::vector<int> indeg(n, 0);
    for (auto& e : g.edges)
        indeg[e.dst]++;

    // build perm[] such that perm[new_id] = old_id, sorted by in-degree descending
    std::vector<int> perm(n);
    std::iota(perm.begin(), perm.end(), 0);
    std::sort(perm.begin(), perm.end(),
              [&](int a, int b){ return indeg[a] > indeg[b]; });

    // build inv[] such that inv[old_id] = new_id
    std::vector<int> inv(n);
    for (int i = 0; i < n; i++) inv[perm[i]] = i;

    // apply the renumbering to every edge
    for (auto& e : g.edges) {
        e.src = inv[e.src];
        e.dst = inv[e.dst];
    }

    // rebuild outdeg[] under the new vertex numbering
    std::vector<int> newOutdeg(n, 0);
    for (auto& e : g.edges) newOutdeg[e.src]++;
    g.outdeg = std::move(newOutdeg);

    // perm[] is kept — we need it at the end to map pr[new_id] back to original ids
    inv.clear();   inv.shrink_to_fit();
    indeg.clear(); indeg.shrink_to_fit();
    double msDBG = tDBG.elapsedMs();

    std::cout << "DBG reordering applied (in-degree descending)\n";

    // edge-balanced partitioning
    //
    // the original paper assigns a fixed vertex count m to each partition. on power-law
    // graphs this is terrible: a partition containing one high-degree hub can have 100x
    // more edges than a partition of low-degree nodes, so one thread does 100x more work.
    //
    // fix: find boundaries so each partition owns roughly g.m / k edges. we do this
    // with a prefix sum over outdeg[] and a binary search per boundary.

    Timer tPart; tPart.start();

    // cumEdges[v] = total number of edges from vertices 0 through v-1
    std::vector<long long> cumEdges(n + 1, 0);
    for (int v = 0; v < n; v++)
        cumEdges[v + 1] = cumEdges[v] + g.outdeg[v];

    // decide how many partitions k to use.
    // start from the cache-derived vertex limit to preserve the l2 fit property,
    // then ensure at least nthreads*K_MULT partitions for guided scheduling granularity.
    int m_cache = computePartitionSize(nthreads);
    double avg_deg = (n > 0) ? (double)g.m / n : 1.0;
    long long max_edges_per_part = (long long)(avg_deg * m_cache * 2); // 2x headroom
    if (max_edges_per_part < 1) max_edges_per_part = 1;
    int k = (int)((g.m + max_edges_per_part - 1) / max_edges_per_part);
    k = std::max(k, nthreads * K_MULT);
    k = std::min(k, n); // can't have more partitions than vertices
    if (k < 1) k = 1;

    long long target = (g.m + k - 1) / k; // edges per partition

    // find vertex boundaries: binary search on cumEdges[] for each partition start
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
        vBounds[p] = std::max(lo, vBounds[p - 1] + 1); // no empty partitions
        if (vBounds[p] > n) vBounds[p] = n;
    }
    vBounds[k] = n;

    std::vector<Partition> parts(k);
    for (int p = 0; p < k; p++) {
        parts[p].vStart = vBounds[p];
        parts[p].vEnd   = vBounds[p + 1];
    }

    // build a vertex-to-partition lookup so edge assignment is O(1) per edge
    std::vector<int> vertexToPart(n);
    for (int p = 0; p < k; p++)
        for (int v = parts[p].vStart; v < parts[p].vEnd; v++)
            vertexToPart[v] = p;

    for (auto& e : g.edges)
        parts[vertexToPart[e.src]].edgeList.push_back({e.src, e.dst});
    g.edges.clear(); g.edges.shrink_to_fit();

    // print how much better the load balance is vs the original fixed-vertex scheme
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

    // sort each partition's edge list by destination — done once, before any iterations.
    // sequential writes within a partition exploit the hardware prefetcher on acc[].
    #pragma omp parallel for schedule(dynamic, 1)
    for (int p = 0; p < k; p++) {
        std::sort(parts[p].edgeList.begin(), parts[p].edgeList.end(),
                  [](const PartEdge& a, const PartEdge& b){ return a.dst < b.dst; });
    }

    // sort partitions by edge count descending — longest job first.
    // dynamic/guided scheduling picks the heaviest remaining partition next,
    // so all threads stay busy until the very end of scatter rather than some
    // finishing early while others crawl through large partitions.
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

    // choose accumulator mode based on how much memory the local arrays would need.
    // thread-local arrays avoid atomics entirely — fast when they fit in l3.
    // when nthreads is large the footprint exceeds l3 and every scatter write becomes
    // an l3 miss, making atomics on the smaller shared array the better choice.
    long long localAccBytes = (long long)nthreads * n * sizeof(double);
    bool useLocalAcc = (localAccBytes <= L3_BYTES);

    std::vector<double> localAcc; // used when useLocalAcc == true
    std::vector<double> acc;      // used when useLocalAcc == false (atomic path)

    if (useLocalAcc) {
        localAcc.assign((long long)nthreads * n, 0.0);
        std::cout << "Accumulator: thread-local flat ("
                  << localAccBytes / (1024*1024) << " MB)\n";
    } else {
        acc.assign(n, 0.0);
        std::cout << "Accumulator: atomic global (footprint "
                  << localAccBytes / (1024*1024) << " MB > L3 "
                  << L3_BYTES / (1024*1024) << " MB)\n";
    }

    // contrib[u] is recomputed once per iteration and reused for every edge leaving u.
    // this moves the division and the branch on outdeg out of the scatter inner loop.
    std::vector<double> contrib(n, 0.0);

    double teleport = (1.0 - D) / n;

    Timer t; t.start();
    int finalIter = 0;
    double totalScatterMs = 0.0;

    for (int iter = 0; iter < MAX_ITER; iter++) {
        finalIter = iter + 1;

        // collect dangling mass once per iteration and spread it uniformly in gather
        double dangling = 0.0;
        #pragma omp parallel for reduction(+:dangling) schedule(static)
        for (int u = 0; u < n; u++)
            if (g.outdeg[u] == 0) dangling += pr[u];
        double dang_contrib = D * dangling / n;

        // precompute contrib[u] = D * pr[u] / outdeg[u] so the scatter inner loop
        // only does a load and an add — no division, no branch per edge
        #pragma omp parallel for schedule(static)
        for (int u = 0; u < n; u++) {
            int deg = g.outdeg[u];
            contrib[u] = (deg > 0) ? D * pr[u] / deg : 0.0;
        }

        // scatter: push precomputed contributions into the accumulator.
        // local-acc mode: each thread writes to its own slice — no synchronisation.
        // atomic mode: multiple threads write to the same shared array — omp atomic
        //              serialises conflicting writes without a full lock.
        Timer tScatter; tScatter.start();
        if (useLocalAcc) {
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

        // gather: sum up the accumulator, compute new pr, check convergence, zero the slot.
        // for local-acc mode, each vertex v must read nthreads slots and sum them up —
        // the cross-thread read is unavoidable but the pattern is stride-n, which hardware
        // prefetchers handle well once the access stream is established.
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

    // undo the dbg renumbering: pr[new_id] holds the rank of the vertex
    // originally called old_id. perm[new_id] = old_id, so we write back accordingly.
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
