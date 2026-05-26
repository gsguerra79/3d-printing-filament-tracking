const state = {
  locations: [],
  spools: [],
  usage: [],
  settings: {},
  catalogCount: 0,
  catalogResults: [],
  pendingBarcode: "",
  filters: {
    search: "",
    material: "",
    location: "",
    status: "",
  },
};

const els = {
  addSpoolButton: document.querySelector("#addSpoolButton"),
  spoolDialog: document.querySelector("#spoolDialog"),
  spoolForm: document.querySelector("#spoolForm"),
  spoolDialogTitle: document.querySelector("#spoolDialogTitle"),
  usageDialog: document.querySelector("#usageDialog"),
  usageForm: document.querySelector("#usageForm"),
  usageSpoolName: document.querySelector("#usageSpoolName"),
  cfsGrid: document.querySelector("#cfsGrid"),
  usageList: document.querySelector("#usageList"),
  inventoryGrid: document.querySelector("#inventoryGrid"),
  inventoryCount: document.querySelector("#inventoryCount"),
  cfsCount: document.querySelector("#cfsCount"),
  searchInput: document.querySelector("#searchInput"),
  materialFilter: document.querySelector("#materialFilter"),
  locationFilter: document.querySelector("#locationFilter"),
  statusFilter: document.querySelector("#statusFilter"),
  locationInput: document.querySelector("#locationInput"),
  printerUrlInput: document.querySelector("#printerUrlInput"),
  probePrinterButton: document.querySelector("#probePrinterButton"),
  syncPrinterButton: document.querySelector("#syncPrinterButton"),
  checkUsageButton: document.querySelector("#checkUsageButton"),
  startUsageButton: document.querySelector("#startUsageButton"),
  stopUsageButton: document.querySelector("#stopUsageButton"),
  printerStatus: document.querySelector("#printerStatus"),
  printerOutput: document.querySelector("#printerOutput"),
  catalogResults: document.querySelector("#catalogResults"),
  scanBarcodeButton: document.querySelector("#scanBarcodeButton"),
  stopBarcodeButton: document.querySelector("#stopBarcodeButton"),
  barcodeScanner: document.querySelector("#barcodeScanner"),
  barcodeVideo: document.querySelector("#barcodeVideo"),
  barcodeStatus: document.querySelector("#barcodeStatus"),
};

const fields = {
  spoolId: document.querySelector("#spoolId"),
  barcode: document.querySelector("#barcodeInput"),
  material: document.querySelector("#materialInput"),
  brand: document.querySelector("#brandInput"),
  colorName: document.querySelector("#colorNameInput"),
  colorHex: document.querySelector("#colorHexInput"),
  status: document.querySelector("#statusInput"),
  location: document.querySelector("#locationInput"),
  originalWeight: document.querySelector("#originalWeightInput"),
  remainingWeight: document.querySelector("#remainingWeightInput"),
  diameter: document.querySelector("#diameterInput"),
  purchasedAt: document.querySelector("#purchasedAtInput"),
  openedAt: document.querySelector("#openedAtInput"),
  notes: document.querySelector("#notesInput"),
  usageSpoolId: document.querySelector("#usageSpoolId"),
  gramsUsed: document.querySelector("#gramsUsedInput"),
  project: document.querySelector("#projectInput"),
  usageNotes: document.querySelector("#usageNotesInput"),
};

let barcodeStream = null;
let barcodeDetector = null;
let barcodeScanTimer = null;
let usageTrackingTimer = null;

const materialDensities = {
  PLA: 1.24,
  PETG: 1.27,
  ABS: 1.04,
  ASA: 1.07,
  TPU: 1.2,
  PC: 1.2,
  NYLON: 1.14,
  PA: 1.14,
};

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const data = await response.json();
  if (!response.ok) {
    throw new Error(data.error || "Request failed.");
  }
  return data;
}

async function refresh() {
  const data = await api("/api/bootstrap");
  state.locations = data.locations;
  state.spools = data.spools;
  state.usage = data.usage;
  state.settings = data.settings || {};
  state.catalogCount = data.catalog_count || 0;
  if (!els.printerUrlInput.value && state.settings.printer_base_url) {
    els.printerUrlInput.value = state.settings.printer_base_url;
  }
  render();
}

function spoolTitle(spool) {
  return `${spool.brand} ${spool.color_name}`;
}

function percentRemaining(spool) {
  if (!spool.original_weight_g) return 0;
  return Math.max(
    0,
    Math.min(100, Math.round((spool.remaining_weight_g / spool.original_weight_g) * 100))
  );
}

function filteredSpools() {
  const search = state.filters.search.toLowerCase();
  return state.spools.filter((spool) => {
    const haystack = [
      spool.material,
      spool.brand,
      spool.color_name,
      spool.location_name,
      spool.notes,
    ]
      .join(" ")
      .toLowerCase();
    return (
      (!search || haystack.includes(search)) &&
      (!state.filters.material || spool.material === state.filters.material) &&
      (!state.filters.location || String(spool.location_id) === state.filters.location) &&
      (!state.filters.status || spool.status === state.filters.status)
    );
  });
}

