#!/bin/zsh
# Cuts a release: builds the app, zips it, publishes a GitHub Release, and
# bumps the Homebrew cask. Requires `gh` to be authenticated.
#
# Usage: scripts/release.sh 0.1.0
#
# Optional notarization (needs a paid Apple Developer membership):
#   export NETRA_NOTARY_PROFILE=<notarytool keychain profile>
set -e
cd "$(dirname "$0")/.."

VERSION="$1"
[[ -z "$VERSION" ]] && { echo "usage: scripts/release.sh <version>"; exit 1; }

TAP_DIR="${NETRA_TAP_DIR:-../homebrew-tap}"
ZIP="dist/Netra-${VERSION}.zip"

# Netra's numbers are only as good as the pinned ccusage; never ship on a
# stale one by accident. Upgrading still needs contract verification
# (swift test, including PinnedCCUsageTests) before this check passes.
PINNED_CCUSAGE="$(./ccusage-bin --version | awk '{print $NF}')"
LATEST_CCUSAGE="$(npm view @ccusage/ccusage-darwin-arm64 version 2>/dev/null || true)"
if [[ -z "$LATEST_CCUSAGE" ]]; then
  echo "⚠ Could not check npm for a newer ccusage (pinned ${PINNED_CCUSAGE})."
elif [[ "$LATEST_CCUSAGE" != "$PINNED_CCUSAGE" && -z "$NETRA_ALLOW_OLD_CCUSAGE" ]]; then
  echo "✋ ccusage ${LATEST_CCUSAGE} is available; ccusage-bin is pinned at ${PINNED_CCUSAGE}." >&2
  echo "  Review its changelog, upgrade and re-verify, or set NETRA_ALLOW_OLD_CCUSAGE=1." >&2
  exit 1
fi

scripts/build-app.sh "$VERSION"

if [[ -n "$NETRA_NOTARY_PROFILE" ]]; then
  ditto -c -k --keepParent dist/Netra.app "dist/notarize-tmp.zip"
  xcrun notarytool submit "dist/notarize-tmp.zip" --keychain-profile "$NETRA_NOTARY_PROFILE" --wait
  xcrun stapler staple dist/Netra.app
  rm dist/notarize-tmp.zip
else
  echo "⚠ Skipping notarization (NETRA_NOTARY_PROFILE not set)."
  echo "  Friends must clear quarantine: xattr -dr com.apple.quarantine /Applications/Netra.app"
fi

ditto -c -k --keepParent dist/Netra.app "$ZIP"
SHA256=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "sha256: $SHA256"

# -c tag.gpgSign=false: signed tags hang without an interactive GPG prompt.
git -c tag.gpgSign=false tag "v${VERSION}" 2>/dev/null || echo "(tag v${VERSION} already exists)"
git push origin "v${VERSION}"
gh release create "v${VERSION}" "$ZIP" \
  --title "Netra ${VERSION}" \
  --generate-notes

# Bump the cask in the tap so `brew upgrade` sees the new version.
if [[ -d "$TAP_DIR" ]]; then
  sed -i '' \
    -e "s/^  version \".*\"/  version \"${VERSION}\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"${SHA256}\"/" \
    "$TAP_DIR/Casks/netra.rb"
  git -C "$TAP_DIR" add Casks/netra.rb
  git -C "$TAP_DIR" commit -m "netra ${VERSION}"
  git -C "$TAP_DIR" push
  echo "Cask bumped and pushed."
else
  echo "⚠ Tap not found at $TAP_DIR — update the cask manually:"
  echo "  version \"${VERSION}\" / sha256 \"${SHA256}\""
fi

echo "✅ Released v${VERSION}"
