#!/usr/bin/env python3
"""Applies VoxelTrail's iOS native-bridge patches to the fetched LÖVE 11.5
source tree (mobile/ios/love-src/). Idempotent AND re-appliable: the first
run stashes a pristine `.orig` copy of every file it rewrites, and later
runs always start over from that copy — so editing the patch content here
just works on the next build, no manual restore needed.

What it does:
  1. Copies the document-picker bridge and bootstrap into the LÖVE tree.
  2. Patches liblove's wrap_System.cpp to expose love.system.pickFile,
     love.system.createFile on iOS (each
     calls a GR*Bridge Swift class through the Objective-C runtime, so
     liblove never links against Swift directly).
  3. Patches love.xcodeproj so the love-ios app target compiles the native
     files (Swift 5, iOS 16 deployment).
"""

import re
import shutil
import sys
from pathlib import Path

IOS_DIR = Path(__file__).resolve().parent
LOVE_SRC = IOS_DIR / "love-src"
NATIVE_SRC = IOS_DIR / "native"
NATIVE_DST = LOVE_SRC / "platform" / "xcode" / "ios" / "native"
WRAP_SYSTEM = LOVE_SRC / "src" / "modules" / "system" / "wrap_System.cpp"
PBXPROJ = LOVE_SRC / "platform" / "xcode" / "love.xcodeproj" / "project.pbxproj"
# Both Xcode projects in the LÖVE tree; liblove is a separate one that
# love.xcodeproj depends on, and it carries its own deployment target.
ALL_PBXPROJ = (
    PBXPROJ,
    LOVE_SRC / "platform" / "xcode" / "liblove.xcodeproj" / "project.pbxproj",
)
# LÖVE 11.5 ships targeting iOS 8.0. Xcode 26/27 refuses to open or build that:
#
#   The iOS deployment target 'IPHONEOS_DEPLOYMENT_TARGET' is set to 8.0, but
#   the range of supported deployment target versions is 15.0 to 27.0.x
#
# Command-line builds get away with it because scripts/build_ios.sh passes
# IPHONEOS_DEPLOYMENT_TARGET on the xcodebuild invocation, which overrides every
# target -- but the IDE reads the project files, so opening the project (to set
# a signing team, or to register a connected device) hits the error on targets
# the script never rewrote. Normalise the stale value in the files themselves.
STALE_DEPLOYMENT_TARGET = "8.0"
# Kept in step with DEPLOYMENT_TARGET in scripts/build_ios.sh.
DEPLOYMENT_TARGET = "16.0"
NATIVE_FILES = (
    "GRPickerBridge.swift",
    "GRBootstrap.m",
    "VoxelTrailSceneLifecycle.m",
)

MARKER = "VoxelTrail iOS picker bridge"

# Headers must land outside `namespace love { namespace system {`.
WRAP_INCLUDES = """
// %s: headers for the native-bridge functions below.
#ifdef LOVE_IOS
#include <objc/runtime.h>
#include <objc/message.h>
#include "filesystem/Filesystem.h"
#endif
""" % MARKER

WRAP_FUNCS = """
// --- %s -------------------------------------------------
// love.system.pickFile / createFile for iOS. pickFile and
// createFile mirror the love-android extension this project's importer
// already targets. Implemented in
// Swift (GR*Bridge classes, love-ios app target); reached via the ObjC
// runtime so liblove itself needs no Swift interop.
#ifdef LOVE_IOS
static const char *gr_saveDirectory()
{
	auto fs = Module::getInstance<love::filesystem::Filesystem>(Module::M_FILESYSTEM);
	return fs != nullptr ? fs->getSaveDirectory() : "";
}

static int gr_callBridge(lua_State *L, const char *className,
                         const char *selector, const char *arg)
{
	Class cls = objc_getClass(className);
	if (cls == nullptr)
	{
		lua_pushboolean(L, 0);
		return 1;
	}
	typedef signed char (*GRMsg)(Class, SEL, const char *, const char *);
	signed char ok = ((GRMsg)objc_msgSend)(cls, sel_registerName(selector),
	                                       arg, gr_saveDirectory());
	lua_pushboolean(L, ok != 0);
	return 1;
}

int w_pickFile(lua_State *L)
{
	const char *kind = luaL_optstring(L, 1, "rom");
	return gr_callBridge(L, "GRPickerBridge", "presentPickerWithKind:saveDir:", kind);
}

int w_createFile(lua_State *L)
{
	const char *name = luaL_optstring(L, 1, "export.sav");
	return gr_callBridge(L, "GRPickerBridge", "presentExportWithName:saveDir:", name);
}

#endif // LOVE_IOS
// ---------------------------------------------------------------------------

""" % MARKER

