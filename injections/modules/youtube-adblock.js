// Lily ad blocking for YouTube. Network rules can't separate YouTube's ads from its videos
// (same servers), so this works in the page: it hides ad slots and, when the player shows an ad,
// mutes it, fast-forwards to the end and presses Skip. Runs in the isolated injection world, so
// YouTube's own scripts can't see or tamper with it.
(() => {
  "use strict";
  const lily = window.__lily;
  if (!lily || window.__lilyYouTubeAdBlock) return;
  window.__lilyYouTubeAdBlock = true;

  let enabled = true;
  const STYLE_ID = "lily-youtube-adblock";
  const HIDE = [
    "ytd-ad-slot-renderer", "ytd-in-feed-ad-layout-renderer", "ytd-display-ad-renderer", "ytd-promoted-sparkles-web-renderer",
    "ytd-promoted-video-renderer", "ytd-banner-promo-renderer", "ytd-statement-banner-renderer", "ytd-companion-slot-renderer",
    "ytd-action-companion-ad-renderer", "ytd-player-legacy-desktop-watch-ads-renderer", "ytd-engagement-panel-section-list-renderer[target-id='engagement-panel-ads']",
    "#masthead-ad", "#player-ads", ".ytp-ad-overlay-container", ".ytp-ad-image-overlay", ".ytd-merch-shelf-renderer",
    "ytd-rich-item-renderer:has(ytd-ad-slot-renderer)", "ytd-reel-video-renderer:has(.ytd-ad-slot-renderer)",
  ];
  const SKIP_BUTTONS = ".ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, button[id^='skip-button']";
  const saved = new WeakMap(); // video -> { muted, rate }

  function setStyle(on) {
    let style = document.getElementById(STYLE_ID);
    if (!on) { style?.remove(); return; }
    if (style) return;
    style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = `${HIDE.join(",\n")} { display: none !important; }`;
    (document.head || document.documentElement).appendChild(style);
  }

  function handlePlayer() {
    if (!enabled) return;
    const player = document.querySelector(".html5-video-player");
    const video = player?.querySelector("video");
    if (!player || !video) return;
    const showingAd = player.classList.contains("ad-showing") || player.classList.contains("ad-interrupting");
    if (showingAd) {
      if (!saved.has(video)) saved.set(video, { muted: video.muted, rate: video.playbackRate });
      video.muted = true;
      try { video.playbackRate = 16; } catch { /* some ads clamp the rate */ }
      if (Number.isFinite(video.duration) && video.duration > 0 && video.currentTime < video.duration - 0.1) {
        video.currentTime = video.duration - 0.05;
      }
      document.querySelectorAll(SKIP_BUTTONS).forEach((button) => button.click());
    } else if (saved.has(video)) {
      const before = saved.get(video);
      saved.delete(video);
      video.muted = before.muted;
      video.playbackRate = before.rate;
    }
  }

  // Watch only the player's class attribute ("ad-showing" toggles there). Observing YouTube's
  // whole DOM would run this hundreds of times per second.
  const playerObserver = new MutationObserver(handlePlayer);
  let watchedPlayer = null;
  let finder = null;

  function attachToPlayer() {
    const player = document.querySelector(".html5-video-player");
    if (player === watchedPlayer) return !!player;
    playerObserver.disconnect();
    watchedPlayer = player;
    if (!player) return false;
    playerObserver.observe(player, { attributes: true, attributeFilter: ["class"] });
    handlePlayer();
    return true;
  }

  /// Until the player exists, look for it on DOM additions only; stop as soon as it's found.
  function findPlayer() {
    if (attachToPlayer() || finder) return;
    finder = new MutationObserver(() => {
      if (attachToPlayer()) { finder.disconnect(); finder = null; }
    });
    finder.observe(document.documentElement, { childList: true, subtree: true });
  }

  function start() {
    setStyle(enabled);
    findPlayer();
    // YouTube swaps players on some navigations.
    document.addEventListener("yt-navigate-finish", findPlayer);
  }

  lily.register("adblock.configure", ({ enabled: on } = {}) => {
    enabled = on !== false;
    setStyle(enabled);
    if (enabled) handlePlayer();
    return { enabled };
  });

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
  else start();
})();
