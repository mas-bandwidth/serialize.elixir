#!/bin/sh
# tools/revendor.sh <tag>: re-vendor the wire format from a released tag of
# mas-bandwidth/serialize. STANDARD.md, IMPLEMENTING.md (which STANDARD.md
# links), conformance/ and conformance-controls/ are verbatim copies, and CI
# diffs them against the pinned release, so this copies all four across and
# then shows what changed for review. After it runs, set SERIALIZE_TAG in
# .github/workflows/ci.yml to the same tag, and port whatever the diff implies
# in the same pull request.
set -eu
tag="${1:?usage: tools/revendor.sh <tag>, for example v2.0.0}"
cd "$(dirname "$0")/.."
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" https://github.com/mas-bandwidth/serialize.git "$scratch/serialize"
cp "$scratch/serialize/STANDARD.md" STANDARD.md
cp "$scratch/serialize/IMPLEMENTING.md" IMPLEMENTING.md
rm -rf conformance conformance-controls
cp -R "$scratch/serialize/conformance" conformance
cp -R "$scratch/serialize/conformance-controls" conformance-controls
echo "re-vendored from mas-bandwidth/serialize $tag ($(git -C "$scratch/serialize" rev-parse HEAD))"
git status --short -- STANDARD.md IMPLEMENTING.md conformance conformance-controls
