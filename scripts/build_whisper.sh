#!/bin/bash
# Builds whisper.cpp (pinned tag) as static libraries for the Mac app's optional Whisper engine → vendor/whisper/.
# Only this small runtime ships inside the app; the model itself is downloaded from 설정 › 음성 인식.
#
#   scripts/build_whisper.sh
#
# Portable on purpose: no -mcpu=native (a build tuned for one chip can crash on an older Apple Silicon Mac),
# Metal shaders embedded in the library, Accelerate for BLAS. Needs cmake (brew install cmake).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="v1.9.4"
SRC="$ROOT/whisper.cpp"
OUT="$ROOT/vendor/whisper"
if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/whisper.cpp "$SRC"
fi
git -C "$SRC" tag --points-at HEAD | grep -qx "$TAG" || { echo "whisper.cpp is not at $TAG"; exit 1; }
cmake -S "$SRC" -B "$SRC/build-app" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
  -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16 \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON -DGGML_OPENMP=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2 >/dev/null
cmake --build "$SRC/build-app" --config Release -j 4
rm -rf "$OUT"; mkdir -p "$OUT/lib" "$OUT/include"
find "$SRC/build-app" -name '*.a' -exec cp {} "$OUT/lib/" \;
cp "$SRC/include/whisper.h" "$SRC"/ggml/include/*.h "$OUT/include/"
cp "$SRC/LICENSE" "$OUT/LICENSE"
echo "→ $OUT ($(du -sh "$OUT/lib" | cut -f1) of static libraries)"; ls "$OUT/lib"
