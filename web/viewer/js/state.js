/** Mock HomeStateProvider, matching RoomScanCore's sample seed and toggle rules. */

export const TOGGLEABLE = new Set(["light", "switch", "fan"]);

const TOKEN = /^[a-z_][a-z0-9_]*$/;

export const SAMPLE_SEED = [
  { entity_id: "light.kitchen", state: "on", domain: "light", unit: null, friendly_name: "Kitchen light" },
  { entity_id: "light.living_room", state: "off", domain: "light", unit: null, friendly_name: "Living room light" },
  { entity_id: "switch.living_room", state: "on", domain: "switch", unit: null, friendly_name: "Living room switch" },
  {
    entity_id: "sensor.living_room_temperature",
    state: "21.5",
    domain: "sensor",
    unit: "°C",
    friendly_name: "Living room temperature",
  },
];

export function canonicalEntityId(raw) {
  if (raw == null) return { unset: true };
  const value = String(raw).trim().toLowerCase();
  if (!value) return { unset: true };
  const parts = value.split(".");
  if (parts.length !== 2 || !TOKEN.test(parts[0]) || !TOKEN.test(parts[1])) {
    return { invalid: String(raw).trim() };
  }
  return { id: value, domain: parts[0] };
}

export function formatState(snapshot) {
  if (!snapshot) return "unavailable";
  if (snapshot.unit) return `${snapshot.state} ${snapshot.unit}`;
  return String(snapshot.state).replaceAll("_", " ");
}

export function isToggleable(snapshot) {
  return Boolean(snapshot && TOGGLEABLE.has(snapshot.domain));
}

export function isOn(snapshot) {
  return snapshot?.state === "on";
}

export function pinColor(snapshot) {
  if (!snapshot) return "#8a8175";
  const state = snapshot.state;
  if (state === "unavailable" || state === "unknown") return "#6b645c";
  if (state === "on" || state === "open" || state === "unlocked" || state === "heat" || state === "cool") {
    return snapshot.domain === "light" ? "#f0a202" : "#3cbe86";
  }
  if (state === "off" || state === "closed" || state === "locked") return "#8d8680";
  return "#7eb6d6";
}

export function createMockState(seed = SAMPLE_SEED) {
  const states = new Map(seed.map((item) => [item.entity_id, { ...item }]));

  function snapshot(raw) {
    const parsed = canonicalEntityId(raw);
    if (parsed.unset || parsed.invalid) {
      const shown = parsed.invalid || raw || "";
      throw new Error(`${shown} is not a Home Assistant entity id. Use the form light.kitchen.`);
    }
    if (states.has(parsed.id)) return { ...states.get(parsed.id) };
    const created = {
      entity_id: parsed.id,
      state: TOGGLEABLE.has(parsed.domain) ? "off" : "unknown",
      domain: parsed.domain,
      unit: null,
      friendly_name: null,
    };
    states.set(parsed.id, created);
    return { ...created };
  }

  function toggle(raw) {
    const current = snapshot(raw);
    if (!isToggleable(current)) {
      throw new Error(`${current.entity_id} can't be toggled from here.`);
    }
    const next = { ...current, state: current.state === "on" ? "off" : "on" };
    states.set(next.entity_id, next);
    return { ...next };
  }

  return { snapshot, toggle };
}

export function snapshotFromHass(hass, entityId) {
  const parsed = canonicalEntityId(entityId);
  if (!parsed.id) return null;
  const entity = hass?.states?.[parsed.id];
  if (!entity) {
    return {
      entity_id: parsed.id,
      state: "unavailable",
      domain: parsed.domain,
      unit: null,
      friendly_name: null,
    };
  }
  return {
    entity_id: parsed.id,
    state: entity.state,
    domain: parsed.domain,
    unit: entity.attributes?.unit_of_measurement || null,
    friendly_name: entity.attributes?.friendly_name || null,
  };
}
