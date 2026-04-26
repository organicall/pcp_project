# PageRank — Running on Linux

## Prerequisites

Install g++ with OpenMP support and Python 3:

```bash
# Ubuntu / Debian
sudo apt update
sudo apt install -y g++ python3

# Fedora / RHEL / CentOS
sudo dnf install -y gcc-c++ python3

# Arch
sudo pacman -S gcc python
```

OpenMP is included in g++ by default on Linux — no separate libomp install needed.

---

## Build

The Makefile is written for macOS (clang + Homebrew libomp). On Linux, compile directly with g++:

```bash
cd pagerank

g++ -O3 -fopenmp -std=c++17 -o pagerank_sequential        pagerank_sequential.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_paper1            pagerank_paper1.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_paper1_improved   pagerank_paper1_improved.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_paper1_improved_2 pagerank_paper1_improved_2.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_paper1_improved_3 pagerank_paper1_improved_3.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_paper1_improved_4 pagerank_paper1_improved_4.cpp
g++ -O3 -fopenmp -std=c++17 -o pagerank_combined          pagerank_combined.cpp
```

All `.cpp` files include `graph_loader.h` from the same directory — no extra flags needed.

---

## Download graph data

Graphs come from the [SNAP dataset collection](https://snap.stanford.edu/data/). Download them into `data/`:

```bash
mkdir -p data
cd data

# web-Google (875K nodes, 5.1M edges) — good default
curl -O https://snap.stanford.edu/data/web-Google.txt.gz && gunzip web-Google.txt.gz

# web-Stanford (281K nodes, 2.3M edges) — faster to run
curl -O https://snap.stanford.edu/data/web-Stanford.txt.gz && gunzip web-Stanford.txt.gz

# web-BerkStan (685K nodes, 7.6M edges) — stresses load balancing
curl -O https://snap.stanford.edu/data/web-BerkStan.txt.gz && gunzip web-BerkStan.txt.gz

cd ..
```

---

## Run all implementations and benchmark

```bash
cd pagerank
./benchmark.sh data/web-Google.txt
```

This runs all 7 binaries, checks correctness against the sequential baseline, and saves a timestamped report to `results/`.

To run on other graphs:

```bash
./benchmark.sh data/web-Stanford.txt
./benchmark.sh data/web-BerkStan.txt
```

---

## Run each binary individually

```bash
./pagerank_sequential        data/web-Google.txt
./pagerank_paper1            data/web-Google.txt
./pagerank_paper1_improved   data/web-Google.txt
./pagerank_paper1_improved_2 data/web-Google.txt
./pagerank_paper1_improved_3 data/web-Google.txt
./pagerank_paper1_improved_4 data/web-Google.txt
./pagerank_combined          data/web-Google.txt
```

---

## Control thread count

Set `OMP_NUM_THREADS` before running to control parallelism:

```bash
OMP_NUM_THREADS=8  ./pagerank_paper1 data/web-Google.txt
OMP_NUM_THREADS=16 ./pagerank_paper1 data/web-Google.txt
```

To check how many cores the machine has:

```bash
nproc
```

---

## Output format

Each binary prints one line per vertex to stdout:

```
node <v>  PR=<value>
```

followed by timing and stats (iterations, time in ms, memory bandwidth estimate).

---

## Correctness check (manual)

```bash
./pagerank_sequential data/web-Google.txt > /tmp/seq.txt
./pagerank_combined   data/web-Google.txt > /tmp/comb.txt

python3 - <<'EOF'
def load(path):
    d = {}
    with open(path) as f:
        for line in f:
            if line.startswith("node "):
                p = line.split(); d[int(p[1])] = float(p[2].split("=")[1])
    return d

seq  = load("/tmp/seq.txt")
comb = load("/tmp/comb.txt")

bad  = sum(1 for v in seq if abs(seq[v] - comb[v]) > 1e-5)
maxe = max(abs(seq[v] - comb[v]) for v in seq)
print("PASS" if bad == 0 else f"FAIL ({bad} vertices)")
print(f"max error: {maxe:.2e}")
EOF
```

---

## Clean

```bash
rm -f pagerank_sequential pagerank_paper1 pagerank_paper1_improved \
      pagerank_paper1_improved_2 pagerank_paper1_improved_3 \
      pagerank_paper1_improved_4 pagerank_combined
```
