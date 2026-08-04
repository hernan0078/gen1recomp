#!/usr/bin/env python3
"""Build an import manifest for a translated ROM from the English one.

This is the whole pipeline in one command: align the two ROMs, recover every
symbol address from the translated build, read its font to find out what its
character codes mean, and write a manifest the extractor can use.

    python3 tools/es/make_es_manifest.py \
        --base "Pokemon - Yellow Version.gbc" \
        --target "Pokemon - Edicion Amarilla.gb" \
        --manifest tools/rom_manifest_yellow.json \
        --out tools/rom_manifest_yellow_es.json

Symbols that could not be recovered are left out and listed, along with the
manifest sections that referred to them -- that is the honest measure of what
still needs doing, and it is what the report ends with.

The manifest embeds nothing from the ROM beyond addresses and the character
map, exactly as the English manifests do.
"""

from __future__ import annotations

import argparse
import collections
import copy
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import charmap as charmap_tool  # noqa: E402
import dynamic_text  # noqa: E402
from relocate import (  # noqa: E402
    dex_entry_labels,
    format_report,
    ordered_map_headers,
    relocate,
    to_offset,
)

# Manifest sections that hold a {bank, address} pair rather than a symbol
# name.  They move too, so they are relocated alongside the symbols under a
# reserved name and written back afterwards.
INLINE_PREFIX = "@"


def collect_inline(node, path=""):
    """Every {"bank": b, "address": a} in the manifest, by JSON path."""
    found = {}
    if isinstance(node, dict):
        if (isinstance(node.get("bank"), int)
                and isinstance(node.get("address"), int)):
            found[path] = (node["bank"], node["address"])
        for key, value in node.items():
            found.update(collect_inline(value, "%s/%s" % (path, key)))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            found.update(collect_inline(value, "%s[%d]" % (path, index)))
    return found


def apply_inline(node, resolved, path=""):
    """Write recovered addresses back into the manifest tree."""
    written = 0
    if isinstance(node, dict):
        if (isinstance(node.get("bank"), int)
                and isinstance(node.get("address"), int)):
            found = resolved.get(INLINE_PREFIX + path)
            if found:
                node["bank"], node["address"] = found
                written += 1
        for key, value in node.items():
            written += apply_inline(value, resolved, "%s/%s" % (path, key))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            written += apply_inline(value, resolved, "%s[%d]" % (path, index))
    return written


def references(node, wanted, path=""):
    """Where a manifest still names a symbol we could not place."""
    found = collections.defaultdict(list)
    if isinstance(node, dict):
        for key, value in node.items():
            for name, places in references(value, wanted,
                                           "%s/%s" % (path, key)).items():
                found[name].extend(places)
    elif isinstance(node, list):
        for index, value in enumerate(node):
            for name, places in references(value, wanted,
                                           "%s[%d]" % (path, index)).items():
                found[name].extend(places)
    elif isinstance(node, str) and node in wanted:
        found[node].append(path or "/")
    return found


def prune(out, missing):
    """Drop references to symbols we could not place.

    A manifest that names a symbol it has no address for is not honest, and
    the extractor is right to refuse it.  Removing the reference is what
    "this cartridge's import does not include that string" looks like: the
    game already falls back when a text label is absent, so the result is a
    line that stays untranslated rather than an import that fails.
    """
    dropped = collections.Counter()

    labels = out.get("text", {}).get("labels")
    if isinstance(labels, list):
        kept = [label for label in labels if label not in missing]
        dropped["text.labels"] = len(labels) - len(kept)
        out["text"]["labels"] = kept

    for section in ("dexEntryLabels",):
        table = out.get(section)
        if isinstance(table, dict):
            kept = {key: value for key, value in table.items()
                    if value not in missing}
            dropped[section] = len(table) - len(kept)
            out[section] = kept

    for section in ("typeNameLabels",):
        table = out.get(section)
        if isinstance(table, list):
            kept = [value for value in table if value not in missing]
            dropped[section] = len(table) - len(kept)
            out[section] = kept

    return {name: count for name, count in dropped.items() if count}


def _dex_units(base, target, manifest, resolved):
    """3 if this cartridge's Pokedex measurements are metric, 4 if imperial.

    Asks the relocator, which decides it for the whole table at once -- per
    entry it is ambiguous, because a metric entry whose text pointer starts
    with $17 puts a TX_FAR exactly where an imperial one would.
    """
    from relocate import Relocator
    labels = dex_entry_labels(manifest)
    if "PokedexEntryPointers" not in resolved or not labels:
        return None
    probe = Relocator(base, target, {}, verbose=False)
    bank, address = resolved["PokedexEntryPointers"]
    return probe._dex_measure_width(target, bank, address, labels)


