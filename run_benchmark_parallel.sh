#!/bin/bash
# Parallel AFP Abduction Benchmark Runner
# Spawns N processes, each handling goals where index % N == job_id

set -euo pipefail

ISABELLE_HOME="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${ISABELLE_HOME}/mirabelle_afp_evaluation}"
TARGET_SESSION="Abduct_AFP_Evaluation"
TIMEOUT="${1:-60}"
DEPTH="${2:-1}"
TOTAL_JOBS="${3:-16}"  # Number of parallel workers
TEST_PREMISES="${4:-true}"  # Default true
TEST_TIMEOUT="${5:-10}"
STAGGER_DELAY="${6:-5}"  # Seconds between worker starts
GRAMMAR_ASSERTIONS_MODE="${7:-true}"  # enabled|disabled|both|true|false
AFP_RANDOM_SEED="${8:-}"  # If set, select one random AFP theory
RANDOM_AFP_MAX_GOALS="${9:-1}"  # Max proof problems for the selected random theory
WORK_ROOT="${OUTPUT_DIR}/.workers"
SELECTED_SESSION_DIR="${OUTPUT_DIR}/.selected_session"
SESSION_DIR="src/Abduct"
MIRABELLE_PARALLEL_GROUP_SIZE=16
MIRABELLE_THEORY_ARGS=()
MIRABELLE_RANDOMIZE_ARGS=()
MAX_GOALS_PER_THEORY=0
RANDOM_AFP_MODE=false
BUILD_JOBS="${BUILD_JOBS:-1}"
SKIP_REQUIREMENTS_BUILD="${SKIP_REQUIREMENTS_BUILD:-false}"
HEAP_SOURCE_BASE="${HEAP_SOURCE_BASE:-}"
EXTRA_HEAP_SOURCE_BASE="${EXTRA_HEAP_SOURCE_BASE:-}"
BENCHMARK_DRY_RUN="${BENCHMARK_DRY_RUN:-false}"

require_bool() {
    case "$1" in
        true|false) ;;
        *)
            echo "Error: $2 must be true or false, got '$1'" >&2
            exit 1
            ;;
    esac
}

require_grammar_assertions_mode() {
    case "$1" in
        enabled|disabled|both|true|false) ;;
        *)
            echo "Error: grammar assertions mode must be enabled, disabled, both, true, or false, got '$1'" >&2
            exit 1
            ;;
    esac
}

require_nonnegative_int() {
    case "$1" in
        ''|*[!0-9]*)
            echo "Error: $2 must be a non-negative integer, got '$1'" >&2
            exit 1
            ;;
    esac
}

resolve_cvc5_path() {
    local candidate=""
    local cvc5_home=""

    if [ -n "${CVC5:-}" ]; then
        candidate="$(expand_tilde_path "${CVC5}")"
    elif [ -n "${CVC5_HOME:-}" ]; then
        cvc5_home="$(expand_tilde_path "${CVC5_HOME}")"
        if [ -x "${cvc5_home}/bin/cvc5" ]; then
            candidate="${cvc5_home}/bin/cvc5"
        fi
    fi

    if [ -z "${candidate}" ] && [ -x "$(dirname "${ISABELLE_HOME}")/cvc5/build/bin/cvc5" ]; then
        candidate="$(dirname "${ISABELLE_HOME}")/cvc5/build/bin/cvc5"
    elif [ -z "${candidate}" ] && [ -x "${ISABELLE_HOME}/contrib/cvc5/bin/cvc5" ]; then
        candidate="${ISABELLE_HOME}/contrib/cvc5/bin/cvc5"
    elif [ -z "${candidate}" ] && command -v cvc5 >/dev/null 2>&1; then
        candidate="$(command -v cvc5)"
    fi

    if [ -n "${candidate}" ] && [ ! -x "${candidate}" ] && command -v "${candidate}" >/dev/null 2>&1; then
        candidate="$(command -v "${candidate}")"
    fi

    [ -n "${candidate}" ] || return 1
    [ -x "${candidate}" ] || return 1
    printf '%s\n' "${candidate}"
}

expand_tilde_path() {
    case "$1" in
        "~/"*) printf '%s/%s\n' "${HOME}" "${1#~/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

