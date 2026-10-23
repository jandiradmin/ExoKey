#!/bin/bash
# Downloads source word lists and builds data/dict/*.exd
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"
command -v unmunch >/dev/null || brew install hunspell
mkdir -p data/raw && cd data/raw
for l in en ru uk; do
  [ -f ${l}_full.txt ] || curl -fsSL -o ${l}_full.txt "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/$l/${l}_full.txt"
done
for p in en/en_US ru_RU/ru_RU uk_UA/uk_UA; do
  b=$(basename $p)
  [ -f $b.dic ] || curl -fsSL -o $b.dic "https://raw.githubusercontent.com/LibreOffice/dictionaries/master/$p.dic"
  [ -f $b.aff ] || curl -fsSL -o $b.aff "https://raw.githubusercontent.com/LibreOffice/dictionaries/master/$p.aff"
  [ -f ${b}_forms.txt ] || unmunch $b.dic $b.aff 2>/dev/null > ${b}_forms.txt
done
cd ../..
python3 tools/build_dicts.py
