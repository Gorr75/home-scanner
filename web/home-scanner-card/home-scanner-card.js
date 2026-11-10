// Home Scanner Lovelace card.
// Reads /local/home_scanner/<slug>/layout.json and model.glb.
// Install notes: README.md in this folder.

const LOCAL_ROOT = "/local/home_scanner";
const TOGGLE_DOMAINS = new Set(["light", "switch", "fan"]);

function listedRoom(room) {
  if (!room || typeof room !== "object") return null;
  const slug = String(room.slug || room.id || "").trim();
  if (!slug) return null;
  return {
    slug,
    name: room.name || slug,
    path: room.path || `${LOCAL_ROOT}/${slug}/`,
    floor: Number.isInteger(room.floor) ? room.floor : null,
  };
}

function configuredRooms(config) {
  if (Array.isArray(config.rooms) && config.rooms.length) {
    return config.rooms.map(listedRoom).filter(Boolean);
  }
  if (config.slug) {
    return [listedRoom({ slug: config.slug, name: config.name, floor: config.floor })].filter(Boolean);
  }
  return null;
}

async function discoverRooms(hass) {
  if (hass && typeof hass.callApi === "function") {
    try {
      const index = await hass.callApi("GET", "home_scanner/rooms");
      if (index && Array.isArray(index.rooms)) return index.rooms.map(listedRoom).filter(Boolean);
    } catch (_error) {
      // The integration may be older than the card. Fall through to index.json.
    }
  }
  try {
    const response = await fetch(`${LOCAL_ROOT}/index.json`, { cache: "no-store" });
    if (!response.ok) return [];
    const index = await response.json();
    return Array.isArray(index.rooms) ? index.rooms.map(listedRoom).filter(Boolean) : [];
  } catch (_error) {
    return [];
  }
}

function fileURL(slug, name) {
  return `${LOCAL_ROOT}/${encodeURIComponent(slug)}/${name}`;
}

async function loadLayout(slug) {
  const response = await fetch(fileURL(slug, "layout.json"), { cache: "no-store" });
  if (!response.ok) {
    throw new Error(`No layout.json for ${slug} (${response.status}).`);
  }
  const document = await response.json();
  if (!document || document.format !== "roomscan.home" || document.version !== 1 || !document.home) {
    throw new Error("layout.json is not a roomscan.home version 1 document.");
  }
  return document.home;
}

function planPoints(plan) {
  const points = [];
  if (!plan) return points;
  for (const floor of plan.floors || []) {
    for (const corner of floor.corners || []) points.push(corner);
  }
  for (const wall of plan.walls || []) {
    if (wall.start) points.push(wall.start);
    if (wall.end) points.push(wall.end);
  }
  return points;
}

function boundsOf(points) {
  let minX = Infinity;
  let maxX = -Infinity;
  let minZ = Infinity;
  let maxZ = -Infinity;
  for (const point of points) {
    if (!point || typeof point.x !== "number" || typeof point.z !== "number") continue;
    minX = Math.min(minX, point.x);
    maxX = Math.max(maxX, point.x);
    minZ = Math.min(minZ, point.z);
    maxZ = Math.max(maxZ, point.z);
  }
  if (!Number.isFinite(minX)) return { minX: 0, maxX: 1, minZ: 0, maxZ: 1 };
  if (maxX - minX < 0.2) maxX = minX + 0.2;
  if (maxZ - minZ < 0.2) maxZ = minZ + 0.2;
  return { minX, maxX, minZ, maxZ };
}

function roomFrames(home) {
  const rooms = Array.isArray(home.rooms) ? home.rooms : [];
  const unified = rooms.length <= 1 || home.structure?.coordinates_are_unified === true;
  if (unified) return rooms.map((room) => ({ room, ox: 0, oz: 0, unified: true }));
  let cursor = 0;
  return rooms.map((room) => {
    const box = boundsOf(planPoints(room.floor_plan));
    const frame = { room, ox: cursor - box.minX, oz: -box.minZ, unified: false };
    cursor += Math.max(box.maxX - box.minX, 0.5) + 0.8;
    return frame;
  });
}

function sceneGeometry(home) {
  const frames = roomFrames(home);
  const byRoom = new Map(frames.map((frame) => [frame.room.id, frame]));
  const points = [];
  for (const frame of frames) {
    for (const point of planPoints(frame.room.floor_plan)) {
      points.push({ x: point.x + frame.ox, z: point.z + frame.oz });
    }
  }
  for (const pin of home.pins || []) {
    const frame = byRoom.get(pin.room_id);
    const position = pin.position || {};
    points.push({
      x: (position.x || 0) + (frame ? frame.ox : 0),
      z: (position.z || 0) + (frame ? frame.oz : 0),
    });
  }
  return { frames, byRoom, bounds: boundsOf(points), unified: frames.every((frame) => frame.unified) };
}

function integerFloor(value) {
  return Number.isInteger(value) ? value : null;
}

function floorChoices(rooms) {
  const levels = [];
  let unassigned = false;
  for (const room of rooms || []) {
    const level = integerFloor(room.floor);
    if (level == null) {
      unassigned = true;
      continue;
    }
    if (!levels.includes(level)) levels.push(level);
  }
  levels.sort((a, b) => a - b);
  if (!levels.length) return [];
  const choices = levels.map((level) => ({ level, name: `Floor ${level}` }));
  if (unassigned) choices.push({ level: null, name: "No floor" });
  return choices;
}

