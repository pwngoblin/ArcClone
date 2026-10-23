<script>
  import TabItem from "./TabItem.svelte";
  import Icon from "./Icon.svelte";
  import { browser } from "../lib/state.svelte.js";

  let dragging = null;

  function start(tab) {
    dragging = tab;
  }

  function drop(target, index) {
    if (!dragging || dragging.id === target.id) return;
    if (dragging.pinned !== target.pinned) {
      browser.setPinned(dragging.id, target.pinned);
    } else {
      browser.move(dragging.id, index);
    }
    dragging = null;
  }

  function dropOnPinnedZone(e) {
    e.preventDefault();
    if (dragging && !dragging.pinned) browser.setPinned(dragging.id, true);
    dragging = null;
  }
</script>

<div class="list">
  <section class="pinned" role="list" ondragover={(e) => e.preventDefault()} ondrop={dropOnPinnedZone}>
    {#each browser.pinned as tab, i (tab.id)}
      <TabItem {tab} index={i} compact ondragstartTab={start} ondropTab={drop} />
    {:else}
      <div class="pin-hint">Drag tabs here or double-click to pin</div>
    {/each}
  </section>

  <div class="divider">
    <span>Today</span>
    {#if browser.unpinned.length > 1}
      <button class="link" onclick={() => browser.unpinned.forEach((t) => browser.close(t.id))}>Clear</button>
    {/if}
  </div>

  <button class="new-tab" onclick={() => browser.openCommandBar({ newTab: true })}>
    <Icon name="plus" size={14} /> <span>New Tab</span><kbd>⌘T</kbd>
  </button>

  <section role="tablist" aria-orientation="vertical">
    {#each browser.unpinned as tab, i (tab.id)}
      <TabItem {tab} index={browser.pinned.length + i} ondragstartTab={start} ondropTab={drop} />
    {/each}
  </section>
</div>

<style>
  .list { display: flex; flex-direction: column; gap: 2px; }
  .pinned {
    display: grid; grid-template-columns: repeat(auto-fill, minmax(52px, 1fr)); gap: 6px;
    padding-bottom: 6px; min-height: 40px;
  }
  .pinned :global(.tab) { background: var(--field); }
  .pinned :global(.tab.active) { background: var(--selected); }
  .pin-hint {
    grid-column: 1 / -1; font-size: 11px; color: var(--muted); text-align: center; padding: 12px 0;
    border: 1px dashed var(--border); border-radius: 9px;
  }
  .divider {
    display: flex; justify-content: space-between; align-items: center;
    font-size: 11px; color: var(--muted); padding: 8px 6px 4px; border-top: 1px solid var(--border); margin-top: 2px;
  }
  .new-tab {
    display: flex; align-items: center; gap: 9px; height: 32px; padding: 0 10px; border-radius: 9px;
    color: var(--muted); font-size: 13px; text-align: left;
  }
  .new-tab:hover { background: var(--hover); color: var(--text); }
  .new-tab span { flex: 1; }
  kbd { font: inherit; font-size: 11px; opacity: 0.6; }
</style>