make_worker_home() {
    mktemp -d "${WORK_ROOT}/worker_${1}_XXXXXX"
}

worker_isabelle_home_user() {
    local user_home="$1"
    local identifier="${ISABELLE_IDENTIFIER:-}"

    if [ -z "${identifier}" ] && [ -f "${ISABELLE_HOME}/etc/ISABELLE_IDENTIFIER" ]; then
        identifier="$(cat "${ISABELLE_HOME}/etc/ISABELLE_IDENTIFIER")"
    fi

    if [ -z "${identifier}" ]; then
        printf '%s/.isabelle\n' "${user_home}"
    else
        printf '%s/.isabelle/%s\n' "${user_home}" "${identifier}"
    fi
}

write_worker_settings() {
    local user_home="$1"
    local worker_system_heaps="$2"
    local tmp_dir="$3"
    local components_base="$4"
    local home_user

    home_user="$(worker_isabelle_home_user "${user_home}")"
    mkdir -p "${home_user}/etc"

    cat > "${home_user}/etc/settings" <<EOF
ISABELLE_COMPONENTS_BASE="${components_base}"
if [ -f "${ISABELLE_HOME}/Admin/components/main" ]; then
  init_components "\${ISABELLE_COMPONENTS_BASE}" "${ISABELLE_HOME}/Admin/components/main"
fi
ISABELLE_HEAPS_SYSTEM="${worker_system_heaps}"
ISABELLE_TMP_PREFIX="${tmp_dir}/isabelle"
ISABELLE_JAVA_SYSTEM_OPTIONS="\${ISABELLE_JAVA_SYSTEM_OPTIONS} -Xms512m -Xmx2g"
ML_OPTIONS="--minheap 500 --maxheap 2000"
EOF
}

create_system_heaps_overlay() {
    local source_base="$1"
    local overlay_base="$2"
    local source_ml_dir
    local overlay_ml_dir
    local path
    local base

    mkdir -p "${overlay_base}"

    while IFS= read -r -d '' source_ml_dir; do
        overlay_ml_dir="${overlay_base}/$(basename "${source_ml_dir}")"
        mkdir -p "${overlay_ml_dir}"

        while IFS= read -r -d '' path; do
            base="$(basename "${path}")"
            if [ "${base}" = "${TARGET_SESSION}" ]; then
                continue
            fi
            ln -sfn "${path}" "${overlay_ml_dir}/"
        done < <(find "${source_ml_dir}" -mindepth 1 -maxdepth 1 ! -name log -print0)

        if [ -d "${source_ml_dir}/log" ]; then
            mkdir -p "${overlay_ml_dir}/log"
            while IFS= read -r -d '' path; do
                base="$(basename "${path}")"
                case "${base}" in
                    "${TARGET_SESSION}"|"${TARGET_SESSION}".*)
                        continue
                        ;;
                esac
                ln -sfn "${path}" "${overlay_ml_dir}/log/"
            done < <(find "${source_ml_dir}/log" -mindepth 1 -maxdepth 1 -print0)
        fi
    done < <(find "${source_base}" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0)
}

require_bool "${TEST_PREMISES}" "test_premises"
require_bool "${SKIP_REQUIREMENTS_BUILD}" "skip_requirements_build"
require_bool "${BENCHMARK_DRY_RUN}" "BENCHMARK_DRY_RUN"
require_grammar_assertions_mode "${GRAMMAR_ASSERTIONS_MODE}"

if [ -n "${AFP_RANDOM_SEED}" ]; then
    require_nonnegative_int "${AFP_RANDOM_SEED}" "afp_random_seed"
    require_nonnegative_int "${RANDOM_AFP_MAX_GOALS}" "random_afp_max_goals"
    if [ "${RANDOM_AFP_MAX_GOALS}" -le 0 ]; then
        echo "Error: random_afp_max_goals must be positive in random AFP mode" >&2
        exit 1
    fi
    RANDOM_AFP_MODE=true
    MAX_GOALS_PER_THEORY="${RANDOM_AFP_MAX_GOALS}"
    MIRABELLE_PARALLEL_GROUP_SIZE=1
    MIRABELLE_RANDOMIZE_ARGS=("-r" "${AFP_RANDOM_SEED}")
fi

