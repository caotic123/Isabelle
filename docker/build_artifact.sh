#!/usr/bin/env bash
# Build the self-contained Isabelle Abduct artifact image.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${IMAGE:-isabelle-abduct-artifact}"

cd "${REPO_ROOT}"

docker build --progress=plain -t "${IMAGE}" "$@" .
