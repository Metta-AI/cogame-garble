// Garble broadcast chrome — inherited from cogame-babel.
//
// Every function below this comment is cogame-babel/client/renderer.js's
// function, character for character, with no edits: the palette constants,
// assetUrl, loadImages, seatColor, ellipsize, hexToRgb, shade, rgba,
// roundRect, wrapLines, escapeHtml, clampName, isBaselineFiller,
// makeNameMap (including its third `glyphs` parameter and its `.glyph`
// accessor, which Garble does not use), applyNames and bindFeedToggle.
// The only non-copied lines are this IIFE wrapper, the
// window.GarbleChrome export at the bottom, and one clearly-marked added
// function, relayout().
//
// Nothing game-specific belongs in here. Babel's makeEffects is per-pair
// and game-specific, so it is NOT chrome: Garble forks it into
// client/renderer.js as makeGarbleEffects instead.
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. Babel
  // seats four cogs: red, blue, green, yellow. The extra colours stay so
  // the chrome's seatN classes keep lining up with the CSS.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var CARD_EDGE = "rgba(42, 31, 22, 0.85)";
  var STRIP = "rgba(242, 232, 216, 0.06)";

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  function seatColor(index) {
    return COLORS[index % COLORS.length];
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  // Colour helpers for the shape rims / highlights.
  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function shade(hex, factor) {
    var c = hexToRgb(hex).map(function (v) {
      return Math.max(0, Math.min(255, Math.round(v * factor)));
    });
    return "rgb(" + c[0] + "," + c[1] + "," + c[2] + ")";
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = text.split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous table names ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  // The map also carries the canonical alphabet so feed lines can spell
  // messages the way the stage does.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames, glyphs) {
    var table = tableNames || [];
    var alphabet = glyphs || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      },
      glyph: function (t) {
        return alphabet[t] !== undefined ? alphabet[t] : "?";
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- ADDED FOR GARBLE (not from the starter) -----------------------------

  // The one added function. Every Garble-added chrome measure derives from
  // --hudscale, never from the raw viewport, and --band is what keeps the
  // endcard out of the transport band. Runs on load, on every resize, and
  // after every bindFeedToggle toggle (which dispatches a resize).
  function relayout() {
    var root = document.documentElement;
    var stage = document.getElementById("stage");
    var topband = document.getElementById("topband");
    var transport = document.getElementById("transport");
    var stageWidth = stage ? stage.getBoundingClientRect().width :
      window.innerWidth;
    var topHeight = topband ? topband.getBoundingClientRect().height : 0;
    var bandHeight = transport ? transport.getBoundingClientRect().height : 0;
    root.style.setProperty("--topband", Math.round(topHeight) + "px");
    root.style.setProperty("--band", Math.round(bandHeight) + "px");
    root.style.setProperty("--hudscale",
      String(Math.max(0.7, Math.min(stageWidth / 960, 1.6))));
  }

  window.addEventListener("load", relayout);
  window.addEventListener("resize", relayout);

  window.GarbleChrome = {
    COLORS: COLORS,
    COLOR_HEX: COLOR_HEX,
    PAPER: PAPER,
    INK: INK,
    AMBER: AMBER,
    GHOST: GHOST,
    CARD_EDGE: CARD_EDGE,
    STRIP: STRIP,
    assetUrl: assetUrl,
    loadImages: loadImages,
    seatColor: seatColor,
    ellipsize: ellipsize,
    hexToRgb: hexToRgb,
    shade: shade,
    rgba: rgba,
    roundRect: roundRect,
    wrapLines: wrapLines,
    escapeHtml: escapeHtml,
    clampName: clampName,
    isBaselineFiller: isBaselineFiller,
    makeNameMap: makeNameMap,
    applyNames: applyNames,
    bindFeedToggle: bindFeedToggle,
    relayout: relayout
  };
})();
