#!/usr/bin/env bash
# benchmark_final.sh
# Multi-graph thread-sweep benchmark: 5 trials per graph across 4 hardcoded
# graphs. Focuses on paper1, improved_3 (adaptive), improved_3_atomic,
# improved_3_local to isolate the accumulator mode effect.
#
# Extra sections vs benchmark_avg.sh:
#   - "Preprocessing vs Iteration Cost" per graph (DBG/Partition/Scatter times)
#   - "Accumulator Mode Comparison" showing adaptive vs forced-atomic vs
#     forced-local side by side at each thread count
#
# Usage: ./benchmark_final.sh
# Saves to results/benchmark_final_TIMESTAMP.{txt,csv}

set -euo pipefail

NRUNS=5
RESULTS_DIR="results"
mkdir -p "$RESULTS_DIR"

TIMESTAMP=$(date "+%Y-%m-%d_%H-%M-%S")
OUTFILE="$RESULTS_DIR/benchmark_final_${TIMESTAMP}.txt"
CSVFILE="$RESULTS_DIR/benchmark_final_${TIMESTAMP}.csv"

THREAD_COUNTS=(1 2 4 8 16 24)

GRAPHS=(
    "data/soc-pokec-relationships.txt"
    "data/soc-LiveJournal1.txt"
    "data/com-orkut.txt"
    "data/indochina-2004.txt"
)
GRAPH_LABELS=(
    "Pokec"
    "LiveJournal"
    "Orkut"
    "Indochina-2004"
)

IMPLS=(
    "pagerank_paper1"
    "pagerank_paper1_improved_3"
    "pagerank_paper1_improved_3_atomic"
    "pagerank_paper1_improved_3_local"
)
IMPL_LABELS=(
    "Paper1 (baseline)   "
    "Improved3 (adaptive)"
    "Improved3 (atomic)  "
    "Improved3 (local)   "
)

# Indices into IMPLS for the three accumulator variants (used in the
# Accumulator Mode Comparison section)
IDX_ADAPTIVE=1
IDX_ATOMIC=2
IDX_LOCAL=3

