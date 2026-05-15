#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:?usage: scripts/update-homebrew-tap.sh VERSION}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="${APP_NAME:-CalendarSync}"
FORMULA_NAME="${FORMULA_NAME:-calendarsync}"
TAP_REPO="${TAP_REPO:-https://github.com/khramtsoff/homebrew-brew.git}"
TAP_DIR="${TAP_DIR:-$HOME/Projects/homebrew-brew}"
SOURCE_REPO="${SOURCE_REPO:-khramtsoff/eas-calendar-sync-macos}"
TAG="${TAG:-v$VERSION}"

ZIP_PATH="$ROOT_DIR/dist/$APP_NAME-$VERSION-macos.zip"

command -v git >/dev/null 2>&1 || {
  echo "Required tool not found: git" >&2
  exit 127
}
command -v shasum >/dev/null 2>&1 || {
  echo "Required tool not found: shasum" >&2
  exit 127
}

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Missing $ZIP_PATH. Run make dist VERSION=$VERSION first." >&2
  exit 2
fi

SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
URL="https://github.com/$SOURCE_REPO/releases/download/$TAG/$APP_NAME-$VERSION-macos.zip"

if [[ -d "$TAP_DIR/.git" ]]; then
  git -C "$TAP_DIR" fetch origin
  git -C "$TAP_DIR" checkout main
  git -C "$TAP_DIR" pull --ff-only origin main
else
  mkdir -p "$(dirname "$TAP_DIR")"
  git clone "$TAP_REPO" "$TAP_DIR"
fi

mkdir -p "$TAP_DIR/Casks"
CASK_PATH="$TAP_DIR/Casks/$FORMULA_NAME.rb"

cat > "$CASK_PATH" <<EOF_CASK
cask "$FORMULA_NAME" do
  version "$VERSION"
  sha256 "$SHA256"

  url "$URL"
  name "$APP_NAME"
  desc "Exchange ActiveSync calendar bridge for macOS"
  homepage "https://github.com/$SOURCE_REPO"

  app "$APP_NAME.app"
end
EOF_CASK

git -C "$TAP_DIR" add "$CASK_PATH"
if git -C "$TAP_DIR" diff --cached --quiet; then
  echo "Homebrew tap already up to date."
  exit 0
fi

git -C "$TAP_DIR" commit -m "Update $FORMULA_NAME to $VERSION"
git -C "$TAP_DIR" push origin HEAD:main

echo "Updated $CASK_PATH"
