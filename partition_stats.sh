#!/usr/bin/env bash
# partition_stats.sh
#
# Runs pagerank_paper1_improved_3 across multiple graphs and thread counts,
# captures the partition diagnostic output, and produces a human-readable
# summary table plus a CSV file.
#
# Prerequisites:
#   1. Compile the binary first:
#        g++ -O3 -fopenmp -o pagerank_paper1_improved_3 pagerank_paper1_improved_3.cpp
#   2. The binary must include the partition diagnostic print block that
#      emits lines matching:
#        "Partition summary:"
#        "  k             = <N>"
#        "  min edges     = <N>"
#        "  max edges     = <N>"
#        "  mean edges    = <F>"
#        "  stddev edges  = <F>"
#        "  imbalance (max/min)  = <F>"
#        "  imbalance (max/mean) = <F>"
#      (Added to pagerank_paper1_improved_3.cpp after the vertexToPart loop.)
#
# Usage:
#   ./partition_stats.sh
#
# Output:
#   results/partition_stats/stats_<TIMESTAMP>.txt   — human-readable report
#   results/partition_stats/stats_<TIMESTAMP>.csv   — CSV data

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

GRAPHS=(
    "data/web-Google.txt"
    "data/soc-LiveJournal1.txt"
    "data/soc-pokec-relationships.txt"
    "data/com-orkut.ungraph.txt"ps
    "data/twitter_combined.txt"
    "data/indochina-2004.txt"
)

THREAD_COUNTS=(1 2 4 8 16 24)

BINARY="./pagerank_paper1_improved_3"

RESULTS_DIR="results/partition_stats"
TIMESTAMP=$(date "+%Y-%m-%d_%H-%M-%S")
OUTFILE="${RESULTS_DIR}/stats_${TIMESTAMP}.txt"
CSVFILE="${RESULTS_DIR}/stats_${TIMESTAMP}.csv"

# ── Setup ────────────────────────────────────────────────────────────────────

mkdir -p "$RESULTS_DIR"

# Temp file for capturing binary output; cleaned up on exit
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# ── Validation ───────────────────────────────────────────────────────────────

if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: binary not found or not executable: $BINARY"
    echo ""
    echo "Compile it with:"
    echo "  g++ -O3 -fopenmp -o pagerank_paper1_improved_3 pagerank_paper1_improved_3.cpp"
    exit 1
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

# extract_field <label_regex> <file>
# Grabs the first numeric token after the matching label line.
extract_field() {
    local pattern="$1"
    local file="$2"
    grep -m1 "$pattern" "$file" | awk -F'= ' '{print $2}' | awk '{print $1}'
}

# pad_right <width> <string>
pad_right() {
    printf "%-${1}s" "$2"
}

# ── Data storage (parallel arrays keyed by run index) ────────────────────────

declare -a RUN_GRAPH RUN_THREADS RUN_VERTICES RUN_EDGES
declare -a RUN_K RUN_MIN RUN_MAX RUN_MEAN RUN_STD RUN_IMBAL_MM RUN_IMBAL_MN
RUN_IDX=0

# ── Main loop ────────────────────────────────────────────────────────────────

for GRAPH in "${GRAPHS[@]}"; do
    if [[ ! -f "$GRAPH" ]]; then
        echo "WARNING: graph file not found, skipping: $GRAPH"
        continue
    fi

    GNAME=$(basename "$GRAPH" .txt)

    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  Graph: $GRAPH"
    echo "════════════════════════════════════════════════════════════════"
    printf "  %-10s %-6s %-6s %-12s %-12s %-12s %-12s %-12s %-12s\n" \
        "Threads" "k" "min" "max" "mean" "std" "max/min" "max/mean" ""

    for T in "${THREAD_COUNTS[@]}"; do

        # Run binary; suppress non-zero exit so we can report gracefully
        if ! OMP_NUM_THREADS=$T "$BINARY" "$GRAPH" > "$TMP" 2>&1; then
            echo "  WARNING: binary exited non-zero for $GRAPH T=$T — skipping"
            continue
        fi

        # Parse graph metadata
        VERTICES=$(grep -m1 "^Vertices:" "$TMP" | awk '{print $2}')
        EDGES=$(grep -m1 "^Vertices:" "$TMP" | awk '{print $4}')

        # Parse partition summary block
        PART_K=$(extract_field "^  k " "$TMP")
        PART_MIN=$(extract_field "^  min edges" "$TMP")
        PART_MAX=$(extract_field "^  max edges" "$TMP")
        PART_MEAN=$(extract_field "^  mean edges" "$TMP")
        PART_STD=$(extract_field "^  stddev edges" "$TMP")
        PART_IMBAL_MM=$(grep -m1 "imbalance (max/min)" "$TMP" | awk -F'= ' '{print $2}' | awk '{print $1}')
        PART_IMBAL_MN=$(grep -m1 "imbalance (max/mean)" "$TMP" | awk -F'= ' '{print $2}' | awk '{print $1}')

        # One-line summary to terminal
        printf "  T=%-8s k=%-5s min=%-10s max=%-10s mean=%-10s std=%-10s max/min=%-10s max/mean=%-10s\n" \
            "$T" "${PART_K:-?}" "${PART_MIN:-?}" "${PART_MAX:-?}" \
            "${PART_MEAN:-?}" "${PART_STD:-?}" \
            "${PART_IMBAL_MM:-?}" "${PART_IMBAL_MN:-?}"

        # Store for final table and CSV
        RUN_GRAPH[$RUN_IDX]="$GNAME"
        RUN_THREADS[$RUN_IDX]="$T"
        RUN_VERTICES[$RUN_IDX]="${VERTICES:-?}"
        RUN_EDGES[$RUN_IDX]="${EDGES:-?}"
        RUN_K[$RUN_IDX]="${PART_K:-?}"
        RUN_MIN[$RUN_IDX]="${PART_MIN:-?}"
        RUN_MAX[$RUN_IDX]="${PART_MAX:-?}"
        RUN_MEAN[$RUN_IDX]="${PART_MEAN:-?}"
        RUN_STD[$RUN_IDX]="${PART_STD:-?}"
        RUN_IMBAL_MM[$RUN_IDX]="${PART_IMBAL_MM:-?}"
        RUN_IMBAL_MN[$RUN_IDX]="${PART_IMBAL_MN:-?}"
        (( RUN_IDX++ )) || true
    done
