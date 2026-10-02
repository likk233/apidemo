#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cache="${USAGEBAR_BUILD_ROOT:-$PWD/.build}/windows-core-tests"
mkdir -p "$cache"
"${CXX:-clang++}" -std=c++17 -O2 -Wall -Wextra Windows/Core.cpp Windows/Tests.cpp -o "$cache/UsageBarChecks"
"$cache/UsageBarChecks"