function render() {
  renderSelectors();
  renderMetrics();
  renderCfs();
  renderUsage();
  renderInventory();
  renderPrinterStatus();
}

function renderPrinterStatus(message = null) {
  if (message) {
    els.printerStatus.textContent = message;
    return;
  }
  if (els.printerUrlInput.value) {
    if (!usageTrackingTimer) schedulePageUsageTracking();
    els.printerStatus.textContent = "Auto tracking";
    return;
  }
  if (usageTrackingTimer) {
    window.clearInterval(usageTrackingTimer);
    usageTrackingTimer = null;
  }
  els.printerStatus.textContent = els.printerUrlInput.value ? "Ready" : "Not connected";
}

function renderSelectors() {
  const materials = [
    ...new Set(state.spools.map((spool) => spool.material)),
  ].sort();
  const currentMaterial = els.materialFilter.value;
  els.materialFilter.innerHTML = `<option value="">All</option>${materials
    .map((material) => `<option value="${escapeHtml(material)}">${escapeHtml(material)}</option>`)
    .join("")}`;
  els.materialFilter.value = currentMaterial;

  const locationOptions = state.locations
    .map((location) => `<option value="${location.id}">${escapeHtml(location.name)}</option>`)
    .join("");
  els.locationFilter.innerHTML = `<option value="">All</option>${locationOptions}`;
  els.locationFilter.value = state.filters.location;
  els.locationInput.innerHTML = `<option value="">None</option>${locationOptions}`;
}

function renderMetrics() {
  const active = state.spools.filter((spool) => spool.status !== "retired");
  const open = active.filter((spool) => spool.status === "open" || spool.status === "loaded");
  const sealed = active.filter((spool) => spool.status === "sealed");
  const low = active.filter((spool) => spool.remaining_weight_g < 200);
  document.querySelector("#metricTotal").textContent = active.length;
  document.querySelector("#metricOpen").textContent = open.length;
  document.querySelector("#metricSealed").textContent = sealed.length;
  document.querySelector("#metricLow").textContent = low.length;
}

function renderCfs() {
  const cfsLocations = state.locations.filter((location) => location.kind === "cfs");
  const loaded = state.spools.filter((spool) => spool.status === "loaded");
  const activeSpoolIds = new Set(
    String(state.settings.usage_monitor_active_spool_ids || "")
      .split(",")
      .filter(Boolean)
      .map(Number),
  );
  els.cfsCount.textContent = `${loaded.length} loaded`;
  els.cfsGrid.innerHTML = "";
  cfsLocations.forEach((location) => {
    const slot = document.createElement("article");
    slot.className = "slot";
    const spool = state.spools.find(
      (candidate) => candidate.location_id === location.id && candidate.status !== "retired"
    );
    const isActive = spool && activeSpoolIds.has(spool.id);
    slot.classList.toggle("active-slot", Boolean(isActive));
    slot.innerHTML = `
      <p class="slot-name">
        <span>${escapeHtml(location.name)}</span>
        ${isActive ? `<span class="slot-active-flag">In use</span>` : ""}
      </p>
    `;
    if (spool) {
      slot.appendChild(createSpoolCard(spool, true));
    } else {
      slot.innerHTML += `<div class="empty-slot">Empty</div>`;
    }
    els.cfsGrid.appendChild(slot);
  });
}

function renderUsage() {
  if (!state.usage.length) {
    els.usageList.innerHTML = `<div class="empty-state">No usage logged yet</div>`;
    return;
  }
  els.usageList.innerHTML = state.usage
    .slice(0, 8)
    .map((event) => {
      const date = new Date(event.created_at).toLocaleDateString();
      const title = `${event.grams_used}g - ${event.brand} ${event.color_name}`;
      const note = event.project || event.notes || event.material;
      return `
        <article class="usage-item">
          <span class="usage-dot" style="background:${escapeHtml(event.color_hex)}"></span>
          <div>
            <p class="usage-title">${escapeHtml(title)}</p>
            <p class="usage-note">${escapeHtml(note)}</p>
          </div>
          <span class="usage-date">${escapeHtml(date)}</span>
        </article>
      `;
    })
    .join("");
}

function renderInventory() {
  const spools = filteredSpools();
  els.inventoryCount.textContent = `${spools.length} ${spools.length === 1 ? "spool" : "spools"}`;
  if (!spools.length) {
    els.inventoryGrid.innerHTML = `<div class="empty-state">No matching spools</div>`;
    return;
  }
  els.inventoryGrid.innerHTML = "";
  spools.forEach((spool) => els.inventoryGrid.appendChild(createSpoolCard(spool)));
}

