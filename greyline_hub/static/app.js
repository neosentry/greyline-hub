"use strict";

const pageId = meta("greyline-page") || "main";
const statusURL = meta("greyline-status") || "data/status.json";
const worldURL = meta("greyline-world") || "assets/land.geojson";
const pagesURL = meta("greyline-pages") || "pages/";

const stage = document.getElementById("stage");
const banner = document.getElementById("banner");
const topEl = document.getElementById("top");
const columns = document.getElementById("columns");
const mapPanel = document.getElementById("map-panel");
const canvas = document.getElementById("map");
const legend = document.getElementById("legend");
const side = document.getElementById("side");
const dxEl = document.getElementById("dx");
const statusline = document.getElementById("statusline");

const BAND_COLOR = {
  "160m": "#8d6a4a",
  "80m": "#d06a6a",
  "60m": "#d08a5a",
  "40m": "#e0a15a",
  "30m": "#e0c15a",
  "20m": "#d6d26a",
  "17m": "#8dce7a",
  "15m": "#5ec8b0",
  "12m": "#5aa6e0",
  "10m": "#8a7ae0",
  "6m": "#d06ac8",
  "2m": "#d08aa8",
  "70cm": "#c08ad0",
};

let status = null;
let world = null;
let baseCanvas = null;
let clockOffset = 0;
let driftTimer = 0;
let driftKey = "";
let lastSpotKey = "";

function meta(name) {
  const node = document.querySelector(`meta[name="${name}"]`);
  return node ? node.getAttribute("content") : "";
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function clear(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
}

function dash(value) {
  return value == null || value === "" ? "–" : String(value);
}

function compact(value, digits) {
  if (value == null || value === "") return "–";
  const number = Number(value);
  if (Number.isNaN(number)) return String(value);
  return number.toFixed(digits).replace(/\.0+$/, "").replace(/(\.\d*[1-9])0+$/, "$1");
}

function zoneLabel(date, timeZone) {
  if (!timeZone) return "Local";
  try {
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone,
      timeZoneName: "short",
    }).formatToParts(date);
    const name = parts.find((part) => part.type === "timeZoneName");
    return name && name.value ? name.value : "Local";
  } catch (err) {
    return "Local";
  }
}

