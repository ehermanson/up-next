#!/bin/bash
# Score search quality against live TMDB (see search_checks.swift). Needs network and a TMDB key,
# from $TMDB_API_KEY or "Up Next/Info.plist". Optional argument: only run cases containing it.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${TMDB_API_KEY:-}" ]; then
    TMDB_API_KEY="$(/usr/libexec/PlistBuddy -c "Print :TMDB_API_KEY" "$repo_root/Up Next/Info.plist" 2>/dev/null || true)"
fi
export TMDB_API_KEY
checks_dir="$(mktemp -d "${TMPDIR:-/tmp}/up-next-search.XXXXXX")"
trap 'rm -rf "$checks_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    "$repo_root/ci_scripts/search_checks.swift" \
    "$repo_root/Up Next/Services/DescriptiveSearch.swift" \
    "$repo_root/Up Next/Services/SearchRanking.swift" -o "$checks_dir/checks"
"$checks_dir/checks" "$@"