function materialBadge(material) {
  const text = String(material || "").toUpperCase();
  if (text.includes("TPU")) return "TPU";
  if (text.includes("PETG")) return "PETG";
  if (text.includes("ABS") || text.includes("ASA")) return "ABS";
  return "PLA";
}

function contrastTextColor(hexColor) {
  const hex = String(hexColor || "").replace("#", "").trim();
  const normalized = hex.length === 3
    ? hex.split("").map((char) => char + char).join("")
    : hex;
  if (!/^[0-9a-f]{6}$/i.test(normalized)) return "#111111";
  const red = parseInt(normalized.slice(0, 2), 16);
  const green = parseInt(normalized.slice(2, 4), 16);
  const blue = parseInt(normalized.slice(4, 6), 16);
  const brightness = (red * 299 + green * 587 + blue * 114) / 1000;
  return brightness > 145 ? "#111111" : "#ffffff";
}

function spoolIconSvg() {
  return `
    <svg class="cfs-spool-icon" viewBox="0 0 82 96" aria-hidden="true" focusable="false">
      <ellipse class="spool-shadow" cx="39" cy="91" rx="29" ry="4" />
      <ellipse class="spool-rear" cx="20" cy="48" rx="20" ry="45" />
      <path class="spool-filament-body" d="M 20 12 L 58 12 C 64 28 64 68 58 84 L 20 84 C 8 68 8 28 20 12 Z" />
      <ellipse class="spool-front-outer" cx="58" cy="48" rx="20" ry="45" />
      <ellipse class="spool-front-face" cx="58" cy="48" rx="15" ry="36" />
      <path class="spool-edge-highlight" d="M 50 6 C 67 6 78 25 78 48 C 78 71 67 90 50 90" />
      <path class="spool-side-highlight" d="M 21 14 L 56 14" />
      <ellipse class="spool-hub-rim" cx="58" cy="48" rx="10" ry="19" />
      <ellipse class="spool-hub" cx="58" cy="48" rx="7" ry="14" />
    </svg>
  `;
}

function createSpoolCard(spool, compact = false) {
  const template = document.querySelector("#spoolCardTemplate");
  const card = template.content.firstElementChild.cloneNode(true);
  const percent = percentRemaining(spool);
  card.dataset.id = spool.id;
  card.classList.toggle("compact", compact);
  card.classList.toggle("low", percent <= 20);
  const swatch = card.querySelector(".swatch");
  swatch.style.background = spool.color_hex;
  swatch.style.setProperty("--spool-color", spool.color_hex);
  swatch.innerHTML = compact ? spoolIconSvg() : `<span class="swatch-label">${materialBadge(spool.material)}</span>`;
  swatch.querySelector(".swatch-label")?.style.setProperty("color", contrastTextColor(spool.color_hex));
  card.querySelector("h3").textContent = spoolTitle(spool);
  card.querySelector(".spool-meta").textContent = spool.material;
  card.querySelector(".weight-label").textContent = `${spool.remaining_weight_g}g of ${spool.original_weight_g}g (${percent}%)`;
  card.querySelector(".bar span").style.width = `${percent}%`;

  let tags = [];
  if (!compact) {
    tags = [
      `<span class="tag ${spool.status}">${labelStatus(spool.status)}</span>`,
      `<span class="tag">${escapeHtml(spool.location_name || "No location")}</span>`,
    ];
  }
  card.querySelector(".tag-row").innerHTML = tags.join("");

  card.querySelector('[data-action="edit"]').addEventListener("click", () => openSpoolDialog(spool));
  card.querySelector('[data-action="usage"]').addEventListener("click", () => openUsageDialog(spool));
  card.querySelector('[data-action="retire"]').addEventListener("click", () => retireSpool(spool));
  card.querySelector('[data-action="delete"]').addEventListener("click", () => deleteSpool(spool));
  if (compact) {
    card.querySelector('[data-action="usage"]').remove();
    card.querySelector('[data-action="retire"]').remove();
    card.querySelector('[data-action="delete"]').remove();
  }
  return card;
}

function closeCardMenus(exceptMenu = null) {
  document.querySelectorAll(".card-menu[open]").forEach((menu) => {
    if (menu !== exceptMenu) {
      menu.removeAttribute("open");
    }
  });
}

function setupCardMenus() {
  document.addEventListener(
    "toggle",
    (event) => {
      const menu = event.target;
      if (menu.matches?.(".card-menu") && menu.open) {
        closeCardMenus(menu);
      }
    },
    true,
  );

  document.addEventListener("click", (event) => {
    const menu = event.target.closest?.(".card-menu");
    if (!menu || event.target.closest(".card-actions button")) {
      closeCardMenus();
    }
  });
}

function labelStatus(status) {
  return {
    loaded: "Loaded",
    open: "Open",
    sealed: "Sealed",
    retired: "Retired",
  }[status] || status;
}

