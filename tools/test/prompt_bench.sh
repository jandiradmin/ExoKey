#!/bin/bash
# Runs the comparison in the background; results in .build/prompt-bench.txt
cd "$(dirname "$0")/../.."
out=.build/prompt-bench.txt
: > $out
python3 tools/test/prompt_bench.py model-base.gguf raw,labeled,dialog,style >> $out 2>&1
python3 tools/test/prompt_bench.py model-fast.gguf raw,chat,labeled >> $out 2>&1
echo DONE >> $out
