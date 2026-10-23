// In-memory record of local browser events (navigations, selections, videos) per tab.
// Core forwards injection events here via `events.ingest`; tasks read them for context.

const MAX_EVENTS_PER_TAB = 50;
const MAX_HISTORY = 100;

export class ContextStore {
  constructor() {
    this.tabs = new Map(); // tabId -> { events: [], page, selection, video }
    this.history = []; // global navigation history, newest last
  }

  #tab(tabId) {
    const key = String(tabId ?? "global");
    let t = this.tabs.get(key);
    if (!t) {
      t = { events: [], page: null, selection: null, video: null };
      this.tabs.set(key, t);
    }
    return t;
  }

  ingest({ tabId, type, payload, at }) {
    if (typeof type !== "string") return { accepted: false };
    const t = this.#tab(tabId);
    const event = { type, at: at || new Date().toISOString(), payload: payload ?? null };
    t.events.push(event);
    if (t.events.length > MAX_EVENTS_PER_TAB) t.events.splice(0, t.events.length - MAX_EVENTS_PER_TAB);

    switch (type) {
      case "page.didChange":
        if (payload?.url) {
          t.page = { url: payload.url, title: payload.title || "", description: payload.description || null };
          t.selection = null;
          const last = this.history[this.history.length - 1];
          if (!last || last.url !== payload.url) {
            this.history.push({ url: payload.url, title: payload.title || "", at: event.at, tabId: String(tabId) });
            if (this.history.length > MAX_HISTORY) this.history.shift();
          } else if (payload.title) {
            last.title = payload.title;
          }
        }
        break;
      case "selection.changed":
        t.selection = payload?.text ? { text: String(payload.text), url: payload.url } : null;
        break;
      case "selection.cleared":
        t.selection = null;
        break;
      case "youtube.videoChanged":
        t.video = payload?.videoId ? { videoId: payload.videoId, url: payload.url } : null;
        break;
      case "tab.closed":
        this.tabs.delete(String(tabId));
        break;
      default:
        break;
    }
    return { accepted: true };
  }

  snapshot(tabId) {
    const t = this.tabs.get(String(tabId ?? "global"));
    return {
      page: t?.page ?? null,
      selection: t?.selection ?? null,
      video: t?.video ?? null,
      recentEvents: t ? t.events.slice(-10) : [],
      recentHistory: this.history.slice(-15),
    };
  }

  stats() {
    return { tabs: this.tabs.size, history: this.history.length };
  }
}
