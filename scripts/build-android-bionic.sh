#!/usr/bin/env bash
# MangoHud Winlator Bionic (Android aarch64) build script
# Runs on Ubuntu (GitHub Actions) with Android NDK installed.
set -euo pipefail

# ---------------------------------------------------------------------------
# Paths (overridable via environment variables)
# ---------------------------------------------------------------------------
WORKSPACE="${GITHUB_WORKSPACE:-$(pwd)}"
NDK_VERSION="${NDK_VERSION:-r27c}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-${WORKSPACE}/android-ndk-${NDK_VERSION}}"
NDK_BIN="${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin"
LIBDRM_DIR="${WORKSPACE}/libdrm-headers"
BUILD_DIR="build-bionic"

echo "==> WORKSPACE        = ${WORKSPACE}"
echo "==> ANDROID_NDK_HOME = ${ANDROID_NDK_HOME}"
echo "==> NDK_BIN          = ${NDK_BIN}"

# ---------------------------------------------------------------------------
# 1. System packages (only on GitHub Actions / apt systems)
# ---------------------------------------------------------------------------
if command -v apt-get >/dev/null 2>&1; then
  echo "==> Installing system build dependencies"
  sudo apt-get update -qq
  sudo apt-get install -y -qq meson ninja-build python3-pip glslang-dev \
    libx11-dev libxext-dev pkg-config zip git
  pip3 install --quiet mako || true
fi

# glslangValidator: prefer system, fall back to checking PATH
if ! command -v glslangValidator >/dev/null 2>&1; then
  echo "WARNING: glslangValidator not found in PATH"
fi

# ---------------------------------------------------------------------------
# 2. Download Android NDK if missing
# ---------------------------------------------------------------------------
if [ ! -d "${ANDROID_NDK_HOME}" ]; then
  echo "==> Downloading Android NDK ${NDK_VERSION}"
  cd "${WORKSPACE}"
  wget -q "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip"
  unzip -q "android-ndk-${NDK_VERSION}-linux.zip"
  cd -
fi

# ---------------------------------------------------------------------------
# 3. Prepare libdrm headers (header-only, no linking needed)
# ---------------------------------------------------------------------------
if [ ! -d "${LIBDRM_DIR}" ]; then
  echo "==> Cloning libdrm headers"
  git clone --depth 1 https://gitlab.freedesktop.org/mesa/drm.git "${LIBDRM_DIR}"
  ln -sf drm "${LIBDRM_DIR}/include/libdrm"
fi

# ---------------------------------------------------------------------------
# 4. Generate the meson cross file
# ---------------------------------------------------------------------------
echo "==> Generating cross file"
cat > cross-aarch64-android.txt <<CROSSFILE
[binaries]
c = '${NDK_BIN}/aarch64-linux-android26-clang'
cpp = '${NDK_BIN}/aarch64-linux-android26-clang++'
ar = '${NDK_BIN}/llvm-ar'
strip = '${NDK_BIN}/llvm-strip'
ld = '${NDK_BIN}/ld.lld'

[built-in options]
c_args = ['-fPIC', '-fdata-sections', '-ffunction-sections', '-Wno-unused-command-line-argument', '-I/usr/include', '-I${LIBDRM_DIR}/include', '-I${LIBDRM_DIR}/include/drm', '-DHAVE_X11']
cpp_args = ['-fPIC', '-fdata-sections', '-ffunction-sections', '-Wno-unused-command-line-argument', '-std=c++20', '-I/usr/include', '-I${LIBDRM_DIR}/include', '-I${LIBDRM_DIR}/include/drm', '-DHAVE_X11']
c_link_args = ['-Wl,--gc-sections', '-Wl,-z,max-page-size=16384', '-Wl,--undefined-version']
cpp_link_args = ['-Wl,--gc-sections', '-Wl,-z,max-page-size=16384', '-Wl,--undefined-version']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
CROSSFILE

# ---------------------------------------------------------------------------
# 5. Meson setup
# ---------------------------------------------------------------------------
echo "==> Meson setup"
rm -rf "${BUILD_DIR}"
meson setup "${BUILD_DIR}" \
  --cross-file=cross-aarch64-android.txt \
  --prefix=/usr --libdir=lib \
  -Dwith_x11=disabled -Dwith_wayland=disabled -Dwith_dbus=disabled \
  -Dwith_xnvctrl=disabled -Dwith_nvml=disabled \
  -Dmangoapp=false -Dmangohudctl=false -Dtests=disabled -Dinclude_doc=false \
  -Dimgui:opengl=disabled -Dimgui:sdl2=disabled -Dimgui:glfw=disabled \
  -Dwith_mangohud_next=false -Dwith_server=false \
  -Dbuildtype=release -Dstrip=true

# ---------------------------------------------------------------------------
# 6. Build
# ---------------------------------------------------------------------------
echo "==> Building"
ninja -C "${BUILD_DIR}" -j"$(nproc)"

# ---------------------------------------------------------------------------
# 7. Strip
# ---------------------------------------------------------------------------
echo "==> Stripping libraries"
STRIP="${NDK_BIN}/llvm-strip"
"${STRIP}" --strip-unneeded "${BUILD_DIR}/src/libMangoHud.so"
"${STRIP}" --strip-unneeded "${BUILD_DIR}/src/libMangoHud_opengl.so"
"${STRIP}" --strip-unneeded "${BUILD_DIR}/src/libMangoHud_shim.so"
ls -lh "${BUILD_DIR}/src/libMangoHud"*.so

# ---------------------------------------------------------------------------
# 8. Package
# ---------------------------------------------------------------------------
echo "==> Packaging"
rm -rf release
mkdir -p release/lib/mangohud
cp "${BUILD_DIR}/src/libMangoHud.so"          release/lib/mangohud/
cp "${BUILD_DIR}/src/libMangoHud_opengl.so"   release/lib/mangohud/
cp "${BUILD_DIR}/src/libMangoHud_shim.so"     release/lib/mangohud/
cp cross-aarch64-android.txt                  release/

cat > release/README.txt <<'README'
MangoHud Winlator Bionic (Android aarch64)

Install:
  1. Copy lib/mangohud/*.so to imagefs /lib/mangohud/
  2. Put MangoHud.conf at imagefs /home/MangoHud.conf
  3. Ensure the Vulkan implicit layer json uses forced mode with a
     relative library_path (../../../lib/mangohud/libMangoHud.so)
README

cd release
zip -r ../MangoHud-Winlator-bionic-aarch64.zip .
cd ..
ls -lh MangoHud-Winlator-bionic-aarch64.zip
echo "==> Done"
