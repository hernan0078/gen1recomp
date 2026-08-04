#!/usr/bin/env bash
# Packages VoxelTrail into an iOS app via LÖVE 11.5's
# official iOS Xcode project (love-11.5-ios-source.zip).
#
# Usage: scripts/build_ios.sh [--fetch] [--device] [--unsigned] [--release]
#                             [--install] [--version X.Y.Z] [--package-only]
#
#   (default)         Simulator Debug (ad-hoc signed)
#   --device          iphoneos SDK; signing team auto-detected from the
#                     keychain when DEVELOPMENT_TEAM is not set
#   --unsigned        with --device, disable signing and emit an IPA for
#                     AltStore/SideStore/TrollStore or another signer
#   --install         after a --device build, install the app onto the
#                     first connected iPhone/iPad (unlock it first)
#   --release         Release configuration
#   --version X.Y.Z   stamp MARKETING_VERSION / CURRENT_PROJECT_VERSION
#   --fetch           Download love-11.5-ios-source.zip into mobile/ios/love-src/
#   --package-only    Zip game.love + apply plist overlay; skip xcodebuild
#   --allow-unstaged  Package the git INDEX even though tracked files have
#                     unstaged edits (default is to refuse: the payload
#                     comes from the index, so those edits would be lost)
#
# Prerequisites:
#   - macOS + Xcode (xcodebuild)
#   - mobile/ios/love-src/ (see --fetch / mobile/ios/README.md)
#   - prebuilt iOS libraries under love-src/platform/xcode/ios/libraries/
#
# Output: dist/ios/<Config>-<sdk>/VoxelTrail.app (convenience copy)
#         dist/ios/VoxelTrail.ipa                 (device builds only)
#         mobile/ios/build/Build/Products/<Config>-<sdk>/VoxelTrail.app

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DIR="$ROOT/mobile/ios"
LOVE_SRC="$IOS_DIR/love-src"
CACHE="$IOS_DIR/cache"
# Xcode's DerivedData. Kept OUT of iCloud Drive when the checkout is inside
# it: iCloud stamps every file it manages with com.apple.FinderInfo and
# com.apple.fileprovider.fpfs#P, and codesign refuses a bundle carrying them --
#
#   love.app: resource fork, Finder information, or similar detritus not
#   allowed
#
# Stripping with `xattr -cr` does not hold, because the file provider puts them
# straight back on the next sync. Building somewhere iCloud does not manage is
# the fix, and it is much faster besides -- build artifacts have no business
# being synced. Override with VOXELTRAIL_BUILD_DIR.
BUILD_DIR="${VOXELTRAIL_BUILD_DIR:-}"
if [ -z "$BUILD_DIR" ]; then
  case "$ROOT" in
    *"/Mobile Documents/"*)
      BUILD_DIR="$HOME/Library/Developer/VoxelTrail/$(basename "$ROOT")-build" ;;
    *)
      BUILD_DIR="$IOS_DIR/build" ;;
  esac
fi
DIST="$ROOT/dist/ios"
OVERLAY_PLIST="$IOS_DIR/overlays/love-ios.plist"
XCODE_DIR="$LOVE_SRC/platform/xcode"
PROJECT="$XCODE_DIR/love.xcodeproj"
RESOURCES_DIR="$XCODE_DIR/ios/resources"
LOVE_FILE="$RESOURCES_DIR/game.love"
LIBS_DIR="$XCODE_DIR/ios/libraries"

APP_NAME="VoxelTrail"
DISPLAY_NAME="VoxelTrail"
DEPLOYMENT_TARGET="16.0"
ICON_SOURCE="$IOS_DIR/branding/VoxelTrail-AppIcon-Source.png"
# Bundle ID resolution, most specific wins:
#   1. GEN1_BUNDLE_ID env var
#   2. mobile/ios/bundle_id.local (one line, gitignored — pins YOUR install
#      so rebuilds keep updating the same app on your phone)
#   3. device builds: app.voxeltrail.t<your team id> — explicit App IDs are
#      globally unique across Apple accounts, so a per-team default lets
#      anyone build without colliding with someone else's app
#   4. simulator: the project default (no App ID registration involved)
BUNDLE_ID="${VOXELTRAIL_BUNDLE_ID:-${GEN1_BUNDLE_ID:-}}"
if [ -z "$BUNDLE_ID" ] && [ -f "$IOS_DIR/bundle_id.local" ]; then
  BUNDLE_ID="$(tr -d '[:space:]' < "$IOS_DIR/bundle_id.local")"
