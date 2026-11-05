// Home Scanner Lovelace card.
// Reads /local/home_scanner/<slug>/layout.json and model.glb.
// Install notes: README.md in this folder.

const LOCAL_ROOT = "/local/home_scanner";
const TOGGLE_DOMAINS = new Set(["light", "switch", "fan"]);

function configuredRooms(config) {
  if (Array.isArray(config.rooms) && config.rooms.length) {
    return config.rooms
      .map((room) => {
        const slug = String(room.slug || room.id || "").trim();
        if (!slug) return null;
        return {
          slug,
          name: room.name || slug,
          path: `${LOCAL_ROOT}/${slug}/`,
        };
      })
      .filter(Boolean);
  }
  if (config.slug) {
    const slug = String(config.slug).trim();
    return [{ slug, name: config.name || slug, path: `${LOCAL_ROOT}/${slug}/` }];
  }
  return null;
}

async function discoverRooms(hass) {
  if (hass && typeof hass.callApi === "function") {
    try {
      const index = await hass.callApi("GET", "home_scanner/rooms");
      if (index && Array.isArray(index.rooms)) return index.rooms;
    } catch (_error) {
      // The integration may be older than the card. Fall through to index.json.
    }
  }
  try {
    const response = await fetch(`${LOCAL_ROOT}/index.json`, { cache: "no-store" });
    if (!response.ok) return [];
    const index = await response.json();
    return Array.isArray(index.rooms) ? index.rooms : [];
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
  }

  setConfig(config) {
    if (!config || typeof config !== "object") {
      throw new Error("Home Scanner card needs a configuration.");
    }
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
    this._status = "Loading layout…";
    this._render();
    try {
      this._home = await loadLayout(slug);
      this._status = "";
      if (this._mode === "model") await this._showModel();
    } catch (error) {
      this._home = null;
      this._status = error.message || "Could not read layout.json.";
    }
    this._render();
  }

  async _showModel() {
    const ready = await ensureModelViewer();
    this._modelReady = ready;
    this._mode = "model";
    this._render();
  }

  _render() {
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
          .rooms, .tabs { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 8px; }
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
          .status, .hint { color: var(--secondary-text-color, #5c564e); font-size: 0.85rem; }
          ul { list-style: none; padding: 0; margin: 8px 0 0; }
          li { display: flex; justify-content: space-between; gap: 8px; padding: 4px 0; }
          .swatch { width: 10px; height: 10px; border-radius: 50%; display: inline-block; margin-right: 6px; }
        </style>
        <div class="card">
          <h2></h2>
          <div class="rooms"></div>
          <div class="tabs"></div>
          <canvas width="640" height="360" hidden></canvas>
          <div class="model"></div>
          <p class="status"></p>
          <ul class="pins"></ul>
          <p class="hint"></p>
        </div>
      `;
      root.querySelector("canvas").addEventListener("click", (event) => this._onCanvasClick(event));
    }
    root.querySelector("h2").textContent = title;
    const rooms = root.querySelector(".rooms");
    rooms.replaceChildren();
    for (const room of this._rooms) {
      const button = document.createElement("button");
      button.type = "button";
      button.textContent = room.name || room.slug;
      button.setAttribute("aria-pressed", room.slug === this._slug ? "true" : "false");
      button.addEventListener("click", () => this._open(room.slug));
      rooms.append(button);
    }
    const tabs = root.querySelector(".tabs");
    tabs.replaceChildren();
    if (this._slug) {
      for (const mode of ["plan", "model"]) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = mode === "plan" ? "Plan" : "3D";
        button.setAttribute("aria-pressed", this._mode === mode ? "true" : "false");
        button.addEventListener("click", () => {
          if (mode === "model") this._showModel();
          else {
            this._mode = "plan";
            this._render();
          }
        });
        tabs.append(button);
      }
    }
    const canvas = root.querySelector("canvas");
    const modelHost = root.querySelector(".model");
    canvas.hidden = this._mode !== "plan" || !this._home;
    modelHost.hidden = this._mode !== "model";
    if (this._mode === "model") this._mountModel(modelHost);
    else modelHost.replaceChildren();
    root.querySelector(".status").textContent = this._status || "";
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
      if (pin.entity_id) {
        button.addEventListener("click", (event) => {
          event.preventDefault();
          this._toggle(pin.entity_id);
        });
      }
      viewer.append(button);
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
    context.fillStyle = "#100e0c";
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
    context.strokeStyle = "#e8e0d4";
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
    description: "Rooms uploaded by the Home Scanner app, with the floor plan and model.glb.",
    preview: false,
  });
}