function roomsOnFloor(rooms, level) {
  return (rooms || []).filter((room) => integerFloor(room.floor) === level);
}

function activeFloor(choices, selected) {
  if (!choices.length) return undefined;
  if (choices.some((choice) => choice.level === selected)) return selected;
  return choices[0].level;
}

function foldersOnFloor(folders, level, enabled) {
  if (!enabled) return folders || [];
  return (folders || []).filter((folder) => integerFloor(folder.floor) === level);
}

function focusedRoom(rooms, floor, roomId) {
  const list = Array.isArray(rooms) ? rooms : [];
  if (!list.length) return null;
  if (list.length === 1) return list[0];
  const choices = floorChoices(list);
  const level = activeFloor(choices, floor);
  const visible = choices.length ? roomsOnFloor(list, level) : list;
  return visible.find((room) => room.id === roomId) || visible[0] || list[0];
}

function plateSlugFor(folderSlug, home, room) {
  const rooms = home && Array.isArray(home.rooms) ? home.rooms : [];
  if (rooms.length <= 1) return folderSlug || null;
  if (room && room.id) return String(room.id);
  return folderSlug || null;
}

function trimNumber(value) {
  if (!Number.isFinite(value)) return "0";
  return String(Math.round(value * 10000) / 10000);
}

function cameraOrbit(viewpoint, offset) {
  const shift = offset || {};
  const position = viewpoint && viewpoint.position ? viewpoint.position : {};
  const target = viewpoint && viewpoint.target ? viewpoint.target : {};
  const targetX = (Number(target.x) || 0) + (Number(shift.x) || 0);
  const targetY = Number(target.y) || 0;
  const targetZ = (Number(target.z) || 0) + (Number(shift.z) || 0);
  let dx = (Number(position.x) || 0) + (Number(shift.x) || 0) - targetX;
  let dy = (Number(position.y) || 0) - targetY;
  let dz = (Number(position.z) || 0) + (Number(shift.z) || 0) - targetZ;
  let radius = Math.hypot(dx, dy, dz);
  if (!(radius > 1e-4)) {
    dx = 0;
    dy = 0;
    dz = 1;
    radius = 1;
  }
  const theta = Math.atan2(dx, dz);
  const phi = Math.acos(Math.min(1, Math.max(-1, dy / radius)));
  const fov = Number(viewpoint && (viewpoint.field_of_view ?? viewpoint.fieldOfView));
  return {
    theta,
    phi,
    radius,
    fieldOfView: Number.isFinite(fov) && fov > 0 ? fov : 48,
    orbit: `${trimNumber(theta)}rad ${trimNumber(phi)}rad ${trimNumber(radius)}m`,
    target: `${trimNumber(targetX)}m ${trimNumber(targetY)}m ${trimNumber(targetZ)}m`,
  };
}

function plateVariant(tint) {
  return tint && tint.phase === "night" ? "night" : "day";
}

function plateStyle(stateObj) {
  if (!stateObj || stateObj.state !== "on") {
    return { opacity: 0, color: "rgb(255, 255, 255)" };
  }
  const domain = (stateObj.entity_id || "").split(".")[0];
  if (domain !== "light") return { opacity: 1, color: "rgb(255, 255, 255)" };
  const attrs = stateObj.attributes || {};
  const brightness = typeof attrs.brightness === "number" ? Math.max(0, Math.min(1, attrs.brightness / 255)) : 1;
  const rgb = lightRGB(attrs).map((value) => Math.round(Math.max(0, Math.min(255, value))));
  return { opacity: brightness, color: `rgb(${rgb[0]}, ${rgb[1]}, ${rgb[2]})` };
}

function hitRegion(regions, x, y) {
  let best = null;
  let bestDistance = Infinity;
  for (const region of regions || []) {
    if (!region || typeof region.x !== "number" || typeof region.y !== "number") continue;
    const radius = Number(region.radius);
    if (!(radius > 0)) continue;
    const distance = (region.x - x) ** 2 + (region.y - y) ** 2;
    if (distance <= radius * radius && distance < bestDistance) {
      best = region;
      bestDistance = distance;
    }
  }
  return best;
}

async function loadPlates(slug) {
  const response = await fetch(fileURL(slug, "plates/manifest.json"), { cache: "no-store" });
  if (!response.ok) return null;
  const manifest = await response.json();
  if (!manifest || manifest.format !== "home_scanner.plates" || manifest.version !== 1) return null;
  if (!manifest.day || !manifest.night) return null;
  return manifest;
}

