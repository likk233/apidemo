#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cache_root="${USAGEBAR_BUILD_ROOT:-$PWD/.build}"
mkdir -p "$cache_root"
export CLANG_MODULE_CACHE_PATH="$cache_root/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache_root/swift-cache"
args=(--scratch-path "$cache_root/tests" --cache-path "$cache_root/spm-cache" --config-path "$cache_root/spm-config" --security-path "$cache_root/spm-security")
if [[ "${USAGEBAR_DISABLE_BUILD_SANDBOX:-0}" == "1" ]]; then args+=(--disable-sandbox); fi
swift run "${args[@]}" UsageCoreChecks
