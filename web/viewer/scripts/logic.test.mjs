import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { parseLayout, readPins } from "../js/layout.js";
import {
  initialRoomId,
  isSafeRoomId,
  joinUrl,
  mergeRooms,
  normalizeRooms,
  roomAssetUrls,
  roomsManifestUrl,
  shouldShowRoomPicker,
} from "../js/rooms.js";
import { createMockState, formatState } from "../js/state.js";

const sampleUrl = new URL("../sample/sample-apartment.roomscan.json", import.meta.url);
const sample = JSON.parse(readFileSync(sampleUrl, "utf8"));

test("sample layout is roomscan.home version 1 with the four sample pins", () => {
  const doc = parseLayout(sample);
  const { pins } = readPins(doc);
  assert.equal(doc.home.name, "Sample apartment");
  assert.equal(doc.home.structure.coordinates_are_unified, true);
  assert.deepEqual(
    pins.map((pin) => pin.entityId),
    ["light.kitchen", "light.living_room", "switch.living_room", "sensor.living_room_temperature"],
  );
  assert.equal(pins[0].position.y, 2.35);
});

test("unknown format and version are rejected", () => {
  assert.throws(() => parseLayout({ format: "other", version: 1, home: {} }), /not a Home Scanner layout/);
  assert.throws(
    () => parseLayout({ format: "roomscan.home", version: 2, home: { rooms: [], pins: [] } }),
    /format version 2/,
  );
});

test("room urls stay inside the integration folder", () => {
  assert.equal(isSafeRoomId("living-room"), true);
  assert.equal(isSafeRoomId("../secrets"), false);
  assert.equal(isSafeRoomId("kitchen/model"), false);
  assert.equal(isSafeRoomId("a b"), false);
  assert.equal(
    roomAssetUrls("/local/home_scanner", "living-room").layout,
    "/local/home_scanner/living-room/layout.json",
  );
  assert.equal(
    roomAssetUrls("/local/home_scanner", "living-room").model,
    "/local/home_scanner/living-room/model.glb",
  );
  assert.equal(roomsManifestUrl("/local/home_scanner/"), "/local/home_scanner/rooms.json");
  assert.equal(joinUrl("sample-rooms", "kitchen", "model.glb"), "sample-rooms/kitchen/model.glb");
  assert.throws(() => roomAssetUrls("/local/home_scanner", ".."), /folder name/);
});

test("picker shows when more than one room is uploaded", () => {
  const discovered = normalizeRooms({
    rooms: [
      { id: "kitchen", name: "Kitchen" },
      { slug: "living-room", title: "Living room" },
      "kitchen",
      { id: "../bad", name: "nope" },
    ],
  });
  assert.deepEqual(discovered, [
    { id: "kitchen", name: "Kitchen" },
    { id: "living-room", name: "Living room" },
  ]);
  const rooms = mergeRooms(discovered, "hall", null);
  assert.equal(rooms[0].id, "hall");
  assert.equal(shouldShowRoomPicker(rooms), true);
  assert.equal(initialRoomId(rooms, "living-room"), "living-room");
  assert.equal(initialRoomId(rooms, null), "hall");
  assert.equal(shouldShowRoomPicker([{ id: "kitchen", name: "Kitchen" }]), false);
});

test("mock state matches the app seed and refuses sensor toggles", () => {
  const mock = createMockState();
  assert.equal(mock.snapshot("light.kitchen").state, "on");
  assert.equal(mock.snapshot("light.living_room").state, "off");
  assert.equal(formatState(mock.snapshot("sensor.living_room_temperature")), "21.5 °C");
  assert.equal(mock.toggle("light.living_room").state, "on");
  assert.equal(mock.toggle("Light.Kitchen").state, "off");
  assert.throws(() => mock.toggle("sensor.living_room_temperature"), /can't be toggled/);
});

test("sample glb is a binary glTF", () => {
  const bytes = readFileSync(new URL("../sample/sample-apartment.glb", import.meta.url));
  assert.equal(bytes.subarray(0, 4).toString(), "glTF");
  assert.equal(bytes.readUInt32LE(4), 2);
  assert.equal(bytes.readUInt32LE(8), bytes.length);
});
