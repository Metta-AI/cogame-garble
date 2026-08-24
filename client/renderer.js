// Garble stage renderer + drivers — the GAME block.
//
// The inherited broadcast chrome (palette, name maps, feed toggle, text
// helpers, relayout) lives in client/chrome_common.js and is read through
// `window.GarbleChrome`; nothing in this file re-declares any of it. What is
// here is Garble-specific: the interference meter, the SAID-over-HEARD
// transmission card, the five cogs with their airtime meters, the price
// ticker, the trade tape, the labelled scrubber beats, and the WebAudio
// static.
//
// One canvas scene fed by three drivers — live /global websocket, live
// /player websocket, and replay (from the game's /replay websocket or the
// static wasm bundle). All state derivation happens server-side / wasm-side;
// this file only draws state objects:
//   {seats:[{name,portfolio,hold,score,cash,units[4],surplus,demand,airtime,
//            silent,deals,misheard,channel,notes} x5],
//    turn, turns, turnsPlayed, interference, burst, band, curve[turns],
//    prices[4], prevPrices[4], commodities[4],
//    wire:[{seat,channel,said,silent,clipped,ticket,
//           heard:[{to,words:[{said,heard,flag}]}]}],
//    tickets:[...], tape:[...],
//    phase:"open|wire|settle|between|done", gameDone, reason}
// The HEARD text is never transported: the sim re-derives it from the seed,
// so the bytes carry the truth and the viewer computes the lie.
(function () {
  "use strict";

  var C = window.GarbleChrome;

  var AIRTIME_BUDGET = 900;
  var COMMODITIES = ["ORE", "OAT", "TIN", "TAR"];
  var BLANK = "\u25A9";
  var MONO = "'rajdhani', ui-monospace, 'SFMono-Regular', Menlo, monospace";
  var FACE = "'rajdhani', system-ui, sans-serif";
  var BURST_MS = 700;
  var SAY_SLIDE_MS = 420;
  var DEAL_HOLD_MS = 1800;

  // ---- geometry -------------------------------------------------------------

  function layoutOf(width, height) {
    var compact = width < 560;
    var hud = Math.max(0.62, Math.min(width / 960, 1.5));
    var meterH = Math.round((compact ? 34 : 46) * hud);
    var tickerH = Math.round((compact ? 22 : 30) * hud);
    var tapeH = Math.round((compact ? 42 : 62) * hud);
    var boardTop = meterH;
    var boardH = Math.max(80, height - meterH - tickerH - tapeH);
    return {
      compact: compact,
      hud: hud,
      width: width,
      height: height,
      meter: { x: 0, y: 0, w: width, h: meterH },
      board: { x: 0, y: boardTop, w: width, h: boardH },
      ticker: { x: 0, y: boardTop + boardH, w: width, h: tickerH },
      tape: { x: 0, y: boardTop + boardH + tickerH, w: width, h: tapeH }
    };
  }

  function cardRect(layout) {
    var b = layout.board;
    if (layout.compact) {
      return { x: 6, y: b.y + 4, w: b.w - 12, h: Math.round(b.h * 0.58) };
    }
    var cw = b.w * 0.50;
    var ch = b.h * 0.46;
    return { x: b.x + (b.w - cw) / 2, y: b.y + (b.h - ch) / 2, w: cw, h: ch };
  }

  // Five cogs ring the card at broadcast width; below 560 px they collapse
  // to one row of portraits under it.
  function cogSpots(layout, size) {
    var b = layout.board;
    var spots = [];
    var index;
    if (layout.compact) {
      var card = cardRect(layout);
      var rowY = card.y + card.h + size * 0.55;
      var step = b.w / 5;
      for (index = 0; index < 5; index++) {
        spots.push({ x: step * (index + 0.5), y: rowY });
      }
      return spots;
    }
    var cx = b.x + b.w / 2;
    var cy = b.y + b.h / 2;
    var rx = b.w * 0.40;
    var ry = b.h * 0.40;
    for (index = 0; index < 5; index++) {
      var angle = -Math.PI / 2 + index * Math.PI * 2 / 5;
      spots.push({ x: cx + Math.cos(angle) * rx,
        y: cy + Math.sin(angle) * ry });
    }
    return spots;
  }

  // ---- the interference meter ----------------------------------------------

  function drawMeter(ctx, rect, view, layout) {
    var hud = layout.hud;
    var curve = view.curve || [];
    var turns = view.turns || curve.length || 1;
    var live = typeof view.interference === "number" ? view.interference : 0;
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.55)";
    ctx.fillRect(rect.x, rect.y, rect.w, rect.h);

    var labelW = Math.round((layout.compact ? 64 : 96) * hud);
    var plot = { x: 8, y: rect.y + 5 * hud, w: rect.w - labelW - 16,
      h: rect.h - 10 * hud };

    if (curve.length > 1 && plot.w > 40) {
      if (!layout.compact) {
        // The published base curve, as a paper sparkline over every turn.
        ctx.beginPath();
        for (var i = 0; i < curve.length; i++) {
          var px = plot.x + plot.w * (i / Math.max(curve.length - 1, 1));
          var py = plot.y + plot.h * (1 - curve[i]);
          if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py);
        }
        ctx.strokeStyle = "rgba(242, 232, 216, 0.45)";
        ctx.lineWidth = 1.5;
        ctx.stroke();
      }
      // The live turn as a filled amber column. Below 560 px the sparkline
      // drops away and this column plus the band word ARE the meter.
      var turn = typeof view.turn === "number" && view.turn >= 0 ?
        view.turn : 0;
      var colX = plot.x + plot.w * (turn / Math.max(curve.length - 1, 1));
      var colW = Math.max(3, plot.w / Math.max(turns, 1) * 0.6);
      ctx.fillStyle = C.rgba(C.AMBER, 0.8);
      ctx.fillRect(colX - colW / 2, plot.y + plot.h * (1 - live), colW,
        plot.h * live);
    }

    ctx.textAlign = "right";
    ctx.textBaseline = "middle";
    ctx.font = "700 " + Math.round(15 * hud) + "px " + FACE;
    ctx.fillStyle = live >= 0.75 ? C.COLOR_HEX.red : C.AMBER;
    ctx.fillText(Math.round(live * 100) + "%", rect.w - 10,
      rect.y + rect.h * 0.38);
    ctx.font = "600 " + Math.round(10 * hud) + "px " + FACE;
    ctx.fillStyle = C.PAPER;
    ctx.fillText(view.band || "", rect.w - 10, rect.y + rect.h * 0.74);

    if (view.burst) {
      ctx.textAlign = "left";
      ctx.font = "700 " + Math.round(11 * hud) + "px " + FACE;
      ctx.fillStyle = C.AMBER;
      ctx.fillText("STATIC BURST", plot.x + 2, rect.y + rect.h * 0.28);
    }
    ctx.restore();
  }

  // A seeded scanline wash over the whole stage on a burst turn.
  function drawBurstWash(ctx, layout, view, age) {
    if (!view.burst || age === null || age > BURST_MS) return;
    var alpha = 0.16 * (1 - age / BURST_MS);
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.fillStyle = C.PAPER;
    var step = Math.max(3, Math.round(4 * layout.hud));
    for (var y = (Math.floor(age / 60) % step); y < layout.height;
        y += step * 2) {
      ctx.fillRect(0, y, layout.width, 1);
    }
    ctx.restore();
  }

  // ---- the transmission card ----------------------------------------------

  function featuredWire(view) {
    var wire = view.wire || [];
    if (!wire.length) return null;
    var seat = view.effects && view.effects.saySeat;
    for (var i = wire.length - 1; i >= 0; i--) {
      if (wire[i].seat === seat) return wire[i];
    }
    return wire[wire.length - 1];
  }

  // Which HEARD lines to show. Wide: all of them. Compact: the two that
  // differ most from what was said, so the drama survives the crop.
  function heardLines(entry, compact) {
    var lines = (entry.heard || []).slice();
    if (!compact || lines.length <= 2) return lines;
    lines.sort(function (a, b) {
      return damageOf(b.words) - damageOf(a.words);
    });
    return lines.slice(0, 2);
  }

  function damageOf(words) {
    var damage = 0;
    (words || []).forEach(function (word) {
      if (word.flag !== "ok") damage += 1;
    });
    return damage;
  }

  function drawWordRow(ctx, words, x, y, maxWidth, size, inkColor, ghost) {
    // One word per cell: a clean word in ink, a dropped or blanked word as a
    // red blank mark, a swapped word in red under a red rule with the said
    // word ghosted above it.
    ctx.save();
    ctx.font = "600 " + Math.round(size) + "px " + MONO;
    ctx.textAlign = "left";
    ctx.textBaseline = "alphabetic";
    var gap = size * 0.55;
    var cells = words.map(function (word) {
      var shown = word.heard === undefined ? word.said :
        (word.heard || BLANK);
      return { word: word, shown: shown,
        w: ctx.measureText(shown).width };
    });
    var total = 0;
    cells.forEach(function (cell) { total += cell.w + gap; });
    var scale = total > maxWidth && total > 0 ? maxWidth / total : 1;
    if (scale < 1) {
      size = Math.max(7, size * scale);
      ctx.font = "600 " + Math.round(size) + "px " + MONO;
      gap = size * 0.55;
      cells.forEach(function (cell) {
        cell.w = ctx.measureText(cell.shown).width;
      });
    }
    var cursor = x;
    cells.forEach(function (cell) {
      var flag = cell.word.flag;
      if (flag === "drop" || flag === "static") {
        ctx.fillStyle = C.COLOR_HEX.red;
        ctx.fillText(BLANK, cursor, y);
      } else if (flag === "swap") {
        if (ghost) {
          ctx.save();
          ctx.font = "600 " + Math.round(size * 0.6) + "px " + MONO;
          ctx.fillStyle = C.rgba(C.PAPER, 0.45);
          ctx.fillText(cell.word.said, cursor, y - size * 0.85);
          ctx.restore();
        }
        ctx.fillStyle = C.COLOR_HEX.red;
        ctx.fillText(cell.shown, cursor, y);
        ctx.fillRect(cursor, y + size * 0.16, cell.w, Math.max(1, size * 0.08));
      } else {
        ctx.fillStyle = inkColor;
        ctx.fillText(cell.shown, cursor, y);
      }
      cursor += cell.w + gap;
    });
    ctx.restore();
    return size;
  }

  function drawCard(ctx, rect, view, layout, nameMap) {
    var hud = layout.hud;
    var entry = featuredWire(view);
    ctx.save();
    ctx.shadowColor = "rgba(0,0,0,0.55)";
    ctx.shadowBlur = 8 * hud;
    ctx.fillStyle = C.PAPER;
    C.roundRect(ctx, rect.x, rect.y, rect.w, rect.h, 6 * hud);
    ctx.fill();
    ctx.shadowColor = "transparent";
    ctx.strokeStyle = C.CARD_EDGE;
    ctx.lineWidth = 1;
    ctx.stroke();

    var pad = 10 * hud;
    var slide = 1;
    if (view.effects && typeof view.effects.sayAt === "number") {
      slide = Math.min(1, (view.now - view.effects.sayAt) / SAY_SLIDE_MS);
    }

    if (!entry) {
      ctx.fillStyle = C.GHOST;
      ctx.font = "600 " + Math.round(12 * hud) + "px " + FACE;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText("THE BAND IS QUIET", rect.x + rect.w / 2,
        rect.y + rect.h / 2);
      ctx.restore();
      return;
    }

    var speaker = C.seatColor(entry.seat);
    var head = (nameMap ? nameMap.seat(entry.seat) : ("Seat " + entry.seat)) +
      (entry.channel === -1 ? "  \u25b8 RADIO" :
        "  \u25b8 LINE \u2192 " + (nameMap ? nameMap.seat(entry.channel) :
          entry.channel));
    ctx.textAlign = "left";
    ctx.textBaseline = "alphabetic";
    ctx.font = "700 " + Math.round(10 * hud) + "px " + FACE;
    ctx.fillStyle = C.COLOR_HEX[speaker];
    ctx.fillText(C.ellipsize(ctx, head.toUpperCase(), rect.w - pad * 2),
      rect.x + pad, rect.y + pad + 8 * hud);
    if (entry.ticket > 0) {
      ctx.textAlign = "right";
      ctx.fillStyle = C.INK;
      ctx.fillText("TICKET #" + entry.ticket, rect.x + rect.w - pad,
        rect.y + pad + 8 * hud);
      ctx.textAlign = "left";
    }

    var saidWords = (entry.said || "").split(/\s+/).filter(function (word) {
      return word.length > 0;
    }).map(function (word) { return { said: word, heard: word, flag: "ok" }; });
    var y = rect.y + pad + 26 * hud;
    var bodySize = Math.round((layout.compact ? 13 : 16) * hud);
    ctx.globalAlpha = Math.max(0.25, slide);
    if (entry.silent) {
      ctx.font = "700 " + Math.round(bodySize) + "px " + FACE;
      ctx.fillStyle = C.GHOST;
      ctx.fillText("SILENT \u2014 NO AIRTIME LEFT", rect.x + pad, y);
    } else if (!saidWords.length) {
      ctx.font = "700 " + Math.round(bodySize) + "px " + FACE;
      ctx.fillStyle = C.GHOST;
      ctx.fillText("(said nothing)", rect.x + pad, y);
    } else {
      drawWordRow(ctx, saidWords, rect.x + pad, y, rect.w - pad * 2,
        bodySize, C.COLOR_HEX[speaker], false);
    }
    ctx.globalAlpha = 1;

    ctx.font = "600 " + Math.round(8 * hud) + "px " + FACE;
    ctx.fillStyle = C.GHOST;
    ctx.fillText("SAID", rect.x + pad, rect.y + pad + 16 * hud);

    var lines = heardLines(entry, layout.compact);
    var rowH = (bodySize + 12 * hud);
    var startY = y + rowH * 0.9;
    var available = rect.y + rect.h - pad - startY;
    var rows = Math.max(1, Math.min(lines.length,
      Math.floor(available / rowH)));
    for (var i = 0; i < rows; i++) {
      var line = lines[i];
      var rowY = startY + rowH * (i + 0.75);
      var listener = C.seatColor(line.to);
      ctx.font = "700 " + Math.round(9 * hud) + "px " + FACE;
      ctx.fillStyle = C.COLOR_HEX[listener];
      var label = (nameMap ? nameMap.seat(line.to) : ("Seat " + line.to));
      var labelW = Math.min(rect.w * 0.26,
        ctx.measureText(label).width + 8 * hud);
      ctx.fillText(C.ellipsize(ctx, label, labelW), rect.x + pad, rowY);
      drawWordRow(ctx, line.words, rect.x + pad + labelW + 6 * hud, rowY,
        rect.w - pad * 2 - labelW - 6 * hud,
        Math.round(bodySize * 0.86), C.INK, !layout.compact);
    }
    if (rows < lines.length) {
      ctx.font = "600 " + Math.round(8 * hud) + "px " + FACE;
      ctx.fillStyle = C.GHOST;
      ctx.fillText("+" + (lines.length - rows) + " more listeners",
        rect.x + pad, rect.y + rect.h - pad * 0.4);
    }
    ctx.restore();
  }

  // ---- the cogs ------------------------------------------------------------

  function drawAirtime(ctx, x, y, w, h, left) {
    var share = Math.max(0, Math.min(1, left / AIRTIME_BUDGET));
    ctx.save();
    ctx.fillStyle = "rgba(242, 232, 216, 0.18)";
    ctx.fillRect(x, y, w, h);
    ctx.fillStyle = share > 0.15 ? C.AMBER : C.COLOR_HEX.red;
    ctx.fillRect(x, y, w * share, h);
    ctx.restore();
  }

  function drawTag(ctx, x, y, text, accent, hud) {
    ctx.save();
    ctx.font = "700 " + Math.round(9 * hud) + "px " + FACE;
    var label = text.toUpperCase();
    var pad = 4 * hud;
    var bw = ctx.measureText(label).width + pad * 2;
    var bh = 13 * hud;
    ctx.fillStyle = "rgba(242, 232, 216, 0.95)";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 1.5;
    C.roundRect(ctx, x - bw / 2, y - bh / 2, bw, bh, 3 * hud);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = C.INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label, x, y + 0.5);
    ctx.restore();
  }

  function drawCog(ctx, images, seat, index, spot, size, layout, opts,
      nameMap) {
    var hud = layout.hud;
    var color = C.seatColor(index);
    var sprite = images["cog_" + color + "_front.png"];
    ctx.save();
    if (sprite && sprite.width) {
      ctx.drawImage(sprite, spot.x - size / 2, spot.y - size / 2, size, size);
    } else {
      ctx.fillStyle = C.COLOR_HEX[color];
      ctx.fillRect(spot.x - size / 3, spot.y - size / 3, size / 1.5,
        size / 1.5);
    }
    ctx.restore();

    if (opts.pending) {
      ctx.save();
      ctx.strokeStyle = C.AMBER;
      ctx.lineWidth = 2;
      ctx.setLineDash([5, 4]);
      ctx.beginPath();
      ctx.arc(spot.x, spot.y, size * 0.6, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    var tag = opts.leads ? "LEADS" : opts.tag;
    if (tag) {
      drawTag(ctx, spot.x, spot.y - size * 0.56, tag,
        opts.leads ? C.AMBER : C.COLOR_HEX[color], hud);
    }

    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "alphabetic";
    ctx.font = "600 " + Math.round(12 * hud) + "px " + FACE;
    ctx.fillStyle = C.PAPER;
    ctx.shadowColor = "rgba(0,0,0,0.8)";
    ctx.shadowBlur = 4;
    var name = nameMap ? nameMap.seat(index) : (seat.name || "");
    ctx.fillText(C.ellipsize(ctx, C.clampName(name), size * 1.9), spot.x,
      spot.y + size * 0.56 + 11 * hud);
    ctx.font = "700 " + Math.round(12 * hud) + "px " + FACE;
    ctx.fillStyle = C.AMBER;
    ctx.fillText((seat.portfolio || 0) + " cr  " +
      (seat.score || 0).toFixed(2) + "\u00d7", spot.x,
      spot.y + size * 0.56 + 24 * hud);
    ctx.restore();

    var barW = size * 1.3;
    drawAirtime(ctx, spot.x - barW / 2, spot.y + size * 0.56 + 29 * hud,
      barW, Math.max(2, 4 * hud), seat.airtime || 0);
  }

  function drawCogs(ctx, images, view, layout, nameMap) {
    var seats = view.seats || [];
    var size = Math.round((layout.compact ?
      Math.min(layout.board.w / 6.4, layout.board.h * 0.30) :
      Math.min(layout.board.w / 11, layout.board.h * 0.34)));
    size = Math.max(26, size);
    var spots = cogSpots(layout, size);
    var best = -Infinity;
    seats.forEach(function (seat) {
      if ((seat.score || 0) > best) best = seat.score || 0;
    });
    var level = seats.every(function (seat) {
      return (seat.score || 0) === best;
    });
    seats.forEach(function (seat, index) {
      var spot = spots[index];
      if (!spot) return;
      var said = (view.wire || []).some(function (entry) {
        return entry.seat === index;
      });
      var tag = "";
      if (seat.silent) tag = "SILENT";
      else if (said) {
        tag = seat.channel === -1 ? "RADIO" :
          "LINE \u2192 " + (nameMap ? nameMap.seat(seat.channel) :
            seat.channel);
      }
      drawCog(ctx, images, seat, index, spot, size, layout, {
        pending: !said && !view.done && view.phase === "wire",
        leads: view.done && !level && (seat.score || 0) === best,
        tag: tag
      }, nameMap);
    });
    return { spots: spots, size: size };
  }

  // ---- the price ticker ----------------------------------------------------

  function drawTicker(ctx, rect, view, layout) {
    var hud = layout.hud;
    var prices = view.prices || [];
    var previous = view.prevPrices || [];
    var names = view.commodities || COMMODITIES;
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.5)";
    ctx.fillRect(rect.x, rect.y, rect.w, rect.h);
    var step = rect.w / Math.max(prices.length, 1);
    ctx.textBaseline = "middle";
    for (var i = 0; i < prices.length; i++) {
      var x = step * (i + 0.5);
      var delta = prices[i] - (previous[i] === undefined ? prices[i] :
        previous[i]);
      ctx.textAlign = "center";
      ctx.font = "700 " + Math.round(11 * hud) + "px " + FACE;
      ctx.fillStyle = C.PAPER;
      var mark = delta > 0 ? " \u25b2" : delta < 0 ? " \u25bc" : " =";
      ctx.fillText(names[i] + " " + prices[i], x - 6 * hud,
        rect.y + rect.h / 2);
      ctx.fillStyle = delta > 0 ? C.COLOR_HEX.green :
        delta < 0 ? C.COLOR_HEX.red : C.GHOST;
      ctx.textAlign = "left";
      ctx.fillText(mark, x + step * 0.28, rect.y + rect.h / 2);
    }
    ctx.restore();
  }

  // ---- the tape -----------------------------------------------------------

  function drawTape(ctx, rect, view, layout, nameMap) {
    var hud = layout.hud;
    var tape = (view.tape || []).slice();
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.62)";
    ctx.fillRect(rect.x, rect.y, rect.w, rect.h);
    ctx.font = "600 " + Math.round(8 * hud) + "px " + FACE;
    ctx.fillStyle = C.GHOST;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText("TAPE", 8, rect.y + 3 * hud);
    var show = layout.compact ? 2 : 3;
    var recent = tape.slice(Math.max(0, tape.length - show));
    var rowH = (rect.h - 12 * hud) / show;
    var names = view.commodities || COMMODITIES;
    recent.forEach(function (deal, i) {
      var y = rect.y + 10 * hud + rowH * i;
      var seller = nameMap ? nameMap.seat(deal.seller) : deal.seller;
      var buyer = nameMap ? nameMap.seat(deal.buyer) : deal.buyer;
      ctx.font = "600 " + Math.round(11 * hud) + "px " + FACE;
      ctx.fillStyle = deal.misheard ? C.COLOR_HEX.red : C.PAPER;
      var line = "#" + deal.ticket + "  " + C.clampName(seller) + " sold " +
        deal.fill + " " + names[deal.commodity] + " to " +
        C.clampName(buyer) + " at " + deal.price +
        (deal.partial ? "  (partial " + deal.fill + "/" + deal.qty + ")" : "");
      ctx.fillText(C.ellipsize(ctx, line, rect.w * (deal.misheard ?
        0.62 : 0.96) - 16), 8, y);
      if (deal.misheard) {
        var said = "said " + deal.saidQty + " " + names[deal.saidCommodity] +
          " at " + deal.saidPrice;
        ctx.font = "600 " + Math.round(9 * hud) + "px " + FACE;
        ctx.fillStyle = C.GHOST;
        var saidX = rect.w * 0.64;
        ctx.fillText(said, saidX, y + 1 * hud);
        var width = ctx.measureText(said).width;
        ctx.fillRect(saidX, y + 6 * hud, width, 1);
        ctx.font = "700 " + Math.round(9 * hud) + "px " + FACE;
        ctx.fillStyle = C.COLOR_HEX.red;
        ctx.fillText("MISHEARD", saidX + width + 8 * hud, y + 1 * hud);
      }
    });
    if (!recent.length) {
      ctx.font = "600 " + Math.round(10 * hud) + "px " + FACE;
      ctx.fillStyle = C.GHOST;
      ctx.fillText("no deals settled yet", 8, rect.y + rect.h * 0.42);
    }
    ctx.restore();
  }

  // ---- the scene ----------------------------------------------------------

  function sweepLightpool(view, geometry, layout) {
    var pool = document.getElementById("lightpool");
    if (!pool) return;
    if (!view.done || !geometry || !geometry.spots.length) {
      pool.style.background = "";
      return;
    }
    var seats = view.seats || [];
    var best = 0;
    var leader = 0;
    seats.forEach(function (seat, index) {
      if ((seat.score || 0) > best) { best = seat.score || 0; leader = index; }
    });
    var spot = geometry.spots[leader];
    if (!spot) return;
    var px = Math.round(spot.x / Math.max(layout.width, 1) * 100);
    var py = Math.round((spot.y + layout.meter.h * 0) /
      Math.max(layout.height, 1) * 100);
    pool.style.background = "radial-gradient(38% 34% at " + px + "% " + py +
      "%, rgba(232,163,61,0.16) 0%, rgba(12, 8, 5, 0.42) 100%)";
  }

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var layout = layoutOf(w, h);
    var nameMap = view.nameMap;

    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.5)";
    ctx.fillRect(0, 0, w, h);

    drawMeter(ctx, layout.meter, view, layout);
    drawCard(ctx, cardRect(layout), view, layout, nameMap);
    var geometry = drawCogs(ctx, images, view, layout, nameMap);
    drawTicker(ctx, layout.ticker, view, layout);
    drawTape(ctx, layout.tape, view, layout, nameMap);
    var burstAge = view.effects && typeof view.effects.burstAt === "number" ?
      view.now - view.effects.burstAt : null;
    drawBurstWash(ctx, layout, view, burstAge);
    sweepLightpool(view, geometry, layout);
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["cog_red_front.png", "cog_blue_front.png",
      "cog_green_front.png", "cog_yellow_front.png", "cog_violet_front.png",
      "arena_floor.png"];
    C.loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  // ---- animation bookkeeping ---------------------------------------------

  // Babel's makeEffects is per-pair and game-specific, so this is a fork,
  // not chrome: it turns a monotonically-growing event list into transient
  // view effects — which seat's transmission is on the card, when a burst
  // turn opened, and when the last deal stamped.
  function makeGarbleEffects() {
    var seen = 0;
    var sayAt = null;
    var saySeat = -1;
    var burstAt = null;
    var dealAt = null;
    var dealTicket = -1;
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only the
      // newest event gets to animate.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "turn") {
            sayAt = null;
            saySeat = -1;
            burstAt = event.burst && animate ? now : null;
          } else if (event.kind === "say") {
            saySeat = event.seat;
            sayAt = animate ? now : null;
          } else if (event.kind === "deal") {
            dealTicket = event.ticket;
            dealAt = animate ? now : null;
          }
        }
      },
      reset: function () {
        seen = 0; sayAt = null; saySeat = -1; burstAt = null;
        dealAt = null; dealTicket = -1;
      },
      view: function () {
        return { effects: { sayAt: sayAt, saySeat: saySeat,
          burstAt: burstAt, dealAt: dealAt, dealTicket: dealTicket } };
      }
    };
  }

  // ---- readouts ----------------------------------------------------------

  function leaderOf(state) {
    var seats = state.seats || [];
    var best = -Infinity;
    var index = -1;
    seats.forEach(function (seat, i) {
      if ((seat.score || 0) > best) { best = seat.score || 0; index = i; }
    });
    return { index: index, score: best };
  }

  function matchHeader(state, nameMap) {
    if (!state) return "";
    if (state.gameDone || state.done) {
      var leader = leaderOf(state);
      var who = leader.index < 0 ? "" :
        C.clampName(nameMap ? nameMap.seat(leader.index) :
          (state.seats[leader.index] || {}).name || "").toUpperCase();
      return "FINAL \u2014 " + who + " " + leader.score.toFixed(2) + "\u00d7" +
        (state.reason === "deadline" ? " \u00b7 DEADLINE" : "");
    }
    var turn = typeof state.turn === "number" && state.turn >= 0 ?
      state.turn : 0;
    var parts = ["TURN " + (turn + 1) + " / " + (state.turns || 0)];
    parts.push((state.band || "") + " " +
      Math.round((state.interference || 0) * 100) + "%");
    if (state.burst) parts.push("STATIC BURST");
    var landed = (state.wire || []).length;
    if (state.phase === "wire" && landed < (state.seats || []).length) {
      parts.push("WAITING ON " + ((state.seats || []).length - landed));
    }
    return parts.join(" \u00b7 ");
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var landed = {};
    (state.wire || []).forEach(function (entry) { landed[entry.seat] = true; });
    var html = "";
    state.seats.forEach(function (seat, index) {
      var pips = "";
      var filled = Math.round(Math.max(0, Math.min(1,
        (seat.airtime || 0) / AIRTIME_BUDGET)) * 12);
      for (var p = 0; p < 12; p++) {
        pips += '<span class="plate-pip' + (p < filled ? "" : " spent") +
          '"></span>';
      }
      var pending = !landed[index] && !state.gameDone &&
        state.phase === "wire";
      html += '<div class="plate ' + C.seatColor(index) + '">' +
        '<span class="plate-name">' +
        C.escapeHtml(C.clampName(nameMap ? nameMap.seat(index) : seat.name)) +
        "</span>" +
        (pending ? '<span class="plate-it">\u25b6</span>' : "") +
        '<span class="plate-score">' + (seat.portfolio || 0) + "</span>" +
        '<span class="plate-label">credits</span>' +
        '<span class="plate-ratio">' + (seat.score || 0).toFixed(2) +
        "\u00d7</span>" +
        '<span class="plate-pips">' + pips + "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function updateLegend(state) {
    var legend = document.getElementById("legend");
    if (!legend || !state) return;
    var prices = state.prices || [];
    var previous = state.prevPrices || [];
    var names = state.commodities || COMMODITIES;
    var html = "";
    for (var i = 0; i < prices.length; i++) {
      var delta = prices[i] - (previous[i] === undefined ? prices[i] :
        previous[i]);
      var cls = delta > 0 ? "up" : delta < 0 ? "down" : "flat";
      var mark = delta > 0 ? "\u25b2" : delta < 0 ? "\u25bc" : "=";
      html += '<span class="legend-chip"><span class="legend-name">' +
        C.escapeHtml(names[i]) + '</span><span class="legend-price">' +
        prices[i] + '</span><span class="legend-delta ' + cls + '">' +
        mark + "</span></span>";
    }
    if (legend.dataset.html !== html) {
      legend.dataset.html = html;
      legend.innerHTML = html;
    }
  }

  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var portfolio = results.portfolio || [];
    var deals = results.deals || [];
    var misheard = results.misheard || [];
    var airtime = results.airtimeUsed || [];
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) {
      var byScore = (scores[b] || 0) - (scores[a] || 0);
      if (byScore) return byScore;
      return (portfolio[b] || 0) - (portfolio[a] || 0);
    });
    var topIndex = order.length ? order[0] : -1;
    var level = order.every(function (i) {
      return (scores[i] || 0) === (scores[topIndex] || 0);
    });
    var verdictColor = !level && topIndex >= 0 ? C.seatColor(topIndex) : "";
    var verdict = !level && topIndex >= 0 ?
      C.escapeHtml(names[topIndex]).toUpperCase() + " LEADS THE TABLE" :
      "ALL LEVEL";
    var reason = results.reason === "deadline" ?
      "episode deadline: scored on " + (results.turns || 0) + " of " +
      (results.maxTurns || results.turns || 0) + " turns" : "";
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL \u2014 ' + (results.turns || 0) +
      " TURN" + ((results.turns || 0) === 1 ? "" : "S") + "</div>" +
      '<div class="end-verdict ' + verdictColor + '">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + C.escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">score</span>' +
      '<span class="end-head">credits</span>' +
      '<span class="end-head">deals</span>' +
      '<span class="end-head">misheard</span>' +
      '<span class="end-head">airtime used</span>';
    order.forEach(function (i, rank) {
      var leader = !level && i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' + C.seatColor(i) +
        (leader ? " end-row-winner" : "") + '">' +
        C.escapeHtml(names[i]) + "</span>" +
        cell((scores[i] || 0).toFixed(2) + "\u00d7") +
        cell(portfolio[i] || 0) +
        cell(deals[i] || 0) +
        cell(misheard[i] || 0) +
        cell(airtime[i] || 0);
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  // ---- the feed ----------------------------------------------------------

  function termsOf(event) {
    return event.terms || null;
  }

  function sayText(event, nameMap, heard) {
    var name = C.clampName(nameMap.seat(event.seat));
    var where = event.channel === -1 ? "RADIO" :
      "LINE\u2192" + C.clampName(nameMap.seat(event.channel));
    if (event.silent) {
      return name + " \u25b8 " + where + " \u2014 SILENT (no airtime)";
    }
    return name + " \u25b8 " + where + ": \"" + (event.text || "") + "\"" +
      (event.scripted ? " \u00b7" : "");
  }

  function heardText(words) {
    return (words || []).map(function (word) {
      return word.heard && word.heard.length ? word.heard : BLANK;
    }).join(" ");
  }

  function confirmText(event, nameMap) {
    return C.clampName(nameMap.seat(event.seat)) + " confirms #" +
      event.ticket + " \u2014 " + event.side + " " + event.qty + " " +
      COMMODITIES[event.commodity] + " at " + event.price +
      (event.scripted ? " \u00b7" : "");
  }

  function dealText(event, nameMap) {
    var line = "DEAL #" + event.ticket + " \u2014 " +
      C.clampName(nameMap.seat(event.seller)) + " sells " + event.fill + " " +
      COMMODITIES[event.commodity] + " to " +
      C.clampName(nameMap.seat(event.buyer)) + " at " + event.price;
    if (event.misheard) {
      line += " \u00b7 said " + event.saidQty + " " +
        COMMODITIES[event.saidCommodity] + " at " + event.saidPrice +
        " \u00b7 MISHEARD";
    }
    if (event.partial) {
      line += " \u00b7 partial " + event.fill + "/" + event.qty;
    }
    return line;
  }

  var VOID_WHY = {
    "no-ticket": "there is no such open ticket",
    "expired": "the ticket had expired",
    "already-settled": "the ticket was already settled",
    "own-ticket": "it was its own ticket",
    "not-addressed": "the line was not addressed to it",
    "side": "the side did not match",
    "inadmissible": "the confirm was inadmissible (the field was repeated)",
    "uncovered": "nobody could cover the trade"
  };

  function voidText(event, nameMap) {
    return "VOID #" + event.ticket + " \u2014 " +
      C.clampName(nameMap.seat(event.seat)) + "'s confirm failed: " +
      (VOID_WHY[event.reason] || event.reason);
  }

  function pricesText(event, names) {
    var parts = [];
    (event.prices || []).forEach(function (price, i) {
      parts.push((names[i] || COMMODITIES[i]) + " " + price);
    });
    return "PRICES " + parts.join(" \u00b7 ");
  }

  // `heardBySay` maps an event index to that transmission's per-listener
  // garbling, which the wasm/server states carry; the heard text is never
  // in the events themselves.
  function renderFeed(element, events, nameMap, currentIndex, heardBySay) {
    if (!element) return;
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var html = "";
    var lastTurn = null;
    var lastNotes = {};
    var names = COMMODITIES;
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var future = i >= limit;
      if (event.kind === "turn") {
        lastTurn = event.turn;
        html += '<div class="feed-turn-head' +
          (future ? " feed-future" : "") + '">TURN ' + (event.turn + 1) +
          " \u00b7 INTERFERENCE " +
          Math.round((event.interference || 0) * 100) + "% " +
          (event.burst ? "STATIC BURST" : "") + "</div>";
        html += '<div class="feed-line feed-prices' +
          (future ? " feed-future" : "") + '">' +
          C.escapeHtml(pricesText(event, names)) + "</div>";
        continue;
      }
      var line = "";
      var cls = "feed-line feed-" + event.kind + (future ? " feed-future" : "");
      switch (event.kind) {
        case "start":
          line = "The band opens \u2014 five cogs, four commodities, one " +
            "noisy exchange.";
          break;
        case "say":
          line = sayText(event, nameMap, null);
          cls += " seat" + (event.seat % 6);
          break;
        case "confirm":
          line = confirmText(event, nameMap);
          break;
        case "deal":
          line = dealText(event, nameMap);
          if (event.misheard) cls += " misheard";
          break;
        case "void":
          line = voidText(event, nameMap);
          break;
        case "end":
          line = event.text === "deadline" ?
            "Episode deadline \u2014 scored on " + event.turn + " turns." :
            "FINAL \u2014 " + event.turn + " turns played.";
          break;
        default:
          line = JSON.stringify(event);
      }
      html += '<div class="' + cls + '">' + C.escapeHtml(line) + "</div>";
      // A heard line is printed only when it differs from what was said.
      if (event.kind === "say" && heardBySay && heardBySay[i]) {
        heardBySay[i].forEach(function (entry) {
          if (!damageOf(entry.words)) return;
          html += '<div class="feed-line feed-heard' +
            (future ? " feed-future" : "") + '">' +
            C.escapeHtml("    " + C.clampName(nameMap.seat(entry.to)) +
              " hears: \"" + heardText(entry.words) + "\"") + "</div>";
        });
      }
      if (event.kind === "say" && event.notes &&
          event.notes !== lastNotes[event.seat]) {
        lastNotes[event.seat] = event.notes;
        html += '<div class="feed-line feed-notes' +
          (future ? " feed-future" : "") + '">' +
          C.escapeHtml(C.clampName(nameMap.seat(event.seat)) + " notes: " +
            nameMap.text(event.notes)) + "</div>";
      }
    }
    element.innerHTML = html;
    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  // ---- the scrubber ------------------------------------------------------

  // Beats are labelled, clickable buttons — never bare divs. No function in
  // this game block may share a name with a GarbleChrome key, so the marker
  // helper is garbleMarkBeat and the builder is buildGarbleScrub.
  function garbleMarkBeat(container, tick, total, kind, team, label, onSeek) {
    var marker = document.createElement("button");
    marker.type = "button";
    marker.className = "beat-marker " + kind +
      (team !== null && team !== undefined && team >= 0 ?
        " seat" + (team % 6) : "");
    marker.style.left = (total ? (tick / total * 100) : 0) + "%";
    marker.title = label;
    marker.setAttribute("aria-label", label);
    marker.onclick = function (evt) {
      evt.stopPropagation();
      onSeek(tick);
    };
    container.appendChild(marker);
    return marker;
  }

  function beatLabel(event, nameMap) {
    var turn = "Turn " + ((event.turn || 0) + 1);
    switch (event.kind) {
      case "start": return "Table set";
      case "turn": return turn + " opens \u2014 interference " +
        Math.round((event.interference || 0) * 100) + "%" +
        (event.burst ? " with a static burst" : "");
      case "say": return turn + " \u2014 " +
        C.clampName(nameMap.seat(event.seat)) +
        (event.silent ? " is silent (no airtime)" :
          " transmits on " + (event.channel === -1 ? "the radio" : "a line"));
      case "confirm": return turn + " \u2014 " +
        C.clampName(nameMap.seat(event.seat)) + " confirms #" + event.ticket +
        " as " + event.side + " " + event.qty + " " +
        COMMODITIES[event.commodity] + " at " + event.price;
      case "deal": return turn + " \u2014 deal #" + event.ticket + ": " +
        C.clampName(nameMap.seat(event.seller)) + " \u2192 " +
        C.clampName(nameMap.seat(event.buyer)) + ", " + event.fill + " " +
        COMMODITIES[event.commodity] + " at " + event.price +
        (event.misheard ? " \u2014 MISHEARD" : "");
      case "void": return turn + " \u2014 " +
        C.clampName(nameMap.seat(event.seat)) + "'s confirm voided (" +
        event.reason + ")";
      case "end": return "Final \u2014 " + event.turn + " turns, " +
        (event.text || "complete");
      default: return event.kind;
    }
  }

  function beatSeat(event) {
    switch (event.kind) {
      case "say": case "confirm": case "void": return event.seat;
      case "deal": return event.seller;
      default: return -1;
    }
  }

  function buildGarbleScrub(container, events, nameMap, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);

    // One span per turn, as babel does.
    var starts = [];
    var lastTurn = null;
    events.forEach(function (event, i) {
      var turn = event.kind === "start" ? -1 :
        event.kind === "end" ? lastTurn : event.turn;
      if (turn !== lastTurn) {
        starts.push(i);
        lastTurn = turn;
      }
    });
    starts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < starts.length ? starts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
    });

    events.forEach(function (event, i) {
      var kind = event.kind;
      var extra = kind === "turn" && event.burst ? " burst" :
        kind === "say" && event.silent ? " silent" :
        kind === "deal" && event.misheard ? " misheard" : "";
      garbleMarkBeat(container, i + 1, events.length, kind + extra,
        beatSeat(event), beatLabel(event, nameMap), onSeek);
    });

    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) - rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      if (evt.target !== container && evt.target !== track &&
          evt.target !== fill && evt.target !== head) {
        return;                  // a beat button handles its own click
      }
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () { dragging = false; });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  // ---- WebAudio static ---------------------------------------------------

  // Off by default behind one button, constructed only on the first click
  // (the user gesture browser autoplay policy requires), and fully fenced:
  // audio NEVER gates data-replay-loaded and never touches the render loop.
  function makeStatic(button) {
    var ctxAudio = null;
    var gain = null;
    var source = null;
    var on = false;
    var broken = false;

    function label() {
      if (!button) return;
      button.textContent = broken ? "\u266a STATIC N/A" :
        on ? "\u266a STATIC" : "\u266a STATIC";
      button.classList.toggle("on", on && !broken);
      button.classList.toggle("na", broken);
    }

    function build() {
      var Ctor = window.AudioContext || window.webkitAudioContext;
      if (!Ctor) throw new Error("no AudioContext");
      ctxAudio = new Ctor();
      var seconds = 2;
      var buffer = ctxAudio.createBuffer(1, ctxAudio.sampleRate * seconds,
        ctxAudio.sampleRate);
      var data = buffer.getChannelData(0);
      var seed = 12345;
      for (var i = 0; i < data.length; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        data[i] = (seed / 0x3fffffff) - 1;
      }
      source = ctxAudio.createBufferSource();
      source.buffer = buffer;
      source.loop = true;
      var band = ctxAudio.createBiquadFilter();
      band.type = "bandpass";
      band.frequency.value = 1800;
      gain = ctxAudio.createGain();
      gain.gain.value = 0;
      var master = ctxAudio.createGain();
      master.gain.value = 0.2;
      var comp = ctxAudio.createDynamicsCompressor();
      source.connect(band);
      band.connect(gain);
      gain.connect(master);
      master.connect(comp);
      comp.connect(ctxAudio.destination);
      source.start();
    }

    if (button) {
      button.onclick = function () {
        if (broken) return;
        try {
          if (!ctxAudio) build();
          on = !on;
          if (ctxAudio.state === "suspended") ctxAudio.resume();
          if (gain) gain.gain.value = on ? gain.gain.value : 0;
        } catch (error) {
          broken = true;
          on = false;
          if (button) button.disabled = true;
        }
        label();
      };
      label();
    }

    return {
      level: function (interference) {
        if (broken || !on || !gain || !ctxAudio) return;
        try {
          var target = Math.max(0, Math.min(0.18, interference * 0.19));
          gain.gain.value = target;
        } catch (error) {
          broken = true;
          on = false;
          label();
        }
      },
      stop: function () {
        if (broken || !gain) return;
        try { gain.gain.value = 0; } catch (error) { broken = true; }
      }
    };
  }

  // ---- drivers -----------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = C.applyNames(state.seats, nameMap);
    view.nameMap = nameMap;
    view.wire = state.wire || [];
    view.tape = state.tape || [];
    view.tickets = state.tickets || [];
    view.curve = state.curve || [];
    view.prices = state.prices || [];
    view.prevPrices = state.prevPrices || [];
    view.commodities = state.commodities || COMMODITIES;
    view.interference = state.interference || 0;
    view.band = state.band || "";
    view.burst = !!state.burst;
    view.phase = state.phase || "";
    view.turn = state.turn;
    view.turns = state.turns || 0;
    view.turnsPlayed = state.turnsPlayed || 0;
    view.reason = state.reason || "";
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  function seatNames(data) {
    return (data.seats || []).map(function (s) { return s.name; });
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, endscreen, assetBase,
    //           wsPath, staticButton, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      // Player pages get no policyNames (they must not learn who is behind a
      // seat) and a redacted state, so their map degrades to the aliases.
      var nameMap = C.makeNameMap([], null);
      var effects = makeGarbleEffects();
      var noise = makeStatic(options.staticButton ||
        document.getElementById("staticbtn"));
      var heardBySay = {};
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function absorbHeard(data) {
        // The live snapshot carries only the current turn's garbling, so
        // stash it as it arrives and the feed keeps the whole history.
        var events = data.events || [];
        var wire = data.wire || [];
        wire.forEach(function (entry) {
          for (var i = events.length - 1; i >= 0; i--) {
            if (events[i].kind === "say" && events[i].seat === entry.seat &&
                events[i].turn === data.turn) {
              heardBySay[i] = entry.heard || [];
              return;
            }
          }
        });
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = data;
            if (latest) {
              nameMap = C.makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || []);
              absorbHeard(latest);
              renderFeed(options.feed, latest.events || [], nameMap,
                undefined, heardBySay);
              if (options.clock) {
                options.clock.textContent = matchHeader(latest, nameMap);
              }
              updateScorebug(options.scorebug, latest, nameMap);
              updateLegend(latest);
              noise.level(latest.interference || 0);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap);
              noise.stop();
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () { setStatus("live", true); };
      }
      connect();

      (function frame() {
        if (latest) {
          renderer.draw(stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          }));
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  function buildHeardMap(events, states) {
    // states[i + 1] is the frame after events[i], and it carries that
    // transmission's per-listener garbling.
    var map = {};
    if (!states || !states.length) return map;
    for (var i = 0; i < events.length; i++) {
      if (events[i].kind !== "say") continue;
      var frame = states[i + 1];
      if (!frame || !frame.wire) continue;
      for (var w = frame.wire.length - 1; w >= 0; w--) {
        if (frame.wire[w].seat === events[i].seat) {
          map[i] = frame.wire[w].heard || [];
          break;
        }
      }
    }
    return map;
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           endscreen, assetBase, payload, staticButton}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var nameMap = C.makeNameMap(payload.names, payload.policyNames);
    var heardBySay = buildHeardMap(events, states);
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeGarbleEffects();
      var noise = makeStatic(options.staticButton ||
        document.getElementById("staticbtn"));
      var scrub = buildGarbleScrub(options.scrub, events, nameMap,
        function (next) {
          playing = false;
          setIndex(next, true);
        });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], wire: [], tape: [], curve: [], prices: [],
            prevPrices: [], phase: "", turn: -1, turns: 0, turnsPlayed: 0 };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) effects.reset();
        effects.absorb(events.slice(0, index), jumped);
        renderFeed(options.feed, events, nameMap, index, heardBySay);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        var state = currentState();
        if (options.clock) {
          options.clock.textContent = matchHeader(state, nameMap);
        }
        updateScorebug(options.scorebug, state, nameMap);
        updateLegend(state);
        noise.level(state.interference || 0);
        // Every seek dismisses the endcard: updateEndscreen's first
        // statement toggles the class off whenever `show` is false.
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on the event the viewer is currently looking at, so the
        // transmission gets read and the settlement gets seen.
        var shown = index > 0 ? events[index - 1] : null;
        var kind = shown ? shown.kind : "";
        var stepMs = kind === "turn" ? 1200 :
          kind === "say" ? 900 :
          kind === "confirm" ? 700 :
          kind === "deal" ? 1600 :
          kind === "void" ? 900 :
          kind === "end" ? 1500 : 600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "\u275a\u275a" : "\u25b6";
          options.playButton.classList.toggle("on", running);
        }
        renderer.draw(stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        }));
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.GarbleRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: C.bindFeedToggle
  };
})();
