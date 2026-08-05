"""Byte-level alignment between two localisations of the same Game Boy ROM.

A translated Gen-1 cartridge is not a rewrite.  Almost every routine, every
graphics blob and every fixed-size table is byte-identical to the original --
what changes is the text, and everything after a longer or shorter string
slides.  So the two ROMs line up as a sequence of long identical runs
separated by short replaced regions, exactly the shape a diff is good at.

This module recovers that mapping one bank at a time:

  1. Find n-grams that occur exactly once in each bank.  A shared unique
     n-gram is an anchor: it can only correspond to itself.
  2. Keep the longest strictly increasing chain of anchors (LIS).  Content
     does not reorder inside a bank, so any anchor that would require going
     backwards is a coincidence and gets dropped.
  3. Grow each surviving anchor outwards while the bytes still agree, and
     merge the results into disjoint matched intervals.
  4. Recurse into the gaps with a shorter n-gram, which picks up the small
     identical fragments between two replaced strings.

The result is `BankAlignment`, which maps an offset in the original bank to
the same content's offset in the translated bank, or reports that the offset
falls inside a region that was replaced.

Nothing here knows what a symbol is -- see relocate.py for that.
"""

from __future__ import annotations

import bisect

BANK_SIZE = 0x4000

# Anchor widths, tried in order.  32 bytes is long enough that a shared
# occurrence is almost never chance; 12 then fills the gaps between two
# rewritten strings, where the surviving fragments are short.  Going below
# 12 is counterproductive: the extra anchors are mostly coincidences inside
# rewritten text, and they fragment the gaps that relocate.py interpolates
# across.  Measured against Spanish Yellow, (32, 12) resolves 94% of symbols
# where (32, 12, 8) manages 91%.
ANCHOR_WIDTHS = (32, 12)

# Below this a gap is not worth recursing into.
MIN_GAP = 16


def _unique_positions(data, start, end, width):
    """Offsets of every `width`-byte window that occurs exactly once in the
    half-open slice [start, end), keyed by the window itself."""
    once = {}
    repeated = set()
    for offset in range(start, end - width + 1):
        window = data[offset:offset + width]
        if window in repeated:
            continue
        if window in once:
            del once[window]
            repeated.add(window)
        else:
            once[window] = offset
    return once


def _longest_increasing(pairs):
    """Longest subsequence of (a, b) pairs -- already sorted by a -- whose b
    values strictly increase.  Patience sorting, O(n log n)."""
    if not pairs:
        return []
    tails = []          # tails[i] = smallest b ending an increasing run of i+1
    tail_index = []     # index into `pairs` of that run's last element
    previous = [-1] * len(pairs)
    for index, (_, b) in enumerate(pairs):
        slot = bisect.bisect_left(tails, b)
        if slot > 0:
            previous[index] = tail_index[slot - 1]
        if slot == len(tails):
            tails.append(b)
            tail_index.append(index)
        else:
            tails[slot] = b
            tail_index[slot] = index
    out = []
    cursor = tail_index[-1]
    while cursor >= 0:
        out.append(pairs[cursor])
        cursor = previous[cursor]
    out.reverse()
    return out


def _grow(left, right, left_pos, right_pos, width, left_lo, left_hi,
          right_lo, right_hi):
    """Extend a `width`-byte match at (left_pos, right_pos) as far as the
    bytes agree, without leaving the given windows."""
    start_l, start_r = left_pos, right_pos
    while (start_l > left_lo and start_r > right_lo
           and left[start_l - 1] == right[start_r - 1]):
        start_l -= 1
        start_r -= 1
    end_l, end_r = left_pos + width, right_pos + width
    while (end_l < left_hi and end_r < right_hi
           and left[end_l] == right[end_r]):
        end_l += 1
        end_r += 1
    return start_l, start_r, end_l - start_l


def _match_window(left, right, left_lo, left_hi, right_lo, right_hi,
                  width, out):
    """Collect monotone matched intervals between two windows."""
    if left_hi - left_lo < width or right_hi - right_lo < width:
        return
    left_once = _unique_positions(left, left_lo, left_hi, width)
    if not left_once:
        return
    right_once = _unique_positions(right, right_lo, right_hi, width)
    if not right_once:
        return
    shared = []
    for window, left_pos in left_once.items():
        right_pos = right_once.get(window)
        if right_pos is not None:
            shared.append((left_pos, right_pos))
    if not shared:
        return
    shared.sort()

    grown = []
    for left_pos, right_pos in _longest_increasing(shared):
        if grown:
            last_l, last_r, last_len = grown[-1]
            # Already covered by the previous anchor's growth.
            if left_pos < last_l + last_len and right_pos < last_r + last_len:
                continue
        grown.append(_grow(left, right, left_pos, right_pos, width,
                           left_lo, left_hi, right_lo, right_hi))

    # Growth can make two anchors overlap; keep a strictly increasing,
    # non-overlapping cover.
    for start_l, start_r, length in grown:
        if out:
            prev_l, prev_r, prev_len = out[-1]
            overlap_l = prev_l + prev_len - start_l
            overlap_r = prev_r + prev_len - start_r
            trim = max(overlap_l, overlap_r)
            if trim > 0:
                if trim >= length:
                    continue
                start_l += trim
                start_r += trim
                length -= trim
            if start_r <= prev_r:
                continue
        out.append((start_l, start_r, length))


