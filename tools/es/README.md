# Importing a translated cartridge

`tools/es/` builds an import manifest for a localised Gen-1 cartridge from
the English one, by reading the two ROMs against each other.

It exists because the extractor needs `name -> [bank, address]` for ~4,459
symbols, and for the English games those addresses come from a pret
disassembly's `.sym` output. There is no Spanish Yellow disassembly, and
there may never be one — so these tools recover the addresses from the
cartridge instead.

Run against **Pokémon Edición Amarilla** (Spain) it resolves **all 4,711
symbols**, and the extractor completes every stage.

## Use it

```bash
python3 tools/es/make_es_manifest.py \
    --base "Pokemon - Yellow Version.gbc" \
    --target "Pokemon - Edicion Amarilla.gb" \
    --manifest tools/rom_manifest_yellow.json \
    --out tools/rom_manifest_yellow_es.json \
    --report tools/es/yellow_es_report.txt
```

Then add the cartridge to `GameVersion.VERSIONS` with the SHA-1 the report
prints, and it imports like any other ROM. `yellow_es` is already there.

To find out what a ROM is first:

```bash
python3 tools/es/romid.py "some dump.gb"
```

## How it works

A translated cartridge is not a rewrite. Every routine, every graphics blob
and every fixed-size table is byte-identical; what changes is the text, and
everything after a longer or shorter string slides. The Spanish and English
Yellow ROMs are **72% byte-identical**, and 32 of their 62 used banks line up
at exactly the same offsets.

`align.py` recovers that correspondence per bank: n-grams unique to both banks
are anchors, the longest increasing chain of them survives, each anchor grows
until the bytes stop agreeing. What is left is a list of identical runs with
short replaced regions between them.

`relocate.py` turns that into addresses, by whichever of these it can prove:

| | how |
|---|---|
| `content` | the bytes are unchanged and sit inside one matched run — it just slid. A symbol at a bank's first byte is here too: banks are fixed windows |
| `table` | a whole family reached through one indexed table. Map headers are addressed by a pointer table plus a parallel bank table, and both can be found exactly because we know every entry the English ROM holds |
| `blockwalk` | dialogue between two placed labels, block by block. A Gen-1 block ends on `$57`/`$58`, not on any `$50`, so boundaries are exact; a run is applied only if the English replay reproduces every known address **and** the Spanish chain closes precisely on the label that ends it. It follows text that outgrew its bank into the spill bank |
| `dexwalk` | each Pokédex description, read out of its own entry block — category string, height, weight, then the `text_far` |
| `farptr` | dialogue is reached through `text_far`: `$17`, address, bank. The `$17` is untouched code so it relocates by alignment, and the pointer behind it is the cartridge telling us where its own text went |
| `farscan` | the same, where the block changed length: count `text_far` calls from the nearest position known on both sides |
| `dwptr` | any two-byte reference to the symbol, relocated and re-read. A pointer table is a run of these |
| `pincer` | measure forward from the symbol before and backward from the one after; when the two agree there is only one address they can both describe |
| `shape` | measure from one neighbour when the block's own command shape is intact — same opcodes, same size, different operands |
| `carry` | step from a placed neighbour when every byte between the two is identical |
| `aligned` | an interpolated position, accepted only when the bytes there still mostly agree |
| `gap` | a same-length gap under 256 bytes: redrawn graphics, same size, same place |

`charmap.py` reads the font to find out what the character codes mean. The
Spanish build did not extend the character set — it reused the kana slots
`$C0`–`$DF` for accented vowels and two apostrophe-ligature slots for `¿` and
`¡`. Nothing in the ROM records that, but a changed glyph *is* a reassigned
code: strip the diacritic rows, match what is left against the English
letters, then read the diacritic. Run it with `--render` to check the
conclusions against the art.

`dynamic_text.py` rebuilds the RAM-splice table. Spanish word order puts the
substitutions somewhere else, and the Spanish build's work RAM sits five
bytes further along, so both the positions and the addresses are learned from
the streams rather than copied.

## What keeps it honest

Nothing here is allowed to guess:

- **Bracketing.** A symbol cannot move past the identical runs either side of
  it, so those runs bound every candidate. Out-of-window candidates are
  discarded.
- **Ordering.** Assembling a bank does not shuffle it, so within each
  destination bank the symbols must come out in the order they went in. The
  largest self-consistent subset is kept and the rest reported — one bad
  address should not evict its neighbours.
- **Self-check before trust.** `dexwalk` runs on the *English* ROM first and
  refuses to run on the translated one unless it reproduces all 151 known
  addresses exactly. This caught a real bug: `PokedexEntryPointers` is
  indexed by internal species order, not Pokédex number, and the wrong order
  reads a real address for the wrong species — text that passes every
  plausibility check there is.
