#!/usr/bin/env bash
# 在 WSL Ubuntu 中交叉编译本项目用的 LGPL 裁剪 ffmpeg.exe（无 GPL / 无 libx264）
# 用法（WSL）:
#   bash /mnt/d/tmp/DiuBangWenJian_Windows/tool/build_ffmpeg_lgpl_wsl.sh
# 前提:
#   1) 源码在 /mnt/d/ffmpeg（Windows: D:\ffmpeg），版本约 n8.1.x
#   2) 已装: mingw-w64 nasm yasm pkg-config git
#   3) 本机 gcc: sudo apt install build-essential
#      （若无 sudo，脚本会尝试用 ~/opt/host-gcc 用户态解包的 gcc）

set -euo pipefail

SRC_WIN="${SRC_WIN:-/mnt/d/ffmpeg}"
OUT_ASSET="${OUT_ASSET:-/mnt/d/tmp/DiuBangWenJian_Windows/assets/ffmpeg.exe}"
WORK="${WORK:-$HOME/ffmpeg-build-lgpl}"
OPENH264_PREFIX="$WORK/openh264-mingw"
FFMPEG_PREFIX="$WORK/ffmpeg-mingw64"
JOBS="$(nproc)"

if [[ ! -x "$SRC_WIN/configure" ]]; then
  echo "找不到源码: $SRC_WIN/configure"
  exit 1
fi

# ---- host gcc ----
if command -v gcc >/dev/null 2>&1; then
  HOST_CC="$(command -v gcc)"
else
  ROOT="$HOME/opt/host-gcc/root"
  if [[ ! -x "$ROOT/usr/bin/gcc" ]]; then
    echo "未找到系统 gcc。请先执行: sudo apt-get install -y build-essential"
    echo "或按文档用 apt-get download + dpkg-deb 解包到 ~/opt/host-gcc"
    exit 1
  fi
  mkdir -p "$HOME/bin"
  cat > "$HOME/bin/host-gcc" <<'EOF'
#!/bin/bash
ROOT="$HOME/opt/host-gcc/root"
export PATH="$ROOT/usr/bin:$PATH"
exec "$ROOT/usr/bin/gcc" --sysroot="$ROOT" "$@"
EOF
  chmod +x "$HOME/bin/host-gcc"
  HOST_CC="$HOME/bin/host-gcc"
  export PATH="$HOME/bin:$ROOT/usr/bin:$PATH"
fi

command -v x86_64-w64-mingw32-gcc >/dev/null || {
  echo "缺少 mingw: sudo apt-get install -y mingw-w64 g++-mingw-w64-x86-64"
  exit 1
}

mkdir -p "$WORK"
rsync -a --delete \
  --exclude ".git" \
  --exclude "ffbuild/config.*" \
  --exclude "ffbuild/.config" \
  "$SRC_WIN/" "$WORK/ffmpeg/"

# 防止 configure 生成物冲掉 ffbuild 辅助文件：从源再补一份 mak
cp -a "$SRC_WIN/ffbuild/common.mak" \
      "$SRC_WIN/ffbuild/arch.mak" \
      "$SRC_WIN/ffbuild/library.mak" \
      "$SRC_WIN/ffbuild/bin2c.c" \
      "$SRC_WIN/ffbuild/"*.sh \
      "$WORK/ffmpeg/ffbuild/" 2>/dev/null || true

find "$WORK/ffmpeg" -type f \( -name configure -o -name "*.sh" -o -name "Makefile*" \) \
  -print0 | xargs -0 sed -i 's/\r$//' || true

# ---- OpenH264 (BSD) ----
if [[ ! -f "$OPENH264_PREFIX/lib/libopenh264.a" ]]; then
  cd "$WORK"
  rm -rf openh264
  git clone --depth 1 https://github.com/cisco/openh264.git openh264 \
    || git clone --depth 1 https://gitee.com/mirrors/openh264.git openh264
  cd openh264
  make -j"$JOBS" \
    OS=mingw_nt ARCH=x86_64 \
    CC=x86_64-w64-mingw32-gcc \
    CXX=x86_64-w64-mingw32-g++ \
    AR=x86_64-w64-mingw32-ar \
    PREFIX="$OPENH264_PREFIX" \
    install