if [ "$#" -gt 9 ]; then
    echo "Warning: ignoring extra positional arguments after RANDOM_AFP_MAX_GOALS; random AFP mode always selects one theory." >&2
fi

echo "=============================================="
echo "Parallel Abduction Benchmark"
echo "=============================================="
echo "Timeout: ${TIMEOUT}s"
echo "Depth: ${DEPTH}"
echo "Workers: ${TOTAL_JOBS}"
echo "Test premises: ${TEST_PREMISES}"
echo "Test timeout: ${TEST_TIMEOUT}s"
echo "Stagger delay: ${STAGGER_DELAY}s between workers"
echo "Grammar assertions mode: ${GRAMMAR_ASSERTIONS_MODE}"
echo "Random AFP one-theory mode: ${RANDOM_AFP_MODE}"
if [ "${RANDOM_AFP_MODE}" = true ]; then
    echo "AFP random seed: ${AFP_RANDOM_SEED}"
    echo "Max goals per selected theory: ${MAX_GOALS_PER_THEORY}"
fi
echo "Build jobs: ${BUILD_JOBS}"
echo "Skip requirements build: ${SKIP_REQUIREMENTS_BUILD}"
echo "Output: ${OUTPUT_DIR}"
echo "Dry run: ${BENCHMARK_DRY_RUN}"
echo "=============================================="

if [ "${BENCHMARK_DRY_RUN}" = true ]; then
    echo "Dry run complete: arguments validated; no workers launched."
    exit 0
fi

mkdir -p "${OUTPUT_DIR}"
rm -rf "${WORK_ROOT}"
rm -rf "${SELECTED_SESSION_DIR}"
rm -f "${OUTPUT_DIR}/selected_theories.txt" \
    "${OUTPUT_DIR}/replacement_theories.txt" \
    "${OUTPUT_DIR}/rejected_theories.txt" \
    "${OUTPUT_DIR}/selection_validation_failures.txt" \
    "${OUTPUT_DIR}"/selection_validation_*.out
mkdir -p "${WORK_ROOT}"
find "${OUTPUT_DIR}" -maxdepth 1 \( -name '_*' -o -name 'mirabelle.log' \) -exec rm -rf {} + 2>/dev/null || true

if [ "${RANDOM_AFP_MODE}" = true ]; then
    echo "Selecting one random patched AFP theory with seed ${AFP_RANDOM_SEED}..."
    PYTHONDONTWRITEBYTECODE=1 python3 "${ISABELLE_HOME}/src/Abduct/select_afp_theories.py" \
        --output-dir "${OUTPUT_DIR}" \
        --seed "${AFP_RANDOM_SEED}" \
        --session-name "${TARGET_SESSION}"

    SESSION_DIR="${SELECTED_SESSION_DIR}"
    SELECTED_THEORY="$(sed -n '1p' "${OUTPUT_DIR}/selected_theories.txt")"
    if [ -z "${SELECTED_THEORY}" ]; then
        echo "Error: no AFP theory was selected" >&2
        exit 1
    fi
    MIRABELLE_THEORY_ARGS=("-T" "${SELECTED_THEORY}")
    echo "Selected AFP theory: ${SELECTED_THEORY}"
fi

if ! CVC5_PATH="$(resolve_cvc5_path)"; then
    echo "Error: cvc5 is not available." >&2
    echo "Checked CVC5, CVC5_HOME/bin/cvc5, ${ISABELLE_HOME}/contrib/cvc5/bin/cvc5, and PATH." >&2
    exit 1
fi

echo "cvc5 available: ${CVC5_PATH}"

if [ "${SKIP_REQUIREMENTS_BUILD}" = true ]; then
    if [ -z "${HEAP_SOURCE_BASE}" ]; then
        HEAP_SOURCE_BASE=$(./bin/isabelle getenv -b ISABELLE_HEAPS 2>/dev/null | head -1)
    fi
    if [ -z "${EXTRA_HEAP_SOURCE_BASE}" ]; then
        EXTRA_HEAP_SOURCE_BASE=$(./bin/isabelle getenv -b ISABELLE_HEAPS_SYSTEM 2>/dev/null | head -1)
    fi
    SYSTEM_HEAPS_BASE="${HEAP_SOURCE_BASE}"
    echo "Skipping requirements build; using heap source base: ${SYSTEM_HEAPS_BASE}"
    if [ -n "${EXTRA_HEAP_SOURCE_BASE}" ]; then
        echo "Additional heap source base: ${EXTRA_HEAP_SOURCE_BASE}"
    fi
