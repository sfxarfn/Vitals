#!/bin/zsh
# Rebuilds the vendored MediaRemote adapter from source, pinned to one commit.
#
# Vitals reads Now Playing through ungive/mediaremote-adapter (BSD 3-Clause):
# Apple-signed /usr/bin/perl still holds the MediaRemote entitlement that
# macOS 15.4 took from third-party apps, and loads this helper library.
#
# Output goes to Vitals/Interactions/MediaRemoteAdapter/. The library ships
# zipped, as `MediaRemoteAdapter.zip`, on purpose: Xcode's synchronized group
# recognises a Mach-O by its contents, whatever the extension — a `.dat` was
# linked into Vitals and dyld aborted at launch looking for it. Inside a zip
# it is just a resource. `NowPlaying` unzips it into the
# `MediaRemoteAdapter.framework` folder the script expects, in Caches.
#
# Needs only the Xcode command line tools (clang, codesign) — no CMake. The
# flags mirror the adapter's own CMakeLists.txt.
set -euo pipefail

COMMIT=0e82bf1
REPO=https://github.com/ungive/mediaremote-adapter.git
ROOT=${0:A:h:h}
DEST="$ROOT/Vitals/Interactions/MediaRemoteAdapter"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git clone --quiet "$REPO" "$WORK/src"
git -C "$WORK/src" checkout --quiet "$COMMIT"
cd "$WORK/src"

clang -dynamiclib -arch arm64 -arch x86_64 -fobjc-arc -fvisibility=default \
  -Iinclude -Isrc \
  src/adapter/{env,get,globals,keys,now_playing,repeat,seek,send,shuffle,speed,stream,test}.m \
  src/private/MediaRemote.m src/utility/Debounce.m src/utility/helpers.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name @rpath/MediaRemoteAdapter.framework/MediaRemoteAdapter \
  -o "$WORK/MediaRemoteAdapter"
codesign --force --sign - "$WORK/MediaRemoteAdapter"

mkdir -p "$DEST"
rm -f "$DEST/MediaRemoteAdapter.dat"
(cd "$WORK" && ditto -c -k MediaRemoteAdapter "$DEST/MediaRemoteAdapter.zip")
cp bin/mediaremote-adapter.pl "$DEST/mediaremote-adapter.pl"
{
  echo "ungive/mediaremote-adapter, commit $COMMIT — $REPO"
  echo "Bundled in Vitals as MediaRemoteAdapter.zip and mediaremote-adapter.pl."
  echo
  cat LICENSE
} > "$DEST/MediaRemoteAdapter-LICENSE.txt"

echo "Adapter written to $DEST"
