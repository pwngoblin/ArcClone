<script>
  import Icon from "./Icon.svelte";
  import { request } from "../lib/bridge.js";
  import { browser } from "../lib/state.svelte.js";
  const tab = $derived(browser.activeTab);
</script>

<div class="nav">
  <button class="icon" title="Toggle sidebar (⌘S)" onclick={() => request("window.toggleSidebar")}><Icon name="sidebar" /></button>
  <button class="icon" title="Back (⌘[)" disabled={!tab?.canGoBack} onclick={() => request("nav.back")}><Icon name="back" /></button>
  <button class="icon" title="Forward (⌘])" disabled={!tab?.canGoForward} onclick={() => request("nav.forward")}><Icon name="forward" /></button>
  {#if tab?.isLoading}
    <button class="icon" title="Stop" onclick={() => request("nav.stop")}><Icon name="stop" /></button>
  {:else}
    <button class="icon" title="Reload (⌘R)" disabled={!tab} onclick={() => request("nav.reload")}><Icon name="reload" /></button>
  {/if}
</div>

<style>
  .nav { display: flex; gap: 2px; justify-content: flex-end; }
</style>
