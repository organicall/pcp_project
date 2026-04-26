# PageRank — How to Run

## Prerequisites

```bash
brew install libomp   # one-time setup
```

## Build

```bash
cd pagerank
make
```

Produces six binaries: `pagerank_sequential`, `pagerank_paper1`, `pagerank_paper1_improved`, `pagerank_paper1_improved_2`, `pagerank_paper1_improved_3`, `pagerank_paper1_improved_4`.

---

## Graph file format

All binaries accept any SNAP-format edge-list file:

```
# comment lines starting with # are skipped
# Nodes: N  Edges: M
FromNodeId  ToNodeId
0  1
0  2
1  3
...
```

---

## Run all five and compare

The quickest way — runs all five one by one and saves a timestamped report to `results/`:

```bash
./benchmark.sh data/web-Google.txt
./benchmark.sh data/web-Stanford.txt
./benchmark.sh data/web-BerkStan.txt
```

Or manually — change `GRAPH=` then paste the whole block:

```bash
GRAPH=data/web-Google.txt

./pagerank_sequential        "$GRAPH" > /tmp/seq.txt
./pagerank_paper1            "$GRAPH" > /tmp/p1.txt
./pagerank_paper1_improved   "$GRAPH" > /tmp/p1imp.txt
./pagerank_paper1_improved_2 "$GRAPH" > /tmp/p1imp2.txt
./pagerank_paper1_improved_3 "$GRAPH" > /tmp/p1imp3.txt
./pagerank_paper1_improved_4 "$GRAPH" > /tmp/p1imp4.txt

python3 - <<'EOF'
import re

def parse(path):
    pr, iters, ms = {}, None, None
    for line in open(path):
        if line.startswith("node "):
            p = line.split(); pr[int(p[1])] = float(p[2].split("=")[1])
        m = re.match(r"^Iterations:\s+(\d+)", line)
        if m: iters = int(m.group(1))
        m = re.match(r"^Time:\s+([\d.]+)", line)
        if m: ms = float(m.group(1))
    return pr, iters, ms

def check(a, b, tol=1e-5):
    bad  = sum(1 for v in a if abs(a[v]-b[v]) > tol)
    maxe = max(abs(a[v]-b[v]) for v in a)
    return ("PASS" if bad == 0 else f"FAIL({bad})"), maxe

seq,  si, sm   = parse("/tmp/seq.txt")
p1,   pi, pm   = parse("/tmp/p1.txt")
imp,  ii, im   = parse("/tmp/p1imp.txt")
imp2, i2, im2  = parse("/tmp/p1imp2.txt")
imp3, i3, im3  = parse("/tmp/p1imp3.txt")
imp4, i4, im4  = parse("/tmp/p1imp4.txt")

p1_ok,   p1_err   = check(seq, p1)
imp_ok,  imp_err  = check(seq, imp)
imp2_ok, imp2_err = check(seq, imp2)
imp3_ok, imp3_err = check(seq, imp3)
imp4_ok, imp4_err = check(seq, imp4)

W = 68
print("=" * W)
print(f"  {'Implementation':<32} {'Iters':>5}  {'Time (ms)':>10}  {'vs Seq':>8}")
print("-" * W)
print(f"  {'Sequential (baseline)':<32} {si:>5}  {sm:>10.1f}  {'1.00x':>8}")
print(f"  {'Paper 1':<32} {pi:>5}  {pm:>10.1f}  {sm/pm:>7.2f}x")
print(f"  {'Paper 1 improved':<32} {ii:>5}  {im:>10.1f}  {sm/im:>7.2f}x")
print(f"  {'Paper 1 improved_2':<32} {i2:>5}  {im2:>10.1f}  {sm/im2:>7.2f}x")
print(f"  {'Paper 1 improved_3 (DBG)':<32} {i3:>5}  {im3:>10.1f}  {sm/im3:>7.2f}x")
print(f"  {'Paper 1 improved_4 (PCPM)':<32} {i4:>5}  {im4:>10.1f}  {sm/im4:>7.2f}x")
print("=" * W)
print(f"  Correctness vs sequential (tol 1e-5):")
print(f"    Paper 1            : {p1_ok:<6}  max_err={p1_err:.2e}")
print(f"    Paper 1 improved   : {imp_ok:<6}  max_err={imp_err:.2e}")
print(f"    Paper 1 improved_2 : {imp2_ok:<6}  max_err={imp2_err:.2e}")
print(f"    Paper 1 improved_3 : {imp3_ok:<6}  max_err={imp3_err:.2e}")
print(f"    Paper 1 improved_4 : {imp4_ok:<6}  max_err={imp4_err:.2e}")
print("=" * W)
EOF
```

---

## Run each method individually

```bash
./pagerank_sequential        data/web-Google.txt
./pagerank_paper1            data/web-Google.txt
./pagerank_paper1_improved   data/web-Google.txt
./pagerank_paper1_improved_2 data/web-Google.txt
./pagerank_paper1_improved_3 data/web-Google.txt
./pagerank_paper1_improved_4 data/web-Google.txt
```

---

## Currently available graphs

| File | Nodes | Edges | What it exercises |
|---|---|---|---|
| `data/web-Google.txt` | 875,713 | 5,105,039 | General web graph, good default |
| `data/web-Stanford.txt` | 281,903 | 2,312,497 | Smaller web graph, faster to iterate |
| `data/web-BerkStan.txt` | 685,230 | 7,600,595 | Power-law heavy; paper1 imbalance ~4.7×, improved ~1.0× |

---

## Adding more graphs

1. Download from [https://snap.stanford.edu/data/](https://snap.stanford.edu/data/) — use the `.txt.gz` files.
2. Unzip into `data/`:

```bash
cd data
curl -O https://snap.stanford.edu/data/<graph-name>.txt.gz
gunzip <graph-name>.txt.gz
cd ..
```

3. Swap the `GRAPH=` line in the comparison script above and re-run.

---

## Clean

```bash
make clean
```

# testing goals 
# test it on the lab machine. make sure to fig out what graphs to use
