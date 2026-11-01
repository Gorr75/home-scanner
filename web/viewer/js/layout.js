/** Read a roomscan.home document. Readers reject a different format or version. */

export const FORMAT = "roomscan.home";
export const VERSION = 1;

export function parseLayout(data) {
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    throw new Error("This file is not a Home Scanner layout.");
  }
  if (data.format !== FORMAT) {
    const found = data.format == null ? "unrecognized" : String(data.format);
    throw new Error(`This file is ${found}, not a Home Scanner layout.`);
  }
  if (data.version !== VERSION) {
    throw new Error(
      `This Home Scanner layout uses format version ${data.version}, which this viewer does not read.`,
    );
  }
  if (!data.home || !Array.isArray(data.home.pins) || !Array.isArray(data.home.rooms)) {
    throw new Error("Layout is missing home.rooms or home.pins.");
  }
  return data;
}

export async function fetchLayout(url) {
  const response = await fetch(url, { cache: "no-cache" });
  if (!response.ok) {
    throw new Error(`Could not read layout (${response.status}) at ${url}`);
  }
  let data;
  try {
    data = await response.json();
  } catch {
    throw new Error(`Layout at ${url} is not JSON.`);
  }
  return parseLayout(data);
}

function finite(value, fallback = 0) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function roomName(doc, roomId) {
  if (!roomId) return null;
  const room = doc.home.rooms.find((item) => item.id === roomId);
  return room?.name || null;
}

export function readPins(doc) {
  const pins = [];
  const skipped = [];
  for (const pin of doc.home.pins) {
    const position = pin?.position;
    if (!position || !["x", "y", "z"].every((key) => Number.isFinite(Number(position[key])))) {
      skipped.push(pin?.name || pin?.id || "pin");
      continue;
    }
    pins.push({
      id: String(pin.id || pins.length),
      roomId: pin.room_id ?? null,
      roomName: roomName(doc, pin.room_id),
      name: pin.name || "Device",
      kind: pin.kind || "other",
      entityId: pin.entity_id ?? null,
      position: {
        x: finite(position.x),
        y: finite(position.y),
        z: finite(position.z),
      },
    });
  }
  return { pins, skipped };
}

export function layoutSummary(doc) {
  const home = doc.home;
  const structure = home.structure;
  const unified = !structure || structure.coordinates_are_unified !== false;
  let warning = null;
  if (structure && structure.coordinates_are_unified === false) {
    warning =
      "Pins stay in each room's scan space. This shell is a different coordinate space, so a pin may not sit on the model.";
  }
  return {
    name: home.name || "Home",
    unified,
    warning,
  };
}
