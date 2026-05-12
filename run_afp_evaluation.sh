#!/bin/bash
# AFP Evaluation Benchmark Runner
# Runs Mirabelle abduct action on all goals in the session

set -e

ISABELLE_HOME="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${ISABELLE_HOME}/mirabelle_afp_evaluation"

# Configuration parameters
TIMEOUT="${1:-60}"           # Timeout per goal (seconds)
DEPTH="${2:-1}"              # Abduction depth
TEST_PREMISES="${3:-true}"   # Test if abducts imply dropped premise
TEST_TIMEOUT="${4:-10}"      # Timeout for premise testing

echo "=============================================="
echo "AFP Evaluation Benchmark"
echo "=============================================="
echo "Timeout: ${TIMEOUT}s"
echo "Depth: ${DEPTH}"
echo "Test premises: ${TEST_PREMISES}"
echo "Test timeout: ${TEST_TIMEOUT}s"
echo "Output: ${OUTPUT_DIR}"
echo "=============================================="

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Build the session first
echo ""
echo "Building Abduct_AFP_Evaluation session..."
./bin/isabelle build -d src/Abduct Abduct_AFP_Evaluation 2>&1 | tee "${OUTPUT_DIR}/build.log" || {
    echo "Warning: Some theories may have failed to build"
}

# Run mirabelle
echo ""
echo "Running Mirabelle..."
echo ""

./bin/isabelle mirabelle \
    -A "abduct[timeout=${TIMEOUT},depth=${DEPTH},test_premises=${TEST_PREMISES},test_timeout=${TEST_TIMEOUT}]" \
    -O "${OUTPUT_DIR}" \
    -d src/Abduct \
    -t "${TIMEOUT}" \
    -j 32 \
    Abduct_AFP_Evaluation 2>&1 | tee "${OUTPUT_DIR}/mirabelle.out"

echo ""
echo "=============================================="
echo "Evaluation complete!"
echo "=============================================="

# Summary
if [ -f "${OUTPUT_DIR}/mirabelle.log" ]; then
    echo ""
    echo "Summary:"
    echo "  Total goals processed: $(grep -c "DROPPED PREMISE" "${OUTPUT_DIR}/mirabelle.log" 2>/dev/null || echo 0)"
    echo "  Goals with abducts: $(grep -c "ABDUCTS FOUND ([1-9]" "${OUTPUT_DIR}/mirabelle.log" 2>/dev/null || echo 0)"
    echo "  Total abducts found: $(grep -oE "ABDUCTS FOUND \([0-9]+\)" "${OUTPUT_DIR}/mirabelle.log" 2>/dev/null | grep -oE "[0-9]+" | awk '{s+=$1} END {print s+0}')"
fi

echo ""
echo "Results saved to: ${OUTPUT_DIR}"
echo "  - mirabelle.log: Detailed results"
echo "  - mirabelle.out: Console output"
echo "  - build.log: Session build log"
