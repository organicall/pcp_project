#!/usr/bin/env bash
# te23
# Runs the full thread-sweep 15 times and reports averaged timings.
# Same structure as benchmark_threads.sh: sequential baseline once per trial,
# then all parallel implementations at OMP_NUM_THREADS = 1, 2, 4, 8, 16, 24.
# Results are averaged across all 15 trials.
#
# Usage: ./benchmark_avg.sh [graph_file]
#        Defaults to data/web-Google.txt

set -euo pipefail

GRAPH="${1:-data/web-Google.txt}"
NRUNS=1
RESULTS_DIR="results"
mkdir -p "$RESULTS_DIR"

if [[ ! -f "$GRAPH" ]]; then
    echo "Graph file not found: $GRAPH"
    exit 1
fi

GRAPH_NAME=$(basename "$GRAPH" .txt)
TIMESTAMP=$(date "+%Y-%m-%d_%H-%M-%S")
OUTFILE="$RESULTS_DIR/${GRAPH_NAME}_avg${NRUNS}_${TIMESTAMP}.txt"
CSVFILE="$RESULTS_DIR/${GRAPH_NAME}_avg${NRUNS}_${TIMESTAMP}.csv"

THREAD_COUNTS=(1 2 4 8 16 24)

IMPLS=(
	"pagerank_paper1"
	"pagerank_paper1_improved_3"
)

IMPL_LABELS=(
	"Paper1 (vertex-bal.)"
	"Paper1 improved_3   "
)

