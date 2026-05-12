#!/usr/bin/env bash
# Smoke checks for the Docker artifact.

set -euo pipefail

ISABELLE_HOME="${ISABELLE_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "${ISABELLE_HOME}"

MODE="${1:-all}"
THEORY_FILE="${JEDIT_SMOKE_THEORY:-src/Abduct/Lambda/Lambda_Calculus_Abduction.thy}"
LOGIC="${JEDIT_SMOKE_LOGIC:-Abduct_Lambda_Calculus}"
ISABELLE_BUILD_ARGS="${ISABELLE_BUILD_ARGS:--j1 -o threads=1}"
JEDIT_SMOKE_SECONDS="${JEDIT_SMOKE_SECONDS:-30}"
JEDIT_SMOKE_LOG="${JEDIT_SMOKE_LOG:-/tmp/isabelle-jedit-smoke.log}"
CVC5_SMOKE="${CVC5:-${ISABELLE_HOME}/contrib/cvc5/bin/cvc5}"

usage() {
    cat <<EOF
Usage: $0 [all|benchmark|build|jedit]

Environment:
  JEDIT_SMOKE_THEORY    Theory file to open in jEdit.
  JEDIT_SMOKE_SECONDS   Seconds jEdit must remain alive before the smoke passes.
  BENCHMARK_DRY_RUN     Used internally for benchmark command smoke checks.
EOF
}

test_benchmark_scripts() {
    echo "Checking benchmark scripts..."
    for script in ./run_benchmark.sh ./run_benchmark_parallel_random.sh; do
        bash -n "${script}"
    done
    if [ -x "${CVC5_SMOKE}" ]; then
        "${CVC5_SMOKE}" --version
    else
        echo "Error: cvc5 is not executable: ${CVC5_SMOKE}" >&2
        exit 1
    fi

    BENCHMARK_DRY_RUN=true \
      OUTPUT_DIR=/tmp/isabelle-run-benchmark-smoke \
      TARGET_SESSION="${LOGIC}" \
      SESSION_DIR=src/Abduct \
      MIRABELLE_JOBS=1 \
      ./run_benchmark.sh src/Abduct/Lambda/Lambda_Calculus_Abduction.thy 5 1 1 false 2

    BENCHMARK_DRY_RUN=true \
      OUTPUT_DIR=/tmp/isabelle-run-benchmark-parallel-random-smoke \
      ./run_benchmark_parallel_random.sh 5 1 1 false 2 0 true 1 1
}

test_build() {
    echo "Building ${LOGIC}..."
    ./bin/isabelle build ${ISABELLE_BUILD_ARGS} -d src/Abduct -b "${LOGIC}"
}

test_jedit() {
    if ! command -v xvfb-run >/dev/null 2>&1; then
        echo "Error: xvfb-run is required for the jEdit smoke test." >&2
        exit 1
    fi
    if [ ! -f "${THEORY_FILE}" ]; then
        echo "Error: theory file does not exist: ${THEORY_FILE}" >&2
        exit 1
    fi

    test_build

    echo "Launching jEdit under Xvfb for ${THEORY_FILE}..."
    rm -f "${JEDIT_SMOKE_LOG}"
    xvfb-run -a ./bin/isabelle jedit -n -l "${LOGIC}" -d src/Abduct "${THEORY_FILE}" \
      > "${JEDIT_SMOKE_LOG}" 2>&1 &
    jedit_pid=$!

    sleep "${JEDIT_SMOKE_SECONDS}"

    if kill -0 "${jedit_pid}" >/dev/null 2>&1; then
        kill "${jedit_pid}" >/dev/null 2>&1 || true
        wait "${jedit_pid}" >/dev/null 2>&1 || true
        echo "jEdit smoke passed: process stayed alive for ${JEDIT_SMOKE_SECONDS}s."
    else
        wait "${jedit_pid}" || status=$?
        status="${status:-1}"
        echo "jEdit exited before the smoke window. Log follows:" >&2
        sed -n '1,160p' "${JEDIT_SMOKE_LOG}" >&2 || true
        exit "${status}"
    fi
}

case "${MODE}" in
    all)
        test_benchmark_scripts
        test_jedit
        ;;
    benchmark)
        test_benchmark_scripts
        ;;
    build)
        test_build
        ;;
    jedit)
        test_jedit
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
