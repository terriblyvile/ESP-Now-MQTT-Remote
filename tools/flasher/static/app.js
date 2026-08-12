"use strict";

const SECRET_FIELDS = [
  "WIFI_SSID", "WIFI_PASSWORD", "MQTT_HOST", "MQTT_PORT",
  "MQTT_USERNAME", "MQTT_PASSWORD", "OTA_PASSWORD",
];

const PAGES = {
  home: {
    title: "Remote Firmware Flasher",
    sub: "Flash a hub, read its ESP-NOW address off the boot log, then flash remotes that talk to it.",
  },
  credentials: { title: "Credentials", sub: "WiFi, MQTT broker and OTA passwords." },
  radio: { title: "Radio & topics", sub: "Channel, MQTT topic root and hold threshold." },
  remotes: { title: "Define Remotes", sub: "One row per physical handset." },
  hubs: { title: "Flash a base station", sub: "Upload to a hub, then capture the address remotes transmit to." },
  flash: { title: "Flash a remote", sub: "Build a handset's firmware and upload it over USB." },
};

let state = null;
let secrets = null;
let stream = null;

const $ = (id) => document.getElementById(id);

// ---------------------------------------------------------------------------
// routing
// ---------------------------------------------------------------------------

function currentPage() {
  const name = (location.hash || "#/home").replace(/^#\/?/, "") || "home";
  return PAGES[name] ? name : "home";
}

function route() {
  const page = currentPage();
  Object.keys(PAGES).forEach((name) => {
    const view = $(`view-${name}`);
    if (view) view.hidden = name !== page;
  });
  $("page-title").textContent = PAGES[page].title;
  $("page-sub").textContent = PAGES[page].sub;
  $("home-btn").hidden = page === "home";
  if (page === "home") refreshTiles();
  window.scrollTo(0, 0);
}

function go(page) {
  location.hash = `#/${page}`;
}

window.addEventListener("hashchange", route);
$("home-btn").onclick = () => go("home");
document.querySelectorAll("[data-go]").forEach((el) => {
  el.onclick = () => go(el.dataset.go);
});

/** Home tiles double as a status board, so the page is worth returning to. */
function refreshTiles() {
  if (!state) return;

  const haveSecrets = secrets && secrets.WIFI_SSID && secrets.MQTT_HOST;
  setTile("t-credentials",
    haveSecrets ? `${secrets.WIFI_SSID} · ${secrets.MQTT_HOST}` : "not set yet",
    haveSecrets ? "ok" : "missing");

  setTile("t-radio", `channel ${state.wifi_channel} · ${state.topic_root}/`, "ok");

  // Read the inputs, not the last saved state, so a just-captured address is
  // reflected before you have got round to saving.
  const macs = hubMacs();
  const captured = ["wired", "wireless"].filter((h) => macs[h]);
  setTile("t-hubs",
    captured.length ? `${captured.join(" and ")} address captured` : "no address captured",
    captured.length ? "ok" : "missing");

  const n = state.remotes.length;
  setTile("t-remotes", n === 1 ? "1 remote" : `${n} remotes`, n ? "ok" : "missing");

  const ready = state.remotes.filter((r) => macs[r.hub]).length;
  setTile("t-flash",
    ready ? `${ready} ready to flash` : "capture a hub address first",
    ready ? "ok" : "missing");
}

function setTile(id, text, kind) {
  const el = $(id);
  if (!el) return;
  el.textContent = text;
  el.className = "tile-status " + kind;
}

// ---------------------------------------------------------------------------
// log panel
// ---------------------------------------------------------------------------

const logEl = $("log");
const panel = $("logpanel");

function classify(line) {
  if (line.startsWith("$ ")) return "cmd";
  if (/\berror\b|\bfailed\b|FAILED|Traceback/i.test(line)) return "err";
  if (/SUCCESS|\[flasher\] captured/.test(line)) return "good";
  if (line.startsWith("[flasher]")) return "note";
  return "";
}

function append(line) {
  const span = document.createElement("span");
  const cls = classify(line);
  if (cls) span.className = cls;
  span.textContent = line + "\n";
  logEl.appendChild(span);
  logEl.scrollTop = logEl.scrollHeight;
}

function openLog() {
  panel.classList.remove("collapsed");
  $("toggle").textContent = "Hide log";
}

$("toggle").onclick = () => {
  panel.classList.toggle("collapsed");
  $("toggle").textContent = panel.classList.contains("collapsed") ? "Show log" : "Hide log";
};
$("clearlog").onclick = () => { logEl.textContent = ""; };
$("cancel").onclick = () => api("/api/cancel", {});

// ---------------------------------------------------------------------------
// api
// ---------------------------------------------------------------------------

async function api(path, body) {
  const opts = body === undefined
    ? {}
    : { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) };
  const res = await fetch(path, opts);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `${res.status} ${res.statusText}`);
  return data;
}

function status(el, text, kind) {
  el.textContent = text;
  el.className = (el.classList.contains("config-status") ? "status config-status" : "status")
    + (kind ? " " + kind : "");
}

