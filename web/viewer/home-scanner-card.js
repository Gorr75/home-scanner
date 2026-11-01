import { mountViewer } from "./js/viewer.js";
import {
  initialRoomId,
  isSafeRoomId,
  mergeRooms,
  normalizeRooms,
  roomAssetUrls,
  roomsManifestUrl,
  shouldShowRoomPicker,
} from "./js/rooms.js";
import { canonicalEntityId, isToggleable, snapshotFromHass } from "./js/state.js";

const DEFAULT_BASE = "/local/home_scanner";

class HomeScannerCard extends HTMLElement {
  static getStubConfig() {
    return { room: "kitchen" };
  }

  setConfig(config) {
    if (!config || typeof config !== "object" || Array.isArray(config)) {
      throw new Error("Card configuration must be an object.");
    }
    if (config.room != null && !isSafeRoomId(String(config.room))) {
      throw new Error("room must be a folder name under /config/www/home_scanner, not a path.");
    }
    const rooms = config.rooms == null ? null : normalizeRooms(config.rooms);
    if (config.rooms != null && rooms.length !== config.rooms.length) {
      throw new Error("rooms entries need an id that is a safe folder name.");
    }
    this._config = {
      base: config.base || DEFAULT_BASE,
      room: config.room ? String(config.room) : null,
      rooms,
      title: config.title || null,
      layout: config.layout || null,
      model: config.model || null,
    };
    this._roomId = this._config.room;
    if (this._mounted) this._load();
  }

  set hass(hass) {
    this._hass = hass;
    this._pushStates();
    if (this._mounted && !this._discovered) this._load();
  }

  getCardSize() {
    return 10;
  }

  connectedCallback() {
    this._mount();
  }

  disconnectedCallback() {
    this._viewer?.destroy();
    this._viewer = null;
  }

  async _mount() {
    if (this._mounted) return;
    this._mounted = true;
    const cssUrl = new URL("./css/viewer.css", import.meta.url);
    const css = await fetch(cssUrl).then((response) => response.text());
    const root = this.attachShadow({ mode: "open" });
    root.innerHTML = `
      <style>${css}</style>
      <ha-card>
        <div class="app">
          <header class="top">
            <div>
              <h1 data-title>Home Scanner</h1>
              <p class="sub" data-sub>Loading room…</p>
            </div>
            <div class="files">
              <label class="room-picker" data-picker hidden>
                <span>Room</span>
                <select data-rooms></select>
              </label>
              <button type="button" class="reload" data-reload>Reload</button>
            </div>
          </header>
          <div data-viewer></div>
          <p class="banner" data-banner></p>
          <p class="error-banner" data-error hidden></p>
        </div>
      </ha-card>
    `;
    root.querySelector("[data-rooms]").addEventListener("change", (event) => {
      this._roomId = event.target.value;
      this._showCurrent();
    });
    root.querySelector("[data-reload]").addEventListener("click", () => {
      this._discovered = false;
      this._showCurrent();
    });
    if (this._config) this._load();
  }

  async _load() {
    const root = this.shadowRoot;
    if (!root || !this._config) return;
    const generation = (this._generation || 0) + 1;
    this._generation = generation;
    try {
      const discovered = this._config.rooms?.length
        ? { rooms: this._config.rooms, source: "config" }
        : await discoverRooms(this._hass, this._config.base);
      if (generation !== this._generation) return;
      this._discovered = true;
      this._rooms = mergeRooms(discovered.rooms, this._config.room, null);
      this._source = discovered.source;
      if (!this._roomId) this._roomId = initialRoomId(this._rooms, this._config.room);
      this._renderPicker();
      await this._showCurrent();
    } catch (error) {
      this._fail(error);
    }
  }

  _renderPicker() {
    const picker = this.shadowRoot.querySelector("[data-picker]");
    const select = this.shadowRoot.querySelector("[data-rooms]");
    const show = shouldShowRoomPicker(this._rooms || []);
    picker.hidden = !show;
    select.replaceChildren();
    for (const room of this._rooms || []) {
      const option = document.createElement("option");
      option.value = room.id;
      option.textContent = room.name;
      option.selected = room.id === this._roomId;
      select.append(option);
    }
  }

