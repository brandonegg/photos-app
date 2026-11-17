#!/bin/sh
# Builds the SHARP model the Spatial Scene feature runs on the iPhone (Apple's
# "Sharp Monocular View Synthesis", apple/ml-sharp): one photo in, a 3D scene of about
# 1.2 million Gaussian splats out. It downloads Apple's checkpoint (2.8 GB, checked against
# its SHA-256 sum), converts it to Core ML with float16 weights (about 1.2 GB) and puts it in
# App/Models, where the next build picks it up. Without it the app uses the depth-map renderer.
#
# The checkpoint is under the Apple Machine Learning Research Model licence: research and
# evaluation only, not for shipping. Needs uv (https://docs.astral.sh/uv/) and about 10 GB free.
# Usage: Scripts/build-sharp-model.sh [--int8]   (--int8: 0.6 GB, less accurate)
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="$ROOT/build/sharp"
DEST="$ROOT/App/Models/SharpGaussians.mlpackage"
CHECKPOINT="$WORK/sharp_2572gikvuh.pt"
SUM=94211a75198c47f61fca7d739ba08a215418d8d398d48fddf023baccc24f073d
WEIGHTS=float16
[ "${1:-}" = "--int8" ] && WEIGHTS=int8

mkdir -p "$WORK"
if [ ! -d "$WORK/ml-sharp" ]; then
  git clone -q https://github.com/apple/ml-sharp.git "$WORK/ml-sharp"
  git -C "$WORK/ml-sharp" checkout -q aed6527499ef91cba3b54c18d49a870f25947190
fi
if [ ! -f "$CHECKPOINT" ] || [ "$(shasum -a 256 "$CHECKPOINT" | cut -d' ' -f1)" != "$SUM" ]; then
  echo "Downloading the SHARP checkpoint (2.8 GB)"
  curl -fL --retry 3 -o "$CHECKPOINT.part" https://ml-site.cdn-apple.com/models/sharp/sharp_2572gikvuh.pt
  [ "$(shasum -a 256 "$CHECKPOINT.part" | cut -d' ' -f1)" = "$SUM" ] || { echo "Checksum mismatch" >&2; rm -f "$CHECKPOINT.part"; exit 1; }
  mv "$CHECKPOINT.part" "$CHECKPOINT"
fi
if [ ! -x "$WORK/venv/bin/python" ]; then
  uv venv -q -p 3.13 "$WORK/venv"
  # coremltools is tested against torch 2.7.
  VIRTUAL_ENV="$WORK/venv" uv pip install -q -e "$WORK/ml-sharp" coremltools==9.0 torch==2.7.0 torchvision==0.22.0 numpy==2.3.3 timm==1.0.20
fi
rm -rf "$DEST"
"$WORK/venv/bin/python" "$ROOT/Tools/sharp/convert.py" --checkpoint "$CHECKPOINT" --output "$DEST" --weights "$WEIGHTS"
echo "SHARP model ready: App/Models/SharpGaussians.mlpackage (run xcodegen generate if the project doesn't show it)"