function lightRGB(attributes) {
  if (Array.isArray(attributes.rgb_color) && attributes.rgb_color.length >= 3) {
    return attributes.rgb_color;
  }
  if (Array.isArray(attributes.hs_color) && attributes.hs_color.length >= 2) {
    const hue = Number(attributes.hs_color[0]) / 60;
    const saturation = Number(attributes.hs_color[1]) > 1 ? Number(attributes.hs_color[1]) / 100 : Number(attributes.hs_color[1]);
    const chroma = saturation;
    const x = chroma * (1 - Math.abs((hue % 2) - 1));
    let red = 0;
    let green = 0;
    let blue = 0;
    if (hue < 1) [red, green, blue] = [chroma, x, 0];
    else if (hue < 2) [red, green, blue] = [x, chroma, 0];
    else if (hue < 3) [red, green, blue] = [0, chroma, x];
    else if (hue < 4) [red, green, blue] = [0, x, chroma];
    else if (hue < 5) [red, green, blue] = [x, 0, chroma];
    else [red, green, blue] = [chroma, 0, x];
    const match = 1 - chroma;
    return [(red + match) * 255, (green + match) * 255, (blue + match) * 255];
  }
  const kelvin = Number(attributes.color_temp_kelvin) || (attributes.color_temp ? 1000000 / Number(attributes.color_temp) : 0);
  if (kelvin > 500 && kelvin < 20000) {
    const temperature = kelvin / 100;
    const red = temperature <= 66 ? 255 : 329.698727446 * (temperature - 60) ** -0.1332047592;
    const green = temperature <= 66
      ? 99.4708025861 * Math.log(temperature) - 161.1195681661
      : 288.1221695283 * (temperature - 60) ** -0.0755148492;
    let blue = 255;
    if (temperature < 66) {
      blue = temperature <= 19 ? 0 : 138.5177312231 * Math.log(temperature - 10) - 305.0447927307;
    }
    return [red, green, blue];
  }
  return [255, 198, 115];
}

// Stops, peak elevation, and the 06:00/18:00 clock match DaylightMath in
// RoomScanCore/Sources/RoomScanCore/Daylight.swift.
const DAYLIGHT_STOPS = [
  [-90, 0.3, 0.42, 0.76, 0.06, 0.08],
  [-8, 0.4, 0.5, 0.74, 0.14, 0.13],
  [0, 1, 0.55, 0.26, 0.32, 0.18],
  [15, 1, 0.68, 0.36, 0.55, 0.3],
  [28, 1, 0.86, 0.68, 0.78, 0.42],
  [48, 1, 0.97, 0.93, 1, 0.55],
  [90, 1, 0.98, 0.95, 1, 0.56],
];
const DAYLIGHT_PEAK = 55;
const DAYLIGHT_SUNRISE_HOUR = 6;
const daylightEnvironments = new Map();

function daylightMix(start, end, t) {
  const value = start + (end - start) * t;
  if (!Number.isFinite(value)) return 0;
  return Math.min(1, Math.max(0, value));
}

function daylightChannels(elevation) {
  const clamped = Math.min(90, Math.max(-90, elevation));
  const stops = DAYLIGHT_STOPS;
  if (clamped <= stops[0][0]) return stops[0].slice(1);
  if (clamped >= stops[stops.length - 1][0]) return stops[stops.length - 1].slice(1);
  for (let index = 1; index < stops.length; index += 1) {
    const upper = stops[index];
    const lower = stops[index - 1];
    if (clamped <= upper[0]) {
      const span = upper[0] - lower[0];
      const t = span === 0 ? 0 : (clamped - lower[0]) / span;
      return [1, 2, 3, 4, 5].map((channel) => daylightMix(lower[channel], upper[channel], t));
    }
  }
  return stops[stops.length - 1].slice(1);
}

function daylightPhase(elevation, morning) {
  if (elevation >= 20) return "day";
  if (elevation <= -6) return "night";
  return morning ? "sunrise" : "sunset";
}

function daylightTint(elevation, morning) {
  const clamped = Math.min(90, Math.max(-90, elevation));
  const channels = daylightChannels(clamped);
  return {
    red: channels[0],
    green: channels[1],
    blue: channels[2],
    key: channels[3],
    fill: channels[4],
    phase: daylightPhase(clamped, morning),
    source: "clock",
  };
}

function hourOf(date) {
  return date.getHours() + date.getMinutes() / 60 + date.getSeconds() / 3600;
}

function daylightFromClock(date) {
  const hour = ((hourOf(date) % 24) + 24) % 24;
  const elevation = DAYLIGHT_PEAK * Math.sin(((hour - DAYLIGHT_SUNRISE_HOUR) / 12) * Math.PI);
  return daylightTint(elevation, hour < 12);
}

function parseSunDate(value) {
  if (!value) return null;
  const time = Date.parse(value);
  return Number.isFinite(time) ? time : null;
}

function syntheticElevation(nowMs, risingMs, settingMs) {
  if (settingMs < risingMs) {
    const previousRise = risingMs - 86400000;
    const span = settingMs - previousRise;
    if (span <= 60000) return null;
    const fraction = Math.min(1, Math.max(0, (nowMs - previousRise) / span));
    return DAYLIGHT_PEAK * Math.sin(fraction * Math.PI);
  }
  const previousSet = settingMs - 86400000;
  const span = risingMs - previousSet;
  if (span <= 60000) return null;
  const fraction = Math.min(1, Math.max(0, (nowMs - previousSet) / span));
  return -DAYLIGHT_PEAK * Math.sin(fraction * Math.PI);
}

function sunIsMorning(nowMs, risingMs, settingMs) {
  if (risingMs == null || settingMs == null) return null;
  if (settingMs < risingMs) {
    const previousRise = risingMs - 86400000;
    const mid = previousRise + (settingMs - previousRise) / 2;
    return nowMs < mid;
  }
  const previousSet = settingMs - 86400000;
  const mid = previousSet + (risingMs - previousSet) / 2;
  return nowMs >= mid;
}

