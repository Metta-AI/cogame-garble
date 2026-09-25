# Garble rules

## Seats, commodities and contracts

- **Five seats**, always. In-game they are anonymous cog aliases drawn from the
  seed; a policy display name never reaches a seat.
- **Four commodities in fixed index order: `ORE` (0), `OAT` (1), `TIN` (2),
  `TAR` (3).** The names are chosen so a channel swap produces a *valid but
  wrong* commodity: `ORE` <-> `OAT` and `TIN` <-> `TAR` are the only confusable
  pairs.
- **Prices** are public, current and previous turn. The whole path is drawn at
  init from the seed: `price[0][c] = 8 + rand(6)`, then a -1/0/+1 walk clamped
  to `3..30`.
- **Endowment.** Seat `s` starts with 20 units of its surplus commodity, 0 of
  everything else, and 120 credits.
- **Contract.** Seat `s` is paid `premium[s]` (6..9) credits for each unit of its
  demand commodity `dem[s]` held at the horizon, up to `quota[s]` (12..19) units.
  Beyond the quota those units are worth only the market price. **A seat's own
  contract is private** - nobody else learns its demand commodity, its premium or
  its quota except by inference from what it says.

## The wire

A transmission is one line of text. The exchange normalises it before anything
else: uppercase, every character outside `[A-Z0-9]` replaced by a space, split on
whitespace, truncated to **32 words**.

Four word classes; everything else is chatter:

| class | members |
| --- | --- |
| verb | `SELL`, `BUY` |
| pivot | `AT` |
| commodity | `ORE`, `OAT`, `TIN`, `TAR` |
| number | any digit string of 1-2 digits (`0`..`99`), or one of `ZERO ONE TWO THREE FOUR FIVE SIX SEVEN EIGHT NINE TEN ELEVEN TWELVE THIRTEEN FOURTEEN FIFTEEN SIXTEEN SEVENTEEN EIGHTEEN NINETEEN TWENTY THIRTY FORTY FIFTY SIXTY SEVENTY EIGHTY NINETY` |

There are **no compound spellings**: `TWENTY FIVE` is two number words worth 20
and 5, not 25. Round numbers can be spoken; odd ones must be digits - which
matters, because digits garble more widely than words.

### The scanner, exactly

Run identically on the said text and on every heard text:

1. `v` = the smallest index with `words[v]` in `{SELL, BUY}`. None => **no terms**
   (the transmission is chatter).
2. `a` = the smallest index `> v` with `words[a] == "AT"`. None => **no terms**.
3. `side` = `SELL` or `BUY` from `words[v]`, **stated from the transmitter's point
   of view**.
4. **qty** = the *modal* value among the number words in `words[v+1 .. a-1]`; ties
   in multiplicity break toward the **last** such word. No number word there =>
   **no terms**. `kQty` = the multiplicity of that modal value.
5. **commodity** = the *modal* commodity word in `words[v+1 .. a-1]`; ties break
   toward the **last**. None => **no terms**. `kCom` = its multiplicity.
6. **price** = the *modal* value among the number words in `words[a+1 ..]`; ties
   break toward the **first**. None => **no terms**. `kPrice` = its multiplicity.
7. `qty` and `price` are in `0..99` by construction. `qty == 0` => **no terms**.

The modal rule is the whole robustness mechanic: `SELL 5 5 5 ORE ORE AT 12 12 12`
survives one garble per field by majority vote, and costs 26 characters of airtime
against the 20 of `SELL 5 ORE AT 12`.

### Interference and delivery

`interference[t]` is one public value per turn in `[0.05, 0.95]`, a cosine swell of
period `max(6, turns div 2)` with a random phase, plus 0.35 on a **burst** turn,
all scaled by `noiseScale` and clamped. **The base curve for every turn of the
episode is published from turn 0** - a policy can plan to talk in the quiet. **The
bursts are not**: they are the surprise.

Effective noise is `n = interference[t] * chanFactor`, with `chanFactor = 1.0` on
the radio and **0.6 on a private line**. Per word, drawing `r` uniform in `[0,1)`:

