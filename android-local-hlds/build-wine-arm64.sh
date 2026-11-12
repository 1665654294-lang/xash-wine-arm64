#!/usr/bin/env bash
# build-wine-arm64.sh
# 从源码编出「能直接塞进 Android APK 的 arm64 Wine + wowbox64」。
#
# 与 host-build.sh 的区别（重要）：
#   host-build.sh 编的是 x86_64 Wine，再由 box64 主程序去跑它 —— 那是「整个 Wine 都进模拟器」，
#   慢，还要一整套 x86_64 系统库。
#   本脚本编的是 **arm64 原生 Wine**，32 位 PE 交给 box64 编出来的 **wowbox64.dll**（一个 PE dll），
#   模拟边界只在 Win32 syscall 层。
#
# 关键技巧：--prefix 直接写成 Android 的私有目录路径，make install 用 DESTDIR 挪到暂存区。
#   这样产物解压到 /data/data/<包名>/files/ 下就能直接跑，**不需要 proot**。
#
# 用法：
#   APP_ID=su.xash.engine ./build-wine-arm64.sh
#
# 必须在 **aarch64 Linux** 上跑（原生 arm64 机器、arm64 runner、或 docker --platform linux/arm64）。
#   x86_64 机器上要交叉编 wine，得走 Debian multiarch（dpkg-buildpackage -a arm64），麻烦得多。

set -euo pipefail

APP_ID="${APP_ID:-su.xash.engine}"
ANDROID_PREFIX="/data/data/$APP_ID/files/usr"

WORK="${WORK:-$HOME/wine-arm64-build}"
WINE_SRC="${WINE_SRC:-/mnt/d/wine-wine-11.21/wine-wine-11.21}"
BOX64_SRC="${BOX64_SRC:-/mnt/d/games/box64-0.4.4/box64-0.4.4}"
LLVM_MINGW_VER="${LLVM_MINGW_VER:-20261104}"
LLVM_MINGW_DIR="$WORK/llvm-mingw"
STAGE="$WORK/stage"
JOBS="${JOBS:-$(nproc)}"

# 服务器场景：不要图形、不要音频、不要 Vulkan。hlds 是纯 console 程序。
WINE_CONFIGURE_FLAGS="${WINE_CONFIGURE_FLAGS:---disable-tests --with-mingw=clang --enable-archs=arm64ec,aarch64,i386 --without-x --without-freetype --without-fontconfig --without-pulse --without-oss --without-alsa --without-vulkan --without-opengl}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

# ------------------------------------------------------------------ 0. 自检
[ "$(uname -m)" = "aarch64" ] || die "必须在 aarch64 主机上跑（当前 $(uname -m)）。x86_64 请用 docker --platform linux/arm64 或 arm64 runner"
[ -f "$WINE_SRC/configure" ] || die "找不到 Wine 源码：$WINE_SRC"
[ -f "$BOX64_SRC/CMakeLists.txt" ] || die "找不到 box64 源码：$BOX64_SRC"
grep -q 'WOW64' "$BOX64_SRC/CMakeLists.txt" || die "这份 box64 没有 WOW64 选项，需要 0.4.x 以上"

mkdir -p "$WORK" "$STAGE"

# ------------------------------------------------------------------ 1. 依赖
log "安装构建依赖（Ubuntu/Debian）"
sudo apt-get update -y
sudo apt-get install -y \
    build-essential cmake ninja-build pkg-config git curl xz-utils \
    bison flex gettext autoconf automake libtool \
    libgnutls28-dev libxml2-dev libxslt1-dev libssl-dev \
    libosmesa6-dev

# ------------------------------------------------------------------ 2. llvm-mingw
log "准备 llvm-mingw（PE 交叉编译用）"
if [ ! -x "$LLVM_MINGW_DIR/bin/aarch64-w64-mingw32-clang" ]; then
    TARBALL="$WORK/llvm-mingw.tar.xz"
    # 宿主是 arm64 → 取 aarch64 版；Hangover 的 Dockerfile 是 x86_64 宿主所以用 x86_64 版，别抄错
    URL="https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VER}/llvm-mingw-${LLVM_MINGW_VER}-ucrt-ubuntu-22.04-aarch64.tar.xz"
    if [ ! -f "$TARBALL" ]; then
        log "下载 $URL"
        curl -fL --retry 3 -o "$TARBALL" "$URL" \
          || die "下载失败。去 https://github.com/mstorsjo/llvm-mingw/releases 找一个 ubuntu-22.04-aarch64 的 tar.xz，
        用 LLVM_MINGW_VER=<tag> 重跑，或手动解到 $LLVM_MINGW_DIR 再跑（脚本会跳过下载）"
    fi
    rm -rf "$LLVM_MINGW_DIR"; mkdir -p "$LLVM_MINGW_DIR"
    tar -xf "$TARBALL" -C "$LLVM_MINGW_DIR" --strip-components=1
