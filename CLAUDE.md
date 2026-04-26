# PageRank Implementation Guide

This document covers three progressively optimized implementations of the PageRank algorithm, grounded in two research papers:

- **Paper 1**: Zhou et al., *"Design and Implementation of Parallel PageRank on Multicore Platforms"* (IEEE 2017)
- **Paper 2**: Garg & Kothapalli, *"STIC-D: Algorithmic Techniques for Efficient Parallel PageRank Computation on Real-World Graphs"* (ICDCN 2016)

Each implementation builds on the previous. The goal is to measure the contribution of each layer of optimization independently, then together.

---

## Project Structure

```
pagerank/
├── CLAUDE.md
├── src/
│   ├── graph_loader.h             # Graph loading, CSR/COO builders, Timer, partition-size helper
│   ├── pagerank_sequential.cpp    # Implementation 1
│   ├── pagerank_paper1.cpp        # Implementation 2
│   └── pagerank_combined.cpp      # Implementation 3
├── test/
│   ├── run_tests.sh               # Test runner
│   ├── verify_correctness.py      # Numerical correctness checker
│   └── graphs/
│       ├── tiny_5node.txt
│       ├── chain_10node.txt
│       ├── scc_test.txt
│       ├── dangling_nodes.txt
│       └── identical_nodes.txt
├── data/
│   └── README.md
└── results/
    └── benchmark_results.csv
```

---

## graph_loader.h — Shared Header

All three `.cpp` files `#include "graph_loader.h"`. This header must provide:

```cpp
#pragma once
#include <vector>
#include <string>
#include <algorithm>
#include <chrono>
#include <fstream>
#include <sstream>
#include <iostream>
#include <cassert>

// ── Edge and graph types ──────────────────────────────────────────────────────

struct RawEdge { int src, dst; };

// COO — used by Paper 1 and combined
struct COO {
    int n;               // number of vertices
    long long m;         // number of edges
    std::vector<RawEdge> edges;
    std::vector<int> outdeg;  // out-degree[v]
};

// CSR — used by the sequential baseline
struct CSR {
    int n;
    long long m;
    std::vector<long long> row;   // row_ptr, size n+1, indexes into col[]
    std::vector<int> col;         // destination indices (i.e. transposed: col[row[v]..row[v+1]) = in-neighbors of v)
    std::vector<int> outdeg;
};

// ── Loaders ───────────────────────────────────────────────────────────────────

// Read edge list from file. Format:
//   optional comment lines starting with '#'
//   then one "src dst" pair per line (0-indexed)
// n is set to max(vertex id) + 1.
inline std::vector<RawEdge> loadEdgeList(const std::string& path, int& n) {
    std::ifstream f(path);
    if (!f) { std::cerr << "Cannot open " << path << "\n"; exit(1); }
    std::vector<RawEdge> edges;
    std::string line;
    n = 0;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line);
        int u, v;
        if (!(ss >> u >> v)) continue;
        edges.push_back({u, v});
        n = std::max(n, std::max(u, v) + 1);
    }
    return edges;
}

// Build COO from raw edges (self-loops removed).
inline COO buildCOO(const std::vector<RawEdge>& edges, int n) {
    COO g;
    g.n = n;
    g.outdeg.assign(n, 0);
    for (auto& e : edges) {
        if (e.src == e.dst) continue;   // drop self-loops
        g.edges.push_back(e);
        g.outdeg[e.src]++;
    }
    g.m = (long long)g.edges.size();
    return g;
}

// Build CSR (transposed: row[v]..row[v+1] gives in-neighbors of v).
// Used by the sequential baseline for the gather-style loop.
inline CSR buildCSR(const std::vector<RawEdge>& edges, int n) {
    CSR g;
    g.n = n;
    g.outdeg.assign(n, 0);
    // Count in-degrees for the transposed row_ptr
    std::vector<int> indeg(n, 0);
    std::vector<RawEdge> valid;
    for (auto& e : edges) {
        if (e.src == e.dst) continue;
        valid.push_back(e);
        g.outdeg[e.src]++;
        indeg[e.dst]++;
    }
    g.m = (long long)valid.size();
    // Build row_ptr for transposed graph
    g.row.assign(n + 1, 0);
    for (int i = 0; i < n; i++) g.row[i + 1] = g.row[i] + indeg[i];
    g.col.resize(g.m);
    std::vector<long long> pos(g.row.begin(), g.row.end());
    for (auto& e : valid) g.col[pos[e.dst]++] = e.src;
    return g;
}

// ── Partition-size helper ────────────────────────────────────────────────────

// Returns number of vertices that fit in L2/nthreads.
// 256 KB L2 per core; each vertex needs 8 bytes (double PR value + double prev).
inline int computePartitionSize(int nthreads) {
    const int L2_BYTES = 256 * 1024;
    int m = (L2_BYTES / nthreads) / (int)sizeof(double) / 2;
    // Round down to a power of 2 for cheap modulo
    int p = 1;
    while (p * 2 <= m) p *= 2;
    return p;
}

// ── Timer ─────────────────────────────────────────────────────────────────────

struct Timer {
    std::chrono::high_resolution_clock::time_point t0;
    void start() { t0 = std::chrono::high_resolution_clock::now(); }
    double elapsedMs() const {
        return std::chrono::duration<double, std::milli>(
            std::chrono::high_resolution_clock::now() - t0).count();
    }
};
```

