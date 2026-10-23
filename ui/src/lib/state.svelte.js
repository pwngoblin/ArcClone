// Reactive app state (Svelte 5 runes) fed by native events.
import { request, on, newRequestId, NativeError } from "./bridge.js";

const MODEL_KEY = "arcclone.model";

function readStoredModel() {
  try {
    return localStorage.getItem(MODEL_KEY) || "";
  } catch {
    return "";
  }
}

class BrowserState {
  tabs = $state([]);
  activeTabId = $state(null);
  canReopenClosed = $state(false);
  selection = $state(null);
  toast = $state(null);
  commandBar = $state({ open: false, newTab: true, seed: "" });
  addressFocusTick = $state(0);

  activeTab = $derived(this.tabs.find((t) => t.id === this.activeTabId) ?? null);
  pinned = $derived(this.tabs.filter((t) => t.pinned));
  unpinned = $derived(this.tabs.filter((t) => !t.pinned));

  applyState(s) {
    if (!s) return;
    this.tabs = s.tabs ?? [];
    this.activeTabId = s.activeTabId ?? null;
    this.canReopenClosed = Boolean(s.canReopenClosed);
  }

  showToast(message) {
    const t = { message, at: Date.now() };
    this.toast = t;
    setTimeout(() => {
      if (this.toast === t) this.toast = null;
    }, 2200);
  }

  openCommandBar({ newTab = true, seed = "" } = {}) {
    this.commandBar = { open: true, newTab, seed };
  }

  closeCommandBar() {
    this.commandBar = { ...this.commandBar, open: false };
    request("page.focus").catch(() => {});
  }

  async go(input, newTab = false) {
    await request("nav.go", { input, newTab });
  }

  create(url) {
    return request("tabs.create", url ? { url } : {});
  }
  activate(id) {
    return request("tabs.activate", { id });
  }
  close(id) {
    return request("tabs.close", { id });
  }
  setPinned(id, pinned) {
    return request("tabs.setPinned", { id, pinned });
  }
  move(id, index) {
    return request("tabs.move", { id, index });
  }
}

class AssistantState {
  open = $state(false);
  bridge = $state({ state: "starting" });
  models = $state([]);
  model = $state(readStoredModel());
  messages = $state([]); // { id, role, content, status, error, model, requestId }
  includePage = $state(true);
  health = $state(null);
  busy = $derived(this.messages.some((m) => m.status === "streaming" || m.status === "pending"));

  setModel(name) {
    this.model = name;
    try {
      localStorage.setItem(MODEL_KEY, name);
    } catch {
      /* storage unavailable */
    }
  }

  async refreshModels() {
    try {
      const { models } = await request("agent.models", { refresh: true });
      this.models = models ?? [];
      if (this.model && !this.models.some((m) => m.name === this.model)) this.setModel("");
    } catch (e) {
      this.models = [];
    }
  }

  async checkHealth() {
    try {
      this.health = await request("agent.health");
    } catch (e) {
      this.health = { error: e.message };
    }
  }

  #find(requestId) {
    return this.messages.find((m) => m.requestId === requestId);
  }

  async #start(type, payload, userText, label) {
    const requestId = newRequestId();
    if (userText) this.messages.push({ id: newRequestId(), role: "user", content: userText, label });
    this.messages.push({ id: requestId, role: "assistant", content: "", status: "pending", requestId, phase: null });
    try {
      const res = await request(type, { ...payload, requestId, model: this.model || undefined });
      const m = this.#find(requestId);
      if (m && res?.model) m.model = res.model;
    } catch (e) {
      const m = this.#find(requestId);
      if (m) {
        m.status = "error";
        m.error = e instanceof NativeError ? e.message : String(e);
        m.errorCode = e.code;
      }
    }
  }

  ask(prompt) {
    const history = this.messages
      .filter((m) => (m.role === "user" || (m.role === "assistant" && m.status === "done")) && !m.label)
      .slice(-12)
      .map((m) => ({ role: m.role, content: m.content }));
    return this.#start("agent.ask", { prompt, history, includePage: this.includePage }, prompt);
  }

  summarize() {
    const tab = browser.activeTab;
    return this.#start("agent.summarize", { source: "auto" }, tab?.isYouTubeVideo ? "Summarize this video" : "Summarize this page", "summary");
  }

  explainSelection(text) {
    return this.#start("agent.explainSelection", { text }, `Explain: “${text.slice(0, 140)}${text.length > 140 ? "…" : ""}”`, "explain");
  }

  cancel(requestId) {
    return request("agent.cancel", { requestId }).catch(() => {});
  }

  clear() {
    for (const m of this.messages) if (m.status === "streaming" || m.status === "pending") this.cancel(m.requestId);
    this.messages = [];
  }

  onStatus(p) {
    const m = this.#find(p.requestId);
    if (!m) return;
    m.phase = p.phase === "reading" ? `Reading part ${p.part} of ${p.of}…` : null;
    if (p.model) m.model = p.model;
  }

  onDelta(p) {
    const m = this.#find(p.requestId);
    if (!m) return;
    m.status = "streaming";
    m.phase = null;
    m.content += p.delta;
  }

  onDone(p) {
    const m = this.#find(p.requestId);
    if (!m) return;
    m.status = "done";
    m.content = p.content ?? m.content;
    m.model = p.model ?? m.model;
    m.stats = p.stats ?? null;
  }

  onError(p) {
    const m = this.#find(p.requestId);
    if (!m) return;
    m.status = p.code === "cancelled" ? "cancelled" : "error";
    m.error = p.message;
  }
}

export const browser = new BrowserState();
export const assistant = new AssistantState();

export async function connect() {
  on("tabs.state", (s) => browser.applyState(s));
  on("page.selection", (p) => {
    if (!p || p.tabId === browser.activeTabId) browser.selection = p?.text ?? null;
  });
  on("chrome.toast", (p) => browser.showToast(p.message));
  on("chrome.command", ({ command }) => {
    if (command === "newTab") browser.openCommandBar({ newTab: true });
    else if (command === "focusAddressBar") browser.addressFocusTick++;
    else if (command === "toggleAssistant") assistant.open = !assistant.open;
    else if (command === "summarize") {
      assistant.open = true;
      assistant.summarize();
    }
  });
  on("agent.bridgeState", (s) => {
    assistant.bridge = s;
    if (s.state === "ready") assistant.refreshModels();
  });
  on("agent.status", (p) => assistant.onStatus(p));
  on("agent.delta", (p) => assistant.onDelta(p));
  on("agent.done", (p) => assistant.onDone(p));
  on("agent.error", (p) => assistant.onError(p));

  const ready = await request("chrome.ready");
  browser.applyState(ready.state);
  browser.selection = ready.selection ?? null;
  assistant.bridge = ready.agent ?? assistant.bridge;
  if (assistant.bridge.state === "ready") assistant.refreshModels();
}
