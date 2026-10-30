#!/bin/bash
# Records docs/media/demo-en.gif and demo-uk.gif from docs/demo/index.html
cd "$(dirname "$0")/.."
tools/.venv/bin/python tools/record_demo.py en && tools/.venv/bin/python tools/record_demo.py uk
