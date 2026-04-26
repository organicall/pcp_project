# PageRank — Thread-Sweep Benchmarking on Linux

## What was changed

All six parallel implementations (`pagerank_paper1`, `pagerank_paper1_improved`,
`pagerank_paper1_improved_2`, `pagerank_paper1_improved_3`, `pagerank_paper1_improved_4`,
`pagerank_combined`) previously had the thread count hard-coded to 8 via
`static constexpr int NTHREADS = 8` and `omp_set_num_threads(NTHREADS)`.

They now read the thread count at runtime via `omp_get_max_threads()`, which
respects the `OMP_NUM_THREADS` environment variable. The sequential baseline is
unaffected (it has no OpenMP parallelism).

For `improved_2` and `improved_3`, the `std::array<double, NTHREADS>` accumulator
(which required a compile-time constant) was replaced with a flat
`std::vector<double>` of size `n * nthreads` with manual `v * nthreads + t` indexing.

---

## Prerequisites

```bash
# Ubuntu / Debian
sudo apt install -y g++ python3

# Fedora / RHEL
sudo dnf install -y gcc-c++ python3
```

Check how many physical cores the machine has:

```bash
nproc
```

---

## Build

```bash
cd ~/pcp_proj-main/pagerank

g++ -O3 -fopenmp -std=c++17 -o pagerank_sequential        pagerank_sequential.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_paper1            pagerank_paper1.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_paper1_improved   pagerank_paper1_improved.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_paper1_improved_2 pagerank_paper1_improved_2.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_paper1_improved_3 pagerank_paper1_improved_3.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_paper1_improved_4 pagerank_paper1_improved_4.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_combined          pagerank_combined.cpp
```

---

## Run a single binary at a specific thread count

Set `OMP_NUM_THREADS` before the command:

```bash
OMP_NUM_THREADS=1  ./pagerank_paper1 data/web-Google.txt
OMP_NUM_THREADS=2  ./pagerank_paper1 data/web-Google.txt
OMP_NUM_THREADS=4  ./pagerank_paper1 data/web-Google.txt
OMP_NUM_THREADS=8  ./pagerank_paper1 data/web-Google.txt
OMP_NUM_THREADS=16 ./pagerank_paper1 data/web-Google.txt
OMP_NUM_THREADS=32 ./pagerank_paper1 data/web-Google.txt
```

Works the same for any binary. The sequential baseline ignores `OMP_NUM_THREADS`.

---

## Full thread-sweep benchmark (1, 2, 4, 8, 16, 32 threads)

Runs all 6 parallel implementations × 6 thread counts (36 runs total), plus the
sequential baseline once. Prints two tables (time in ms, speedup vs sequential)
and saves a timestamped report + CSV to `results/`.

```bash
cd ~/pcp_proj-main/pagerank
./benchmark_threads.sh data/web-Google.txt
```

Other graphs:

```bash
./benchmark_threads.sh data/web-Stanford.txt
./benchmark_threads.sh data/web-BerkStan.txt
./benchmark_threads.sh data/indochina-2004.txt
```

Output files written to `results/`:
- `<graph>_threads_<timestamp>.txt` — human-readable tables
- `<graph>_threads_<timestamp>.csv` — `implementation,threads,time_ms,speedup_vs_seq`

---

## Download graph data

```bash
mkdir -p ~/pcp_proj-main/pagerank/data
cd ~/pcp_proj-main/pagerank/data

# web-Google (875K nodes, 5.1M edges)
curl -O https://snap.stanford.edu/data/web-Google.txt.gz && gunzip web-Google.txt.gz

# web-Stanford (281K nodes, 2.3M edges) — faster
curl -O https://snap.stanford.edu/data/web-Stanford.txt.gz && gunzip web-Stanford.txt.gz

# web-BerkStan (685K nodes, 7.6M edges)
curl -O https://snap.stanford.edu/data/web-BerkStan.txt.gz && gunzip web-BerkStan.txt.gz
```

### indochina-2004 (7.4M nodes, 194M edges — ~3–4 GB uncompressed)

```bash
cd ~/pcp_proj-main/pagerank/data

# Check disk space first
df -h .

# Download (~449 MB compressed)
curl -L -o indochina-2004.tar.gz \
  https://suitesparse-collection-website.herokuapp.com/MM/LAW/indochina-2004.tar.gz

# Mirror if the above fails:
# curl -L -o indochina-2004.tar.gz \
#   https://sparse.tamu.edu/MM/LAW/indochina-2004.tar.gz

# Extract
tar -xzf indochina-2004.tar.gz

# Convert from Matrix Market (1-indexed) to plain edge list (0-indexed)
# This step takes a few minutes over 194M edges
grep -v '^%' indochina-2004/indochina-2004.mtx | tail -n +2 | \
  awk '{print $1-1, $2-1}' > indochina-2004.txt

cd ~/pcp_proj-main/pagerank
```

---

## Notes on thread counts vs core count

If the machine has fewer than 32 physical cores, runs at T=32 will still work but
may show degraded performance due to over-subscription. Always check `nproc` first.

For NUMA machines (multiple sockets), performance at high thread counts can drop
if threads span sockets. Pin threads to one socket if needed:

```bash
numactl --cpunodebind=0 --membind=0 OMP_NUM_THREADS=16 ./pagerank_paper1 data/web-Google.txt
```