function openSpoolDialog(spool = null) {
  els.spoolForm.reset();
  renderSelectors();
  els.spoolDialogTitle.textContent = spool ? "Edit Spool" : "Add Spool";
  fields.spoolId.value = spool?.id || "";
  state.catalogResults = [];
  state.pendingBarcode = "";
  renderCatalogResults();
  setBarcodeStatus("");
  fields.barcode.value = spool?.barcode || "";
  fields.material.value = spool?.material || "PLA";
  fields.brand.value = spool?.brand || "";
  fields.colorName.value = spool?.color_name || "";
  fields.colorHex.value = spool?.color_hex || "#333333";
  fields.status.value = spool?.status || "sealed";
  fields.location.value = spool?.location_id || defaultLocationForStatus(fields.status.value);
  fields.originalWeight.value = spool?.original_weight_g ?? 1000;
  fields.remainingWeight.value = spool?.remaining_weight_g ?? 1000;
  fields.diameter.value = spool?.diameter || "1.75mm";
  fields.purchasedAt.value = spool?.purchased_at || "";
  fields.openedAt.value = spool?.opened_at || "";
  fields.notes.value = spool?.notes || "";
  els.spoolDialog.showModal();
}

function openUsageDialog(spool) {
  els.usageForm.reset();
  fields.usageSpoolId.value = spool.id;
  els.usageSpoolName.textContent = `${spoolTitle(spool)} - ${spool.remaining_weight_g}g remaining`;
  fields.gramsUsed.max = spool.remaining_weight_g;
  els.usageDialog.showModal();
}

async function retireSpool(spool) {
  const retiredLocation = state.locations.find((location) => location.kind === "retired");
  await api(`/api/spools/${spool.id}`, {
    method: "PUT",
    body: JSON.stringify({
      ...spool,
      status: "retired",
      location_id: retiredLocation?.id || spool.location_id,
    }),
  });
  await refresh();
}

async function deleteSpool(spool) {
  const confirmed = window.confirm(`Delete ${spoolTitle(spool)} from the database? This cannot be undone.`);
  if (!confirmed) return;
  await api(`/api/spools/${spool.id}`, { method: "DELETE" });
  await refresh();
}

function defaultLocationForStatus(status) {
  const match =
    status === "loaded"
      ? state.locations.find((location) => location.kind === "cfs")
      : status === "open"
        ? state.locations.find((location) => location.kind === "dryer")
        : status === "retired"
          ? state.locations.find((location) => location.kind === "retired")
          : state.locations.find((location) => location.name === "Sealed Stock");
  return match?.id || "";
}

function payloadFromSpoolForm() {
  return {
    barcode: fields.barcode.value,
    material: fields.material.value,
    brand: fields.brand.value,
    color_name: fields.colorName.value,
    color_hex: fields.colorHex.value,
    status: fields.status.value,
    location_id: fields.location.value,
    original_weight_g: fields.originalWeight.value,
    remaining_weight_g: fields.remainingWeight.value,
    diameter: fields.diameter.value,
    purchased_at: fields.purchasedAt.value,
    opened_at: fields.openedAt.value,
    notes: fields.notes.value,
  };
}

