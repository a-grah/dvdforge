#!/bin/zsh
# Builds the vendored native dependencies (libdvdcss, libdvdread, a minimal FFmpeg)
# as static libraries for arm64 + x86_64, merges them into one universal static
# library and wraps it as Vendor/build/DiscDeps.xcframework.
#
# Usage: Scripts/build-deps.sh [--force]
# Skips work when the xcframework already exists unless --force is given.
set -euo pipefail

ROOT="${0:A:h:h}"
SRC="$ROOT/Vendor/src"
OUT="$ROOT/Vendor/build"
WORK="$OUT/work"
XCF="$OUT/DiscDeps.xcframework"
ARCHS=(arm64 x86_64)
export MACOSX_DEPLOYMENT_TARGET=15.0
JOBS=$(sysctl -n hw.ncpu)

if [[ -d "$XCF" && "${1:-}" != "--force" ]]; then
  echo "DiscDeps.xcframework is up to date (use --force to rebuild)"
  exit 0
fi

# Xcode run-script phases inherit a sanitized PATH; make sure Homebrew tools are visible.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
for tool in meson ninja pkg-config; do
  command -v $tool >/dev/null || { echo "error: $tool not found (brew install $tool)"; exit 1; }
done

rm -rf "$WORK" "$XCF"
mkdir -p "$WORK"

cross_file() {  # $1 = arch, $2 = prefix
  local cpu=$1; [[ $1 == arm64 ]] && cpu=aarch64
  cat > "$WORK/cross-$1.ini" <<EOF
[binaries]
c = ['clang', '-arch', '$1', '-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET']
objc = ['clang', '-arch', '$1', '-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'

[properties]
# Only ever resolve dependencies from our own prefix, never from Homebrew.
pkg_config_libdir = ['$2/lib/pkgconfig']

[host_machine]
system = 'darwin'
cpu_family = '$cpu'
cpu = '$cpu'
endian = 'little'
EOF
  echo "$WORK/cross-$1.ini"
}

build_meson() {  # $1 = project, $2 = arch, $3 = prefix, rest = meson options
  local proj=$1 arch=$2 prefix=$3; shift 3
  local bdir="$WORK/$proj-$arch"
  # The projects generate a ChangeLog via `git log`; point it at the submodule's own repo.
  export GIT_DIR="$(git -C "$SRC/$proj" rev-parse --absolute-git-dir)"
  meson setup "$bdir" "$SRC/$proj" --cross-file "$(cross_file $arch $prefix)" \
    --prefix "$prefix" --libdir lib --default-library static --buildtype release \
    -Db_staticpic=true "$@"
  ninja -C "$bdir" install
  unset GIT_DIR
}

build_ffmpeg() {  # $1 = arch, $2 = prefix
  local arch=$1 prefix=$2 bdir="$WORK/ffmpeg-$1"
  mkdir -p "$bdir"
  (cd "$bdir" && "$SRC/ffmpeg/configure" \
    --prefix="$prefix" --enable-cross-compile --target-os=darwin --arch="$arch" \
    --cc="clang -arch $arch" --extra-cflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
    --extra-ldflags="-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
    --enable-static --disable-shared --enable-pic \
    --disable-autodetect --disable-programs --disable-doc --disable-network \
    --disable-avdevice --disable-avfilter --disable-swscale --disable-swresample \
    --disable-x86asm \
    --disable-everything \
    --enable-demuxer=mpegps \
    --enable-muxer=matroska \
    --enable-parser=mpegvideo,ac3,dca,mlp,mpegaudio,dvdsub \
    --enable-decoder=dvdsub,pcm_dvd \
    --enable-encoder=flac \
    --enable-protocol=file)
  make -C "$bdir" -j$JOBS install
}

LIBS=()
for arch in $ARCHS; do
  prefix="$WORK/prefix-$arch"
  echo "==> Building for $arch"
  build_meson libdvdcss $arch $prefix
  build_meson libdvdread $arch $prefix -Dlibdvdcss=enabled
  build_ffmpeg $arch $prefix
  # One merged static archive per arch.
  libtool -static -o "$WORK/libDiscDeps-$arch.a" \
    $prefix/lib/{libdvdcss,libdvdread,libavformat,libavcodec,libavutil}.a
  LIBS+=("$WORK/libDiscDeps-$arch.a")
done

echo "==> Creating universal library and xcframework"
mkdir -p "$WORK/universal"
lipo -create $LIBS -output "$WORK/universal/libDiscDeps.a"
# Headers are architecture independent; take them from the first prefix.
cp -R "$WORK/prefix-${ARCHS[1]}/include" "$WORK/universal/include"
xcodebuild -create-xcframework \
  -library "$WORK/universal/libDiscDeps.a" -headers "$WORK/universal/include" \
  -output "$XCF"

rm -rf "$WORK"
echo "==> Done: $XCF"
