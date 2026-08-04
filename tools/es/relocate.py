#!/usr/bin/env python3
"""Recover a translated ROM's symbol addresses from the English manifest.

The extractor resolves ~4,459 named symbols through `name -> [bank, address]`
pairs.  For English Red/Blue/Yellow those addresses come from a pret
disassembly's `.sym` output.  For a Spanish cartridge there is no such
disassembly, which is the single reason Spanish Yellow cannot be imported
today.

This tool derives the addresses from the two ROMs instead.  It never guesses:
every address it emits is either read out of the translated ROM's own
pointers or carried across a byte-identical run, and everything it emits is
range- and order-checked afterwards.  What it cannot establish it lists as
unresolved rather than inventing.

The strategies, in descending confidence:

  content   The bytes at the symbol are unchanged and sit inside one matched
            run of the bank alignment, so the symbol simply slid.  A symbol
            at the very first byte of a bank is included here: banks are
            fixed windows, so it cannot have moved at all.

  table     A whole family reached through one indexed table -- the map
            headers, addressed by a pointer table and a parallel bank table,
            both of which can be found exactly because we know every entry
            they hold in the English ROM.

  dexwalk   Each Pokedex description, read out of its own entry block.
            Refuses to run at all unless it first reproduces every known
            English address exactly.

  blockwalk A run of dialogue between two labels already placed, walked block
            by block on both sides.  Applied only when the English replay
            reproduces every address we know and the Spanish walk closes
            precisely on the label that ends the run; a walk that has drifted
            by one block does not close, which is what makes it safe to let
            this overrule a mislocated pointer.

  farptr    Gen-1 dialogue is reached through `text_far`: the byte $17, an
            address, a bank.  The pointer behind the $17 is the translated ROM
            telling us where it moved its own text.  Note that only 44 of
            2,694 such sites sit inside a matched run -- the rest have to be
            interpolated, and an interpolated site can land on the wrapper
            next door and read a valid pointer to the wrong label's text.
            That is why the walks above outrank it.

  farscan   The same idea where the block changed length: count `text_far`
            calls from the nearest position known on both sides.

  dwptr     Any two-byte reference to the symbol, relocated and re-read.  A
            pointer table is a run of these.

  pincer    Measured forward from the previous symbol and backward from the
            next; accepted only when the two agree.

  shape     Measured from one neighbour, when the symbol's own block has the
            same command shape on both sides -- same opcodes, same size, only
            the operands differ.

  carry     Stepped from a placed neighbour when every byte between the two
            is identical.

  textwalk  Dialogue between two placed labels, by counting string starts.

  aligned   A position the alignment placed rather than matched.  Exact when
            the address falls inside a matched run; otherwise interpolated
            across a gap that kept its length, and then only accepted when
            the bytes still mostly agree.

  unique    Last resort -- the symbol's leading bytes occur exactly once in
            the whole translated bank.

A candidate normally has to land inside the window the alignment brackets it
into, and afterwards the whole result is checked for symbols that overtook
their neighbour or landed on top of each other.  Whatever fails is thrown
away and the recovery loop runs again, because vacating a slot is what lets a
structural strategy answer where a higher-ranked one was sitting on a wrong
address.

    python3 tools/es/relocate.py \
        --base "Pokemon - Yellow Version.gbc" \
        --target "Pokemon Amarillo.gbc" \
        --manifest tools/rom_manifest_yellow.json \
        --out tools/es/yellow_es_symbols.json
"""

from __future__ import annotations

import argparse
import bisect
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from align import BANK_SIZE, align_rom  # noqa: E402

TX_FAR = 0x17

# Bytes compared when testing whether a symbol's content survived unchanged.
# Long enough to be distinctive, short enough that a symbol followed closely
# by translated text still matches.
PROBE = 48
MIN_PROBE = 8

# Confidence order -- earlier wins when two strategies disagree.
METHODS = ("content", "table", "dexwalk", "blockwalk", "farptr",
           "farscan", "dwptr", "pincer", "shape", "carry", "textwalk",
           "aligned", "unique", "gap")

# Bytes a Gen-1 string is built from: the control codes, the line/paragraph
# markers and terminators, and everything from $7F up -- space, the two
# letter runs, punctuation, digits, and the accented characters the Spanish
# release added above $BA.  Measured over the English manifest's own text
# symbols this admits 99.9% of them while a code bank only reaches ~75%.
TEXT_BYTES = (frozenset(range(0x00, 0x20))
              | frozenset(range(0x4A, 0x60))
              | frozenset(range(0x7F, 0x100)))
LETTER_BYTES = frozenset(range(0x80, 0x9B)) | frozenset(range(0xA0, 0xBA))
TEXT_DENSITY = 0.9

# What a Gen-1 string ends with -- text_end, done, prompt.  A text symbol
# should sit immediately after one of these; 99.7% of the English ones do.
TERMINATORS = frozenset([0x50, 0x57, 0x58])

# What ends a whole text block rather than one chunk of it, and how many
# payload bytes each value-splicing command carries.
STREAM_END = frozenset([0x57, 0x58, 0x5F])
SPLICE_PAYLOAD = {1: 2, 2: 3, 9: 3}

# `aligned` accepts a position the alignment interpolated rather than
# matched, so it insists the bytes there still look like the same thing.
# The bar is not high: where it applies, the position is already pinned by a
# gap that kept its length, and the data is often pointer-dense -- a music
# header is a handful of addresses, most of which shift by design.
SIMILARITY = 0.6

# How wide a same-length gap may be before "it must be in here somewhere"
# stops being an argument.  Only used by the `gap` method of last resort.
MAX_BLIND_GAP = 256


def _longest_run(slots):
    """Indices of the longest stretch of consecutive filled slots."""
    best, current = [], []
    for index, value in enumerate(slots):
        if value:
            current.append(index)
        else:
            if len(current) > len(best):
                best = current
            current = []
    return current if len(current) > len(best) else best


def ordered_map_headers(manifest):
    """Map header symbols in map-index order, as the ROM's tables hold them."""
    symbols = manifest["symbols"]
    slots = []
    for constant in manifest["constants"]["mapOrder"]:
        label = manifest["maps"].get(constant, {}).get("label")
        header = (label + "_h") if label else None
        slots.append(header if header in symbols else None)
    return [("map headers", slots)]


