#!/usr/bin/env bash
set -euo pipefail
[[ $# == 1 && -s $1 ]]
dmg=$1
source scripts/ci/runtime.env
release=${STELLA_RUNTIME_URL%/*}
sources=${release/\/download\//\/tag\/}
notes=$(mktemp)
trap 'rm -f "$notes"' EXIT
printf 'Apple Silicon build of [%s](%s/%s/commit/%s).\n\n[VM runtime and corresponding source](%s)\n\nSHA-256 `%s`\n' \
    "${GITHUB_SHA:0:10}" "$GITHUB_SERVER_URL" "$GH_REPO" "$GITHUB_SHA" "$sources" \
    "$(sha256sum "$dmg" | cut -d' ' -f1)" > "$notes"

if [[ $GITHUB_REF_TYPE == tag ]]; then
    tag=$GITHUB_REF_NAME
    if gh release view "$tag" >/dev/null 2>&1; then
        # A retry preserves the original asset on an already published version.
        assets=$(gh release view "$tag" --json assets --jq '.assets[].name')
        if ! grep -Fxq "$(basename "$dmg")" <<< "$assets"; then
            gh release upload "$tag" "$dmg"
        fi
    else
        prerelease=false
        [[ $tag == *-* ]] && prerelease=true
        gh release create "$tag" "$dmg" --verify-tag --title "Stella $tag" --notes-file "$notes" --prerelease="$prerelease"
    fi
else
    # Keep a stable public download URL; the tag identifies the source of this DMG.
    rolling="$(dirname "$dmg")/Stella-arm64.dmg"
    mv "$dmg" "$rolling"
    if gh release view continuous >/dev/null 2>&1; then
        order=$(gh api "repos/$GH_REPO/compare/continuous...$GITHUB_SHA" --jq .status)
        if [[ $order == behind ]]; then
            echo "A newer commit has already been published."
            exit 0
        fi
        gh release upload continuous "$rolling" --clobber
        gh api --method PATCH "repos/$GH_REPO/git/refs/tags/continuous" -f sha="$GITHUB_SHA" -F force=true --silent
        gh release edit continuous --notes-file "$notes"
    else
        gh release create continuous "$rolling" --target "$GITHUB_SHA" --prerelease --latest=false \
            --title 'Stella · Continuous build' --notes-file "$notes"
    fi
fi
