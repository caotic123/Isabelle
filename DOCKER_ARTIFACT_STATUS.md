# Isabelle Abduct Docker Artifact Status

Date: 2026-05-12

## Goal

Create a Docker artifact for this Isabelle checkout that:

- builds the local edited cvc5 from `third_party/cvc5`,
- configures Isabelle to use that cvc5 binary,
- can smoke-test jEdit on `src/Abduct/Lambda/Lambda_Calculus_Abduction.thy`,
- can smoke-test `run_benchmark.sh`,
- can smoke-test `run_benchmark_parallel_random.sh`.

## Files Added Or Updated

- `Dockerfile`
  - Multi-stage image.
  - Builds bundled `third_party/cvc5` in a `cvc5-builder` stage.
  - Installs the built solver at `/opt/isabelle/contrib/cvc5/bin/cvc5`.
  - Copies required cvc5 shared libraries into `/opt/isabelle/contrib/cvc5/lib`.
  - Sets `CVC5=/opt/isabelle/contrib/cvc5/bin/cvc5`.
  - Sets `LD_LIBRARY_PATH=/opt/isabelle/contrib/cvc5/lib`.
  - Installs Isabelle components needed for batch builds and headless jEdit.
  - Includes `verit-2021.06.2-rmx-1` because HOL uses it in SMT replay.
  - Does not install Isabelle's stock `cvc5-1.2.0-1` component; the bundled edited solver is used instead.
  - Defaults `BUILD_SESSION=false` to avoid building the Isabelle heap during image build on low-memory machines.

- `.dockerignore`
  - Excludes local heaps, contrib, benchmark output, logs, VCS metadata, and cvc5 build artifacts from the Docker context.

- `docker/build_artifact.sh`
  - Builds the image as `isabelle-abduct-artifact` by default.

- `docker/smoke.sh`
  - Modes: `all`, `benchmark`, `build`, `jedit`.
  - `benchmark` checks script syntax, confirms cvc5 runs, dry-runs `run_benchmark.sh`, and dry-runs `run_benchmark_parallel_random.sh`.
  - `jedit` builds `Abduct_Lambda_Calculus`, then starts Isabelle/jEdit under `xvfb-run` for `src/Abduct/Lambda/Lambda_Calculus_Abduction.thy`.

- `docker/Dockerfile.local-cvc5`
  - Kept as an auxiliary local-cvc5 Dockerfile.

- `third_party/cvc5`
  - Copied from `/Users/caotic/Desktop/Workspace/cvc5`.
  - This is the edited local cvc5 source used by the artifact build.
  - `.git`, build outputs, object files, libraries, and IDE/cache files were excluded.

- `run_benchmark.sh`
  - First positional argument now optionally selects one theory.
  - A `.thy` path is normalized to its theory name.
  - `-`, `all`, or an empty first argument means all theories in the target session.
  - Supports `BENCHMARK_DRY_RUN=true`.
  - Uses configurable `OUTPUT_DIR`, `SESSION_DIR`, `TARGET_SESSION`, and `MIRABELLE_JOBS`.

- `run_benchmark_parallel_random.sh`
  - Copy of the parallel benchmark runner for the random one-theory mode.
  - Supports `BENCHMARK_DRY_RUN=true`.

- `run_benchmark_parallel.sh`
  - Supports dry-run validation.

- Abduct command files
  - The command is `abduce`, not `abduct`.
  - The Isabelle/Mirabelle action remains `abduct` where appropriate.

## Commands To Rebuild On A Larger Machine

Build the image:

```bash
./docker/build_artifact.sh
```

Run benchmark smoke checks:

```bash
docker run --rm isabelle-abduct-artifact benchmark
```

Run only the session build:

```bash
docker run --rm isabelle-abduct-artifact build
```

Run the jEdit smoke for Lambda Calculus Abduction:

```bash
docker run --rm -e JEDIT_SMOKE_SECONDS=10 isabelle-abduct-artifact jedit
```

Run everything:

```bash
docker run --rm isabelle-abduct-artifact all
```

If the Docker host has enough memory and you want the image to prebuild the Lambda heap:

```bash
./docker/build_artifact.sh --build-arg BUILD_SESSION=true
```

For low-memory machines, keep `BUILD_SESSION=false` and run the build/jEdit smoke later on a machine with more Docker memory.

## Verified On This Machine

The Docker image `isabelle-abduct-artifact:latest` built successfully.

The image built the bundled cvc5 and reported:

```text
This is cvc5 version 1.3.3.dev
compiled with GCC version 11.4.0
on May 12 2026 00:20:10
```

The runtime cvc5 linkage resolved correctly:

```text
libcvc5parser.so.1 => /opt/isabelle/contrib/cvc5/lib/libcvc5parser.so.1
libcvc5.so.1 => /opt/isabelle/contrib/cvc5/lib/libcvc5.so.1
libpoly.so.0 => /opt/isabelle/contrib/cvc5/lib/libpoly.so.0
libpolyxx.so.0 => /opt/isabelle/contrib/cvc5/lib/libpolyxx.so.0
```

This benchmark smoke passed:

```bash
docker run --rm isabelle-abduct-artifact benchmark
```

It validated these dry-run paths:

```text
./bin/isabelle mirabelle -A abduct[timeout=5,depth=1,test_premises=false,test_timeout=2] -O /tmp/isabelle-run-benchmark-smoke -d src/Abduct -T Lambda_Calculus_Abduction -t 5 -m 1 -j 1 Abduct_Lambda_Calculus
./run_benchmark_parallel_random.sh 5 1 1 false 2 0 true 1 1
```

## Known Runtime Limitation On This Machine

The jEdit smoke was started with:

```bash
docker run --rm -e JEDIT_SMOKE_SECONDS=10 isabelle-abduct-artifact jedit
```

It successfully built `Pure`, then continued building `HOL`, but failed under the local Docker memory limit:

```text
Exception in thread "Isabelle.message_output" java.lang.OutOfMemoryError: Java heap space
```

Observed Docker limit during that run:

```text
3.827 GiB
```

The container was using about 3.2-3.3 GiB while compiling. Run this on a host with more Docker memory, preferably at least 8 GiB available to Docker.

## Expected Warning

During Isabelle commands, this warning can appear:

```text
### Missing Isabelle component: ".../cvc5-1.2.0-1"
```

That is expected for this artifact. The Dockerfile intentionally does not install Isabelle's stock cvc5 component, because it uses the edited bundled solver at:

```text
/opt/isabelle/contrib/cvc5/bin/cvc5
```

## Docker Cleanup On This Machine

After this note was written, the local generated Docker image and builder cache were removed from this machine as requested. Rebuild with `./docker/build_artifact.sh` on the target machine.
