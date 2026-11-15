#!/bin/zsh
# Fails when the pinned ccusage-bin is behind the latest published ccusage.
#
# Netra's numbers are only as good as the pinned ccusage (20.0.32 hid almost
# all Codex history), so this runs before anything reaches master (the
# pre-push hook) and before a release. To upgrade: replace ccusage-bin with
# bin/ccusage from npm's @ccusage/ccusage-darwin-arm64, then run `swift test`,
# whose PinnedCCUsageTests run the new binary against synthetic logs.
#
#   NETRA_ALLOW_OLD_CCUSAGE=1   proceed on the pinned version deliberately
set -e
cd "$(dirname "$0")/.."

PINNED="$(./ccusage-bin --version | awk '{print $NF}')"
LATEST="$(npm view @ccusage/ccusage-darwin-arm64 version 2>/dev/null || true)"
if [[ -z "$LATEST" ]]; then
  echo "⚠ Could not check npm for a newer ccusage (pinned ${PINNED})."
elif [[ "$LATEST" != "$PINNED" && -z "$NETRA_ALLOW_OLD_CCUSAGE" ]]; then
  echo "✋ ccusage ${LATEST} is available; ccusage-bin is pinned at ${PINNED}." >&2
  echo "  Review its changelog, upgrade and re-verify, or set NETRA_ALLOW_OLD_CCUSAGE=1." >&2
  exit 1
else
  echo "ccusage ${PINNED} (latest: ${LATEST})"
fi
