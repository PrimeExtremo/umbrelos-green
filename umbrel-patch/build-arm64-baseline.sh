#!/usr/bin/env bash
# Build the upstream generic EFI baseline, NOT a flashable Green port.
# Run inside Linux with Docker Engine/buildx and a native Linux source checkout.
set -euo pipefail

source_dir="${1:?Usage: bash build-arm64-baseline.sh /path/to/umbrel-2.0-checkout}"
source_dir="$(realpath "$source_dir")"
expected_commit=9298257b0e904ca8d8270b1702672666343f0b86
actual_commit="$(git -C "$source_dir" rev-parse HEAD)"
if [[ "$actual_commit" != "$expected_commit" ]]; then
    echo "Expected Umbrel 2.0.0 commit $expected_commit; got $actual_commit" >&2
    exit 1
fi
if [[ -n "$(git -C "$source_dir" status --porcelain --untracked-files=no)" ]]; then
    echo 'Use an unchanged release checkout for the baseline build.' >&2
    exit 1
fi
command -v docker >/dev/null
docker info >/dev/null
docker buildx version
cd "$source_dir/packages/os"
echo 'Building a generic ARM64 EFI baseline. This is not Green-compatible media.'
# SKIP_* options are enabled by nonempty values in the upstream build script.
# Do not set SKIP_ARM64, since ARM64 is the requested target.
unset SKIP_ARM64 SKIP_ROOTS SKIP_RUGIX_ARTIFACTS
export SKIP_PI=true SKIP_AMD64=true SKIP_MENDER_ARTIFACTS=true
export SKIP_CACHE_EXPORT=true
bash build.sh 2.0.0-green-baseline
sha256sum build/umbrelos-arm64.img
echo 'Baseline built. Green bootloader/kernel integration and testing remain.'