1. `r < 0.45*n` -> **DROP**: the word vanishes.
2. `r < 0.85*n` -> **SWAP**: the word is replaced by a uniform draw from its
   neighbour set; if that set is empty the word drops instead.
3. otherwise -> clean.

Then, on a burst turn, a **static burst** blanks a contiguous run of 2-4 words at
the same positions for **every** delivery in that turn - the burst is weather, not
per-listener luck.

Each recipient gets its own independent garbling, and the RNG depends only on
`(seed, turn, from, to)` - so a replay re-derives every mishearing from the said
text alone and nobody can fake a mishear they did not get.

### The neighbour table - the only admissible mishearings

| word | neighbours |
| --- | --- |
| digit string `d`, value `x` | `d & "0"` when `x*10 <= 99`; `d` without its last digit when `len(d) >= 2`; `d` with its **last** digit replaced by `(last +/- 1) mod 10`, when the result is `<= 99` |
| spelled number | a fixed symmetric **matching** - at most one neighbour each: `FIVE<->NINE`, `FIFTY<->FIFTEEN`, `SIXTY<->SIXTEEN`, `SEVENTY<->SEVENTEEN`, `EIGHTY<->EIGHTEEN`, `NINETY<->NINETEEN`, `FORTY<->FOURTEEN`, `THIRTY<->THIRTEEN`, `TWENTY<->TWELVE`, `TEN<->TWO`, `THREE<->SIX`. `ZERO`, `ONE`, `FOUR`, `SEVEN`, `EIGHT` and `ELEVEN` have **no** neighbour and can only drop |
| commodity | `ORE<->OAT`, `TIN<->TAR` (one neighbour each) |
| `SELL`, `BUY`, `AT` | **no neighbours** - they drop, never swap |
| chatter | no neighbours; a swap degenerates to a drop |

So `5` -> `{50, 4, 6}` (three ways to be misheard) but `FIVE` -> `{NINE}` (one):
**spelling a number out narrows its mishearing surface at the cost of four extra
characters of airtime.** Structure words never swap, so a structural garble
*voids* a reading rather than inverting it: you can lose a deal to noise, you
cannot be flipped from seller to buyer.

## Tickets

The words are noisy; the exchange is not. When a seat's *said* text parses, the
exchange opens a ticket with a sequential id, tagged with the offerer's alias, the
channel, the turn it opened and the turn it expires. **The ticket id, the offerer
and the channel are delivered reliably.** Only the terms are what you heard.

- A ticket opened on turn `t` may be confirmed on turns `t+1` and `t+2`. It cannot
  be confirmed on turn `t` - decisions are simultaneous. It expires at the open of
  turn `t+3`.
- A **radio** ticket may be confirmed by any seat except the offerer. A **line**
  ticket only by the addressed seat.
- If two seats confirm the same ticket in one turn they resolve in seat index
  order; the first admissible confirm settles it and every later confirm that turn
  voids as `already-settled`.
- If the said text does not parse, no ticket exists - even if some listener's
  garbled version happens to parse. Listeners always know the real ticket ids, so
  this never bites an honest seat.

## Confirming - binding as heard, with the redundancy shield

A confirm names a ticket and asserts `side`, `qty`, `commodity`, `price`. **Those
asserted fields are what the exchange enforces**, not what the offerer said.

> For each of `qty`, `commodity`, `price`: the asserted value is admissible if it
> **equals** the said value. Otherwise it is admissible **only if** the said field
> was transmitted **once** (`k == 1`) **and** the asserted value is the value of a
> member of the neighbour set of that single said word. If the offerer said the
> field **twice or more** with the same value (`k >= 2`), only the exact said value
> is admissible.

`side` is never a near-neighbour of anything, so an asserted `side` must equal the
said `side`.

**Worked examples.**

- Offerer says `SELL 5 ORE AT 12` (`kQty = kCom = kPrice = 1`). A confirm of
  `SELL 50 ORE AT 1` is **admissible**: `50` is a neighbour of `5` and `1` is a
  neighbour of `12`. The deal settles on the confirmed terms - the offerer sells up
  to 50 units at 1 credit.
