#!/bin/bash
# Builds the LAME MP3 encoder (libmp3lame) as a static, universal (arm64 + x86_64) library. LogiKast uses it to
# convert backup audio to MP3 (macOS can read MP3 but has no MP3 encoder).
# Output: build/lame/lib/libmp3lame.a and build/lame/include/lame/lame.h
# Usage: scripts/build-lame.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/src"
OUT="$ROOT/build/lame"
MIN_MACOS=13.0
URL="https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz"
SHA256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
TARBALL="$SRC/lame-3.100.tar.gz"
JOBS=$(sysctl -n hw.ncpu)
# Use Xcode's SDK when there is one: a newer Command Line Tools SDK can be too new for Xcode's linker.
XSDK="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
[ -d "$XSDK" ] && export SDKROOT="$XSDK"

mkdir -p "$SRC"
[ -f "$TARBALL" ] || curl -fsSL -o "$TARBALL" "$URL"
echo "$SHA256  $TARBALL" | shasum -a 256 -c - >/dev/null || { echo "error: lame-3.100.tar.gz does not match its pinned checksum" >&2; exit 1; }

LIBS=()
for arch in arm64 x86_64; do
  W="$ROOT/build/work/lame-$arch"; P="$ROOT/build/prefix/lame-$arch"
  rm -rf "$W" "$P"; mkdir -p "$W" "$P"
  tar -xzf "$TARBALL" -C "$W" --strip-components=1
  cpu=$arch; [ "$arch" = arm64 ] && cpu=aarch64
  # The encoder library only: no command-line tool, no MP3 decoder, no hand-written x86 assembly.
  ( cd "$W" && sed -i "" "s/-force_cpusubtype_ALL//g" configure \
    && CC="clang -arch $arch" CFLAGS="-O2 -arch $arch -mmacosx-version-min=$MIN_MACOS" LDFLAGS="-arch $arch -mmacosx-version-min=$MIN_MACOS" \
       ./configure --prefix="$P" --host="$cpu-apple-darwin" --enable-static --disable-shared --disable-frontend --disable-decoder \
         --disable-nasm --disable-gtktest >/dev/null \
    && make -j"$JOBS" >/dev/null && make install >/dev/null )
  LIBS+=("$P/lib/libmp3lame.a")
done

rm -rf "$OUT"; mkdir -p "$OUT/lib" "$OUT/include"
lipo -create "${LIBS[@]}" -output "$OUT/lib/libmp3lame.a"
cp -R "$ROOT/build/prefix/lame-arm64/include/lame" "$OUT/include/"
lipo -info "$OUT/lib/libmp3lame.a"
