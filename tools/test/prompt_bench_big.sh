#!/bin/bash
cd "$(dirname "$0")/../.."
out=.build/prompt-bench-big.txt
: > $out
while [ ! -f "$HOME/Library/Application Support/ExoKey/ai/bench/dl.done" ]; do sleep 5; done
for m in bench/Qwen3-8B-Base.Q4_K_M.gguf bench/Qwen3-14B-Base.Q4_K_M.gguf; do
  python3 tools/test/prompt_bench.py $m style >> $out 2>&1
done
echo DONE >> $out
