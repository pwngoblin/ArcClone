// In-browser stand-in for core so the chrome can be developed with `npm run dev`.
export function createMockNative(emit) {
  let seq = 0;
  const id = () => `00000000-0000-4000-8000-${String(++seq).padStart(12, "0")}`;
  let tabs = [
    { id: id(), title: "YouTube", url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", favicon: null, isLoading: false, pinned: true, canGoBack: false, canGoForward: false, isYouTubeVideo: true },
    { id: id(), title: "Svelte • Web development, streamlined", url: "https://svelte.dev/", favicon: null, isLoading: false, pinned: false, canGoBack: true, canGoForward: false, isYouTubeVideo: false },
  ];
  let activeTabId = tabs[1].id;
  const state = () => ({ tabs, activeTabId, canReopenClosed: false });
  const push = () => setTimeout(() => emit("tabs.state", state()), 0);

  async function stream(requestId, text) {
    emit("agent.status", { requestId, phase: "generating", model: "mock" });
    for (const word of text.split(/(?<= )/)) {
      await new Promise((r) => setTimeout(r, 25));
      emit("agent.delta", { requestId, delta: word });
    }
    emit("agent.done", { requestId, content: text, model: "mock", stats: { completionTokens: text.split(" ").length } });
  }

  const routes = {
    "chrome.ready": () => ({ state: state(), agent: { state: "ready" }, selection: null, platform: "mock" }),
    "tabs.create": (p) => {
      const t = { id: id(), title: p?.url || "New Tab", url: p?.url ?? null, favicon: null, isLoading: false, pinned: false, canGoBack: false, canGoForward: false };
      tabs = [...tabs, t];
      activeTabId = t.id;
      push();
      return { id: t.id };
    },
    "tabs.close": (p) => {
      tabs = tabs.filter((t) => t.id !== p.id);
      if (activeTabId === p.id) activeTabId = tabs.at(-1)?.id ?? null;
      push();
    },
    "tabs.activate": (p) => {
      activeTabId = p.id;
      push();
    },
    "tabs.setPinned": (p) => {
      tabs = tabs.map((t) => (t.id === p.id ? { ...t, pinned: p.pinned } : t)).sort((a, b) => Number(b.pinned) - Number(a.pinned));
      push();
    },
    "tabs.move": (p) => {
      const i = tabs.findIndex((t) => t.id === p.id);
      const [t] = tabs.splice(i, 1);
      tabs.splice(p.index, 0, t);
      tabs = [...tabs];
      push();
    },
    "nav.go": (p) => {
      const url = /^https?:/.test(p.input) ? p.input : `https://www.google.com/search?q=${encodeURIComponent(p.input)}`;
      if (p.newTab || !activeTabId) return routes["tabs.create"]({ url });
      tabs = tabs.map((t) => (t.id === activeTabId ? { ...t, url, title: url } : t));
      push();
    },
    "nav.suggest": (p) => tabs.filter((t) => t.title.toLowerCase().includes((p.query || "").toLowerCase())).map((t) => ({ kind: "tab", ...t })),
    "agent.models": () => ({ models: [{ name: "llama3.2:latest" }, { name: "qwen3:8b" }] }),
    "agent.health": () => ({ ollama: { reachable: true, version: "mock", modelCount: 2 } }),
    "agent.ask": (p) => {
      stream(p.requestId, `You asked: **${p.prompt}**. This is a mock reply from the dev bridge with a timestamp [1:23].`);
      return { requestId: p.requestId, model: "mock" };
    },
    "agent.summarize": (p) => {
      stream(p.requestId, "**TL;DR:** a mock summary.\n\n- First point\n- Second point at [0:42]\n- `code` sample");
      return { requestId: p.requestId, model: "mock" };
    },
    "agent.explainSelection": (p) => {
      stream(p.requestId, "Mock explanation of the selection.");
      return { requestId: p.requestId, model: "mock" };
    },
    "agent.cancel": () => ({ cancelled: true }),
  };

  return {
    async handle(envelope) {
      const fn = routes[envelope.type];
      if (!fn) return { ok: true, result: null };
      try {
        return { ok: true, result: (await fn(envelope.payload)) ?? null };
      } catch (e) {
        return { ok: false, error: { code: "mock", message: String(e) } };
      }
    },
  };
}
