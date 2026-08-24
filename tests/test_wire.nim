## The channel in isolation: normalisation, the lexicon, the scanner, the
## near-neighbour table, the noise model and the redundancy shield. Every
## one of these is a rule a policy is told about in its system prompt, so a
## drift here is a drift in the published game.

import std/[algorithm, math, random, sets, strutils, unittest]
import garble/wire

proc sorted(values: seq[string]): seq[string] =
  result = values
  result.sort()

suite "normalisation":
  test "punctuation separates, case folds, and the word cap holds":
    check normaliseWords("sell 5, ore at 12!") ==
      @["SELL", "5", "ORE", "AT", "12"]
    check normaliseWords("SELL-5/ORE@AT#12") ==
      @["SELL", "5", "ORE", "AT", "12"]
    check normaliseWords("").len == 0
    check normaliseWords("   ").len == 0
    var long: seq[string]
    for index in 0 ..< 40:
      long.add("W" & $index)
    check normaliseWords(long.join(" ")).len == MaxWords

  test "a multi-byte rune survives as one unrecognised word":
    let words = normaliseWords("SELL \u97F3 ORE AT 12")
    check words == @["SELL", "\u97F3", "ORE", "AT", "12"]
    check not isNumberWord("\u97F3")
    check commodityIndex("\u97F3") == -1
    check neighborsOf("\u97F3").len == 0

suite "lexicon":
  test "wordValue maps every digit string 0..99":
    for value in 0 .. 99:
      check wordValue($value) == value
      check isNumberWord($value)

  test "wordValue maps every spelled word in the table":
    for pair in SpelledNumbers:
      check wordValue(pair[0]) == pair[1]
      check isNumberWord(pair[0])

  test "non-numbers are not number words":
    for word in ["HUNDRED", "TWENTY-FIVE", "ORE", "SELL", "AT", "100", "5X"]:
      check not isNumberWord(word)
    ## post-normalisation TWENTY-FIVE is two words worth 20 and 5, never 25
    let words = normaliseWords("TWENTY-FIVE")
    check words == @["TWENTY", "FIVE"]
    check wordValue(words[0]) == 20
    check wordValue(words[1]) == 5

  test "commodityIndex is the fixed order":
    check commodityIndex("ORE") == 0
    check commodityIndex("OAT") == 1
    check commodityIndex("TIN") == 2
    check commodityIndex("TAR") == 3
    check commodityIndex("COAL") == -1

suite "scanner":
  test "a terse offer parses with k = 1 everywhere":
    let terms = scanTerms(normaliseWords("SELL 5 ORE AT 12"))
    check terms.isSome
    let value = terms.get()
    check value.side == sdSell
    check value.qty == 5
    check value.commodity == 0
    check value.price == 12
    check (value.kQty, value.kCom, value.kPrice) == (1, 1, 1)

  test "a repeated offer parses with k = 2 everywhere":
    let terms = scanTerms(normaliseWords("SELL 5 5 ORE ORE AT 12 12"))
    check terms.isSome
    let value = terms.get()
    check (value.qty, value.commodity, value.price) == (5, 0, 12)
    check (value.kQty, value.kCom, value.kPrice) == (2, 2, 2)

  test "the modal rule survives one garble per field":
    let terms = scanTerms(normaliseWords("SELL 5 5 9 ORE AT 12"))
    check terms.isSome
    check terms.get().qty == 5
    check terms.get().kQty == 2

  test "a qty tie breaks toward the last word, a price tie toward the first":
    let qtyTie = scanTerms(normaliseWords("SELL 5 9 ORE AT 12"))
    check qtyTie.isSome
    check qtyTie.get().qty == 9
    check qtyTie.get().kQty == 1
    let priceTie = scanTerms(normaliseWords("SELL 5 ORE AT 12 30"))
    check priceTie.isSome
    check priceTie.get().price == 12
    check priceTie.get().kPrice == 1

  test "a commodity tie breaks toward the last":
    let terms = scanTerms(normaliseWords("SELL 5 ORE TIN AT 12"))
    check terms.isSome
    check terms.get().commodity == 2

  test "a missing field is chatter, not an error":
    for line in ["5 ORE AT 12", "SELL 5 ORE 12", "SELL ORE AT 12",
        "SELL 5 AT 12", "SELL 5 ORE AT", "SELL 0 ORE AT 12",
        "nothing to see here", ""]:
      check scanTerms(normaliseWords(line)).isNone

  test "a second verb after the first is ignored":
    let terms = scanTerms(normaliseWords("SELL 5 ORE BUY 7 AT 12"))
    check terms.isSome
    check terms.get().side == sdSell
    ## 5 and 7 tie in the qty region, so the LAST wins
    check terms.get().qty == 7

  test "AT must come after the verb":
    check scanTerms(normaliseWords("AT 12 SELL 5 ORE")).isNone

