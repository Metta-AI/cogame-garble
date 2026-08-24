## Garble player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default Garble strategy), then idles until the final frame. All of the
## actual decision making happens inside the game server, which sends this
## seat's prompt to Claude once per turn, in one parallel batch with the
## other seats.
##
## PLAYER_SCRIPTED=quoter|shark registers the seat as a built-in baseline
## instead: the server plays it deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <garble-image> --name my-garble \
##     --run /bin/garble-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
Trade toward your contract commodity and out of your surplus. Price your
offers between the market price and the market price plus your premium —
anything inside that band is profitable. Watch the interference meter before
you speak: when it is under 25% be terse and fast, and when it is over 50%
repeat every number and every commodity once, because a repeated field cannot
be confirmed against you. Spell numbers out when they are round; a spelled
number has one near-neighbour and a digit has three. Confirm the reading you
actually heard when the counterparty repeated, and when they did not, weigh
whether the favourable neighbour is worth the ticket. Keep a note of who
repeats and who is terse — the terse ones can be taken and will take you.
Airtime is the budget that decides how much protocol you can afford: do not
spend it on chatter.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let baselineRaw = getEnv("PLAYER_SCRIPTED").strip().toLowerAscii()
  let scripted = baselineRaw in ["1", "true", "yes", "quoter", "shark"]
  let baseline = if baselineRaw == "shark": "shark" else: "quoter"

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted,
      "baseline": baseline}

  echo "garble player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "garble player: prompt delivered (", prompt.len, " chars",
    (if scripted: ", scripted " & baseline else: ""), ")"

  ## whisky's receiveMessage RAISES on a close frame, and the game's quit(0)
  ## can outrun the flushed final frame. A dead socket is a normal end of
  ## an episode, not a player failure: log it and exit 0.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "garble player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "garble player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr()
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "garble player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "garble player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "garble player: socket ended (", error.msg, "), exiting"
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