function formatTime(date, timeZone) {
  const options = { hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" };
  try {
    return new Intl.DateTimeFormat("en-GB", Object.assign({ timeZone }, options)).format(date);
  } catch (err) {
    return new Intl.DateTimeFormat("en-GB", options).format(date);
  }
}

function formatDate(date, timeZone) {
  try {
    return new Intl.DateTimeFormat("en-GB", {
      timeZone: timeZone || "UTC",
      weekday: "short",
      day: "2-digit",
      month: "short",
    }).format(date);
  } catch (err) {
    return "";
  }
}

function ageLabel(seconds) {
  if (seconds == null) return "";
  if (seconds < 90) return `${Math.round(seconds)}s`;
  if (seconds < 90 * 60) return `${Math.round(seconds / 60)}m`;
  return `${Math.round(seconds / 3600)}h`;
}

function currentPage() {
  const pages = (status && status.pages) || [];
  return (
    pages.find((page) => page.id === pageId) ||
    pages[0] || {
      id: pageId,
      title: "Greyline Hub",
      panels: ["clock", "map", "space_weather", "bands", "dx_spots"],
      dx_rows: 8,
      show_vhf: false,
      map: { spots: true, labels: true, greyline: true, home: true, sun: true, graticule: true },
      burn_in: { enabled: true, period_sec: 180, pixels: 8 },
    }
  );
}

function panelsOf(page) {
  return new Set(page.panels || []);
}

function condClass(text) {
  const value = String(text || "").toLowerCase();
  if (value.includes("good") || value.includes("open")) return "good";
  if (value.includes("fair")) return "fair";
  if (value.includes("poor") || value.includes("closed")) return "poor";
  return "unk";
}

function wrapLon(lon) {
  return ((((lon + 180) % 360) + 360) % 360) - 180;
}

function solarView() {
  if (!status || !status.solar) return null;
  const at = Date.parse(status.solar.at || status.server_time);
  const dtHours = Number.isNaN(at) ? 0 : (Date.now() + clockOffset - at) / 3600000;
  return {
    decl: status.solar.declination,
    subLon: wrapLon(status.solar.subsolar_longitude - 15 * dtHours),
    subLat: status.solar.subsolar_latitude,
    shift: 15 * dtHours,
    grid: status.solar.grid,
  };
}

function solarElevation(lat, lon, decl, subLon) {
  const rad = Math.PI / 180;
  const ha = (lon - subLon) * rad;
  const sinElev =
    Math.sin(lat * rad) * Math.sin(decl * rad) +
    Math.cos(lat * rad) * Math.cos(decl * rad) * Math.cos(ha);
  return (Math.asin(Math.max(-1, Math.min(1, sinElev))) * 180) / Math.PI;
}

function daylightName(elev) {
  if (elev >= -12 && elev <= 6) return "greyline";
  return elev > 6 ? "day" : "night";
}

function render() {
  const page = currentPage();
  const panels = panelsOf(page);
  renderHeader(page, panels);
  renderSide(page, panels);
  renderDx(page, panels);
  renderLegend(page, panels);
  renderStatusline();
  columns.classList.toggle("no-map", !panels.has("map"));
  columns.classList.toggle("no-side", side.hidden);
  applyDrift(page);
  drawMap(true);
}

function renderHeader(page, panels) {
  topEl.hidden = !panels.has("clock");
  if (topEl.hidden) return;
  const station = (status && status.station) || {};
  const zone = station.timezone || undefined;
  clear(topEl);

  const brand = el("div", "brand");
  const word = el("div", "wordmark");
  word.append(el("span", null, "GREYLINE"), el("span", "hub", "HUB"));
  brand.append(word, el("div", "page-name", page.title || "Dashboard"));

  const stationEl = el("div", "station");
  stationEl.append(el("div", "call", station.callsign || "–"));
  stationEl.append(el("div", "grid", station.grid || ""));
  const state = el("div", "state", "–");
  state.dataset.state = "1";
  const elev = el("div", "elev", "");
  elev.dataset.elev = "1";
  stationEl.append(state, elev);

  const clocks = el("div", "clocks");
  clocks.append(clockBlock("UTC", "utc", "utc-date"));
  clocks.append(clockBlock(zoneLabel(new Date(), zone), "local", "local-date"));
  topEl.append(brand, stationEl, clocks);
  tick();
}

function clockBlock(label, kind, dateKind) {
  const block = el("div", `clock ${kind === "local" ? "local" : "utc"}`);
  block.append(el("div", "lbl", label));
  const time = el("div", "time", "––:––:––");
  time.dataset.clock = kind;
  const sub = el("div", "sub", "");
  sub.dataset.date = dateKind;
  block.append(time, sub);
  return block;
}

function tick() {
  const now = new Date(Date.now() + clockOffset);
  const station = (status && status.station) || {};
  const zone = station.timezone;
  const utc = document.querySelector("[data-clock=utc]");
  const local = document.querySelector("[data-clock=local]");
  if (utc) utc.textContent = formatTime(now, "UTC");
  if (local) local.textContent = formatTime(now, zone);
  const utcDate = document.querySelector("[data-date=utc-date]");
  const localDate = document.querySelector("[data-date=local-date]");
  if (utcDate) {
    const sr = station.sunrise_utc ? `rise ${station.sunrise_utc}` : "";
    const ss = station.sunset_utc ? `set ${station.sunset_utc}` : "";
    utcDate.textContent = [formatDate(now, "UTC"), sr, ss].filter(Boolean).join("  ");
  }
  if (localDate) {
    const sr = station.sunrise_local ? `rise ${station.sunrise_local}` : "";
    const ss = station.sunset_local ? `set ${station.sunset_local}` : "";
    localDate.textContent = [formatDate(now, zone), sr, ss].filter(Boolean).join("  ");
  }
  const view = solarView();
  const stateEl = document.querySelector("[data-state]");
  const elevEl = document.querySelector("[data-elev]");
  if (view && station.lat != null && stateEl && elevEl) {
    const elev = solarElevation(station.lat, station.lon, view.decl, view.subLon);
    const name = daylightName(elev);
    stateEl.textContent = name === "greyline" ? "Greyline" : name === "day" ? "Day" : "Night";
    stateEl.className = `state ${name}`;
    elevEl.textContent = `elev ${elev.toFixed(0)}°`;
  }
}

function renderSide(page, panels) {
  clear(side);
  if (panels.has("space_weather")) side.append(renderWeather());
  if (panels.has("bands")) side.append(renderBands(page));
  side.hidden = side.childElementCount === 0;
}

function sectionHead(title, stale, extra) {
  const head = el("div", "section-h");
  head.append(el("h2", null, title));
  if (stale) head.append(el("div", "badge", extra || "stale"));
  else if (extra) head.append(el("div", "badge", extra));
  return head;
}

function renderWeather() {
  const panel = el("section", "panel");
  const wx = (status && status.space_weather) || {};
  panel.append(sectionHead("Space weather", wx.stale, wx.empty ? "no report" : wx.stale ? "stale" : ""));
  const grid = el("div", "stats");
  const fields = [
    ["SFI", wx.sfi, 0],
    ["SSN", wx.ssn, 0],
    ["Kp", wx.kp, 2],
    ["A", wx.a, 0],
    ["X-ray", wx.xray, null],
    ["Wind", wx.solar_wind, 0],
    ["Bz", wx.bz, 1],
  ];
  fields.forEach(([label, field, digits]) => {
    const block = el("div", "stat");
    const value = !field ? "–" : digits == null ? dash(field.value) : compact(field.value, digits);
    const shown = label === "Wind" && field && field.value != null ? `${value}` : value;
    block.append(el("div", "lbl", label === "Wind" ? "Wind km/s" : label === "Bz" ? "Bz nT" : label));
    block.append(el("div", "val", shown));
    block.append(el("div", "src", field && field.source ? field.source : ""));
    grid.append(block);
  });
  const scales = wx.scales || {};
  const scale = el("div", "stat");
  scale.append(el("div", "lbl", "NOAA scales"));
  scale.append(el("div", "val scales", `R${dash(scales.R)}  S${dash(scales.S)}  G${dash(scales.G)}`));
  scale.append(el("div", "src", [wx.geomag, wx.noise].filter(Boolean).join(" · ")));
  grid.append(scale);
  panel.append(grid);
  if (wx.muf) {
    panel.append(el("div", "wx-note", `MUF ${wx.muf} MHz`));
  }
  return panel;
}

function renderBands(page) {
  const panel = el("section", "panel");
  const bands = (status && status.bands) || {};
  panel.append(
    sectionHead("HF bands", bands.stale, bands.estimated ? "estimated" : bands.empty ? "no report" : bands.stale ? "stale" : "")
  );
  const table = el("table", "bands");
  const head = el("thead");
  const hr = el("tr");
  ["Band", "Day", "Night"].forEach((label) => hr.append(el("th", null, label)));
  head.append(hr);
  const body = el("tbody");
  (bands.rows || []).forEach((row) => {
    const tr = el("tr");
    tr.append(el("td", null, row.name || ""));
    tr.append(conditionCell(row.day));
    tr.append(conditionCell(row.night));
    body.append(tr);
  });
  if (!bands.rows || !bands.rows.length) {
    const tr = el("tr");
    const td = el("td", "cond unk", "Waiting for a band report");
    td.colSpan = 3;
    tr.append(td);
    body.append(tr);
  }
  table.append(head, body);
  panel.append(table);
  if (bands.estimated) {
    panel.append(el("p", "estimate", "N0NBH is unreachable. These are rough SFI and Kp rules, not a path forecast."));
  }
  if (page.show_vhf && bands.vhf && bands.vhf.length) {
    const wrap = el("div", "vhf");
    bands.vhf.forEach((item) => {
      const label = `${prettyVhf(item.name)} ${prettyPlace(item.location)}`.trim();
      const chip = el("span", `chip ${condClass(item.condition)}`, `${label}: ${item.condition || "–"}`);
      wrap.append(chip);
    });
    panel.append(wrap);
  }
  return panel;
}

function prettyVhf(name) {
  const known = {
    "vhf-aurora": "Aurora",
    "E-Skip": "E-skip",
  };
  return known[name] || String(name || "").replace(/-/g, " ");
}

function prettyPlace(name) {
  const known = {
    northern_hemi: "N. hemisphere",
    europe: "Europe",
    north_america: "N. America",
    europe_6m: "Europe 6m",
    europe_4m: "Europe 4m",
  };
  if (known[name]) return known[name];
  return String(name || "")
    .replace(/_/g, " ")
    .replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function conditionCell(value) {
  return el("td", `cond ${condClass(value)}`, value || "–");
}

function renderDx(page, panels) {
  dxEl.hidden = !panels.has("dx_spots");
  if (dxEl.hidden) return;
  const spots = (status && status.spots) || {};
  const items = (spots.items || []).slice(0, page.dx_rows || 10);
  const key = items.map((spot) => spot.id).join("|") + (spots.stale ? "s" : "");
  if (key === lastSpotKey && dxEl.childElementCount) return;
  lastSpotKey = key;
  clear(dxEl);
  dxEl.append(sectionHead("DX spots", spots.stale, spots.empty ? "quiet" : spots.source || ""));
  const table = el("table");
  const head = el("thead");
  const hr = el("tr");
  ["UTC", "MHz", "Band", "DX", "Mode", "Spotter", "Where", "Note"].forEach((label) => {
    hr.append(el("th", null, label));
  });
  head.append(hr);
  const body = el("tbody");
  if (!items.length) {
    const tr = el("tr");
    const td = el("td", null, "No fresh spots. The last good list stays here when the cluster is reachable again.");
    td.colSpan = 8;
    tr.append(td);
    body.append(tr);
  }
  items.forEach((spot) => {
    const tr = el("tr");
    const time = (spot.time || "").slice(11, 16);
    tr.append(el("td", null, time || "–"));
    tr.append(el("td", null, spot.freq_khz != null ? (spot.freq_khz / 1000).toFixed(3) : "–"));
    const band = el("td");
    if (spot.band) {
      const pip = el("span", "swatch");
      pip.style.cssText = `height:8px;width:8px;border-radius:50%;background:${BAND_COLOR[spot.band] || "#d7dee6"};margin-right:6px`;
      band.append(pip);
    }
    band.append(document.createTextNode(spot.band || "–"));
    tr.append(band);
    tr.append(el("td", "dx", spot.dx || "–"));
    tr.append(el("td", "mode", spot.mode || ""));
    tr.append(el("td", null, spot.spotter || ""));
    tr.append(el("td", null, spot.country || ""));
    const note = spot.comment && spot.comment.toUpperCase() !== (spot.mode || "").toUpperCase() ? spot.comment : "";
    tr.append(el("td", "comment", note));
    body.append(tr);
  });
  table.append(head, body);
  dxEl.append(table);
}

function renderLegend(page, panels) {
  clear(legend);
  if (!panels.has("map")) return;
  legend.append(el("span", null, ""));
  const line = el("span");
  line.append(el("i", "swatch"), document.createTextNode("Greyline"));
  const night = el("span");
  night.append(el("i", "swatch night"), document.createTextNode("Night"));
  legend.append(line, night);
  const station = status && status.station;
  if (station && station.callsign) {
    legend.append(el("span", null, station.callsign));
  }
}

function renderStatusline() {
  clear(statusline);
  const feeds = (status && status.feeds) || {};
  ["space_weather", "bands", "dx"].forEach((key) => {
    const feed = feeds[key];
    if (!feed) return;
    const row = el("span", "feed");
    let kind = "bad";
    if (feed.ok) kind = "ok";
    else if (feed.stale) kind = "stale";
    else if (feed.empty) kind = "";
    row.append(el("i", `dot ${kind}`));
    const age = ageLabel(feed.age_sec);
    row.append(document.createTextNode(`${feed.name}${age ? " " + age : ""}`));
    statusline.append(row);
  });
  const link = el("a", null, "Pages");
  link.id = "pages-link";
  link.href = pagesURL;
  statusline.append(link);
}

function applyDrift(page) {
  const burn = page.burn_in || {};
  const key = JSON.stringify(burn);
  if (key === driftKey) return;
  driftKey = key;
  if (driftTimer) clearInterval(driftTimer);
  if (!burn.enabled || !burn.pixels) {
    stage.style.transform = "none";
    return;
  }
  const path = [
    [0, 0],
    [1, 0.35],
    [0.4, 1],
    [-0.8, 0.45],
    [-0.3, -0.7],
    [0.65, -0.25],
  ];
  let index = 0;
  const move = () => {
    const pair = path[index % path.length];
    index += 1;
    stage.style.transition = "transform 3s linear";
    stage.style.transform = `translate(${(pair[0] * burn.pixels).toFixed(1)}px, ${(pair[1] * burn.pixels).toFixed(1)}px)`;
  };
  move();
  driftTimer = setInterval(move, (burn.period_sec * 1000) / path.length);
}

function project(lon, lat, width, height) {
  return [((lon + 180) / 360) * width, ((90 - lat) / 180) * height];
}

function drawRings(ctx, rings, width, height) {
  rings.forEach((ring) => {
    ring.forEach((point, index) => {
      const xy = project(point[0], point[1], width, height);
      if (index === 0) ctx.moveTo(xy[0], xy[1]);
      else ctx.lineTo(xy[0], xy[1]);
    });
    ctx.closePath();
  });
}

function buildBase(width, height, page) {
  const ratio = window.devicePixelRatio || 1;
  baseCanvas = document.createElement("canvas");
  baseCanvas.width = Math.max(1, Math.floor(width * ratio));
  baseCanvas.height = Math.max(1, Math.floor(height * ratio));
  const ctx = baseCanvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.fillStyle = "#0c141c";
  ctx.fillRect(0, 0, width, height);
  if (world && world.features) {
    ctx.fillStyle = "#1a2b3a";
    ctx.beginPath();
    world.features.forEach((feature) => {
      const geom = feature.geometry || {};
      const polys = geom.type === "Polygon" ? [geom.coordinates] : geom.type === "MultiPolygon" ? geom.coordinates : [];
      polys.forEach((poly) => drawRings(ctx, poly, width, height));
    });
    ctx.fill("evenodd");
    ctx.strokeStyle = "rgba(186, 206, 220, 0.28)";
    ctx.lineWidth = 0.7;
    ctx.stroke();
  }
  if (!page || !page.map || page.map.graticule !== false) {
    ctx.strokeStyle = "rgba(255,255,255,0.05)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let lon = -150; lon < 180; lon += 30) {
      const x = project(lon, 0, width, height)[0];
      ctx.moveTo(x, 0);
      ctx.lineTo(x, height);
    }
    for (let lat = -60; lat <= 60; lat += 30) {
      const y = project(0, lat, width, height)[1];
      ctx.moveTo(0, y);
      ctx.lineTo(width, y);
    }
    ctx.stroke();
  }
}

function sample(arr, lon) {
  if (!arr || !arr.length || !status || !status.solar) return null;
  const step = status.solar.grid.step || 2;
  const x = (wrapLon(lon) + 180) / step;
  const i = Math.max(0, Math.min(arr.length - 1, Math.floor(x)));
  const j = Math.min(arr.length - 1, i + 1);
  const f = Math.min(1, Math.max(0, x - Math.floor(x)));
  const a = arr[i];
  const b = arr[j];
  if (a == null && b == null) return null;
  if (a == null || b == null) return a == null ? b : a;
  if (Math.abs(a - b) > 50) return f < 0.5 ? a : b;
  return a + (b - a) * f;
}

function sampleFill(lon) {
  const arr = status.solar.grid.fill || [];
  const step = status.solar.grid.step || 2;
  const index = Math.max(0, Math.min(arr.length - 1, Math.round((wrapLon(lon) + 180) / step)));
  return arr[index] || "";
}

function drawMap(rebuild) {
  const page = currentPage();
  if (!canvas || mapPanel.hidden) return;
  const width = mapPanel.clientWidth;
  const height = mapPanel.clientHeight;
  if (width < 4 || height < 4) return;
  const ratio = window.devicePixelRatio || 1;
  if (canvas.width !== Math.floor(width * ratio) || canvas.height !== Math.floor(height * ratio)) {
    canvas.width = Math.floor(width * ratio);
    canvas.height = Math.floor(height * ratio);
    rebuild = true;
  }
  if (rebuild || !baseCanvas) buildBase(width, height, page);
  const ctx = canvas.getContext("2d");
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, width, height);
  if (baseCanvas) ctx.drawImage(baseCanvas, 0, 0, width, height);
  const view = solarView();
  if (view && page.map && page.map.greyline !== false) shadeNight(ctx, width, height, view);
  if (view && page.map && page.map.sun !== false) drawSun(ctx, width, height, view);
  if (page.map && page.map.spots !== false) drawSpots(ctx, width, height, page);
  if (page.map && page.map.home !== false) drawHome(ctx, width, height);
}

