<script>
  /** Minimal inline icon set (24px grid, stroke-based) so the chrome has no font or network dependency. */
  let { name, size = 16 } = $props();
  const paths = {
    back: "M15 18l-6-6 6-6",
    forward: "M9 6l6 6-6 6",
    reload: "M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6",
    stop: "M6 6l12 12M18 6L6 18",
    plus: "M12 5v14M5 12h14",
    close: "M7 7l10 10M17 7L7 17",
    sparkle: "M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8zM19 16l.8 2.2L22 19l-2.2.8L19 22l-.8-2.2L16 19l2.2-.8z",
    sidebar: "M4 5h16v14H4zM9 5v14",
    pin: "M9 4h6l-1 6 3 3H7l3-3zM12 13v7",
    send: "M5 12h14M13 6l6 6-6 6",
    trash: "M5 7h14M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3",
    lock: "M7 11V8a5 5 0 0 1 10 0v3M5 11h14v9H5z",
    search: "M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14zM20 20l-4-4",
    summary: "M5 6h14M5 10h14M5 14h9M5 18h6",
    tabs: "M4 6h16M4 12h16M4 18h16",
    copy: "M9 9h11v11H9zM5 15V4h11",
  };
</script>

<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"
  stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
  <path d={paths[name] ?? ""} />
</svg>
