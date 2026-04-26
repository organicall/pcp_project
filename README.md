# Parallel PageRank

Progressive implementations of the PageRank algorithm, benchmarking the impact of cache-aware partitioning and seven further optimisations on shared-memory multicore systems.

Based on two papers:
- **Paper 1** — Zhou et al., *"Design and Implementation of Parallel PageRank on Multicore Platforms"* (IEEE 2017)
- **Paper 2** — Garg & Kothapalli, *"STIC-D: Algorithmic Techniques for Efficient Parallel PageRank Computation on Real-World Graphs"* (ICDCN 2016)

---

## Repository layout

```
.
├── graph_loader.h                         # Shared header: COO/CSR loaders, Timer, computePartitionSize
├── pagerank_naive_csr.cpp                 # Naive CSR pull-model baseline (no parallelism)
├── pagerank_paper1.cpp                    # Zhou et al. 2017 — faithful partitioned scatter-gather
├── pagerank_paper1_improved_3.cpp         # Main improved implementation — 7 optimisations
├── pagerank_paper1_improved_3_atomic.cpp  # Forced-atomic accumulator variant (Test 3)
├── pagerank_paper1_improved_3_local.cpp   # Forced-local accumulator variant (Test 3)
├── benchmark_avg.sh                       # Thread-sweep benchmark, averaged over N trials
├── benchmark_final.sh                     # Multi-graph benchmark with preprocessing & accumulator breakdown
├── Makefile
└── data/                                  # Large graph files (not committed — download separately)
```

---

## Prerequisites

### macOS

```bash
# Xcode command-line tools (provides clang++)
xcode-select --install

# OpenMP runtime (Apple clang does not bundle it)
brew install libomp
```

### Linux

```bash
# GCC with OpenMP
sudo apt install g++ libomp-dev   # Debian/Ubuntu
# or
sudo dnf install gcc-c++          # Fedora/RHEL
```

---

## Build

### macOS (Makefile — Apple clang + Homebrew libomp)

```bash
make pagerank_naive_csr \
     pagerank_paper1 \
     pagerank_paper1_improved_3 \
     pagerank_paper1_improved_3_atomic \
     pagerank_paper1_improved_3_local
```

Or build everything the Makefile knows about:

```bash
make
```

### Linux (g++)

```bash
g++ -O3 -fopenmp -std=c++17 -o pagerank_naive_csr                pagerank_naive_csr.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_paper1                   pagerank_paper1.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_paper1_improved_3        pagerank_paper1_improved_3.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_paper1_improved_3_atomic  pagerank_paper1_improved_3_atomic.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_paper1_improved_3_local   pagerank_paper1_improved_3_local.cpp
```

---

## Graph data

The binaries take a plain edge-list file. Format:

```
# comment lines are skipped
0 1
1 2
2 0
...
```

One `src dst` pair per line (0-indexed). Self-loops are dropped automatically. Vertex count is inferred as `max(vertex_id) + 1`.