function setBarcodeStatus(message) {
  els.barcodeStatus.textContent = message;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function printerPayload() {
  return { base_url: els.printerUrlInput.value.trim() };
}

function printerBaseUrl() {
  const value = els.printerUrlInput.value.trim();
  if (!value) throw new Error("Printer address is required.");
  return value.startsWith("http://") || value.startsWith("https://") ? value.replace(/\/+$/, "") : `http://${value}`;
}

function showPrinterOutput(message, detail = null) {
  els.printerOutput.hidden = false;
  els.printerOutput.textContent = detail
    ? `${message}\n${JSON.stringify(detail, null, 2)}`
    : message;
}

async function probePrinter() {
  renderPrinterStatus("Testing...");
  try {
    const result = await api("/api/printer/probe", {
      method: "POST",
      body: JSON.stringify(printerPayload()),
    });
    const candidates = result.cfs_candidates?.length
      ? result.cfs_candidates.join(", ")
      : "No obvious CFS object names found";
    renderPrinterStatus("Connected");
    showPrinterOutput(
      `Connected to printer. Found ${result.object_count} printer objects.\nCFS candidates: ${candidates}`,
      result.printer
    );
  } catch (error) {
    renderPrinterStatus("Could not connect");
    showPrinterOutput(error.message);
  }
}

async function syncPrinter() {
  renderPrinterStatus("Syncing...");
  try {
    const result = await api("/api/printer/sync", {
      method: "POST",
      body: JSON.stringify(printerPayload()),
    });
    state.locations = result.locations;
    state.spools = result.spools;
    state.usage = result.usage;
    state.settings = result.settings || state.settings;
    state.catalogCount = result.catalog_count || state.catalogCount;
    renderPrinterStatus("Synced");
    showPrinterOutput(`Synced ${result.synced} CFS slot${result.synced === 1 ? "" : "s"} from ${result.source}.`);
    render();
  } catch (error) {
    renderPrinterStatus("Sync failed");
    showPrinterOutput(error.message);
  }
}

function applyBootstrapPayload(result) {
  state.locations = result.locations;
  state.spools = result.spools;
  state.usage = result.usage;
  state.settings = result.settings || state.settings;
  state.catalogCount = result.catalog_count || state.catalogCount;
}

function usageSummary(result) {
  const snapshot = result.snapshot;
  const fileLine = snapshot?.filename ? `\nPrint: ${snapshot.filename}` : "";
  const progressLine =
    snapshot?.progress !== undefined
      ? `\nProgress: ${Math.round(snapshot.progress * 1000) / 10}%`
      : "";
  const allocationLine = result.allocations?.length
    ? `\n${result.allocations.map((item) => `${item.grams}g - ${item.spool}`).join("\n")}`
    : "";
  return `${result.message || "Usage tracking updated."}${fileLine}${progressLine}${allocationLine}`;
}

function cleanNumber(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function densityForMaterial(material) {
  const text = String(material || "").toUpperCase();
  const match = Object.entries(materialDensities).find(([key]) => text.includes(key));
  return match ? match[1] : 1.24;
}

function filamentMmToGrams(lengthMm, material, diameterMm = 1.75) {
  const areaMm2 = Math.PI * (diameterMm / 2) ** 2;
  const volumeCm3 = (Math.max(0, lengthMm) * areaMm2) / 1000;
  return volumeCm3 * densityForMaterial(material);
}

function normalizeColor(value) {
  const text = String(value || "").trim();
  if (/^[0-9a-fA-F]{6}$/.test(text)) return `#${text}`;
  if (/^#[0-9a-fA-F]{6}$/.test(text)) return text;
  if (/^#[0-9a-fA-F]{8}$/.test(text)) return `#${text.slice(-6)}`;
  return "";
}

async function printerJson(path) {
  const response = await fetch(`${printerBaseUrl()}${path}`, { headers: { Accept: "application/json" } });
  if (!response.ok) throw new Error(`Printer answered with ${response.status}`);
  const data = await response.json();
  return data.result || data;
}

async function fetchPrinterStatus() {
  try {
    const payload = await printerJson("/printer/objects/query?print_stats&virtual_sdcard");
    const status = payload.status || payload;
    if (status.print_stats || status.virtual_sdcard) return status;
  } catch (error) {
    // Some printer builds do not accept combined object queries.
  }
  const [printStatsPayload, sdcardPayload] = await Promise.all([
    printerJson("/printer/objects/query?print_stats"),
    printerJson("/printer/objects/query?virtual_sdcard"),
  ]);
  return {
    print_stats: (printStatsPayload.status || printStatsPayload).print_stats || {},
    virtual_sdcard: (sdcardPayload.status || sdcardPayload).virtual_sdcard || {},
  };
}

async function fetchPrinterUsageSnapshotFromPage() {
  const status = await fetchPrinterStatus();
  const printStats = status.print_stats || {};
  const sdcard = status.virtual_sdcard || {};
  const currentPrint = sdcard.cur_print_data || {};
  const metadata = currentPrint.metadata || {};
  const modelInfo = metadata.model_info || {};
  const filename =
    printStats.filename ||
    currentPrint.filename ||
    String(sdcard.file_path || "").split("/").pop() ||
    "";
  const state = printStats.state || currentPrint.status || "";
  const startTime = currentPrint.start_time || metadata.uuid || "";
  const material = String(metadata.filament_type || modelInfo.MaterialType || printStats.filament_type || "").toUpperCase();
  const progress = Math.max(0, Math.min(cleanNumber(sdcard.progress, 0), 1));
  const plannedGrams = Array.isArray(metadata.filament_used_g)
    ? metadata.filament_used_g.map((item) => Math.max(0, cleanNumber(item, 0)))
    : [];
  const plannedTotalGrams = plannedGrams.reduce((sum, item) => sum + item, 0);
  const filamentUsedMm = cleanNumber(printStats.filament_used || currentPrint.filament_used, 0);
  const usedGrams =
    plannedTotalGrams > 0 && progress > 0
      ? plannedTotalGrams * progress
      : filamentMmToGrams(filamentUsedMm, material || "PLA");
  const colors = Array.isArray(metadata.default_filament_colour) ? metadata.default_filament_colour : [];
  let parts = plannedGrams
    .map((grams, index) => ({
      index,
      planned_g: grams,
      material,
      color_hex: normalizeColor(colors[index]),
    }))
    .filter((part) => part.planned_g > 0);
  if (!parts.length) {
    parts = [{ index: 0, planned_g: Math.max(plannedTotalGrams, 1), material, color_hex: "" }];
  }
  return {
    filename,
    signature: filename ? `${filename}|${startTime}` : "",
    state,
    progress,
    material,
    planned_total_g: plannedTotalGrams,
    used_grams: Math.max(0, usedGrams),
    filament_used_mm: filamentUsedMm,
    basis: plannedTotalGrams > 0 && progress > 0 ? "browser slicer progress" : "browser extrusion length",
    parts,
  };
}

async function applyPrinterUsageSnapshot({ reset = false, enable = false } = {}) {
  try {
    const snapshot = await fetchPrinterUsageSnapshotFromPage();
    const result = await api("/api/printer/usage/snapshot", {
      method: "POST",
      body: JSON.stringify({
        base_url: printerBaseUrl(),
        snapshot,
        reset,
        enable,
      }),
    });
    applyBootstrapPayload(result);
    return result;
  } catch (directError) {
    const fallbackPath = enable ? "/api/printer/usage/start" : "/api/printer/usage/check";
    try {
      const result = await api(fallbackPath, {
        method: "POST",
        body: JSON.stringify({ ...printerPayload(), reset }),
      });
      applyBootstrapPayload(result);
      return {
        ...result,
        message: `${result.message || "Usage tracking updated."} Browser access was blocked, so the local app read the printer instead.`,
      };
    } catch (backendError) {
      throw new Error(
        `Could not read the printer from the browser or the local app. Browser said: ${directError.message}. Local app said: ${backendError.message}.`
      );
    }
  }
}

function schedulePageUsageTracking() {
  window.clearInterval(usageTrackingTimer);
  usageTrackingTimer = window.setInterval(async () => {
    try {
      const result = await applyPrinterUsageSnapshot();
      if (result.deducted) {
        showPrinterOutput(usageSummary(result));
        render();
      }
    } catch (error) {
      showPrinterOutput(`Usage tracking paused: ${error.message}`);
    }
  }, 30000);
}

async function checkPrinterUsage(reset = false) {
  renderPrinterStatus(reset ? "Setting baseline..." : "Checking usage...");
  try {
    const result = await applyPrinterUsageSnapshot({ reset });
    renderPrinterStatus();
    showPrinterOutput(usageSummary(result));
    render();
  } catch (error) {
    renderPrinterStatus("Usage check failed");
    showPrinterOutput(error.message);
  }
}

async function startUsageTracking() {
  renderPrinterStatus("Starting tracking...");
  try {
    const result = await applyPrinterUsageSnapshot({ reset: true, enable: true });
    schedulePageUsageTracking();
    renderPrinterStatus();
    showPrinterOutput(`${usageSummary(result)}\nUsage tracking is now automatic while the local tracker is running.`);
    render();
  } catch (error) {
    renderPrinterStatus("Tracking failed");
    showPrinterOutput(error.message);
  }
}

async function stopUsageTracking() {
  renderPrinterStatus("Stopping tracking...");
  try {
    const result = await api("/api/printer/usage/stop", {
      method: "POST",
      body: JSON.stringify({}),
    });
    applyBootstrapPayload(result);
    window.clearInterval(usageTrackingTimer);
    usageTrackingTimer = null;
    renderPrinterStatus();
    showPrinterOutput("Usage tracking stopped.");
    render();
  } catch (error) {
    renderPrinterStatus("Stop failed");
    showPrinterOutput(error.message);
  }
}

function renderCatalogResults() {
  if (state.pendingBarcode) {
    renderBarcodeCandidates();
    return;
  }
  if (!state.catalogCount) {
    els.catalogResults.innerHTML = `<div class="catalog-help">No catalog loaded yet.</div>`;
    return;
  }
  const typed = [fields.brand.value, fields.material.value, fields.colorName.value]
    .join(" ")
    .trim();
  if (typed.length < 2) {
    els.catalogResults.innerHTML = `<div class="catalog-help">Catalog matches appear here as you enter brand, material, and color. You can save manual entries even when there is no match.</div>`;
    return;
  }
  if (!state.catalogResults.length) {
    els.catalogResults.innerHTML = `<div class="catalog-help">No catalog matches.</div>`;
    return;
  }
  els.catalogResults.innerHTML = state.catalogResults
    .map(
      (item) => `
        <button class="catalog-result" type="button" data-catalog-id="${item.id}">
          <span class="catalog-swatch" style="background:${escapeHtml(item.color_hex || "#888888")}"></span>
          <span>
            <strong>${escapeHtml(item.brand)}</strong>
            <small>${escapeHtml(item.material)} / ${escapeHtml(item.color_name)}</small>
          </span>
        </button>
      `
    )
    .join("");
  els.catalogResults.querySelectorAll("[data-catalog-id]").forEach((button) => {
    button.addEventListener("click", () => {
      const selected = state.catalogResults.find((item) => String(item.id) === button.dataset.catalogId);
      if (selected) applyCatalogItem(selected);
    });
  });
}

function applyCatalogItem(selected) {
  if (selected.barcode && !fields.barcode.value) {
    fields.barcode.value = selected.barcode;
  }
  fields.brand.value = selected.brand;
  fields.material.value = selected.material;
  fields.colorName.value = selected.color_name;
  fields.colorHex.value = selected.color_hex || "#888888";
  state.catalogResults = [];
  state.pendingBarcode = "";
  renderCatalogResults();
}

function applySpoolProduct(spool) {
  fields.brand.value = spool.brand;
  fields.material.value = spool.material;
  fields.colorName.value = spool.color_name;
  fields.colorHex.value = spool.color_hex || "#888888";
  fields.diameter.value = spool.diameter || "1.75mm";
  fields.originalWeight.value = spool.original_weight_g || 1000;
  fields.remainingWeight.value = spool.original_weight_g || 1000;
  state.catalogResults = [];
  state.pendingBarcode = "";
  renderCatalogResults();
}

function candidateSpools() {
  const hasSpecificText = fields.brand.value.trim() || fields.colorName.value.trim();
  const materialText =
    hasSpecificText || fields.material.value.trim().toUpperCase() !== "PLA"
      ? fields.material.value
      : "";
  const terms = [fields.brand.value, materialText, fields.colorName.value]
    .join(" ")
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean);
  return state.spools
    .filter((spool) => spool.status !== "retired")
    .filter((spool) => {
      if (!terms.length) return true;
      const haystack = [spool.brand, spool.material, spool.color_name].join(" ").toLowerCase();
      return terms.every((term) => haystack.includes(term));
    })
    .sort((a, b) => {
      const statusOrder = { sealed: 1, open: 2, loaded: 3, retired: 4 };
      return (
        (statusOrder[a.status] || 9) - (statusOrder[b.status] || 9) ||
        a.brand.localeCompare(b.brand) ||
        a.color_name.localeCompare(b.color_name)
      );
    })
    .slice(0, 30);
}

function renderBarcodeCandidates() {
  const spools = candidateSpools();
  if (!spools.length) {
    els.catalogResults.innerHTML = `<div class="catalog-help">No barcode match yet. Enter the filament details, then save; this barcode will be remembered next time.</div>`;
    return;
  }
  els.catalogResults.innerHTML = `
    <div class="catalog-help">No barcode match yet. Pick the matching filament below to teach this barcode.</div>
    ${spools
      .map(
        (spool) => `
          <button class="catalog-result" type="button" data-barcode-spool-id="${spool.id}">
            <span class="catalog-swatch" style="background:${escapeHtml(spool.color_hex || "#888888")}"></span>
            <span>
              <strong>${escapeHtml(spool.brand)} ${escapeHtml(spool.color_name)}</strong>
              <small>${escapeHtml(spool.material)} / ${escapeHtml(labelStatus(spool.status))} / ${escapeHtml(spool.location_name || "No location")}</small>
            </span>
          </button>
        `
      )
      .join("")}
  `;
  els.catalogResults.querySelectorAll("[data-barcode-spool-id]").forEach((button) => {
    button.addEventListener("click", () => {
      const selected = state.spools.find((spool) => String(spool.id) === button.dataset.barcodeSpoolId);
      if (selected) {
        applySpoolProduct(selected);
        setBarcodeStatus("Product details copied. Save to remember this barcode.");
      }
    });
  });
}

function debounce(fn, delay = 250) {
  let timer = null;
  return (...args) => {
    window.clearTimeout(timer);
    timer = window.setTimeout(() => fn(...args), delay);
  };
}

async function searchCatalog() {
  const brand = fields.brand.value.trim();
  const material = fields.material.value.trim();
  const color = fields.colorName.value.trim();
  if ([brand, material, color].join(" ").trim().length < 2) {
    state.catalogResults = [];
    renderCatalogResults();
    return;
  }
  try {
    const params = new URLSearchParams({
      brand,
      material,
      color,
      limit: "30",
    });
    const data = await api(`/api/catalog/search?${params.toString()}`);
    state.catalogResults = data.results || [];
    renderCatalogResults();
  } catch (error) {
    state.catalogResults = [];
    els.catalogResults.innerHTML = `<div class="catalog-help">Catalog search failed.</div>`;
  }
}

async function lookupBarcode(code) {
  const barcode = String(code || "").trim();
  if (!barcode) return;
  fields.barcode.value = barcode;
  setBarcodeStatus(`Found ${barcode}. Looking for a match...`);
  try {
    const params = new URLSearchParams({ code: barcode });
    const data = await api(`/api/barcode/lookup?${params.toString()}`);
    if (data.spools?.length) {
      applySpoolProduct(data.spools[0]);
      setBarcodeStatus("Matched an existing spool. Product details copied.");
      return;
    }
    if (data.catalog?.length) {
      applyCatalogItem(data.catalog[0]);
      setBarcodeStatus("Matched the catalog. Product details copied.");
      return;
    }
    state.pendingBarcode = barcode;
    state.catalogResults = [];
    renderBarcodeCandidates();
    setBarcodeStatus("No match yet. Pick an existing filament below or fill the details once.");
  } catch (error) {
    setBarcodeStatus("Barcode lookup failed. You can still save it manually.");
  }
}

async function scanVideoFrame() {
  if (!barcodeDetector || !barcodeStream) return;
  try {
    const codes = await barcodeDetector.detect(els.barcodeVideo);
    if (codes.length) {
      const value = codes[0].rawValue;
      stopBarcodeScanner();
      await lookupBarcode(value);
      return;
    }
    barcodeScanTimer = window.setTimeout(scanVideoFrame, 180);
  } catch (error) {
    barcodeScanTimer = window.setTimeout(scanVideoFrame, 350);
  }
}

async function startBarcodeScanner() {
  if (!("BarcodeDetector" in window) || !navigator.mediaDevices?.getUserMedia) {
    setBarcodeStatus("Camera barcode scanning is not available in this browser.");
    els.barcodeScanner.hidden = false;
    return;
  }
  stopBarcodeScanner();
  els.barcodeScanner.hidden = false;
  setBarcodeStatus("Starting camera...");
  try {
    barcodeDetector = new BarcodeDetector({
      formats: ["ean_13", "ean_8", "upc_a", "upc_e", "code_128", "code_39", "qr_code"],
    });
    barcodeStream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: "environment" },
      audio: false,
    });
    els.barcodeVideo.srcObject = barcodeStream;
    await els.barcodeVideo.play();
    setBarcodeStatus("Point the camera at the box barcode");
    scanVideoFrame();
  } catch (error) {
    setBarcodeStatus("Could not start the camera. Check browser camera permission.");
    stopBarcodeScanner(false);
  }
}

