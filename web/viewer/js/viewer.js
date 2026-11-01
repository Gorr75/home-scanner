import * as THREE from "../vendor/three.module.js";
import { OrbitControls } from "../vendor/OrbitControls.js";
import { GLTFLoader } from "../vendor/GLTFLoader.js";
import { fetchLayout, layoutSummary, readPins } from "./layout.js";
import {
  canonicalEntityId,
  createMockState,
  formatState,
  isOn,
  isToggleable,
  pinColor,
} from "./state.js";

const CLEAR = 0x141311;

export async function mountViewer(container, options) {
  const layout = options.layout || (await fetchLayout(options.layoutUrl));
  const summary = layoutSummary(layout);
  const { pins, skipped } = readPins(layout);
  const mock = options.mode === "live" ? null : createMockState();
  const states = new Map();

  container.replaceChildren();
  container.classList.add("stage");
  const viewport = document.createElement("div");
  viewport.className = "viewport";
  const side = document.createElement("aside");
  side.className = "side";
  side.innerHTML = `
    <div data-detail></div>
    <h2>Devices</h2>
    <ul data-pins></ul>
  `;
  container.append(viewport, side);

  const renderer = new THREE.WebGLRenderer({
    antialias: true,
    alpha: false,
    preserveDrawingBuffer: true,
    failIfMajorPerformanceCaveat: false,
  });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.setClearColor(CLEAR, 1);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.12;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  viewport.append(renderer.domElement);

  const scene = new THREE.Scene();
  scene.background = new THREE.Color(CLEAR);
  const camera = new THREE.PerspectiveCamera(42, 1, 0.05, 100);
  const controls = new OrbitControls(camera, renderer.domElement);
  controls.enableDamping = true;
  controls.target.set(4.4, 1.1, 2);
  controls.maxPolarAngle = Math.PI * 0.49;
  controls.minDistance = 0.6;
  controls.maxDistance = 28;
  camera.position.set(10.5, 6.2, 9.2);

  scene.add(new THREE.HemisphereLight(0xfff4e4, 0x3a342c, 0.72));
  const sun = new THREE.DirectionalLight(0xfff7ee, 1.55);
  sun.position.set(2, 10, -3);
  sun.castShadow = true;
  sun.shadow.mapSize.set(1024, 1024);
  scene.add(sun);

  const loader = new GLTFLoader();
  let observer = null;
  let gltf;
  try {
    gltf = await loader.loadAsync(options.modelUrl);
  } catch (error) {
    dispose();
    const message = error?.message || String(error);
    throw new Error(`Could not read model at ${options.modelUrl}. ${message}`);
  }
  const model = gltf.scene;
  model.traverse((node) => {
    if (!node.isMesh) return;
    node.castShadow = true;
    node.receiveShadow = true;
  });
  scene.add(model);

  const box = new THREE.Box3().setFromObject(model);
  const sphere = box.getBoundingSphere(new THREE.Sphere());
  if (Number.isFinite(sphere.radius) && sphere.radius > 0) {
    const distance = sphere.radius / Math.sin((camera.fov * Math.PI) / 360);
    const direction = new THREE.Vector3(0.62, 1.2, 0.78).normalize();
    camera.position.copy(sphere.center).addScaledVector(direction, distance * 0.82);
    camera.near = Math.max(0.02, distance / 200);
    camera.far = distance * 30;
    camera.updateProjectionMatrix();
    controls.target.copy(sphere.center);
    const extent = Math.max(sphere.radius, 1);
    sun.position.set(sphere.center.x - extent, sphere.center.y + extent * 2.2, sphere.center.z + extent * 0.2);
    sun.shadow.camera.left = -extent * 1.4;
    sun.shadow.camera.right = extent * 1.4;
    sun.shadow.camera.top = extent * 1.4;
    sun.shadow.camera.bottom = -extent * 1.4;
    sun.shadow.camera.near = 0.2;
    sun.shadow.camera.far = extent * 6;
    sun.shadow.camera.updateProjectionMatrix();
  }
  controls.update();

  const pinRoot = new THREE.Group();
  pinRoot.name = "pins";
  scene.add(pinRoot);
  const markers = new Map();
  let selectedId = null;
  let frame = 0;
  let stopped = false;

  function stateFor(pin) {
    if (!pin.entityId) return null;
    const parsed = canonicalEntityId(pin.entityId);
    if (!parsed.id) return null;
    return states.get(parsed.id) || null;
  }

  function remember(snapshot) {
    if (!snapshot?.entity_id) return;
    states.set(snapshot.entity_id, snapshot);
  }

  function seedStates() {
    states.clear();
    if (options.states) {
      for (const snapshot of Object.values(options.states)) remember(snapshot);
    }
    if (!mock) return;
    for (const pin of pins) {
      if (!pin.entityId) continue;
      try {
        remember(mock.snapshot(pin.entityId));
      } catch {
        // Invalid ids stay unlinked in the panel.
      }
    }
  }

  function makeLabel(title, subtitle) {
    const canvas = document.createElement("canvas");
    canvas.width = 768;
    canvas.height = subtitle ? 176 : 104;
    const ctx = canvas.getContext("2d");
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    roundRect(ctx, 8, 8, canvas.width - 16, canvas.height - 16, 28);
    ctx.fillStyle = "rgba(20, 16, 12, 0.88)";
    ctx.fill();
    ctx.strokeStyle = "rgba(240, 162, 2, 0.85)";
    ctx.lineWidth = 6;
    ctx.stroke();
    ctx.fillStyle = "#f6f1e8";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    const titleSize = fitFont(ctx, title, canvas.width - 64, 44, 600);
    ctx.fillText(title, canvas.width / 2, subtitle ? 58 : canvas.height / 2);
    if (subtitle) {
      ctx.fillStyle = "#f0a202";
      fitFont(ctx, subtitle, canvas.width - 64, Math.min(34, titleSize), 500);
      ctx.fillText(subtitle, canvas.width / 2, 122);
    }
    const texture = new THREE.CanvasTexture(canvas);
    texture.colorSpace = THREE.SRGBColorSpace;
    const material = new THREE.SpriteMaterial({ map: texture, transparent: true, depthTest: false });
    const sprite = new THREE.Sprite(material);
    sprite.userData.aspect = subtitle ? 176 / 768 : 104 / 768;
    sprite.position.y = 0.32;
    sprite.renderOrder = 10;
    return sprite;
  }

  function markerGeometry(kind) {
    if (kind === "switch") return new THREE.BoxGeometry(0.14, 0.18, 0.07);
    if (kind === "sensor") return new THREE.OctahedronGeometry(0.11, 0);
    return new THREE.SphereGeometry(0.11, 24, 16);
  }

  function addPin(pin) {
    const group = new THREE.Group();
    group.position.set(pin.position.x, pin.position.y, pin.position.z);
    group.userData.pinId = pin.id;
    const material = new THREE.MeshStandardMaterial({
      color: 0x8a8175,
      emissive: 0x000000,
      roughness: 0.45,
      metalness: 0.05,
    });
    const mesh = new THREE.Mesh(markerGeometry(pin.kind), material);
    mesh.castShadow = true;
    mesh.userData.pinId = pin.id;
    group.add(mesh);

    const halo = new THREE.Mesh(
      new THREE.SphereGeometry(0.26, 16, 12),
      new THREE.MeshBasicMaterial({
        color: 0xffb040,
        transparent: true,
        opacity: 0.0,
        depthWrite: false,
      }),
    );
    halo.userData.pinId = pin.id;
    group.add(halo);

    let stem = null;
    if (pin.kind === "light" && pin.position.y > 0.4) {
      stem = new THREE.Mesh(
        new THREE.CylinderGeometry(0.012, 0.012, pin.position.y, 8),
        new THREE.MeshStandardMaterial({ color: 0x4a453f, roughness: 0.8 }),
      );
      stem.position.y = -pin.position.y / 2;
      group.add(stem);
    }

    const light = new THREE.PointLight(0xffb15a, 0, 6.5, 2);
    light.castShadow = false;
    group.add(light);

    pinRoot.add(group);
    markers.set(pin.id, { pin, group, mesh, material, halo, light, label: null });
  }

  function refreshMarker(record) {
    const snapshot = stateFor(record.pin);
    const color = new THREE.Color(pinColor(snapshot));
    record.material.color.copy(color);
    const glow = record.pin.kind === "light" && isOn(snapshot);
    record.material.emissive.copy(glow ? new THREE.Color(0xffb15a) : new THREE.Color(0x000000));
    record.material.emissiveIntensity = glow ? 1.4 : 0;
    record.halo.material.opacity = glow ? 0.34 : 0;
    record.light.intensity = glow ? 18 : 0;
    const selected = record.pin.id === selectedId;
    record.mesh.scale.setScalar(selected ? 1.25 : 1);
    const labelText = labelFor(record.pin, snapshot, selected);
    if (record.label) {
      record.label.material.map.dispose();
      record.label.material.dispose();
      record.group.remove(record.label);
      record.label = null;
    }
    if (labelText) {
      record.label = makeLabel(labelText.title, labelText.subtitle);
      record.label.userData.pinId = record.pin.id;
      record.group.add(record.label);
    }
  }

  function labelFor(pin, snapshot, selected) {
    const sensor = pin.kind === "sensor" || snapshot?.domain === "sensor";
    if (selected) {
      return {
        title: pin.name,
        subtitle: pin.entityId || "No entity id",
      };
    }
    if (sensor) {
      return { title: pin.name, subtitle: formatState(snapshot) };
    }
    return null;
  }

  function renderSide() {
    const detail = side.querySelector("[data-detail]");
    const list = side.querySelector("[data-pins]");
    const selected = pins.find((pin) => pin.id === selectedId) || null;
    detail.replaceChildren();
    if (!selected) {
      const hint = document.createElement("p");
      hint.className = "hint";
      hint.textContent = "Click a pin to see its entity id.";
      detail.append(hint);
    } else {
      const snapshot = stateFor(selected);
      const parsed = selected.entityId ? canonicalEntityId(selected.entityId) : { unset: true };
      detail.append(line("kind", selected.kind.replaceAll("_", " ")));
      const title = document.createElement("h3");
      title.textContent = selected.name;
      detail.append(title);
      if (selected.roomName) detail.append(line("meta", selected.roomName));
      const entity = document.createElement("p");
      entity.className = "entity";
      entity.dataset.entity = parsed.id || "";
      entity.textContent = parsed.id || (parsed.invalid ? parsed.invalid : "No entity id");
      detail.append(entity);
      const state = document.createElement("p");
      state.className = "state";
      state.dataset.state = snapshot?.state || "";
      state.textContent = parsed.invalid ? "Not a valid entity id." : formatState(snapshot);
      detail.append(state);
      if (isToggleable(snapshot)) {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "toggle";
        button.dataset.action = "toggle";
        button.textContent = isOn(snapshot) ? "Turn off" : "Turn on";
        button.addEventListener("click", () => toggleSelected());
        detail.append(button);
      } else if (snapshot || parsed.id) {
        const note = document.createElement("p");
        note.className = "note";
        note.textContent = parsed.id
          ? `${parsed.id} can't be toggled from here.`
          : "This pin has no entity id.";
        detail.append(note);
      }
      const error = document.createElement("p");
      error.className = "note error";
      error.dataset.toggleError = "";
      error.hidden = true;
      detail.append(error);
    }
    list.replaceChildren();
    for (const pin of pins) {
      const snapshot = stateFor(pin);
      const item = document.createElement("li");
      const button = document.createElement("button");
      button.type = "button";
      button.className = "pin";
      button.dataset.pinId = pin.id;
      if (pin.entityId) button.dataset.entity = canonicalEntityId(pin.entityId).id || pin.entityId;
      if (pin.id === selectedId) button.setAttribute("aria-current", "true");
      const dot = document.createElement("span");
      dot.className = "dot";
      dot.style.background = pinColor(snapshot);
      const copy = document.createElement("span");
      copy.className = "pin-copy";
      const name = document.createElement("span");
      name.className = "pin-name";
      name.textContent = pin.name;
      const meta = document.createElement("span");
      meta.className = "pin-meta";
      meta.textContent = snapshot ? formatState(snapshot) : pin.entityId || pin.kind;
      copy.append(name, meta);
      button.append(dot, copy);
      button.addEventListener("click", () => select(pin.id));
      item.append(button);
      list.append(item);
    }
  }

  function select(pinId) {
    selectedId = pinId;
    for (const record of markers.values()) refreshMarker(record);
    renderSide();
    options.onSelect?.(pins.find((pin) => pin.id === pinId) || null);
  }

  async function toggleSelected() {
    const pin = pins.find((item) => item.id === selectedId);
    const errorNode = side.querySelector("[data-toggle-error]");
    if (!pin?.entityId) return;
    try {
      if (mock) {
        remember(mock.toggle(pin.entityId));
      } else if (options.onToggle) {
        await options.onToggle(pin.entityId);
      }
      if (errorNode) errorNode.hidden = true;
      select(pin.id);
    } catch (error) {
      if (errorNode) {
        errorNode.hidden = false;
        errorNode.textContent = error?.message || String(error);
      }
    }
  }

  const raycaster = new THREE.Raycaster();
  const pointer = new THREE.Vector2();
  let down = null;

  function pickAt(clientX, clientY) {
    const rect = renderer.domElement.getBoundingClientRect();
    pointer.x = ((clientX - rect.left) / rect.width) * 2 - 1;
    pointer.y = -((clientY - rect.top) / rect.height) * 2 + 1;
    raycaster.setFromCamera(pointer, camera);
    const hits = raycaster.intersectObjects(pinRoot.children, true);
    for (const hit of hits) {
      let node = hit.object;
      while (node) {
        if (node.userData.pinId) {
          select(node.userData.pinId);
          return node.userData.pinId;
        }
        node = node.parent;
      }
    }
    return null;
  }

  renderer.domElement.addEventListener("pointerdown", (event) => {
    down = { x: event.clientX, y: event.clientY };
  });
  renderer.domElement.addEventListener("pointerup", (event) => {
    if (!down) return;
    const dx = event.clientX - down.x;
    const dy = event.clientY - down.y;
    down = null;
    if (dx * dx + dy * dy > 16) return;
    pickAt(event.clientX, event.clientY);
  });

  function resize() {
    const width = viewport.clientWidth || 1;
    const height = viewport.clientHeight || 1;
    renderer.setSize(width, height, false);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
  }
  observer = new ResizeObserver(resize);
  observer.observe(viewport);
  resize();

  const labelAnchor = new THREE.Vector3();

  function tick() {
    if (stopped) return;
    controls.update();
    for (const record of markers.values()) {
      if (!record.label) continue;
      record.group.getWorldPosition(labelAnchor);
      const distance = Math.max(camera.position.distanceTo(labelAnchor), 1);
      const width = Math.min(2.8, distance * 0.32);
      record.label.scale.set(width, width * (record.label.userData.aspect || 0.23), 1);
    }
    renderer.render(scene, camera);
    frame = requestAnimationFrame(tick);
  }

  function dispose() {
    stopped = true;
    cancelAnimationFrame(frame);
    observer?.disconnect();
    controls.dispose();
    scene.traverse((node) => {
      if (node.geometry) node.geometry.dispose();
      const materials = node.material ? [].concat(node.material) : [];
      for (const material of materials) {
        material.map?.dispose();
        material.dispose?.();
      }
    });
    renderer.dispose();
    container.replaceChildren();
  }

  seedStates();
  for (const pin of pins) addPin(pin);
  for (const record of markers.values()) refreshMarker(record);
  renderSide();
  tick();

  const api = {
    summary,
    pins: () => pins.map((pin) => ({ ...pin })),
    skipped,
    setStates(next) {
      if (mock) return;
      for (const snapshot of Object.values(next || {})) remember(snapshot);
      for (const record of markers.values()) refreshMarker(record);
      renderSide();
    },
    selectedEntityId() {
      const pin = pins.find((item) => item.id === selectedId);
      return pin?.entityId ? canonicalEntityId(pin.entityId).id || null : null;
    },
    pinClientPoint(entityId) {
      const record = [...markers.values()].find((item) => {
        const parsed = item.pin.entityId ? canonicalEntityId(item.pin.entityId) : null;
        return parsed?.id === entityId;
      });
      if (!record) return null;
      const vector = record.group.position.clone().project(camera);
      const rect = renderer.domElement.getBoundingClientRect();
      return {
        x: rect.left + (vector.x * 0.5 + 0.5) * rect.width,
        y: rect.top + (-vector.y * 0.5 + 0.5) * rect.height,
        behind: vector.z > 1,
      };
    },
    pickClient(x, y) {
      return pickAt(x, y);
    },
    debug() {
      renderer.render(scene, camera);
      const gl = renderer.getContext();
      const width = gl.drawingBufferWidth;
      const height = gl.drawingBufferHeight;
      const samples = [];
      for (const [fx, fy] of [
        [0.5, 0.42],
        [0.32, 0.38],
        [0.68, 0.46],
        [0.5, 0.22],
      ]) {
        const pixel = new Uint8Array(4);
        gl.readPixels(
          Math.floor(width * fx),
          Math.floor(height * fy),
          1,
          1,
          gl.RGBA,
          gl.UNSIGNED_BYTE,
          pixel,
        );
        samples.push([pixel[0], pixel[1], pixel[2]]);
      }
      const glowing = [];
      for (const record of markers.values()) {
        if (record.light.intensity > 0) {
          const parsed = canonicalEntityId(record.pin.entityId);
          if (parsed.id) glowing.push(parsed.id);
        }
      }
      return {
        pinCount: pins.length,
        glbLoaded: true,
        meshCount: countMeshes(model),
        glowing,
        samples,
        home: summary.name,
      };
    },
    destroy: dispose,
  };

  options.onReady?.({ ...summary, pinCount: pins.length, skipped });
  return api;
}

function countMeshes(root) {
  let count = 0;
  root.traverse((node) => {
    if (node.isMesh) count += 1;
  });
  return count;
}

function line(className, text) {
  const node = document.createElement("p");
  node.className = className;
  node.textContent = text;
  return node;
}

function fitFont(ctx, text, maxWidth, start, weight) {
  let size = start;
  do {
    ctx.font = `${weight} ${size}px sans-serif`;
    if (ctx.measureText(text).width <= maxWidth) return size;
    size -= 2;
  } while (size > 18);
  ctx.font = `${weight} ${size}px sans-serif`;
  return size;
}

function roundRect(ctx, x, y, width, height, radius) {
  ctx.beginPath();
  ctx.moveTo(x + radius, y);
  ctx.arcTo(x + width, y, x + width, y + height, radius);
  ctx.arcTo(x + width, y + height, x, y + height, radius);
  ctx.arcTo(x, y + height, x, y, radius);
  ctx.arcTo(x, y, x + width, y, radius);
  ctx.closePath();
}
