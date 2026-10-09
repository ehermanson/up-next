#!/bin/bash
# Score search quality against live TMDB (see search_checks.swift). Needs network and a TMDB key,
# from $TMDB_API_KEY or "Up Next/Info.plist". Optional argument: only run cases containing it.
# Uses Apple's on-device model (SearchModel) when this Mac has Apple Intelligence on;
# SEARCH_MODEL=off scores the rules alone; SEARCH_VERBOSE=1 prints each case's top rows.
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
    "$repo_root/Up Next/Services/SearchSession.swift" \
    "$repo_root/Up Next/Services/DescriptiveSearch.swift" \
    "$repo_root/Up Next/Services/SearchRanking.swift" \
    "$repo_root/Up Next/Services/SearchModel.swift" \
    "$repo_root/Up Next/Services/AppLog.swift" -o "$checks_dir/checks"
"$checks_dir/checks" "$@"