fi
LOVE_VERSION="$(tr -d '[:space:]' < "$IOS_DIR/LOVE_VERSION" 2>/dev/null || echo 11.5)"
IOS_SOURCE_ZIP="love-${LOVE_VERSION}-ios-source.zip"
APPLE_LIBS_ZIP="love-${LOVE_VERSION}-apple-libraries.zip"
IOS_SOURCE_URL="https://github.com/love2d/love/releases/download/${LOVE_VERSION}/${IOS_SOURCE_ZIP}"
APPLE_LIBS_URL="https://github.com/love2d/love/releases/download/${LOVE_VERSION}/${APPLE_LIBS_ZIP}"

FETCH=false
DEVICE=false
UNSIGNED=false
RELEASE=false
PACKAGE_ONLY=false
INSTALL=false
VERSION=""
ALLOW_UNSTAGED=false
# The bundled 3D renderer is third-party and carries no licence, so a build
# meant for redistribution has to be able to leave it out.  --no-mods packs
# the engine alone; the game plays in classic 2D and the mod manager simply
# lists nothing built in.
WITH_MOD=true

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --fetch) FETCH=true ;;
    --device) DEVICE=true ;;
    --unsigned) UNSIGNED=true ;;
    --release) RELEASE=true ;;
    --package-only) PACKAGE_ONLY=true ;;
    --allow-unstaged) ALLOW_UNSTAGED=true ;;
    --no-mods) WITH_MOD=false ;;
    --install) INSTALL=true ;;
    --version) VERSION="$2"; shift ;;
    -h|--help)
      sed -n '2,24p' "$0"
      exit 0
      ;;
    *) fail "unknown argument: $1 (try --fetch, --device, --unsigned, --release, --version, --install, --allow-unstaged, --no-mods, or --package-only)" ;;
  esac
  shift
done

VERSION_CODE=""
if [ -n "$VERSION" ]; then
  if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    fail "invalid --version '$VERSION' (expected X.Y.Z)"
  fi
  major="${VERSION%%.*}"
  rest="${VERSION#*.}"
  minor="${rest%%.*}"
  patch="${rest##*.}"
  VERSION_CODE=$((major * 10000 + minor * 100 + patch))
fi

