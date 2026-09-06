#!/usr/bin/env bash
# plot_pod.sh - generate gnuplot PNG(s) from k8s metrics CSV
#
# Usage:
#   Single pod:
#     ./plot_pod.sh <namespace> <pod> [input_csv] [output_dir] [cpu_min] [cpu_max] [mem_min] [mem_max]
#
#   All pods in a namespace:
#     ./plot_pod.sh --all <namespace> [input_csv] [output_dir] [asc|desc] [cpu_min] [cpu_max] [mem_min] [mem_max]
#
# Notes:
#  - CPU limits accepted: "400m", "0.4", "400" (millicores, cores, or plain millicores)
#    Parsed to numeric millicores (passed to gnuplot as cpu_min/cpu_max).
#  - Memory limits accepted: "1024Mi", "1Gi", "2048" (Mi if plain numeric)
#    Parsed to numeric Mi (passed to gnuplot as mem_min/mem_max).
#  - Requires gnuplot and plot_pod.gp (updated to accept cpu_min/cpu_max/mem_min/mem_max)
#
set -euo pipefail

usage() {
  cat <<EOF
Usage:
  Single pod:
    $0 <namespace> <pod> [input_csv] [output_dir] [cpu_min] [cpu_max] [mem_min] [mem_max]

  All pods in namespace:
    $0 --all <namespace> [input_csv] [output_dir] [asc|desc] [cpu_min] [cpu_max] [mem_min] [mem_max]

Defaults:
  input_csv   = k8s_metrics.csv
  output_dir  = . (current directory)
  order       = desc (most recent first) when using --all

Examples:
  ./plot_pod.sh kube-cert-manager cert-manager-6546d94fd7-4v8pr
  ./plot_pod.sh kube-cert-manager cert-manager-6546d94fd7-4v8pr k8s_metrics.csv ./out 0 400m 0 1024Mi
  ./plot_pod.sh --all kube-cert-manager k8s_metrics.csv ./out desc 0 400m 0 1024Mi
EOF
  exit 1
}

if [ "$#" -lt 1 ]; then
  usage
fi

MODE="single"
if [ "$1" = "--all" ]; then
  MODE="all"
  shift
fi

# defaults
INPUT_CSV="k8s_metrics.csv"
OUTPUT_DIR="."
ORDER="desc"   # for --all mode

if [ "$MODE" = "single" ]; then
  if [ "$#" -lt 2 ]; then usage; fi
  NAMESPACE="$1"
  POD="$2"
  INPUT_CSV="${3:-$INPUT_CSV}"
  OUTPUT_DIR="${4:-$OUTPUT_DIR}"
  CPU_MIN_RAW="${5:-}"
  CPU_MAX_RAW="${6:-}"
  MEM_MIN_RAW="${7:-}"
  MEM_MAX_RAW="${8:-}"
else
  if [ "$#" -lt 1 ]; then usage; fi
  NAMESPACE="$1"
  INPUT_CSV="${2:-$INPUT_CSV}"
  OUTPUT_DIR="${3:-$OUTPUT_DIR}"
  ORDER="${4:-$ORDER}"
  if [ "$ORDER" != "asc" ] && [ "$ORDER" != "desc" ]; then
    echo "Invalid order: $ORDER (must be 'asc' or 'desc')" >&2
    exit 2
  fi
  CPU_MIN_RAW="${5:-}"
  CPU_MAX_RAW="${6:-}"
  MEM_MIN_RAW="${7:-}"
  MEM_MAX_RAW="${8:-}"
fi

GNUPLOT_SCRIPT="${GNUPLOT_SCRIPT:-plot_pod.gp}"

# sanity checks
if ! command -v gnuplot >/dev/null 2>&1; then
  echo "ERROR: gnuplot not found in PATH. Install gnuplot and retry." >&2
  exit 2
fi
if [ ! -f "$GNUPLOT_SCRIPT" ]; then
  echo "ERROR: gnuplot script '$GNUPLOT_SCRIPT' not found. Place plot_pod.gp in this directory or set GNUPLOT_SCRIPT env." >&2
  exit 3
fi
if [ ! -f "$INPUT_CSV" ]; then
  echo "ERROR: input CSV '$INPUT_CSV' not found." >&2
  exit 4
fi

mkdir -p "$OUTPUT_DIR"

# ---------------- helpers -----------------
escape_for_gnuplot() { printf "%s" "$1" | sed "s/'/'\\\\''/g"; }

