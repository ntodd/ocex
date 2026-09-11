#!/bin/sh
# Install the exact supported OCCT release without changing a system package manager.
set -eu
version=7.9.3
checksum=5ecf094ec6b12d5413dfb851d8c3590c354058aee556e32e408bdfbf8c357d57
prefix=${1:-"$HOME/.local/occt-$version"}
jobs=${OCEX_BUILD_JOBS:-4}
for tool in cmake curl tar patch c++; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing $tool. Install CMake, curl, tar, and a C++17 compiler." >&2; exit 1; }
done
case "$prefix" in /*) ;; *) echo 'Installation prefix must be an absolute path.' >&2; exit 1 ;; esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
curl --fail --location --retry 3 'https://github.com/Open-Cascade-SAS/OCCT/archive/refs/tags/V7_9_3.tar.gz' -o "$work/occt.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then
  actual=$(sha256sum "$work/occt.tar.gz" | cut -d ' ' -f 1)
else
  actual=$(shasum -a 256 "$work/occt.tar.gz" | cut -d ' ' -f 1)
fi
[ "$actual" = "$checksum" ] || { echo 'OCCT download checksum mismatch.' >&2; exit 1; }
mkdir "$work/source"
tar -xzf "$work/occt.tar.gz" -C "$work/source" --strip-components=1
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
patch -d "$work/source" -p1 < "$script_dir/patches/occt-7.9.3-alignment.patch"
case $(uname -s) in Darwin) rpath='@loader_path' ;; *) rpath='$ORIGIN' ;; esac
cmake -S "$work/source" -B "$work/build" \
  -DCMAKE_INSTALL_RPATH="$rpath" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DINSTALL_DIR="$prefix" \
  -DINSTALL_DIR_LIB=lib -DINSTALL_DIR_CMAKE=lib/cmake/opencascade \
  -DBUILD_RELEASE_DISABLE_EXCEPTIONS=OFF -DBUILD_LIBRARY_TYPE=Shared -DBUILD_MODULE_Draw=OFF \
  -DBUILD_MODULE_FoundationClasses=OFF -DBUILD_MODULE_ModelingData=OFF \
  -DBUILD_MODULE_ModelingAlgorithms=OFF -DBUILD_MODULE_Visualization=OFF \
  -DBUILD_MODULE_ApplicationFramework=OFF -DBUILD_MODULE_DataExchange=OFF \
  '-DBUILD_ADDITIONAL_TOOLKITS=TKDESTEP TKDESTL TKMesh TKFillet TKOffset TKBool TKBO TKPrim' \
  -DUSE_TCL=OFF -DUSE_TK=OFF -DUSE_FREETYPE=OFF -DUSE_TBB=OFF \
  -DUSE_XLIB=OFF -DUSE_OPENGL=OFF -DUSE_GLES2=OFF -DBUILD_DOC_Overview=OFF
cmake --build "$work/build" --parallel "$jobs"
cmake --install "$work/build"
c++ -std=c++17 "$script_dir/check-allocator.cpp" -I"$prefix/include/opencascade" \
  -L"$prefix/lib" -Wl,-rpath,"$prefix/lib" -lTKernel -o "$work/check-allocator"
"$work/check-allocator"
printf '\nOCCT %s installed. Set:\nexport OpenCASCADE_DIR="%s/lib/cmake/opencascade"\n' "$version" "$prefix"