function daylightFromSun(stateObj, now) {
  if (!stateObj) return daylightFromClock(now);
  const attrs = stateObj.attributes || {};
  const nowMs = now.getTime();
  const rising = parseSunDate(attrs.next_rising);
  const setting = parseSunDate(attrs.next_setting);
  const morningClock = hourOf(now) < 12;
  const morning = sunIsMorning(nowMs, rising, setting);
  const morningFlag = morning == null ? morningClock : morning;
  const elevation = Number(attrs.elevation);
  if (Number.isFinite(elevation)) {
    const tint = daylightTint(elevation, morningFlag);
    tint.source = "sun";
    return tint;
  }
  if (rising != null && setting != null) {
    const synthetic = syntheticElevation(nowMs, rising, setting);
    if (synthetic != null) {
      const tint = daylightTint(synthetic, morningFlag);
      tint.source = "sun";
      return tint;
    }
  }
  if (stateObj.state === "above_horizon") {
    const tint = daylightTint(45, morningClock);
    tint.source = "sun";
    return tint;
  }
  if (stateObj.state === "below_horizon") {
    const tint = daylightTint(-30, morningClock);
    tint.source = "sun";
    return tint;
  }
  return daylightFromClock(now);
}

function daylightBackground(tint) {
  const mix = 0.12 + 0.1 * tint.key;
  const base = [16, 14, 12];
  const channels = [tint.red, tint.green, tint.blue].map((channel, index) =>
    Math.round(base[index] * (1 - mix) + channel * 255 * mix)
  );
  return `rgb(${channels[0]}, ${channels[1]}, ${channels[2]})`;
}

function daylightStroke(tint) {
  const chalk = [232, 224, 212];
  const mix = 0.28;
  const channels = [tint.red, tint.green, tint.blue].map((channel, index) =>
    Math.round(chalk[index] * (1 - mix) + channel * 255 * mix)
  );
  return `rgb(${channels[0]}, ${channels[1]}, ${channels[2]})`;
}

function daylightEnvironment(tint) {
  const key = [tint.red, tint.green, tint.blue, tint.key].map((value) => Math.round(value * 32)).join(".");
  const cached = daylightEnvironments.get(key);
  if (cached) return cached;
  const canvas = document.createElement("canvas");
  canvas.width = 64;
  canvas.height = 32;
  const context = canvas.getContext("2d");
  if (!context) return "";
  const sky = context.createLinearGradient(0, 0, 0, 32);
  const red = Math.round(tint.red * 255);
  const green = Math.round(tint.green * 255);
  const blue = Math.round(tint.blue * 255);
  sky.addColorStop(0, `rgb(${red}, ${green}, ${blue})`);
  sky.addColorStop(1, daylightBackground(tint));
  context.fillStyle = sky;
  context.fillRect(0, 0, 64, 32);
  const url = canvas.toDataURL("image/jpeg", 0.85);
  daylightEnvironments.set(key, url);
  return url;
}

function daylightLabel(tint) {
  const names = { night: "Night", sunrise: "Sunrise", sunset: "Sunset", day: "Midday" };
  const source = tint.source === "sun" ? "sun.sun" : "this device's clock";
  return `Daylight from ${source} · ${names[tint.phase] || ""}`;
}

function lightStyle(stateObj) {
  if (!stateObj) return { fill: "#8aa39a", label: "—" };
  const state = stateObj.state;
  const domain = (stateObj.entity_id || "").split(".")[0];
  if (domain === "light") {
    if (state !== "on") return { fill: "#726c64", label: state || "off" };
    const attrs = stateObj.attributes || {};
    const rgb = lightRGB(attrs);
    const brightness = typeof attrs.brightness === "number" ? attrs.brightness / 255 : 1;
    const gain = 0.22 + 0.78 * Math.max(0, Math.min(1, brightness));
    const channel = (value) => Math.round(Math.max(0, Math.min(255, value)) * gain);
    const percent = Math.round(brightness * 100);
    return {
      fill: `rgb(${channel(rgb[0])}, ${channel(rgb[1])}, ${channel(rgb[2])})`,
      label: `on ${percent}%`,
    };
  }
  if (state === "on") return { fill: "#2e8c52", label: "on" };
  if (state === "off") return { fill: "#726c64", label: "off" };
  const unit = stateObj.attributes?.unit_of_measurement;
  return { fill: "#32618c", label: unit ? `${state} ${unit}` : String(state || "") };
}

async function ensureModelViewer() {
  if (customElements.get("model-viewer")) return true;
  const urls = [
    new URL("./model-viewer.min.js", import.meta.url).href,
    "https://unpkg.com/@google/model-viewer@3.5.0/dist/model-viewer.min.js",
  ];
  for (const url of urls) {
    try {
      await import(url);
      if (customElements.get("model-viewer")) return true;
    } catch (_error) {
      // Try the next source. The plan view does not need this script.
    }
  }
  return false;
}