done

# ── Final summary tables (one per graph) ─────────────────────────────────────

{
printf "\n"
printf "================================================================\n"
printf "  Partition Statistics Summary  —  %s\n" "$TIMESTAMP"
printf "================================================================\n"

PREV_GRAPH=""
for (( i=0; i<RUN_IDX; i++ )); do
    G="${RUN_GRAPH[$i]}"

    # New graph — print header
    if [[ "$G" != "$PREV_GRAPH" ]]; then
        if [[ -n "$PREV_GRAPH" ]]; then printf "\n"; fi
        printf "\n  Graph: %s  (V=%s  E=%s)\n" \
            "$G" "${RUN_VERTICES[$i]}" "${RUN_EDGES[$i]}"
        printf "  %-8s  %-6s  %-12s  %-12s  %-12s  %-12s  %-12s  %-12s\n" \
            "Threads" "k" "min_edges" "max_edges" "mean_edges" "std_dev" \
            "imbal(max/min)" "imbal(max/mean)"
        printf "  %-8s  %-6s  %-12s  %-12s  %-12s  %-12s  %-12s  %-12s\n" \
            "--------" "------" "------------" "------------" "------------" \
            "------------" "------------" "------------"
        PREV_GRAPH="$G"

        # Find worst imbalance (max/min) across this graph's runs for asterisk
        WORST_MM=""
        WORST_MM_VAL=0
        for (( j=i; j<RUN_IDX; j++ )); do
            [[ "${RUN_GRAPH[$j]}" != "$G" ]] && break
            VAL="${RUN_IMBAL_MM[$j]}"
            if [[ "$VAL" != "?" ]] && \
               python3 -c "exit(0 if float('$VAL') > float('$WORST_MM_VAL') else 1)" 2>/dev/null; then
                WORST_MM_VAL="$VAL"
                WORST_MM="$j"
            fi
        done
    fi

    MARKER=""
    [[ -n "$WORST_MM" && "$i" == "$WORST_MM" ]] && MARKER=" *"

    printf "  %-8s  %-6s  %-12s  %-12s  %-12s  %-12s  %-12s  %-12s%s\n" \
        "${RUN_THREADS[$i]}" "${RUN_K[$i]}" \
        "${RUN_MIN[$i]}" "${RUN_MAX[$i]}" \
        "${RUN_MEAN[$i]}" "${RUN_STD[$i]}" \
        "${RUN_IMBAL_MM[$i]}" "${RUN_IMBAL_MN[$i]}" \
        "$MARKER"
done

printf "\n"
printf "  * = worst imbalance (max/min) for that graph\n"
printf "\n"
printf "  Full report : %s\n" "$OUTFILE"
printf "  CSV         : %s\n" "$CSVFILE"
printf "================================================================\n"
} | tee "$OUTFILE"

# ── CSV output ────────────────────────────────────────────────────────────────

{
printf "graph,threads,vertices,edges,k,min_edges,max_edges,mean_edges,std_dev,imbal_min,imbal_mean\n"
for (( i=0; i<RUN_IDX; i++ )); do
    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
        "${RUN_GRAPH[$i]}" "${RUN_THREADS[$i]}" \
        "${RUN_VERTICES[$i]}" "${RUN_EDGES[$i]}" \
        "${RUN_K[$i]}" "${RUN_MIN[$i]}" "${RUN_MAX[$i]}" \
        "${RUN_MEAN[$i]}" "${RUN_STD[$i]}" \
        "${RUN_IMBAL_MM[$i]}" "${RUN_IMBAL_MN[$i]}"
done
} > "$CSVFILE"

echo ""
echo "CSV saved to: $CSVFILE"
