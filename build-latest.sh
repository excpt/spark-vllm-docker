#!/usr/bin/env bash
# Build vLLM from the ACTUAL latest main. No cache, no fallbacks, no silent failures.
set -euo pipefail

SRC=/tmp/vllm-latest
WHEELS=$(cd "$(dirname "$0")" && pwd)/wheels

rm -rf "$SRC"
git clone --recursive https://github.com/vllm-project/vllm.git "$SRC"
cd "$SRC"
git checkout --detach origin/main          # no `||` fallback — fails loudly
git submodule update --init --recursive

SHA=$(git rev-parse --short HEAD)
DESC=$(git describe --tags)
echo "=============================================="
echo " commit:   $SHA"
echo " describe: $DESC"
echo "=============================================="

# Refuse to burn hours compiling something stale.
case "$DESC" in
  v0.25*|v0.26*|v0.27*) ;;
  *) echo "ABORT: describe='$DESC' is not >= v0.25 — checkout is wrong."; exit 1 ;;
esac

docker build \
  --no-cache \
  --target vllm-export \
  --output "type=local,dest=$WHEELS" \
  --build-arg BUILD_JOBS="$(nproc)" \
  --build-arg TORCH_CUDA_ARCH_LIST=12.1a \
  --build-arg NCCL_NVCC_GENCODE="-gencode=arch=compute_121,code=sm_121" \
  --build-arg VLLM_REF="$SHA" \
  --build-arg CACHEBUST_VLLM="$(date +%s)" \
  --progress=plain \
  "$(dirname "$0")"

echo
echo "Built wheel:"
ls -l "$WHEELS"/vllm-*.whl