---

## Implementation 1: Sequential Baseline

**File:** `src/pagerank_sequential.cpp`

Standard iterative PageRank on a transposed CSR. Strictly single-threaded. Serves as the correctness reference for everything else.

### Formula

```
PR(v) = (1 - d) / n  +  d * sum_{u -> v} PR(u) / outdeg(u)
```

Damping `d = 0.85`. Convergence measured as **L∞ norm** (max absolute change over all vertices).

### Pseudocode

```
pr[v]   = 1.0 / n   for all v
prev[v] = 1.0 / n   for all v

for iter = 1..max_iter:
    dangling_sum = sum of pr[u] for all u where outdeg[u] == 0
    dang_contrib = d * dangling_sum / n

    for each vertex v:
        sum = 0
        for each in-neighbor u of v (via transposed CSR):
            sum += prev[u] / outdeg[u]
        pr[v] = (1 - d) / n  +  dang_contrib  +  d * sum

    error = max_v |pr[v] - prev[v]|
    swap(pr, prev)
    if error < threshold: break

normalize so sum(pr) = 1.0
```

### Implementation Notes

- Store the transposed graph so in-neighbor iteration is sequential in memory.
- Compute `dangling_sum` once per iteration before the vertex loop.
- No OpenMP. No STIC-D preprocessing.
- `threshold = 1e-10` (L∞).
- `max_iter = 200`.

---

## Implementation 2: Paper 1 — Partitioned Parallel Scatter-Gather

**File:** `src/pagerank_paper1.cpp`

Implements Zhou et al. verbatim. The graph is partitioned so each vertex set fits in one core's L2. Edge lists are sorted by destination to turn random DRAM writes into sequential writes (Theorem III.1).

### Key Optimizations

1. **Vertex partitioning** — divide vertices into chunks of `m` (computed from L2 size / threads). Each partition owns its vertex set, edge list, and a dense accumulation array.
2. **Edge list sorted by dst** — within each partition, edges are sorted by `dst`. Scatter writes to the accumulation array are therefore sequential per partition, giving O(k²) random writes total instead of O(|E|).
3. **OpenMP dynamic scheduling** — partitions distributed across threads with `schedule(dynamic, max(1, k/nthreads))`.
4. **Atomic accumulation** — use `#pragma omp atomic` on the global `acc[dst] += val` write to avoid race conditions between threads writing to the same destination.

### Pseudocode

