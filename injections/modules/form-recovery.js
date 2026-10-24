// Keeps what you type into long fields (comments, posts, messages) so it can be put back if the
// page crashes, closes or reloads before you send it (FormDrafts.swift).
//
// Only textareas and rich-text editors, never single-line inputs, and never fields that hold
// secrets: password, card and one-time-code fields, anything marked autocomplete="off", or
// read-only and disabled fields. Short text (under 20 characters) isn't kept. Sending the form
// or emptying the field forgets it. Restoring only fills fields that are empty, as plain text.
(() => {
  "use strict";
  const lily = window.__lily;
  if (!lily || window.__lilyFormRecovery) return;
  window.__lilyFormRecovery = true;

  const MIN_CHARS = 20;
  const MAX_CHARS = 40000; // fits the 256 KB message limit even for 4-byte characters
  const DEBOUNCE_MS = 1000;
  const EDITABLE = 'textarea, [contenteditable]:not([contenteditable="false"])';
  const SECRET = /\b(cc-[a-z-]+|one-time-code|current-password|new-password)\b/;
  const pending = new Map(); // field key -> { element, timer }

  // A rich editor's outermost editable element (input events target it, not inner nodes).
  function editableRoot(node) {
    let element = node instanceof Element ? node : node && node.parentElement;
    if (!element) return null;
    if (element.tagName === "TEXTAREA") return element;
    if (!element.isContentEditable) return null;
    while (element.parentElement && element.parentElement.isContentEditable) element = element.parentElement;
    return element;
  }

  function eligible(element) {
    if (!element || element.disabled || element.readOnly || element.getAttribute("aria-readonly") === "true") return false;
    const marks = [element, element.closest("form")].filter(Boolean)
      .map((node) => (node.getAttribute("autocomplete") || "").toLowerCase());
    return !marks.some((mark) => mark === "off" || SECRET.test(mark));
  }

  function textOf(element) {
    return element.tagName === "TEXTAREA" ? element.value : element.innerText;
  }

  function candidates() {
    return Array.from(document.querySelectorAll(EDITABLE)).filter((element) => editableRoot(element) === element && eligible(element));
  }

  // Stable across reloads where the page allows: its id or name, else its position among the
  // page's long-text fields.
  function keyOf(element) {
    const tag = element.tagName.toLowerCase();
    if (element.id) return `${tag}#${element.id}`.slice(0, 200);
    const name = element.getAttribute("name");
    if (name) return `${tag}[name=${name}]`.slice(0, 200);
    return `${tag}:${candidates().indexOf(element)}`;
  }

  function send(key, element) {
    const text = textOf(element) || "";
    if (text.trim().length < MIN_CHARS) {
      lily.emit("form.clear", { url: location.href, field: key });
    } else {
      lily.emit("form.snapshot", { url: location.href, field: key, text: text.slice(0, MAX_CHARS) });
    }
  }

  function flush() {
    for (const [key, entry] of pending) {
      clearTimeout(entry.timer);
      send(key, entry.element);
    }
    pending.clear();
  }

  document.addEventListener("input", (event) => {
    const element = editableRoot(event.target);
    if (!element || !eligible(element)) return;
    const key = keyOf(element);
    const entry = pending.get(key);
    if (entry) clearTimeout(entry.timer);
    const timer = setTimeout(() => {
      pending.delete(key);
      send(key, element);
    }, DEBOUNCE_MS);
    pending.set(key, { element, timer });
  }, { capture: true, passive: true });

  // Sent: nothing left to recover.
  document.addEventListener("submit", (event) => {
    const form = event.target;
    if (!(form instanceof HTMLFormElement)) return;
    for (const element of candidates()) {
      if (!form.contains(element)) continue;
      const key = keyOf(element);
      const entry = pending.get(key);
      if (entry) clearTimeout(entry.timer);
      pending.delete(key);
      lily.emit("form.clear", { url: location.href, field: key });
    }
  }, { capture: true });

  // Leaving or backgrounding the page: don't lose the last second of typing.
  window.addEventListener("pagehide", flush);
  document.addEventListener("visibilitychange", () => { if (document.visibilityState === "hidden") flush(); });

  function fill(element, text) {
    if (element.tagName === "TEXTAREA") {
      // The prototype's setter, so frameworks that track the value (React) see the change.
      const setter = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value").set;
      setter.call(element, text);
    } else {
      element.innerText = text; // plain text: line breaks become <br>, nothing is parsed as HTML
    }
    element.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertReplacementText" }));
  }

  // Native asks after the user chose Restore. Fills empty fields only; returns how many.
  lily.register("form.restore", ({ drafts } = {}) => {
    if (!Array.isArray(drafts)) return { restored: 0 };
    const fields = candidates();
    const empty = fields.filter((element) => textOf(element).trim() === "");
    let restored = 0;
    for (const draft of drafts) {
      if (!draft || typeof draft.field !== "string" || typeof draft.text !== "string") continue;
      let element = fields.find((candidate) => keyOf(candidate) === draft.field);
      // Generated ids change between loads; one draft and one empty field is unambiguous.
      if (!element && drafts.length === 1 && empty.length === 1) element = empty[0];
      if (!element || textOf(element).trim() !== "") continue;
      fill(element, draft.text.slice(0, MAX_CHARS));
      restored += 1;
    }
    return { restored };
  });

  // Whether this page has fields a draft could go back into (native offers Restore only then).
  lily.register("form.fields", () => ({ count: candidates().length }));
})();
