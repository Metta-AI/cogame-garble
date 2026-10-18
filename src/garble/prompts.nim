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
  PromptBankVersion* = "garble-rules-v1"

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

proc ordinarySystemPrompt*(selection: PromptSelection): string =
  selection.ordinaryIntroduction() & "\n\n" & PlayerRules
