<script>
  import Favicon from "./Favicon.svelte";
  import Icon from "./Icon.svelte";
  import { browser } from "../lib/state.svelte.js";
  import { request } from "../lib/bridge.js";

  let query = $state(browser.commandBar.seed ?? "");
  let input = $state(null);
  let selected = $state(0);
  let suggestions = $state([]);

  $effect(() => {
    requestAnimationFrame(() => input?.focus());
  });

  $effect(() => {
    const q = query.trim();
    if (!q) {
      suggestions = [];
      return;
    }
    let cancelled = false;
    request("nav.suggest", { query: q }).then((s) => {
      if (!cancelled) suggestions = s ?? [];
    }).catch(() => {});
    return () => (cancelled = true);
  });

  const items = $derived([
    ...(query.trim() ? [{ kind: "go", title: query.trim() }] : []),
    ...suggestions,
  ]);

  $effect(() => {
    items.length;
    selected = 0;
  });

  async function choose(item) {
    browser.closeCommandBar();
    try {
      if (item.kind === "tab") await browser.activate(item.id);
      else await browser.go(item.title, browser.commandBar.newTab);
    } catch (e) {
      browser.showToast(e.message);
    }
  }

  function keydown(e) {
    if (e.key === "Escape") {
      e.preventDefault();
      browser.closeCommandBar();
    } else if (e.key === "ArrowDown") {
      e.preventDefault();
      selected = Math.min(selected + 1, items.length - 1);
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      selected = Math.max(selected - 1, 0);
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (items[selected]) choose(items[selected]);
    }
  }
</script>

<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
<div class="scrim" onclick={() => browser.closeCommandBar()}>
  <div class="bar" onclick={(e) => e.stopPropagation()}>
    <div class="field">
      <Icon name="search" size={14} />
      <input bind:this={input} bind:value={query} onkeydown={keydown} placeholder="Search or enter URL…" spellcheck="false" autocomplete="off" />
    </div>
    {#if items.length}
      <ul>
        {#each items as item, i (item.kind + (item.id ?? item.title))}
          <li class:selected={i === selected}>
            <button onclick={() => choose(item)} onmouseenter={() => (selected = i)}>
              {#if item.kind === "tab"}
                <Favicon src={item.favicon} title={item.title} url={item.url} size={14} />
                <span class="t">{item.title}</span><span class="k">Switch to tab</span>
              {:else}
                <Icon name="forward" size={14} />
                <span class="t">{item.title}</span><span class="k">{browser.commandBar.newTab ? "Open" : "Go"}</span>
              {/if}
            </button>
          </li>
        {/each}
      </ul>
    {/if}
  </div>
</div>

<style>
  .scrim { position: fixed; inset: 0; background: var(--scrim); z-index: 10; padding: 46px 8px 0; }
  .bar { background: var(--panel); border-radius: 12px; box-shadow: var(--shadow-lg); overflow: hidden; border: 1px solid var(--border); }
  .field { display: flex; align-items: center; gap: 8px; padding: 0 12px; height: 42px; color: var(--muted); }
  input { flex: 1; min-width: 0; border: 0; background: transparent; color: var(--text); font: inherit; font-size: 14px; outline: none; }
  ul { list-style: none; margin: 0; padding: 4px; border-top: 1px solid var(--border); }
  li button { display: flex; align-items: center; gap: 8px; width: 100%; height: 32px; padding: 0 8px; border-radius: 7px; text-align: left; color: var(--text); }
  li.selected button { background: var(--accent); color: var(--on-accent); }
  .t { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 13px; }
  .k { font-size: 11px; opacity: 0.7; }
</style>
