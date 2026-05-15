#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: scripts/publish-github-release.sh VERSION}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="${APP_NAME:-CalendarSync}"
TAG="${TAG:-v$VERSION}"
ZIP_PATH="$ROOT_DIR/dist/$APP_NAME-$VERSION-macos.zip"
SHA_PATH="$ZIP_PATH.sha256"
export GH_PAGER="${GH_PAGER:-cat}"

command -v gh >/dev/null 2>&1 || {
  echo "Required tool not found: gh" >&2
  exit 127
}

if [[ ! -f "$ZIP_PATH" || ! -f "$SHA_PATH" ]]; then
  echo "Missing dist artifacts. Run make dist VERSION=$VERSION first." >&2
  exit 2
fi

cd "$ROOT_DIR"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Working tree has uncommitted changes. Commit before publishing a release." >&2
  exit 4
fi

git fetch --tags origin

if ! git rev-parse "$TAG" >/dev/null 2>&1; then
  git tag "$TAG"
  git push origin "$TAG"
fi

NOTES_FILE="$(mktemp)"
{
  echo "$APP_NAME $VERSION"
  echo ""
  echo "SHA-256:"
  echo '```'
  cat "$SHA_PATH"
  echo '```'
} > "$NOTES_FILE"

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP_PATH" "$SHA_PATH" --clobber
else
  gh release create "$TAG" "$ZIP_PATH" "$SHA_PATH" \
    --title "$APP_NAME $VERSION" \
    --notes-file "$NOTES_FILE"
fi

rm -f "$NOTES_FILE"
gh release view "$TAG" --json url --jq .url
