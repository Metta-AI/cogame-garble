## Shared value types for Garble: the runtime config, the event vocabulary,
## and the error every rule violation raises.

import std/[json, strutils]

const
  MinTurns* = 6
  MaxTurns* = 24

type
  GarbleError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    turns*: int           ## turns in the episode (every seat decides every turn)
    noiseScale*: float    ## multiplies the interference curve, 0.0 .. 2.0
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is silent
    sampled*: bool        ## true once the budget cap has been applied
    turnDelayMs*: int
    turnSpacingMs*: int   ## minimum time between opening decisions
    playerConnectTimeoutSeconds*: float
    actionTimeoutSeconds*: int

  Side* = enum
    sdSell = "SELL"
    sdBuy = "BUY"

  EventKind* = enum
    evStart = "start"
    evTurn = "turn"
    evSay = "say"
    evConfirm = "confirm"
    evDeal = "deal"
    evVoid = "void"
    evEnd = "end"

  GameEvent* = object
    ## One flat record per recorded fact. `say` and `confirm` are the
    ## decisions; `turn`, `deal`, `void` and `end` are derived facts that
    ## are recorded anyway so `replayMatch` can re-derive and check them.
    kind*: EventKind
    turn*: int            ## 0-based turn; end: turns played; start: -1
    seat*: int            ## say/confirm/void: the actor; -1 otherwise
    channel*: int         ## say: -1 radio, else the addressed seat
    text*: string         ## say: the said text; end: the reason
    cost*: int            ## say: airtime charged
    airtimeLeft*: int     ## say: the seat's meter after the charge
    silent*: bool         ## say: no airtime left, nothing transmitted
    clipped*: bool        ## say: the text was cut to fit the meter
    ticket*: int          ## say: the ticket opened, or -1; confirm/deal/void
    hasTerms*: bool       ## say: the said text parsed
    side*: Side           ## say terms / confirm / deal
    qty*: int
    commodity*: int
    price*: int
    kQty*: int            ## say: multiplicity of the said qty
    kCom*: int
    kPrice*: int
    scripted*: bool       ## say/confirm: decided by a scripted baseline
    notes*: string        ## say: the seat's notes after this reply
    interference*: float  ## turn
    burst*: bool          ## turn
    prices*: seq[int]     ## turn / end: the four commodity prices
    portfolios*: seq[int] ## turn / end: portfolio value per seat
    airtime*: seq[int]    ## turn: airtime left per seat
    scores*: seq[float]   ## end
    seller*: int          ## deal
    buyer*: int           ## deal
    fill*: int            ## deal: units actually moved
    saidQty*: int         ## deal: the offerer's spoken terms
    saidCommodity*: int
    saidPrice*: int
    partial*: bool        ## deal: fill < qty
    misheard*: bool       ## deal: confirmed terms differ from spoken terms
    cash*: int            ## deal: credits moved
    reason*: string       ## void: why the confirm did not settle

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    turns: 12,
    noiseScale: 1.0,
    episodeTimeoutSeconds: 1200,
    turnDelayMs: 400,
    turnSpacingMs: 12_000,
    playerConnectTimeoutSeconds: 180,
    actionTimeoutSeconds: 25
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(GarbleError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getInt()
  if node.hasKey("turns"):
    config.turns = node["turns"].getInt()
  if node.hasKey("noiseScale"):
    config.noiseScale = node["noiseScale"].getFloat()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("turnDelayMs"):
    config.turnDelayMs = node["turnDelayMs"].getInt()
  if node.hasKey("turnSpacingMs"):
    config.turnSpacingMs = node["turnSpacingMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("actionTimeoutSeconds"):
    config.actionTimeoutSeconds = node["actionTimeoutSeconds"].getInt()
  if config.turns < MinTurns:
    raise newException(GarbleError, "turns must be at least " & $MinTurns)
  if config.noiseScale < 0.0 or config.noiseScale > 2.0:
    raise newException(GarbleError, "noiseScale must be 0.0 .. 2.0")
