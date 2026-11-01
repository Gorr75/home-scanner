import { mountViewer } from "./viewer.js";

const params = new URLSearchParams(location.search);
const defaults = {
  layout: params.get("layout") || "sample/sample-apartment.roomscan.json",
  model: params.get("model") || "sample/sample-apartment.glb",
};

const title = document.querySelector("[data-title]");
const sub = document.querySelector("[data-sub]");
const banner = document.querySelector("[data-banner]");
const errorNode = document.querySelector("[data-error]");
const viewer = document.querySelector("[data-viewer]");
const layoutInput = document.querySelector("[data-layout-file]");
const modelInput = document.querySelector("[data-model-file]");

let current = null;
let layoutUrl = defaults.layout;
let modelUrl = defaults.model;
const objectUrls = [];

function track(url) {
  if (url.startsWith("blob:")) objectUrls.push(url);
  return url;
}

async function show() {
  errorNode.hidden = true;
  window.__viewerReady = { ok: false, error: "loading" };
  if (current) {
    current.destroy();
    current = null;
  }
  try {
    current = await mountViewer(viewer, {
      layoutUrl,
      modelUrl,
      mode: "mock",
      onReady(info) {
        title.textContent = info.name;
        const extra = info.warning ? ` ${info.warning}` : "";
        sub.textContent = `${info.pinCount} device pins. Drag to orbit, scroll to zoom, click a pin.${extra}`;
      },
    });
    window.__viewer = current;
    window.__viewerReady = { ok: true, ...current.debug() };
    banner.textContent = "States are sample data in this page. Home Assistant is not connected.";
  } catch (error) {
    const message = error?.message || String(error);
    errorNode.hidden = false;
    errorNode.textContent = message;
    window.__viewerReady = { ok: false, error: message };
  }
}

function useFile(file, kind) {
  const url = track(URL.createObjectURL(file));
  if (kind === "layout") layoutUrl = url;
  if (kind === "model") modelUrl = url;
  show();
}

layoutInput.addEventListener("change", () => {
  const file = layoutInput.files?.[0];
  if (file) useFile(file, "layout");
});
modelInput.addEventListener("change", () => {
  const file = modelInput.files?.[0];
  if (file) useFile(file, "model");
});

document.querySelector(".app").addEventListener("dragover", (event) => {
  event.preventDefault();
});
document.querySelector(".app").addEventListener("drop", (event) => {
  event.preventDefault();
  let changed = false;
  for (const file of event.dataTransfer?.files || []) {
    const name = file.name.toLowerCase();
    if (name.endsWith(".json")) {
      layoutUrl = track(URL.createObjectURL(file));
      changed = true;
    } else if (name.endsWith(".glb") || name.endsWith(".gltf")) {
      modelUrl = track(URL.createObjectURL(file));
      changed = true;
    }
  }
  if (changed) show();
});

show();
