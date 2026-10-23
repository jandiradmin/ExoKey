#!/bin/bash
cd "$HOME/Library/Application Support/ExoKey/ai"
E=engine/llama-b11840/llama-server
pkill -f 'port 880[12]'
$E -m model-q4.gguf --host 127.0.0.1 --port 8801 -c 4096 -ngl 99 > /tmp/q4.log 2>&1 &
$E -m model-q4.gguf -md draft.gguf -ngld 99 --spec-draft-n-max 8 --host 127.0.0.1 --port 8802 -c 4096 -ngl 99 > /tmp/spec.log 2>&1 &
for port in 8801 8802; do for i in $(seq 1 40); do curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$port/health | grep -q 200 && break; sleep 1; done; done
python3 "$HOME/exokey/tools/test/bench.py"
tail -3 /tmp/spec.log
pkill -f 'port 880[12]'
echo END
