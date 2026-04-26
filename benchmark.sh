#!/usr/bin/env bash
# Runs all 7 implementations: sequential, combined (STIC-D), paper1,
# paper1_improved, paper1_improved_2, paper1_improved_3, paper1_improved_4.
# Saves a timestamped report to results/.
# Usage: ./benchmark.sh [graph_file]
#        Defaults to data/web-Google.txt if no argument given.

set -euo pipefail

GRAPH="${1:-data/web-Google.txt}"
RESULTS_DIR="results"
mkdir -p "$RESULTS_DIR"

if [[ ! -f "$GRAPH" ]]; then
    echo "Graph file not found: $GRAPH"
    exit 1
fi

GRAPH_NAME=$(basename "$GRAPH" .txt)
TIMESTAMP=$(date "+%Y-%m-%d_%H-%M-%S")
OUTFILE="$RESULTS_DIR/${GRAPH_NAME}_${TIMESTAMP}.txt"

# ── Run all 7, capture full output ────────────────────────────────────────────
TMP_SEQ=$(mktemp)
TMP_COMB=$(mktemp)
TMP_P1=$(mktemp)
TMP_P1IMP=$(mktemp)
TMP_P1IMP2=$(mktemp)
TMP_P1IMP3=$(mktemp)
TMP_P1IMP4=$(mktemp)
trap 'rm -f "$TMP_SEQ" "$TMP_COMB" "$TMP_P1" "$TMP_P1IMP" "$TMP_P1IMP2" "$TMP_P1IMP3" "$TMP_P1IMP4"' EXIT

echo "Running sequential..."        && ./pagerank_sequential        "$GRAPH" > "$TMP_SEQ"    2>&1
echo "Running combined (STIC-D)..." && ./pagerank_combined          "$GRAPH" > "$TMP_COMB"   2>&1
echo "Running paper1..."            && ./pagerank_paper1            "$GRAPH" > "$TMP_P1"     2>&1
echo "Running paper1_improved..."   && ./pagerank_paper1_improved   "$GRAPH" > "$TMP_P1IMP"  2>&1
echo "Running paper1_improved_2..." && ./pagerank_paper1_improved_2 "$GRAPH" > "$TMP_P1IMP2" 2>&1
echo "Running paper1_improved_3..." && ./pagerank_paper1_improved_3 "$GRAPH" > "$TMP_P1IMP3" 2>&1
echo "Running paper1_improved_4..." && ./pagerank_paper1_improved_4 "$GRAPH" > "$TMP_P1IMP4" 2>&1
echo "Done. Generating report..."

# ── Extract metrics ───────────────────────────────────────────────────────────
seq_vertices=$(grep "^Vertices:" "$TMP_SEQ" | awk '{print $2}')
seq_edges=$(grep "^Vertices:" "$TMP_SEQ" | awk '{print $4}')
seq_iters=$(grep "^Iterations:" "$TMP_SEQ" | awk '{print $2}')
seq_time=$(grep "^Time:" "$TMP_SEQ" | awk '{print $2}')

# Combined outputs "Preprocessing: X ms", "Computation: Y ms", "Total: Z ms"
comb_pre_ms=$(grep "^Preprocessing:" "$TMP_COMB" | head -1 | awk '{print $2}')
comb_comp_ms=$(grep "^Computation:" "$TMP_COMB" | head -1 | awk '{print $2}')
comb_total_ms=$(grep "^Total:" "$TMP_COMB" | head -1 | awk '{print $2}')

p1_iters=$(grep "^Iterations:" "$TMP_P1" | awk '{print $2}')
p1_time=$(grep "^Time:" "$TMP_P1" | awk '{print $2}')
p1_bw=$(grep "^Est. memory bandwidth:" "$TMP_P1" | awk '{print $4, $5}')
p1_partm=$(grep "^L2-derived" "$TMP_P1" | sed 's/.*m=\([0-9]*\).*/\1/')
p1_k=$(grep "^L2-derived" "$TMP_P1" | sed 's/.*k=\([0-9]*\).*/\1/')
# Original imbalance ratio is printed by paper1_improved in its comparison block
p1_imbalance=$(grep "^  imbalance ratio:" "$TMP_P1IMP" | head -1 | awk '{print $3}')

p1imp_iters=$(grep "^Iterations:" "$TMP_P1IMP" | awk '{print $2}')
p1imp_time=$(grep "^Time:" "$TMP_P1IMP" | awk '{print $2}')
p1imp_bw=$(grep "^Est. memory bandwidth:" "$TMP_P1IMP" | awk '{print $4, $5}')
p1imp_k=$(grep "^Edge-balanced partitions:" "$TMP_P1IMP" | sed 's/.*k=\([0-9]*\).*/\1/')
p1imp_imbalance=$(grep "^  imbalance ratio:" "$TMP_P1IMP" | tail -1 | awk '{print $3}')