def _longest_non_decreasing(values):
    """Indices of a longest non-decreasing subsequence."""
    if not values:
        return []
    import bisect
    tails = []
    tail_index = []
    previous = [-1] * len(values)
    for index, value in enumerate(values):
        slot = bisect.bisect_right(tails, value)
        if slot > 0:
            previous[index] = tail_index[slot - 1]
        if slot == len(tails):
            tails.append(value)
            tail_index.append(index)
        else:
            tails[slot] = value
            tail_index[slot] = index
    out = []
    cursor = tail_index[-1]
    while cursor >= 0:
        out.append(cursor)
        cursor = previous[cursor]
    out.reverse()
    return out


def bank_window(bank):
    return (0x0000, 0x4000) if bank == 0 else (0x4000, 0x8000)


def to_offset(bank, address):
    low, _ = bank_window(bank)
    return bank * BANK_SIZE + address - low


def to_address(bank, offset):
    low, _ = bank_window(bank)
    return offset - bank * BANK_SIZE + low


class Relocator:
    def __init__(self, base, target, symbols, tables=(), dex_labels=(),
                 verbose=False):
        self.base = base
        self.target = target
        self.symbols = symbols
        self.tables = tables
        self.dex_labels = dex_labels
        self.verbose = verbose
        self.banks = min(len(base), len(target)) // BANK_SIZE
        self.alignments = {}
        self.resolved = {}      # name -> (bank, address)
        self.method = {}        # name -> strategy that produced it
        self.conflicts = []
        self.notes = []

        self.by_bank = collections.defaultdict(list)
        for name, (bank, address) in symbols.items():
            self.by_bank[bank].append((address, name))
        for entries in self.by_bank.values():
            entries.sort()

        self.at_address = collections.defaultdict(list)
        for name, (bank, address) in symbols.items():
            self.at_address[(bank, address)].append(name)

    # -- reporting ---------------------------------------------------------

    def log(self, message):
        if self.verbose:
            print(message, file=sys.stderr)

    # -- span of a symbol --------------------------------------------------

    def probe_length(self, bank, address):
        """How many bytes to treat as 'this symbol's content'.  Bounded by
        the next symbol in the same bank so a short symbol is not judged by
        its neighbour's bytes."""
        entries = self.by_bank[bank]
        _, high = bank_window(bank)
        following = high
        for other_address, _ in entries:
            if other_address > address:
                following = other_address
                break
        return max(MIN_PROBE, min(PROBE, following - address))

    # -- strategy 1: unchanged content -------------------------------------

    def pass_bank_starts(self):
        """A symbol at the first byte of a bank cannot have moved.

        Banks are fixed 16 KiB windows, so whatever the translation did
        inside one, its first byte is still its first byte.  This is what
        places the big name tables -- MoveNames, MonsterNames -- which are
        loaded with an explicit bank switch and so have no pointer to follow.
        """
        found = 0
        for name, (bank, address) in self.symbols.items():
            if bank >= self.banks or name in self.resolved:
                continue
            low, _ = bank_window(bank)
            if address == low:
                self.record(name, bank, address, "content")
                found += 1
        self.log("bank starts: %d" % found)

    def pass_content(self):
        found = 0
        for name, (bank, address) in self.symbols.items():
            if bank >= self.banks:
                continue
            alignment = self.alignments.get(bank)
            if alignment is None:
                continue
            offset = to_offset(bank, address) - bank * BANK_SIZE
            length = self.probe_length(bank, address)
            # The whole probe has to be inside one matched run.  Settling for
            # a shorter one is tempting and wrong: two different strings that
            # merely start alike -- "ELECTRODE is loafing around" and
            # "ELECTRODE ignored orders" share eight bytes -- then match, and
            # because this is the highest-ranked strategy that wrong answer
            # beats the pointer the ROM itself supplies.
            mapped = alignment.maps_span(offset, length)
            if mapped is not None:
                self.record(name, bank, to_address(bank, mapped + bank * BANK_SIZE),
                            "content")
                found += 1
        self.log("content: %d" % found)

    # -- strategies 2 and 3: follow the translated ROM's own pointers ------

    def _relocate_site(self, bank, site_offset):
        """Where a byte at `site_offset` in this bank of the base ROM ended up.

        The interesting sites are pointers, so by definition their own bytes
        differ and they never sit inside a matched run.  What saves us is
        that rewriting a pointer does not move anything: the gap it sits in
        is the same length on both sides, and `locate` interpolates through
        it."""
        alignment = self.alignments.get(bank)
        if alignment is None:
            return None
        mapped, _ = alignment.locate(site_offset)
        if mapped is not None:
            return mapped
        for start_l, start_r, length in alignment.intervals:
            if start_l + length == site_offset:
                return start_r + length
        return None

    def collect_far_pointers(self):
        """Every `text_far` site in the base ROM that names a known symbol."""
        sites = collections.defaultdict(list)
        data = self.base
        limit = len(data) - 3
        for offset in range(limit):
            if data[offset] != TX_FAR:
                continue
            address = data[offset + 1] | (data[offset + 2] << 8)
            target_bank = data[offset + 3]
            names = self.at_address.get((target_bank, address))
            if names:
                for name in names:
                    sites[name].append(offset)
        return sites

    def pass_far_pointers(self, sites):
        found = 0
        for name, offsets in sites.items():
            votes = collections.Counter()
            for offset in offsets:
                bank = offset // BANK_SIZE
                alignment = self.alignments.get(bank)
                if alignment is None:
                    continue
                base_of_bank = bank * BANK_SIZE
                readings = set()
                for moved in alignment.candidates(offset - base_of_bank):
                    site = base_of_bank + moved
                    if site + 3 >= len(self.target):
                        continue
                    if self.target[site] != TX_FAR:
                        continue
                    address = (self.target[site + 1]
                               | (self.target[site + 2] << 8))
                    target_bank = self.target[site + 3]
                    if target_bank >= self.banks:
                        continue
                    low, high = bank_window(target_bank)
                    if not low <= address < high:
                        continue
                    if not self.looks_like_text(
                            self.target, to_offset(target_bank, address)):
                        continue
                    readings.add((target_bank, address))
                # Only 44 of 2,694 sites sit inside a matched run; the rest
                # have to be interpolated, and a `text_far` wrapper is five
                # bytes, so the two interpolations either side of a gap can
                # land on adjacent wrappers and *both* read a valid pointer
                # to plausible text.  Taking the first would silently pick a
                # neighbouring label's string.  When the site is ambiguous,
                # say nothing and leave it to the passes anchored on
                # something that cannot move.
                if len(readings) == 1:
                    votes[readings.pop()] += 1
            picked = self._pick(name, votes)
            if picked is not None:
                self.record(name, picked[0], picked[1], "farptr")
                found += 1
        self.log("farptr: %d" % found)

    # -- strategy 3: anchored structural scan ------------------------------

    def looks_like_text(self, rom, offset, length=24):
        """Does `offset` point at a Gen-1 string?

        Cheap, and it is what makes the anchored scan safe: a wrong guess
        lands on code or graphics, which fail this immediately."""
        window = rom[offset:offset + length]
        if len(window) < 4:
            return False
        if not any(byte in LETTER_BYTES for byte in window):
            return False
        good = sum(1 for byte in window if byte in TEXT_BYTES)
        return good >= TEXT_DENSITY * len(window)

    def _far_candidates(self, rom, bank, start, stop):
        """Offsets in [start, stop) that look like a `text_far` pointing at
        real text.  Applied identically to both ROMs, so the n-th candidate
        on one side is the n-th on the other."""
        out = []
        base = bank * BANK_SIZE
        limit = min(stop, BANK_SIZE - 4)
        for offset in range(max(0, start), limit):
            if rom[base + offset] != TX_FAR:
                continue
            address = rom[base + offset + 1] | (rom[base + offset + 2] << 8)
            target_bank = rom[base + offset + 3]
            if target_bank >= self.banks:
                continue
            low, high = bank_window(target_bank)
            if not low <= address < high:
                continue
            if not self.looks_like_text(rom, to_offset(target_bank, address)):
                continue
            out.append(offset)
        return out

    def pass_far_scan(self, sites):
        """Recover the `text_far` sites the alignment could not place.

        Where a block really did change length -- a Pokedex entry whose
        category was translated, say -- interpolation gives up.  But the
        block still starts at a symbol we resolved, and it still contains the
        same `text_far` calls in the same order.  So count them from that
        anchor on the English side, count the same way on the Spanish side,
        and take the one at the matching position.
        """
        anchors = collections.defaultdict(list)
        # Every matched run ends at a position we know exactly on both sides,
        # and there are far more of those than there are symbols -- in the
        # Pokedex bank, eighty-odd runs against ten symbols.  Counting from
        # the nearest one keeps the window short, which is what makes the
        # count trustworthy.
        for bank, alignment in self.alignments.items():
            for start_l, start_r, length in alignment.intervals:
                anchors[bank].append((start_l + length, start_r + length))
        for name, (bank, address) in self.resolved.items():
            original_bank, original_address = self.symbols[name]
            if bank != original_bank:
                continue
            low, _ = bank_window(bank)
            anchors[bank].append((original_address - low, address - low))
        for entries in anchors.values():
            entries.sort()

        # Distance to the anchor is not what makes this safe -- the count
        # match is -- so the window is generous.  The Pokedex entries are one
        # long stretch with a single anchor at the front and 151 `text_far`
        # calls behind it, one per species, and they line up all the way.
        window = 4096
        drift = 0.25
        found = 0
        for name, offsets in sites.items():
            if name in self.resolved:
                continue
            for site in offsets:
                bank = site // BANK_SIZE
                offset = site - bank * BANK_SIZE
                entries = anchors.get(bank)
                if not entries:
                    continue
                slot = bisect.bisect_right(entries, (offset, BANK_SIZE)) - 1
                if slot < 0:
                    continue
                anchor_base, anchor_target = entries[slot]
                if offset - anchor_base > window:
                    continue
                here = self._far_candidates(self.base, bank, anchor_base,
                                            offset + 4)
                if not here or here[-1] != offset:
                    continue
                index = len(here) - 1
                reach = offset - anchor_base
                there = self._far_candidates(
                    self.target, bank, anchor_target,
                    anchor_target + int(reach * (1 + drift)) + window)
                if index >= len(there):
                    continue
                # Translation stretches a block; it does not double it.
                if abs((there[index] - anchor_target) - reach) > drift * reach + 256:
                    continue
                found_at = bank * BANK_SIZE + there[index]
                address = (self.target[found_at + 1]
                           | (self.target[found_at + 2] << 8))
                target_bank = self.target[found_at + 3]
                if self.in_bracket(name, target_bank, address):
                    self.record(name, target_bank, address, "farscan")
                    found += 1
                    break
        self.log("farscan: %d" % found)
        return found

    def collect_word_pointers(self):
        """Two-byte references to a known symbol, indexed by symbol.

        Same-bank references only, plus bank-0 targets referenced from
        anywhere -- those are the two forms the games actually use."""
        sites = collections.defaultdict(list)
        data = self.base
        home = {}
        for (bank, address), names in self.at_address.items():
            if bank == 0 and address >= 0x100:
                home[address] = names
        for bank in range(self.banks):
            base_of_bank = bank * BANK_SIZE
            low, high = bank_window(bank)
            local = {}
            for (other_bank, address), names in self.at_address.items():
                if other_bank == bank:
                    local[address] = names
            for offset in range(BANK_SIZE - 1):
                value = (data[base_of_bank + offset]
                         | (data[base_of_bank + offset + 1] << 8))
                names = None
                if low <= value < high:
                    names = local.get(value)
                elif value < 0x4000:
                    names = home.get(value)
                if names:
                    for name in names:
                        sites[name].append((bank, offset))
        return sites

    def pass_word_pointers(self):
        sites = self.collect_word_pointers()
        found = 0
        for name, entries in sites.items():
            if name in self.resolved:
                continue
            bank = self.symbols[name][0]
            low, high = bank_window(bank)
            votes = collections.Counter()
            for site_bank, offset in entries:
                alignment = self.alignments.get(site_bank)
                if alignment is None:
                    continue
                candidates = alignment.candidates(offset)
                for rank, moved in enumerate(candidates):
                    site = site_bank * BANK_SIZE + moved
                    if site + 1 >= len(self.target):
                        continue
                    value = self.target[site] | (self.target[site + 1] << 8)
                    if low <= value < high:
                        # The exact match, where there is one, outvotes the
                        # two interpolated guesses behind it.
                        votes[(bank, value)] += len(candidates) - rank
            picked = self._pick(name, votes)
            if picked is not None:
                self.record(name, picked[0], picked[1], "dwptr")
                found += 1
        self.log("dwptr: %d" % found)

    def _pick(self, name, votes):
        """Best-supported candidate that also fits where the alignment says
        the symbol has to be."""
        if not votes:
            return None
        for (bank, address), _ in votes.most_common():
            if self.in_bracket(name, bank, address):
                return bank, address
        return None

    # -- strategy 4: indexed tables ----------------------------------------

    def pass_indexed_tables(self, groups):
        """Resolve a whole family of symbols through the table that indexes it.

        Map headers are the case that matters.  They are reached through two
        parallel tables -- addresses in one, banks in the other -- and the
        addresses point across banks, so the per-site pointer strategies
        cannot see them.  But the tables can be found exactly: we know every
        entry's value in the English ROM, so the table is the one place those
        bytes occur in that order.  Relocate the two tables and the whole
        family falls out at once.
        """
        for label, slots in groups:
            self._resolve_indexed_table(label, slots)

    def _find_unique(self, needle):
        first = self.base.find(needle)
        if first < 0 or self.base.find(needle, first + 1) >= 0:
            return None
        return first

    def _resolve_indexed_table(self, label, slots):
        run = _longest_run(slots)
        if len(run) < 8:
            self.log("table %s: too few known entries to locate" % label)
            return
        addresses = b"".join(
            bytes([self.symbols[slots[index]][1] & 0xFF,
                   self.symbols[slots[index]][1] >> 8]) for index in run)
        banks = bytes(self.symbols[slots[index]][0] for index in run)
        pointer_at = self._find_unique(addresses)
        bank_at = self._find_unique(banks)
        if pointer_at is None or bank_at is None:
            self.log("table %s: could not locate its tables uniquely" % label)
            return
        pointer_base = pointer_at - 2 * run[0]
        bank_base = bank_at - run[0]

        known = [index for index, name in enumerate(slots) if name]
        for index in known:
            address = (self.base[pointer_base + 2 * index]
                       | (self.base[pointer_base + 2 * index + 1] << 8))
            if (self.base[bank_base + index], address) != self.symbols[slots[index]]:
                self.log("table %s: entry %d disagrees with the manifest"
                         % (label, index))
                return

        best = None
        for pointer_moved in self._site_candidates(pointer_base):
            for bank_moved in self._site_candidates(bank_base):
                agreed = 0
                reading = {}
                for index in known:
                    address = (self.target[pointer_moved + 2 * index]
                               | (self.target[pointer_moved + 2 * index + 1] << 8))
                    bank = self.target[bank_moved + index]
                    reading[index] = (bank, address)
                    if self.in_bracket(slots[index], bank, address):
                        agreed += 1
                if best is None or agreed > best[0]:
                    best = (agreed, reading)
        if best is None or best[0] < 0.9 * len(known):
            self.log("table %s: relocated tables did not check out (%s/%d)"
                     % (label, best[0] if best else "-", len(known)))
            return
        found = 0
        for index, (bank, address) in best[1].items():
            if self.in_bracket(slots[index], bank, address):
                if slots[index] not in self.resolved:
                    found += 1
                self.record(slots[index], bank, address, "table")
        self.log("table %s: %d new" % (label, found))

    def _site_candidates(self, offset):
        """Whole-ROM version of BankAlignment.candidates."""
        bank = offset // BANK_SIZE
        alignment = self.alignments.get(bank)
        if alignment is None:
            return []
        base_of_bank = bank * BANK_SIZE
        return [base_of_bank + moved
                for moved in alignment.candidates(offset - base_of_bank)]

    # -- strategy 4b: walk the Pokedex entries -----------------------------

    def _dex_measure_width(self, rom, bank, base, labels):
        """Bytes of height and weight per entry: 4 imperial, 3 metric.

        Decided for the table as a whole.  Per entry it is ambiguous -- a
        metric entry whose text pointer starts with $17 puts a TX_FAR where
        an imperial one would -- but only the real width works for all of
        them at once.
        """
        for width in (4, 3):
            for index, name in enumerate(labels):
                if not name:
                    continue
                cursor = self._dex_measure_start(rom, bank, base, index)
                if cursor is None or rom[cursor + width] != TX_FAR:
                    break
            else:
                return width
        return None

    def _dex_measure_start(self, rom, bank, base, index):
        """Offset of an entry's height byte, just past its category string."""
        cursor = to_offset(bank, base + index * 2)
        entry = rom[cursor] | (rom[cursor + 1] << 8)
        low, high = bank_window(bank)
        if not low <= entry < high:
            return None
        cursor = to_offset(bank, entry)
        end = cursor + 32
        while cursor < end and rom[cursor] != 0x50:
            cursor += 1
        if cursor >= end:
            return None
        return cursor + 1

    def _dex_entry_pointer(self, rom, bank, base, index, width):
        """The text_far target of Pokedex entry `index`, read from the ROM."""
        cursor = self._dex_measure_start(rom, bank, base, index)
        if cursor is None:
            return None
        cursor += width
        if rom[cursor] != TX_FAR:
            return None
        address = rom[cursor + 1] | (rom[cursor + 2] << 8)
        text_bank = rom[cursor + 3]
        if text_bank >= self.banks:
            return None
        low, high = bank_window(text_bank)
        if not low <= address < high:
            return None
        return text_bank, address

    def _dex_walk_agrees(self, labels):
        """Does the walk reproduce the base manifest exactly?"""
        bank, base = self.symbols["PokedexEntryPointers"]
        width = self._dex_measure_width(self.base, bank, base, labels)
        if width is None:
            return False
        for index, name in enumerate(labels):
            if not name:
                continue
            if self._dex_entry_pointer(self.base, bank, base, index,
                                       width) != self.symbols[name]:
                return False
        return True

    def pass_dex_entries(self, labels):
        """Read each Pokedex entry's text pointer out of its own entry block.

        `PokedexEntryPointers` resolves, and from there the layout is fixed:
        the category string, the height and weight, then the `text_far` to
        the description.  So every description address can be read rather
        than searched for -- the same walk the extractor does at import time.

        US cartridges spend four bytes on height and weight (feet, inches,
        pounds); European ones are metric and spend three.  Which it is
        shows in where the $17 lands.
        """
        table = self.resolved.get("PokedexEntryPointers")
        if table is None or not labels:
            return 0
        # Prove the walk before trusting it: run it on the English ROM, where
        # the answers are already known, and refuse to run it on the
        # translated one unless it reproduces every single address.  A walk
        # with the wrong index order reads a real address for the wrong
        # species, and that is worse than reading none.
        if not self._dex_walk_agrees(labels):
            self.notes.append("dexwalk: disabled, the walk does not reproduce "
                              "the base manifest")
            self.log("dexwalk: disabled (self-check failed)")
            return 0
        bank, base = table
        width = self._dex_measure_width(self.target, bank, base, labels)
        if width is None:
            self.log("dexwalk: the translated table has no consistent width")
            return 0
        found = 0
        for index, name in enumerate(labels):
            if not name:
                continue
            # Deliberately not skipping labels already resolved.  In the
            # Pokedex region the blocks changed length, so an interpolated
            # `text_far` site can land on a neighbouring entry and read a
            # perfectly valid pointer to the wrong species' description --
            # text that passes every plausibility check there is.  This walk
            # ranks above those strategies, so letting it overrule them is
            # the point.
            hit = self._dex_entry_pointer(self.target, bank, base, index,
                                          width)
            if hit is None:
                continue
            text_bank, address = hit
            if not self.looks_like_text(self.target,
                                        to_offset(text_bank, address)):
                continue
            # Count only what changes.  This pass re-reads every entry each
            # round on purpose, and reporting all 149 every time would keep
            # the loop looking productive forever.
            if self.resolved.get(name) != (text_bank, address):
                found += 1
            self.record(name, text_bank, address, "dexwalk")
        self.log("dexwalk: %d" % found)
        return found

    # -- strategy 5: carry from the neighbour ------------------------------

    def pass_carry(self):
        """Step from a placed neighbour when nothing changed in between.

        A symbol whose own bytes were rewritten cannot be found by its
        content, and one with no pointer to it cannot be read out of the ROM
        -- the trainer-class name list is both.  But its neighbour is placed,
        and if every byte between the two is identical in both ROMs then
        nothing moved in that span, so the distance carries over exactly.
        The byte comparison is the proof, not the assumption.
        """
        found = 0
        for bank, entries in sorted(self.by_bank.items()):
            if bank >= self.banks:
                continue
            low, _ = bank_window(bank)
            for index, (address, name) in enumerate(entries):
                if name in self.resolved:
                    continue
                for step in (-1, 1):
                    neighbour = index + step
                    if not 0 <= neighbour < len(entries):
                        continue
                    other_address, other_name = entries[neighbour]
                    anchor = self.resolved.get(other_name)
                    if anchor is None or anchor[0] != bank:
                        continue
                    candidate = anchor[1] + (address - other_address)
                    if not self.in_bracket(name, bank, candidate):
                        continue
                    first, last = sorted((address, other_address))
                    span = last - first
                    if span <= 0 or span > BANK_SIZE:
                        continue
                    here = to_offset(bank, first)
                    there = to_offset(bank, min(candidate, anchor[1]))
                    if self.base[here:here + span] != self.target[there:there + span]:
                        continue
                    self.record(name, bank, candidate, "carry")
                    found += 1
                    break
        self.log("carry: %d" % found)
        return found

    # -- strategy 5a: agreement between both neighbours --------------------

    def pass_pincer(self):
        """Place a symbol its two neighbours agree on.

        Measuring forward from the symbol before and backward from the symbol
        after gives two independent answers.  When they coincide, the block
        between them kept its length and there is only one address they can
        both be describing.  Neither estimate alone would be worth much; the
        agreement is the evidence.

        This is what places the small `text_far` wrappers -- five bytes of
        pointer and terminator -- which have no content to match and nothing
        pointing at them.
        """
        found = 0
        for bank, entries in sorted(self.by_bank.items()):
            if bank >= self.banks:
                continue
            for index, (address, name) in enumerate(entries):
                if name in self.resolved or index == 0:
                    continue
                if index + 1 >= len(entries):
                    continue
                before_address, before_name = entries[index - 1]
                after_address, after_name = entries[index + 1]
                before = self.resolved.get(before_name)
                after = self.resolved.get(after_name)
                if before is None or after is None:
                    continue
                # Both neighbours have to have landed in the same bank, but
                # not necessarily the one they started in -- translated text
                # spills into whatever bank was free.
                if before[0] != after[0]:
                    continue
                found_bank = before[0]
                forwards = before[1] + (address - before_address)
                backwards = after[1] - (after_address - address)
                if forwards != backwards:
                    continue
                low, high = bank_window(found_bank)
                if not low <= forwards < high:
                    continue
                self.record(name, found_bank, forwards, "pincer")
                found += 1
        self.log("pincer: %d" % found)
        return found

    # -- strategy 5a2: same command shape, measured from one neighbour -----

    def _shape(self, rom, bank, start, stop):
        """The command opcodes between two addresses, or None.

        Returns None unless the stream parses and lands exactly on `stop`.
        Text lengths are not part of the shape -- a translated chunk is a
        different length by definition -- but the opcodes and the exact
        landing are, and together they are enough to say two spans hold the
        same thing.
        """
        cursor = to_offset(bank, start)
        end = to_offset(bank, stop)
        if end <= cursor or end - cursor > BANK_SIZE:
            return None
        shape = []
        while cursor < end:
            command = rom[cursor]
            cursor += 1
            shape.append(command)
            if command == 0x50 or command in STREAM_END:
                continue
            if command == 0x00:
                while cursor <= end:
                    value = rom[cursor]
                    cursor += 1
                    if value == 0x50 or value in STREAM_END:
                        break
                else:
                    return None
                continue
            if command in SPLICE_PAYLOAD:
                cursor += SPLICE_PAYLOAD[command]
                continue
            return None
        return tuple(shape) if cursor == end else None

    def pass_shape_carry(self):
        """Measure from one neighbour when the block's own shape is intact.

        `pincer` needs both neighbours to agree, which fails when the
        neighbour on one side changed length.  If the symbol's own block did
        not -- same opcodes, same total size, only the operands differ -- then
        the distance from the neighbour on the *other* side still carries it,
        and the matching shape is what says so.
        """
        found = 0
        for bank, entries in sorted(self.by_bank.items()):
            if bank >= self.banks:
                continue
            for index, (address, name) in enumerate(entries):
                if name in self.resolved:
                    continue
                for step in (1, -1):
                    other = index + step
                    if not 0 <= other < len(entries):
                        continue
                    other_address, other_name = entries[other]
                    anchor = self.resolved.get(other_name)
                    if anchor is None:
                        continue
                    found_bank = anchor[0]
                    candidate = anchor[1] + (address - other_address)
                    low, high = bank_window(found_bank)
                    if not low <= candidate < high:
                        continue
                    first = min(address, other_address)
                    last = max(address, other_address)
                    mine = self._shape(self.base, bank, first, last)
                    if mine is None:
                        continue
                    theirs = self._shape(
                        self.target, found_bank, min(candidate, anchor[1]),
                        max(candidate, anchor[1]))
                    if theirs != mine:
                        continue
                    self.record(name, found_bank, candidate, "shape")
                    found += 1
                    break
        self.log("shape: %d" % found)
        return found

    # -- strategy 5b: walk the text blocks themselves ----------------------

    def _block_end(self, rom, bank, address, limit=4096):
        """Offset just past the text block starting at `address`.

        A Gen-1 string is a command stream, and it ends where the extractor
        stops reading it: a `text_end` at the top level, or a `done` /
        `prompt` / `$5F` inside a run of characters.  A bare `$50` in the
        middle only ends that chunk -- the stream carries on -- which is why
        counting `$50`s finds boundaries that are not there.
        """
        cursor = to_offset(bank, address)
        for _ in range(limit):
            command = rom[cursor]
            cursor += 1
            if command == 0x50:
                return cursor
            if command == 0x00:
                while True:
                    value = rom[cursor]
                    cursor += 1
                    if value == 0x50:
                        break
                    if value in STREAM_END:
                        return cursor
                continue
            if command in SPLICE_PAYLOAD:
                cursor += SPLICE_PAYLOAD[command]
                continue
            if command in STREAM_END:
                return cursor
            return None
        return None

    def _is_padding(self, rom, offset, run=8):
        """Is this the filler at the end of a bank rather than content?

        $00 is a legitimate text command, so a single byte proves nothing --
        a run of identical filler does.
        """
        window = rom[offset:offset + run]
        return (len(window) == run and window[0] in (0x00, 0xFF)
                and window.count(window[0]) == run)

    def _snap_to_terminator(self, bank, address):
        """Nudge an address onto a block boundary.

        Blocks are occasionally separated by a byte or two of padding, and
        the walk lands before it rather than after.  A text symbol sits
        immediately after a terminator -- 99.7% of the English ones do -- so
        that is what to look for, within a byte or two either way.
        """
        for delta in (0, 1, 2, -1, -2):
            offset = to_offset(bank, address + delta)
            if offset > 0 and self.target[offset - 1] in TERMINATORS:
                return address + delta
        return address

    def _try_block_run(self, bank, entries, left, right):
        """Place every label between two anchors by walking the blocks.

        Returns True only if the chain is exact at both ends: the English
        walk has to reproduce every address we already know between the two,
        and the Spanish walk has to arrive precisely on the closing label.
        Anything less and this says nothing and returns False, because a
        chain that is one block out relocates the whole run.
        """
        target_bank, left_address = self.resolved[entries[left][1]]
        right_bank, right_address = self.resolved[entries[right][1]]

        wanted = [entries[k][0] for k in range(left + 1, right + 1)]
        cursor = entries[left][0]
        for want in wanted:
            end = self._block_end(self.base, bank, cursor)
            if end is None or to_address(bank, end) != want:
                return False
            cursor = want

        steps = []
        cursor_bank, cursor = target_bank, left_address
        spilled = False
        for _ in wanted:
            end = self._block_end(self.target, cursor_bank, cursor)
            if end is None:
                return False
            cursor = self._snap_to_terminator(
                cursor_bank, to_address(cursor_bank, end))
            # Spanish text outgrew its bank.  Where the blocks run into the
            # padding at the end, the run continues at the start of the bank
            # the closing label landed in -- which is the one piece of
            # information needed to follow it, and that label supplies it.
            if (not spilled and right_bank != cursor_bank
                    and self._is_padding(
                        self.target, to_offset(cursor_bank, cursor))):
                cursor_bank, cursor = right_bank, bank_window(right_bank)[0]
                spilled = True
            steps.append((cursor_bank, cursor))
        if steps[-1] != (right_bank, right_address):
            return False

        # Deliberately not asking `in_bracket`.  That test bounds a symbol by
        # the identical runs either side of it, which is the right question in
        # a bank of code and the wrong one in a text bank that was 99.6%
        # rewritten -- there the handful of runs are coincidences, and they
        # clamp the window shut on correct answers.  This run is bounded by
        # two known symbol positions with an exact chain of blocks between
        # them, which is tighter than the alignment can offer.
        for offset, index in enumerate(range(left + 1, right)):
            name = entries[index][1]
            found_bank, address = steps[offset]
            low, high = bank_window(found_bank)
            if not low <= address < high:
                continue
            if not self.looks_like_text(
                    self.target, to_offset(found_bank, address)):
                continue
            self.record(name, found_bank, address, "blockwalk")
        return True

    def pass_block_walk_runs(self):
        """Audit and fill the text banks run by run.

        Anchors are the labels already placed.  Consecutive anchors are tried
        first; when that run will not close, wider pairs are tried, which is
        what steps over an anchor that is itself in the wrong place.  A
        closed run is authoritative for everything inside it, including
        labels another strategy already answered for -- that is how a
        `text_far` read from an interpolated site gets corrected.
        """
        # Reach far enough to step over a whole stretch of anchors that are
        # themselves misplaced.  Widening this is safe because a run is only
        # applied when it closes exactly on the label that ends it: a chain
        # that has drifted by even one block simply does not close.
        lookahead = 16
        longest = 96
        found = 0
        before = dict(self.resolved)

        text_by_bank = collections.defaultdict(list)
        for name, (bank, address) in self.symbols.items():
            if name.startswith("_"):
                text_by_bank[bank].append((address, name))
        for entries in text_by_bank.values():
            entries.sort()

        for bank, entries in sorted(text_by_bank.items()):
            if bank >= self.banks:
                continue
            placed = [index for index, (_, name) in enumerate(entries)
                      if name in self.resolved]
            cursor = 0
            while cursor < len(placed) - 1:
                left = placed[cursor]
                stepped = None
                for ahead in range(cursor + 1,
                                   min(cursor + 1 + lookahead, len(placed))):
                    right = placed[ahead]
                    if right - left > longest:
                        break
                    if right > left + 1 and self._try_block_run(
                            bank, entries, left, right):
                        stepped = ahead
                        break
                cursor = stepped if stepped is not None else cursor + 1

        for name, value in self.resolved.items():
            if before.get(name) != value:
                found += 1
        self.log("blockwalk: %d" % found)
        return found

    # -- strategy 6: walk the translated text bank -------------------------

    def _string_starts(self, rom, bank):
        base_of_bank = bank * BANK_SIZE
        block = rom[base_of_bank:base_of_bank + BANK_SIZE]
        return [offset for offset in range(1, len(block))
                if block[offset - 1] in TERMINATORS]

    def pass_text_walk(self):
        """Fill in dialogue between two labels we already placed.

        Text sits end to end in its bank, so between two known labels the
        strings on each side line up one for one.  When both sides agree on
        how many there are, the n-th is the n-th; when they disagree, the
        block was restructured and this says nothing.
        """
        cache = {}
        found = 0
        text_by_bank = collections.defaultdict(list)
        for name, (bank, address) in self.symbols.items():
            if name.startswith("_"):
                text_by_bank[bank].append((address, name))
        for entries in text_by_bank.values():
            entries.sort()

        for bank, entries in sorted(text_by_bank.items()):
            if bank >= self.banks:
                continue
            low, _ = bank_window(bank)
            anchors = [index for index, (_, name) in enumerate(entries)
                       if name in self.resolved]
            for left, right in zip(anchors, anchors[1:]):
                if right == left + 1:
                    continue
                pending = [entries[index] for index in range(left + 1, right)
                           if entries[index][1] not in self.resolved]
                if not pending:
                    continue
                start_bank, start_address = self.resolved[entries[left][1]]
                end_bank, end_address = self.resolved[entries[right][1]]
                if start_bank != end_bank or end_address <= start_address:
                    continue
                target_low, _ = bank_window(start_bank)
                here = [offset for offset in
                        self._string_starts(self.base, bank)
                        if entries[left][0] - low < offset < entries[right][0] - low]
                if start_bank not in cache:
                    cache[start_bank] = self._string_starts(self.target, start_bank)
                there = [offset for offset in cache[start_bank]
                         if start_address - target_low < offset
                         < end_address - target_low]
                if len(here) != len(there) or not here:
                    continue
                for address, name in pending:
                    try:
                        slot = here.index(address - low)
                    except ValueError:
                        continue
                    candidate = there[slot] + target_low
                    if not self.looks_like_text(
                            self.target, to_offset(start_bank, candidate)):
                        continue
                    self.record(name, start_bank, candidate, "textwalk")
                    found += 1
        self.log("textwalk: %d" % found)
        return found

    # -- strategy 6: interpolated position, checked against the bytes ------

    def pass_aligned(self):
        """Symbols the alignment can place but whose bytes were partly
        rewritten -- a table of addresses, a routine with retargeted jumps.

        The position comes from interpolation, so it is only accepted when
        most of the bytes there still agree with the original."""
        found = 0
        for name, (bank, address) in self.symbols.items():
            if name in self.resolved or bank >= self.banks:
                continue
            alignment = self.alignments.get(bank)
            if alignment is None:
                continue
            low, _ = bank_window(bank)
            offset = address - low
            mapped, _kind = alignment.locate(offset)
            if mapped is None:
                continue
            length = self.probe_length(bank, address)
            here = self.base[to_offset(bank, address):][:length]
            there = self.target[bank * BANK_SIZE + mapped:][:length]
            if len(there) < len(here):
                continue
            same = sum(1 for left, right in zip(here, there) if left == right)
            method = "aligned"
            if _kind == "run":
                # The address itself sits inside a matched identical run, so
                # its position is not interpolated at all -- the run is the
                # proof.  What the symbol holds past the end of that run may
                # well differ (a music header is mostly pointers), and
                # judging the position by those bytes would be judging it by
                # the wrong thing.
                pass
            elif same < SIMILARITY * len(here):
                # The bytes disagree, but the gap this sits in kept its
                # length on both sides and is short -- the Pokedex tile sheet
                # redrawn in Spanish, same size, same place.  Position by
                # structure and mark it as the weaker evidence it is.
                left, right = alignment.bracket(offset)
                if _kind != "substitution" or right - left > MAX_BLIND_GAP:
                    continue
                method = "gap"
            self.record(name, bank, to_address(bank, mapped + bank * BANK_SIZE),
                        method)
            found += 1
        self.log("aligned: %d" % found)

    # -- strategy 5: unique content ----------------------------------------

    def pass_unique(self):
        found = 0
        for name, (bank, address) in self.symbols.items():
            if name in self.resolved or bank >= self.banks:
                continue
            length = self.probe_length(bank, address)
            if length < 16:
                continue
            offset = to_offset(bank, address)
            needle = self.base[offset:offset + length]
            if len(set(needle)) < 4:
                continue    # flat padding matches anywhere meaningless
            base_of_bank = bank * BANK_SIZE
            haystack = self.target[base_of_bank:base_of_bank + BANK_SIZE]
            first = haystack.find(needle)
            if first < 0 or haystack.find(needle, first + 1) >= 0:
                continue
            candidate = to_address(bank, base_of_bank + first)
            if self.in_bracket(name, bank, candidate):
                self.record(name, bank, candidate, "unique")
                found += 1
        self.log("unique: %d" % found)

    # -- validation --------------------------------------------------------

    def in_bracket(self, name, bank, address):
        """Is `address` inside the window the alignment allows for `name`?

        A symbol cannot move past the identical runs on either side of it, so
        those runs bound it.  Only applies when the candidate stayed in the
        symbol's own bank -- a `text_far` that reports a different bank is
        taken at its word."""
        original_bank, original_address = self.symbols[name]
        low, high = bank_window(bank)
        if not low <= address < high:
            return False
        if bank != original_bank:
            # Spanish text outgrew its bank and spilled into space the
            # English build left empty.  The ROM said so itself, via the bank
            # byte of a `text_far`; there is nothing to bracket it against.
            return bank < self.banks
        alignment = self.alignments.get(bank)
        if alignment is None:
            return False
        low, _ = bank_window(bank)
        offset = original_address - low
        left, right = alignment.bracket(offset)
        candidate = address - low
        return left <= candidate <= right

    def record(self, name, bank, address, method):
        existing = self.resolved.get(name)
        if existing is None:
            self.resolved[name] = (bank, address)
            self.method[name] = method
            return
        if existing == (bank, address):
            return
        # Keep whichever strategy we trust more, but say so.
        keep_existing = METHODS.index(self.method[name]) <= METHODS.index(method)
        self.conflicts.append({
            "symbol": name,
            "kept": self.method[name] if keep_existing else method,
            "kept_address": list(existing if keep_existing else (bank, address)),
            "dropped": method if keep_existing else self.method[name],
            "dropped_address": list((bank, address) if keep_existing else existing),
        })
        if not keep_existing:
            self.resolved[name] = (bank, address)
            self.method[name] = method

    def check_collisions(self):
        """Two symbols that started apart cannot have ended up together.

        The order check cannot see this: equal addresses are non-decreasing,
        so a run with a duplicate in it still looks sorted.  Symbols that
        share an address in the base manifest are aliases and are left alone;
        it is only symbols that were genuinely in different places that
        cannot now be in one.  The less trustworthy claim loses.
        """
        bad = []
        landed = collections.defaultdict(list)
        for name, value in self.resolved.items():
            landed[value].append(name)
        for value, names in sorted(landed.items()):
            if len(names) < 2:
                continue
            if len({self.symbols[name] for name in names}) < 2:
                continue        # aliases of one address, which is fine
            names.sort(key=lambda name: (METHODS.index(self.method[name]),
                                         name))
            for name in names[1:]:
                bad.append({
                    "symbol": name,
                    "bank": value[0],
                    "address": value[1],
                    "method": self.method[name],
                    "clashesWith": names[0],
                })
        return bad

    def _drop(self, violations):
        """Forget addresses the order check rejected."""
        for violation in violations:
            self.resolved.pop(violation["symbol"], None)
            self.method.pop(violation["symbol"], None)
        return violations

    def check_order(self):
        """Assembling a translated bank does not shuffle its contents.

        So within each destination bank, symbols must come out in the same
        order they went in.  Rather than blaming whichever symbol trips the
        check first, keep the largest subset that is consistent and report
        the rest -- one bad address should not evict its innocent
        neighbours."""
        bad = []
        landed = collections.defaultdict(list)
        for name, (bank, address) in self.resolved.items():
            landed[bank].append((self.symbols[name], address, name))
        for bank, entries in sorted(landed.items()):
            entries.sort(key=lambda entry: entry[0])
            addresses = [address for _, address, _ in entries]
            keep = set(_longest_non_decreasing(addresses))
            for index, (_, address, name) in enumerate(entries):
                if index not in keep:
                    bad.append({
                        "symbol": name,
                        "bank": bank,
                        "address": address,
                        "method": self.method[name],
                    })
        return bad

    # -- driver ------------------------------------------------------------

    def run(self):
        def progress(bank, alignment):
            self.log("bank %02X aligned: %.1f%% identical, %d runs"
                     % (bank, alignment.coverage * 100, len(alignment.intervals)))

        self.alignments = align_rom(self.base, self.target,
                                    progress=progress if self.verbose else None)
        far_sites = self.collect_far_pointers()
        self.pass_content()
        self.pass_bank_starts()
        self.pass_indexed_tables(self.tables)
        self.pass_far_pointers(far_sites)
        self.pass_word_pointers()
        # Before the iterative passes, not after: they walk outwards from
        # symbols already placed, and `aligned` is what places some of the
        # tables they need to start from.
        self.pass_aligned()
        # Each round turns freshly resolved symbols into anchors for the
        # next, so keep going while it is still paying.  When a round stops
        # paying, audit the order and throw away whatever is out of place:
        # a wrong address is worse than a missing one, and vacating the slot
        # gives the structural strategies a chance at it that they did not
        # have while a higher-ranked strategy was sitting on the wrong
        # answer.
        order_violations = []
        for _ in range(8):
            # Dex entries first: this reads the pointer out of the entry
            # block, so it is exact, and letting the counting heuristic claim
            # them first only means throwing its answers away again.
            progressed = self.pass_dex_entries(self.dex_labels)
            progressed += self.pass_far_scan(far_sites)
            progressed += self.pass_pincer()
            progressed += self.pass_shape_carry()
            progressed += self.pass_carry()
            progressed += self.pass_block_walk_runs()
            progressed += self.pass_text_walk()
            if not progressed:
                found = self.check_order() + self.check_collisions()
                if not found:
                    break
                order_violations.extend(self._drop(found))
        self.pass_unique()
        order_violations.extend(
            self._drop(self.check_order() + self.check_collisions()))

        unresolved = sorted(name for name in self.symbols
                            if name not in self.resolved)
        counts = collections.Counter(self.method.values())
        identical = sum(a.matched_bytes for a in self.alignments.values())
        total = self.banks * BANK_SIZE
        return {
            "symbols": {name: [bank, address]
                        for name, (bank, address) in sorted(self.resolved.items())},
            "method": dict(sorted(self.method.items())),
            "unresolved": unresolved,
            "conflicts": self.conflicts,
            "order_violations": order_violations,
            "stats": {
                "total": len(self.symbols),
                "resolved": len(self.resolved),
                "unresolved": len(unresolved),
                "by_method": dict(counts),
                "identical_bytes": identical,
                "identical_fraction": (identical / total) if total else 0.0,
                "banks": self.banks,
            },
        }