# ---------------------------------------------------------- signing identity
# Auto-detect the Apple Development team when the caller didn't set one.
# Prefer a *valid* identity from `find-identity` (the parenthetical there is
# the cert id, not the team), then read that cert's OU. Scanning every
# "Apple Development" certificate picks expired personal/work certs first.
detect_team() {
  local cn
  cn="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n -E 's/.*"Apple Development: ([^"]+)".*/\1/p' \
    | head -1)"
  [ -n "$cn" ] || return 1
  security find-certificate -c "Apple Development: $cn" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' \
    | head -1
}
if $UNSIGNED && ! $DEVICE; then
  fail "--unsigned is only meaningful with --device"
fi
if $UNSIGNED && $INSTALL; then
  fail "--install cannot install an unsigned IPA; sign it with your sideload tool first"
fi
if $DEVICE && ! $UNSIGNED && [ -z "${DEVELOPMENT_TEAM:-}" ]; then
  DEVELOPMENT_TEAM="$(detect_team || true)"
  if [ -n "$DEVELOPMENT_TEAM" ]; then
    say "signing team auto-detected from keychain: $DEVELOPMENT_TEAM"
  else
    fail "no Apple signing identity found.
  Open Xcode -> Settings -> Accounts, press +, and sign in with your
  Apple ID (a free account works). That creates the certificate this
  script signs with. Then re-run this command."
  fi
fi
if [ -z "$BUNDLE_ID" ]; then
  if $DEVICE && ! $UNSIGNED; then
    BUNDLE_ID="app.voxeltrail.t$(printf '%s' "$DEVELOPMENT_TEAM" | tr '[:upper:]' '[:lower:]')"
  else
    BUNDLE_ID="app.voxeltrail.local"
  fi
fi

# --------------------------------------------------------------- host checks
if [ "$(uname -s)" != "Darwin" ]; then
  fail "iOS builds require macOS (Darwin). This host is $(uname -s).
  Run scripts/build_ios.sh on a Mac with Xcode installed."
fi

if ! $PACKAGE_ONLY; then
  command -v xcodebuild >/dev/null 2>&1 \
    || fail "xcodebuild not found. Install Xcode from the App Store, then run:
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

# --------------------------------------------------------------- fetch love-src
fetch_love_ios() {
  mkdir -p "$CACHE"
  local zip_path="$CACHE/$IOS_SOURCE_ZIP"
  if [ ! -f "$zip_path" ]; then
    say "downloading $IOS_SOURCE_ZIP (LÖVE $LOVE_VERSION iOS sources)"
    curl -fL --progress-bar "$IOS_SOURCE_URL" -o "$zip_path" \
      || fail "download failed: $IOS_SOURCE_URL"
  else
    say "using cached $zip_path"
  fi

  say "extracting into $LOVE_SRC"
  rm -rf "$LOVE_SRC"
  local tmp
  tmp="$(mktemp -d "$CACHE/extract.XXXXXX")"
  unzip -q "$zip_path" -d "$tmp"
  # Zip root is love-<version>-ios-source/
  local extracted
  extracted="$(find "$tmp" -maxdepth 1 -mindepth 1 -type d ! -name '__MACOSX' | head -1)"
  [ -n "$extracted" ] || fail "unexpected layout inside $IOS_SOURCE_ZIP"
  mv "$extracted" "$LOVE_SRC"
  rm -rf "$tmp"
  say "love-src ready (LÖVE $LOVE_VERSION)"
}

if [ ! -d "$XCODE_DIR/love.xcodeproj" ]; then
  if $FETCH; then
    fetch_love_ios
  else
    fail "LÖVE $LOVE_VERSION iOS sources not found at mobile/ios/love-src/.
  Fetch them (documented download of love-${LOVE_VERSION}-ios-source.zip):
    scripts/build_ios.sh --fetch
  Or manually:
    mkdir -p mobile/ios/cache
    curl -fL -o mobile/ios/cache/$IOS_SOURCE_ZIP \\
      $IOS_SOURCE_URL
    unzip -q mobile/ios/cache/$IOS_SOURCE_ZIP -d mobile/ios/cache
    mv mobile/ios/cache/love-${LOVE_VERSION}-ios-source mobile/ios/love-src
  See mobile/ios/README.md."
  fi
elif $FETCH; then
  say "love-src already present; skipping download (delete mobile/ios/love-src to refresh)"
fi

[ -d "$XCODE_DIR/love.xcodeproj" ] \
  || fail "missing $PROJECT after fetch"

# --------------------------------------------------------------- apple libraries
require_ios_libraries() {
  if [ -d "$LIBS_DIR/SDL2.xcframework" ]; then
    return 0
  fi
  fail "prebuilt iOS libraries missing at:
  $LIBS_DIR
  love-ios expects SDL2.xcframework (and friends) there.

  The official love-${LOVE_VERSION}-ios-source.zip normally includes them.
  If they are absent, install love-${LOVE_VERSION}-apple-libraries.zip:

    mkdir -p mobile/ios/cache
    curl -fL -o mobile/ios/cache/$APPLE_LIBS_ZIP \\
      $APPLE_LIBS_URL
    unzip -q mobile/ios/cache/$APPLE_LIBS_ZIP -d mobile/ios/cache
    rm -rf mobile/ios/love-src/platform/xcode/ios/libraries
    cp -R mobile/ios/cache/love-apple-dependencies/iOS/libraries \\
      mobile/ios/love-src/platform/xcode/ios/libraries

  See mobile/ios/README.md (Apple libraries dependency)."
}

require_ios_libraries

# --------------------------------------------------------------- branding / plist
apply_ios_branding() {
  [ -f "$OVERLAY_PLIST" ] || fail "missing overlay plist: $OVERLAY_PLIST"
  local dest="$XCODE_DIR/ios/love-ios.plist"
  say "applying iOS branding (portrait + landscape Info.plist, display name)"
  cp "$OVERLAY_PLIST" "$dest"
}

apply_ios_icons() {
  [ -f "$ICON_SOURCE" ] || fail "missing icon source: $ICON_SOURCE"
  local icon_dir="$XCODE_DIR/Images.xcassets/iOS AppIcon.appiconset"
  [ -d "$icon_dir" ] || fail "missing iOS app icon set: $icon_dir"
  say "generating VoxelTrail iPhone/iPad app icons"
  local spec name px
  for spec in \
    "icon-29pt@1x.png:29" "icon-29pt@2x.png:58" "icon-29pt@3x.png:87" \
    "icon-40pt@1x.png:40" "icon-40pt@2x.png:80" "icon-40pt@3x.png:120" \
    "icon-60pt@2x.png:120" "icon-60pt@3x.png:180" \
    "icon-76pt@1x.png:76" "icon-76pt@2x.png:152" \
    "icon-83.5pt@2x.png:167" "icon-1024pt@1x.png:1024"; do
    name="${spec%%:*}"
    px="${spec##*:}"
    sips -z "$px" "$px" "$ICON_SOURCE" --out "$icon_dir/$name" >/dev/null
  done
}

# --------------------------------------------------------------- game.love
pack_game_love() {
  say "packing game.love for love-ios resources"
  mkdir -p "$RESOURCES_DIR"
  rm -f "$LOVE_FILE"
  local pack_tmp staged_love mod_path
  mod_path="mods/DramaticShapeVoxelMod"
  [ "$WITH_MOD" = true ] || mod_path=""
  pack_tmp="$(mktemp -d /private/tmp/voxeltrail-love.XXXXXX)"
  staged_love="$pack_tmp/game.love"
  # Same payload as scripts/build.sh / build_android.sh: game sources plus
  # tools/save-editor, which the launcher's Edit button opens in-process.
  # VoxelTrail intentionally ships DramaticShapeVoxelMod as its built-in 3D
  # renderer. It remains disableable in the mod manager; user-added mods
  # continue to install into the writable save directory.
  if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # iCloud can take minutes to hydrate thousands of individual files for
    # Info-ZIP. Git's object store produces the tracked engine payload in one
    # stream; overlay the bundled renderer from the working tree afterward.
    # `git write-tree` below writes the INDEX, so a tracked file edited but
    # not staged is packaged at its OLD content -- silently, and the build
    # still succeeds. That produces an artifact that does not match the
    # working tree the developer just tested, which is worse than a failure
    # because nothing anywhere says so. Refuse instead.
    local dirty
    dirty="$(git -C "$ROOT" diff --name-only -- \
      main.lua conf.lua src data assets $mod_path \
      tools/save-editor tools/rom_manifest.json tools/rom_manifest_blue.json \
      tools/rom_manifest_yellow.json tools/rom_manifest_red_es.json \
      tools/rom_manifest_blue_es.json tools/rom_manifest_yellow_es.json)"
    if [ -n "$dirty" ] && [ "$ALLOW_UNSTAGED" != true ]; then
      fail "unstaged changes would NOT be packaged (the payload comes from the
git index). Stage them with 'git add' -- or pass --allow-unstaged to build the
staged content deliberately:
$dirty"
    fi
    local archive_tree="HEAD"
    if ! git -C "$ROOT" diff --cached --quiet -- \
        main.lua conf.lua src data assets $mod_path \
        tools/save-editor tools/rom_manifest.json tools/rom_manifest_blue.json \
        tools/rom_manifest_yellow.json tools/rom_manifest_red_es.json \
      tools/rom_manifest_blue_es.json tools/rom_manifest_yellow_es.json; then
      archive_tree="$(git -C "$ROOT" write-tree)"
    fi
    git -C "$ROOT" archive --format=zip --output="$staged_love" \
      "$archive_tree" main.lua conf.lua src data assets \
      $mod_path tools/save-editor \
      tools/rom_manifest.json tools/rom_manifest_blue.json \
      tools/rom_manifest_yellow.json tools/rom_manifest_red_es.json \
      tools/rom_manifest_blue_es.json tools/rom_manifest_yellow_es.json
  else
    (cd "$ROOT" && zip -q -9 -r "$staged_love" \
      main.lua conf.lua src data assets $mod_path tools/save-editor \
      tools/rom_manifest.json tools/rom_manifest_blue.json \
      tools/rom_manifest_yellow.json tools/rom_manifest_red_es.json \
      tools/rom_manifest_blue_es.json tools/rom_manifest_yellow_es.json \
      -x '*.DS_Store' -x '*/.git/*' -x '*/.DS_Store' \
      -x 'data/generated/*' -x 'assets/generated/*')
  fi
  cp "$staged_love" "$LOVE_FILE"
  rm -rf "$pack_tmp"
  # NOTE: grep -q here would race pipefail — it exits on first match, unzip
  # dies of SIGPIPE (141), and the pipeline "fails" nondeterministically.
  # >/dev/null keeps grep reading the whole stream instead.
  if unzip -Z1 "$LOVE_FILE" \
      | grep -E '^(data|assets)/generated/[^/]+|^(data|assets)/generated/.+/' >/dev/null; then
    fail "game.love unexpectedly contains generated ROM data"
  fi
  unzip -Z1 "$LOVE_FILE" | grep -x 'tools/save-editor/App.lua' >/dev/null \
    || fail "game.love is missing the save editor (Edit on a save row would crash)"
  if [ "$WITH_MOD" = true ]; then
    unzip -Z1 "$LOVE_FILE" \
      | grep -x 'mods/DramaticShapeVoxelMod/manifest.json' >/dev/null \
      || fail "game.love is missing DramaticShapeVoxelMod"
  else
    # The point of --no-mods is that nothing third-party ships.  Assert it,
    # rather than trusting that dropping the pathspec was enough.
    if unzip -Z1 "$LOVE_FILE" | grep '^mods/' >/dev/null; then
      fail "--no-mods build still contains mod files"
    fi
  fi
  # Every lib/ module the working tree has, not just the manifest.
  #
  # The payload comes out of `git archive`, so a mod source file that is
  # merely UNTRACKED is dropped without a word -- and the mod does not fail
  # at load, it fails at the first V.require of the missing module, with
  # "lib/X.lua is missing -- reinstall the mod" pointing the player at their
  # install rather than at this build. That is exactly how a new lib/ module
  # shipped empty once. Compare the two lists instead of trusting the archive.
  local missing
  missing="$(
    for lua in "$ROOT"/mods/DramaticShapeVoxelMod/lib/*.lua; do
      [ -e "$lua" ] || continue
      rel="mods/DramaticShapeVoxelMod/lib/$(basename "$lua")"
      unzip -Z1 "$LOVE_FILE" | grep -x "$rel" >/dev/null || echo "$rel"
    done
  )"
  if [ "$WITH_MOD" = true ] && [ -n "$missing" ]; then
    fail "game.love is missing mod sources (untracked in git?):
$missing"
  fi
  for manifest in tools/rom_manifest.json tools/rom_manifest_blue.json \
                  tools/rom_manifest_yellow.json tools/rom_manifest_red_es.json \
      tools/rom_manifest_blue_es.json tools/rom_manifest_yellow_es.json; do
    unzip -Z1 "$LOVE_FILE" | grep -x "$manifest" >/dev/null \
      || fail "game.love is missing $manifest"
  done
  say "game.love: $(du -h "$LOVE_FILE" | cut -f1) -> $LOVE_FILE"
}

# Ensure game.love is in the love-ios Copy Bundle Resources phase (idempotent).
ensure_game_love_in_xcode() {
  local pbx="$XCODE_DIR/love.xcodeproj/project.pbxproj"
  [ -f "$pbx" ] || fail "missing $pbx"

  if grep -q 'ios/resources/game.love' "$pbx"; then
    return 0
  fi

  say "wiring game.love into love-ios Copy Bundle Resources"
  python3 - "$pbx" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
if "ios/resources/game.love" in text:
    raise SystemExit(0)

file_ref = "A1B2C3D41E5F678901234567"
build_file = "A1B2C3D41E5F678901234568"

file_ref_entry = (
    f"\t\t{file_ref} /* game.love */ = {{isa = PBXFileReference; "
    f"lastKnownFileType = file; name = game.love; "
    f'path = ios/resources/game.love; sourceTree = "<group>"; }};\n'
)
build_file_entry = (
    f"\t\t{build_file} /* game.love in Resources */ = {{isa = PBXBuildFile; "
    f"fileRef = {file_ref} /* game.love */; }};\n"
)

# PBXBuildFile section
marker = "/* Begin PBXBuildFile section */\n"
if marker not in text:
    raise SystemExit("PBXBuildFile section not found")
text = text.replace(marker, marker + build_file_entry, 1)

# PBXFileReference section
marker = "/* Begin PBXFileReference section */\n"
if marker not in text:
    raise SystemExit("PBXFileReference section not found")
text = text.replace(marker, marker + file_ref_entry, 1)

# Add to love-ios Resources build phase (FA0B7F041A95AAF3000E1D17)
old = (
    "\t\tFA0B7F041A95AAF3000E1D17 /* Resources */ = {\n"
    "\t\t\tisa = PBXResourcesBuildPhase;\n"
    "\t\t\tbuildActionMask = 2147483647;\n"
    "\t\t\tfiles = (\n"
    "\t\t\t\tFA5D249C1A96CF4300C6FC8F /* Images.xcassets in Resources */,\n"
    "\t\t\t\tFA7C636A1A9C49570000FD29 /* Launch Screen.xib in Resources */,\n"
    "\t\t\t);\n"
)
new = (
    "\t\tFA0B7F041A95AAF3000E1D17 /* Resources */ = {\n"
    "\t\t\tisa = PBXResourcesBuildPhase;\n"
    "\t\t\tbuildActionMask = 2147483647;\n"
    "\t\t\tfiles = (\n"
    "\t\t\t\tFA5D249C1A96CF4300C6FC8F /* Images.xcassets in Resources */,\n"
    "\t\t\t\tFA7C636A1A9C49570000FD29 /* Launch Screen.xib in Resources */,\n"
    f"\t\t\t\t{build_file} /* game.love in Resources */,\n"
    "\t\t\t);\n"
)
if old not in text:
    # Fallback: insert before the closing of that files = ( list if markers differ slightly
    needle = "\t\tFA0B7F041A95AAF3000E1D17 /* Resources */ = {"
    if needle not in text:
        raise SystemExit("love-ios Resources build phase not found")
    # Insert build file line after "files = (" within that block
    idx = text.index(needle)
    files_idx = text.index("files = (", idx)
    insert_at = text.index("\n", files_idx) + 1
    text = (
        text[:insert_at]
        + f"\t\t\t\t{build_file} /* game.love in Resources */,\n"
        + text[insert_at:]
    )
else:
    text = text.replace(old, new, 1)

# Add file ref to the ios group if present
ios_group = "FA5D24961A96CE0A00C6FC8F /* ios */ = {"
if ios_group in text and file_ref not in text[text.index(ios_group):text.index(ios_group)+400]:
    # Prefer adding under Resources group,  skip if structure unknown; path is absolute enough via sourceTree
    pass

path.write_text(text)
print("patched project.pbxproj")
PY
}

# --------------------------------------------------------------- xcodebuild
run_xcodebuild() {
  local config sdk destination
  if $RELEASE; then
    config="Release"
  else
    config="Debug"
  fi

  if $DEVICE; then
    sdk="iphoneos"
    destination="generic/platform=iOS"
  else
    sdk="iphonesimulator"
    destination="generic/platform=iOS Simulator"
  fi

  mkdir -p "$BUILD_DIR"

  # Prefer -target + SYMROOT over -derivedDataPath: modern Xcode requires
  # -scheme whenever -derivedDataPath is set, and love-ios ships no shared schemes.
  # Always stamp both: the overlay plist expands $(MARKETING_VERSION) /
  # $(CURRENT_PROJECT_VERSION), and love-ios has no project-level defaults.
  local marketing_version="$LOVE_VERSION"
  local project_version="1"
  if [ -n "$VERSION" ]; then
    marketing_version="$VERSION"
    project_version="$VERSION_CODE"
  fi

  local args=(
    -project "$PROJECT"
    -target love-ios
    -configuration "$config"
    -sdk "$sdk"
    -destination "$destination"
    SYMROOT="$BUILD_DIR/Build/Products"
    OBJROOT="$BUILD_DIR/Build/Intermediates"
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID"
    IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
    MARKETING_VERSION="$marketing_version"
    CURRENT_PROJECT_VERSION="$project_version"
    ONLY_ACTIVE_ARCH=NO
  )

  if ! $DEVICE || $UNSIGNED; then
    # Simulator and resignable device archives need no development profile.
    args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=)
  else
    warn "device build: configure signing in Xcode or set DEVELOPMENT_TEAM / CODE_SIGN_IDENTITY"
    if [ -n "${DEVELOPMENT_TEAM:-}" ]; then
      # Automatic signing + provisioning updates lets xcodebuild register the
      # bundle ID / create a development profile from the CLI, so a device
      # build works without ever opening the project in Xcode.
      args+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
             CODE_SIGN_STYLE=Automatic
             -allowProvisioningUpdates)
    fi
    if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
      args+=(CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY")
    fi
  fi

  if ! xcodebuild -showsdks 2>/dev/null | grep -q "$sdk"; then
    fail "Xcode SDK '$sdk' is not installed (xcodebuild -showsdks).
  Open Xcode → Settings → Platforms (or Components) and install iOS.
  Simulator builds need the iOS Simulator platform; device builds need iOS."
  fi

  say "xcodebuild love-ios ($config / $sdk)"
  set +e
  (
    cd "$XCODE_DIR"
    xcodebuild "${args[@]}"
  )
  local xc_status=$?
  set -e
  if [ "$xc_status" -ne 0 ]; then
    fail "xcodebuild failed (exit $xc_status).
  Common causes:
    - iOS platform/SDK not installed in Xcode (Settings → Platforms)
    - device build without DEVELOPMENT_TEAM / provisioning (see mobile/ios/README.md)
    - Xcode too new for LÖVE $LOVE_VERSION sources (try an older Xcode)
  Packaging still succeeded: $LOVE_FILE"
  fi

  local products="$BUILD_DIR/Build/Products/${config}-${sdk}"
  local app="$products/$APP_NAME.app"
  if [ ! -d "$app" ]; then
    # PRODUCT_NAME override can still leave love.app on older projects
    if [ -d "$products/love.app" ]; then
      app="$products/love.app"
      warn "built app is love.app (PRODUCT_NAME override not applied); fusing game.love anyway"
    else
      warn "xcodebuild finished but no .app under $products"
      find "$BUILD_DIR/Build/Products" -name '*.app' 2>/dev/null | head -20 || true
      return 0
    fi
  fi

  # Fuse even if the pbxproj wire-up failed,  LÖVE runs any bundled *.love.
  if [ ! -f "$app/game.love" ]; then
    say "fusing game.love into $(basename "$app")"
    cp "$LOVE_FILE" "$app/game.love"
  fi

  local dist_dir="$DIST/${config}-${sdk}"
  rm -rf "$dist_dir"
  mkdir -p "$dist_dir"
  cp -R "$app" "$dist_dir/$APP_NAME.app"
  say "copied to $dist_dir/$APP_NAME.app"

  if $DEVICE; then
    package_ipa "$dist_dir/$APP_NAME.app"
  fi

  say "iOS app: $app"
  say "bundle id: $BUNDLE_ID  display: $DISPLAY_NAME"
  if $DEVICE && ! $UNSIGNED; then
    if $INSTALL; then
      install_to_device "$app"
    else
      say "install with: scripts/build_ios.sh --device --install (iPhone plugged in + unlocked)"
    fi
  elif ! $DEVICE; then
    say "simulator tip: xcrun simctl install booted \"$app\""
  else
    say "unsigned IPA ready for an external sideload signer; do not install the raw .app"
  fi
}

# Pack Payload/<app>.app into dist/ios/VoxelTrail.ipa for sideload tools.
package_ipa() {
  local app="$1"
  local ipa="$DIST/$APP_NAME.ipa"
  local tmp
  tmp="$(mktemp -d "$DIST/ipa.XXXXXX")"
  mkdir -p "$tmp/Payload"
  cp -R "$app" "$tmp/Payload/$(basename "$app")"
  rm -f "$ipa"
  (cd "$tmp" && zip -q -r "$ipa" Payload)
  rm -rf "$tmp"
  say "ipa: $ipa ($(du -h "$ipa" | cut -f1))"
}

# ------------------------------------------------------------ device install
# Installs the freshly built .app onto the first connected iPhone/iPad via
# devicectl. The phone must be paired (plugged in at least once + "Trust
# This Computer") and UNLOCKED during the install.
install_to_device() {
  local app="$1"
  local line udid
  # Filter on the Reality column: `devicectl list devices` lists simulators
  # too, and their Model column says "iPhone ..." just like a real handset,
  # so matching on the model picks whichever happens to be listed first and
  # then hands a simulator UDID to `devicectl device install`.  Only rows
  # marked `physical` are installable.  IOS_DEVICE_UDID overrides the choice
  # when more than one phone is plugged in.
  if [ -n "${IOS_DEVICE_UDID:-}" ]; then
    udid="$IOS_DEVICE_UDID"
    line="$(xcrun devicectl list devices 2>/dev/null | grep -F "$udid" || true)"
  else
    line="$(xcrun devicectl list devices 2>/dev/null \
      | grep -E '[[:space:]]physical([[:space:]]|$)' \
      | grep -E 'iPhone|iPad' | grep -v 'Watch' | head -1 || true)"
    udid="$(printf '%s' "$line" \
      | grep -Eo '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}' \
      | head -1 || true)"
  fi
  if [ -z "$udid" ]; then
    fail "no physical iPhone/iPad found.
  Plug the phone in with a cable, unlock it, tap 'Trust This Computer'
  if asked, then re-run: scripts/build_ios.sh --device --install
  (Set IOS_DEVICE_UDID=... to choose between several attached devices.)"
  fi
  local extra
  extra="$(xcrun devicectl list devices 2>/dev/null \
    | grep -E '[[:space:]]physical([[:space:]]|$)' | grep -cE 'iPhone|iPad' || true)"
  if [ "${extra:-0}" -gt 1 ] && [ -z "${IOS_DEVICE_UDID:-}" ]; then
    warn "$extra devices attached; installing to the first. Set IOS_DEVICE_UDID to pick."
  fi
  say "installing onto: $(printf '%s' "$line" | sed 's/  .*//') ($udid)"
  if xcrun devicectl device install app --device "$udid" "$app"; then
    say "installed. On the phone: tap the new app on your Home Screen."
    say "first launch may ask you to enable Developer Mode (Settings ->"
    say "Privacy & Security -> Developer Mode) and to trust the developer"
    say "(Settings -> General -> VPN & Device Management)."
  else
    fail "install failed. Most common cause: the phone was locked.
  Unlock it, keep it plugged in, and re-run:
  scripts/build_ios.sh --device --install"
  fi
}

# --------------------------------------------------------------- main
apply_ios_branding
apply_ios_icons
say "applying iOS native bridge patches (picker/Files support)"
python3 "$IOS_DIR/patch_love_src.py" || fail "patch_love_src.py failed"
pack_game_love
ensure_game_love_in_xcode

if $PACKAGE_ONLY; then
  say "package-only: skipping xcodebuild (game.love + plist ready under mobile/ios/love-src/)"
  exit 0
fi

run_xcodebuild
say "done"
