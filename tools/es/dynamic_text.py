"""Rebuild the `text.dynamic` table for a translated ROM.

A Gen-1 string is a little command stream, and three of its commands splice
in a value from RAM -- the player's name, a Pokemon's nickname, a number.
The manifest records what each splice means, per label, in order:

    "_AbandonLearningText": [[1, "{RAM:wStringBuffer}"]]

That list cannot be carried across to a translation.  Spanish word order is
not English word order, so a line can splice in a different order, or splice
where the English did not: "missing substitution for command $01".

But the commands themselves carry the RAM address they read, and the address
is the same in both builds -- it is RAM, not ROM, and nothing moved it.  So
learn address -> name from the English ROM, where the manifest says what each
splice is, then walk the translated streams and name their splices from what
they actually read.

Whatever cannot be named is reported, and its label is dropped rather than
guessed at.
"""

from __future__ import annotations

# Commands that splice in a value, and how many bytes of payload each takes.
# The first two are always the RAM address being read.
SPLICE = {1: 2, 2: 3, 9: 3}

TEXT_START = 0x00
TEXT_END = 0x50
STREAM_END = frozenset([0x57, 0x58, 0x5F])
MAX_COMMANDS = 4096


def walk(rom, bank, address):
    """The splice commands in one string, as (command, ram_address).

    Mirrors the extractor's own decoder, so a stream it would reject is
    rejected here too -- by raising, which the caller turns into a dropped
    label."""
    out = []
    cursor = _offset(bank, address)
    for _ in range(MAX_COMMANDS):
        command = rom[cursor]
        cursor += 1
        if command == TEXT_END:
            return out
        if command == TEXT_START:
            while True:
                value = rom[cursor]
                cursor += 1
                if value == TEXT_END:
                    break
                if value in STREAM_END:
                    return out
            continue
        payload = SPLICE.get(command)
        if payload is None:
            raise ValueError("unsupported text command $%02X" % command)
        out.append((command, rom[cursor] | (rom[cursor + 1] << 8)))
        cursor += payload
    raise ValueError("text command stream is too long")


def _offset(bank, address):
    return bank * 0x4000 + address - (0x4000 if bank else 0)


def learn(base_rom, manifest):
    """(command, ram address) -> token, from the English ROM and manifest."""
    known = {}
    dynamic = manifest["text"]["dynamic"]
    symbols = manifest["symbols"]
    for label, entries in dynamic.items():
        location = symbols.get(label)
        if location is None:
            continue
        try:
            found = walk(base_rom, location[0], location[1])
        except ValueError:
            continue
        if len(found) != len(entries):
            continue
        for (command, address), entry in zip(found, entries):
            expected, token = entry[0], entry[1]
            if command != expected:
                continue
            known[(command, address)] = token
    return known


def learn_ram_map(base_rom, target_rom, manifest, resolved):
    """Translated RAM address -> the English address holding the same thing.

    The Spanish build's work RAM is not laid out identically -- the buffers
    this text reads sit five bytes further along.  Nothing in the ROM says
    so, but most lines splice the same values in the same order in both
    languages, and those lines pair their addresses up for us.  A pairing is
    only believed when the lines that disagree are outvoted.
    """
    votes = {}
    symbols = manifest["symbols"]
    for label in manifest["text"]["labels"]:
        here, there = symbols.get(label), resolved.get(label)
        if here is None or there is None:
            continue
        try:
            mine = walk(base_rom, here[0], here[1])
            theirs = walk(target_rom, there[0], there[1])
        except ValueError:
            continue
        if len(mine) != len(theirs):
            continue
        if [command for command, _ in mine] != [command for command, _ in theirs]:
            continue
        for (command, base), (_, target) in zip(mine, theirs):
            votes.setdefault((command, target), {})
            votes[(command, target)][base] = \
                votes[(command, target)].get(base, 0) + 1
    out = {}
    for key, tally in votes.items():
        best = max(tally, key=tally.get)
        if tally[best] * 2 > sum(tally.values()):
            out[key] = best
    return out


def rebuild(base_rom, target_rom, manifest, resolved):
    """The translated ROM's `text.dynamic`, plus the labels it defeated.

    `resolved` maps label -> (bank, address) in the translated ROM.
    """
    known = learn(base_rom, manifest)
    ram = learn_ram_map(base_rom, target_rom, manifest, resolved)
    dynamic = {}
    unnamed = {}
    for label in manifest["text"]["labels"]:
        location = resolved.get(label)
        if location is None:
            continue
        try:
            found = walk(target_rom, location[0], location[1])
        except ValueError as error:
            unnamed[label] = str(error)
            continue
        if not found:
            continue
        entries = []
        for command, address in found:
            base = ram.get((command, address), address)
            token = known.get((command, base))
            if token is None:
                unnamed[label] = ("no name for command $%02X reading $%04X"
                                  % (command, address))
                break
            entries.append([command, token])
        else:
            dynamic[label] = entries
    return dynamic, unnamed
