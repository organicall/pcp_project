// pagerank_naive_csr.cpp
//
// naive sequential pagerank using the pull model over a transposed csr.
// this replicates the "base sequential" benchmark that zhou et al. compare against.
//
// what makes it naive:
//   - predecessors stored in arrival order (no cache-friendly sorting), so reads of
//     pr[u] jump randomly across memory — guaranteed cache misses on large graphs
//   - division pr[u]/outdeg[u] is recomputed on every edge, every iteration
//   - uses a second buffer new_pr[] instead of an in-place acc[]+reset trick
//
// damping, dangling-node handling, and convergence threshold are identical to all
// other implementations so iteration counts are directly comparable.

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

    // load the raw edge list
    int n = 0;
    auto edges = loadEdgeList(argv[1], n);

    std::cout << "Vertices: " << n << "  Edges: " << (long long)edges.size() << "\n";

    // build an outgoing csr just to get outdeg[] — we don't need the adjacency
    // lists themselves since the pull loop reads predecessors, not successors
    CSR out = buildCSR(edges, n);
    out.col.clear();
    out.col.shrink_to_fit();
    out.row.clear();
    out.row.shrink_to_fit();

    // build the transposed (incoming-edge) csr manually.
    // in_row[v]..in_row[v+1]-1 give the predecessors of v.
    //
    // edges are placed in arrival order — no sorting by any locality criterion.
    // this is the root cause of the random access pattern: when we read pr[in_col[i]],
    // the index jumps unpredictably across the pr[] array on every edge.

    std::vector<long long> in_row(n + 1, 0);

    // pass 1: count in-degrees, storing them shifted by one slot for the prefix sum
    for (auto& e : edges)
        in_row[e.dst + 1]++;

    // pass 2: turn the counts into row offsets via prefix sum
    for (int v = 0; v < n; v++)
        in_row[v + 1] += in_row[v];

    long long m = in_row[n];

    // pass 3: scatter each edge into in_col[] at the right row, using pos[] as cursors
    std::vector<int> in_col(m);
    {
        std::vector<long long> pos(in_row.begin(), in_row.end());
        for (auto& e : edges)
            in_col[pos[e.dst]++] = e.src;
    }

    // raw edges no longer needed — free memory before the iteration loop
    edges.clear();
    edges.shrink_to_fit();

    std::cout << "Transposed CSR built (incoming-edge, unsorted predecessors)\n";

    // initialise all pr values uniformly; new_pr is the double-buffer
    std::vector<double> pr(n, 1.0 / n);
    std::vector<double> new_pr(n, 0.0);

    double teleport = (1.0 - D) / n;

    Timer t; t.start();
    int finalIter = 0;

    for (int iter = 0; iter < MAX_ITER; iter++) {
        finalIter = iter + 1;

        // vertices with no outgoing edges would leak probability mass, so we
        // collect their total pr and redistribute it uniformly across all vertices
        double dangling = 0.0;
        for (int u = 0; u < n; u++)
            if (out.outdeg[u] == 0) dangling += pr[u];
        double dang_contrib = D * dangling / n;

        // pull: for each vertex v, walk all predecessors u and accumulate their
        // contributions. reading pr[u] here causes random cache misses because
        // in_col[] was built in arrival order with no spatial locality.
        for (int v = 0; v < n; v++) {
            double sum = 0.0;
            for (long long i = in_row[v]; i < in_row[v + 1]; i++) {
                int u   = in_col[i];
                int deg = out.outdeg[u];
                if (deg > 0)
                    sum += pr[u] / deg; // division on every edge — no precomputed contrib[]
            }
            new_pr[v] = teleport + dang_contrib + D * sum;
        }

        // l-inf convergence: max absolute change across all vertices
        double err = 0.0;
        for (int v = 0; v < n; v++) {
            double delta = std::fabs(new_pr[v] - pr[v]);
            if (delta > err) err = delta;
        }

        std::swap(pr, new_pr); // pointer swap — no element copies

        if (err < THRESHOLD) break;
    }

    double elapsed = t.elapsedMs();

    // rescale so values sum to exactly 1.0
    double sum = std::accumulate(pr.begin(), pr.end(), 0.0);
    for (auto& x : pr) x /= sum;

    for (int v = 0; v < n; v++)
        std::cout << "node " << v << "  PR=" << pr[v] << "\n";

    std::cout << "\n=== Naive CSR Sequential PageRank ===\n";
    std::cout << "Iterations: " << finalIter << "\n";
    std::cout << "Time: " << elapsed << " ms\n";

    return 0;
}