p1imp2_iters=$(grep "^Iterations:" "$TMP_P1IMP2" | awk '{print $2}')
p1imp2_time=$(grep "^Time:" "$TMP_P1IMP2" | awk '{print $2}')
p1imp2_bw=$(grep "^Est. memory bandwidth:" "$TMP_P1IMP2" | awk '{print $4, $5}')
p1imp2_k=$(grep "^  Improved (edge-balanced):" "$TMP_P1IMP2" | sed 's/.*k=\([0-9]*\).*/\1/')
p1imp2_imbalance=$(grep "^  Improved (edge-balanced):" "$TMP_P1IMP2" | sed 's/.*imbalance=\([0-9.]*\).*/\1/')

p1imp3_iters=$(grep "^Iterations:" "$TMP_P1IMP3" | awk '{print $2}')
p1imp3_time=$(grep "^Time:" "$TMP_P1IMP3" | awk '{print $2}')
p1imp3_bw=$(grep "^Est. memory bandwidth:" "$TMP_P1IMP3" | awk '{print $4, $5}')

p1imp4_iters=$(grep "^Iterations:" "$TMP_P1IMP4" | awk '{print $2}')
p1imp4_time=$(grep "^Time:" "$TMP_P1IMP4" | awk '{print $2}')
p1imp4_bw=$(grep "^Est. memory bandwidth:" "$TMP_P1IMP4" | awk '{print $4, $5}')

seq_ms=$(echo "$seq_time" | awk '{print $1}')
p1_ms=$(echo "$p1_time" | awk '{print $1}')
p1imp_ms=$(echo "$p1imp_time" | awk '{print $1}')
p1imp2_ms=$(echo "$p1imp2_time" | awk '{print $1}')
p1imp3_ms=$(echo "$p1imp3_time" | awk '{print $1}')
p1imp4_ms=$(echo "$p1imp4_time" | awk '{print $1}')

comb_speedup=$(python3 -c "print(f'{float($seq_ms)/float($comb_total_ms):.2f}')")
p1_speedup=$(python3 -c "print(f'{float($seq_ms)/float($p1_ms):.2f}')")
p1imp_speedup=$(python3 -c "print(f'{float($seq_ms)/float($p1imp_ms):.2f}')")
p1imp2_speedup=$(python3 -c "print(f'{float($seq_ms)/float($p1imp2_ms):.2f}')")
p1imp3_speedup=$(python3 -c "print(f'{float($seq_ms)/float($p1imp3_ms):.2f}')")
p1imp4_speedup=$(python3 -c "print(f'{float($seq_ms)/float($p1imp4_ms):.2f}')")
p1imp2_vs_p1=$(python3 -c "print(f'{float($p1_ms)/float($p1imp2_ms):.2f}')")

