// ArcClone ad blocking for YouTube. Network rules can't separate YouTube's ads from its videos
// (same servers), so this works in the page: it hides ad slots and, when the player shows an ad,
// mutes it, fast-forwards to the end and presses Skip. Runs in the isolated injection world, so
// YouTube's own scripts can't see or tamper with it.
(() => {
  "use strict";
  const arc = window.__arc;
  if (!arc || window.__arcYouTubeAdBlock) return;
  window.__arcYouTubeAdBlock = true;

  let enabled = true;
  const STYLE_ID = "arcclone-youtube-adblock";
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

  const observer = new MutationObserver(handlePlayer);
  function start() {
    setStyle(enabled);
    observer.observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ["class"] });
    handlePlayer();
  }

  arc.register("adblock.configure", ({ enabled: on } = {}) => {
    enabled = on !== false;
    setStyle(enabled);
    if (enabled) handlePlayer();
    return { enabled };
  });

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start, { once: true });
  else start();
})();
