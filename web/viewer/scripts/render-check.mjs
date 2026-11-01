#!/usr/bin/env node
/**
 * Load the standalone viewer and the card preview in headless Chrome,
 * assert the sample room actually drew, and write PNG screenshots.
 *
 *   node scripts/render-check.mjs [output-dir]
 */

import { spawn } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import http from "node:http";
import { createReadStream } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const outDir = path.resolve(process.argv[2] || path.join(root, "screenshots"));
const port = 8765;

const types = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".glb": "model/gltf-binary",
  ".png": "image/png",
};

function startServer() {
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, `http://127.0.0.1:${port}`);
    const filePath = path.normalize(path.join(root, decodeURIComponent(url.pathname)));
    if (!filePath.startsWith(root)) {
      response.writeHead(403);
      response.end();
      return;
    }
    const stream = createReadStream(filePath);
    stream.on("error", () => {
      response.writeHead(404);
      response.end("not found");
    });
    stream.on("open", () => {
      response.writeHead(200, { "content-type": types[path.extname(filePath)] || "application/octet-stream" });
      stream.pipe(response);
    });
  });
  return new Promise((resolve) => server.listen(port, "127.0.0.1", () => resolve(server)));
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(predicate, label, timeout = 20000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    if (await predicate()) return;
    await wait(200);
  }
  throw new Error(`timed out waiting for ${label}`);
}

function launchChrome() {
  const chrome = process.env.CHROME || "google-chrome";
  const userData = `/tmp/home-scanner-chrome-${process.pid}`;
  const child = spawn(
    chrome,
    [
      "--headless=new",
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--use-gl=angle",
      "--use-angle=swiftshader",
      "--enable-unsafe-swiftshader",
      "--remote-debugging-port=9222",
      `--user-data-dir=${userData}`,
      "--window-size=1440,1000",
      "--no-first-run",
      "--disable-features=Translate",
      "about:blank",
    ],
    { stdio: "ignore" },
  );
  return child;
}

async function debuggerSocket() {
  for (let attempt = 0; attempt < 40; attempt += 1) {
    try {
      const response = await fetch("http://127.0.0.1:9222/json/list");
      const pages = await response.json();
      const page = pages.find((item) => item.type === "page");
      if (page?.webSocketDebuggerUrl) return page.webSocketDebuggerUrl;
    } catch {
      // Chrome is still starting.
    }
    await wait(200);
  }
  throw new Error("Chrome DevTools did not come up");
}

function connect(wsUrl) {
  const ws = new WebSocket(wsUrl);
  let nextId = 0;
  const pending = new Map();
  const opened = new Promise((resolve, reject) => {
    ws.addEventListener("open", () => resolve());
    ws.addEventListener("error", () => reject(new Error("devtools socket failed")));
  });
  ws.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (!message.id || !pending.has(message.id)) return;
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    if (message.error) reject(new Error(JSON.stringify(message.error)));
    else resolve(message.result);
  });
  return {
    opened,
    send(method, params = {}) {
      const id = ++nextId;
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        ws.send(JSON.stringify({ id, method, params }));
      });
    },
    close() {
      ws.close();
    },
  };
}

