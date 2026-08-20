# App Store listing — Inkstone

Everything App Store Connect asks for, written and ready to paste. Character
limits are Apple's and each field below is inside its own.

**This cannot be entered until the app record exists.** Creating it is the one
manual step: appstoreconnect.apple.com → Apps → **+** → New App, platform iOS,
name `Inkstone`, primary language English (U.S.), bundle ID `com.orris.inkstone`
(already registered), SKU `inkstone`. The App Store Connect API refuses to create
app records — `POST /v1/apps` returns 403, "The resource 'apps' does not allow
'CREATE'" — so there is no scripted way around it.

---

## App information

| Field | Value |
| --- | --- |
| Name (30) | `Inkstone` |
| Subtitle (30) | `Markdown notes, as files` |
| Bundle ID | `com.orris.inkstone` |
| SKU | `inkstone` |
| Primary category | Productivity |
| Secondary category | Utilities |
| Primary language | English (U.S.) |
| Copyright | `2026 Orris Technology Pty Ltd` |

## URLs

| Field | Value |
| --- | --- |
| Privacy Policy URL | `https://inkslab.app/privacy.html` |
| Support URL | `https://github.com/iamzifei/inkstone/issues` |
| Marketing URL | `https://inkslab.app` |

## Promotional text (170)

```
Your notes stay plain Markdown files in a folder you choose — openable by any
other editor, on any other device, long after this app is gone.
```

## Description (4000)

```
Inkstone keeps your notes as what they already are: plain Markdown files, in a
folder you choose, on your own device.

There is no database, no import step and no proprietary format. A vault another
Markdown app created opens here, and a vault created here opens there. If
Inkstone disappeared tomorrow, you would still have a folder of Markdown.

WRITING
Headings, bold, quotes, callouts, checkboxes, tables and code all render in
place as you type, with the syntax revealed only on the line the cursor is on.
Reading mode is a separate, read-only view for when you want the page without
the scaffolding. Body font, code font and their sizes are set independently.

LINKING
[[Note]], [[Note#Heading]], [[Note^block]], ![[Embeds]] and aliases declared in
frontmatter all resolve into one index. Every note shows what points at it, what
it points at, and which of its links have no target yet. Rename a note and every
link that pointed at it is rewritten across the whole vault, in the same action.

SEEING THE SHAPE
The graph view draws your notes as nodes joined by their links, and the
simulation is deterministic — the same vault draws the same picture every time,
so you can learn its layout instead of re-reading it on every open.

SPATIAL NOTES
The canvas puts cards, files and connections on an infinite sheet, saved as JSON
Canvas 1.0 — the same open format other implementations read and write.

FINDING THINGS
A fuzzy switcher opens over every note with one gesture. Full-text search
understands tag: and path:, and tags work inline or in frontmatter, nested, in
any script: #项目/进行中 indexes exactly like #project/active.

TYPOGRAPHY THAT HANDLES CJK
Chinese sets solid — no word spaces — so a Latin word dropped into a Han
sentence collides with it. Inkstone sets the gap between scripts properly, and
lets you choose fonts and sizes that suit both.

TWO DEVICES
Sync a vault through iCloud, or push it to a GitHub repository with conflicts
settled once rather than left as two copies. Per-file-type filters decide
whether attachments and media travel with it.

PRIVATE BY CONSTRUCTION
No account. No telemetry. No network call you did not ask for. Your files are on
your device and go only where you send them.

Interface in English, 简体中文 and 繁體中文.
```

## Keywords (100, comma-separated, no spaces after commas)

```
markdown,notes,wiki,zettelkasten,backlink,graph,canvas,plain text,writing,editor,obsidian,vault,note
```

## What's New (4000) — first version

```
First release.
```

## Screenshots

Captured 2026-08-20 from the current build, at exactly the sizes Apple requires,
so none of them need resizing or padding.

| Set | Size | Files |
| --- | --- | --- |
| iPhone 6.9" | 1320 × 2868 | `assets/ios-shots/01-library.png` … `06-search.png` |
| iPad 13" | 2064 × 2752 | `assets/ios-shots/ipad/01-live-preview.png` … `03-measure.png` |

Reproduce with `scripts/capture-ios-shots.sh`.

## App Privacy answers

Every question is "No", because the app collects nothing:

- **Data collection**: *No, we do not collect data from this app.*

That answer is truthful and worth keeping truthful — there is no analytics SDK,
no crash reporter, and no server of ours. iCloud and GitHub are the user's own
accounts, reached only when the user configures them, and Apple does not count a
user's own iCloud storage as collection by the developer.

## Age rating

4+. No objectionable content of any kind, no user-generated content from anyone
but the user, no advertising, no web browsing beyond fetching a static update
feed.

## Export compliance

The app uses HTTPS to reach GitHub, iCloud and its own update feed, and stores a
token in the Keychain. That is standard, exempt encryption:

- Does your app use encryption? **Yes**
- Does it qualify for any exemptions? **Yes** — only standard encryption within
  Apple's operating system, and HTTPS.
- Result: exempt, no CCATS or year-end self-classification report needed.

`ITSAppUsesNonExemptEncryption` is set to `false` in Info.plist, so App Store
Connect stops asking on every upload.