/** The same message on whichever page you happen to be looking at. */
function configStatus(text, kind) {
  document.querySelectorAll(".config-status").forEach((el) => status(el, text, kind));
}

function busy(on, label) {
  document.querySelectorAll("button[data-flash],button[data-capture],button[data-ota],#flash-remote")
    .forEach((b) => { b.disabled = on; });
  $("cancel").disabled = !on;
  $("joblabel").innerHTML = on ? `<span class="spin"></span>${label}` : (label || "Idle");
}

/** Tail a job's output, resolving with its exit code. */
function follow(jobId, label, onLine) {
  return new Promise((resolve) => {
    openLog();
    busy(true, label);
    if (stream) stream.close();
    stream = new EventSource(`/api/stream/${jobId}`);
    stream.onmessage = (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.done) {
        stream.close();
        stream = null;
        busy(false, msg.returncode === 0 ? `${label} — done` : `${label} — failed`);
        resolve(msg.returncode);
        return;
      }
      if (onLine) onLine(msg.line);
      // The MAC marker is plumbing for the field above, not output worth showing.
      if (!msg.line.startsWith("##MAC##")) append(msg.line);
    };
    stream.onerror = () => {
      if (stream) { stream.close(); stream = null; }
      busy(false, `${label} — connection lost`);
      resolve(-1);
    };
  });
}

// ---------------------------------------------------------------------------
// rendering
// ---------------------------------------------------------------------------

function renderPorts(ports) {
  const options = ports.length
    ? ports.map((p) => `<option value="${escapeAttr(p.device)}">${escapeAttr(p.device)}${p.description ? " — " + escapeAttr(p.description) : ""}</option>`).join("")
    : `<option value="">no serial ports found</option>`;
  ["port-wireless", "port-wired", "port-remote"].forEach((id) => {
    const sel = $(id);
    const previous = sel.value;
    sel.innerHTML = options;
    if (previous) sel.value = previous;
  });
}

function renderMacBadges() {
  [["wired", "hub_mac_wired"], ["wireless", "hub_mac_wireless"]].forEach(([hub, field]) => {
    const badge = $(`badge-${hub}`);
    const value = $(field).value.trim();
    badge.textContent = value ? value.toUpperCase() : "no address yet";
    badge.className = "badge " + (value ? "ok" : "missing");
  });
}

