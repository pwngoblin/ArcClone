<script>
  import Favicon from "./Favicon.svelte";
  import Icon from "./Icon.svelte";
  import { browser } from "../lib/state.svelte.js";

  let { tab, index, compact = false, ondragstartTab, ondropTab } = $props();
  const active = $derived(tab.id === browser.activeTabId);
  let over = $state(false);

  function auxclick(e) {
    if (e.button === 1) browser.close(tab.id);
  }
</script>

<div
  class="tab"
  class:active
  class:compact
  class:over
  role="tab"
  tabindex="0"
  aria-selected={active}
  title={tab.title + (tab.url ? `\n${tab.url}` : "")}
  draggable="true"
  onclick={() => browser.activate(tab.id)}
  onauxclick={auxclick}
  onkeydown={(e) => e.key === "Enter" && browser.activate(tab.id)}
  ondragstart={(e) => { e.dataTransfer.effectAllowed = "move"; ondragstartTab?.(tab, index); }}
  ondragover={(e) => { e.preventDefault(); over = true; }}
  ondragleave={() => (over = false)}
  ondrop={(e) => { e.preventDefault(); over = false; ondropTab?.(tab, index); }}
  ondblclick={() => browser.setPinned(tab.id, !tab.pinned)}
>
  <span class="icon-wrap" class:loading={tab.isLoading}><Favicon src={tab.favicon} title={tab.title} url={tab.url} size={compact ? 18 : 16} /></span>
  {#if !compact}
    <span class="title">{tab.title}</span>
    <button class="icon close" title="Close tab (⌘W)" onclick={(e) => { e.stopPropagation(); browser.close(tab.id); }}>
      <Icon name="close" size={13} />
    </button>
  {/if}
</div>

<style>
  .tab {
    display: flex; align-items: center; gap: 9px; height: 34px; padding: 0 6px 0 10px; border-radius: 9px;
    color: var(--text); cursor: default; user-select: none; outline: none;
  }
  .tab:hover { background: var(--hover); }
  .tab.active { background: var(--selected); box-shadow: var(--selected-shadow); }
  .tab.over { box-shadow: inset 0 2px 0 var(--accent); }
  .tab:focus-visible { box-shadow: 0 0 0 2px var(--accent-soft); }
  .compact { justify-content: center; padding: 0; height: 40px; }
  .title { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 13px; }
  .close { opacity: 0; width: 22px; height: 22px; }
  .tab:hover .close, .tab.active .close { opacity: 0.7; }
  .icon-wrap { display: grid; position: relative; }
  .icon-wrap.loading::after {
    content: ""; position: absolute; inset: -3px; border-radius: 50%;
    border: 1.5px solid var(--accent); border-right-color: transparent; animation: spin 0.8s linear infinite;
  }
  @keyframes spin { to { transform: rotate(360deg); } }
</style>
