<script>
  import Icon from "./Icon.svelte";
  import MessageView from "./MessageView.svelte";
  import { assistant, browser } from "../lib/state.svelte.js";
  import { request } from "../lib/bridge.js";

  let prompt = $state("");
  let scroller = $state(null);
  let textarea = $state(null);

  const tab = $derived(browser.activeTab);
  const bridgeState = $derived(assistant.bridge?.state ?? "starting");
  const ready = $derived(bridgeState === "ready");

  $effect(() => {
    // Keep pinned to the bottom while streaming.
    assistant.messages.length;
    assistant.messages.at(-1)?.content;
    if (scroller) requestAnimationFrame(() => (scroller.scrollTop = scroller.scrollHeight));
  });

  $effect(() => {
    if (assistant.open) requestAnimationFrame(() => textarea?.focus());
  });

  function send(e) {
    e?.preventDefault();
    const text = prompt.trim();
    if (!text || !ready) return;
    prompt = "";
    assistant.ask(text);
  }

  function keydown(e) {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) send(e);
  }

  function statusText() {
    switch (bridgeState) {
      case "ready": return null;
      case "starting": return "Starting local agent…";
      case "restarting": return "Agent bridge restarting…";
      default: return assistant.bridge?.message ?? "Agent unavailable";
    }
  }
</script>

<div class="panel">
  <header>
    <div class="title"><Icon name="sparkle" size={14} /> Assistant</div>
    <select
      value={assistant.model}
      onchange={(e) => assistant.setModel(e.currentTarget.value)}
      onfocus={() => assistant.refreshModels()}
      title="Ollama model"
      disabled={!ready}
    >
      <option value="">Auto model</option>
      {#each assistant.models as m (m.name)}
        <option value={m.name}>{m.name}</option>
      {/each}
    </select>
    <button class="icon" title="Clear conversation" onclick={() => assistant.clear()} disabled={!assistant.messages.length}><Icon name="trash" size={14} /></button>
    <button class="icon" title="Back to tabs (⌘E)" onclick={() => (assistant.open = false)}><Icon name="tabs" size={14} /></button>
  </header>

  {#if statusText()}
    <div class="banner">
      {statusText()}
      {#if bridgeState === "failed" || bridgeState === "unavailable"}
        <button class="link" onclick={() => request("agent.restart")}>Restart</button>
      {/if}
    </div>
  {:else if ready && assistant.models.length === 0}
    <div class="banner">
      No Ollama models found. In Terminal run <code>ollama pull llama3.2</code>, then
      <button class="link" onclick={() => assistant.refreshModels()}>refresh</button>.
    </div>
  {/if}

  <div class="messages" bind:this={scroller}>
    {#if !assistant.messages.length}
      <div class="empty">
        <p>Ask about {tab?.isYouTubeVideo ? "this video" : "this page"}, or anything else. Everything runs locally through Ollama.</p>
        <div class="actions">
          <button class="chip" disabled={!tab || !ready} onclick={() => assistant.summarize()}>
            <Icon name="summary" size={13} /> {tab?.isYouTubeVideo ? "Summarize video" : "Summarize page"}
          </button>
          {#if browser.selection}
            <button class="chip" disabled={!ready} onclick={() => assistant.explainSelection(browser.selection)}>
              <Icon name="sparkle" size={13} /> Explain selection
            </button>
          {/if}
        </div>
      </div>
    {/if}
    {#each assistant.messages as message (message.id)}
      <MessageView {message} />
    {/each}
  </div>

  <form class="composer" onsubmit={send}>
    {#if assistant.messages.length}
      <div class="actions inline">
        <button type="button" class="chip" disabled={!tab || !ready || assistant.busy} onclick={() => assistant.summarize()}>
          {tab?.isYouTubeVideo ? "Summarize video" : "Summarize"}
        </button>
        {#if browser.selection}
          <button type="button" class="chip" disabled={!ready || assistant.busy} onclick={() => assistant.explainSelection(browser.selection)}>Explain selection</button>
        {/if}
      </div>
    {/if}
    <div class="box">
      <textarea
        bind:this={textarea}
        bind:value={prompt}
        onkeydown={keydown}
        rows="2"
        placeholder={ready ? "Ask anything…" : "Waiting for agent…"}
        disabled={!ready}
      ></textarea>
      <button class="icon send" type="submit" disabled={!prompt.trim() || !ready} title="Send (↩)"><Icon name="send" size={15} /></button>
    </div>
    <label class="context">
      <input type="checkbox" bind:checked={assistant.includePage} />
      Use {tab?.isYouTubeVideo ? "video transcript and page" : "current page"} as context
    </label>
  </form>
</div>

<style>
  .panel { display: flex; flex-direction: column; min-height: 0; flex: 1; }
  header { display: flex; align-items: center; gap: 4px; padding: 2px 0 8px; }
  .title { display: flex; align-items: center; gap: 6px; font-weight: 600; font-size: 13px; flex: 1; }
  select {
    max-width: 120px; font: inherit; font-size: 11px; color: var(--text); background: var(--field);
    border: 0; border-radius: 6px; padding: 3px 4px;
  }
  .banner { font-size: 12px; color: var(--muted); background: var(--field); border-radius: 8px; padding: 8px; margin-bottom: 8px; }
  .banner code { font-size: 11px; }
  .messages { flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; gap: 12px; padding: 4px 2px 12px; }
  .empty { color: var(--muted); font-size: 13px; line-height: 1.5; }
  .empty p { margin: 4px 0 12px; }
  .actions { display: flex; flex-wrap: wrap; gap: 6px; }
  .actions.inline { margin-bottom: 6px; }
  .chip {
    display: inline-flex; align-items: center; gap: 5px; font-size: 12px; height: 26px; padding: 0 10px;
    border-radius: 13px; background: var(--field); color: var(--text);
  }
  .chip:hover:not(:disabled) { background: var(--hover); }
  .composer { border-top: 1px solid var(--border); padding-top: 8px; }
  .box { display: flex; align-items: flex-end; gap: 4px; background: var(--field); border-radius: 10px; padding: 6px 6px 6px 10px; }
  .box:focus-within { background: var(--field-focus); box-shadow: 0 0 0 2px var(--accent-soft); }
  textarea {
    flex: 1; resize: none; border: 0; background: transparent; color: var(--text); font: inherit; font-size: 13px;
    outline: none; max-height: 140px; field-sizing: content; min-height: 36px;
  }
  .send { color: var(--accent); }
  .context { display: flex; align-items: center; gap: 6px; font-size: 11px; color: var(--muted); margin-top: 6px; }
</style>