WRAP_REGISTRATION = """#ifdef LOVE_IOS
	{ "pickFile", w_pickFile },
	{ "createFile", w_createFile },
#endif
"""

# Deterministic 24-hex-digit object IDs, chosen not to collide with the
# upstream project (grep-verified against love-11.5's pbxproj).
ID_FILE_PICKER = "6E1AC0DE0001000000000001"
ID_FILE_OBJC = "6E1AC0DE0001000000000002"
ID_BUILD_PICKER = "6E1AC0DE0002000000000001"
ID_BUILD_OBJC = "6E1AC0DE0002000000000002"
ID_FILE_SCENE = "6E1AC0DE0001000000000003"
ID_BUILD_SCENE = "6E1AC0DE0002000000000003"
SOURCES_PHASE_ID = "FA0B7F021A95AAF3000E1D17"  # love-ios Sources phase
IOS_APP_CONFIG_IDS = (
    "FA0B7F261A95AAF4000E1D17",  # Debug
    "FA0B7F271A95AAF4000E1D17",  # Release
    "FA0B7F281A95AAF4000E1D17",  # Distribution
)

PBX_SOURCES = (
    ("GRPickerBridge.swift", ID_FILE_PICKER, ID_BUILD_PICKER, "sourcecode.swift"),
    ("GRBootstrap.m", ID_FILE_OBJC, ID_BUILD_OBJC, "sourcecode.c.objc"),
    ("VoxelTrailSceneLifecycle.m", ID_FILE_SCENE, ID_BUILD_SCENE,
     "sourcecode.c.objc"),
)


def fail(msg):
    print(f"patch_love_src: error: {msg}", file=sys.stderr)
    sys.exit(1)


def pristine(path: Path) -> str:
    """Text of `path` before any of our patching: backed by a `.orig` stash.

    The stash is only trusted if it is itself unpatched; that protects
    against a stash accidentally taken after an earlier patch run.
    """
    orig = path.with_suffix(path.suffix + ".orig")
    if orig.is_file():
        text = orig.read_text()
        if MARKER not in text and ID_FILE_PICKER not in text:
            return text
    text = path.read_text()
    if MARKER in text or ID_FILE_PICKER in text:
        fail(f"{path} is already patched and no pristine .orig stash exists;\n"
             f"  delete {LOVE_SRC} and re-run scripts/build_ios.sh --fetch")
    orig.write_text(text)
    return text


def copy_native_files():
    NATIVE_DST.mkdir(parents=True, exist_ok=True)
    for name in NATIVE_FILES:
        src = NATIVE_SRC / name
        if not src.is_file():
            fail(f"missing {src}")
        shutil.copy2(src, NATIVE_DST / name)
    print(f"patch_love_src: native files -> {NATIVE_DST}")


def patch_wrap_system():
    text = pristine(WRAP_SYSTEM)
    include_anchor = '#include "sdl/System.h"\n'
    if include_anchor not in text:
        fail(f"include anchor not found in {WRAP_SYSTEM}")
    text = text.replace(include_anchor, include_anchor + WRAP_INCLUDES, 1)
    anchor = "static const luaL_Reg functions[] ="
    if anchor not in text:
        fail(f"anchor not found in {WRAP_SYSTEM}")
    text = text.replace(anchor, WRAP_FUNCS + anchor, 1)
    reg_anchor = '\t{ "vibrate", w_vibrate },\n'
    if reg_anchor not in text:
        fail(f"registration anchor not found in {WRAP_SYSTEM}")
    text = text.replace(reg_anchor, reg_anchor + WRAP_REGISTRATION, 1)
    WRAP_SYSTEM.write_text(text)
    print("patch_love_src: wrap_System.cpp patched (pickFile/createFile)")


