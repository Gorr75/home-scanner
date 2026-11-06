// Parity checks for the card's copy of DaylightMath. Run with:
// TZ=UTC node web/home-scanner-card/daylight.test.mjs
import assert from "node:assert/strict";

globalThis.HTMLElement = class {};
globalThis.customElements = { get: () => false, define() {} };
globalThis.window = globalThis;

const { daylightFromClock, daylightFromSun, daylightTint } = await import("./home-scanner-card.js");

const sunrise = daylightTint(0, true);
const sunset = daylightTint(0, false);
assert.equal(sunrise.phase, "sunrise");
assert.equal(sunset.phase, "sunset");
assert.equal(sunrise.red, 1);
assert.equal(sunrise.green, 0.55);
assert.equal(sunrise.blue, 0.26);
assert.equal(sunrise.key, 0.32);
assert.equal(sunrise.red, sunset.red);
assert.ok(sunrise.red > sunrise.blue + 0.5);

const midday = daylightTint(48, true);
assert.equal(midday.phase, "day");
assert.equal(midday.key, 1);
assert.ok(midday.blue > 0.9);

const night = daylightTint(-90, false);
assert.equal(night.phase, "night");
assert.equal(night.blue, 0.76);
assert.equal(night.key, 0.06);
assert.ok(night.blue > night.red);
assert.ok(night.key < sunrise.key);

const noon = daylightFromClock(new Date("2026-06-21T12:00:00Z"));
const six = daylightFromClock(new Date("2026-06-21T06:00:00Z"));
const eighteen = daylightFromClock(new Date("2026-06-21T18:00:00Z"));
const midnight = daylightFromClock(new Date("2026-06-21T00:00:00Z"));
assert.equal(noon.phase, "day");
assert.ok(noon.key > 0.9);
assert.equal(six.phase, "sunrise");
assert.equal(eighteen.phase, "sunset");
assert.equal(six.red, eighteen.red);
assert.equal(midnight.phase, "night");
assert.ok(midnight.blue > midnight.red);
assert.equal(noon.source, "clock");

const highAtMidnight = daylightFromSun(
  { state: "below_horizon", attributes: { elevation: 50 } },
  new Date("2026-06-21T00:00:00Z")
);
assert.equal(highAtMidnight.phase, "day");
assert.equal(highAtMidnight.source, "sun");
assert.ok(highAtMidnight.key > 0.9);

const fromRiseSet = daylightFromSun(
  {
    state: "above_horizon",
    attributes: {
      next_rising: "2026-06-22T06:00:00+00:00",
      next_setting: "2026-06-21T18:00:00+00:00",
    },
  },
  new Date("2026-06-21T12:00:00Z")
);
assert.equal(fromRiseSet.phase, "day");
assert.ok(Math.abs(fromRiseSet.key - 1) < 0.02);

const nightFromRiseSet = daylightFromSun(
  {
    state: "below_horizon",
    attributes: {
      next_rising: "2026-06-21T06:00:00+00:00",
      next_setting: "2026-06-21T18:00:00+00:00",
    },
  },
  new Date("2026-06-21T00:00:00Z")
);
assert.equal(nightFromRiseSet.phase, "night");
assert.ok(nightFromRiseSet.blue > nightFromRiseSet.red);

const stateOnly = daylightFromSun({ state: "below_horizon", attributes: {} }, new Date("2026-06-21T12:00:00Z"));
assert.equal(stateOnly.phase, "night");
assert.equal(stateOnly.source, "sun");

const missing = daylightFromSun(null, new Date("2026-06-21T12:00:00Z"));
assert.equal(missing.phase, "day");
assert.equal(missing.source, "clock");

console.log("daylight card mapping matches the RoomScanCore stops");