fi

mkdir -p "$OPENH264_PREFIX/lib/pkgconfig"
cat > "$OPENH264_PREFIX/lib/pkgconfig/openh264.pc" <<EOF
prefix=$OPENH264_PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: openh264
Version: 2.6.0
Libs: -L\${libdir} -lopenh264
Cflags: -I\${includedir}
EOF
export PKG_CONFIG_PATH="$OPENH264_PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$OPENH264_PREFIX/lib/pkgconfig"

# ---- configure + build ----
cd "$WORK/ffmpeg"
make distclean 2>/dev/null || true
# distclean 可能清掉 mak，再补一次
cp -a "$SRC_WIN/ffbuild/common.mak" \
      "$SRC_WIN/ffbuild/arch.mak" \
      "$SRC_WIN/ffbuild/library.mak" \
      "$SRC_WIN/ffbuild/bin2c.c" \
      "$SRC_WIN/ffbuild/"*.sh \
      ffbuild/ 2>/dev/null || true

./configure \
  --prefix="$FFMPEG_PREFIX" \
  --enable-cross-compile \
  --cross-prefix=x86_64-w64-mingw32- \
  --arch=x86_64 \
  --target-os=mingw32 \
  --pkg-config=pkg-config \
  --cc=x86_64-w64-mingw32-gcc \
  --cxx=x86_64-w64-mingw32-g++ \
  --host-cc="$HOST_CC" \
  --enable-static \
  --disable-shared \
  --disable-debug \
  --disable-doc \
  --disable-everything \
  --enable-ffmpeg \
  --disable-ffprobe \
  --disable-ffplay \
  --disable-network \
  --enable-libopenh264 \
  --enable-protocol=file,pipe \
  --enable-demuxer=mov,matroska,avi,asf,ogg,flv,mpegts,mp3,aac,wav,image2 \
  --enable-muxer=hls,mpegts,mp4,image2,image2pipe \
  --enable-decoder=h264,hevc,vp8,vp9,mpeg4,mpeg2video,mjpeg,aac,mp3,ac3,opus,vorbis,flac,pcm_s16le \
  --enable-encoder=libopenh264,aac,mjpeg \
  --enable-parser=h264,hevc,vp9,mpeg4video,aac,mpegaudio,ac3,opus \
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,aac_adtstoasc \
  --enable-filter=format,scale,aresample \
  --enable-swscale \
  --enable-swresample \
  --enable-avfilter \
  --extra-cflags="-Os -I${OPENH264_PREFIX}/include" \
  --extra-ldflags="-L${OPENH264_PREFIX}/lib -static -static-libgcc -static-libstdc++" \
  --extra-libs="-lopenh264 -lpthread -lwinpthread -lstdc++"

# configure 后再补 mak（防止生成物目录冲掉）
cp -a "$SRC_WIN/ffbuild/common.mak" \
      "$SRC_WIN/ffbuild/arch.mak" \
      "$SRC_WIN/ffbuild/library.mak" \
      "$SRC_WIN/ffbuild/bin2c.c" \
      "$SRC_WIN/ffbuild/"*.sh \
      ffbuild/ 2>/dev/null || true

make -j"$JOBS"
make install

mkdir -p "$(dirname "$OUT_ASSET")"
cp -f "$FFMPEG_PREFIX/bin/ffmpeg.exe" "$OUT_ASSET"
cp -f "$FFMPEG_PREFIX/bin/ffmpeg.exe" /mnt/d/ffmpeg/ffmpeg-lgpl-min.exe

echo "==== done ===="
ls -lh "$OUT_ASSET"
"$OUT_ASSET" -hide_banner -buildconf | head -20
"$OUT_ASSET" -hide_banner -encoders | grep -E 'libopenh264|mjpeg| aac'