NUM_IMPLS=${#IMPLS[@]}
NUM_THREADS=${#THREAD_COUNTS[@]}

# Accumulators: SUM_SEQ, SUM[ii:ti] across runs
SUM_SEQ=0
declare -A SUM   # key: "ii:ti" -> sum of ms across runs

# Initialize sums to 0
for (( ii=0; ii<NUM_IMPLS; ii++ )); do
    for (( ti=0; ti<NUM_THREADS; ti++ )); do
        SUM["$ii:$ti"]=0
    done
done

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

echo "Graph     : $GRAPH"
echo "Trials    : $NRUNS"
echo ""

# ── Run all trials ────────────────────────────────────────────────────────────
for (( run=1; run<=NRUNS; run++ )); do
    echo "=== Trial $run / $NRUNS ==="

    # Sequential baseline
    printf "  %-30s ... " "pagerank_sequential"
    ./pagerank_sequential "$GRAPH" > "$TMP" 2>&1
    MS=$(grep "^Time:" "$TMP" | awk '{print $2}')
    SUM_SEQ=$(python3 -c "print($SUM_SEQ + float('$MS'))")
    echo "${MS} ms"

    # Parallel implementations at each thread count
    for (( ti=0; ti<NUM_THREADS; ti++ )); do
        T=${THREAD_COUNTS[$ti]}
        for (( ii=0; ii<NUM_IMPLS; ii++ )); do
            BIN="${IMPLS[$ii]}"
            printf "  T=%-2s  %-30s ... " "$T" "$BIN"
            OMP_NUM_THREADS=$T ./"$BIN" "$GRAPH" > "$TMP" 2>&1
            if [[ "$BIN" == "pagerank_combined" ]]; then
                MS=$(grep "^Total:" "$TMP" | head -1 | awk '{print $2}')
            else
                MS=$(grep "^Time:" "$TMP" | awk '{print $2}')
            fi
            SUM["$ii:$ti"]=$(python3 -c "print(${SUM[$ii:$ti]} + float('$MS'))")
            echo "${MS} ms"
        done
    done
    echo ""
done

# ── Compute averages ──────────────────────────────────────────────────────────
AVG_SEQ=$(python3 -c "print(f'{$SUM_SEQ / $NRUNS:.2f}')")

declare -A AVG
for (( ii=0; ii<NUM_IMPLS; ii++ )); do
    for (( ti=0; ti<NUM_THREADS; ti++ )); do
        AVG["$ii:$ti"]=$(python3 -c "print(f'{${SUM[$ii:$ti]} / $NRUNS:.2f}')")
    done
done

# ── Get graph info from last sequential run ───────────────────────────────────
./pagerank_sequential "$GRAPH" > "$TMP" 2>&1
SEQ_VERTICES=$(grep "^Vertices:" "$TMP" | awk '{print $2}')
SEQ_EDGES=$(grep "^Vertices:" "$TMP" | awk '{print $4}')
SEQ_ITERS=$(grep "^Iterations:" "$TMP" | awk '{print $2}')

# ── Extract iteration counts (deterministic: same value every trial/thread) ───
# Run each impl once at T=1. pagerank_combined has no Iterations: line → N/A.
declare -A ITERS
for (( ii=0; ii<NUM_IMPLS; ii++ )); do
    BIN="${IMPLS[$ii]}"
    OMP_NUM_THREADS=1 ./"$BIN" "$GRAPH" > "$TMP" 2>&1
    if [[ "$BIN" == "pagerank_combined" ]]; then
        ITERS["$ii"]="N/A"
    else
        ITERS["$ii"]=$(grep "^Iterations:" "$TMP" | awk '{print $2}')
    fi
done

# ── Build report ──────────────────────────────────────────────────────────────
{
printf "================================================================\n"
printf "  PageRank Thread-Sweep Benchmark  (averaged over %s trials)\n" "$NRUNS"
printf "  Graph     : %s\n" "$GRAPH"
printf "  Vertices  : %s    Edges: %s\n" "$SEQ_VERTICES" "$SEQ_EDGES"
printf "  Timestamp : %s\n" "$TIMESTAMP"
printf "================================================================\n"
printf "\n"
printf "  Sequential baseline (avg): %s ms  (%s iters)\n" "$AVG_SEQ" "$SEQ_ITERS"
printf "\n"

# ── Timing table (avg ms) ─────────────────────────────────────────────────────
printf "  AVG TIME (ms)  [%s trials]\n" "$NRUNS"
printf "  %-24s  %6s" "Implementation" "Iters"
for T in "${THREAD_COUNTS[@]}"; do printf "  %8s" "T=$T"; done
printf "\n"
printf "  %-24s  %6s" "------------------------" "------"
for _ in "${THREAD_COUNTS[@]}"; do printf "  %8s" "--------"; done
printf "\n"

for (( ii=0; ii<NUM_IMPLS; ii++ )); do
    printf "  %-24s  %6s" "${IMPL_LABELS[$ii]}" "${ITERS[$ii]:-N/A}"
    for (( ti=0; ti<NUM_THREADS; ti++ )); do
        printf "  %8s" "${AVG[$ii:$ti]}"
    done
    printf "\n"
done

printf "\n"

# ── Convergence verification ───────────────────────────────────────────────────
printf "  Iteration counts (deterministic — same across all trials and thread counts):\n"
printf "  %-30s %s\n" "Sequential:" "${SEQ_ITERS:-N/A}"
for (( ii=0; ii<NUM_IMPLS; ii++ )); do
    printf "  %-30s %s\n" "${IMPL_LABELS[$ii]}:" "${ITERS[$ii]:-N/A}"
done
printf "\n"
for (( ii=0; ii<NUM_IMPLS; ii++ )); do
    iters="${ITERS[$ii]:-0}"
    if [[ "$iters" == "200" ]]; then
        printf "  WARNING: %s hit MAX_ITER=200 — did NOT converge!\n" "${IMPLS[$ii]}"
    fi
done
if [[ "${SEQ_ITERS:-0}" == "200" ]]; then
    printf "  WARNING: pagerank_sequential hit MAX_ITER=200 — did NOT converge!\n"
fi

printf "\n"

# ── Speedup table (vs avg sequential) ─────────────────────────────────────────
printf "  AVG SPEEDUP vs sequential  [%s trials]\n" "$NRUNS"
printf "  %-24s" "Implementation"
for T in "${THREAD_COUNTS[@]}"; do printf "  %8s" "T=$T"; done
printf "\n"
printf "  %-24s" "------------------------"
for _ in "${THREAD_COUNTS[@]}"; do printf "  %8s" "--------"; done
printf "\n"

for (( ii=0; ii<NUM_IMPLS; ii++ )); do
    printf "  %-24s" "${IMPL_LABELS[$ii]}"
    for (( ti=0; ti<NUM_THREADS; ti++ )); do
        SP=$(python3 -c "print(f'{float($AVG_SEQ)/float(${AVG[$ii:$ti]}):.2f}x')")
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
printf "implementation,threads,avg_time_ms,speedup_vs_seq,trials\n"
printf "sequential,1,%s,1.00,%s\n" "$AVG_SEQ" "$NRUNS"
for (( ii=0; ii<NUM_IMPLS; ii++ )); do
    for (( ti=0; ti<NUM_THREADS; ti++ )); do
        T=${THREAD_COUNTS[$ti]}
        A="${AVG[$ii:$ti]}"
        SP=$(python3 -c "print(f'{float($AVG_SEQ)/float($A):.4f}')")
        printf "%s,%s,%s,%s,%s\n" "${IMPLS[$ii]}" "$T" "$A" "$SP" "$NRUNS"
    done
done
} > "$CSVFILE"

echo ""
echo "CSV saved to: $CSVFILE"

