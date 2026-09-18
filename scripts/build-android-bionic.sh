#!/usr/bin/env bash
# MangoHud Winlator Bionic (Android aarch64) build for GitHub Actions (Ubuntu 24.04)
set -euo pipefail

WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
BUILD_DIR="build-bionic"

echo "=================== [1/9] Locate Android NDK ==================="
# GitHub runners set ANDROID_NDK_HOME to a concrete NDK dir (e.g. .../ndk/27.3.x),
# not the ndk parent dir. Detect both layouts.
NDK_DIR=""
for candidate in "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK_HOME:-}"; do
  if [ -n "$candidate" ] && [ -d "$candidate/toolchains/llvm/prebuilt/linux-x86_64/bin" ]; then
    NDK_DIR="$candidate"
    break
  fi
done
if [ -z "$NDK_DIR" ]; then
  NDK_PARENT="${ANDROID_HOME:-/usr/local/lib/android/sdk}/ndk"
  if [ -d "$NDK_PARENT" ]; then
    NDK_DIR="$(ls -d "${NDK_PARENT}"/27.* 2>/dev/null | sort -V | tail -1 || true)"
  fi
fi
if [ -z "$NDK_DIR" ] || [ ! -d "$NDK_DIR" ]; then
  echo "Pre-installed NDK 27.x not found, downloading NDK r27c ..."
  cd "$WORKSPACE"
  wget -q "https://dl.google.com/android/repository/android-ndk-r27c-linux.zip"
  unzip -q "android-ndk-r27c-linux.zip"
  NDK_DIR="$WORKSPACE/android-ndk-r27c"
  cd -
fi
NDK_BIN="$NDK_DIR/toolchains/llvm/prebuilt/linux-x86_64/bin"
echo "Using NDK: $NDK_DIR"
test -x "$NDK_BIN/aarch64-linux-android26-clang"
"$NDK_BIN/aarch64-linux-android26-clang" --version | head -1

echo "=================== [2/9] Host dependencies ==================="
sudo apt-get update -qq
# glslang-tools provides /usr/bin/glslangValidator on 24.04
# libdrm-dev provides /usr/include/libdrm/*.h (header-only use for the build)
# libx11-dev provides the X11 headers (loaded via dlopen at runtime)
sudo apt-get install -y -qq \
  glslang-tools libdrm-dev libx11-dev libxext-dev \
  python3-mako \
  ninja-build pkg-config zip curl ca-certificates

# Ubuntu 24.04 apt meson is 1.4 (too old, MangoHud needs >= 1.7); install newest via pipx
export PATH="$HOME/.local/bin:$PATH"
pipx install meson || pipx upgrade meson
pipx ensurepath >/dev/null 2>&1 || true
echo "meson: $(meson --version)"
echo "ninja: $(ninja --version)"
echo "glslangValidator: $(command -v glslangValidator)"

echo "=================== [3/9] Prepare clean cross-include dir ==================="
# CRITICAL: do NOT use -I/usr/include for the Android cross build.
# /usr/include contains glibc headers that override bionic headers and break
# meson's compiler sanity check ("cannot compile programs").
# Instead symlink only the X11/ and libdrm/ subdirs into a clean directory.
CROSS_INCLUDE="$WORKSPACE/cross-include"
rm -rf "$CROSS_INCLUDE"
mkdir -p "$CROSS_INCLUDE"
ln -s /usr/include/X11    "$CROSS_INCLUDE/X11"
ln -s /usr/include/libdrm "$CROSS_INCLUDE/libdrm"
echo "Clean cross-include at: $CROSS_INCLUDE"
ls -la "$CROSS_INCLUDE"

echo "=================== [4/9] Generate cross file ==================="
cat > cross-aarch64-android.txt <<CROSSFILE
[binaries]
c = '${NDK_BIN}/aarch64-linux-android26-clang'
cpp = '${NDK_BIN}/aarch64-linux-android26-clang++'
ar = '${NDK_BIN}/llvm-ar'
strip = '${NDK_BIN}/llvm-strip'
ld = '${NDK_BIN}/ld.lld'

[built-in options]
c_args = ['-fPIC', '-fdata-sections', '-ffunction-sections', '-Wno-unused-command-line-argument', '-I${CROSS_INCLUDE}', '-I${CROSS_INCLUDE}/libdrm', '-DHAVE_X11']
cpp_args = ['-fPIC', '-fdata-sections', '-ffunction-sections', '-Wno-unused-command-line-argument', '-std=c++20', '-I${CROSS_INCLUDE}', '-I${CROSS_INCLUDE}/libdrm', '-DHAVE_X11']
c_link_args = ['-Wl,--gc-sections', '-Wl,-z,max-page-size=16384', '-Wl,--undefined-version']
cpp_link_args = ['-Wl,--gc-sections', '-Wl,-z,max-page-size=16384', '-Wl,--undefined-version']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
CROSSFILE
echo "Cross file written:"
cat cross-aarch64-android.txt

echo "=================== [5/9] Meson setup ==================="
rm -rf "$BUILD_DIR"
meson setup "$BUILD_DIR" \
  --cross-file=cross-aarch64-android.txt \
  --prefix=/usr --libdir=lib \
  -Dwith_x11=disabled -Dwith_wayland=disabled -Dwith_dbus=disabled \
  -Dwith_xnvctrl=disabled -Dwith_nvml=disabled \
  -Dmangoapp=false -Dmangohudctl=false -Dtests=disabled -Dinclude_doc=false \
  -Dimgui:opengl=disabled -Dimgui:sdl2=disabled -Dimgui:glfw=disabled \
  -Dwith_mangohud_next=false -Dwith_server=false \
  -Dbuildtype=release -Dstrip=true

echo "=================== [6/9] Build ==================="
ninja -C "$BUILD_DIR" -j"$(nproc)"

echo "=================== [7/9] Strip ==================="
STRIP="$NDK_BIN/llvm-strip"
"$STRIP" --strip-unneeded "$BUILD_DIR/src/libMangoHud.so"
"$STRIP" --strip-unneeded "$BUILD_DIR/src/libMangoHud_opengl.so"
"$STRIP" --strip-unneeded "$BUILD_DIR/src/libMangoHud_shim.so"
ls -lh "$BUILD_DIR/src/libMangoHud"*.so

echo "=================== [8/9] Verify ELF ==================="
"$NDK_BIN/llvm-readelf" -h "$BUILD_DIR/src/libMangoHud.so" | grep -E "Machine|Type"
"$NDK_BIN/llvm-readelf" -d "$BUILD_DIR/src/libMangoHud.so" | grep NEEDED || true

echo "=================== [9/9] Package ==================="
rm -rf release
mkdir -p release/lib/mangohud
cp "$BUILD_DIR/src/libMangoHud.so"        release/lib/mangohud/
cp "$BUILD_DIR/src/libMangoHud_opengl.so" release/lib/mangohud/
cp "$BUILD_DIR/src/libMangoHud_shim.so"   release/lib/mangohud/
cp cross-aarch64-android.txt              release/
cat > release/README.txt <<'README'
MangoHud Winlator Bionic (Android aarch64)

Install:
  1. Copy lib/mangohud/*.so to imagefs /lib/mangohud/
  2. Put MangoHud.conf at imagefs /home/MangoHud.conf
  3. Vulkan implicit layer json must use forced mode with a relative
     library_path (../../../lib/mangohud/libMangoHud.so)
README
(cd release && zip -r ../MangoHud-Winlator-bionic-aarch64.zip .)
ls -lh MangoHud-Winlator-bionic-aarch64.zip
echo "==> Build finished successfully"