async function evaluate(cdp, expression) {
  const result = await cdp.send("Runtime.evaluate", {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (result.exceptionDetails) {
    throw new Error(result.exceptionDetails.text || "evaluate failed");
  }
  return result.result.value;
}

async function openPage(cdp, url) {
  await cdp.send("Page.navigate", { url });
}

async function screenshot(cdp, file) {
  const shot = await cdp.send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
  await writeFile(file, Buffer.from(shot.data, "base64"));
  console.log(`wrote ${file}`);
}

function assertDrawn(info, label) {
  if (!info?.ok) throw new Error(`${label} failed: ${info?.error || "not ready"}`);
  if (info.pinCount !== 4) throw new Error(`${label} pin count ${info.pinCount}`);
  if (!info.glbLoaded || info.meshCount < 5) throw new Error(`${label} model did not load`);
  const brightest = Math.max(...info.samples.flat());
  if (brightest < 80) {
    throw new Error(`${label} framebuffer looks empty: ${JSON.stringify(info.samples)}`);
  }
  if (!info.glowing?.includes("light.kitchen")) {
    throw new Error(`${label} kitchen light is not glowing: ${JSON.stringify(info.glowing)}`);
  }
  if (info.glowing.includes("light.living_room")) {
    throw new Error(`${label} living room light should start off`);
  }
}

async function main() {
  await mkdir(outDir, { recursive: true });
  const server = await startServer();
  const chrome = launchChrome();
  let cdp;
  try {
    const wsUrl = await debuggerSocket();
    cdp = connect(wsUrl);
    await cdp.opened;
    await cdp.send("Page.enable");
    await cdp.send("Runtime.enable");

    await openPage(cdp, `http://127.0.0.1:${port}/index.html`);
    await waitFor(async () => {
      const info = await evaluate(cdp, "window.__viewerReady");
      return info && info.error !== "loading";
    }, "viewer");
    const ready = await evaluate(cdp, "window.__viewerReady");
    assertDrawn(ready, "standalone");
    await wait(400);
    await screenshot(cdp, path.join(outDir, "sample-room.png"));

    const picked = await evaluate(
      cdp,
      `(() => {
        const point = window.__viewer.pinClientPoint("light.living_room");
        const canvas = document.querySelector("canvas");
        for (const type of ["pointerdown", "pointerup"]) {
          canvas.dispatchEvent(new PointerEvent(type, {
            bubbles: true,
            clientX: point.x,
            clientY: point.y,
            pointerId: 1,
          }));
        }
        const entity = document.querySelector("[data-entity]")?.textContent || "";
        return { selected: window.__viewer.selectedEntityId(), entity, point };
      })()`,
    );
    if (picked.selected !== "light.living_room" || !picked.entity.includes("light.living_room")) {
      throw new Error(`pin click missed: ${JSON.stringify(picked)}`);
    }
    const toggled = await evaluate(
      cdp,
      `(() => {
        document.querySelector("[data-action='toggle']").click();
        return window.__viewer.debug();
      })()`,
    );
    if (!toggled.glowing.includes("light.living_room") || !toggled.glowing.includes("light.kitchen")) {
      throw new Error(`toggle did not light the living room: ${JSON.stringify(toggled.glowing)}`);
    }
    const sensor = await evaluate(
      cdp,
      `(() => {
        document.querySelector("[data-entity='sensor.living_room_temperature']").click();
        const state = document.querySelector("[data-state]")?.textContent || "";
        const toggle = document.querySelector("[data-action='toggle']");
        return { state, toggle: Boolean(toggle) };
      })()`,
    );
    if (sensor.state !== "21.5 °C" || sensor.toggle) {
      throw new Error(`sensor label failed: ${JSON.stringify(sensor)}`);
    }
    await wait(200);
    await screenshot(cdp, path.join(outDir, "pin-sensor.png"));

    await openPage(cdp, `http://127.0.0.1:${port}/card-preview.html`);
    await waitFor(
      async () => {
        const info = await evaluate(cdp, "window.__cardReady");
        return info && (info.ok || info.error);
      },
      "card",
      40000,
    );
    const card = await evaluate(cdp, "window.__cardReady");
    if (!card.ok) throw new Error(`card preview failed: ${card.error || JSON.stringify(card)}`);
    if (card.options.length < 2) throw new Error(`room picker missing: ${JSON.stringify(card.options)}`);
    const cardPin = await evaluate(
      cdp,
      `(() => {
        const root = document.querySelector("home-scanner-card").shadowRoot;
        root.querySelector("[data-entity='light.kitchen']").click();
        return root.querySelector("[data-entity]").textContent;
      })()`,
    );
    if (cardPin !== "light.kitchen") throw new Error(`card pin panel showed ${cardPin}`);
    await wait(300);
    await screenshot(cdp, path.join(outDir, "card-room-picker.png"));
    console.log("render check passed");
  } finally {
    cdp?.close();
    chrome.kill("SIGKILL");
    server.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