Download graphs from [SNAP](https://snap.stanford.edu/data/) and place them under `data/`. The benchmark scripts default to:

| Label | SNAP dataset | File |
|---|---|---|
| web-Google | [web-Google](https://snap.stanford.edu/data/web-Google.html) | `data/web-Google.txt` |
| Pokec | [soc-pokec](https://snap.stanford.edu/data/soc-pokec.html) | `data/soc-pokec-relationships.txt` |
| LiveJournal | [soc-LiveJournal1](https://snap.stanford.edu/data/soc-LiveJournal1.html) | `data/soc-LiveJournal1.txt` |
| Orkut | [com-orkut](https://snap.stanford.edu/data/com-Orkut.html) | `data/com-orkut.txt` |
| Indochina-2004 | [indochina-2004](https://law.di.unimi.it/webdata/indochina-2004/) | `data/indochina-2004.txt` |

---

## Running a single implementation

```bash
# Naive sequential baseline
./pagerank_naive_csr data/web-Google.txt

# Paper 1 faithful — set thread count via OMP_NUM_THREADS
OMP_NUM_THREADS=8 ./pagerank_paper1 data/web-Google.txt

# Improved (7 optimisations, adaptive accumulator)
OMP_NUM_THREADS=8 ./pagerank_paper1_improved_3 data/web-Google.txt

# Forced accumulator variants
OMP_NUM_THREADS=8 ./pagerank_paper1_improved_3_atomic data/web-Google.txt
OMP_NUM_THREADS=8 ./pagerank_paper1_improved_3_local  data/web-Google.txt
```

Each binary prints one line per vertex to stdout:

```
node 0  PR=0.00000123456789
node 1  PR=0.00000234567890
...
```

followed by timing and iteration stats (`Time:`, `Iterations:`, `Vertices:`, and preprocessing labels parsed by the benchmark scripts).

---

## Benchmark scripts

### `benchmark_avg.sh` — thread sweep, averaged

Runs `pagerank_paper1` and `pagerank_paper1_improved_3` across thread counts 1 2 4 8 16 24, repeated N times, then reports average time and speedup vs the sequential baseline.

```bash
# Default graph: data/web-Google.txt
./benchmark_avg.sh

# Specify a different graph
./benchmark_avg.sh data/soc-LiveJournal1.txt
```

Output: a text report and a CSV saved to `results/`.

### `benchmark_final.sh` — multi-graph, accumulator comparison

Runs all four parallel implementations (`paper1`, `improved_3`, `improved_3_atomic`, `improved_3_local`) across four hardcoded graphs and 5 trials each. Produces:

- Average timing and speedup tables per graph
- Preprocessing cost breakdown (DBG reordering time, edge-balanced partition time)
- Accumulator mode comparison (adaptive vs forced-atomic vs forced-local) at each thread count

```bash
./benchmark_final.sh
```

Output: `results/benchmark_final_<timestamp>.{txt,csv}`.

> The graphs must exist at the paths in the `GRAPHS` array at the top of `benchmark_final.sh`. Edit those paths if your files are in a different location.

---

## Implementation summary

| Binary | Algorithm | Parallel | Key technique |
|---|---|---|---|
| `pagerank_naive_csr` | Pull over transposed CSR | No | Reference baseline |
| `pagerank_paper1` | Scatter-gather, vertex partitioning | Yes (OpenMP) | L2-sized vertex partitions; edges sorted by dst |
| `pagerank_paper1_improved_3` | Same + 7 optimisations | Yes (OpenMP) | See below |
| `pagerank_paper1_improved_3_atomic` | `improved_3` with forced global atomic acc | Yes (OpenMP) | Isolates atomic accumulator cost |
| `pagerank_paper1_improved_3_local` | `improved_3` with forced thread-local acc | Yes (OpenMP) | Isolates local accumulator cost |

### 7 optimisations in `improved_3`

1. **Edge-balanced partitioning** — partitions sized by edge count (prefix-sum + binary search) rather than vertex count, giving equal scatter work per thread.
2. **Hybrid accumulator** — thread-local flat array when `nthreads × n × 8 bytes` fits in L3; falls back to atomic global `acc[]` otherwise.
3. **Longest-job-first ordering** — partitions sorted descending by edge count before iteration begins, improving dynamic-scheduling load balance.
4. **Precomputed contributions** — `contrib[u] = D × pr[u] / outdeg[u]` computed once per iteration, eliminating per-edge division in the scatter inner loop.
5. **Scaled partition count** — `k ≥ nthreads × K_MULT` (default `K_MULT=4`) for enough work units at high thread counts.
6. **Guided scheduling** — `schedule(guided)` in scatter; chunks start large and shrink, reducing overhead while preserving balance.
7. **DBG vertex reordering** — vertices renumbered by in-degree descending (Degree-Based Grouping, Faldu et al. IISWC 2019) so hub nodes cluster at the front of all arrays and thread-local `localAcc` slices receive spatially coherent scatter writes.

---

## Algorithm parameters

| Parameter | Value |
|---|---|
| Damping factor | 0.85 |
| Convergence threshold (L1 norm) | 1e-10 |
| Max iterations | 200 |
| L3 cache threshold for hybrid acc | 20 MB |
| Partition scale factor `K_MULT` | 4 |

---

## Cleaning up

```bash
make clean
```
# pcp_project
