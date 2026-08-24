## The Garble channel, in one auditable pure module: the lexicon, the term
## scanner, the near-neighbour table, the noise model, and the redundancy
## shield. No IO, no networking, no LLM — the server, the tests and the wasm
## replay viewer all drive this same code, so every garble in a replay can be
## re-derived from `(seed, turn, from, to)` and audited.

import std/[options, random, strutils, unicode], types

export options, types

const
  Commodities* = ["ORE", "OAT", "TIN", "TAR"]
  Verbs* = ["SELL", "BUY"]
  Pivot* = "AT"
  ## A transmission is scanned as at most this many words.
  MaxWords* = 32
  ## Quantities and prices live in 0..99; nothing outside it is a number word.
  MaxValue* = 99
  ## What a dropped or static-blanked word looks like on screen.
  Blank* = "\u25A9"

  SpelledNumbers* = [
    ("ZERO", 0), ("ONE", 1), ("TWO", 2), ("THREE", 3), ("FOUR", 4),
    ("FIVE", 5), ("SIX", 6), ("SEVEN", 7), ("EIGHT", 8), ("NINE", 9),
    ("TEN", 10), ("ELEVEN", 11), ("TWELVE", 12), ("THIRTEEN", 13),
    ("FOURTEEN", 14), ("FIFTEEN", 15), ("SIXTEEN", 16), ("SEVENTEEN", 17),
    ("EIGHTEEN", 18), ("NINETEEN", 19), ("TWENTY", 20), ("THIRTY", 30),
    ("FORTY", 40), ("FIFTY", 50), ("SIXTY", 60), ("SEVENTY", 70),
    ("EIGHTY", 80), ("NINETY", 90)
  ]

  ## A MATCHING, not a graph: every spelled number appears in at most one
  ## pair, so a spelled number has at most ONE way to be misheard. That is
  ## what makes spelling a number out a defence worth four extra characters.
  ## ZERO, ONE, FOUR, SEVEN, EIGHT and ELEVEN appear in no pair at all and
  ## can only drop.
  SpelledNeighbors* = [
    ("FIVE", "NINE"), ("FIFTY", "FIFTEEN"), ("SIXTY", "SIXTEEN"),
    ("SEVENTY", "SEVENTEEN"), ("EIGHTY", "EIGHTEEN"),
    ("NINETY", "NINETEEN"), ("FORTY", "FOURTEEN"),
    ("THIRTY", "THIRTEEN"), ("TWENTY", "TWELVE"), ("TEN", "TWO"),
    ("THREE", "SIX")
  ]

  ## The commodity names are chosen so a swap yields a VALID but WRONG
  ## commodity.
  CommodityNeighbors* = [("ORE", "OAT"), ("TIN", "TAR")]

type
  Terms* = object
    ## What the exchange reads out of a line of words.
    side*: Side
    qty*: int
    commodity*: int
    price*: int
    kQty*: int      ## multiplicity of the modal qty value before AT
    kCom*: int      ## multiplicity of the modal commodity word before AT
    kPrice*: int    ## multiplicity of the modal price value after AT
    qtyWord*: string   ## the last word carrying the modal qty value
    comWord*: string
    priceWord*: string

  WordFlag* = enum
    wfOk = "ok"
    wfDrop = "drop"
    wfSwap = "swap"
    wfStatic = "static"

  HeardWord* = object
    said*: string
    heard*: string   ## "" when the word did not arrive
    flag*: WordFlag

# ---- Lexicon ----------------------------------------------------------------

proc isDigitWord*(word: string): bool =
  ## A digit string of one or two digits, i.e. a spoken 0..99.
  if word.len < 1 or word.len > 2:
    return false
  for ch in word:
    if ch notin {'0' .. '9'}:
      return false
  true

proc wordValue*(word: string): int =
  ## 0..99 for a number word, -1 for anything else.
  if isDigitWord(word):
    return parseInt(word)
  for pair in SpelledNumbers:
    if pair[0] == word:
      return pair[1]
  -1

proc isNumberWord*(word: string): bool =
  wordValue(word) >= 0