```
pr[v]  = 1.0 / n   for all v
acc[v] = 0.0       for all v

m = computePartitionSize(nthreads)
k = ceil(n / m)

// Build partitions: each partition owns edges whose src is in its range.
for each edge (u, v) in G:
    p = u / m
    parts[p].edgeList.push_back({u, v})

// Sort each partition's edge list by dst (once, before the iteration loop).
for p in 0..k-1:
    sort parts[p].edgeList by dst

teleport = (1 - d) / n

for iter = 1..max_iter:
    dangling = sum of pr[u] for u with outdeg[u] == 0
    dang_contrib = d * dangling / n

    // --- SCATTER ---
    #pragma omp parallel for schedule(dynamic, max(1, k/nthreads))
    for p = 0..k-1:
        for each edge (u, v) in parts[p].edgeList:
            if outdeg[u] == 0: continue
            val = d * pr[u] / outdeg[u]
            #pragma omp atomic
            acc[v] += val

    // --- GATHER ---
    err = 0.0
    #pragma omp parallel for reduction(+:err) schedule(static)
    for v = 0..n-1:
        newpr = teleport + dang_contrib + acc[v]
        err += |newpr - pr[v]|
        pr[v]  = newpr
        acc[v] = 0.0    // reset accumulator

    if err < threshold: break

normalize so sum(pr) = 1.0
```

### Implementation Notes