# parse CPU string to millicores (numeric). Accept "400m", "0.4", "400"
parse_cpu_to_millicores() {
  local s; s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' || true)"
  if [ -z "$s" ]; then
    printf ""
    return
  fi
  if [[ "$s" =~ ^([0-9]+)m$ ]]; then
    printf "%s" "${BASH_REMATCH[1]}"
    return
  fi
  if [[ "$s" =~ ^([0-9]*\.[0-9]+|[0-9]+)$ ]]; then
    # decimal -> if contains dot treat as cores -> multiply by 1000
    if [[ "$s" == *.* ]]; then
      awk -v v="$s" 'BEGIN{printf "%.6f", v*1000}'
    else
      # integer without unit: ambiguous; treat as millicores
      printf "%s" "$s"
    fi
    return
  fi
  # unknown -> empty
  printf ""
}

# parse memory to Mi (numeric). Accept Ki/Mi/Gi/Ti or plain numeric (Mi)
parse_mem_to_Mi() {
  local s; s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' || true)"
  if [ -z "$s" ]; then
    printf ""
    return
  fi
  if [[ "$s" =~ ^([0-9]*\.[0-9]+|[0-9]+)ki$ ]]; then
    awk -v v="${BASH_REMATCH[1]}" 'BEGIN{printf "%.6f", v/1024.0}'
    return
  fi
  if [[ "$s" =~ ^([0-9]*\.[0-9]+|[0-9]+)mi$ ]]; then
    printf "%s" "${BASH_REMATCH[1]}"
    return
  fi
  if [[ "$s" =~ ^([0-9]*\.[0-9]+|[0-9]+)gi$ ]]; then
    awk -v v="${BASH_REMATCH[1]}" 'BEGIN{printf "%.6f", v*1024.0}'
    return
  fi
  if [[ "$s" =~ ^([0-9]*\.[0-9]+|[0-9]+)ti$ ]]; then
    awk -v v="${BASH_REMATCH[1]}" 'BEGIN{printf "%.6f", v*1024.0*1024.0}'
    return
  fi
  if [[ "$s" =~ ^([0-9]*\.[0-9]+|[0-9]+)$ ]]; then
    # plain numeric -> assume Mi
    printf "%s" "${BASH_REMATCH[1]}"
    return
  fi
  printf ""
}

# Build optional gnuplot -e fragment for axis limits
CPU_MIN_PARSED="$(parse_cpu_to_millicores "$CPU_MIN_RAW" || true)"
CPU_MAX_PARSED="$(parse_cpu_to_millicores "$CPU_MAX_RAW" || true)"
MEM_MIN_PARSED="$(parse_mem_to_Mi "$MEM_MIN_RAW" || true)"
MEM_MAX_PARSED="$(parse_mem_to_Mi "$MEM_MAX_RAW" || true)"

build_limits_e() {
  local e=""
  if [ -n "$CPU_MIN_PARSED" ] && [ -n "$CPU_MAX_PARSED" ]; then
    e="${e}; cpu_min=${CPU_MIN_PARSED}; cpu_max=${CPU_MAX_PARSED}"
  fi
  if [ -n "$MEM_MIN_PARSED" ] && [ -n "$MEM_MAX_PARSED" ]; then
    e="${e}; mem_min=${MEM_MIN_PARSED}; mem_max=${MEM_MAX_PARSED}"
  fi
  printf "%s" "$e"
}

# run gnuplot safely for a single pod
run_gnuplot_for_pod() {
  local namespace="$1"; local pod="$2"; local output_file="$3"
  local e_vars; e_vars="$(build_limits_e)"
  local in_esc ns_esc pod_esc out_esc
  in_esc="$(escape_for_gnuplot "$INPUT_CSV")"
  ns_esc="$(escape_for_gnuplot "$namespace")"
  pod_esc="$(escape_for_gnuplot "$pod")"
  out_esc="$(escape_for_gnuplot "$output_file")"
  local GNUPLOT_E="input_file='${in_esc}'; namespace='${ns_esc}'; pod='${pod_esc}'; output_file='${out_esc}'${e_vars}"

  local GNUPLOT_LOG; GNUPLOT_LOG="$(mktemp -t gnuplot_log_XXXXXX.txt)"
  echo "  gnuplot -> ${output_file}"
  if gnuplot -e "$GNUPLOT_E" "$GNUPLOT_SCRIPT" 2> "$GNUPLOT_LOG"; then
    if [ -s "$output_file" ]; then
      echo "    created $(basename "$output_file") (size: $(stat -c%s "$output_file") bytes)"
      rm -f "$GNUPLOT_LOG" /tmp/__pod_plot.csv || true
      return 0
    else
      echo "ERROR: output file missing/empty: $output_file" >&2
      echo "Filtered CSV head (/tmp/__pod_plot.csv):"
      head -n 50 /tmp/__pod_plot.csv || true
      echo "Gnuplot stderr:"
      sed -n '1,200p' "$GNUPLOT_LOG" || true
      rm -f "$GNUPLOT_LOG"
      return 1
    fi
  else
    echo "ERROR: gnuplot failed for ${namespace}/${pod}" >&2
    echo "Filtered CSV head (/tmp/__pod_plot.csv):"
    head -n 50 /tmp/__pod_plot.csv || true
    echo "Gnuplot stderr:"
    sed -n '1,200p' "$GNUPLOT_LOG" || true
    rm -f "$GNUPLOT_LOG"
    return 2
  fi
}