function shadeNight(ctx, width, height, view) {
  const grid = view.grid;
  if (!grid) return;
  const night = "rgba(2, 6, 12, 0.6)";
  const dusk = "rgba(126, 146, 176, 0.2)";
  ctx.fillStyle = night;
  for (let x = 0; x < width; x += 1) {
    const lon = (x / width) * 360 - 180;
    const lookup = wrapLon(lon + view.shift);
    const dayLat = sample(grid.day, lookup);
    if (dayLat == null) {
      if (sampleFill(lookup) === "night") ctx.fillRect(x, 0, 1, height);
      continue;
    }
    const y0 = project(0, dayLat, width, height)[1];
    if (grid.night_south) ctx.fillRect(x, y0, 1, height - y0);
    else ctx.fillRect(x, 0, 1, y0);
    const twiLat = sample(grid.twi, lookup);
    if (twiLat == null) continue;
    const y6 = project(0, twiLat, width, height)[1];
    const onNight = grid.night_south ? y6 > y0 : y6 < y0;
    if (!onNight) continue;
    ctx.fillStyle = dusk;
    ctx.fillRect(x, Math.min(y0, y6), 1, Math.abs(y6 - y0));
    ctx.fillStyle = night;
  }
  ctx.beginPath();
  let open = false;
  for (let x = 0; x < width; x += 2) {
    const lon = (x / width) * 360 - 180;
    const dayLat = sample(grid.day, wrapLon(lon + view.shift));
    if (dayLat == null) {
      open = false;
      continue;
    }
    const y = project(0, dayLat, width, height)[1];
    if (!open) {
      ctx.moveTo(x, y);
      open = true;
    } else ctx.lineTo(x, y);
  }
  ctx.strokeStyle = "rgba(214, 206, 186, 0.28)";
  ctx.lineWidth = 10;
  ctx.stroke();
  ctx.strokeStyle = "rgba(240, 220, 176, 0.92)";
  ctx.lineWidth = 1.6;
  ctx.stroke();
}