- The partition sort is done **once before the iteration loop**. Do not re-sort each iteration.
- `acc[]` is a global dense array of size `n`. Resetting it in the gather phase (one sequential pass) is cheaper than zeroing between partitions.
- Report preprocessing time (load + sort) separately from iteration time.
- `threshold = 1e-10` (L1 norm of change, not L∞ — to match the combined implementation's convergence check).

---

## Implementation 3: Combined — STIC-D + Paper 1

**File:** `src/pagerank_combined.cpp`

Paper 2's SCC-based graph decomposition is applied first (once, sequentially). Paper 1's scatter-gather engine then runs on each SCC in topological order. Paper 2 eliminates repeated processing of cross-SCC edges; Paper 1 keeps cache behavior efficient within each SCC.

---

### Correctness Invariants (read these before coding anything)

These are the constraints that the previous version violated, causing wrong PageRank values on web-Google and other graphs:

1. **`crossContrib[v]` is a permanent additive offset, not an initial value that decays.**
   Every scatter iteration, `next[v]` must be initialized to `(1-d)/n + crossContrib[v]`, not just `(1-d)/n`. The cross-SCC contribution is constant for the lifetime of an SCC's computation (it comes from already-converged upstream SCCs) and must be included in every new iteration's starting value.

2. **`outdeg[u]` must count ALL outgoing edges of `u`, including cross-SCC edges.**
   PageRank is a probability distribution. The formula `PR(u) / outdeg(u)` divides by the total out-degree of `u`, not just its internal-SCC out-degree. Using only the internal out-degree inflates contributions and breaks stochasticity. When scattering within an SCC, use the global `outdeg[u]`.

3. **Dangling nodes within an SCC must be handled.**
   A node can be dangling globally (no outgoing edges at all) or have all its outgoing edges be cross-SCC edges — making it effectively dangling *within* the SCC. In both cases, its PageRank mass must be redistributed within the SCC. Compute `scc_dangling = sum of pr[u]` for all u in the SCC where `outdeg[u] == 0 OR all edges of u leave the SCC`. Add `d * scc_dangling / n` (using global `n`) to every vertex in the SCC each iteration.

4. **The singleton fast path must apply the full PageRank formula, not just `crossContrib`.**
   A singleton SCC with no self-loop converges in one step. Its PR is:
   `pr[v] = (1 - d) / n + d * crossContrib[v] + d * scc_dangling / n`
   where `scc_dangling` covers dangling mass from other singleton SCCs at the same level. In practice for singletons, treat them as a one-iteration gather: apply the same formula as regular SCCs use in their gather phase.

5. **`crossContrib[w]` must use the GLOBAL `outdeg[u]`.**
   When propagating a converged SCC's contribution to downstream SCCs:
   `crossContrib[w] += D * pr[u] / outdeg[u]`
   where `outdeg[u]` is the global out-degree (total edges leaving `u`, not just cross-SCC edges).

6. **Topological processing must be strict: process level L fully before level L+1.**
   Parallelism is allowed within a level (independent SCCs), but a barrier must separate levels. Within a level, `crossContrib[]` writes from parallel SCCs target disjoint downstream vertex sets (they live in later levels, not the current one), so no synchronization is needed for those writes.

7. **Identical-node optimization: skip both non-representative sources AND destinations in scatter.**
   Currently the code skips `e.src` if `rep[e.src] != e.src`. It must also skip `e.dst` if `rep[e.dst] != e.dst` (because those writes go to a slot that will be overwritten by the gather phase anyway).

8. **Chain edges must be bucketed by SCC during preprocessing.**
   The current code scans ALL chain edges for every SCC, which is O(K * |chainEdges|). Instead, during preprocessing, partition chain edges by their SCC id so each SCC only processes its own chain edges.

9. **`localIdx[]` must be a precomputed global array, not a per-SCC `unordered_map`.**
   Building a hash map per SCC is a major hot-path allocation. Build a single `localIdx[v]` array once during preprocessing.

10. **Convergence threshold must be SCC-local.**
    The global threshold `1e-10` is an L1 sum. For an SCC with `sz` nodes, use `threshold * sz` as the per-SCC convergence criterion to avoid over-iterating tiny SCCs and under-iterating large ones.

---

### Phase 0: STIC-D Preprocessing

#### Step 0a — Kosaraju SCC + Topological Levels

Run Kosaraju's algorithm (two-pass iterative DFS — no recursion, to avoid stack overflow on large graphs).

**Pass 1:** DFS on the forward graph; push vertices onto a stack in finish order.

**Pass 2:** Pop vertices from the stack; DFS on the reverse graph; each DFS tree is one SCC.

After Kosaraju:
- `scc_id[v]` = which SCC vertex `v` belongs to
- `scc_members[i]` = list of vertices in SCC `i`
- Build the SCC DAG (condensed graph): for each edge `(u, v)` where `scc_id[u] != scc_id[v]`, add DAG edge `scc_id[u] -> scc_id[v]`.
- Compute topological levels via Kahn's BFS: level 0 = SCCs with in-degree 0 in the DAG; level L = SCCs all of whose DAG predecessors are at level < L.
- Precompute `localIdx[v]` = the index of `v` within its SCC's member list (used in scatter).

#### Step 0b — Identical Node Merging (optional, threshold-gated)

Two nodes are identical if they have exactly the same set of in-neighbors.

For efficiency, only check nodes with in-degree 1 or 2 (Paper 2 Section 3.6).

Group by sorted in-neighbor set. Within each group, pick the lowest-index node as representative. Set `rep[u] = representative` for all others.

If `count(rep[u] != u) / n < 0.07`, disable this optimization (skip it entirely for this graph).

#### Step 0c — Chain Node Compression (optional, threshold-gated)

A chain interior node has in-degree == 1 AND out-degree == 1.

For each maximal chain `u0 -> u1 -> ... -> uk`:
- Interior nodes `u1` through `u_{k-1}` are removed.
- A compressed edge `(u0, uk)` with chain length `k` is recorded.
- Contribution formula (Lemma 1): `D^(k+1) * PR(u0) / outdeg(u0) + D*(1 - D^k) / n`
- Store `chainLength[u0->uk] = k` for use in scatter.

If `count(chain interior nodes) / n < 0.15`, disable this optimization.

Pre-bucket all chain edges by `scc_id` of their source. Each SCC then only scans its own chain edges.

#### Step 0d — Edge Classification per SCC

For each SCC `i`, build two structures:
- `intraEdges[i]`: edges `(u, v)` where `scc_id[u] == scc_id[v] == i`
  - If chain optimization is on, exclude edges where source or destination is a chain interior node.
  - Sort by destination (Paper 1 optimization).
- `crossEdges_out[i]`: edges `(u, v)` where `scc_id[u] == i` and `scc_id[v] != i`.
  - Used after convergence to populate `crossContrib[]` for downstream SCCs.

---

### Phase 1: Main Loop — Topological Level Processing

```
pr[v]            = 1.0 / n   for all v
crossContrib[v]  = 0.0       for all v

for each level L = 0, 1, 2, ..., maxLevel:

    // SCCs at the same level are independent — process in parallel.
    // Each SCC's crossContrib writes target later levels, so no races.
    #pragma omp parallel for schedule(dynamic, 1)
    for each SCC i in sccsAtLevel[L]:
        processSCC(i)

// BARRIER between levels is enforced by the omp parallel for completing
// before the next iteration of the outer for loop.
```

### processSCC(i) — detailed

```
members = sccMembers[i]
sz      = members.size()

// ── Singleton fast path ────────────────────────────────────────────────
if sz == 1:
    v = members[0]
    // Check for self-loop (makes it non-trivial)
    if v has no self-loop:
        // Dangling correction: if v has no outgoing edges, its mass stays
        scc_dang = (outdeg[v] == 0) ? pr[v] : 0.0
        // One-shot gather
        pr[v] = (1 - D) / n  +  D * crossContrib[v]  +  D * scc_dang / n
        // Propagate to downstream SCCs
        propagateCross(i)
        return

// ── Multi-node SCC ─────────────────────────────────────────────────────
// Partition intraEdges[i] by source-vertex partition index (Paper 1).
// Use global localIdx[] array, not a per-SCC hash map.
// Partition size = computePartitionSize(nthreads).

lm = computePartitionSize(nthreads)
lk = ceil(sz / lm)

// Build per-partition edge lists (sorted by dst) — reuse intraEdges[i]
// which are already sorted globally; re-sort by local index if needed.

teleport = (1 - D) / n

for iter = 1..MAX_ITER:

    // Compute dangling mass within this SCC.
    // A node u is "locally dangling" if outdeg[u] == 0 OR all edges of u
    // are cross-SCC edges (i.e., intraEdges[i] has no edge with src == u).
    scc_dang = 0.0
    for u in members:
        if dead[u]: continue
        if u contributes nothing to intraEdges[i]:  // no internal out-edges
            scc_dang += pr[u]
    scc_dang_contrib = D * scc_dang / n   // uses GLOBAL n

    // Reset acc[] for vertices in this SCC.
    for v in members:
        acc[v] = 0.0

    // --- SCATTER (Paper 1 style within this SCC) ---
    for p = 0..lk-1 in parallel:
        for each edge (u, v) in localParts[p]:
            if dead[u]: continue
            if useIdentical and rep[u] != u: continue   // skip non-rep sources
            if useIdentical and rep[v] != v: continue   // skip non-rep destinations
            val = D * pr[u] / outdeg[u]                 // GLOBAL outdeg
            #pragma omp atomic
            acc[v] += val

    // Chain edge contributions (only for this SCC's chain edges)
    if useChain:
        for each compressed edge (u, uk, k) in chainEdgesForSCC[i]:
            if dead[u]: continue
            dk1 = D^(k+1)
            contrib = dk1 * pr[u] / outdeg[u]  +  D * (1 - D^k) / n
            #pragma omp atomic
            acc[uk] += contrib

    // --- GATHER ---
    err = 0.0
    for v in members in parallel:
        if dead[v]: continue
        if useIdentical and rep[v] != v:
            // Copy representative's value; do not gather independently
            pr[v] = pr[rep[v]]
            continue
        newpr = teleport  +  scc_dang_contrib  +  crossContrib[v]  +  acc[v]
        err += |newpr - pr[v]|
        pr[v] = newpr

    if err < threshold * sz: break   // SCC-local threshold

    // Dead-node check every TNUM iterations
    if iter % TNUM == 0:
        for v in members:
            if |pr[v] - prSnap[v]| < threshold2: dead[v] = true
            else: prSnap[v] = pr[v]

// Propagate converged PR to downstream SCCs (once, after convergence)
propagateCross(i)
```

### propagateCross(i) — detailed

```
for u in sccMembers[i]:
    deg = outdeg[u]       // GLOBAL out-degree
    if deg == 0: continue
    for each cross-SCC edge (u, w) in crossEdges_out[i]:
        crossContrib[w] += D * pr[u] / deg
```

**No synchronization needed**: cross-edge targets are in later levels. Within a level, distinct SCCs have disjoint downstream targets (a node can only be in one SCC).

---

### Phase 2: Post-Processing

Recover PageRank for nodes that were compressed out.

```
// Recover chain interior nodes
for each chain u0 -> u1 -> ... -> uk:
    for i = 1 to k-1:
        di = D^i
        pr[u_i] = (1 - di) / n  +  di * pr[u0] / outdeg[u0]

// Recover identical-node group members
for each v where rep[v] != v:
    pr[v] = pr[rep[v]]
```

---

## Compilation and Build

The three `.cpp` files compile independently. All include `graph_loader.h` which is a header-only utility.

```bash
# Using g++ directly (no CMake needed)
g++ -O3 -fopenmp -std=c++17 -o pagerank_seq      src/pagerank_sequential.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_p1       src/pagerank_paper1.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_combined src/pagerank_combined.cpp

# Alternatively with CMake
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

Each binary takes a single argument: the graph file path.

```bash
./pagerank_seq      data/web-Google.txt
./pagerank_p1       data/web-Google.txt
./pagerank_combined data/web-Google.txt
```

---

## Graph File Format

```
# optional comment lines
# num_vertices num_edges (also treated as a comment if starting with #)
0 1
1 2
2 0
...
```

One `src dst` pair per line (0-indexed). Lines starting with `#` are skipped. Vertex count is inferred as `max(vertex_id) + 1`. Self-loops are silently dropped.

---

## Testing

### Correctness check (all three implementations on web-Google)

The combined implementation must produce PageRank values within `1e-5` of the sequential baseline for every vertex on web-Google and the small test graphs.

Run both and compare:
```bash
./pagerank_seq      data/web-Google.txt > seq_out.txt
./pagerank_combined data/web-Google.txt > comb_out.txt
python3 test/verify_correctness.py --ref seq_out.txt --cmp comb_out.txt --tol 1e-5
```

### Output format

Each binary prints one line per vertex to stdout:
```
node <v>  PR=<value>
```
followed by timing and stats. The correctness checker reads this format.

### Small test graphs

| File | What it tests |
|---|---|
| `tiny_5node.txt` | Basic correctness, one cycle, one dangling node |
| `chain_10node.txt` | Chain compression in combined |
| `scc_test.txt` | SCC ordering and cross-edge initialization |
| `dangling_nodes.txt` | Dangling node redistribution |
| `identical_nodes.txt` | Identical node merging |

For `scc_test.txt`, the combined implementation should converge faster (fewer total iterations) than the sequential baseline.

---

## Theoretical Performance Summary

| Implementation | Random DRAM writes / iter | Cache behavior | Iterations |
|---|---|---|---|
| Sequential | O(\|E\|) | All vertex reads miss L3 | Baseline T |
| Paper 1 | O(k²) | Vertex sets fit in L2 | Same T |
| Combined | O(k'²), k' ≤ k | Smaller graph, same L2 fit | T_i per SCC, sum < T |

Where k = partitions on full graph, k' = partitions on reduced graph. Because the combined approach processes each SCC independently with fixed cross-SCC contributions, the effective iteration count per SCC is typically much lower than T.

---

## Known Bugs Fixed From Previous Version

The previous `pagerank_combined.cpp` produced wrong PageRank values on web-Google. These are the exact bugs that must NOT be repeated:

1. **`next[v]` was initialized to `teleport` only, omitting `crossContrib[v]`.**
   Fix: every gather phase must start with `next[v] = teleport + crossContrib[v]`.

2. **`outdeg[e.src]` used SCC-internal out-degree instead of global out-degree.**
   Fix: always use the global `outdeg[]` array, never count only intra-SCC edges.

3. **No dangling-node handling within SCCs.**
   Fix: compute `scc_dang` per SCC per iteration (nodes with no internal out-edges) and add `D * scc_dang / n` in the gather phase.

4. **Chain edge scan was O(K × |chainEdges|) due to filtering all chain edges per SCC.**
   Fix: pre-bucket chain edges by SCC id at preprocessing time.

5. **`unordered_map` per SCC for local index lookup.**
   Fix: precompute a global `localIdx[]` array once.

6. **No level-parallel execution of independent SCCs.**
   Fix: compute topological levels and use `#pragma omp parallel for` over SCCs within each level.

7. **Identical-node optimization only skipped non-rep sources, not destinations.**
   Fix: skip `e.dst` if `rep[e.dst] != e.dst` in scatter phase too.

8. **Global convergence threshold used per-SCC.**
   Fix: per-SCC threshold = `global_threshold * sz`.
