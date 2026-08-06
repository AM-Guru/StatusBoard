/* Status Board — statusboard.am.guru
 *
 * Two jobs: reveal-on-scroll, and a miniature working board that reflows
 * between device sizes the way the real app does. No dependencies, no network.
 */
(function () {
  "use strict";

  var reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  /* ── Reveal on scroll ────────────────────────────────────────────── */
  function initReveal() {
    var items = document.querySelectorAll(".reveal");
    if (reducedMotion.matches || !("IntersectionObserver" in window)) {
      items.forEach(function (el) { el.classList.add("is-visible"); });
      return;
    }
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    items.forEach(function (el) { observer.observe(el); });
  }

  /* ── The demo board ──────────────────────────────────────────────── */

  // `span` is in board columns, mirroring how a real panel occupies the grid.
  // `full` marks the panels the watch layout refuses to shrink (charts, lists).
  var PANELS = [
    { id: "clock",   title: "Time",          kind: "clock",    span: 1, accent: "#f7a23c" },
    { id: "cpu",     title: "Bridge · CPU",  kind: "ring",     span: 1, accent: "#f7a23c" },
    { id: "mem",     title: "Bridge · RAM",  kind: "ring",     span: 1, accent: "#3ecfc0" },
    { id: "uptime",  title: "Uptime",        kind: "number",   span: 1, accent: "#8d68ff" },
    { id: "rps",     title: "Requests / sec", kind: "graph",   span: 2, accent: "#f7a23c", full: true },
    { id: "status",  title: "Services",      kind: "lights",   span: 2, accent: "#3ecfc0", full: true },
    { id: "deploys", title: "Deploys today", kind: "bars",     span: 2, accent: "#3ecfc0", full: true },
    { id: "errors",  title: "Error rate",    kind: "number",   span: 1, accent: "#ff6b6b" },
    { id: "ship",    title: "Ship window",   kind: "countdown", span: 1, accent: "#8d68ff" }
  ];

  var DEVICES = {
    mac:    { cols: 4, tile: 96,  note: "four columns · every panel at full detail" },
    ipad:   { cols: 3, tile: 92,  note: "three columns · panels keep their weight" },
    iphone: { cols: 2, tile: 84,  note: "two columns · wide panels take the full row" },
    tv:     { cols: 4, tile: 120, note: "four columns, larger type for across the room" },
    watch:  { cols: 1, tile: 62,  note: "one column · reflowed, not shrunk" }
  };

  // A four-column Mac board squeezed into a phone truncates every title, so
  // the demo opens on whichever device actually fits the viewport.
  function defaultDevice() {
    var w = window.innerWidth;
    if (w < 560) return "iphone";
    if (w < 860) return "ipad";
    return "mac";
  }

  var state = {
    device: defaultDevice(),
    rps: [42, 48, 45, 61, 58, 72, 66, 80, 74, 88, 96, 91],
    deploys: [3, 5, 2, 8, 6, 9, 4],
    cpu: 0.38,
    mem: 0.61,
    errors: 0.42,
    services: ["up", "up", "up", "up", "down", "up", "up", "idle"],
    uptimeDays: 41
  };

  var grid = document.getElementById("board-grid");
  var caption = document.getElementById("board-caption");
  var frame = document.querySelector(".device-frame");
  var tiles = {};

  function el(tag, cls, text) {
    var node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function spanFor(panel, cols) {
    // On the watch every panel is its own row; elsewhere a panel never spans
    // wider than the board itself.
    if (cols === 1) return 1;
    return Math.min(panel.span, cols);
  }

  function buildTile(panel, cols) {
    var tile = el("div", "tile");
    tile.setAttribute("data-span", String(spanFor(panel, cols)));
    tile.style.setProperty("--accent", panel.accent);

    var head = el("div", "tile-head");
    head.appendChild(el("i", "dot"));
    head.appendChild(el("span", null, panel.title));
    tile.appendChild(head);

    var body;
    switch (panel.kind) {
      case "ring":
        body = el("div", "ring");
        body.innerHTML =
          '<svg width="34" height="34" viewBox="0 0 34 34" aria-hidden="true">' +
          '<circle class="ring-track" cx="17" cy="17" r="14" fill="none" stroke-width="5"/>' +
          '<circle class="ring-fill" cx="17" cy="17" r="14" fill="none" stroke-width="5"' +
          ' stroke-linecap="round" transform="rotate(-90 17 17)"' +
          ' stroke-dasharray="87.96" stroke-dashoffset="87.96"/></svg>';
        body.appendChild(el("div", "tile-value", "—"));
        break;
      case "graph":
        body = el("canvas");
        break;
      case "bars":
        body = el("div", "bars");
        state.deploys.forEach(function () { body.appendChild(el("i")); });
        break;
      case "lights":
        body = el("div");
        body.appendChild(el("div", "tile-value", "—"));
        body.appendChild(el("div", "lights"));
        break;
      default:
        body = el("div", "tile-value", "—");
    }
    tile.appendChild(body);
    return tile;
  }

  function render() {
    var device = DEVICES[state.device];
    grid.style.setProperty("--cols", String(device.cols));
    grid.style.setProperty("--tile-h", device.tile + "px");
    if (frame) frame.setAttribute("data-device", state.device);
    grid.textContent = "";
    tiles = {};

    PANELS.forEach(function (panel) {
      // The watch drops nothing, but its own layout gives every panel a row.
      var tile = buildTile(panel, device.cols);
      grid.appendChild(tile);
      tiles[panel.id] = tile;
    });

    if (caption) {
      var label = { mac: "Mac", ipad: "iPad", iphone: "iPhone", tv: "Apple TV", watch: "Apple Watch" }[state.device];
      caption.innerHTML = "";
      caption.appendChild(el("strong", null, label));
      caption.appendChild(document.createTextNode(" · " + device.note));
    }
    paint();
  }

  function setRing(tile, fraction, text) {
    var fill = tile.querySelector(".ring-fill");
    var value = tile.querySelector(".tile-value");
    if (fill) {
      var circumference = 2 * Math.PI * 14;
      fill.setAttribute("stroke-dashoffset", String(circumference * (1 - fraction)));
    }
    if (value) value.textContent = text;
  }

  function drawGraph(tile) {
    var canvas = tile.querySelector("canvas");
    if (!canvas) return;
    var ratio = window.devicePixelRatio || 1;
    var width = canvas.clientWidth;
    var height = canvas.clientHeight;
    if (!width || !height) return;
    canvas.width = width * ratio;
    canvas.height = height * ratio;
    var ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    ctx.clearRect(0, 0, width, height);

    var series = state.rps;
    var max = Math.max.apply(null, series) * 1.15;
    var min = Math.min.apply(null, series) * 0.85;
    var span = Math.max(max - min, 1);
    var points = series.map(function (value, i) {
      return [
        (width * i) / (series.length - 1),
        height - ((value - min) / span) * (height - 6) - 3
      ];
    });

    var gradient = ctx.createLinearGradient(0, 0, 0, height);
    gradient.addColorStop(0, "rgba(247,162,60,0.34)");
    gradient.addColorStop(1, "rgba(247,162,60,0)");
    ctx.beginPath();
    ctx.moveTo(0, height);
    points.forEach(function (p) { ctx.lineTo(p[0], p[1]); });
    ctx.lineTo(width, height);
    ctx.closePath();
    ctx.fillStyle = gradient;
    ctx.fill();

    ctx.beginPath();
    points.forEach(function (p, i) { i ? ctx.lineTo(p[0], p[1]) : ctx.moveTo(p[0], p[1]); });
    ctx.strokeStyle = "#f7a23c";
    ctx.lineWidth = 2;
    ctx.lineJoin = "round";
    ctx.stroke();

    var last = points[points.length - 1];
    ctx.beginPath();
    ctx.arc(last[0] - 2, last[1], 3, 0, Math.PI * 2);
    ctx.fillStyle = "#3ecfc0";
    ctx.fill();
  }

  function paint() {
    var now = new Date();
    var clock = tiles.clock && tiles.clock.querySelector(".tile-value");
    if (clock) {
      clock.textContent =
        String(now.getHours()).padStart(2, "0") + ":" +
        String(now.getMinutes()).padStart(2, "0") + ":" +
        String(now.getSeconds()).padStart(2, "0");
    }

    if (tiles.cpu) setRing(tiles.cpu, state.cpu, Math.round(state.cpu * 100) + "%");
    if (tiles.mem) setRing(tiles.mem, state.mem, Math.round(state.mem * 100) + "%");

    if (tiles.uptime) {
      var uptime = tiles.uptime.querySelector(".tile-value");
      if (uptime) {
        uptime.textContent = state.uptimeDays + " ";
        var unit = el("small", null, "days");
        uptime.appendChild(unit);
      }
    }

    if (tiles.errors) {
      var errors = tiles.errors.querySelector(".tile-value");
      if (errors) {
        errors.textContent = state.errors.toFixed(2) + " ";
        errors.appendChild(el("small", null, "%"));
      }
    }

    if (tiles.ship) {
      var ship = tiles.ship.querySelector(".tile-value");
      if (ship) {
        var target = new Date(now);
        target.setHours(18, 0, 0, 0);
        if (target < now) target.setDate(target.getDate() + 1);
        var left = Math.floor((target - now) / 1000);
        ship.textContent =
          String(Math.floor(left / 3600)).padStart(2, "0") + ":" +
          String(Math.floor((left % 3600) / 60)).padStart(2, "0") + ":" +
          String(left % 60).padStart(2, "0");
      }
    }

    if (tiles.status) {
      var summary = tiles.status.querySelector(".tile-value");
      var lights = tiles.status.querySelector(".lights");
      var down = state.services.filter(function (s) { return s === "down"; }).length;
      if (summary) summary.textContent = down === 0 ? "All up" : down + " down";
      if (lights) {
        lights.textContent = "";
        state.services.forEach(function (s) {
          lights.appendChild(el("i", s === "up" ? "" : s));
        });
      }
    }

    if (tiles.deploys) {
      var bars = tiles.deploys.querySelectorAll(".bars i");
      var peak = Math.max.apply(null, state.deploys);
      Array.prototype.forEach.call(bars, function (bar, i) {
        bar.style.height = Math.max((state.deploys[i] / peak) * 100, 8) + "%";
      });
    }

    if (tiles.rps) drawGraph(tiles.rps);
  }

  function wander(value, amount, low, high) {
    var next = value + (Math.random() - 0.5) * amount;
    return Math.min(Math.max(next, low), high);
  }

  function advance() {
    state.cpu = wander(state.cpu, 0.14, 0.08, 0.94);
    state.mem = wander(state.mem, 0.06, 0.35, 0.88);
    state.errors = wander(state.errors, 0.22, 0, 2.4);
    state.rps.push(Math.round(wander(state.rps[state.rps.length - 1], 26, 18, 140)));
    if (state.rps.length > 12) state.rps.shift();
    if (Math.random() < 0.12) {
      var i = Math.floor(Math.random() * state.services.length);
      state.services[i] = state.services[i] === "down" ? "up" : (Math.random() < 0.5 ? "down" : "up");
    }
    if (Math.random() < 0.2) {
      state.deploys.push(Math.round(wander(state.deploys[state.deploys.length - 1], 6, 1, 12)));
      state.deploys.shift();
    }
    paint();
  }

  function initBoard() {
    if (!grid) return;
    render();
    document.querySelectorAll(".device-switch button").forEach(function (button) {
      button.setAttribute("aria-pressed", String(button.getAttribute("data-device") === state.device));
    });

    document.querySelectorAll(".device-switch button").forEach(function (button) {
      button.addEventListener("click", function () {
        var device = button.getAttribute("data-device");
        if (!DEVICES[device]) return;
        state.device = device;
        document.querySelectorAll(".device-switch button").forEach(function (other) {
          other.setAttribute("aria-pressed", String(other === button));
        });
        render();
      });
    });

    window.addEventListener("resize", function () {
      if (tiles.rps) drawGraph(tiles.rps);
    });

    // The clock ticks even with reduced motion; only the simulated data pauses.
    setInterval(paint, 1000);
    if (!reducedMotion.matches) setInterval(advance, 2000);
  }

  function start() {
    initReveal();
    initBoard();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start);
  } else {
    start();
  }
})();