- Offerer says `SELL 5 5 ORE ORE AT 12 12` (`k = 2, 2, 2`). The same confirm
  **voids**, reason `inadmissible`. One repeat kills strategic mishearing on that
  field, and it costs airtime.
- Offerer says `SELL FIVE ORE AT 12`. A confirm of `qty = 9` is admissible
  (`FIVE <-> NINE`); `qty = 50` is not. Spelling narrows the surface.
- The shield also converts *honest* mishearings into **voids** rather than bad
  settlements: if the offerer repeated and the listener genuinely misheard the
  majority, the confirm voids and a turn is burned.

## The turn, in order

0. **Deadline check.** Play stops between turns at 60% of the episode timeout;
   the episode settles with `reason = "deadline"`, scored on the turns played.
1. **Open.** Expire stale tickets, publish `price[t]` and `interference[t]`.
2. **Observe.** One observation per seat, from the state at open.
3. **Decide.** All non-scripted seats' LLM calls go out as ONE parallel batch.
4. **Validate -> retry once -> scripted `quoter` fallback.** An *inadmissible*
   confirm is a perfectly legal move whose outcome is a `void`; it is never
   retried and never falls back.
5. **Transmit, in seat order.** Text is rune-truncated to 160 runes, then to 32
   words; airtime is charged at one rune per character; an over-budget text is cut
   on a rune boundary and flagged `clipped`; an empty meter makes the turn
   `silent`. If the said text parses, the ticket opens.
6. **Confirms, in seat order**, after every transmission of the turn has landed.
   A confirm costs a flat **40** runes and **is never blocked by an empty meter** -
   a seat can always settle. Resolution order: unknown/expired/already-settled/
   own-ticket/not-addressed -> `void`; `side` mismatch -> `void`; any field
   inadmissible -> `void`; coverage (`fill = min(qty, seller units, buyer cash div
   price)`), `fill == 0` -> `void` reason `uncovered`; otherwise **settle** and
   publish both versions on the public tape.
7. **Pace**, then continue or settle.

## Airtime

900 runes for the whole episode, per seat. A transmission costs its length in
runes; a confirm costs a flat 40. Run out and transmissions stop going out, though
you can always still confirm. Repeat-backs, spelled numbers and redundant phrasing
all cost airtime while the market moves.

## Caps

| field | cap |
| --- | --- |
| `text` | 160 runes, then 32 words |
| `notes` | 400 runes |
| `channel` | 16 runes; an unknown value (including this seat's own alias) normalises to `radio` |
| `qty`, `price` | integers `0..99` |

Every truncation is on **rune boundaries** - a string cut mid-UTF-8 renders in a
browser but fails a strict JSON parser, and every string here lands in the replay.

## What each seat sees

| visible to seat `s` | hidden from seat `s` |
| --- | --- |
| turn index and `turns` | every other seat's cash, units, surplus, demand, premium, quota |
| `interference[t]`, its band, and the published base curve for the whole episode | `burst[t]` for any future turn |
| all four prices, current and previous | future price draws |
| its own cash, units, surplus, demand, premium, quota, portfolio, hold, score | every other seat's notes |
| its own airtime remaining | the **said** text of any transmission it did not send |
| its own **heard** traffic | any other listener's heard version |
| open tickets it may confirm: id, offerer alias, channel, open/expiry turn, its own heard text and its own parse | the said terms behind a ticket, and the `k` counts |
| the public tape: every settled deal, both versions, with parties | which seats are scripted |
| its own notes, verbatim | policy display names (aliases only) |

## Endings

`results.reason` has **exactly two legal values**:

| value | when |
| --- | --- |
| `complete` | all `turns` turns were played |
| `deadline` | the clock check fired; scores use the turns played, at the last opened turn's prices |

There is no third value, no forfeit and no early win. A seat that never connects a
player socket is not an ending: after the connect timeout the episode starts anyway
and missing seats receive the game-owned quoter fallback.