suite "neighbours":
  test "a digit string has three ways to be misheard":
    check sorted(neighborsOf("5")) == sorted(@["50", "4", "6"])
    check sorted(neighborsOf("50")) == sorted(@["5", "51", "59"])
    check sorted(neighborsOf("99")) == sorted(@["9", "90", "98"])

  test "a spelled number has at most one":
    check neighborsOf("FIVE") == @["NINE"]
    check neighborsOf("NINE") == @["FIVE"]
    for word in ["ZERO", "ONE", "FOUR", "SEVEN", "EIGHT", "ELEVEN"]:
      check neighborsOf(word).len == 0

  test "commodities pair up and structure words never swap":
    check neighborsOf("ORE") == @["OAT"]
    check neighborsOf("OAT") == @["ORE"]
    check neighborsOf("TIN") == @["TAR"]
    check neighborsOf("TAR") == @["TIN"]
    for word in ["SELL", "BUY", "AT", "HELLO", "\u97F3"]:
      check neighborsOf(word).len == 0

  test "the spelled table is symmetric and a matching":
    for pair in SpelledNumbers:
      let word = pair[0]
      let neighbours = neighborsOf(word)
      check neighbours.len <= 1
      for other in neighbours:
        check neighborsOf(other) == @[word]
    for pair in Commodities:
      let neighbours = neighborsOf(pair)
      check neighbours.len == 1
      check neighborsOf(neighbours[0]) == @[pair]

  test "every digit neighbour is itself a number word in range":
    for value in 0 .. 99:
      for candidate in neighborsOf($value):
        check isNumberWord(candidate)
        check wordValue(candidate) in 0 .. MaxValue

suite "garbling":
  test "silence on the wire is verbatim":
    let words = normaliseWords("SELL 5 5 ORE ORE AT 12 12")
    let heard = garble(words, 11, 0, 0, 1, 0.0, false, 0.0, 0)
    for word in heard:
      check word.flag == wfOk
      check word.heard == word.said
    check heardText(heard) == words.join(" ")

  test "the drop and swap rates match the model":
    var words: seq[string]
    for index in 0 ..< 20:
      words.add("5")
    var drops = 0
    var swaps = 0
    var total = 0
    let noise = 0.95
    for delivery in 0 ..< 500:
      let heard = garble(words, delivery, 0, 0, 1, noise, false, 0.0, 0)
      for word in heard:
        inc total
        if word.flag == wfDrop: inc drops
        elif word.flag == wfSwap: inc swaps
    check abs(drops / total - 0.45 * noise) < 0.05
    check abs(swaps / total - 0.40 * noise) < 0.05

  test "every swap lands inside the said word's neighbour set":
    var words = normaliseWords("SELL BUY AT 5 50 FIVE ORE TIN CHATTER")
    for delivery in 0 ..< 200:
      for word in garble(words, delivery, 1, 2, 3, 0.9, false, 0.0, 0):
        if word.flag == wfSwap:
          check word.heard in neighborsOf(word.said)
        if neighborsOf(word.said).len == 0:
          check word.flag != wfSwap

  test "a burst blanks the same contiguous run for every recipient":
    let words = normaliseWords("SELL 5 5 ORE ORE AT 12 12 PLEASE")
    var runs: seq[seq[int]]
    for listener in 0 ..< 4:
      var blanked: seq[int]
      let heard = garble(words, 7, 2, 4, listener, 0.0, true, 0.4, 3)
      for index, word in heard:
        if word.flag == wfStatic:
          blanked.add(index)
      runs.add(blanked)
    for run in runs:
      check run.len == 3
      check run == runs[0]
      check run[2] - run[0] == 2

  test "the same delivery reproduces, a different listener does not":
    let words = normaliseWords("SELL 5 5 ORE ORE AT 12 12")
    for seed in 0 ..< 20:
      let a = garble(words, seed, 3, 0, 1, 0.6, false, 0.0, 0)
      let b = garble(words, seed, 3, 0, 1, 0.6, false, 0.0, 0)
      check a == b
    var differed = false
    for seed in 0 ..< 20:
      if garble(words, seed, 3, 0, 1, 0.6, false, 0.0, 0) !=
          garble(words, seed, 3, 0, 2, 0.6, false, 0.0, 0):
        differed = true
    check differed

  test "a dropped word shows as a blank and never reaches the scanner":
    let words = normaliseWords("SELL 5 ORE AT 12")
    let heard = garble(words, 4, 0, 0, 1, 0.99, false, 0.0, 0)
    check Blank in heardText(heard)
    for word in heardWords(heard):
      check word.len > 0

