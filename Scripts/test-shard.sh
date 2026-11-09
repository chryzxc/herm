#!/bin/bash
# Run one CI shard of the test suites: Scripts/test-shard.sh <index> <count>
# Whole suites are assigned greedily by test count, so `.serialized` suites stay intact.
set -euo pipefail
index=$1
count=$2
cd "$(dirname "$0")/.."
. Scripts/appintents.sh
reset_stale_metal_cache
swift build --build-tests --disable-automatic-resolution

suites=$(swift test list --skip-build --disable-automatic-resolution |
    awk -F/ '/^HermTests\./ { sub(/^HermTests\./, "", $1); print $1 }' | sort | uniq -c | sort -k1,1nr -k2 |
    awk -v n="$count" -v i="$index" '{
        best = 0
        for (s = 1; s < n; s++) if (load[s] < load[best]) best = s
        load[best] += $1
        if (best == i) { printf "%s%s", sep, $2; sep = "|" }
    }')

[ -n "$suites" ] || { echo "shard $index/$count: no suites"; exit 0; }
echo "shard $index/$count: ${suites//|/ }"
swift test --skip-build --disable-automatic-resolution --filter "^HermTests\.($suites)/"
