#!/bin/bash
# Trains one adapter and converts it for llama.cpp. Usage: tools/train/train.sh textbook|mystyle [iters]
set -e
T="$HOME/Library/Application Support/ExoKey/train"
cd "$T"
NAME=$1; ITERS=${2:-1200}
[ -d llama.cpp ] || git clone -q --depth 1 --branch b11840 https://github.com/ggml-org/llama.cpp.git llama.cpp
venv/bin/python -m mlx_lm lora --model base-hf --train --data "data/$NAME" --adapter-path "adapters/$NAME" \
  --iters "$ITERS" --batch-size 4 --num-layers 16 --learning-rate 1e-4 --max-seq-length 768 --mask-prompt \
  --steps-per-report 50 --steps-per-eval 300 --val-batches 20 --save-every 400 --grad-checkpoint
venv/bin/python ~/exokey/tools/train/mlx_to_gguf.py "adapters/$NAME" base-hf llama.cpp "../ai/lora-$NAME.gguf"
