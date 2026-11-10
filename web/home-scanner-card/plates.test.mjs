// Floor picker, saved camera, and photo-plate blending. Run with:
// node web/home-scanner-card/plates.test.mjs
import assert from "node:assert/strict";

globalThis.HTMLElement = class {};
globalThis.customElements = { get: () => false, define() {} };
globalThis.window = globalThis;

const {
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
} = await import("./home-scanner-card.js");

const choices = floorChoices([
  { id: "loft", floor: 1 },
  { id: "hall" },
  { id: "kitchen", floor: 0 },
  { id: "study", floor: 1 },
]);
assert.deepEqual(choices.map((choice) => choice.level), [0, 1, null]);
assert.equal(choices[0].name, "Floor 0");
assert.equal(choices[2].name, "No floor");
assert.deepEqual(floorChoices([{ id: "only" }]), []);
assert.equal(activeFloor(choices, undefined), 0);
assert.equal(activeFloor(choices, 1), 1);
assert.equal(activeFloor(choices, null), null);
assert.deepEqual(roomsOnFloor([{ id: "a", floor: 0 }, { id: "b" }, { id: "c", floor: 1 }], 0).map((room) => room.id), ["a"]);
assert.deepEqual(roomsOnFloor([{ id: "a", floor: 0 }, { id: "b" }], null).map((room) => room.id), ["b"]);

const folders = [
  { slug: "home", floor: null },
  { slug: "kitchen", floor: 0 },
  { slug: "loft", floor: 1 },
];
assert.equal(foldersOnFloor(folders, 0, false).length, 3);
assert.deepEqual(foldersOnFloor(folders, 0, true).map((folder) => folder.slug), ["kitchen"]);

const rooms = [
  { id: "kitchen", floor: 0, name: "Kitchen" },
  { id: "loft", floor: 1, name: "Loft" },
];
assert.equal(focusedRoom(rooms, undefined, null).id, "kitchen");
assert.equal(focusedRoom(rooms, 1, null).id, "loft");
assert.equal(focusedRoom(rooms, 0, "kitchen").id, "kitchen");
assert.equal(focusedRoom([{ id: "only" }], 0, null).id, "only");
assert.equal(plateSlugFor("home-slug", { rooms }, { id: "loft" }), "loft");
assert.equal(plateSlugFor("room-slug", { rooms: [{ id: "only" }] }, { id: "only" }), "room-slug");

const orbit = cameraOrbit({
  position: { x: 0, y: 2, z: 5 },
  target: { x: 0, y: 1, z: 0 },
  field_of_view: 48,
});
assert.equal(orbit.theta, 0);
assert.ok(Math.abs(orbit.radius - Math.hypot(1, 5)) < 1e-9);
assert.ok(Math.abs(orbit.phi - Math.acos(1 / orbit.radius)) < 1e-9);
assert.equal(orbit.fieldOfView, 48);
assert.equal(orbit.target, "0m 1m 0m");
const shifted = cameraOrbit({
  position: { x: 0, y: 2, z: 5 },
  target: { x: 0, y: 1, z: 0 },
  field_of_view: 48,
}, { x: 4, z: -1 });
assert.equal(shifted.target, "4m 1m -1m");
assert.equal(shifted.theta, 0);

const night = daylightFromSun({ state: "below_horizon", attributes: {} }, new Date("2026-06-21T12:00:00Z"));
assert.equal(plateVariant(night), "night");
assert.equal(plateVariant(daylightTint(48, true)), "day");
assert.equal(plateVariant(daylightTint(0, true)), "day");
assert.equal(plateVariant(daylightTint(-90, false)), "night");

const on = plateStyle({
  entity_id: "light.kitchen",
  state: "on",
  attributes: { brightness: 128, rgb_color: [0, 0, 255] },
});
assert.ok(Math.abs(on.opacity - 128 / 255) < 1e-9);
assert.equal(on.color, "rgb(0, 0, 255)");
assert.equal(plateStyle({ entity_id: "light.kitchen", state: "off", attributes: { brightness: 255 } }).opacity, 0);
assert.equal(plateStyle(null).opacity, 0);

const regions = [
  { x: 0.5, y: 0.5, radius: 0.1, entity_id: "light.a" },
  { x: 0.8, y: 0.2, radius: 0.05, entity_id: "light.b" },
];
assert.equal(hitRegion(regions, 0.52, 0.48).entity_id, "light.a");
assert.equal(hitRegion(regions, 0.1, 0.1), null);
assert.equal(hitRegion(regions, 0.8, 0.2).entity_id, "light.b");

console.log("floor, camera, and photo plate helpers match the card");