fi
export PATH="$LLVM_MINGW_DIR/bin:$PATH"
command -v aarch64-w64-mingw32-clang >/dev/null \
    || die "llvm-mingw 的 aarch64-w64-mingw32-clang 不可用，检查 $LLVM_MINGW_DIR/bin"
log "llvm-mingw ok: $(aarch64-w64-mingw32-clang --version | head -1)"

# ------------------------------------------------------------------ 3. wowbox64.dll
log "编译 wowbox64.dll（32 位 PE 的 box64 后端）"
rm -rf "$BOX64_SRC/build_pe"
cmake -S "$BOX64_SRC" -B "$BOX64_SRC/build_pe" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=cc \
    -DARM_DYNAREC=ON \
    -DWOW64=ON
cmake --build "$BOX64_SRC/build_pe" --target wowbox64 -j "$JOBS"

WOWBOX64="$(find "$BOX64_SRC/build_pe" -name 'wowbox64.dll' -type f | head -1)"
[ -n "$WOWBOX64" ] || die "没有找到 wowbox64.dll"
log "wowbox64.dll: $WOWBOX64 ($(stat -c%s "$WOWBOX64") bytes)"

# ------------------------------------------------------------------ 4. Wine（arm64）
log "编译 Wine（arm64 unix + i386 PE）"
WINE_BUILD="$WORK/wine-build"
rm -rf "$WINE_BUILD"; mkdir -p "$WINE_BUILD"
cd "$WINE_BUILD"

# --prefix 写成 Android 私有目录：编进 ELF 的所有安装路径都指向它
# shellcheck disable=SC2086
"$WINE_SRC/configure" \
    --prefix="$ANDROID_PREFIX" \
    $WINE_CONFIGURE_FLAGS

make -j "$JOBS"

log "安装到暂存区（DESTDIR）"
make install DESTDIR="$STAGE"

# ------------------------------------------------------------------ 5. 装上 wowbox64.dll
WINE_PE_DIR="$STAGE$ANDROID_PREFIX/lib/wine/aarch64-windows"
[ -d "$WINE_PE_DIR" ] || die "wine 没有产出 aarch64-windows 目录：$WINE_PE_DIR（检查 --enable-archs 是否含 aarch64）"
install -m 0644 "$WOWBOX64" "$WINE_PE_DIR/wowbox64.dll"
log "已放入 $WINE_PE_DIR/wowbox64.dll"

# ------------------------------------------------------------------ 6. 打包
log "打包"
OUT="$WORK/out"
mkdir -p "$OUT"
TAR="$OUT/wine-arm64-$APP_ID.tar.gz"
tar -C "$STAGE" -czf "$TAR" .

log "完成：$TAR  ($(du -h "$TAR" | cut -f1))"
cat <<EOF

产物结构（解压后可直接落到 /data/data/$APP_ID/files/）：
  data/data/$APP_ID/files/usr/bin/wine
  data/data/$APP_ID/files/usr/lib/wine/aarch64-windows/wowbox64.dll
  data/data/$APP_ID/files/usr/lib/wine/aarch64-windows/...

APK 里怎么用：
  1) 把 tar 解到 filesDir，得到 <filesDir>/usr/...
  2) 设 WINEPREFIX=<filesDir>/wineprefix（可写，别让它指向 usr）
  3) exec：<filesDir>/usr/bin/wine hlds.exe ...（HODLL=wowbox64.dll）
  4) wine 的 bin 目录和 lib 目录要放进 LD_LIBRARY_PATH

验证（在手机上用 adb shell 先跑）：
  <filesDir>/usr/bin/wine --version
  HODLL=wowbox64.dll <filesDir>/usr/bin/wine cmd /c echo ok
EOF
