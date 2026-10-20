#!/bin/bash
# Signed, notarized NotchFlow releases from this Mac.
#
#   bash Scripts/release.sh check            what's ready and what's missing
#   bash Scripts/release.sh setup            save notarization credentials in your Keychain
#                                            (you type the app-specific password; it never touches a file)
#   bash Scripts/release.sh publish 0.1.0    build, sign, notarize, staple, verify, zip, tag, GitHub release
#
# Needs: a "Developer ID Application" certificate in your login keychain (Xcode › Settings › Accounts ›
# Manage Certificates › + › Developer ID Application), a notarytool profile (setup), and `gh` signed in.
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${NOTCHFLOW_NOTARY_PROFILE:-notchflow}"

identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^.*"\(Developer ID Application: .*\)"$/\1/p' | head -1
}
team() { identity | sed -n 's/^.*(\([A-Z0-9]\{10\}\))$/\1/p'; }

check() {
  local missing=0 id
  id="$(identity)"
  if [[ -n "$id" ]]; then
    echo "✓ Signing identity: $id"
  else
    echo "✗ No Developer ID Application certificate on this Mac."
    echo "  Xcode › Settings › Accounts: sign in with your developer Apple ID, select the team,"
    echo "  Manage Certificates… › + › Developer ID Application."
    missing=1
  fi
  if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "✓ Notarization credentials: keychain profile \"$PROFILE\""
  else
    echo "✗ No working notarization profile \"$PROFILE\". Run: bash Scripts/release.sh setup"
    missing=1
  fi
  if gh auth status >/dev/null 2>&1; then
    echo "✓ GitHub CLI signed in"
  else
    echo "✗ GitHub CLI isn't signed in. Run: gh auth login"
    missing=1
  fi
  return $missing
}

setup() {
  local t apple_id
  t="$(team)"
  if [[ -z "$t" ]]; then
    echo "Create the Developer ID certificate first (bash Scripts/release.sh check explains how)." >&2
    exit 1
  fi
  read -r -p "Apple ID of your developer account: " apple_id
  echo "Create an app-specific password at https://account.apple.com › Sign-In and Security,"
  echo "then paste it when notarytool asks. It's stored in your Keychain as \"$PROFILE\"."
  xcrun notarytool store-credentials "$PROFILE" --apple-id "$apple_id" --team-id "$t"
}

publish() {
  local version="${1:-}" tag zip id
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Usage: bash Scripts/release.sh publish 1.2.3" >&2; exit 1
  fi
  tag="v$version"
  check
  if [[ -n "$(git status --porcelain)" ]]; then echo "Commit or stash your changes first." >&2; exit 1; fi
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then echo "$tag already exists." >&2; exit 1; fi

  NOTCHFLOW_VERSION="$version" NOTCHFLOW_BUILD="$(git rev-list --count HEAD)" bash Scripts/build.sh
  id="$(identity)"
  NOTCHFLOW_SIGN_IDENTITY="$id" NOTCHFLOW_NOTARY_PROFILE="$PROFILE" bash Scripts/notarize.sh
  # What a downloader's Mac will decide: it must say "accepted, source=Notarized Developer ID".
  spctl --assess --type execute --verbose=2 build/NotchFlow.app

  zip="build/NotchFlow-$version.zip"
  rm -f "$zip"
  ditto -c -k --sequesterRsrc --keepParent build/NotchFlow.app "$zip"
  (cd build && shasum -a 256 "$(basename "$zip")" > "$(basename "$zip").sha256")

  git tag -a "$tag" -m "NotchFlow $version"
  git push origin "$tag"
  # Notes go through a file: bash 3.2 (macOS) mis-parses heredocs with apostrophes inside $( ).
  cat > build/release-notes.md <<NOTES
**Download \`NotchFlow-$version.zip\`**, unzip, and drag **NotchFlow** to Applications. It's signed with a
Developer ID and notarized by Apple, so it opens without warnings.

Requires macOS 14.6 or later; runs natively on Apple silicon and Intel. NotchFlow lives at the top of your
screen and in the menu bar (no Dock icon). Hover the notch or press ⌃⌥Space.

SHA-256 checksum: \`NotchFlow-$version.zip.sha256\`
NOTES
  gh release create "$tag" "$zip" "$zip.sha256" --title "NotchFlow $version" --notes-file build/release-notes.md
  echo "Published $tag."
}

case "${1:-check}" in
  check) check ;;
  setup) setup ;;
  publish) publish "${2:-}" ;;
  *) echo "Usage: bash Scripts/release.sh check | setup | publish <version>" >&2; exit 1 ;;
esac