NUM_GRAPHS=${#GRAPHS[@]}
NUM_IMPLS=${#IMPLS[@]}
NUM_THREADS=${#THREAD_COUNTS[@]}

# ── Accumulators ──────────────────────────────────────────────────────────────
# Timing sums:    SUM["gi:ii:ti"]  -> total ms across NRUNS trials
# Sequential sums: SUM_SEQ["gi"]  -> total ms across NRUNS trials
declare -A SUM
declare -A SUM_SEQ

# Iteration counts (deterministic — extracted once from T=1 run post-trials)
declare -A ITERS        # key: "gi:ii"  parallel impls
declare -A ITERS_SEQ    # key: "gi"     sequential baseline

# Graph info
declare -A G_VERTICES   # key: "gi"
declare -A G_EDGES      # key: "gi"

# Preprocessing metrics from improved_3 at T=1
declare -A PRE_DBG      # key: "gi"
declare -A PRE_PART     # key: "gi"
declare -A PRE_TOTAL    # key: "gi"
declare -A AVG_SCATTER  # key: "gi"

# Initialize sums to 0
for (( gi=0; gi<NUM_GRAPHS; gi++ )); do
    SUM_SEQ["$gi"]=0
    for (( ii=0; ii<NUM_IMPLS; ii++ )); do
        for (( ti=0; ti<NUM_THREADS; ti++ )); do
            SUM["$gi:$ii:$ti"]=0
        done
    done
done

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

echo "Graphs    : ${#GRAPHS[@]}"
echo "Trials    : $NRUNS"
echo "Threads   : ${THREAD_COUNTS[*]}"
echo ""

# ── Run all trials ────────────────────────────────────────────────────────────
for (( gi=0; gi<NUM_GRAPHS; gi++ )); do
    GRAPH="${GRAPHS[$gi]}"
    GLABEL="${GRAPH_LABELS[$gi]}"

    if [[ ! -f "$GRAPH" ]]; then
        echo "WARNING: $GRAPH not found — skipping $GLABEL"
        echo ""
        continue
    fi

    echo "════════════════════════════════════════════════════"
    echo "  Graph $((gi+1))/${NUM_GRAPHS}: $GLABEL"
    echo "  File : $GRAPH"
    echo "════════════════════════════════════════════════════"

    for (( run=1; run<=NRUNS; run++ )); do
        echo "  === Trial $run / $NRUNS ==="

        # Sequential baseline
        printf "    %-36s ... " "pagerank_sequential"
        ./pagerank_sequential "$GRAPH" > "$TMP" 2>&1
        MS=$(grep "^Time:" "$TMP" | awk '{print $2}')
        SUM_SEQ["$gi"]=$(python3 -c "print(${SUM_SEQ[$gi]} + float('$MS'))")
        echo "${MS} ms"

        # Parallel implementations at each thread count
        for (( ti=0; ti<NUM_THREADS; ti++ )); do
            T=${THREAD_COUNTS[$ti]}
            for (( ii=0; ii<NUM_IMPLS; ii++ )); do
                BIN="${IMPLS[$ii]}"
                printf "    T=%-2s  %-36s ... " "$T" "$BIN"
                OMP_NUM_THREADS=$T ./"$BIN" "$GRAPH" > "$TMP" 2>&1
                MS=$(grep "^Time:" "$TMP" | awk '{print $2}')
                SUM["$gi:$ii:$ti"]=$(python3 -c "print(${SUM[$gi:$ii:$ti]} + float('$MS'))")
                echo "${MS} ms"
            done
        done
        echo ""
    done
done

# ── Compute averages ──────────────────────────────────────────────────────────
declare -A AVG_SEQ
declare -A AVG

for (( gi=0; gi<NUM_GRAPHS; gi++ )); do
    [[ ! -f "${GRAPHS[$gi]}" ]] && continue
    AVG_SEQ["$gi"]=$(python3 -c "print(f'{${SUM_SEQ[$gi]} / $NRUNS:.2f}')")
    for (( ii=0; ii<NUM_IMPLS; ii++ )); do
        for (( ti=0; ti<NUM_THREADS; ti++ )); do
            AVG["$gi:$ii:$ti"]=$(python3 -c "print(f'{${SUM[$gi:$ii:$ti]} / $NRUNS:.2f}')")
        done
    done
done

# ── Extract metadata, iteration counts, and preprocessing metrics ─────────────
# One fresh T=1 run per impl per graph (deterministic — same as any trial).
# The improved_3 T=1 run also yields DBG/Partition/Total/Avg-Scatter metrics.
echo ""
echo "Extracting iteration counts and preprocessing metrics..."

for (( gi=0; gi<NUM_GRAPHS; gi++ )); do
    GRAPH="${GRAPHS[$gi]}"
    [[ ! -f "$GRAPH" ]] && continue

    # Sequential: graph info + iters
    ./pagerank_sequential "$GRAPH" > "$TMP" 2>&1
    G_VERTICES["$gi"]=$(grep "^Vertices:" "$TMP" | awk '{print $2}')
    G_EDGES["$gi"]=$(grep "^Vertices:" "$TMP" | awk '{print $4}')
    ITERS_SEQ["$gi"]=$(grep "^Iterations:" "$TMP" | awk '{print $2}')

    # Parallel impls: iters from T=1 run
    for (( ii=0; ii<NUM_IMPLS; ii++ )); do
        BIN="${IMPLS[$ii]}"
        OMP_NUM_THREADS=1 ./"$BIN" "$GRAPH" > "$TMP" 2>&1
        ITERS["$gi:$ii"]=$(grep "^Iterations:" "$TMP" | awk '{print $2}')

        # Additional preprocessing metrics from improved_3
        if [[ "$BIN" == "pagerank_paper1_improved_3" ]]; then
            PRE_DBG["$gi"]=$(grep   "^Preprocess-DBG:"        "$TMP" | awk '{print $2}')
            PRE_PART["$gi"]=$(grep  "^Preprocess-Partition:"  "$TMP" | awk '{print $2}')
            PRE_TOTAL["$gi"]=$(grep "^Preprocess-Total:"      "$TMP" | awk '{print $2}')
            AVG_SCATTER["$gi"]=$(grep "^Avg-Scatter-Per-Iter:" "$TMP" | awk '{print $2}')
        fi
    done
done

# ── Build report ──────────────────────────────────────────────────────────────
{
printf "================================================================\n"
printf "  Final PageRank Benchmark  (NRUNS=%s per graph)\n" "$NRUNS"
printf "  Timestamp : %s\n" "$TIMESTAMP"
printf "  Threads   : %s\n" "${THREAD_COUNTS[*]}"
printf "  Graphs    : %s\n" "${GRAPH_LABELS[*]}"
printf "================================================================\n"

for (( gi=0; gi<NUM_GRAPHS; gi++ )); do
    GRAPH="${GRAPHS[$gi]}"
    GLABEL="${GRAPH_LABELS[$gi]}"

    if [[ ! -f "$GRAPH" ]]; then
        printf "\n  [SKIP] %s (%s) — file not found\n" "$GLABEL" "$GRAPH"
        continue
    fi

    # ─────────────────────────────────────────────────────────────────────────
    printf "\n"
    printf "════════════════════════════════════════════════════════════════\n"
    printf "  Graph : %-20s\n" "$GLABEL"
    printf "  File  : %s\n"    "$GRAPH"
    printf "  V=%-10s  E=%s\n" "${G_VERTICES[$gi]:-?}" "${G_EDGES[$gi]:-?}"
    printf "  Sequential baseline (avg): %s ms  (%s iters)\n" \
        "${AVG_SEQ[$gi]:-?}" "${ITERS_SEQ[$gi]:-?}"
    printf "════════════════════════════════════════════════════════════════\n"

    # ── Timing table ──────────────────────────────────────────────────────────
    printf "\n  AVG TIME (ms)  [%s trials]\n" "$NRUNS"
    printf "  %-24s  %6s" "Implementation" "Iters"
    for T in "${THREAD_COUNTS[@]}"; do printf "  %8s" "T=$T"; done
    printf "\n"
    printf "  %-24s  %6s" "------------------------" "------"
    for _ in "${THREAD_COUNTS[@]}"; do printf "  %8s" "--------"; done
    printf "\n"

    for (( ii=0; ii<NUM_IMPLS; ii++ )); do
        printf "  %-24s  %6s" "${IMPL_LABELS[$ii]}" "${ITERS[$gi:$ii]:-N/A}"
        for (( ti=0; ti<NUM_THREADS; ti++ )); do
            printf "  %8s" "${AVG[$gi:$ii:$ti]:-?}"
        done
        printf "\n"
    done

    # ── Convergence verification ───────────────────────────────────────────────
    printf "\n  Iteration counts (deterministic):\n"
    printf "  %-34s %s\n" "Sequential:" "${ITERS_SEQ[$gi]:-N/A}"
    for (( ii=0; ii<NUM_IMPLS; ii++ )); do
        iters="${ITERS[$gi:$ii]:-0}"
        warn=""
        [[ "$iters" == "200" ]] && warn="  *** DID NOT CONVERGE ***"
        printf "  %-34s %s%s\n" \
            "${IMPL_LABELS[$ii]}:" "${ITERS[$gi:$ii]:-N/A}" "$warn"
    done
    if [[ "${ITERS_SEQ[$gi]:-0}" == "200" ]]; then
        printf "  WARNING: pagerank_sequential hit MAX_ITER=200 — did NOT converge!\n"
    fi

    # ── Speedup table ─────────────────────────────────────────────────────────
    printf "\n  AVG SPEEDUP vs sequential  [%s trials]\n" "$NRUNS"
    printf "  %-24s" "Implementation"
    for T in "${THREAD_COUNTS[@]}"; do printf "  %8s" "T=$T"; done
    printf "\n"
    printf "  %-24s" "------------------------"
    for _ in "${THREAD_COUNTS[@]}"; do printf "  %8s" "--------"; done
    printf "\n"

    for (( ii=0; ii<NUM_IMPLS; ii++ )); do
        printf "  %-24s" "${IMPL_LABELS[$ii]}"
        for (( ti=0; ti<NUM_THREADS; ti++ )); do
            SP=$(python3 -c "print(f'{float(${AVG_SEQ[$gi]})/float(${AVG[$gi:$ii:$ti]}):.2f}x')")
            printf "  %8s" "$SP"
        done
        printf "\n"
    done

    # ── Preprocessing vs Iteration Cost ───────────────────────────────────────
    printf "\n  ┌─────────────────────────────────────────────────────────┐\n"
    printf   "  │  Preprocessing vs Iteration Cost  (improved_3, T=1)    │\n"
    printf   "  └─────────────────────────────────────────────────────────┘\n"
    printf "  %-32s %10s\n" "Metric" "Value"
    printf "  %-32s %10s\n" "--------------------------------" "----------"
    printf "  %-32s %9s ms\n" "DBG reordering time:"         "${PRE_DBG[$gi]:-N/A}"
    printf "  %-32s %9s ms\n" "Edge-balanced partition time:" "${PRE_PART[$gi]:-N/A}"
    printf "  %-32s %9s ms\n" "Total preprocessing time:"    "${PRE_TOTAL[$gi]:-N/A}"
    printf "  %-32s %9s ms\n" "Avg scatter time per iter:"   "${AVG_SCATTER[$gi]:-N/A}"

    if [[ -n "${PRE_TOTAL[$gi]:-}" && -n "${AVG_SCATTER[$gi]:-}" ]]; then
        RATIO=$(python3 -c "
sc = float('${AVG_SCATTER[$gi]}')
pt = float('${PRE_TOTAL[$gi]}')
print('N/A' if sc == 0 else f'{pt/sc:.1f}')
")
        printf "  %-32s %9s iters\n" "Ratio (preprocess/scatter):" "$RATIO"
        printf "  (preprocessing equivalent to %s scatter iterations)\n" "$RATIO"
    fi

    # ── Accumulator Mode Comparison ───────────────────────────────────────────
    printf "\n  ┌─────────────────────────────────────────────────────────┐\n"
    printf   "  │  Accumulator Mode Comparison  (avg ms, %s trials)%s│\n" \
        "$NRUNS" "        "
    printf   "  └─────────────────────────────────────────────────────────┘\n"
    printf "  %-24s" "Mode"
    for T in "${THREAD_COUNTS[@]}"; do printf "  %8s" "T=$T"; done
    printf "\n"
    printf "  %-24s" "------------------------"
    for _ in "${THREAD_COUNTS[@]}"; do printf "  %8s" "--------"; done
    printf "\n"

    ACC_LABELS=("Adaptive (hybrid)   " "Forced atomic       " "Forced local        ")
    ACC_IDXS=($IDX_ADAPTIVE $IDX_ATOMIC $IDX_LOCAL)
    for (( ai=0; ai<3; ai++ )); do
        ii=${ACC_IDXS[$ai]}
        printf "  %-24s" "${ACC_LABELS[$ai]}"
        for (( ti=0; ti<NUM_THREADS; ti++ )); do
            printf "  %8s" "${AVG[$gi:$ii:$ti]:-?}"
        done
        printf "\n"
    done

    # Speedup of adaptive over atomic and local at each thread count
    printf "\n  Adaptive speedup vs forced modes:\n"
    printf "  %-24s" "vs Forced atomic"
    for (( ti=0; ti<NUM_THREADS; ti++ )); do
        SP=$(python3 -c "
a=float('${AVG[$gi:$IDX_ATOMIC:$ti]}')
b=float('${AVG[$gi:$IDX_ADAPTIVE:$ti]}')
print('N/A' if b==0 else f'{a/b:.2f}x')
")
        printf "  %8s" "$SP"
    done
    printf "\n"
    printf "  %-24s" "vs Forced local"
    for (( ti=0; ti<NUM_THREADS; ti++ )); do
        SP=$(python3 -c "
a=float('${AVG[$gi:$IDX_LOCAL:$ti]}')
b=float('${AVG[$gi:$IDX_ADAPTIVE:$ti]}')
print('N/A' if b==0 else f'{a/b:.2f}x')
")
        printf "  %8s" "$SP"
    done
    printf "\n"

done  # end graph loop

printf "\n"
printf "================================================================\n"
printf "  Full report : %s\n" "$OUTFILE"
printf "  CSV         : %s\n" "$CSVFILE"
printf "================================================================\n"
} | tee "$OUTFILE"

# ── Write CSV ─────────────────────────────────────────────────────────────────
{
printf "graph,implementation,threads,avg_time_ms,speedup_vs_seq,trials\n"
for (( gi=0; gi<NUM_GRAPHS; gi++ )); do
    [[ ! -f "${GRAPHS[$gi]}" ]] && continue
    GLABEL="${GRAPH_LABELS[$gi]}"
    printf "%s,sequential,1,%s,1.0000,%s\n" \
        "$GLABEL" "${AVG_SEQ[$gi]}" "$NRUNS"
    for (( ii=0; ii<NUM_IMPLS; ii++ )); do
        for (( ti=0; ti<NUM_THREADS; ti++ )); do
            T=${THREAD_COUNTS[$ti]}
            A="${AVG[$gi:$ii:$ti]}"
            SP=$(python3 -c "print(f'{float(${AVG_SEQ[$gi]})/float($A):.4f}')")
            printf "%s,%s,%s,%s,%s,%s\n" \
                "$GLABEL" "${IMPLS[$ii]}" "$T" "$A" "$SP" "$NRUNS"
        done
    done
done
} > "$CSVFILE"

echo ""
echo "CSV saved to: $CSVFILE"