proc commodityIndex*(word: string): int =
  for index, name in Commodities:
    if name == word:
      return index
  -1

proc normaliseWords*(text: string): seq[string] =
  ## Uppercase ASCII, every other ASCII character becomes a separator, and
  ## non-ASCII runes are left alone (they simply are not lexicon words).
  ## Split on whitespace, capped at MaxWords.
  var buffer = ""
  for rune in runes(text):
    if int32(rune) < 128:
      let ch = char(int32(rune))
      if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'}:
        buffer.add(toUpperAscii(ch))
      else:
        buffer.add(' ')
    else:
      buffer.add($rune)
  for word in strutils.splitWhitespace(buffer):
    if result.len >= MaxWords:
      break
    result.add(word)

# ---- Near neighbours --------------------------------------------------------

proc neighborsOf*(word: string): seq[string] =
  ## Every admissible mishearing of one word, in a deterministic order
  ## (digit rules first, then the spelled and commodity tables) so a swap
  ## draw is reproducible from the seed alone. Structure words (SELL, BUY,
  ## AT) and chatter have none: a structural garble VOIDS a reading rather
  ## than inverting it.
  if isDigitWord(word):
    let value = parseInt(word)
    if word.len < 2 and value * 10 <= MaxValue:
      result.add(word & "0")
    if word.len >= 2:
      result.add(word[0 ..< word.high])
    let last = ord(word[word.high]) - ord('0')
    for delta in [1, -1]:
      var candidate = word
      candidate[candidate.high] = chr(ord('0') + ((last + delta + 10) mod 10))
      if candidate != word and parseInt(candidate) <= MaxValue and
          candidate notin result:
        result.add(candidate)
    return
  for pair in SpelledNeighbors:
    if pair[0] == word:
      return @[pair[1]]
    if pair[1] == word:
      return @[pair[0]]
  for pair in CommodityNeighbors:
    if pair[0] == word:
      return @[pair[1]]
    if pair[1] == word:
      return @[pair[0]]
  @[]

proc valueNeighbors*(word: string): seq[int] =
  ## The 0..99 values a number word could be misheard as.
  for candidate in neighborsOf(word):
    let value = wordValue(candidate)
    if value >= 0 and value notin result:
      result.add(value)

proc commodityNeighbors*(word: string): seq[int] =
  for candidate in neighborsOf(word):
    let index = commodityIndex(candidate)
    if index >= 0 and index notin result:
      result.add(index)

# ---- The scanner ------------------------------------------------------------

proc modalValue(words: seq[string], first, last: int, lastWins: bool):
    tuple[value, count: int, word: string] =
  ## The most frequently repeated number VALUE in words[first..last].
  ## `lastWins` breaks ties toward the last such word (qty) rather than the
  ## first (price).
  result = (-1, 0, "")
  for index in max(first, 0) .. min(last, words.high):
    let value = wordValue(words[index])
    if value < 0:
      continue
    var count = 0
    for other in max(first, 0) .. min(last, words.high):
      if wordValue(words[other]) == value:
        inc count
    if count > result.count or (lastWins and count == result.count):
      result = (value, count, words[index])

proc modalCommodity(words: seq[string], first, last: int):
    tuple[value, count: int, word: string] =
  ## The most frequently repeated commodity word, ties toward the last.
  result = (-1, 0, "")
  for index in max(first, 0) .. min(last, words.high):
    let value = commodityIndex(words[index])
    if value < 0:
      continue
    var count = 0
    for other in max(first, 0) .. min(last, words.high):
      if commodityIndex(words[other]) == value:
        inc count
    if count >= result.count:
      result = (value, count, words[index])

