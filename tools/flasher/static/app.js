"use strict";

const SECRET_FIELDS = [
  "WIFI_SSID", "WIFI_PASSWORD", "MQTT_HOST", "MQTT_PORT",
  "MQTT_USERNAME", "MQTT_PASSWORD", "OTA_PASSWORD",
];

let state = null;
let stream = null;

const $ = (id) => document.getElementById(id);

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
  el.className = "status" + (kind ? " " + kind : "");
}

function busy(on, label) {
  document.querySelectorAll("button[data-flash],button[data-capture],button[data-ota],#flash-remote")
    .forEach((b) => { b.disabled = on; });
  $("cancel").disabled = !on;
  $("joblabel").innerHTML = on
    ? `<span class="spin"></span>${label}`
    : (label || "Idle");
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
    ? ports.map((p) => `<option value="${p.device}">${p.device}${p.description ? " — " + p.description : ""}</option>`).join("")
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
      input.oninput = () => {
        state.remotes[index][input.dataset.field] = input.value;
        renderRemoteTargets();
      };
    });
    tr.querySelector("[data-remove]").onclick = () => {
      state.remotes.splice(index, 1);
      renderRemotes();
    };
    tbody.appendChild(tr);
  });
  renderRemoteTargets();
}

function renderRemoteTargets() {
  const sel = $("remote-target");
  const previous = sel.value;
  sel.innerHTML = state.remotes
    .filter((r) => r.location.trim())
    .map((r) => `<option value="remote_${r.location.trim()}">${escapeAttr(r.name || r.location)} — remote_${escapeAttr(r.location.trim())}</option>`)
    .join("") || `<option value="">no remotes configured</option>`;
  if (previous) sel.value = previous;
}

function escapeAttr(value) {
  return String(value == null ? "" : value).replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
}

// ---------------------------------------------------------------------------
// wiring
// ---------------------------------------------------------------------------

function collectState() {
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
  SECRET_FIELDS.forEach((f) => { $(f).value = data.secrets[f] || ""; });
  $("wifi_channel").value = state.wifi_channel;
  $("topic_root").value = state.topic_root;
  $("hold_threshold_ms").value = state.hold_threshold_ms;
  $("hub_mac_wired").value = state.hub_mac_wired || "";
  $("hub_mac_wireless").value = state.hub_mac_wireless || "";
  renderPorts(data.ports);
  renderRemotes();
  renderMacBadges();
}

$("save-secrets").onclick = async () => {
  const payload = {};
  SECRET_FIELDS.forEach((f) => { payload[f] = $(f).value; });
  status($("secrets-status"), "saving…", "busy");
  try {
    await api("/api/secrets", payload);
    status($("secrets-status"), "written to include/secrets.h", "ok");
  } catch (err) {
    status($("secrets-status"), err.message, "bad");
  }
};

$("save-config").onclick = async () => {
  status($("config-status"), "saving…", "busy");
  try {
    await api("/api/config", collectState());
    status($("config-status"), "device_config.h and platformio_local.ini written", "ok");
    renderRemoteTargets();
  } catch (err) {
    status($("config-status"), err.message, "bad");
  }
};

$("add-remote").onclick = () => {
  state.remotes.push({ location: "", name: "", hub: "wired" });
  renderRemotes();
};

["hub_mac_wired", "hub_mac_wireless"].forEach((id) => {
  $(id).oninput = renderMacBadges;
});

// flash buttons
document.querySelectorAll("button[data-flash]").forEach((btn) => {
  btn.onclick = async () => {
    const port = $(btn.dataset.port).value;
    if (!port) { openLog(); append("[flasher] no serial port selected"); return; }
    const { job } = await api("/api/flash", { environment: btn.dataset.flash, port });
    await follow(job, `${btn.dataset.flash} → ${port}`);
  };
});

// over-the-air
document.querySelectorAll("button[data-ota]").forEach((btn) => {
  btn.onclick = async () => {
    const host = btn.dataset.ota === "hub_ota" ? "esp_hub_wifi.local" : "esp_hub_eth.local";
    const target = prompt("Hostname or IP of the hub to reflash:", host);
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
    const { job } = await api("/api/capture", { port, reset, timeout: 30 });
    await follow(job, `capture on ${port}`, (line) => {
      const marker = line.indexOf("##MAC##");
      if (marker === 0) captured = line.slice(7).trim();
    });
    if (captured) {
      $(`hub_mac_${hub}`).value = captured;
      renderMacBadges();
      status($("config-status"), `captured ${captured} — save the configuration to use it`, "ok");
    }
  };
});

$("flash-remote").onclick = async () => {
  const environment = $("remote-target").value;
  const port = $("port-remote").value;
  if (!environment) { openLog(); append("[flasher] no remote configured"); return; }
  if (!port) { openLog(); append("[flasher] no serial port selected"); return; }
  const { job } = await api("/api/flash", { environment, port });
  await follow(job, `${environment} → ${port}`);
};

// Boards come and go on USB; keep the port lists honest without a refresh.
setInterval(async () => {
  if (stream) return;
  try {
    const { ports } = await api("/api/ports");
    renderPorts(ports);
  } catch (_) { /* server gone; the next action will report it */ }
}, 4000);

load().catch((err) => {
  openLog();
  append(`[flasher] could not load state: ${err.message}`);
});