function drawSun(ctx, width, height, view) {
  const xy = project(view.subLon, view.subLat, width, height);
  ctx.beginPath();
  ctx.fillStyle = "#f0c36a";
  ctx.arc(xy[0], xy[1], 4.5, 0, Math.PI * 2);
  ctx.fill();
  ctx.beginPath();
  ctx.strokeStyle = "rgba(240, 195, 106, 0.45)";
  ctx.lineWidth = 1;
  ctx.arc(xy[0], xy[1], 9, 0, Math.PI * 2);
  ctx.stroke();
}

function drawSpots(ctx, width, height, page) {
  const items = (status && status.spots && status.spots.items) || [];
  items.forEach((spot) => {
    if (spot.lat == null || spot.lon == null) return;
    const xy = project(spot.lon, spot.lat, width, height);
    ctx.beginPath();
    ctx.fillStyle = BAND_COLOR[spot.band] || "#e6edf3";
    ctx.arc(xy[0], xy[1], 2.6, 0, Math.PI * 2);
    ctx.fill();
  });
  if (!page.map || page.map.labels === false) return;
  const boxes = [];
  ctx.font = "12px sans-serif";
  items.slice(0, 8).forEach((spot) => {
    if (spot.lat == null || spot.lon == null) return;
    const xy = project(spot.lon, spot.lat, width, height);
    const text = spot.dx;
    const box = { x: xy[0] + 6, y: xy[1] - 14, w: ctx.measureText(text).width + 4, h: 14 };
    const blocked = boxes.some(
      (other) => !(box.x > other.x + other.w || other.x > box.x + box.w || box.y > other.y + other.h || other.y > box.y + box.h)
    );
    if (blocked) return;
    boxes.push(box);
    ctx.lineWidth = 3;
    ctx.strokeStyle = "rgba(8, 10, 13, 0.85)";
    ctx.strokeText(text, box.x, xy[1] - 4);
    ctx.fillStyle = "#f0d7a6";
    ctx.fillText(text, box.x, xy[1] - 4);
  });
}

