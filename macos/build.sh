#!/bin/bash
# Builds "Amber Terminal.app": the app in this folder in a window of its own, with a Dock icon.
# Needs Node.js and Xcode's command line tools (xcode-select --install).
#   macos/build.sh             builds into ~/Applications
#   macos/build.sh <folder>    builds into <folder>
# macos/selftest.sh sets QT_SELFTEST=1 and QT_APP_FOLDER to build its test copy.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
folder="${QT_APP_FOLDER:-$(cd "$here/.." && pwd -P)}"
dest="${1:-$HOME/Applications}"
node="$(command -v node)" || { echo "Node.js isn't on PATH; install it first (brew install node)." >&2; exit 1; }

name="Amber Terminal"
id="io.github.handsomewj.amber-terminal"
sources=("$here/AmberTerminal.swift")
flags=()
if [ "${QT_SELFTEST:-}" = 1 ]; then
  # The test build clicks through the app and answers its dialogs, so it never points at real data.
  [ -n "${QT_APP_FOLDER:-}" ] || { echo "QT_SELFTEST=1 needs QT_APP_FOLDER set to a scratch copy; use macos/selftest.sh." >&2; exit 1; }
  name="Amber Terminal Selftest"
  id="$id.selftest"
  sources+=("$here/SelfTest.swift")
  flags=(-D QT_SELFTEST)
fi
version="$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$folder/package.json" | head -1)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
app="$work/$name.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
target="$(uname -m)-apple-macos13.0"
# ${flags[@]+...}: macOS's bash 3.2 calls an empty array unbound under set -u.
swiftc -parse-as-library -swift-version 5 -O -target "$target" ${flags[@]+"${flags[@]}"} "${sources[@]}" \
  -o "$app/Contents/MacOS/$name"
swiftc -O -target "$target" "$here/make-icon.swift" -o "$work/make-icon"
"$work/make-icon" "$work/AppIcon.iconset"
iconutil -c icns "$work/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"

plist="$app/Contents/Info.plist"
plutil -create xml1 "$plist"
for pair in "CFBundleName=$name" "CFBundleDisplayName=$name" "CFBundleIdentifier=$id" "CFBundleExecutable=$name" \
  "CFBundleIconFile=AppIcon" "CFBundlePackageType=APPL" "CFBundleShortVersionString=$version" \
  "CFBundleVersion=$version" "LSMinimumSystemVersion=13.0" "LSApplicationCategoryType=public.app-category.finance" \
  "NSHumanReadableCopyright=MIT licence. Copyright (c) 2026 Lewis Jackson." "QTInstallDir=$folder" "QTNodePath=$node"; do
  plutil -insert "${pair%%=*}" -string "${pair#*=}" "$plist"
done
plutil -insert NSHighResolutionCapable -bool true "$plist"
# The window loads its own server over plain http on this machine only.
plutil -insert NSAppTransportSecurity -dictionary "$plist"
plutil -insert NSAppTransportSecurity.NSAllowsLocalNetworking -bool true "$plist"
# Ad-hoc signed with the hardened runtime, so DYLD_* variables can't inject code into the app.
codesign --force --options runtime --sign - "$app"

mkdir -p "$dest"
rm -rf "${dest:?}/$name.app"
ditto "$app" "$dest/$name.app"
echo "Built $dest/$name.app for $folder"