else
    # Build requirements first (single process) to avoid parallel build conflicts.
    # Do not build TARGET_SESSION here: Mirabelle must rebuild it with its export
    # hooks installed, otherwise a current heap/log makes the run a no-op.
    echo "Building session requirements first..."
    ./bin/isabelle build \
        -d "${SESSION_DIR}" \
        -j "${BUILD_JOBS}" \
        -o system_heaps=true \
        -o build_database=false \
        -o build_database_server=false \
        -b \
        -R \
        "${TARGET_SESSION}"

    SYSTEM_HEAPS_BASE=$(./bin/isabelle getenv -b ISABELLE_HEAPS_SYSTEM 2>/dev/null | head -1)
fi

if [ -z "${SYSTEM_HEAPS_BASE}" ] || [ ! -d "${SYSTEM_HEAPS_BASE}" ]; then
    echo "Error: heap source base is unavailable: ${SYSTEM_HEAPS_BASE}" >&2
    exit 1
fi
if [ "${SKIP_REQUIREMENTS_BUILD}" = true ]; then
    if ! find "${SYSTEM_HEAPS_BASE}" -mindepth 2 -maxdepth 2 -type f -name HOL -print -quit | grep -q .; then
        echo "Error: skip_requirements_build=true but no HOL heap was found under ${SYSTEM_HEAPS_BASE}" >&2
        exit 1
    fi
fi
echo "Heap source base: ${SYSTEM_HEAPS_BASE}"

COMPONENTS_BASE=$(./bin/isabelle getenv -b ISABELLE_COMPONENTS_BASE 2>/dev/null | head -1)
if [ -z "${COMPONENTS_BASE}" ] || [ ! -d "${COMPONENTS_BASE}" ]; then
    echo "Error: ISABELLE_COMPONENTS_BASE is unavailable after the build step." >&2
    exit 1
fi
echo "Components base: ${COMPONENTS_BASE}"

# Launch workers in parallel
pids=()
worker_homes=()
for job_id in $(seq 0 $((TOTAL_JOBS - 1))); do
    # Stagger worker starts to reduce resource contention
    if [ "$job_id" -gt 0 ]; then
        echo "Waiting ${STAGGER_DELAY}s before starting worker ${job_id}..."
        sleep "${STAGGER_DELAY}"
    fi
    echo "Starting worker ${job_id}/${TOTAL_JOBS}..."

    WORKER_HOME="$(make_worker_home "${job_id}")"
    worker_homes+=("${WORKER_HOME}")
    mkdir -p "${WORKER_HOME}"

    (
        WORKER_USER_HOME="${WORKER_HOME}/user"
        WORKER_SYSTEM_HEAPS="${WORKER_HOME}/heaps-system"
        export TMPDIR="${WORKER_HOME}/tmp"
        export TMP="${TMPDIR}"
        export TEMP="${TMPDIR}"
        export USER_HOME="${WORKER_USER_HOME}"
        export HOME="${WORKER_USER_HOME}"
        export CVC5="${CVC5_PATH}"
        mkdir -p "${WORKER_USER_HOME}" "${TMPDIR}"

        if [ -n "${EXTRA_HEAP_SOURCE_BASE}" ] && [ "${EXTRA_HEAP_SOURCE_BASE}" != "${SYSTEM_HEAPS_BASE}" ]; then
            create_system_heaps_overlay "${EXTRA_HEAP_SOURCE_BASE}" "${WORKER_SYSTEM_HEAPS}"
        fi
        create_system_heaps_overlay "${SYSTEM_HEAPS_BASE}" "${WORKER_SYSTEM_HEAPS}"
        write_worker_settings "${WORKER_USER_HOME}" "${WORKER_SYSTEM_HEAPS}" "${TMPDIR}" "${COMPONENTS_BASE}"

        target_in_overlay="$(find "${WORKER_SYSTEM_HEAPS}" \
            \( -name "${TARGET_SESSION}" -o -name "${TARGET_SESSION}.db" -o -name "${TARGET_SESSION}.gz" \) \
            -print -quit)"
        if [ -n "${target_in_overlay}" ]; then
            echo "Error: worker heap overlay still exposes ${TARGET_SESSION}: ${target_in_overlay}" >&2
            exit 1
        fi

        echo "Worker ${job_id} Isabelle settings:"
        echo "  USER_HOME=${USER_HOME}"
        echo "  ISABELLE_HOME_USER=$(./bin/isabelle getenv -b ISABELLE_HOME_USER)"
        echo "  ISABELLE_HEAPS=$(./bin/isabelle getenv -b ISABELLE_HEAPS)"
        echo "  ISABELLE_HEAPS_SYSTEM=$(./bin/isabelle getenv -b ISABELLE_HEAPS_SYSTEM)"

        ./bin/isabelle mirabelle \
            -A "abduct[timeout=${TIMEOUT},depth=${DEPTH},test_premises=${TEST_PREMISES},test_provable=true,test_timeout=${TEST_TIMEOUT},grammar_assertions_mode=${GRAMMAR_ASSERTIONS_MODE},job_id=${job_id},total_jobs=${TOTAL_JOBS},max_goals_per_theory=${MAX_GOALS_PER_THEORY}]" \
            -O "${OUTPUT_DIR}/_${job_id}" \
            -d "${SESSION_DIR}" \
            "${MIRABELLE_THEORY_ARGS[@]}" \
            "${MIRABELLE_RANDOMIZE_ARGS[@]}" \
            -o export_theory=false \
            -o build_database=false \
            -o build_database_server=false \
            -o system_heaps=false \
            -p "${MIRABELLE_PARALLEL_GROUP_SIZE}" \
            "${TARGET_SESSION}"
    ) > "${OUTPUT_DIR}/_${job_id}.out" 2>&1 &
    pids+=($!)
