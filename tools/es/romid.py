#!/usr/bin/env python3
"""Say what a Game Boy ROM is, and whether this build can import it.

"Unsupported ROM (SHA-1 ...)" is a true answer and a useless one.  This
prints the cartridge header, matches the hash against the versions
GameVersion knows, and when it does not match, says what the file appears to
be and what would have to happen for it to work.

    python3 tools/es/romid.py "Pokemon - Edicion Amarilla.gb"
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re

HEADER = {
    # 15 bytes, not 16: the last byte of the old title field is the CGB
    # flag on a Color cartridge, and reading it as text appends junk that
    # hides the region code.
    "title": (0x134, 15),
    "cgb": (0x143, 1),
    "licensee_new": (0x144, 2),
    "sgb": (0x146, 1),
    "cartridge": (0x147, 1),
    "rom_size": (0x148, 1),
    "ram_size": (0x149, 1),
    "destination": (0x14A, 1),
    "licensee_old": (0x14B, 1),
    "version": (0x14C, 1),
    "header_checksum": (0x14D, 1),
}

# The title's last four bytes are a region code on these carts: the third
# character is the language.
LANGUAGE = {
    "E": "English",
    "F": "French",
    "D": "German",
    "I": "Italian",
    "S": "Spanish",
    "J": "Japanese",
}

VERSIONS_LUA = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "..", "..", "src", "core", "GameVersion.lua")


def known_versions(path=VERSIONS_LUA):
    """The id -> sha1 table GameVersion.lua declares.

    Read from the Lua rather than duplicated here, so this cannot drift from
    what the game will actually accept."""
    try:
        with open(path) as handle:
            source = handle.read()
    except OSError:
        return {}
    out = {}
    for block in re.finditer(r"(\w+)\s*=\s*\{(.*?)\n  \}", source, re.S):
        name, body = block.group(1), block.group(2)
        found = re.search(r'sha1\s*=\s*"([0-9a-f]{40})"', body)
        if found:
            display = re.search(r'displayName\s*=\s*"([^"]*)"', body)
            out[found.group(1)] = (name,
                                   display.group(1) if display else name)
    return out


def describe(data):
    fields = {}
    for name, (offset, length) in HEADER.items():
        raw = data[offset:offset + length]
        fields[name] = raw if length > 1 else raw[0]
    title = fields["title"].split(b"\x00")[0]
    fields["title"] = "".join(chr(byte) for byte in title
                              if 0x20 <= byte < 0x7F).rstrip()
    return fields


def language_of(title):
    """Region letter from a title like POKEMON YELAPSS -> Spanish."""
    tail = title[-4:]
    if len(tail) == 4 and tail[0] == "A":
        return LANGUAGE.get(tail[2])
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("rom", nargs="+")
    args = parser.parse_args(argv)

    versions = known_versions()
    status = 0
    for path in args.rom:
        with open(path, "rb") as handle:
            data = handle.read()
        digest = hashlib.sha1(data).hexdigest()
        fields = describe(data)
        language = language_of(fields["title"])

        print(os.path.basename(path))
        print("  size        %d bytes (%d banks)"
              % (len(data), len(data) // 0x4000))
        print("  title       %s" % fields["title"])
        print("  language    %s" % (language or "unknown from the header"))
        print("  colour      %s"
              % ("Game Boy Color" if fields["cgb"] in (0x80, 0xC0)
                 else "original Game Boy"))
        print("  sha-1       %s" % digest)

        match = versions.get(digest)
        if match:
            print("  -> imports as %s (%s)" % (match[1], match[0]))
        else:
            print("  -> not a ROM this build accepts.")
            if len(data) != 1024 * 1024:
                print("     It is not 1 MiB, so it is not a Gen-1 cartridge "
                      "dump at all.")
            elif language and language != "English":
                print("     It looks like a %s cartridge.  Supporting one "
                      "means building it a manifest:" % language)
                print("       python3 tools/es/make_es_manifest.py \\")
                print("           --base <English ROM> --target %r \\" % path)
                print("           --manifest tools/rom_manifest_yellow.json \\")
                print("           --out tools/rom_manifest_<id>.json")
                print("     then adding it to GameVersion.VERSIONS with this "
                      "sha-1.")
            else:
                print("     Same size as a Gen-1 cartridge but an unknown "
                      "hash -- a patched, trimmed or bad dump.")
            status = 1
        print()
    return status


if __name__ == "__main__":
    raise SystemExit(main())
