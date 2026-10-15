#!/bin/bash
# Builds transcribe.cpp (pinned tag) into one self-contained dylib for the Mac app's optional engines — Qwen3-ASR and
# Parakeet — → vendor/transcribe/. Only this runtime ships inside the app; models are downloaded from 설정 › 음성 인식.
#
#   scripts/build_transcribe.sh
#
# transcribe.cpp carries its own (patched) ggml. Linked statically next to whisper.cpp's ggml the two would collide,
# so everything goes into one dylib that exports only the transcribe_* API: its ggml stays private. Portable on
# purpose (no -mcpu=native), Metal shaders embedded, source paths in its messages relative (no developer folder in the
# binary). Needs cmake (brew install cmake).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="v0.3.1"
SRC="$ROOT/transcribe.cpp"
BUILD="$SRC/build-app"
OUT="$ROOT/vendor/transcribe"
if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/handy-computer/transcribe.cpp "$SRC"
fi
git -C "$SRC" tag --points-at HEAD | grep -qx "$TAG" || { echo "transcribe.cpp is not at $TAG"; exit 1; }
MAP="-ffile-prefix-map=$SRC/=transcribe.cpp/"
cmake -S "$SRC" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DTRANSCRIBE_BUILD_SHARED=OFF \
  -DCMAKE_C_FLAGS="$MAP" -DCMAKE_CXX_FLAGS="$MAP" -DCMAKE_OBJC_FLAGS="$MAP" \
  -DTRANSCRIBE_BUILD_TESTS=OFF -DTRANSCRIBE_BUILD_EXAMPLES=OFF -DTRANSCRIBE_BUILD_TOOLS=OFF \
  -DTRANSCRIBE_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16 \
  -DTRANSCRIBE_USE_SYSTEM_BLAS=OFF -DTRANSCRIBE_USE_OPENMP=OFF \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.2 >/dev/null
cmake --build "$BUILD" --config Release -j 4
rm -rf "$OUT"; mkdir -p "$OUT/lib" "$OUT/include"
LIBS=$(find "$BUILD" -name '*.a' | sort)
MAIN=$(echo "$LIBS" | grep '/libtranscribe\.a$')
REST=$(echo "$LIBS" | grep -v '/libtranscribe\.a$')
printf '_transcribe_*\n' > "$BUILD/exports.txt"
# shellcheck disable=SC2086
clang++ -dynamiclib -arch arm64 -mmacosx-version-min=14.2 -o "$OUT/lib/libtranscribe.dylib" \
  -Wl,-force_load,"$MAIN" $REST -framework Metal -framework MetalKit -framework Foundation -framework Accelerate \
  -Wl,-exported_symbols_list,"$BUILD/exports.txt" -Wl,-dead_strip -install_name @rpath/libtranscribe.dylib
cp "$SRC/include/transcribe.h" "$OUT/include/"
cp "$SRC/LICENSE" "$OUT/LICENSE"
cp "$SRC/THIRD-PARTY-LICENSES.md" "$OUT/THIRD-PARTY-LICENSES.md"
echo "→ $OUT/lib/libtranscribe.dylib ($(du -h "$OUT/lib/libtranscribe.dylib" | cut -f1)), exported: $(nm -gU "$OUT/lib/libtranscribe.dylib" | grep -c ' _transcribe_') functions, ggml exported: $(nm -gU "$OUT/lib/libtranscribe.dylib" | grep -c ' _ggml_')"
