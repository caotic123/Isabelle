#!/bin/bash
# AFP Abduction Benchmark Runner
# Runs Mirabelle abduct action, optionally restricted to one theory.

set -euo pipefail

ISABELLE_HOME="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${ISABELLE_HOME}/mirabelle_benchmark}"
SESSION_DIR="${SESSION_DIR:-src/Abduct}"
TARGET_SESSION="${TARGET_SESSION:-Abduct_AFP_Evaluation}"

THEORY_INPUT="${1:-}"    # Optional theory name/path for Mirabelle -T
TIMEOUT="${2:-60}"       # Default 60 seconds per action
DEPTH="${3:-1}"          # Default depth 1
MAX_CALLS="${4:-0}"      # Default 0 (unlimited), set to limit goals
TEST_PREMISES="${5:-false}"
TEST_TIMEOUT="${6:-10}"
MIRABELLE_JOBS="${MIRABELLE_JOBS:-16}"
BENCHMARK_DRY_RUN="${BENCHMARK_DRY_RUN:-false}"

case "${BENCHMARK_DRY_RUN}" in
    true|false) ;;
    *)
        echo "Error: BENCHMARK_DRY_RUN must be true or false, got '${BENCHMARK_DRY_RUN}'" >&2
        exit 1
        ;;
esac

MIRABELLE_THEORY_ARGS=()
THEORY="${THEORY_INPUT}"
if [[ "${THEORY}" == *.thy ]]; then
    THEORY="$(basename "${THEORY}" .thy)"
fi
if [ -n "${THEORY}" ] && [ "${THEORY}" != "-" ] && [ "${THEORY}" != "all" ]; then
    MIRABELLE_THEORY_ARGS=("-T" "${THEORY}")
fi

echo "=============================================="
echo "Abduction Benchmark"
echo "=============================================="
if [ "${#MIRABELLE_THEORY_ARGS[@]}" -gt 0 ]; then
    echo "Theory: ${THEORY}"
else
    echo "Theory: all theories in ${TARGET_SESSION}"
fi
echo "Timeout: ${TIMEOUT}s"
echo "Depth: ${DEPTH}"
echo "Max calls: ${MAX_CALLS} (0=unlimited)"
echo "Test premises: ${TEST_PREMISES}"
echo "Test timeout: ${TEST_TIMEOUT}s"
echo "Mirabelle jobs: ${MIRABELLE_JOBS}"
echo "Session dir: ${SESSION_DIR}"
echo "Target session: ${TARGET_SESSION}"
echo "Output: ${OUTPUT_DIR}"
echo "Dry run: ${BENCHMARK_DRY_RUN}"
echo "=============================================="

mkdir -p "${OUTPUT_DIR}"

echo ""
echo "Running Mirabelle..."
echo ""

MIRABELLE_COMMAND=(
    ./bin/isabelle mirabelle
    -A "abduct[timeout=${TIMEOUT},depth=${DEPTH},test_premises=${TEST_PREMISES},test_timeout=${TEST_TIMEOUT}]" \
    -O "${OUTPUT_DIR}" \
    -d "${SESSION_DIR}" \
    "${MIRABELLE_THEORY_ARGS[@]}" \
    -t "${TIMEOUT}" \
    -m "${MAX_CALLS}" \
    -j "${MIRABELLE_JOBS}" \
    "${TARGET_SESSION}"
)

if [ "${BENCHMARK_DRY_RUN}" = true ]; then
    printf 'Dry-run command:'
    printf ' %q' "${MIRABELLE_COMMAND[@]}"
    printf '\n'
    exit 0
fi

"${MIRABELLE_COMMAND[@]}" 2>&1 | tee "${OUTPUT_DIR}/benchmark.out"

echo ""
echo "=============================================="
echo "Benchmark complete."
echo "Results in: ${OUTPUT_DIR}/mirabelle.log"
echo "=============================================="

if [ -f "${OUTPUT_DIR}/mirabelle.log" ]; then
    total_goals=$(grep -c "DROPPED PREMISE" "${OUTPUT_DIR}/mirabelle.log" 2>/dev/null || true)
    goals_with_abducts=$(grep -c "ABDUCTS FOUND ([1-9]" "${OUTPUT_DIR}/mirabelle.log" 2>/dev/null || true)
    total_abducts=$({ grep -oE "ABDUCTS FOUND \([0-9]+\)" "${OUTPUT_DIR}/mirabelle.log" 2>/dev/null || true; } | { grep -oE "[0-9]+" || true; } | awk '{s+=$1} END {print s+0}')

    echo ""
    echo "Summary:"
    echo "  Total goals processed: ${total_goals:-0}"
    echo "  Goals with abducts: ${goals_with_abducts:-0}"
    echo "  Total abducts found: ${total_abducts:-0}"
fi