  async _showCurrent() {
    const root = this.shadowRoot;
    const viewerHost = root.querySelector("[data-viewer]");
    const errorNode = root.querySelector("[data-error]");
    errorNode.hidden = true;
    this._viewer?.destroy();
    this._viewer = null;
    const urls = this._urlsForSelection();
    if (!urls) {
      this._fail(
        new Error(
          "No room uploaded yet. Send a scan from Home Scanner, or set room: to a folder under /config/www/home_scanner.",
        ),
      );
      return;
    }
    const stamp = Date.now();
    try {
      this._viewer = await mountViewer(viewerHost, {
        layoutUrl: withStamp(urls.layout, stamp),
        modelUrl: withStamp(urls.model, stamp),
        mode: "live",
        onReady: (info) => {
          const title = root.querySelector("[data-title]");
          const sub = root.querySelector("[data-sub]");
          title.textContent = this._config.title || info.name;
          sub.textContent = info.warning || "Drag to orbit, scroll to zoom, click a pin.";
        },
        onToggle: (entityId) => this._toggle(entityId),
      });
      this._pushStates();
      this.dispatchEvent(new CustomEvent("scanner-ready", { bubbles: true, composed: true }));
    } catch (error) {
      this._fail(error);
    }
  }

  _urlsForSelection() {
    if (this._roomId) return roomAssetUrls(this._config.base, this._roomId);
    if (this._config.layout && this._config.model) {
      return { layout: this._config.layout, model: this._config.model };
    }
    return null;
  }

  _pushStates() {
    if (!this._viewer || !this._hass) return;
    const next = {};
    let linked = 0;
    let missing = 0;
    for (const pin of this._viewer.pins()) {
      const parsed = pin.entityId ? canonicalEntityId(pin.entityId) : null;
      if (!parsed?.id) continue;
      linked += 1;
      const snapshot = snapshotFromHass(this._hass, parsed.id);
      next[parsed.id] = snapshot;
      if (!this._hass.states?.[parsed.id]) missing += 1;
    }
    this._viewer.setStates(next);
    const banner = this.shadowRoot?.querySelector("[data-banner]");
    if (!banner) return;
    if (!linked) {
      banner.textContent = "No linked entity ids in this layout.";
    } else if (missing) {
      banner.textContent = `${missing} of ${linked} entities are missing in Home Assistant.`;
    } else {
      banner.textContent = "Entity states from Home Assistant.";
    }
  }

  async _toggle(entityId) {
    const parsed = canonicalEntityId(entityId);
    if (!parsed.id) return;
    const snapshot = snapshotFromHass(this._hass, parsed.id);
    if (!isToggleable(snapshot)) {
      throw new Error(`${parsed.id} can't be toggled from here.`);
    }
    await this._hass.callService(parsed.domain, "toggle", { entity_id: parsed.id });
  }

  _fail(error) {
    const root = this.shadowRoot;
    if (!root) return;
    const errorNode = root.querySelector("[data-error]");
    const sub = root.querySelector("[data-sub]");
    const message = error?.message || String(error);
    errorNode.hidden = false;
    errorNode.textContent = message;
    if (sub) sub.textContent = "The room model did not load.";
    this.dispatchEvent(new CustomEvent("scanner-error", { bubbles: true, composed: true, detail: message }));
  }
}

async function discoverRooms(hass, base) {
  if (hass && typeof hass.callApi === "function") {
    try {
      const body = await hass.callApi("GET", "home_scanner/rooms");
      const rooms = normalizeRooms(body);
      if (rooms.length) return { rooms, source: "api" };
    } catch {
      // The integration may only have written the static manifest.
    }
  }
  try {
    const response = await fetch(roomsManifestUrl(base), { cache: "no-cache" });
    if (response.ok) {
      const rooms = normalizeRooms(await response.json());
      if (rooms.length) return { rooms, source: "file" };
    }
  } catch {
    // No manifest yet.
  }
  return { rooms: [], source: "none" };
}

function withStamp(url, stamp) {
  const glue = url.includes("?") ? "&" : "?";
  return `${url}${glue}v=${stamp}`;
}

if (!customElements.get("home-scanner-card")) {
  customElements.define("home-scanner-card", HomeScannerCard);
}

window.customCards = window.customCards || [];
window.customCards.push({
  type: "home-scanner-card",
  name: "Home Scanner",
  description: "Orbit a scanned room and colour device pins from Home Assistant.",
  preview: false,
});
