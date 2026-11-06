#!/bin/bash
# Baseline numbers for the current app; results in .build/typing-sim.txt
cd "$(dirname "$0")/../.."
out=.build/typing-sim.txt
: > $out
python3 tools/test/typing_sim.py model-base.gguf --no-model >> $out 2>&1          # screen words only
python3 tools/test/typing_sim.py model-base.gguf --no-screen --conf 1 >> $out 2>&1 # model only, normal
python3 tools/test/typing_sim.py model-base.gguf --conf 1 >> $out 2>&1            # both, normal (= the app now)
python3 tools/test/typing_sim.py model-base.gguf --conf 2 >> $out 2>&1            # both, bold
python3 tools/test/typing_sim.py model-base.gguf --conf 0 >> $out 2>&1            # both, careful
echo DONE >> $out
