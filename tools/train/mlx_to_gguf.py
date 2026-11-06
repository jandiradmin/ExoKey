#!/usr/bin/env python3
"""MLX LoRA adapter → PEFT layout → GGUF LoRA for llama.cpp (llama-server --lora).
Usage: mlx_to_gguf.py ADAPTER_DIR BASE_HF_DIR LLAMA_CPP_DIR OUT.gguf"""
import json, os, subprocess, sys
from safetensors.torch import load_file, save_file
src, base, llama, out = sys.argv[1:5]
cfg = json.load(open(os.path.join(src, 'adapter_config.json')))
lp = cfg.get('lora_parameters', {})
rank, scale = int(lp.get('rank', 8)), float(lp.get('scale', 20.0))
w = load_file(os.path.join(src, 'adapters.safetensors'))
peft, targets = {}, set()
for k, v in w.items():
    # model.layers.N.self_attn.q_proj.lora_a  (in, r)  → lora_A.weight (r, in);  lora_b (r, out) → lora_B.weight (out, r)
    mod, part = k.rsplit('.', 1)
    targets.add(mod.split('.')[-1])
    name = 'base_model.model.' + mod + ('.lora_A.weight' if part == 'lora_a' else '.lora_B.weight')
    peft[name] = v.T.contiguous().float()
pdir = os.path.join(src, 'peft'); os.makedirs(pdir, exist_ok=True)
save_file(peft, os.path.join(pdir, 'adapter_model.safetensors'))
json.dump({'peft_type': 'LORA', 'task_type': 'CAUSAL_LM', 'r': rank, 'lora_alpha': scale * rank,
           'target_modules': sorted(targets), 'base_model_name_or_path': base, 'lora_dropout': 0.0, 'bias': 'none',
           'fan_in_fan_out': False}, open(os.path.join(pdir, 'adapter_config.json'), 'w'))
print('peft tensors', len(peft), 'rank', rank, 'alpha', scale * rank, 'targets', sorted(targets))
py = sys.executable
subprocess.run([py, os.path.join(llama, 'convert_lora_to_gguf.py'), '--base', base, '--outfile', out, '--outtype', 'f16', pdir], check=True)
print('wrote', out)