# ── Correctness check (all parallel variants vs sequential, tol 1e-5) ─────────
correctness=$(python3 -c "
def load(path):
    d = {}
    with open(path) as f:
        for line in f:
            if line.startswith('node '):
                p = line.split(); d[int(p[1])] = float(p[2].split('=')[1])
    return d

seq   = load('$TMP_SEQ')
comb  = load('$TMP_COMB')
p1    = load('$TMP_P1')
imp   = load('$TMP_P1IMP')
imp2  = load('$TMP_P1IMP2')
imp3  = load('$TMP_P1IMP3')
imp4  = load('$TMP_P1IMP4')

def check(a, b, label):
    if not a or not b:
        return f'{label}: N/A (no PR output found)'
    bad  = sum(1 for v in a if abs(a[v]-b[v]) > 1e-5)
    maxe = max(abs(a[v]-b[v]) for v in a)
    status = 'PASS' if bad == 0 else f'FAIL ({bad} vertices exceed 1e-5)'
    return f'{label}: {status}  |  max error: {maxe:.2e}'

print(check(seq, comb, 'Combined (STIC-D)  '))
print(check(seq, p1,   'Paper 1            '))
print(check(seq, imp,  'Paper 1 improved   '))
print(check(seq, imp2, 'Paper 1 improved_2 '))
print(check(seq, imp3, 'Paper 1 improved_3 '))
print(check(seq, imp4, 'Paper 1 improved_4 '))
")

# ── Build the report ──────────────────────────────────────────────────────────
{
printf "================================================================\n"
printf "  PageRank Benchmark Report\n"
printf "  Graph     : %s\n" "$GRAPH"
printf "  Vertices  : %s    Edges: %s\n" "$seq_vertices" "$seq_edges"
printf "  Timestamp : %s\n" "$TIMESTAMP"
printf "================================================================\n"
printf "\n"
printf "┌────────────────────────────────────────────────────────────────┐\n"
printf "│  TIMING SUMMARY                                                │\n"
printf "├───────────────────────────┬──────────┬───────────┬─────────────┤\n"
printf "│  Implementation           │ Iters    │ Time (ms) │ vs Seq      │\n"
printf "├───────────────────────────┼──────────┼───────────┼─────────────┤\n"
printf "│  Sequential (baseline)    │ %-8s │ %-9s │ 1.00×       │\n" "$seq_iters"    "${seq_ms} ms"
printf "│  Combined (STIC-D)        │ %-8s │ %-9s │ %s× faster  │\n" "N/A"           "${comb_total_ms} ms" "$comb_speedup"
printf "│  Paper 1 (vertex-bal.)    │ %-8s │ %-9s │ %s× faster  │\n" "$p1_iters"     "${p1_ms} ms"     "$p1_speedup"
printf "│  Paper 1 improved         │ %-8s │ %-9s │ %s× faster  │\n" "$p1imp_iters"  "${p1imp_ms} ms"  "$p1imp_speedup"
printf "│  Paper 1 improved_2       │ %-8s │ %-9s │ %s× faster  │\n" "$p1imp2_iters" "${p1imp2_ms} ms" "$p1imp2_speedup"
printf "│  Paper 1 improved_3 (DBG) │ %-8s │ %-9s │ %s× faster  │\n" "$p1imp3_iters" "${p1imp3_ms} ms" "$p1imp3_speedup"
printf "│  Paper 1 improved_4 (PCPM)│ %-8s │ %-9s │ %s× faster  │\n" "$p1imp4_iters" "${p1imp4_ms} ms" "$p1imp4_speedup"
printf "└───────────────────────────┴──────────┴───────────┴─────────────┘\n"
printf "\n"
printf "  Paper 1 improved_2 vs Paper 1: %s× faster  (%s ms → %s ms)\n" \
       "$p1imp2_vs_p1" "$p1_ms" "$p1imp2_ms"
printf "\n"
printf "  Combined (STIC-D) details:\n"
printf "    Preprocessing:  %s ms  |  Computation: %s ms\n" "$comb_pre_ms" "$comb_comp_ms"
printf "\n"
printf "  Paper 1 details:\n"
printf "    Partition size m=%s   partitions k=%s\n" "$p1_partm" "$p1_k"
printf "    Imbalance ratio (max/min edges): %s\n" "$p1_imbalance"
printf "    Est. memory bandwidth: %s\n" "$p1_bw"
printf "\n"
printf "  Paper 1 improved details:\n"
printf "    Edge-balanced partitions k=%s\n" "$p1imp_k"
printf "    Imbalance ratio (max/min edges): %s\n" "$p1imp_imbalance"
printf "    Est. memory bandwidth: %s\n" "$p1imp_bw"
printf "\n"
printf "  Paper 1 improved_2 details:\n"
printf "    Edge-balanced partitions k=%s\n" "$p1imp2_k"
printf "    Imbalance ratio (max/min edges): %s\n" "$p1imp2_imbalance"
printf "    Est. memory bandwidth: %s\n" "$p1imp2_bw"
printf "\n"
printf "  Paper 1 improved_3 details:\n"
printf "    DBG vertex reordering (in-degree descending)\n"
printf "    Est. memory bandwidth: %s\n" "$p1imp3_bw"
printf "\n"
printf "  Paper 1 improved_4 details:\n"
printf "    PCPM scatter-gather (edges grouped by src_part x dst_part)\n"
printf "    Est. memory bandwidth: %s\n" "$p1imp4_bw"
printf "\n"
printf "┌────────────────────────────────────────────────────────────────┐\n"
printf "│  CORRECTNESS  (vs sequential, tolerance 1e-5)                  │\n"
printf "└────────────────────────────────────────────────────────────────┘\n"
printf "\n"
printf "  %s\n" "$(echo "$correctness" | sed -n '1p')"
printf "  %s\n" "$(echo "$correctness" | sed -n '2p')"
printf "  %s\n" "$(echo "$correctness" | sed -n '3p')"
printf "  %s\n" "$(echo "$correctness" | sed -n '4p')"
printf "  %s\n" "$(echo "$correctness" | sed -n '5p')"
printf "  %s\n" "$(echo "$correctness" | sed -n '6p')"
printf "\n"
printf "================================================================\n"
printf "  Full output saved to: %s\n" "$OUTFILE"
printf "================================================================\n"
} | tee "$OUTFILE"
