# Privacy in Lily

What Lily keeps about you, for how long, what leaves your Mac and to whom, and what you can do
about each. Security (keeping others from breaking in) is in the README's Security section; this
is about what Lily itself does with your data when everything works as designed.

**In short:** Lily has no account, no telemetry, no analytics and no crash reporting of its own.
What it stores stays on your Mac, encrypted. What it sends is what browsing needs: the pages you
open, plus a few things listed below that you can turn off.

## What stays on your Mac

All in Lily's sandbox container (`~/Library/Containers/dev.lily.browser/`). "Encrypted" means
AES-GCM with a key in your Keychain that only Lily can read, written owner-only and excluded from
backups.

| What | Encrypted | Kept for | Removed by |
|---|---|---|---|
| Open tabs, pinned tabs, spaces (the session) | yes | until they change | Clear Browsing Data; closing tabs |
| History: page addresses, titles, times | yes | 90 days by default (Settings → Privacy → Keep history), at most 20,000 visits | Clear Browsing Data; History → Clear; *Clear history when Lily quits*; deleting visits |
| Site icons, one small image per site you visited | yes (site names too) | while the site is in history; at most 600 | anything that removes the history it came from |
| Typed text in long fields (comments, posts, messages) | yes | 24 hours; until the form is sent or the field emptied | Clear Browsing Data; *Clear history when Lily quits* |
| Site settings (zoom, dark mode, JavaScript, camera, microphone, ads), per site | yes | until you change them | Site Settings → Clear; Clear Browsing Data (*Also forget site settings*, on by default) |
| Bookmarks (imported) | yes | until removed | Bookmarks → Remove All Bookmarks |
| Installed extensions and their storage | yes | until removed | Settings → Extensions |
| Cookies, site storage, caches | by WebKit, not by Lily (FileVault protects them on disk) | as sites set them | Clear Browsing Data; *Clear cookies and website data when Lily quits*; per site in Site Settings |
| A space's own cookies and site data (Separate logins) | as above | as above | the same, and deleting the space |
| Preferences (search engine, homepage, switches, window positions) | no (nothing sensitive) | until changed | — |
| Filter lists for ad blocking | no (public lists, nothing about you) | refreshed weekly | turning the list off |

**Only in memory, gone when Lily quits:** the assistant's context (what you browsed, per tab, so it
can answer about the page), the downloads list, recently closed tabs, and icons seen in private
windows.

**Private windows** write none of the above: no history, no session, no typed-text drafts, no
kept icons, website data in memory only. Their downloads aren't listed in regular windows and are
forgotten when the last private window closes, and their files don't keep the address they came
from (see Downloads). macOS is asked to keep private windows out of screenshots and screen
sharing, and text copied from them is marked so clipboard managers skip it.

**Logs** go to the system log with page addresses, file paths and other personal values marked
private, so they don't appear in Console or crash reports.

## What leaves your Mac

| When | What is sent | To whom | Your control |
|---|---|---|---|
| You open a page | the request, with Safari's user agent | that website (and the sites it loads) | the ad and tracker blocker, link tracking protection, HTTPS-First |
| A tab is open | a request for its site's icon, once per session | that same website | — |
| You search from the address bar | the search text | your search engine (DuckDuckGo by default; Google, Bing, Kagi, Ecosia in Settings → General) | the search engine choice. Nothing is sent while you type: there are no remote suggestions. |
| Ad blocking with filter lists on | a weekly download of each list | the list's maintainer (EasyList, uBlock, AdGuard, Peter Lowe), who sees your IP address | Settings → Privacy → filter lists (the built-in list needs no download) |
| You add an extension from the store | the extension's ID, without cookies or stored logins | Google (Chrome Web Store) | only when you ask |
| Fraudulent-site warnings | parts of hashes of addresses, checked against lists of known fraud sites | Apple, which relays the lookups to its Safe Browsing providers | Settings → Privacy → *Warn about fraudulent websites* (on by default, as in Safari) |
| Handoff | the current page's address and title | your devices on your Apple account | **off by default**; Settings → Privacy → *Continue pages on other devices* |
| You use the assistant | the page's text and your question | Ollama on your Mac, or the Ollama host you set (HTTPS, optionally pinned) | the assistant's server setting |
| Links from other apps | nothing extra: they open in Little Lily or a tab | — | — |

**Lily never sends:** usage statistics, analytics, crash reports of its own, or your history,
bookmarks or typed text to anyone.

## How Lily limits tracking by websites

- **Ads and trackers** are blocked with WebKit content rules: a built-in list, plus the filter lists you choose.
- **Trackers in links are removed** (Settings → Privacy, on by default). Click and campaign identifiers such as `utm_…`, `fbclid`, `gclid`, `msclkid` and `mc_eid` are taken out of links you click, type, open from other apps or copy. The rest of the address is unchanged.
- **Site icons aren't fetched from lists.** History, suggestions and sleeping tabs show icons kept from your visits, so drawing a list never tells the sites in it that you have them in your history.
- **Blending in.** Lily presents exactly as Safari on the same Mac, with no "Lily" in the user agent, so it doesn't stand out to fingerprinting.
- **WebKit's own protections:** third-party cookies are blocked, and Intelligent Tracking Prevention applies as in Safari.
- **Separate logins** keep a space's cookies and storage apart, so sites in different spaces can't link your accounts through them.
- **HTTPS-First** keeps pages off unencrypted connections where a site supports HTTPS.

## Downloads

Files go to your Downloads folder. macOS records where a downloaded file came from in two places
on the file itself: the "Where from" metadata (shown in Finder's Get Info) and the quarantine
record that makes Gatekeeper check it. For downloads from **private windows**, Lily removes the
address from both and keeps the quarantine itself, so the file is still checked.

## What isn't covered yet

Honest limits, so you can decide for yourself:

- **WebKit writes cookies and site storage itself**, inside Lily's container. FileVault and the sandbox protect them, but Lily doesn't encrypt them a second time. *Clear cookies and website data when Lily quits* removes them.
- **No Global Privacy Control or Do Not Track signal** is sent. WebKit gives apps no way to add the header to every request.
- **macOS's own quarantine log** may keep a system-wide record of downloads that Lily can't edit. The file-level scrub described above is verified by tests run outside the sandbox.
- **Extensions** run with the permissions you approved and handle data their own way. Lily audits their code before installing; see [EXTENSIONS.md](EXTENSIONS.md).
- **Filter-list maintainers** see your IP address once a week for each list you turn on.
