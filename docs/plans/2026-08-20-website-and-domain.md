# Inkstone — website and domain

Started 2026-08-20 (Sydney). Owner: Claude, with two items only James can do.

## Goal

A marketing site for Inkstone at its own domain, in the same family as the three
sibling macOS apps (AudioSwitch, Candela, ClipStack) but designed to a much higher
typographic standard — the brief was "newspaper, magazine, book", with CJK-Latin
mixed setting treated as a first-class problem rather than a fallback.

## Decisions already closed — do not reopen

| Decision | Value | Why / evidence |
| --- | --- | --- |
| Domain | **inkslab.app** | James chose it 2026-08-20 from a checked shortlist. `inkstone.com/.app/.io/.dev/.so/.md/.ing/.studio/.pro/.xyz` are all taken — `.md`, the ideal one for a Markdown app, was **registered 2026-07-31**, three weeks before we looked (whois). `inkstone` = *ink slab*, so the name is a translation, not a compromise. Vercel quote $9.99 first year; the domain skill's reference table puts renewal at **$14.93** — 1.7×, which is normal for `.app`. Rejected `inkstone.wiki` at $2.99: its renewal is **$26.26, a 12.7× jump**. |
| Site generator | Adapt `~/Dev/candela/site/build.py` | 694 lines, already production-tested on getcandela.app. It carries hreflang/canonical/og:url computed from one `SITE` constant, srcset from a screenshot manifest, sitemap, robots, `.nojekyll`, `CNAME`, a build fingerprint for the deploy wait, and a reduced-motion path for the hero video. Rewriting all of that would be re-deriving solved problems. **The generator is reused; the design is not** — Inkstone gets its own stylesheet from zero. |
| Hosting | GitHub Pages, domain registered at Vercel | Exactly what Candela does. Keeps the three-app family on one deploy story. |
| Languages | en · zh · zh-Hant · ja · ko · de · fr · es | Same eight as Candela. The app itself ships en/zh/zh-Hant (108 strings); the site goes wider because a site is cheap to translate and an app is not. |
| Sibling links | AudioSwitch, Candela, ClipStack | James named these three explicitly. Not PoseUp/FigViz/AdWhiz/ImaginePro — those are web products, a different audience. |
| Hero | A real screen recording of the macOS app | James chose "我来录" over a placeholder or a CSS mock. |

## Phases

- [ ] **P0 Domain.** Quoted at **$9.99/yr, auto-renew on, non-refundable** (Vercel, team orris, 2026-08-20). **Blocked on James: registrant contact (name, phone, postal address) and an explicit go-ahead.** Vercel keeps no reusable WHOIS profile, and I will not invent one.
- [x] **P1 Demo footage.** 12-note demo vault at `assets/demo-vault`, five scripted segments, encoded to `site/assets/video/hero.{mp4,webm}` + poster. 39 s, 503 KB / 543 KB.
- [x] **P2 Screenshots.** Six, all captured 2026-08-20 from the current build, WebP at 640/960/1280 plus intrinsic, sizes in a manifest the build reads.
- [x] **P3 Site.** `site/build.py`, `site/typeset.py`, `site/assets/styles.css`, `site/assets/site.js`, content as per-language YAML.
- [x] **P4 Translate.** Eight languages. Structure lives in the template, so a dropped key is a build error rather than a missing section.
- [ ] **P5 Deploy.** Workflow written (`.github/workflows/site.yml`, Pages via artifact so `docs/` stays private). Waiting on the domain.

## What the recording rig learned, so it is not re-derived

Four constraints shaped every script in `scripts/`. All four were found the hard way.

1. **A non-frontmost app has no key window, so it has no first responder.** Menu
   key-equivalents (⌘N, ⌘O, ⌘⇧G) still arrive; typing, pasting and clicking do
   not. `scripts/send-keys.py` posts to the pid with `CGEventPostToPid`, which is
   what makes the menu half work while the app is covered.
2. **The Mac was at the lock screen for the first two hours** (`loginwindow` at
   window layer 2004). That is why nothing could be focused. `record-demo.sh` now
   tests `can_focus` and skips the takes that need input rather than shipping
   empty ones — the first attempt recorded thirty characters typed into nothing.
3. **A sleeping display records black.** `caffeinate -d -u` runs for the whole
   session. The first capture was a 156 KB all-black PNG that looked exactly like
   a permissions failure.
4. **`screencapture -v` ignores SIGINT and ignores `-o`.** So `-V` is the stop,
   not a safety limit, and every frame carries a drop shadow whose size depends
   on whether the window was active — 3736×2396 when covered, 3824×2484 when
   frontmost, around the same 3600×2260 window. `measure-window-crop.py` reads it
   off the frame instead of hardcoding it.

## Defects found while doing this

- 🔴 **`[[Note|alias]]` renders with an empty label.** Seen in live preview on
  `Home.md`: the piped links showed as blank runs, one list item rendered as an
  empty bullet. Non-piped `[[Note]]` is fine. The demo vault has had its pipes
  removed so the screenshots do not show it, which means **the vault is no longer
  a regression test for it** — worth a real test case in `InkstoneCore`.
- 🟡 **A canvas opened programmatically never runs fit-to-content**, so it comes
  up as specks in the top-left corner. Opening the same canvas by clicking the
  sidebar frames it correctly. Only reachable by clicking, so the site's canvas
  shot is a click-driven capture.
- 🟡 **No `LICENSE` file.** The README and the site both wanted to say "free and
  open source"; public source with no licence is not open source. The site now
  says "Public on GitHub. A licence has not been chosen yet." Pick one and the
  copy can go back.

## HUMAN QUEUE

1. 🔴 **Registrant contact for inkslab.app** — first/last name, email, phone (+61…),
   street address, city, state, postcode, country. Needed to call `buy_domain`;
   the charge is immediate, non-refundable, and auto-renew is on. Alternative:
   James buys it at <https://vercel.com/domains/search?q=inkslab.app> and P0 is skipped.
2. 🟡 **DNS + Pages settings** after purchase — four A records to GitHub Pages
   (185.199.108–111.153) plus AAAA, and set the custom domain on the repo. The
   `CNAME` file is already generated from `SITE`, so nothing in the build changes.
3. 🟡 **Choose a licence** (see defects above), then the site copy can say so.
4. 🟡 **Cut a release** and flip `HAS_RELEASE = True` in `site/build.py`. That one
   line switches the primary button, its note and the JSON-LD `downloadUrl` from
   "Read the source" to the DMG.

## Verification standard for this plan

Nothing here gets marked done on "the code is written". Done means: the build
succeeded and the artifact was run, the video plays, the deployed URL returns 200,
and the hreflang targets were fetched rather than assumed.
