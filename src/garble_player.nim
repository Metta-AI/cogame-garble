## Garble prompt and scripted policies over the ordinary decision socket.
## The game supplies a private view each turn; this process writes the action.

import
  std/[json, options, os, strutils],
  whisky,
  garble/[llm, prompts, training_capture]

const DefaultPrompt = """
Trade toward your contract commodity and out of your surplus. Price your
offers between the market price and the market price plus your premium.
Watch interference: repeat fields above 50% to protect offers. Confirm the
reading you heard when the counterparty repeated; a terse offer can be
confirmed at a favourable neighbour. Preserve airtime for later turns.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let kind = parseScriptKind(getEnv("PLAYER_SCRIPTED"))
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let client =
    if kind == skNone:
      newLlmClient(parseInt(getEnv("PLAYER_MAX_OUTPUT_TOKENS", "900")),
        getEnv("PLAYER_MODEL", "claude-sonnet-5"))
    else: nil
  var slot = -1
  let socket = newWebSocket(url)
  echo "garble player: connected, policy ",
    (if kind == skNone: "prompt" else: $kind)

  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          slot = payload["slot"].getInt()
          echo "garble player: seated at slot ", slot
        of "turn":
          let view = payload["view"]
          var source = "player"
          let capture = if payload{"private_capture"}.getStr() == CaptureProtocol:
            PrivateCapture() else: nil
          var action: JsonNode
          try:
            action =
              if kind != skNone:
                source = "scripted"
                scriptedDecisionFromView(view, kind)
              elif client.disabled:
                source = "fallback"
                scriptedDecisionFromView(view, skQuoter)
              else:
                choosePromptAction(client, view, prompt,
                  max(1, payload["timeout_ms"].getInt() div 1000 - 1), slot,
                  promptSelection(payload["prompt_config"]),
                  capture)
          except CatchableError:
            if capture != nil and capture.evidence != nil and capture.evidence.kind != JNull:
              try:
                socket.send($ %*{"type": "private_attempt", "turn": payload["turn"],
                  "source": source, "private_attempt": capture.evidence})
              except CatchableError: discard
            raise
          socket.send($decisionFrame(payload["turn"], source, action, capture))
        of "final":
          echo "garble player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "garble player: decision frame failed: ", error.msg
  except CatchableError as error:
    echo "garble player: socket ended (", error.msg, ")"
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