function stopBarcodeScanner(hide = true) {
  if (barcodeScanTimer) {
    window.clearTimeout(barcodeScanTimer);
    barcodeScanTimer = null;
  }
  if (barcodeStream) {
    barcodeStream.getTracks().forEach((track) => track.stop());
    barcodeStream = null;
  }
  els.barcodeVideo.srcObject = null;
  if (hide) {
    els.barcodeScanner.hidden = true;
  }
}

els.addSpoolButton.addEventListener("click", () => openSpoolDialog());
els.probePrinterButton.addEventListener("click", probePrinter);
els.syncPrinterButton.addEventListener("click", syncPrinter);
els.checkUsageButton.addEventListener("click", () => checkPrinterUsage(false));
els.startUsageButton?.addEventListener("click", startUsageTracking);
els.stopUsageButton?.addEventListener("click", stopUsageTracking);
els.printerUrlInput.addEventListener("input", () => renderPrinterStatus());
els.scanBarcodeButton.addEventListener("click", startBarcodeScanner);
els.stopBarcodeButton.addEventListener("click", () => stopBarcodeScanner());
fields.barcode.addEventListener("change", () => lookupBarcode(fields.barcode.value));
[fields.brand, fields.material, fields.colorName].forEach((input) => {
  input.addEventListener("input", debounce(() => {
    if (state.pendingBarcode) {
      renderBarcodeCandidates();
    } else {
      searchCatalog();
    }
  }, 220));
});

