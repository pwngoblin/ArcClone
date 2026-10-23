<script>
  import { renderMarkdown } from "../lib/markdown.js";
  import { request } from "../lib/bridge.js";
  import { assistant, browser } from "../lib/state.svelte.js";

  let { message } = $props();
  const html = $derived(message.role === "assistant" ? renderMarkdown(message.content) : "");

  function click(e) {
    const seek = e.target.closest("[data-seek]");
    if (seek) {
      e.preventDefault();
      request("youtube.seek", { seconds: Number(seek.dataset.seek) }).catch((err) => browser.showToast(err.message));
    }
  }

  async function copy() {
    try {
      await navigator.clipboard.writeText(message.content);
      browser.showToast("Copied");
    } catch {
      browser.showToast("Copy failed");
    }
  }
</script>

{#if message.role === "user"}
  <div class="user">{message.content}</div>
{:else}
  <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
  <div class="assistant" onclick={click}>
    {#if message.status === "pending" || (message.status === "streaming" && !message.content)}
      <div class="thinking"><span></span><span></span><span></span>{#if message.phase}<em>{message.phase}</em>{/if}</div>
    {/if}
    {#if message.content}
      <div class="md">{@html html}</div>
    {/if}
    {#if message.status === "error"}
      <div class="error">
        {message.error}
        {#if message.errorCode === "no_model"}<div class="hint">Then reopen the model menu.</div>{/if}
      </div>
    {:else if message.status === "cancelled"}
      <div class="meta">Stopped</div>
    {/if}
    <div class="footer">
      {#if message.status === "streaming" || message.status === "pending"}
        <button class="link" onclick={() => assistant.cancel(message.requestId)}>Stop</button>
      {:else if message.status === "done"}
        <button class="link" onclick={copy}>Copy</button>
        {#if message.model}<span class="meta">{message.model}{#if message.stats?.completionTokens} · {message.stats.completionTokens} tokens{/if}</span>{/if}
      {/if}
    </div>
  </div>
{/if}

<style>
  .user {
    align-self: flex-end; max-width: 88%; padding: 7px 10px; border-radius: 12px 12px 4px 12px;
    background: var(--accent); color: var(--on-accent); white-space: pre-wrap; word-wrap: break-word; font-size: 13px;
  }
  .assistant { font-size: 13px; line-height: 1.5; word-wrap: break-word; }
  .md :global(p) { margin: 0 0 8px; }
  .md :global(ul), .md :global(ol) { margin: 0 0 8px; padding-left: 18px; }
  .md :global(li) { margin: 2px 0; }
  .md :global(h3), .md :global(h4), .md :global(h5) { font-size: 13px; margin: 10px 0 4px; }
  .md :global(code) { font: 12px ui-monospace, SFMono-Regular, monospace; background: var(--field); padding: 1px 4px; border-radius: 4px; }
  .md :global(pre) { background: var(--field); padding: 8px; border-radius: 8px; overflow-x: auto; }
  .md :global(pre code) { background: none; padding: 0; }
  .md :global(blockquote) { margin: 0 0 8px; padding-left: 8px; border-left: 2px solid var(--border); color: var(--muted); }
  .md :global(a) { color: var(--accent); }
  .md :global(.ts) {
    font: 600 11px ui-monospace, monospace; color: var(--accent); background: var(--accent-soft);
    border-radius: 4px; padding: 0 4px; height: auto; cursor: pointer;
  }
  .thinking { display: flex; gap: 4px; align-items: center; height: 18px; }
  .thinking span { width: 5px; height: 5px; border-radius: 50%; background: var(--muted); animation: pulse 1s infinite ease-in-out; }
  .thinking span:nth-child(2) { animation-delay: 0.15s; }
  .thinking span:nth-child(3) { animation-delay: 0.3s; }
  .thinking em { margin-left: 6px; font-size: 11px; color: var(--muted); font-style: normal; }
  @keyframes pulse { 0%, 100% { opacity: 0.25; } 50% { opacity: 1; } }
  .error { color: var(--danger); font-size: 12px; background: var(--danger-soft); padding: 6px 8px; border-radius: 8px; white-space: pre-wrap; }
  .hint { color: var(--muted); margin-top: 4px; }
  .footer { display: flex; gap: 8px; align-items: center; margin-top: 2px; min-height: 16px; }
  .meta { font-size: 11px; color: var(--muted); }
</style>
