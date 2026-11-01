/** Paths the home_scanner integration serves under /local/home_scanner/. */

const ROOM_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$/;

export function isSafeRoomId(id) {
  return typeof id === "string" && ROOM_ID.test(id) && !id.includes("..");
}

export function joinUrl(base, ...parts) {
  const trimmed = String(base || "").replace(/\/+$/, "");
  const suffix = parts.map((part) => encodeURIComponent(part)).join("/");
  if (!trimmed) return suffix;
  return `${trimmed}/${suffix}`;
}

export function roomsManifestUrl(base) {
  return joinUrl(base, "rooms.json");
}

export function roomAssetUrls(base, roomId) {
  if (!isSafeRoomId(roomId)) {
    throw new Error("room must be a folder name, not a path");
  }
  return {
    layout: joinUrl(base, roomId, "layout.json"),
    model: joinUrl(base, roomId, "model.glb"),
  };
}

function roomRecord(entry) {
  if (typeof entry === "string") {
    return isSafeRoomId(entry) ? { id: entry, name: entry } : null;
  }
  if (!entry || typeof entry !== "object") return null;
  const id = entry.id || entry.slug || entry.room;
  if (!isSafeRoomId(id)) return null;
  const name = entry.name || entry.title || id;
  return { id, name: String(name) };
}

export function normalizeRooms(payload) {
  const list = Array.isArray(payload) ? payload : payload?.rooms;
  if (!Array.isArray(list)) return [];
  const seen = new Set();
  const rooms = [];
  for (const entry of list) {
    const room = roomRecord(entry);
    if (!room || seen.has(room.id)) continue;
    seen.add(room.id);
    rooms.push(room);
  }
  return rooms;
}

export function mergeRooms(discovered, configuredRoom, configuredList) {
  const explicit = configuredList?.length ? normalizeRooms(configuredList) : null;
  const rooms = (explicit || discovered || []).slice();
  if (configuredRoom && isSafeRoomId(configuredRoom) && !rooms.some((room) => room.id === configuredRoom)) {
    rooms.unshift({ id: configuredRoom, name: configuredRoom });
  }
  return rooms;
}

export function initialRoomId(rooms, configuredRoom) {
  if (configuredRoom && rooms.some((room) => room.id === configuredRoom)) return configuredRoom;
  return rooms[0]?.id || null;
}

export function shouldShowRoomPicker(rooms) {
  return rooms.length > 1;
}
