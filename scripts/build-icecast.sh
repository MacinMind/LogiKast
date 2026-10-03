#!/bin/bash
# Builds a self-contained, statically linked, universal (arm64 + x86_64) icecast
# binary for macOS. Output: build/icecast/icecast
# Usage: scripts/build-icecast.sh [arch ...]   (default: arm64 x86_64)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/third_party/src"
OUT="$ROOT/build/icecast"
MIN_MACOS=13.0
ARCHS=("$@"); [ ${#ARCHS[@]} -eq 0 ] && ARCHS=(arm64 x86_64)
for a in "${ARCHS[@]}"; do
  case "$a" in arm64|x86_64) ;; *) echo "error: unknown architecture '$a' (use arm64 and/or x86_64, or no arguments for both)" >&2; exit 1 ;; esac
done
JOBS=$(sysctl -n hw.ncpu)

# name|url  (versions pinned; checksums recorded in third_party/SHA256SUMS)
DEPS=(
  "https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.xz"
  "https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz"
  "https://download.gnome.org/sources/libxml2/2.13/libxml2-2.13.9.tar.xz"
  "https://download.gnome.org/sources/libxslt/1.1/libxslt-1.1.43.tar.xz"
  "https://github.com/rhash/RHash/archive/refs/tags/v1.4.6.tar.gz"
  "https://downloads.xiph.org/releases/igloo/libigloo-0.9.5.tar.gz"
  "https://curl.se/download/curl-8.22.0.tar.xz"
  "https://downloads.xiph.org/releases/icecast/icecast-2.5.0.tar.gz"
)

mkdir -p "$SRC"
for url in "${DEPS[@]}"; do
  f="$SRC/$(basename "$url")"
  [ -f "$f" ] || curl -fsSL -o "$f" "$url"
done
( cd "$SRC" && shasum -a 256 *.tar.* > "$ROOT/third_party/SHA256SUMS.new" )
if [ -f "$ROOT/third_party/SHA256SUMS" ]; then
  ( cd "$SRC" && shasum -a 256 -c "$ROOT/third_party/SHA256SUMS" )
else
  mv "$ROOT/third_party/SHA256SUMS.new" "$ROOT/third_party/SHA256SUMS"
fi
rm -f "$ROOT/third_party/SHA256SUMS.new"

unpack() { # $1=tarball-glob prefix, $2=workdir
  rm -rf "$2"; mkdir -p "$2"
  tar -xf "$(ls "$SRC"/$1* | head -1)" -C "$2" --strip-components=1
}

build_arch() {
  local arch=$1
  local W="$ROOT/build/work/$arch" P="$ROOT/build/prefix/$arch"
  rm -rf "$W" "$P"; mkdir -p "$W" "$P"
  local cpu=$arch; [ "$arch" = arm64 ] && cpu=aarch64; local host="$cpu-apple-darwin"
  export CC="clang -arch $arch" CXX="clang++ -arch $arch"
  export CFLAGS="-O2 -arch $arch -mmacosx-version-min=$MIN_MACOS -I$P/include"
  export LDFLAGS="-arch $arch -mmacosx-version-min=$MIN_MACOS -L$P/lib"
  export PKG_CONFIG_PATH="$P/lib/pkgconfig" PKG_CONFIG_LIBDIR="$P/lib/pkgconfig"
  export MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS
  local common=(--prefix="$P" --host="$host" --enable-static --disable-shared)

  echo "== [$arch] libogg";    unpack libogg "$W/ogg";       (cd "$W/ogg"    && ./configure "${common[@]}" >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)
  echo "== [$arch] libvorbis"; unpack libvorbis "$W/vorbis"; (cd "$W/vorbis" && sed -i "" "s/-force_cpusubtype_ALL//g" configure && ./configure "${common[@]}" --disable-examples --disable-docs >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)
  echo "== [$arch] libxml2";   unpack libxml2 "$W/xml2";     (cd "$W/xml2"   && ./configure "${common[@]}" --without-python --without-lzma --without-zlib --without-icu --without-readline --without-http --without-ftp >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)
  echo "== [$arch] libxslt";   unpack libxslt "$W/xslt";     (cd "$W/xslt"   && ./configure "${common[@]}" --without-python --without-crypto --without-plugins --with-libxml-prefix="$P" >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)
  echo "== [$arch] rhash";     unpack v1.4.6 "$W/rhash";     (cd "$W/rhash"  && ./configure --prefix="$P" --enable-lib-static --disable-lib-shared --disable-openssl --disable-gettext --disable-symlinks --cc="clang -arch $arch" --extra-cflags="-mmacosx-version-min=$MIN_MACOS" >/dev/null && make -j"$JOBS" lib-static >/dev/null && make install-lib-static install-lib-headers >/dev/null)
  echo "== [$arch] libigloo";  unpack libigloo "$W/igloo";   (cd "$W/igloo"  && ./configure "${common[@]}" >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)
  echo "== [$arch] curl";      unpack curl "$W/curl";        (cd "$W/curl"   && ./configure "${common[@]}" --without-ssl --without-libpsl --without-zlib --without-brotli --without-zstd --without-nghttp2 --without-libidn2 --disable-ldap --disable-ipv6 --disable-manual --disable-docs >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)
  echo "== [$arch] icecast";   unpack icecast "$W/icecast"
  for p in "$ROOT"/third_party/patches/*.patch; do (cd "$W/icecast" && patch -p1 < "$p"); done
  # Static link: force the .a archives; macOS system libs (libz, libresolv, libc++) stay dynamic.
  (cd "$W/icecast" && ./configure "${common[@]}" --without-openssl --without-theora --without-speex --without-maxminddb \
      --sysconfdir="$P/etc" --localstatedir="$P/var" >/dev/null && make -j"$JOBS" >/dev/null && make install >/dev/null)
}

for a in "${ARCHS[@]}"; do build_arch "$a"; done

mkdir -p "$OUT"
BINS=(); for a in "${ARCHS[@]}"; do BINS+=("$ROOT/build/prefix/$a/bin/icecast"); done
lipo -create "${BINS[@]}" -output "$OUT/icecast"
# Icecast's runtime assets (admin XSLT + web root) ship alongside the binary.
rm -rf "$OUT/share"; mkdir -p "$OUT/share"
cp -R "$ROOT/build/prefix/${ARCHS[0]}/share/icecast/." "$OUT/share/"
echo "== done"; lipo -info "$OUT/icecast"; otool -L "$OUT/icecast"
