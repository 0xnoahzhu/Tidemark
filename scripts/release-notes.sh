#!/bin/zsh
# Prints the release notes of tag v<version> as Markdown: a `# Title` line, then the body.
#
# A hand-written docs/releases/<version>.md wins. Otherwise the notes list the feat and fix commits since the previous
# `chore(release)` commit: "New" and "Fixes".
set -euo pipefail

cd "${0:A:h}/.."
tag=${1:?usage: release-notes.sh v<version>}
version=${tag#v}

if [[ -f "docs/releases/$version.md" ]]; then
    cat "docs/releases/$version.md"
    exit 0
fi

previous=$(git log --format=%H --grep='^chore(release):' -1 "$tag^" || true)
range=${previous:+$previous..}$tag

# Subjects of the given types, without the type and scope, capitalized.
subjects() {
    git log --no-merges --reverse --format=%s "$range" \
        | sed -nE "s/^($1)(\\([^)]*\\))?!?: (.*)$/\\3/p" \
        | awk '{ print "- " toupper(substr($0, 1, 1)) substr($0, 2) }'
}
new=$(subjects feat)
fixes=$(subjects 'fix|perf')

print "# Tidemark $version"
if [[ -n "$new" ]]; then print "\n## New\n\n$new"; fi
if [[ -n "$fixes" ]]; then print "\n## Fixes\n\n$fixes"; fi
if [[ -z "$new$fixes" ]]; then print "\nMaintenance release."; fi
