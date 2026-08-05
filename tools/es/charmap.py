#!/usr/bin/env python3
"""Work out a translated ROM's character map by looking at its font.

The Spanish release did not extend the character set -- it reused it.  Codes
$C0-$DF hold the Japanese kana in the English build and are dead weight
there, so the Spanish build redrew them as the accented vowels, and put the
inverted punctuation in two of the apostrophe-ligature slots.  Nothing in the
ROM says so; the only record is the glyphs themselves.

So read the glyphs.  `FontGraphics` is 1bpp, one 8-byte tile per code from
$80 up, and for every code the English build still uses the tile is
unchanged -- which means a changed tile is exactly a reassigned code.  For
each of those, strip the top two rows and match what is left against the
English letters to recover the base letter, then read the top two rows to
tell an acute from a grave from a tilde.

Run with --render to see every glyph as ASCII art alongside what this
concluded, which is the only honest way to check it.

    python3 tools/es/charmap.py \
        --base "Pokemon - Yellow Version.gbc" \
        --target "Pokemon Amarillo.gb" \
        --manifest tools/rom_manifest_yellow.json --render
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import unicodedata

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from relocate import to_offset  # noqa: E402

TILE_BYTES = 8
FIRST_CODE = 0x80
LAST_CODE = 0xFF

# Rows a diacritic lives in, and rows that carry the letter itself.
ACCENT_ROWS = 2

# Which letters take which mark in a European Gen-1 font.  Restricting the
# search per accent is what keeps a squeezed capital O from matching C and
# coming out as the Croatian C-acute.
ACCENTABLE = {
    "acute": "aeiouAEIOU",
    "grave": "aeiouAEIOU",
    "tilde": "nN",
    "diaeresis": "aeiouAEIOU",
    "circumflex": "aeiouAEIOU",
}
ALL_ACCENTABLE = frozenset("".join(ACCENTABLE.values()))

# How many pixels a squeezed capital may legitimately differ by.  Beyond this
# the match is a coincidence, and the code goes to the review list instead of
# into the charmap -- a wrong glyph name is worse than a missing one.
MAX_MISFIT = 10

COMBINING = {
    "acute": "́",
    "grave": "̀",
    "tilde": "̃",
    "diaeresis": "̈",
    "circumflex": "̂",
}

# Glyphs with no base letter to match against.  Each is keyed by the exact
# tile bitmap so it is checked, not assumed: if a different ROM draws
# something else in that slot, it simply will not match and gets reported.
PUNCTUATION = {
    ("...##...", "...##...", "........", "...##...", ".##...##",
     "###..##.", ".######.", "........"): "¿",     # inverted question
    ("...##...", "...##...", "........", "...##...", "..####..",
     "..####..", "..####..", "...##..."): "¡",     # inverted exclamation
}


def read_tile(rom, base, index):
    start = base + TILE_BYTES * index
    data = rom[start:start + TILE_BYTES]
    return tuple("".join("#" if (byte >> (7 - column)) & 1 else "."
                         for column in range(8))
                 for byte in data)


def _ink(rows):
    return sum(row.count("#") for row in rows)


def _classify_accent(rows):
    """acute / grave / tilde / diaeresis from the top two rows."""
    top = rows[:ACCENT_ROWS]
    if _ink(top) == 0:
        return None
    columns = [[index for index, cell in enumerate(row) if cell == "#"]
               for row in top]
    if _ink(top) >= 6:
        return "tilde"
    # Two separated dots -- and they sit on the upper row alone, so this has
    # to be decided before any rule that needs ink on both rows.
    if len(columns[0]) >= 2 and columns[0][-1] - columns[0][0] >= 2:
        return "diaeresis"
    if not columns[0] or not columns[1]:
        return None
    # An acute or grave is a single pixel on each row, leaning one way or
    # the other.  Anything thicker is not a mark -- it is the top of a wide
    # two-character ligature, which some of these slots hold instead.
    if len(columns[0]) != 1 or len(columns[1]) != 1:
        return None
    first, second = columns[0][0], columns[1][0]
    if second > first:
        return "grave"
    if second < first:
        return "acute"
    return None


def _body(rows):
    """The glyph with its diacritic removed."""
    return tuple(rows[ACCENT_ROWS:])


def _distance(left, right):
    return sum(1 for a, b in zip("".join(left), "".join(right)) if a != b)


def _ink_rows(rows):
    filled = [index for index, row in enumerate(rows) if "#" in row]
    return (filled[0], filled[-1]) if filled else None


def _squeeze(rows, height):
    """The same glyph drawn `height` rows tall, by nearest-row resampling.

    Lowercase letters already fit under an accent, but a capital does not --
    the Spanish font redraws A as five rows instead of seven to make room.
    Comparing like with like means squeezing the English capital the same
    way before measuring."""
    span = _ink_rows(rows)
    if span is None or height <= 0:
        return None
    top, bottom = span
    source = bottom - top + 1
    out = []
    for index in range(height):
        first = top + (index * source) // height
        last = max(first + 1, top + ((index + 1) * source) // height)
        # OR the rows together rather than picking one, or a crossbar that
        # happens to fall between samples disappears and E stops looking
        # like E.
        merged = ["."] * len(rows[0])
        for row in rows[first:last]:
            for column, cell in enumerate(row):
                if cell == "#":
                    merged[column] = "#"
        out.append("".join(merged))
    return tuple(out)


def _ink_columns(rows):
    used = [index for row in rows for index, cell in enumerate(row)
            if cell == "#"]
    return (min(used), max(used)) if used else None


def _is_capital(rows):
    """Capitals in this font reach column 0; lowercase starts at column 1.

    That is the only reliable case signal left once a capital has been
    squeezed to make room for its accent -- by height it looks lowercase."""
    columns = _ink_columns(rows)
    return columns is not None and columns[0] == 0


def _best_letter(body, letters, accent=None):
    """Closest English letter to an accented glyph's body, at its own size or
    squeezed to fit."""
    span = _ink_rows(body)
    if span is None:
        return None, None
    height = span[1] - span[0] + 1
    if accent:
        allowed = ACCENTABLE[accent]
        letters = {character: glyph for character, glyph in letters.items()
                   if character in allowed} or letters
    capital = _is_capital(body)
    same_case = {character: glyph for character, glyph in letters.items()
                 if _is_capital(_body(glyph) if not _is_capital(glyph)
                                else glyph) == capital}
    letters = same_case or letters
    best, score = None, None
    for character, glyph in letters.items():
        options = [_distance(_body(glyph), body)]
        squeezed = _squeeze(glyph, height)
        if squeezed is not None:
            padded = (("........",) * span[0] + squeezed
                      + ("........",) * (len(body) - span[1] - 1))
            options.append(_distance(padded, body))
        distance = min(options)
        if score is None or distance < score:
            best, score = character, distance
    return best, score


def derive(base_rom, target_rom, manifest, base_font=None, target_font=None):
    """Return (mapping, unresolved) for every code whose glyph changed.

    `mapping` is code -> character; `unresolved` lists codes whose glyph
    changed but could not be named, with their art for review.
    """
    symbols = manifest["symbols"]
    bank, address = symbols["FontGraphics"]
    base_font = base_font if base_font is not None else to_offset(bank, address)
    target_font = (target_font if target_font is not None
                   else to_offset(bank, address))
    charmap = manifest["charmap"]

    letters = {}
    for code in range(FIRST_CODE, LAST_CODE + 1):
        name = charmap.get(str(code))
        if name in ALL_ACCENTABLE:
            letters[name] = read_tile(base_rom, base_font, code - FIRST_CODE)

    mapping = {}
    unresolved = []
    for code in range(FIRST_CODE, LAST_CODE + 1):
        index = code - FIRST_CODE
        here = read_tile(base_rom, base_font, index)
        there = read_tile(target_rom, target_font, index)
        if here == there:
            continue
        if there in PUNCTUATION:
            mapping[code] = (PUNCTUATION[there], 0)
            continue
        accent = _classify_accent(there)
        if accent is None:
            # Same character, redrawn -- a narrower 'm', say.  Keep the
            # English meaning; only report it if there was none.
            if charmap.get(str(code)):
                continue
            unresolved.append((code, there, "redrawn, no accent"))
            continue
        best, score = _best_letter(_body(there), letters, accent)
        if best is None or score > MAX_MISFIT:
            unresolved.append((code, there, "no base letter within tolerance"))
            continue
        composed = unicodedata.normalize("NFC", best + COMBINING[accent])
        if len(composed) != 1:
            unresolved.append((code, there,
                               "%s + %s is not a character" % (best, accent)))
            continue
        mapping[code] = (composed, score)
    return mapping, unresolved


def code_usage(rom, threshold=0.9, letters=0.3):
    """How often each code appears in the ROM's text banks.

    A derived character that never occurs is not worth arguing about; one
    that occurs hundreds of times had better be right.  The letter-density
    floor matters: a graphics bank is mostly bytes in the text range too,
    and counting it makes unused kana slots look busy.
    """
    counts = {}
    for start in range(0, len(rom), 0x4000):
        block = rom[start:start + 0x4000]
        inside = sum(1 for byte in block if byte in _TEXTISH)
        if inside < threshold * len(block):
            continue
        if sum(1 for byte in block if byte in _LETTERS) < letters * len(block):
            continue
        for byte in block:
            if byte >= FIRST_CODE:
                counts[byte] = counts.get(byte, 0) + 1
    return counts


_TEXTISH = (frozenset(range(0x00, 0x20)) | frozenset(range(0x4A, 0x60))
            | frozenset(range(0x7F, 0x100)))
_LETTERS = frozenset(range(0x80, 0x9B)) | frozenset(range(0xA0, 0xBA))


def render(rows):
    return "\n".join("      " + row for row in rows)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--symbols",
                        help="relocate.py output, so the target's "
                             "FontGraphics is read where it actually is")
    parser.add_argument("--out", help="write the mapping as JSON")
    parser.add_argument("--render", action="store_true",
                        help="print each changed glyph for review")
    args = parser.parse_args(argv)

    with open(args.base, "rb") as handle:
        base_rom = handle.read()
    with open(args.target, "rb") as handle:
        target_rom = handle.read()
    with open(args.manifest) as handle:
        manifest = json.load(handle)

    target_font = None
    if args.symbols:
        with open(args.symbols) as handle:
            relocated = json.load(handle)["symbols"]
        if "FontGraphics" in relocated:
            bank, address = relocated["FontGraphics"]
            target_font = to_offset(bank, address)

    mapping, unresolved = derive(base_rom, target_rom, manifest,
                                 target_font=target_font)

    bank, address = manifest["symbols"]["FontGraphics"]
    base_font = to_offset(bank, address)
    usage = code_usage(target_rom)
    print("%d codes were redrawn and named"
          " (fit = pixels off, uses = times the code appears in text):"
          % len(mapping))
    for code in sorted(mapping):
        character, score = mapping[code]
        print("  $%02X  %-2s  fit %-3d uses %d"
              % (code, character, score, usage.get(code, 0)))
        if args.render:
            print(render(read_tile(target_rom,
                                   target_font
                                   if target_font is not None else base_font,
                                   code - FIRST_CODE)))
    if unresolved:
        print("\n%d could not be named -- read these yourself:"
              % len(unresolved))
        for code, glyph, why in unresolved:
            print("  $%02X  (%s)" % (code, why))
            print(render(glyph))

    if args.out:
        with open(args.out, "w") as handle:
            json.dump({str(code): character
                       for code, (character, _) in sorted(mapping.items())},
                      handle, indent=2, ensure_ascii=False)
        print("\nwrote %s" % args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