function drawHome(ctx, width, height) {
  const station = status && status.station;
  if (!station || station.lat == null) return;
  const xy = project(station.lon, station.lat, width, height);
  ctx.strokeStyle = "#79d0c4";
  ctx.lineWidth = 1.4;
  ctx.strokeRect(xy[0] - 5, xy[1] - 5, 10, 10);
  ctx.beginPath();
  ctx.moveTo(xy[0] - 9, xy[1]);
  ctx.lineTo(xy[0] + 9, xy[1]);
  ctx.moveTo(xy[0], xy[1] - 9);
  ctx.lineTo(xy[0], xy[1] + 9);
  ctx.stroke();
  const label = station.callsign || "";
  if (!label) return;
  ctx.font = "12px sans-serif";
  ctx.lineWidth = 3;
  ctx.strokeStyle = "rgba(8, 10, 13, 0.88)";
  ctx.strokeText(label, xy[0] + 12, xy[1] - 8);
  ctx.fillStyle = "#79d0c4";
  ctx.fillText(label, xy[0] + 12, xy[1] - 8);
}

async function poll() {
  try {
    const response = await fetch(statusURL, { cache: "no-store" });
    if (!response.ok) throw new Error(`status ${response.status}`);
    const next = await response.json();
    status = next;
    try {
      localStorage.setItem("greyline.status.v1", JSON.stringify(next));
    } catch (err) {
      /* private mode and some webviews refuse storage; the page still runs */
    }
    const serverMs = Date.parse(next.server_time);
    if (!Number.isNaN(serverMs)) clockOffset = serverMs - Date.now();
    banner.hidden = true;
    render();
  } catch (err) {
    if (!status) status = loadSaved();
    banner.hidden = false;
    banner.textContent = status
      ? "Reconnecting. Showing the last saved update."
      : "Waiting for dashboard data.";
    if (status) render();
  }
}

function loadSaved() {
  try {
    const saved = localStorage.getItem("greyline.status.v1");
    return saved ? JSON.parse(saved) : null;
  } catch (err) {
    return null;
  }
}

fetch(worldURL)
  .then((response) => (response.ok ? response.json() : null))
  .then((data) => {
    world = data;
    drawMap(true);
  })
  .catch(() => {});

if (window.ResizeObserver) {
  const observer = new ResizeObserver(() => drawMap(true));
  observer.observe(mapPanel);
}

render();
poll();
setInterval(poll, 20000);
setInterval(tick, 250);
setInterval(() => drawMap(false), 1000);
