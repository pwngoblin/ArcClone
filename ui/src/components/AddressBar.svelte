<script>
  import Icon from "./Icon.svelte";
  import { browser } from "../lib/state.svelte.js";

  let input = $state(null);
  let focused = $state(false);
  let value = $state("");

  const tab = $derived(browser.activeTab);
  const display = $derived.by(() => {
    if (!tab?.url) return "";
    try {
      const u = new URL(tab.url);
      return u.protocol.startsWith("http") ? u.host.replace(/^www\./, "") + (u.pathname !== "/" ? u.pathname : "") : tab.url;
    } catch {
      return tab.url;
    }
  });
  const secure = $derived(tab?.url?.startsWith("https://"));

  $effect(() => {
    if (!focused) value = tab?.url ?? "";
  });

  $effect(() => {
    if (browser.addressFocusTick > 0) {
      input?.focus();
      input?.select();
    }
  });

  async function submit(e) {
    e.preventDefault();
    const text = value.trim();
    if (!text) return;
    input.blur();
    try {
      await browser.go(text, !tab);
    } catch (err) {
      browser.showToast(err.message);
    }
  }

  function keydown(e) {
    if (e.key === "Escape") {
      value = tab?.url ?? "";
      input.blur();
    }
  }
</script>

<form class="address" class:focused onsubmit={submit}>
  <span class="lead"><Icon name={secure ? "lock" : "search"} size={13} /></span>
  <input
    bind:this={input}
    bind:value={() => (focused ? value : display), (v) => (value = v)}
    onfocus={() => { focused = true; value = tab?.url ?? ""; requestAnimationFrame(() => input.select()); }}
    onblur={() => (focused = false)}
    onkeydown={keydown}
    placeholder="Search or enter URL"
    spellcheck="false"
    autocomplete="off"
    aria-label="Address"
  />
  {#if tab?.isLoading}
    <span class="progress" style="--p:{Math.max(0.08, tab.progress ?? 0)}"></span>
  {/if}
</form>

<style>
  .address {
    position: relative; display: flex; align-items: center; gap: 6px; height: 32px; padding: 0 10px;
    border-radius: 9px; background: var(--field); transition: background 0.15s, box-shadow 0.15s; overflow: hidden;
  }
  .address.focused { background: var(--field-focus); box-shadow: 0 0 0 2px var(--accent-soft); }
  .lead { color: var(--muted); display: grid; }
  input { flex: 1; min-width: 0; border: 0; background: transparent; color: var(--text); font: inherit; outline: none; }
  input::placeholder { color: var(--muted); }
  .progress {
    position: absolute; left: 0; bottom: 0; height: 2px; width: calc(var(--p) * 100%);
    background: var(--accent); transition: width 0.2s ease-out;
  }
</style>