class BankAlignment:
    """Maps offsets inside one bank of the original ROM onto the translated
    ROM's copy of the same bank."""

    def __init__(self, intervals, left_size, right_size):
        self.intervals = intervals
        self.left_size = left_size
        self.right_size = right_size
        self._starts = [interval[0] for interval in intervals]

    @property
    def matched_bytes(self):
        return sum(length for _, _, length in self.intervals)

    @property
    def coverage(self):
        if not self.left_size:
            return 0.0
        return self.matched_bytes / self.left_size

    def _interval_at(self, offset):
        slot = bisect.bisect_right(self._starts, offset) - 1
        if slot < 0:
            return None
        start_l, start_r, length = self.intervals[slot]
        if offset < start_l + length:
            return start_l, start_r, length
        return None

    def map(self, offset):
        """Translated-bank offset for `offset`, or None if it falls in a
        region that was replaced."""
        found = self._interval_at(offset)
        if found is None:
            return None
        start_l, start_r, _ = found
        return start_r + (offset - start_l)

    def _gap_around(self, offset):
        """The unmatched span containing `offset`, as
        ((left_lo, left_hi), (right_lo, right_hi))."""
        left_lo = right_lo = 0
        for start_l, start_r, length in self.intervals:
            if start_l + length <= offset:
                left_lo, right_lo = start_l + length, start_r + length
            elif start_l > offset:
                return (left_lo, start_l), (right_lo, start_r)
            else:
                return None
        return (left_lo, self.left_size), (right_lo, self.right_size)

    def locate(self, offset):
        """Best estimate of where `offset` went, as (offset, kind).

        Two things can be said with confidence.  Inside a matched run the
        answer is exact ("run").  Inside a gap whose two sides are the same
        length the translation substituted bytes without moving anything --
        a retargeted `jp`, a rewritten pointer -- so offsets still line up
        ("substitution").  A gap that changed length is a genuine insertion
        and nothing inside it can be placed; that returns None.
        """
        mapped = self.map(offset)
        if mapped is not None:
            return mapped, "run"
        gap = self._gap_around(offset)
        if gap is None:
            return None, None
        (left_lo, left_hi), (right_lo, right_hi) = gap
        if left_hi - left_lo != right_hi - right_lo:
            return None, None
        return right_lo + (offset - left_lo), "substitution"

    def maps_span(self, offset, length):
        """Translated offset for `offset`, but only when the whole span
        [offset, offset+length) sits inside a single matched run -- i.e. the
        content really is unchanged, not just the first byte."""
        found = self._interval_at(offset)
        if found is None:
            return None
        start_l, start_r, run = found
        if offset + length > start_l + run:
            return None
        return start_r + (offset - start_l)

    def candidates(self, offset):
        """Every position `offset` could plausibly have moved to, best first.

        Inside a matched run there is one answer.  Inside a gap there are two
        worth trying -- measured forwards from the run that ends the gap, and
        backwards from the run that starts it.  They coincide when the gap
        kept its length; when it did not, one of the two is usually still
        right, because a rewritten block tends to grow at one end rather
        than in the middle.  The caller is expected to check the bytes before
        believing any of them.
        """
        out = []
        exact = self.map(offset)
        if exact is not None:
            out.append(exact)
        gap = self._gap_around(offset)
        if gap is not None:
            (left_lo, left_hi), (right_lo, right_hi) = gap
            for guess in (right_lo + (offset - left_lo),
                          right_hi - (left_hi - offset)):
                if 0 <= guess < self.right_size and guess not in out:
                    out.append(guess)
        return out

    def bracket(self, offset):
        """(low, high) bounds on where `offset` must land in the translated
        bank, from the nearest matched run either side.  Used to sanity-check
        an address that had to be recovered some other way."""
        low, high = 0, self.right_size
        for start_l, start_r, length in self.intervals:
            if start_l + length <= offset:
                low = start_r + length
            elif start_l >= offset:
                high = start_r
                break
        return low, high


def align_bank(left, right, widths=None):
    """Align two byte strings holding the same bank of two ROM builds."""
    widths = widths or ANCHOR_WIDTHS
    intervals = []
    _match_window(left, right, 0, len(left), 0, len(right), widths[0],
                  intervals)

    for width in widths[1:]:
        refined = []
        cursor_l = cursor_r = 0
        for start_l, start_r, length in intervals + [(len(left), len(right), 0)]:
            if start_l - cursor_l >= MIN_GAP and start_r - cursor_r >= MIN_GAP:
                _match_window(left, right, cursor_l, start_l, cursor_r,
                              start_r, width, refined)
            if length:
                refined.append((start_l, start_r, length))
            cursor_l = start_l + length
            cursor_r = start_r + length
        intervals = refined

    return BankAlignment(intervals, len(left), len(right))


def align_rom(left_rom, right_rom, banks=None, widths=None,
              progress=None):
    """Align every bank of two ROM images.  Returns {bank: BankAlignment}."""
    widths = widths or ANCHOR_WIDTHS
    count = min(len(left_rom), len(right_rom)) // BANK_SIZE
    wanted = range(count) if banks is None else banks
    out = {}
    for bank in wanted:
        base = bank * BANK_SIZE
        alignment = align_bank(left_rom[base:base + BANK_SIZE],
                               right_rom[base:base + BANK_SIZE], widths)
        out[bank] = alignment
        if progress:
            progress(bank, alignment)
    return out