- **Conflicts are ranked, not averaged.** When two strategies disagree the
  more trustworthy one wins and the disagreement is recorded. On Spanish
  Yellow this is what stops `farptr` from mislabelling 24 Pokédex entries.
- **Plausibility.** A recovered text address must point at something that
  looks like a Gen-1 string. Calibrated against the English manifest's own
  2,686 text symbols, that test admits 99.9% of them while a code bank only
  reaches 75%.
- **No two things in one place.** Symbols that started at different addresses
  cannot end at the same one. The order check cannot see this — equal
  addresses are still non-decreasing — so collisions are checked separately,
  and the less trustworthy claim loses. This caught a real one.
- **The audit feeds back.** When a round stops making progress, the order and
  collision checks run and whatever is out of place is discarded, then the
  loop goes again. Vacating a slot is what lets a structural strategy answer
  where a higher-ranked one was sitting on the wrong address.
- **Nothing dangling.** Symbols that could not be placed are dropped from the
  manifest's reference lists, so the extractor is never asked for an address
  that does not exist. Those lines stay untranslated instead of failing the
  import.

Measured against the English manifest, which is the baseline for what correct
looks like:

| | English (ground truth) | Spanish (derived) |
|---|---|---|
| text addresses sitting just after a terminator | 2,677/2,686 (99.66%) | 2,675/2,686 (99.59%) |
| consecutive labels one text block apart | 2,518 exact, 149 within 2 bytes | 2,660 exact |
| pairs the block chain cannot reconcile | 10 | 10 |
| distinct symbols sharing a destination | 0 | 0 |

## The one thing to be careful about

`farptr` supplies more than half the addresses, and **only 44 of its 2,694
sites sit inside a matched run — the other 2,650 have to be interpolated.** A
`text_far` wrapper is five bytes, so an interpolated site can land on the
wrapper next door and read a perfectly valid pointer to the *neighbouring
label's* text. Nothing about the result looks wrong: it is a real address,
in range, pointing at real Spanish.

That is not hypothetical. A run of nine labels around `_CantDepositLastMonText`
came out shifted by exactly one block each, and none of the range, order,
plausibility or terminator checks noticed, because every individual answer was
well-formed. It was found by reading the decoded Spanish against the English
and is fixed — `blockwalk` reaches far enough to bridge a stretch of bad
anchors, and its exact-closure requirement is what makes the correction safe.

The general lesson is that a strategy anchored on something that cannot move
beats one anchored on an interpolation. An earlier attempt at a whole-bank
census — anchor at `$4000`, walk every block, assign the n-th block to the
n-th label — looked airtight and was wrong: the Spanish banks do not hold the
same number of blocks, so it drifted and produced 156 confident wrong answers
where `farptr` had been right. It was removed. `blockwalk` does the same walk
but refuses to apply a run that does not close exactly, which is the whole
difference.

**So: treat the manifest as very good, not proven.** The checks below all
agree with the English baseline, and every spot-check has been correct, but
the class of error above is detectable only by reading the text.

## Other languages

Nothing here is Spanish-specific. French, German and Italian Yellow should
work the same way, and Red/Blue in any language by pointing `--manifest` at
`tools/rom_manifest.json`. What is Spanish-specific is only which font slots
got reused, and `charmap.py` derives that from whichever ROM you give it.

The one genuine format difference found so far is that European cartridges
store Pokédex height and weight in metric — one byte of decimetres and two of
hectograms, against the US four bytes of feet, inches and tenths of a pound.
Both extractors detect which layout they are reading, keep the metric figures,
and convert for the imperial fields so nothing downstream has to care.

Which layout it is has to be decided for the table as a whole, not per entry:
the marker is the `text_far` that follows the measurements, and a metric entry
whose text pointer happens to begin with `$17` puts one exactly where an
imperial entry would. TENTACOOL is that entry in the Spanish cartridge
(`$09 $C7 $01 $17 $17`), and reading it as imperial yields 199 inches. Across
all 151 entries only the real width works.

Converted against the US Yellow cartridge's own figures, the heights agree
exactly for all 151 species. The weights do not: 21 match and the rest sit
within 0.6 lb, because Nintendo authored the two figures independently rather
than converting one from the other. Pikachu is 0.4 m / 6.0 kg on the Spanish
cart, converting to 1′04″ / 13.2 lb where the US cart states 13.0 lb. The
metric figures are kept verbatim and are what a Spanish import displays.

## Files

| | |
|---|---|
| `align.py` | byte-level bank alignment; no knowledge of symbols |
| `relocate.py` | symbol recovery and validation. Runs standalone |
| `charmap.py` | character map from the font. `--render` to review |
| `dynamic_text.py` | RAM-splice table for translated streams |
| `make_es_manifest.py` | the whole pipeline; writes the manifest |
| `romid.py` | identify a ROM and say why it is or is not accepted |
| `yellow_es_report.txt` | the current Edición Amarilla run |