proc scanTerms*(words: seq[string]): Option[Terms] =
  ## The exchange's reading of a line, run identically on the SAID text and
  ## on every HEARD text. Seven numbered steps; anything missing is chatter,
  ## not an error.
  var verb = -1
  for index, word in words:
    if word == Verbs[0] or word == Verbs[1]:
      verb = index
      break
  if verb < 0:
    return none(Terms)
  var pivot = -1
  for index in verb + 1 .. words.high:
    if words[index] == Pivot:
      pivot = index
      break
  if pivot < 0:
    return none(Terms)
  var terms = Terms(side: if words[verb] == Verbs[0]: sdSell else: sdBuy)
  let qty = modalValue(words, verb + 1, pivot - 1, lastWins = true)
  if qty.count == 0:
    return none(Terms)
  let commodity = modalCommodity(words, verb + 1, pivot - 1)
  if commodity.count == 0:
    return none(Terms)
  let price = modalValue(words, pivot + 1, words.high, lastWins = false)
  if price.count == 0:
    return none(Terms)
  if qty.value == 0:
    return none(Terms)
  terms.qty = qty.value
  terms.kQty = qty.count
  terms.qtyWord = qty.word
  terms.commodity = commodity.value
  terms.kCom = commodity.count
  terms.comWord = commodity.word
  terms.price = price.value
  terms.kPrice = price.count
  terms.priceWord = price.word
  some(terms)

# ---- The noisy channel ------------------------------------------------------

proc deliveryRng*(seed, turn, fromSeat, toSeat: int): Rand =
  ## Per (transmission, listener). Nothing about it depends on earlier
  ## transmissions, so a replay re-derives every garble from the said text
  ## and the seed alone.
  initRand(int64(seed) * 1_000_003 + turn * 997 + fromSeat * 31 +
    toSeat * 7 + 1)

proc garble*(words: seq[string], seed, turn, fromSeat, toSeat: int,
    noise: float, burst: bool, burstFrac: float, burstLen: int):
    seq[HeardWord] =
  ## One delivery. 45% of the effective noise drops a word, the next 40%
  ## swaps it for a near neighbour (dropping it when it has none), and a
  ## static burst then blanks one contiguous run at the SAME positions for
  ## every recipient of that turn — the burst is weather, not per-listener
  ## luck.
  var rng = deliveryRng(seed, turn, fromSeat, toSeat)
  for word in words:
    var heard = HeardWord(said: word, heard: word, flag: wfOk)
    let roll = rng.rand(1.0)
    if roll < 0.45 * noise:
      heard.heard = ""
      heard.flag = wfDrop
    elif roll < 0.85 * noise:
      let candidates = neighborsOf(word)
      if candidates.len == 0:
        heard.heard = ""
        heard.flag = wfDrop
      else:
        heard.heard = candidates[rng.rand(candidates.high)]
        heard.flag = wfSwap
    result.add(heard)
  if burst and result.len > 0 and burstLen > 0:
    let start = max(0, int(burstFrac * float(result.len)))
    for index in start ..< min(result.len, start + burstLen):
      result[index].heard = ""
      result[index].flag = wfStatic

proc heardWords*(words: seq[HeardWord]): seq[string] =
  ## Only what arrived — what the exchange scans for this listener.
  for word in words:
    if word.heard.len > 0:
      result.add(word.heard)

proc heardText*(words: seq[HeardWord]): string =
  ## The heard line as a spectator reads it, with a blank mark where a word
  ## dropped or was blanked by static.
  var parts: seq[string]
  for word in words:
    parts.add(if word.heard.len > 0: word.heard else: Blank)
  parts.join(" ")

# ---- The redundancy shield --------------------------------------------------

proc admissible*(said, asserted: Terms): bool =
  ## A confirm binds AS ASSERTED, but only a value the channel could have
  ## produced is admissible: it must equal what was said, or — when the
  ## field was said exactly once — be a near neighbour of that single word.
  ## One repeat kills strategic mishearing on that field, and it costs
  ## airtime. `side` is never a near neighbour of anything.
  if said.side != asserted.side:
    return false
  if asserted.qty != said.qty:
    if said.kQty != 1 or asserted.qty notin valueNeighbors(said.qtyWord):
      return false
  if asserted.commodity != said.commodity:
    if said.kCom != 1 or
        asserted.commodity notin commodityNeighbors(said.comWord):
      return false
  if asserted.price != said.price:
    if said.kPrice != 1 or asserted.price notin valueNeighbors(said.priceWord):
      return false
  true