def patch_pbxproj():
    text = pristine(PBXPROJ)

    build_files = "".join(
        f"\t\t{build_id} /* {name} in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {file_id} /* {name} */; }};\n"
        for name, file_id, build_id, _ in PBX_SOURCES
    )
    anchor = "/* Begin PBXBuildFile section */\n"
    if anchor not in text:
        fail("PBXBuildFile section not found")
    text = text.replace(anchor, anchor + build_files, 1)

    file_refs = "".join(
        f"\t\t{file_id} /* {name} */ = "
        f"{{isa = PBXFileReference; lastKnownFileType = {ftype}; "
        f"name = {name}; path = ios/native/{name}; "
        f"sourceTree = SOURCE_ROOT; }};\n"
        for name, file_id, _, ftype in PBX_SOURCES
    )
    anchor = "/* Begin PBXFileReference section */\n"
    if anchor not in text:
        fail("PBXFileReference section not found")
    text = text.replace(anchor, anchor + file_refs, 1)

    # Add the files to the love-ios Sources phase.
    phase_re = re.compile(
        re.escape(SOURCES_PHASE_ID)
        + r" /\* Sources \*/ = \{.*?files = \(\n", re.S)
    m = phase_re.search(text)
    if not m:
        fail("love-ios Sources phase not found")
    insertion = "".join(
        f"\t\t\t\t{build_id} /* {name} in Sources */,\n"
        for name, _, build_id, _ in PBX_SOURCES
    )
    text = text[: m.end()] + insertion + text[m.end():]

    # Swift + the VoxelTrail deployment target on the love-ios app target.
    for config_id in IOS_APP_CONFIG_IDS:
        cfg_re = re.compile(
            re.escape(config_id) + r" /\* \w+ \*/ = \{.*?buildSettings = \{\n",
            re.S)
        m = cfg_re.search(text)
        if not m:
            fail(f"build configuration {config_id} not found")
        settings = (
            "\t\t\t\tSWIFT_VERSION = 5.0;\n"
            f"\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};\n"
        )
        text = text[: m.end()] + settings + text[m.end():]

    PBXPROJ.write_text(text)
    print("patch_love_src: love.xcodeproj patched (picker bridge + Swift)")


def patch_deployment_targets():
    """Raise LOVE's shipped iOS 8.0 targets to one Xcode 26/27 accepts.

    LOVE 11.5 ships targeting iOS 8.0 and Xcode 26/27 refuses it outright:

      The iOS deployment target 'IPHONEOS_DEPLOYMENT_TARGET' is set to 8.0,
      but the range of supported deployment target versions is 15.0 to 27.0.x

    Command-line builds never saw it, because scripts/build_ios.sh passes
    IPHONEOS_DEPLOYMENT_TARGET to xcodebuild and that overrides every target.
    The IDE reads the project files instead, so opening the project -- to set a
    signing team, or to get a connected device registered -- hits the error on
    the targets nothing had rewritten. Six configurations across two projects:
    liblove.xcodeproj is a separate project that love.xcodeproj depends on, and
    it was never touched at all.
    """
    stale = f"IPHONEOS_DEPLOYMENT_TARGET = {STALE_DEPLOYMENT_TARGET};"
    fresh = f"IPHONEOS_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};"
    for path in ALL_PBXPROJ:
        if not path.is_file():
            continue          # partial tree; --fetch has not run yet
        text = path.read_text()
        if stale not in text:
            continue
        count = text.count(stale)
        path.write_text(text.replace(stale, fresh))
        print(f"patch_love_src: {path.parent.name} deployment target "
              f"{STALE_DEPLOYMENT_TARGET} -> {DEPLOYMENT_TARGET} "
              f"({count} configuration(s))")


def main():
    if not LOVE_SRC.is_dir():
        fail("love-src/ missing; run scripts/build_ios.sh --fetch first")
    copy_native_files()
    patch_wrap_system()
    patch_pbxproj()
    patch_deployment_targets()


if __name__ == "__main__":
    main()
