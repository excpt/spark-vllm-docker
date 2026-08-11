# Qwen3.6-27B-NVFP4 — TP=2 tuning results (2026-07-25)

Benchmark campaign on `unsloth/Qwen3.6-27B-NVFP4` across the two DGX Sparks (.30 + .31),
vLLM `0.26.1.dev0+gf2654939e` (image `vllm-node`, built 2026-07-25 from main past v0.26.0).

Supersedes the co-hosted TP=1 config for throughput. Costs both Sparks — no co-hosting the 35B.

## Verdict

```sh
./run-recipe.sh qwen3.6-27b-nvfp4-unsloth \
  -n 192.168.2.30,192.168.2.31 --tp 2 --port 8007 -d \
  -t vllm-node --eth-if enP7s7 -- \
  --max-num-batched-tokens 16384 \
  --async-scheduling \
  --speculative-config '{"method":"mtp","num_speculative_tokens":3}'
  # plus the recipe's --kv-cache-memory-bytes cap — do NOT clear it, see Failure modes
```

**197.5 tok/s** output at 64 concurrent. Interactive ceiling is **c≈12–16**; past that
per-user speed drops below 10 tok/s.

| Choice | Grounds |
|---|---|
| TP=2 | +54% over TP=1. Halves per-node weight reads against the 273 GB/s memory wall. |
| MTP-3 | +17% over no MTP. Depth 4 is both slower *and* crashes — see Failure modes. |
| `--async-scheduling` | 0.26 auto-enables it and explicitly supports MTP (`config/vllm.py:1045`). The recipe's `--no-async-scheduling` predates that and is stale. |
| 16384 batched tokens | Prefill 4106 tok/s vs 1232 at 8192. Prefill dominates this workload. |
| 128 seq slots | 512 changed nothing: KV binds at ~180 concurrent regardless. |
| 2 RoCE rails | 4 rails measured identical. Fabric never exceeded 3.1% utilisation. |