def section_of(path):
    parts = [part for part in path.split("/") if part]
    return parts[0].split("[")[0] if parts else "(root)"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--dex-labels", metavar="HEIGHT,WEIGHT",
                        help="on-screen abbreviations for Pokedex height and "
                             "weight in this language, e.g. AL,PE for Spanish. "
                             "Only used when the cartridge turns out to be "
                             "metric.")
    parser.add_argument("--report", help="write the full report here too")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    with open(args.base, "rb") as handle:
        base = handle.read()
    with open(args.target, "rb") as handle:
        target = handle.read()
    with open(args.manifest) as handle:
        manifest = json.load(handle)

    symbols = {name: tuple(value)
               for name, value in manifest["symbols"].items()}
    inline = collect_inline(manifest)
    for path, pair in inline.items():
        symbols[INLINE_PREFIX + path] = pair

    result = relocate(base, target, symbols, ordered_map_headers(manifest),
                      dex_entry_labels(manifest), verbose=not args.quiet)
    resolved = {name: tuple(value)
                for name, value in result["symbols"].items()}

    out = copy.deepcopy(manifest)
    out["symbols"] = {name: list(pair) for name, pair in sorted(resolved.items())
                      if not name.startswith(INLINE_PREFIX)}
    written = apply_inline(out, resolved)

    # The font is read where the translated ROM actually keeps it.
    target_font = None
    if "FontGraphics" in resolved:
        target_font = to_offset(*resolved["FontGraphics"])
    codes, unnamed = charmap_tool.derive(base, target, manifest,
                                         target_font=target_font)
    for code, (character, _score) in codes.items():
        out["charmap"][str(code)] = character
    for entry in out["fontCharmap"]:
        replacement = codes.get(entry["code"])
        if replacement:
            entry["seq"] = replacement[0]

    # European cartridges store Pokedex height and weight in metric, and the
    # extractor is told which layout to expect rather than guessing per entry.
    # Detect it the same way the relocator does, from where the text_far lands.
    width = _dex_units(base, target, manifest, resolved)
    if width == 3:
        out["dexUnits"] = "metric"
        height, weight = (args.dex_labels or ",").split(",")[:2]
        if height or weight:
            out["dexUnitLabels"] = {"height": height, "weight": weight}
        dex_note = ("Pokedex measurements are metric (3 bytes, not 4)"
                    + (" -- labelled %s / %s" % (height, weight)
                       if height or weight else ""))
    else:
        dex_note = None

    out["romSha1"] = hashlib.sha1(target).hexdigest()
    out["derivedFrom"] = {
        "manifest": os.path.basename(args.manifest),
        "baseRomSha1": hashlib.sha1(base).hexdigest(),
        "tool": "tools/es/make_es_manifest.py",
        "resolved": result["stats"]["resolved"],
        "total": result["stats"]["total"],
        "unresolved": [name for name in result["unresolved"]
                       if not name.startswith(INLINE_PREFIX)],
    }

    lines = [format_report(result, "symbol recovery")]
    if dex_note:
        lines.append("")
        lines.append(dex_note)
    lines.append("")
    lines.append("inline {bank, address} entries rewritten: %d of %d"
                 % (written, len(inline)))
    lines.append("character codes the translation reassigned: %d" % len(codes))
    for code in sorted(codes):
        lines.append("  $%02X  %s" % (code, codes[code][0]))
    if unnamed:
        lines.append("  %d glyphs changed but could not be named -- run "
                     "tools/es/charmap.py --render to read them"
                     % len(unnamed))

    # The splice tables have to be rebuilt, not copied: Spanish word order
    # puts the RAM substitutions somewhere else.
    dynamic, defeated = dynamic_text.rebuild(base, target, manifest, resolved)
    out["text"]["dynamic"] = dynamic
    lines.append("")
    lines.append("text splices rebuilt from the translated streams: %d"
                 % len(dynamic))
    if defeated:
        lines.append("  %d labels whose splices could not be named, so they "
                     "are dropped:" % len(defeated))
        for label in sorted(defeated)[:10]:
            lines.append("    %s -- %s" % (label, defeated[label]))
        if len(defeated) > 10:
            lines.append("    ... and %d more" % (len(defeated) - 10))

    missing = set(result["unresolved"]) | set(defeated)
    pruned = prune(out, missing)
    lines.append("")
    if pruned:
        lines.append("references dropped so the manifest names nothing it "
                     "cannot address:")
        for section, count in sorted(pruned.items()):
            lines.append("  %-20s %d" % (section, count))

    used = references(manifest, missing)
    lines.append("")
    if used:
        by_section = collections.Counter()
        for name, places in used.items():
            for place in places:
                by_section[section_of(place)] += 1
        lines.append("what those unresolved symbols cost, by the section "
                     "that wanted them -- this is the content the import "
                     "will not have:")
        for section, count in by_section.most_common():
            lines.append("  %-20s %d" % (section, count))
    else:
        lines.append("no manifest section refers to an unresolved symbol.")

    report = "\n".join(lines)
    print(report)
    if args.report:
        with open(args.report, "w") as handle:
            handle.write(report + "\n")

    with open(args.out, "w") as handle:
        json.dump(out, handle, indent=2, sort_keys=True, ensure_ascii=False)
    print("\nwrote %s (sha1 %s)" % (args.out, out["romSha1"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
