<script>
  import { onMount } from "svelte";
  import NavControls from "./components/NavControls.svelte";
  import AddressBar from "./components/AddressBar.svelte";
  import TabList from "./components/TabList.svelte";
  import AssistantPanel from "./components/AssistantPanel.svelte";
  import CommandBar from "./components/CommandBar.svelte";
  import Icon from "./components/Icon.svelte";
  import { browser, assistant, connect } from "./lib/state.svelte.js";
  import { isNative, request } from "./lib/bridge.js";

  let error = $state(null);

  onMount(() => {
    connect().catch((e) => (error = e.message));
  });

  function keydown(e) {
    // Shortcuts while the sidebar has focus (native menus handle them when the page has focus).
    if (!e.metaKey) return;
    if (e.key === "t") { e.preventDefault(); browser.openCommandBar({ newTab: true }); }
    else if (e.key === "l") { e.preventDefault(); browser.addressFocusTick++; }
    else if (e.key === "e") { e.preventDefault(); assistant.open = !assistant.open; }
  }

  const bridgeDot = $derived({ ready: "ok", starting: "warn", restarting: "warn" }[assistant.bridge?.state] ?? "bad");
</script>

<svelte:window onkeydown={keydown} />

<div class="sidebar" class:dev={!isNative}>
  <div class="titlebar">
    <NavControls />
  </div>

  <AddressBar />

  <main>
    {#if error}
      <div class="fatal">Could not connect to ArcClone core: {error}</div>
    {:else if assistant.open}
      <AssistantPanel />
    {:else}
      <div class="scroll"><TabList /></div>
    {/if}
  </main>

  <footer>
    <button class="foot" class:on={assistant.open} onclick={() => (assistant.open = !assistant.open)} title="Assistant (⌘E)">
      <Icon name="sparkle" size={14} />
      <span>Assistant</span>
      <i class="dot {bridgeDot}" title={`Agent: ${assistant.bridge?.state}`}></i>
    </button>
    {#if browser.canReopenClosed}
      <button class="icon" title="Reopen closed tab (⇧⌘T)" onclick={() => request("tabs.reopenClosed")}><Icon name="reload" size={14} /></button>
    {/if}
    <button class="icon" title="New tab (⌘T)" onclick={() => browser.openCommandBar({ newTab: true })}><Icon name="plus" size={15} /></button>
  </footer>

  {#if browser.commandBar.open}
    <CommandBar />
  {/if}

  {#if browser.toast}
    <div class="toast" role="status">{browser.toast.message}</div>
  {/if}
</div>

<style>
  .sidebar { height: 100vh; display: flex; flex-direction: column; gap: 8px; padding: 0 10px 10px; box-sizing: border-box; }
  .sidebar.dev { width: 300px; background: var(--dev-bg); }
  .titlebar { height: 38px; flex: none; display: flex; align-items: center; justify-content: flex-end; padding-left: 72px; }
  main { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .scroll { overflow-y: auto; flex: 1; min-height: 0; margin: 0 -4px; padding: 0 4px; }
  footer { display: flex; align-items: center; gap: 2px; flex: none; }
  .foot { flex: 1; display: flex; align-items: center; gap: 7px; height: 30px; padding: 0 8px; border-radius: 8px; color: var(--muted); font-size: 12px; }
  .foot:hover, .foot.on { background: var(--hover); color: var(--text); }
  .foot span { flex: 1; text-align: left; }
  .dot { width: 6px; height: 6px; border-radius: 50%; }
  .dot.ok { background: var(--ok); }
  .dot.warn { background: var(--warn); }
  .dot.bad { background: var(--danger); }
  .fatal { color: var(--danger); font-size: 12px; padding: 8px; }
  .toast {
    position: fixed; left: 50%; bottom: 52px; transform: translateX(-50%); background: var(--panel); color: var(--text);
    border: 1px solid var(--border); box-shadow: var(--shadow-lg); padding: 6px 12px; border-radius: 8px; font-size: 12px;
    white-space: nowrap; max-width: 90%; overflow: hidden; text-overflow: ellipsis; z-index: 20;
  }
</style>