done

echo ""
echo "All ${TOTAL_JOBS} workers launched. Waiting for completion..."
echo "Monitor with: watch -n1 'ps aux | grep isabelle | grep -v grep | wc -l'"
echo ""

# Wait for all workers
failed=0
for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
        echo "Worker $i completed successfully"
    else
        echo "Worker $i failed"
        ((failed++))
    fi
done

echo ""
echo "=============================================="
echo "All workers finished. Failed: ${failed}/${TOTAL_JOBS}"
echo "=============================================="

# Cleanup worker homes
echo "Cleaning up worker directories..."
for worker_home in "${worker_homes[@]}"; do
    rm -rf "${worker_home}" 2>/dev/null || true
done

# Merge logs
echo "Merging logs..."
cat ${OUTPUT_DIR}/_*/mirabelle.log > "${OUTPUT_DIR}/mirabelle.log" 2>/dev/null || true
if [ -f "${OUTPUT_DIR}/mirabelle.log" ]; then
    tmp_log="${OUTPUT_DIR}/mirabelle.log.tmp"
    LC_ALL=C LANG=C perl -ne 'print unless /^[^ ]+ goal\.\S+\s+\d+ms\s+\S+\s+\d+:\d+\s*$/' \
        "${OUTPUT_DIR}/mirabelle.log" > "${tmp_log}"
    mv "${tmp_log}" "${OUTPUT_DIR}/mirabelle.log"
fi

# Summary
if [ -f "${OUTPUT_DIR}/mirabelle.log" ]; then
    total_goals=$(grep -cE "DROPPED PREMISE \[[0-9]+/[0-9]+\]:" "${OUTPUT_DIR}/mirabelle.log" 2>/dev/null || true)
    goals_with_abducts=$(grep -c "ABDUCTS FOUND ([1-9]" "${OUTPUT_DIR}/mirabelle.log" 2>/dev/null || true)
    total_abducts=$({ grep -oE "ABDUCTS FOUND \([0-9]+\)" "${OUTPUT_DIR}/mirabelle.log" 2>/dev/null || true; } | { grep -oE "[0-9]+" || true; } | awk '{s+=$1} END {print s+0}')
    echo ""
    echo "Summary:"
    echo "  Total goals processed: ${total_goals:-0}"
    echo "  Goals with abducts: ${goals_with_abducts:-0}"
    echo "  Total abducts found: ${total_abducts:-0}"
fi

echo ""
echo "Results in: ${OUTPUT_DIR}/mirabelle.log"
