## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "garble-rules-v2"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc nativeIntroduction*(selection: PromptSelection, alias: string): string =
  case selection.selectedVariant
  of pvCanonical: "You are " & alias & ", a cog trading commodities with four other cogs over a NOISY exchange."
  of pvPlain: "You play the cog " & alias & ". Trade commodities with four other cogs over a NOISY exchange."
  of pvNumbered: "1. Your cog: " & alias & ". 2. Activity: trading commodities. 3. Counterparties: four other cogs. 4. Exchange: NOISY."
  of pvQuestions: "Who are you? The cog " & alias & ". What do you do? Trade commodities with four other cogs over a NOISY exchange."
  of pvReordered: "Over a NOISY exchange, you trade commodities with four other cogs as " & alias & "."
  of pvHeldoutBriefing: "Take the role of cog " & alias & " to trade commodities with four other cogs through a NOISY exchange."
  of pvHeldoutReference: "Identity: cog " & alias & ". Activity: commodity trading. Other participants: four cogs. Exchange condition: NOISY."
  of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")

proc ordinaryIntroduction*(selection: PromptSelection): string =
  case selection.selectedVariant
  of pvCanonical: "Play Garble. Submit one complete decision as JSON."
  of pvPlain: "You are playing Garble. Return a complete decision in JSON."
  of pvNumbered: "1. Play Garble. 2. Submit a complete decision. 3. Use JSON."
  of pvQuestions: "What game are you playing? Garble. What should you submit? One complete decision as JSON."
  of pvReordered: "Submit one complete decision as JSON for the game Garble."
  of pvHeldoutBriefing: "Your task is to play Garble and provide a complete JSON decision."
  of pvHeldoutReference: "Game: Garble. Required response: one complete decision in JSON."
  of pvMixed: raise newException(ValueError, "mixed selection must resolve to a training wording")

const PlayerRules = staticRead("../../docs/rules.md")

proc confirmationRules*(selection: PromptSelection): string =
  case selection.selectedVariant
  of pvPlain:
    "A confirmation names a ticket and gives side, quantity, commodity, and price. " &
    "The exchange enforces those confirmed terms, not the offerer's spoken terms. " &
    "For quantity, commodity, and price, the exact spoken value is always admissible. " &
    "A different value is admissible only when that field was spoken once and the " &
    "value belongs to that word's published near-neighbours. Repeating a field at " &
    "least twice binds its exact value. You may confirm a value you did not hear, " &
    "but an inadmissible field voids the confirmation and wastes the turn."
  of pvNumbered:
    "1. Confirm a ticket using side, quantity, commodity, and price.\n" &
    "2. Settlement uses your confirmed terms, not the spoken offer.\n" &
    "3. For each quantity, commodity, or price, the exact spoken value is admissible.\n" &
    "4. A different value is admissible only for a field spoken once, and only " &
    "if it is a published near-neighbour of that word.\n" &
    "5. Two or more repetitions bind the field to its exact value.\n" &
    "6. You may assert a value you never heard; an inadmissible assertion voids " &
    "the confirmation and spends the turn."
  of pvQuestions:
    "What does a confirmation contain? Ticket, side, quantity, commodity, and price. " &
    "Which terms settle? The confirmed ones, not the spoken ones. What quantity, " &
    "commodity, or price is admissible? The spoken value, or a published near-neighbour " &
    "of the spoken word if that field appeared exactly once. What if it was repeated " &
    "twice or more? Only the exact value binds. Must you have heard the asserted value? " &
    "No, but it must be admissible. Otherwise the confirmation voids and the turn is wasted."
  of pvReordered:
    "Redundancy binds: repeating a quantity, commodity, or price twice or more " &
    "permits only its exact spoken value. A field spoken once also permits values " &
    "from that word's published near-neighbours. You may assert such a value without " &
    "having heard it; an inadmissible assertion voids the confirmation and wastes " &
    "the turn. Confirm by naming the ticket, side, quantity, commodity, and price. " &
    "The exchange settles on these confirmed terms, not the offerer's spoken terms."
  of pvHeldoutBriefing:
    "Treat confirmation as a binding assertion of ticket, side, quantity, commodity, " &
    "and price: settlement follows your assertion rather than the spoken offer. " &
    "Each quantity, commodity, and price may equal its spoken value. It may differ " &
    "only if the field occurred once and the asserted value is a published " &
    "near-neighbour of that word. Two or more repetitions lock the exact value. " &
    "You need not have heard the asserted value, but asserting an inadmissible " &
    "one voids the confirmation and wastes your turn."
  of pvHeldoutReference:
    "Confirmation fields: ticket, side, quantity, commodity, price. Settlement " &
    "basis: confirmed terms, not spoken terms. Quantity/commodity/price admissibility: " &
    "exact spoken value, plus published word-neighbour values only when spoken once. " &
    "Repetition count >= 2: exact value only. Heard-value requirement: none. " &
    "Inadmissible assertion: confirmation void, turn wasted."
  of pvCanonical, pvMixed:
    raise newException(ValueError, "canonical rules retain their original text; mixed must resolve")

proc ordinarySystemPrompt*(selection: PromptSelection): string =
  result = selection.ordinaryIntroduction() & "\n\n"
  if selection.selectedVariant == pvCanonical:
    return result & PlayerRules
  let sections = PlayerRules.split("\n## ")
  doAssert sections.len == 10, "update section order when the rule document changes"
  # Keep scanner, neighbours, budgets, and examples exact; vary the binding rule
  # and the order of complete sections without dropping game facts.
  var order: seq[int]
  for index in 1 ..< sections.len: order.add(index)
  if selection.selectedVariant in {pvReordered, pvHeldoutReference}:
    order = @[4, 3, 1, 2, 5, 6, 7, 8, 9]
  result.add(sections[0])
  for index in order:
    result.add("\n## ")
    let section = sections[index]
    if section.startsWith("Confirming -"):
      result.add("Confirming - binding as heard, with the redundancy shield\n\n")
      result.add(selection.confirmationRules() & "\n\n")
      let sideRule = section.find("`side` is never")
      doAssert sideRule >= 0
      result.add(section[sideRule .. ^1])
    else:
      result.add(section)