function renderRemotes() {
  const tbody = $("remotes");
  tbody.innerHTML = "";
  state.remotes.forEach((remote, index) => {
    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td><input type="text" data-field="location" value="${escapeAttr(remote.location)}" placeholder="livingroom"></td>
      <td><input type="text" data-field="name" value="${escapeAttr(remote.name)}" placeholder="Living Room Remote"></td>
      <td><select data-field="hub">
            <option value="wired"${remote.hub === "wired" ? " selected" : ""}>Wired hub</option>
            <option value="wireless"${remote.hub === "wireless" ? " selected" : ""}>Wireless hub</option>
          </select></td>
      <td><button class="small danger" data-remove="${index}">Remove</button></td>`;
    tr.querySelectorAll("[data-field]").forEach((input) => {
      const handler = () => {
        state.remotes[index][input.dataset.field] = input.value;
        renderRemoteTargets();
      };
      input.oninput = handler;
      input.onchange = handler;
    });
    tr.querySelector("[data-remove]").onclick = () => {
      state.remotes.splice(index, 1);
      renderRemotes();
    };
    tbody.appendChild(tr);
  });
  renderRemoteTargets();
}

/** Live MAC values, which are the inputs rather than the last saved state. */
function hubMacs() {
  return {
    wired: $("hub_mac_wired").value.trim(),
    wireless: $("hub_mac_wireless").value.trim(),
  };
}

function renderRemoteTargets() {
  const sel = $("remote-target");
  const previous = sel.value;
  const macs = hubMacs();
  sel.innerHTML = state.remotes
    .filter((r) => r.location.trim())
    .map((r) => {
      const loc = r.location.trim();
      // Building against an uncaptured hub gives firmware that transmits into
      // nothing, so say why rather than letting it be picked.
      const blocked = !macs[r.hub];
      const label = `${r.name || loc} — remote_${loc}`
        + (blocked ? ` (needs the ${r.hub} hub's address)` : "");
      return `<option value="remote_${escapeAttr(loc)}"${blocked ? " disabled" : ""}>${escapeAttr(label)}</option>`;
    })
    .join("") || `<option value="">no remotes configured</option>`;
  if (previous) sel.value = previous;
}

function escapeAttr(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
}

// ---------------------------------------------------------------------------
// wiring
// ---------------------------------------------------------------------------

function collectState() {
  // Hidden views keep their inputs in the DOM, so this is correct from any page.
  return {
    wifi_channel: Number($("wifi_channel").value),
    topic_root: $("topic_root").value,
    hold_threshold_ms: Number($("hold_threshold_ms").value),
    hub_mac_wired: $("hub_mac_wired").value.trim(),
    hub_mac_wireless: $("hub_mac_wireless").value.trim(),
    remotes: state.remotes.map((r) => ({
      location: r.location.trim(),
      name: r.name.trim(),
      hub: r.hub,
    })),
  };
}

async function load() {
  const data = await api("/api/state");
  state = data.state;
  secrets = data.secrets;
  SECRET_FIELDS.forEach((f) => { $(f).value = data.secrets[f] || ""; });
  $("wifi_channel").value = state.wifi_channel;
  $("topic_root").value = state.topic_root;
  $("hold_threshold_ms").value = state.hold_threshold_ms;
  $("hub_mac_wired").value = state.hub_mac_wired || "";
  $("hub_mac_wireless").value = state.hub_mac_wireless || "";
  renderPorts(data.ports);
  renderRemotes();
  renderMacBadges();
  refreshTiles();
}

$("save-secrets").onclick = async () => {
  const payload = {};
  SECRET_FIELDS.forEach((f) => { payload[f] = $(f).value; });
  status($("secrets-status"), "saving…", "busy");
  try {
    await api("/api/secrets", payload);
    secrets = payload;
    status($("secrets-status"), "written to include/secrets.h", "ok");
  } catch (err) {
    status($("secrets-status"), err.message, "bad");
  }
};

document.querySelectorAll(".save-config").forEach((btn) => {
  btn.onclick = async () => {
    configStatus("saving…", "busy");
    try {
      const next = collectState();
      await api("/api/config", next);
      Object.assign(state, next);
      configStatus("device_config.h and platformio_local.ini written", "ok");
      renderRemoteTargets();
    } catch (err) {
      configStatus(err.message, "bad");
    }
  };
});

$("add-remote").onclick = () => {
  state.remotes.push({ location: "", name: "", hub: "wired" });
  renderRemotes();
};

["hub_mac_wired", "hub_mac_wireless"].forEach((id) => {
  $(id).oninput = () => {
    renderMacBadges();
    renderRemoteTargets();  // an address arriving unblocks its remotes
  };
});

// flash buttons
document.querySelectorAll("button[data-flash]").forEach((btn) => {
  btn.onclick = async () => {
    const port = $(btn.dataset.port).value;
    if (!port) { openLog(); append("[flasher] no serial port selected"); return; }
    try {
      const { job } = await api("/api/flash", { environment: btn.dataset.flash, port });
      await follow(job, `${btn.dataset.flash} → ${port}`);
    } catch (err) {
      openLog();
      append(`[flasher] ${err.message}`);
    }
  };
});

// over-the-air
document.querySelectorAll("button[data-ota]").forEach((btn) => {
  btn.onclick = async () => {
    const suggested = btn.dataset.ota === "hub_ota" ? "esp_hub_wifi.local" : "esp_hub_eth.local";
    const target = prompt("Hostname or IP of the hub to reflash:", suggested);
    if (!target) return;
    try {
      const { job } = await api("/api/flash", { environment: btn.dataset.ota, port: target });
      await follow(job, `${btn.dataset.ota} → ${target}`);
    } catch (err) {
      openLog();
      append(`[flasher] ${err.message}`);
    }
  };
});

// MAC capture
document.querySelectorAll("button[data-capture]").forEach((btn) => {
  btn.onclick = async () => {
    const hub = btn.dataset.capture;
    const port = $(btn.dataset.port).value;
    if (!port) { openLog(); append("[flasher] no serial port selected"); return; }
    const reset = btn.dataset.noreset !== "1";
    let captured = null;
    try {
      const { job } = await api("/api/capture", { port, reset, timeout: 30 });
      await follow(job, `capture on ${port}`, (line) => {
        if (line.startsWith("##MAC##")) captured = line.slice(7).trim();
      });
    } catch (err) {
      openLog();
      append(`[flasher] ${err.message}`);
      return;
    }
    if (captured) {
      // Assigning .value does not fire oninput, so refresh explicitly.
      $(`hub_mac_${hub}`).value = captured;
      renderMacBadges();
      renderRemoteTargets();
      configStatus(`captured ${captured} — save the configuration to use it`, "ok");
    }
  };
});

$("flash-remote").onclick = async () => {
  const environment = $("remote-target").value;
  const port = $("port-remote").value;
  if (!environment) { openLog(); append("[flasher] no remote configured"); return; }
  if (!port) { openLog(); append("[flasher] no serial port selected"); return; }
  try {
    const { job } = await api("/api/flash", { environment, port });
    await follow(job, `${environment} → ${port}`);
  } catch (err) {
    openLog();
    append(`[flasher] ${err.message}`);
  }
};

// Boards come and go on USB; keep the port lists honest without a refresh.
setInterval(async () => {
  if (stream) return;
  try {
    const { ports } = await api("/api/ports");
    renderPorts(ports);
  } catch (_) { /* server gone; the next action will report it */ }
}, 4000);

// Route first, so navigation still works if the server cannot be reached and
// the page is not left showing nothing.
route();

load().catch((err) => {
  openLog();
  append(`[flasher] could not load state: ${err.message}`);
});