document.querySelectorAll("[data-close-dialog]").forEach((button) => {
  button.addEventListener("click", () => {
    stopBarcodeScanner();
    button.closest("dialog").close();
  });
});

els.spoolDialog.addEventListener("close", () => stopBarcodeScanner());

els.spoolForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const id = fields.spoolId.value;
  await api(id ? `/api/spools/${id}` : "/api/spools", {
    method: id ? "PUT" : "POST",
    body: JSON.stringify(payloadFromSpoolForm()),
  });
  stopBarcodeScanner();
  els.spoolDialog.close();
  await refresh();
});

els.usageForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  await api(`/api/spools/${fields.usageSpoolId.value}/usage`, {
    method: "POST",
    body: JSON.stringify({
      grams_used: fields.gramsUsed.value,
      project: fields.project.value,
      notes: fields.usageNotes.value,
    }),
  });
  els.usageDialog.close();
  await refresh();
});

fields.status.addEventListener("change", () => {
  fields.location.value = defaultLocationForStatus(fields.status.value);
});

setupCardMenus();

[
  [els.searchInput, "search"],
  [els.materialFilter, "material"],
  [els.locationFilter, "location"],
  [els.statusFilter, "status"],
].forEach(([input, key]) => {
  input.addEventListener("input", () => {
    state.filters[key] = input.value;
    render();
  });
});

refresh().catch((error) => {
  document.body.innerHTML = `<main><div class="empty-state">${escapeHtml(error.message)}</div></main>`;
});
