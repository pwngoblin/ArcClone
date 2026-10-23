<script>
  let { src = null, title = "", url = null, size = 16 } = $props();
  let failed = $state(false);
  $effect(() => {
    src;
    failed = false;
  });
  const letter = $derived(((title || url || "?").replace(/^https?:\/\/(www\.)?/, "")[0] || "?").toUpperCase());
  const hue = $derived([...(url || title || "")].reduce((h, c) => (h * 31 + c.charCodeAt(0)) % 360, 0));
</script>

{#if src && !failed}
  <img {src} alt="" width={size} height={size} onerror={() => (failed = true)} />
{:else}
  <span class="fallback" style="--size:{size}px; --hue:{hue}">{letter}</span>
{/if}

<style>
  img { border-radius: 4px; flex: none; object-fit: contain; }
  .fallback {
    width: var(--size); height: var(--size); flex: none; border-radius: 4px;
    display: grid; place-items: center; font-size: calc(var(--size) * 0.62); font-weight: 600;
    color: white; background: hsl(var(--hue) 45% 52%);
  }
</style>