class HomeScannerCard extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: "open" });
    this._config = {};
    this._hass = null;
    this._rooms = [];
    this._slug = null;
    this._home = null;
    this._mode = "plan";
    this._status = "Loading rooms…";
    this._hits = [];
    this._booted = false;
    this._floor = undefined;
    this._focusRoomId = null;
    this._plates = null;
    this._plateRequest = 0;
    this._configView = undefined;
  }

  setConfig(config) {
    if (!config || typeof config !== "object") {
      throw new Error("Home Scanner card needs a configuration.");
    }
    const view = config.view === "model" || config.view === "photo" || config.view === "plan" ? config.view : null;
    if (view && view !== this._configView) this._mode = view;
    this._configView = view;
    this._config = config;
    this._fixedRooms = configuredRooms(config);
    if (this._fixedRooms && this._fixedRooms.length === 1) {
      this._slug = this._fixedRooms[0].slug;
    }
  }

  set hass(hass) {
    this._hass = hass;
    if (!this._booted) {
      this._booted = true;
      this._boot();
    } else {
      this._render();
    }
  }

  getCardSize() {
    return 8;
  }

  async _boot() {
    await this._loadRooms();
    if (this._slug) await this._open(this._slug);
    else this._render();
  }

  async _loadRooms() {
    if (this._fixedRooms) {
      this._rooms = this._fixedRooms;
      if (!this._slug && this._rooms.length) this._slug = this._rooms[0].slug;
      return;
    }
    this._rooms = await discoverRooms(this._hass);
    if (!this._slug && this._rooms.length) this._slug = this._rooms[0].slug;
    if (!this._rooms.length) {
      this._status = "No rooms under /local/home_scanner yet. Send a scan from the iPhone, or list slugs in the card config.";
    }
  }

  async _open(slug) {
    this._slug = slug;
    this._floor = undefined;
    this._focusRoomId = null;
    this._plates = null;
    this._plateRequest += 1;
    this._status = "Loading layout…";
    this._render();
    try {
      this._home = await loadLayout(slug);
      this._status = "";
      if (this._mode === "model") await this._showModel();
      if (this._mode === "photo") await this._loadPlates();
    } catch (error) {
      this._home = null;
      this._status = error.message || "Could not read layout.json.";
    }
    this._render();
  }

  async _setMode(mode) {
    if (mode === "model") {
      await this._showModel();
      return;
    }
    this._mode = mode;
    if (mode === "photo") await this._loadPlates();
    else this._render();
  }

  _focusedRoom() {
    const rooms = this._home && Array.isArray(this._home.rooms) ? this._home.rooms : [];
    return focusedRoom(rooms, this._floor, this._focusRoomId);
  }

  async _loadPlates() {
    const slug = plateSlugFor(this._slug, this._home, this._focusedRoom());
    this._plateRequest += 1;
    const request = this._plateRequest;
    if (!slug) {
      this._plates = null;
      this._render();
      return;
    }
    try {
      const plates = await loadPlates(slug);
      if (request !== this._plateRequest) return;
      this._plates = plates;
    } catch (_error) {
      if (request !== this._plateRequest) return;
      this._plates = null;
    }
    this._render();
  }

  async _showModel() {
    const ready = await ensureModelViewer();
    this._modelReady = ready;
    this._mode = "model";
    this._render();
  }

  _daylight(now = new Date()) {
    const sun = this._hass && this._hass.states ? this._hass.states["sun.sun"] : null;
    return daylightFromSun(sun, now);
  }

  _render() {
    this._tint = this._daylight();
    const title = this._config.title || "Home Scanner";
    const root = this.shadowRoot;
    if (!root.querySelector("style")) {
      root.innerHTML = `
        <style>
          :host { display: block; }
          .card {
            background: var(--ha-card-background, var(--card-background-color, #fff));
            color: var(--primary-text-color, #1c1917);
            border-radius: var(--ha-card-border-radius, 12px);
            padding: 12px;
            box-shadow: var(--ha-card-box-shadow, none);
          }
          h2 { margin: 0 0 8px; font-size: 1.05rem; font-weight: 650; }
          .rooms, .tabs, .floors, .focus { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 8px; }
          .floors:empty, .focus:empty { display: none; }
          button {
            border: 1px solid var(--divider-color, #d9d0c3);
            background: transparent;
            color: inherit;
            border-radius: 999px;
            padding: 4px 10px;
            font: inherit;
            cursor: pointer;
          }
          button[aria-pressed="true"] {
            background: var(--primary-color, #1f6b5a);
            color: var(--text-primary-color, #fff);
            border-color: transparent;
          }
          canvas, model-viewer {
            width: 100%;
            height: 320px;
            background: #100e0c;
            border-radius: 10px;
            display: block;
          }
          canvas[hidden], .model[hidden], .photo[hidden] { display: none !important; }
          .photo {
            width: 100%;
            height: 320px;
            background: #100e0c;
            border-radius: 10px;
            display: flex;
            align-items: center;
            justify-content: center;
            overflow: hidden;
          }
          .stage { position: relative; width: min(100%, calc(320px * 16 / 9)); max-height: 100%; }
          .stage img.base { width: 100%; height: auto; display: block; }
          .glow {
            position: absolute;
            inset: 0;
            mix-blend-mode: screen;
            pointer-events: none;
            -webkit-mask-size: 100% 100%;
            mask-size: 100% 100%;
            -webkit-mask-repeat: no-repeat;
            mask-repeat: no-repeat;
          }
          button.region {
            position: absolute;
            transform: translate(-50%, -50%);
            border-radius: 50%;
            background: transparent;
            border: none;
            padding: 0;
            min-width: 0;
          }
          .status, .hint, .daylight { color: var(--secondary-text-color, #5c564e); font-size: 0.85rem; }
          .daylight { margin: 6px 0 0; }
          button.hotspot {
            background: rgba(244, 239, 230, 0.94);
            border: none;
            border-radius: 999px;
            color: #100e0c;
            font: inherit;
            font-size: 12px;
            padding: 2px 8px;
          }
          ul { list-style: none; padding: 0; margin: 8px 0 0; }
          li { display: flex; justify-content: space-between; gap: 8px; padding: 4px 0; }
          .swatch { width: 10px; height: 10px; border-radius: 50%; display: inline-block; margin-right: 6px; }
        </style>
        <div class="card">
          <h2></h2>
          <div class="floors"></div>
          <div class="rooms"></div>
          <div class="focus"></div>
          <div class="tabs"></div>
          <canvas width="640" height="360" hidden></canvas>
          <div class="model"></div>
          <div class="photo" hidden></div>
          <p class="status"></p>
          <p class="daylight"></p>
          <ul class="pins"></ul>
          <p class="hint"></p>
        </div>
      `;
      root.querySelector("canvas").addEventListener("click", (event) => this._onCanvasClick(event));
    }
    root.querySelector("h2").textContent = title;
    const homeRooms = this._home && Array.isArray(this._home.rooms) ? this._home.rooms : [];
    const multi = homeRooms.length > 1;
    const choices = floorChoices(multi ? homeRooms : this._rooms);
    const floor = activeFloor(choices, this._floor);
    const floors = root.querySelector(".floors");
    floors.replaceChildren();
    for (const choice of choices) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = choice.name;
      button.setAttribute("aria-pressed", choice.level === floor ? "true" : "false");
      button.addEventListener("click", () => {
        this._floor = choice.level;
        this._focusRoomId = null;
        if (this._mode === "photo") this._loadPlates();
        else this._render();
      });
      floors.append(button);
    }
    const rooms = root.querySelector(".rooms");
    rooms.replaceChildren();
    const folders = foldersOnFloor(this._rooms, floor, !multi && choices.length > 0);
    for (const room of folders) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = room.name || room.slug;
      button.setAttribute("aria-pressed", room.slug === this._slug ? "true" : "false");
      button.addEventListener("click", () => this._open(room.slug));
      rooms.append(button);
    }
    const focus = root.querySelector(".focus");
    focus.replaceChildren();
    if (multi) {
      const visible = choices.length ? roomsOnFloor(homeRooms, floor) : homeRooms;
      const current = this._focusedRoom();
      for (const room of visible) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = room.name || "Room";
        button.setAttribute("aria-pressed", current && current.id === room.id ? "true" : "false");
        button.addEventListener("click", () => {
          this._focusRoomId = room.id;
          if (this._mode === "photo") this._loadPlates();
          else this._render();
        });
        focus.append(button);
      }
    }
    const tabs = root.querySelector(".tabs");
    tabs.replaceChildren();
    if (this._slug) {
      const labels = { plan: "Plan", model: "3D", photo: "Photo" };
      for (const mode of ["plan", "model", "photo"]) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = labels[mode];
        button.setAttribute("aria-pressed", this._mode === mode ? "true" : "false");
        button.addEventListener("click", () => this._setMode(mode));
        tabs.append(button);
      }
    }
    const canvas = root.querySelector("canvas");
    const modelHost = root.querySelector(".model");
    const photoHost = root.querySelector(".photo");
    canvas.hidden = this._mode !== "plan" || !this._home;
    modelHost.hidden = this._mode !== "model";
    photoHost.hidden = this._mode !== "photo";
    if (this._mode === "model") this._mountModel(modelHost);
    else modelHost.replaceChildren();
    if (this._mode === "photo") this._syncPhoto(photoHost);
    else {
      photoHost.replaceChildren();
      delete photoHost.dataset.key;
    }
    root.querySelector(".status").textContent = this._status || "";
    const daylightLine = root.querySelector(".daylight");
    if (daylightLine) {
      daylightLine.textContent = this._home && !this._status ? daylightLabel(this._tint) : "";
    }
    this._renderPins(root.querySelector(".pins"));
    const hint = root.querySelector(".hint");
    hint.textContent = this._home && !sceneGeometry(this._home).unified
      ? "This folder has more than one room and the scans are not in one coordinate space. Open a room slug to put pins on that room's model."
      : "";
    if (this._mode === "plan") this._draw();
  }

  _mountModel(host) {
    if (!this._slug || !this._home) {
      host.replaceChildren();
      return;
    }
    if (!this._modelReady) {
      host.textContent = "The 3D view needs model-viewer.min.js next to this card, or a network path to the model-viewer script. The plan still shows the room.";
      return;
    }
    const geometry = sceneGeometry(this._home);
    let viewer = host.querySelector("model-viewer");
    const src = fileURL(this._slug, "model.glb");
    if (!viewer) {
      host.replaceChildren();
      viewer = document.createElement("model-viewer");
      viewer.setAttribute("camera-controls", "");
      viewer.setAttribute("touch-action", "pan-y");
      viewer.setAttribute("alt", "Room model");
      host.append(viewer);
    }
    if (viewer.getAttribute("src") !== src) viewer.setAttribute("src", src);
    const tint = this._tint || daylightFromClock(new Date());
    viewer.style.background = daylightBackground(tint);
    const exposure = (0.28 + tint.key * 1.05).toFixed(3);
    viewer.setAttribute("exposure", exposure);
    viewer.exposure = Number(exposure);
    const shadow = (0.15 + 0.45 * tint.key).toFixed(3);
    viewer.setAttribute("shadow-intensity", shadow);
    if ("shadowIntensity" in viewer) viewer.shadowIntensity = Number(shadow);
    const environment = daylightEnvironment(tint);
    if (viewer.getAttribute("environment-image") !== environment) {
      viewer.setAttribute("environment-image", environment);
    }
    for (const node of [...viewer.querySelectorAll(".hotspot")]) node.remove();
    if (!geometry.unified) return;
    for (const pin of this._home.pins || []) {
      const position = pin.position || {};
      const button = document.createElement("button");
      button.type = "button";
      button.className = "hotspot";
      button.slot = `hotspot-${pin.id || pin.entity_id || pin.name}`;
      button.dataset.position = `${position.x || 0} ${position.y || 0} ${position.z || 0}`;
      button.dataset.normal = "0 1 0";
      button.textContent = pin.name || pin.entity_id || "Device";
      const stateObj = pin.entity_id && this._hass ? this._hass.states[pin.entity_id] : null;
      const domain = pin.entity_id ? pin.entity_id.split(".")[0] : "";
      if (stateObj && domain === "light" && stateObj.state === "on") {
        const style = lightStyle(stateObj);
        button.style.background = style.fill;
        button.style.boxShadow = `0 0 12px 2px ${style.fill}`;
        button.style.color = "#100e0c";
      }
      if (pin.entity_id) {
        button.addEventListener("click", (event) => {
          event.preventDefault();
          this._toggle(pin.entity_id);
        });
      }
      viewer.append(button);
    }
    this._applyCamera(viewer, geometry);
  }

  _applyCamera(viewer, geometry) {
    const room = this._focusedRoom();
    const viewpoint = room && room.viewpoint;
    if (!viewpoint || !room) return;
    const count = this._home && Array.isArray(this._home.rooms) ? this._home.rooms.length : 0;
    // A combined model that is not in one coordinate space is not this room's camera.
    if (count > 1 && !geometry.unified) return;
    const frame = geometry.byRoom.get(room.id);
    const offset = frame && frame.unified === false ? { x: frame.ox, z: frame.oz } : { x: 0, z: 0 };
    const orbit = cameraOrbit(viewpoint, offset);
    const key = `${room.id}|${orbit.orbit}|${orbit.target}|${orbit.fieldOfView}`;
    if (viewer.dataset.orbitKey === key) return;
    viewer.dataset.orbitKey = key;
    viewer.setAttribute("camera-orbit", orbit.orbit);
    viewer.setAttribute("camera-target", orbit.target);
    viewer.setAttribute("field-of-view", `${trimNumber(orbit.fieldOfView)}deg`);
    if ("cameraOrbit" in viewer) viewer.cameraOrbit = orbit.orbit;
    if ("cameraTarget" in viewer) viewer.cameraTarget = orbit.target;
    if ("fieldOfView" in viewer) viewer.fieldOfView = `${trimNumber(orbit.fieldOfView)}deg`;
  }

  _syncPhoto(host) {
    const manifest = this._plates;
    const variant = plateVariant(this._tint);
    const set = manifest && manifest[variant];
    const slug = plateSlugFor(this._slug, this._home, this._focusedRoom());
    if (!manifest || !set || !set.base || !slug) {
      host.replaceChildren();
      delete host.dataset.key;
      const note = document.createElement("p");
      note.className = "status";
      note.textContent = "No photo plates for this room yet. Save a viewpoint in the app and send the room again. Plan and 3D still work.";
      host.append(note);
      return;
    }
    const key = `${slug}|${variant}|${manifest.room_id || ""}|${set.base}`;
    if (host.dataset.key !== key) {
      host.dataset.key = key;
      host.replaceChildren();
      const stage = document.createElement("div");
      stage.className = "stage";
      const width = Number(manifest.width) || 16;
      const height = Number(manifest.height) || 9;
      stage.style.aspectRatio = `${width} / ${height}`;
      const base = document.createElement("img");
      base.className = "base";
      base.alt = "";
      base.src = fileURL(slug, set.base);
      stage.append(base);
      for (const light of set.lights || []) {
        const glow = document.createElement("div");
        glow.className = "glow";
        glow.dataset.pin = light.pin_id || light.file;
        const mask = `url("${fileURL(slug, light.file)}")`;
        glow.style.webkitMaskImage = mask;
        glow.style.maskImage = mask;
        stage.append(glow);
        if (light.region && light.entity_id) {
          const button = document.createElement("button");
          button.type = "button";
          button.className = "region";
          button.style.left = `${light.region.x * 100}%`;
          button.style.top = `${light.region.y * 100}%`;
          button.style.width = `${Math.max(light.region.radius * 2, 0.08) * 100}%`;
          button.style.height = `${Math.max(light.region.radius * 2, 0.08) * 100}%`;
          button.setAttribute("aria-label", light.entity_id);
          button.addEventListener("click", (event) => {
            event.preventDefault();
            this._toggle(light.entity_id);
          });
          stage.append(button);
        }
      }
      host.append(stage);
    }
    const stage = host.querySelector(".stage");
    if (!stage) return;
    for (const light of set.lights || []) {
      const pin = light.pin_id || light.file;
      const glow = [...stage.querySelectorAll(".glow")].find((node) => node.dataset.pin === pin);
      if (!glow) continue;
      const stateObj = light.entity_id && this._hass ? this._hass.states[light.entity_id] : null;
      const style = plateStyle(stateObj);
      glow.style.opacity = String(style.opacity);
      glow.style.backgroundColor = style.color;
    }
  }

  _renderPins(list) {
    list.replaceChildren();
    if (!this._home) return;
    for (const pin of this._home.pins || []) {
      const item = document.createElement("li");
      const name = document.createElement("span");
      const stateObj = pin.entity_id && this._hass ? this._hass.states[pin.entity_id] : null;
      const style = stateObj ? lightStyle(stateObj) : { fill: "#8aa39a", label: pin.entity_id || "" };
      const swatch = document.createElement("span");
      swatch.className = "swatch";
      swatch.style.background = style.fill;
      name.append(swatch, document.createTextNode(pin.name || "Device"));
      item.append(name);
      if (pin.entity_id && stateObj && TOGGLE_DOMAINS.has(pin.entity_id.split(".")[0])) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = stateObj.state === "on" ? "Turn off" : "Turn on";
        button.addEventListener("click", () => this._toggle(pin.entity_id));
        item.append(button);
      } else {
        const label = document.createElement("span");
        label.textContent = style.label;
        item.append(label);
      }
      list.append(item);
    }
  }

  _toggle(entityId) {
    if (!this._hass || !entityId) return;
    const domain = entityId.split(".")[0];
    if (!TOGGLE_DOMAINS.has(domain)) return;
    this._hass.callService(domain, "toggle", { entity_id: entityId });
  }

  _draw() {
    const canvas = this.shadowRoot.querySelector("canvas");
    if (!canvas || !this._home || this._mode !== "plan") return;
    const width = canvas.clientWidth || 640;
    const height = canvas.clientHeight || 320;
    const ratio = window.devicePixelRatio || 1;
    canvas.width = Math.round(width * ratio);
    canvas.height = Math.round(height * ratio);
    const context = canvas.getContext("2d");
    context.setTransform(ratio, 0, 0, ratio, 0, 0);
    context.clearRect(0, 0, width, height);
    const tint = this._tint || daylightFromClock(new Date());
    context.fillStyle = daylightBackground(tint);
    context.fillRect(0, 0, width, height);
    const geometry = sceneGeometry(this._home);
    const box = geometry.bounds;
    const pad = 24;
    const scale = Math.min(
      (width - pad * 2) / Math.max(box.maxX - box.minX, 0.2),
      (height - pad * 2) / Math.max(box.maxZ - box.minZ, 0.2)
    );
    const project = (x, z) => ({
      x: pad + (x - box.minX) * scale,
      y: pad + (z - box.minZ) * scale,
    });
    context.lineWidth = 2;
    context.strokeStyle = daylightStroke(tint);
    context.fillStyle = "rgba(232, 224, 212, 0.08)";
    for (const frame of geometry.frames) {
      const plan = frame.room.floor_plan || {};
      for (const floor of plan.floors || []) {
        const corners = floor.corners || [];
        if (corners.length < 3) continue;
        context.beginPath();
        corners.forEach((corner, index) => {
          const point = project(corner.x + frame.ox, corner.z + frame.oz);
          if (index === 0) context.moveTo(point.x, point.y);
          else context.lineTo(point.x, point.y);
        });
        context.closePath();
        context.fill();
      }
      for (const wall of plan.walls || []) {
        if (!wall.start || !wall.end) continue;
        const start = project(wall.start.x + frame.ox, wall.start.z + frame.oz);
        const end = project(wall.end.x + frame.ox, wall.end.z + frame.oz);
        context.beginPath();
        context.moveTo(start.x, start.y);
        context.lineTo(end.x, end.y);
        context.stroke();
      }
    }
    this._hits = [];
    context.font = "12px sans-serif";
    for (const pin of this._home.pins || []) {
      const frame = geometry.byRoom.get(pin.room_id);
      const position = pin.position || {};
      const point = project((position.x || 0) + (frame ? frame.ox : 0), (position.z || 0) + (frame ? frame.oz : 0));
      const stateObj = pin.entity_id && this._hass ? this._hass.states[pin.entity_id] : null;
      const style = stateObj ? lightStyle(stateObj) : { fill: "#45c9a5", label: "" };
      context.beginPath();
      context.fillStyle = style.fill;
      context.arc(point.x, point.y, 7, 0, Math.PI * 2);
      context.fill();
      context.fillStyle = "#f4efe6";
      context.fillText(pin.name || "", point.x + 10, point.y + 4);
      this._hits.push({ x: point.x, y: point.y, entityId: pin.entity_id || null });
    }
  }

  _onCanvasClick(event) {
    const rect = event.currentTarget.getBoundingClientRect();
    const x = event.clientX - rect.left;
    const y = event.clientY - rect.top;
    const hit = this._hits.find((pin) => (pin.x - x) ** 2 + (pin.y - y) ** 2 <= 16 ** 2);
    if (hit?.entityId) this._toggle(hit.entityId);
  }
}

if (!customElements.get("home-scanner-card")) {
  customElements.define("home-scanner-card", HomeScannerCard);
}

window.customCards = window.customCards || [];
if (!window.customCards.some((card) => card.type === "home-scanner-card")) {
  window.customCards.push({
    type: "home-scanner-card",
    name: "Home Scanner",
    description: "Rooms uploaded by the Home Scanner app, with the floor plan, model, and photo plates.",
    preview: false,
  });
}

export {
  daylightFromClock,
  daylightFromSun,
  daylightTint,
  floorChoices,
  roomsOnFloor,
  activeFloor,
  foldersOnFloor,
  focusedRoom,
  plateSlugFor,
  cameraOrbit,
  plateVariant,
  plateStyle,
  hitRegion,
};