# ---------------- single mode ----------------
TS=$(date +%Y%m%d%H%M%S)
if [ "$MODE" = "single" ]; then
  OUT_BASE="${NAMESPACE}_${POD}_${TS}.png"
  OUT_BASE_SAFE="$(printf '%s' "$OUT_BASE" | sed 's/[^A-Za-z0-9._-]/_/g')"
  OUTPUT_FILE="${OUTPUT_DIR%/}/${OUT_BASE_SAFE}"
  echo "Running plot for ${NAMESPACE}/${POD} -> ${OUTPUT_FILE}"
  run_gnuplot_for_pod "$NAMESPACE" "$POD" "$OUTPUT_FILE"
  exit $?
fi

# ---------------- --all mode ----------------
TMP_FILTERED="$(mktemp -t plot_pod_filtered_XXXXXX.csv)"
TMP_SORTED="$(mktemp -t plot_pod_sorted_XXXXXX.csv)"
POD_LIST_TMP="$(mktemp -t plot_pod_pods_XXXXXX.txt)"
cleanup() { rm -f "$TMP_FILTERED" "$TMP_SORTED" "$POD_LIST_TMP" /tmp/__pod_plot.csv || true; }
trap cleanup EXIT

echo "Filtering all rows for namespace: $NAMESPACE"
awk -F, -v ns="$NAMESPACE" 'NR==1{header=$0; next} $2==ns{print $0}' "$INPUT_CSV" > "$TMP_FILTERED"
if [ ! -s "$TMP_FILTERED" ]; then
  echo "No rows found for namespace '$NAMESPACE' in $INPUT_CSV" >&2
  exit 6
fi

if [ "$ORDER" = "asc" ]; then
  sort -t, -k1,1 "$TMP_FILTERED" > "$TMP_SORTED"
else
  sort -t, -k1,1r "$TMP_FILTERED" > "$TMP_SORTED"
fi

COMBINED_CSV="${OUTPUT_DIR%/}/${NAMESPACE}_all_${TS}.csv"
head -n 1 "$INPUT_CSV" > "$COMBINED_CSV"
cat "$TMP_SORTED" >> "$COMBINED_CSV"
echo "Wrote combined CSV -> $COMBINED_CSV (sorted: $ORDER)"

# Build pod list ordered by most recent sample (desc)
awk -F, -v ns="$NAMESPACE" '
NR>1 && $2==ns {
  pod=$3; ts=$1;
  if (pod in max) {
    if (ts > max[pod]) max[pod]=ts
  } else { max[pod]=ts }
}
END {
  for (p in max) print max[p] "," p
}
' "$INPUT_CSV" | sort -t, -k1,1r > "$POD_LIST_TMP"

if [ ! -s "$POD_LIST_TMP" ]; then
  echo "No pods found for namespace '$NAMESPACE' after processing $INPUT_CSV" >&2
  exit 7
fi

echo "Found $(wc -l < "$POD_LIST_TMP") pods in namespace '$NAMESPACE' (ordered by most recent sample)."

# Generate per-pod PNGs
while IFS=, read -r latest_ts pod; do
  SAFE_POD="$(printf '%s' "$pod" | sed 's/[^A-Za-z0-9._-]/_/g')"
  OUT_BASE="${NAMESPACE}_${SAFE_POD}_${TS}.png"
  OUTPUT_FILE="${OUTPUT_DIR%/}/${OUT_BASE}"
  echo "Plotting pod: ${pod} (latest: ${latest_ts}) -> ${OUTPUT_FILE}"
  run_gnuplot_for_pod "$NAMESPACE" "$pod" "$OUTPUT_FILE" || true
done < "$POD_LIST_TMP"

echo "All done. Combined CSV: $COMBINED_CSV"
exit 0
