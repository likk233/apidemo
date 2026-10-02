#!/bin/bash
# Cross-build on macOS/Linux with the official LLVM-MinGW toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
arch="${1:-x64}"
case "$arch" in
  x64) target=x86_64-w64-mingw32 ;;
  arm64) target=aarch64-w64-mingw32 ;;
  *) printf 'Usage: scripts/build-windows.sh [x64|arm64]\n' >&2; exit 2 ;;
esac
if [[ -n "${USAGEBAR_WINDOWS_TOOLCHAIN:-}" ]]; then
  compiler="$USAGEBAR_WINDOWS_TOOLCHAIN/bin/$target-clang++"
  resource="$USAGEBAR_WINDOWS_TOOLCHAIN/bin/$target-windres"
else
  compiler="$(command -v "$target-clang++" || true)"
  resource="$(command -v "$target-windres" || true)"
fi
if [[ ! -x "$compiler" || ! -x "$resource" ]]; then
  printf 'Set USAGEBAR_WINDOWS_TOOLCHAIN to an extracted official LLVM-MinGW toolchain.\nhttps://github.com/mstorsjo/llvm-mingw/releases\n' >&2
  exit 1
fi
cache="${USAGEBAR_BUILD_ROOT:-$root/.build}/windows-$arch"
output="$root/dist/windows-$arch"
export COPYFILE_DISABLE=1
mkdir -p "$cache" "$output"
"$resource" -I "$root/Windows" -i "$root/Windows/app.rc" -o "$cache/app.o"
"$compiler" -std=c++17 -O2 -Wall -Wextra -Wno-missing-field-initializers \
  -DUNICODE -D_UNICODE -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 \
  -municode -mwindows -static -s -I "$root/Windows" \
  Windows/Core.cpp Windows/Platform.cpp Windows/Main.cpp "$cache/app.o" \
  -lwinhttp -lcrypt32 -lshell32 -lole32 -luuid -lcomctl32 -luxtheme -ladvapi32 -lgdi32 -luser32 \
  -o "$output/UsageBar.exe"
cp LICENSE THIRD_PARTY_NOTICES.txt "$output/"
cp Windows/vendor/JSON-LICENSE.txt "$output/"
cp Windows/README.md "$output/README.txt"
mkdir -p "$output/licenses"
cp Windows/vendor/licenses/*.txt "$output/licenses/"
python3 - "$output" "$root/dist/UsageBar-Windows-$arch.zip" <<'PY'
import sys, zipfile
from pathlib import Path
source, destination = map(Path, sys.argv[1:])
with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as archive:
    for name in ('UsageBar.exe', 'LICENSE', 'THIRD_PARTY_NOTICES.txt', 'JSON-LICENSE.txt', 'README.txt'):
        archive.write(source/name, 'UsageBar-Windows/'+name)
    for name in ('LLVM-LICENSE.txt', 'MINGW-RUNTIME.txt', 'WINPTHREADS-LICENSE.txt'):
        archive.write(source/'licenses'/name, 'UsageBar-Windows/licenses/'+name)
print(destination)
PY
printf 'Built: %s/UsageBar.exe\n' "$output"
