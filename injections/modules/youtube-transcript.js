// YouTube transcript extraction.
// Strategy, in order:
//   1. Read caption tracks from the watch page's player response, fetch the track as json3.
//   2. Same track as legacy XML (srv1) if json3 is empty.
//   3. Open YouTube's own transcript panel and scrape the rendered segments.
// Runs in the isolated content world; same-origin fetches carry the user's YouTube cookies.
(() => {
  "use strict";
  const arc = window.__arc;
  if (!arc || window.__arcYouTubeTranscript) return;
  window.__arcYouTubeTranscript = true;

  const cache = new Map(); // key `${videoId}:${lang}` -> transcript

  function videoIdFrom(href) {
    try {
      const url = new URL(href);
      if (url.pathname === "/watch") return url.searchParams.get("v");
      const m = /^\/(?:shorts|live|embed)\/([A-Za-z0-9_-]{6,})/.exec(url.pathname);
      return m ? m[1] : null;
    } catch {
      return null;
    }
  }

  // Extract a JSON object literal assigned after `marker` using brace matching (strings aware).
  function extractJSONAfter(source, marker) {
    const at = source.indexOf(marker);
    if (at < 0) return null;
    const start = source.indexOf("{", at + marker.length);
    if (start < 0) return null;
    let depth = 0;
    let inString = false;
    let quote = "";
    for (let i = start; i < source.length; i++) {
      const c = source[i];
      if (inString) {
        if (c === "\\") i++;
        else if (c === quote) inString = false;
        continue;
      }
      if (c === '"' || c === "'") {
        inString = true;
        quote = c;
      } else if (c === "{") depth++;
      else if (c === "}") {
        depth--;
        if (depth === 0) {
          try {
            return JSON.parse(source.slice(start, i + 1));
          } catch {
            return null;
          }
        }
      }
    }
    return null;
  }

  async function playerResponse(videoId) {
    // Fresh fetch: on SPA navigations the inline <script> data belongs to the first video.
    const res = await fetch(`/watch?v=${encodeURIComponent(videoId)}&hl=en`, { credentials: "include" });
    if (!res.ok) throw Object.assign(new Error(`Watch page request failed (${res.status})`), { code: "youtube_http" });
    const html = await res.text();
    const pr = extractJSONAfter(html, "ytInitialPlayerResponse =") || extractJSONAfter(html, '"playerResponse":');
    if (!pr) throw Object.assign(new Error("Could not locate player response"), { code: "youtube_parse" });
    return pr;
  }

  function pickTrack(tracks, preferredLang) {
    if (!tracks.length) return null;
    const langs = [preferredLang, (navigator.language || "en").split("-")[0], "en"].filter(Boolean);
    const manual = tracks.filter((t) => t.kind !== "asr");
    for (const lang of langs) {
      const hit = manual.find((t) => t.languageCode === lang) || tracks.find((t) => t.languageCode === lang);
      if (hit) return hit;
    }
    return manual[0] || tracks[0];
  }

  /// Caption text arrives HTML-escaped. DOMParser builds an inert document (no scripts, no
  /// loads), so decoding never assigns untrusted markup to a live element's innerHTML.
  function decodeEntities(s) {
    return new DOMParser().parseFromString(String(s), "text/html").documentElement.textContent || "";
  }

  async function fetchJson3(baseUrl) {
    const url = new URL(baseUrl, location.origin);
    url.searchParams.set("fmt", "json3");
    const res = await fetch(url.href, { credentials: "include" });
    if (!res.ok) return [];
    const body = await res.text();
    if (!body.trim()) return [];
    const data = JSON.parse(body);
    const segments = [];
    for (const ev of data.events || []) {
      if (!ev.segs) continue;
      const text = ev.segs.map((s) => s.utf8 || "").join("").replace(/\s+/g, " ").trim();
      if (!text) continue;
      segments.push({ start: (ev.tStartMs || 0) / 1000, duration: (ev.dDurationMs || 0) / 1000, text });
    }
    return segments;
  }

  async function fetchXml(baseUrl) {
    const res = await fetch(new URL(baseUrl, location.origin).href, { credentials: "include" });
    if (!res.ok) return [];
    const xml = await res.text();
    if (!xml.trim()) return [];
    const doc = new DOMParser().parseFromString(xml, "text/xml");
    return Array.from(doc.getElementsByTagName("text"))
      .map((n) => ({
        start: parseFloat(n.getAttribute("start") || "0"),
        duration: parseFloat(n.getAttribute("dur") || "0"),
        text: decodeEntities(n.textContent || "").replace(/\s+/g, " ").trim(),
      }))
      .filter((s) => s.text);
  }

  function parseTimestamp(ts) {
    const parts = ts.trim().split(":").map((p) => parseInt(p, 10));
    if (parts.some(Number.isNaN)) return 0;
    return parts.reduce((acc, p) => acc * 60 + p, 0);
  }

  function waitFor(selector, timeoutMs) {
    return new Promise((resolve) => {
      const found = document.querySelectorAll(selector);
      if (found.length) return resolve(found);
      const obs = new MutationObserver(() => {
        const nodes = document.querySelectorAll(selector);
        if (nodes.length) {
          obs.disconnect();
          resolve(nodes);
        }
      });
      obs.observe(document.documentElement, { childList: true, subtree: true });
      setTimeout(() => {
        obs.disconnect();
        resolve(document.querySelectorAll(selector));
      }, timeoutMs);
    });
  }

  async function scrapeTranscriptPanel() {
    const SEGMENT = "ytd-transcript-segment-renderer";
    let nodes = document.querySelectorAll(SEGMENT);
    if (!nodes.length) {
      const expand = document.querySelector("tp-yt-paper-button#expand, #description-inline-expander #expand");
      if (expand) expand.click();
      const button =
        document.querySelector("ytd-video-description-transcript-section-renderer button") ||
        Array.from(document.querySelectorAll("button, ytd-button-renderer")).find((b) => /transcript/i.test(b.textContent || b.getAttribute("aria-label") || ""));
      if (!button) return [];
      button.click();
      nodes = await waitFor(SEGMENT, 6000);
    }
    return Array.from(nodes)
      .map((n) => {
        const ts = n.querySelector(".segment-timestamp");
        const tx = n.querySelector(".segment-text, yt-formatted-string");
        return { start: ts ? parseTimestamp(ts.textContent) : 0, duration: 0, text: (tx ? tx.textContent : n.textContent).replace(/\s+/g, " ").trim() };
      })
      .filter((s) => s.text);
  }

  function formatTime(seconds) {
    const s = Math.floor(seconds);
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = String(s % 60).padStart(2, "0");
    return h ? `${h}:${String(m).padStart(2, "0")}:${sec}` : `${m}:${sec}`;
  }

  async function transcript(args) {
    const videoId = (args && args.videoId) || videoIdFrom(location.href);
    if (!videoId) throw Object.assign(new Error("Not a YouTube video page"), { code: "not_video" });
    const lang = (args && args.lang) || null;
    const key = `${videoId}:${lang || ""}`;
    if (cache.has(key) && !(args && args.refresh)) return cache.get(key);

    let segments = [];
    let source = "captions-json3";
    let track = null;
    let details = {};
    try {
      const pr = await playerResponse(videoId);
      details = pr.videoDetails || {};
      const tracks = (((pr.captions || {}).playerCaptionsTracklistRenderer || {}).captionTracks || []);
      track = pickTrack(tracks, lang);
      if (track) {
        segments = await fetchJson3(track.baseUrl);
        if (!segments.length) {
          source = "captions-xml";
          segments = await fetchXml(track.baseUrl);
        }
      }
    } catch (e) {
      if (arc.debug) console.debug("[arc] caption track path failed", e);
    }
    if (!segments.length) {
      source = "transcript-panel";
      segments = await scrapeTranscriptPanel();
    }
    if (!segments.length) throw Object.assign(new Error("This video has no available transcript"), { code: "no_transcript" });

    const result = {
      videoId,
      title: details.title || document.title.replace(/ - YouTube$/, ""),
      author: details.author || null,
      lengthSeconds: details.lengthSeconds ? Number(details.lengthSeconds) : null,
      language: track ? track.languageCode : lang,
      isAutoGenerated: track ? track.kind === "asr" : null,
      source,
      segments,
      text: segments.map((s) => `[${formatTime(s.start)}] ${s.text}`).join("\n"),
    };
    cache.set(key, result);
    return result;
  }

  arc.register("youtube.transcript", transcript);
  arc.register("youtube.videoInfo", () => ({ videoId: videoIdFrom(location.href), url: location.href }));
  arc.register("youtube.seek", ({ seconds }) => {
    const video = document.querySelector("video");
    if (!video) return { ok: false };
    video.currentTime = Math.max(0, Number(seconds) || 0);
    return { ok: true };
  });

  let lastVideo = null;
  function announce() {
    const id = videoIdFrom(location.href);
    if (id === lastVideo) return;
    lastVideo = id;
    arc.emit("youtube.videoChanged", { videoId: id, url: location.href });
  }
  announce();
  document.addEventListener("yt-navigate-finish", () => setTimeout(announce, 100));
  window.addEventListener("popstate", announce);
  // Also nudged by native code on URL changes (no polling timer).
  arc.register("youtube.recheck", () => {
    announce();
    return null;
  });
})();