suite "the redundancy shield":
  proc said(line: string): Terms =
    scanTerms(normaliseWords(line)).get()

  proc asserted(side: Side, qty, commodity, price: int): Terms =
    Terms(side: side, qty: qty, commodity: commodity, price: price,
      kQty: 1, kCom: 1, kPrice: 1)

  test "the exact reading is always admissible":
    let terms = said("SELL 5 ORE AT 12")
    check admissible(terms, asserted(sdSell, 5, 0, 12))
    let repeated = said("SELL 5 5 ORE ORE AT 12 12")
    check admissible(repeated, asserted(sdSell, 5, 0, 12))

  test "with k = 1 a near neighbour binds, a stranger does not":
    let terms = said("SELL 5 ORE AT 12")
    check admissible(terms, asserted(sdSell, 50, 0, 12))
    check not admissible(terms, asserted(sdSell, 93, 0, 12))
    check admissible(terms, asserted(sdSell, 5, 1, 12))
    check not admissible(terms, asserted(sdSell, 5, 2, 12))
    check admissible(terms, asserted(sdSell, 5, 0, 1))

  test "one repeat kills strategic mishearing on that field":
    let terms = said("SELL 5 5 ORE ORE AT 12 12")
    check not admissible(terms, asserted(sdSell, 50, 0, 12))
    check not admissible(terms, asserted(sdSell, 5, 1, 12))
    check not admissible(terms, asserted(sdSell, 5, 0, 1))

  test "a spelled number admits only its single neighbour":
    let terms = said("SELL FIVE ORE AT TWELVE")
    check admissible(terms, asserted(sdSell, 9, 0, 12))
    check not admissible(terms, asserted(sdSell, 50, 0, 12))
    check not admissible(terms, asserted(sdSell, 4, 0, 12))
    check admissible(terms, asserted(sdSell, 5, 0, 20))

  test "side never admits a change":
    let terms = said("SELL 5 ORE AT 12")
    check not admissible(terms, asserted(sdBuy, 5, 0, 12))

  test "admissible is total and never raises":
    var rng = initRand(99)
    let lines = ["SELL 5 ORE AT 12", "BUY TWENTY TIN AT NINE",
      "SELL 50 50 TAR AT 3", "BUY 7 OAT OAT AT 88"]
    for trial in 0 ..< 1000:
      let terms = said(lines[rng.rand(lines.high)])
      let probe = asserted(
        (if rng.rand(1) == 0: sdSell else: sdBuy),
        rng.rand(99), rng.rand(3), rng.rand(99))
      discard admissible(terms, probe)
