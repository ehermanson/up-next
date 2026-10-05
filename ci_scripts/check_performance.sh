#!/bin/bash
# Run source-level async loading/cache regressions without adding an Xcode test target.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
checks_dir="$(mktemp -d "${TMPDIR:-/tmp}/up-next-performance.XXXXXX")"
trap 'rm -rf "$checks_dir"' EXIT
python3 - "$repo_root/Up Next/Services/TMDBService.swift" "$checks_dir/RequestDeduplicator.swift" <<'PY'
import pathlib
import sys
source = pathlib.Path(sys.argv[1]).read_text()
start = source.index('private actor RequestDeduplicator {')
end = source.index('\nnonisolated enum TMDBError', start)
# Compile the real actor implementation with internal visibility for this standalone harness.
pathlib.Path(sys.argv[2]).write_text('import Foundation\n' + source[start:end].replace(
    'private actor RequestDeduplicator {', 'actor RequestDeduplicator {', 1))
PY
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    "$repo_root/ci_scripts/performance_checks.swift" \
    "$repo_root/Up Next/ViewModels/DiscoverViewModel.swift" \
    "$checks_dir/RequestDeduplicator.swift" -o "$checks_dir/checks"
"$checks_dir/checks"
