
#!/usr/bin/env bash
# test2
# Thread-sweep benchmark: runs all parallel implementations at
# OMP_NUM_THREADS = 1, 2, 4, 8, 16, 32 and prints a consolidated table.
# Sequential runs once as the baseline (OMP_NUM_THREADS has no effect on it).
#
# Usage: ./benchmark_threads.sh [graph_file]
#        Defaults to data/web-Google.txt

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
OUTFILE="$RESULTS_DIR/${GRAPH_NAME}_threads_${TIMESTAMP}.txt"
CSVFILE="$RESULTS_DIR/${GRAPH_NAME}_threads_${TIMESTAMP}.csv"

THREAD_COUNTS=(1 2 4 8 16 32)

IMPLS=(
    "pagerank_paper1"
    "pagerank_paper1_improved"
    "pagerank_paper1_improved_2"
    "pagerank_paper1_improved_3"
    "pagerank_combined"
)

IMPL_LABELS=(
    "Paper1 (vertex-bal.)"
    "Paper1 improved     "
    "Paper1 improved_2   "
    "Paper1 improved_3   "
    "Combined (STIC-D)   "
)

# ── Helper: extract time in ms from a binary's output ────────────────────────
extract_ms() {
    local file="$1"
    local impl="$2"
    if [[ "$impl" == "pagerank_combined" ]]; then
        grep "^Total:" "$file" | head -1 | awk '{print $2}'
    else
        grep "^Time:" "$file" | awk '{print $1}'
    fi
}

# ── Run sequential baseline once ─────────────────────────────────────────────
echo "Running sequential baseline..."
TMP_SEQ=$(mktemp)
trap 'rm -f "$TMP_SEQ"' EXIT
./pagerank_sequential "$GRAPH" > "$TMP_SEQ" 2>&1
SEQ_MS=$(grep "^Time:" "$TMP_SEQ" | awk '{print $2}')
SEQ_ITERS=$(grep "^Iterations:" "$TMP_SEQ" | awk '{print $2}')
SEQ_VERTICES=$(grep "^Vertices:" "$TMP_SEQ" | awk '{print $2}')
SEQ_EDGES=$(grep "^Vertices:" "$TMP_SEQ" | awk '{print $4}')
echo "  Sequential: ${SEQ_MS} ms  (${SEQ_ITERS} iters)"
echo ""

# ── Collect timings[impl][thread_count] ──────────────────────────────────────
declare -A TIMINGS  # key: "impl_idx:thread_idx" -> ms

NUM_IMPLS=${#IMPLS[@]}
NUM_THREADS=${#THREAD_COUNTS[@]}

for (( ti=0; ti<NUM_THREADS; ti++ )); do
    T=${THREAD_COUNTS[$ti]}
    echo "=== OMP_NUM_THREADS=$T ==="
    for (( ii=0; ii<NUM_IMPLS; ii++ )); do
        BIN="${IMPLS[$ii]}"
        LABEL="${IMPL_LABELS[$ii]}"
        TMP=$(mktemp)
        printf "  %-24s ... " "$BIN"
        OMP_NUM_THREADS=$T ./"$BIN" "$GRAPH" > "$TMP" 2>&1
        if [[ "$BIN" == "pagerank_combined" ]]; then
            MS=$(grep "^Total:" "$TMP" | head -1 | awk '{print $2}')
        else
            MS=$(grep "^Time:" "$TMP" | awk '{print $2}')
        fi
        TIMINGS["$ii:$ti"]="$MS"
        SPEEDUP=$(python3 -c "print(f'{float($SEQ_MS)/float($MS):.2f}')")
        echo "${MS} ms  (${SPEEDUP}× vs seq)"
        rm -f "$TMP"
    done
    echo ""
done

# ── Build report ──────────────────────────────────────────────────────────────
{
printf "================================================================\n"
printf "  PageRank Thread-Sweep Benchmark\n"
printf "  Graph     : %s\n" "$GRAPH"
printf "  Vertices  : %s    Edges: %s\n" "$SEQ_VERTICES" "$SEQ_EDGES"
printf "  Timestamp : %s\n" "$TIMESTAMP"
printf "================================================================\n"
printf "\n"
printf "  Sequential baseline: %s ms  (%s iters)  [OMP_NUM_THREADS has no effect]\n" "$SEQ_MS" "$SEQ_ITERS"
printf "\n"

# ── Timing table (ms) ─────────────────────────────────────────────────────────
printf "  TIME (ms)\n"
printf "  %-24s" "Implementation"
for T in "${THREAD_COUNTS[@]}"; do printf "  %8s" "T=$T"; done
printf "\n"
printf "  %-24s" "------------------------"
for _ in "${THREAD_COUNTS[@]}"; do printf "  %8s" "--------"; done
printf "\n"

for (( ii=0; ii<NUM_IMPLS; ii++ )); do
    printf "  %-24s" "${IMPL_LABELS[$ii]}"
    for (( ti=0; ti<NUM_THREADS; ti++ )); do
        MS="${TIMINGS[$ii:$ti]}"
        printf "  %8s" "${MS}"
    done
    printf "\n"
done

printf "\n"

# ── Speedup table (vs sequential) ─────────────────────────────────────────────
printf "  SPEEDUP vs sequential\n"
printf "  %-24s" "Implementation"
for T in "${THREAD_COUNTS[@]}"; do printf "  %8s" "T=$T"; done
printf "\n"
printf "  %-24s" "------------------------"
for _ in "${THREAD_COUNTS[@]}"; do printf "  %8s" "--------"; done
printf "\n"

for (( ii=0; ii<NUM_IMPLS; ii++ )); do
    printf "  %-24s" "${IMPL_LABELS[$ii]}"
    for (( ti=0; ti<NUM_THREADS; ti++ )); do
        MS="${TIMINGS[$ii:$ti]}"
        SP=$(python3 -c "print(f'{float($SEQ_MS)/float($MS):.2f}x')")
        printf "  %8s" "$SP"
    done
    printf "\n"
done

printf "\n"
printf "================================================================\n"
printf "  Full report : %s\n" "$OUTFILE"
printf "  CSV         : %s\n" "$CSVFILE"
printf "================================================================\n"
} | tee "$OUTFILE"

# ── Write CSV ─────────────────────────────────────────────────────────────────
{
printf "implementation,threads,time_ms,speedup_vs_seq\n"
printf "sequential,1,%s,1.00\n" "$SEQ_MS"
for (( ii=0; ii<NUM_IMPLS; ii++ )); do
    for (( ti=0; ti<NUM_THREADS; ti++ )); do
        T=${THREAD_COUNTS[$ti]}
        MS="${TIMINGS[$ii:$ti]}"
        SP=$(python3 -c "print(f'{float($SEQ_MS)/float($MS):.4f}')")
        printf "%s,%s,%s,%s\n" "${IMPLS[$ii]}" "$T" "$MS" "$SP"
    done
done
} > "$CSVFILE"

echo ""
echo "CSV saved to: $CSVFILE"