def dex_entry_labels(manifest):
    """The `_XDexEntry` symbols in the order PokedexEntryPointers holds them.

    That order is the internal species index -- Rhydon first, the order
    BaseStats uses -- not the Pokedex number.  Getting this wrong reads a
    real address for the wrong species, which is worse than reading none.
    """
    labels = manifest.get("dexEntryLabels", {})
    symbols = manifest["symbols"]
    out = []
    for species in manifest["constants"].get("speciesOrder", []):
        name = labels.get(species)
        out.append(name if name in symbols else None)
    return out


def relocate(base, target, symbols, tables=(), dex_labels=(), verbose=False):
    return Relocator(base, target, symbols, tables, dex_labels, verbose).run()


def format_report(result, name="relocation"):
    stats = result["stats"]
    lines = []
    lines.append("%s: %d/%d symbols resolved (%.2f%%)"
                 % (name, stats["resolved"], stats["total"],
                    100.0 * stats["resolved"] / max(1, stats["total"])))
    lines.append("  ROMs are %.1f%% byte-identical across %d banks"
                 % (stats["identical_fraction"] * 100, stats["banks"]))
    for method in METHODS:
        if method in stats["by_method"]:
            lines.append("  %-8s %5d" % (method, stats["by_method"][method]))
    if result["conflicts"]:
        lines.append("  conflicts resolved by confidence: %d"
                     % len(result["conflicts"]))
    if result["order_violations"]:
        lines.append("  dropped for going backwards in their bank: %d"
                     % len(result["order_violations"]))
    if result["unresolved"]:
        lines.append("  unresolved (%d):" % len(result["unresolved"]))
        for symbol in result["unresolved"][:40]:
            lines.append("    %s" % symbol)
        if len(result["unresolved"]) > 40:
            lines.append("    ... and %d more"
                         % (len(result["unresolved"]) - 40))
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True,
                        help="ROM the manifest was built for (English)")
    parser.add_argument("--target", required=True,
                        help="ROM to derive addresses for (Spanish)")
    parser.add_argument("--manifest", required=True,
                        help="manifest holding the base ROM's symbols")
    parser.add_argument("--out", help="write the derived symbol table here")
    parser.add_argument("--report", help="write the human-readable report here")
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
    result = relocate(base, target, symbols, ordered_map_headers(manifest),
                      dex_entry_labels(manifest), verbose=not args.quiet)

    report = format_report(result)
    print(report)
    if args.report:
        with open(args.report, "w") as handle:
            handle.write(report + "\n")
    if args.out:
        with open(args.out, "w") as handle:
            json.dump(result, handle, indent=2, sort_keys=True)
        print("wrote %s" % args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
