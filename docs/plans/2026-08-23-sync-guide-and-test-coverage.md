# A sync guide on the site, linked from the app, behind a green test suite

**Started** 2026-08-23. Requested: a tutorial page covering iCloud *and* GitHub
sync, published to the site; its URL surfaced as help in Settings › Sync; both
clients packaged; everything covered by tests and green; committed and pushed.

## Stages

| # | Stage | Done when |
| --- | --- | --- |
| 1 | Write the guide as `site/static/sync.html` | `site/build.py` emits it and the page renders in the site's own type |
| 2 | Link it from Settings › Sync on both platforms | The footer of the GitHub section carries a link, and iCloud's section carries one too |
| 3 | Tests | Unit, smoke, end-to-end and regression all run from one command and pass |
| 4 | Package | A signed `.dmg` for macOS and an `.ipa` for iOS |
| 5 | Commit and push | Clean tree, `origin/main` up to date |

## Why the guide is a static page rather than an eighth-language content file

`site/build.py` requires **every** page to exist in **every** one of the eight
languages, and fails the build otherwise — deliberately, so a dropped translation
is an error rather than a silently missing paragraph. `site/static/` is the
existing escape hatch, and its comment says why: a privacy policy Apple requires
in one language should not be held hostage to that rule. A help page the app
links to has the same shape. It goes in `static/`, matching `privacy.html`.

## What "covered by tests" can and cannot mean here

Stated plainly rather than implied, because the request is for *everything* to be
covered and that is not a claim any honest suite can make about a GUI app.

* **Unit** — `InkstoneCore`, the whole model layer. Real coverage.
* **End-to-end** — `SyncEngine` against a stubbed GitHub, both devices simulated
  by two vault directories against one fake remote. This is where the two
  incidents of this week would have been caught.
* **Regression** — one test per bug actually hit: the interruption contract, the
  per-vault binding, `.gitignore` travelling, the vault-relative path, the
  settings decoder that silently drops new keys.
* **Smoke** — the built app, launched, driving a real vault through create →
  edit → save → reopen → search → rename → delete, and reporting.
* **Not covered** — anything that needs a mouse: the context menu, the Settings
  toggles, the file tree. Reaching those needs a UI-test target and a real
  windowing session. Named here rather than papered over.

## Result

`scripts/test-all.sh` is the one command. Everything green on 2026-08-23:

```
core: pass     308 tests, 56 suites  (unit + e2e + regression)
site: pass      20 tests, 151 subtests
iOS: pass      BUILD SUCCEEDED
macOS: pass    BUILD SUCCEEDED
smoke: pass    21 checks against a real vault on disk
```

New this round:

* `TwoDeviceSyncTests` — a fake GitHub that actually **stores** what is uploaded,
  so two vault directories can be driven against one repository. Every other sync
  test drives one vault against a fixed stub, which cannot see the failures that
  matter. Six tests: alternating edits never conflict, different notes never
  conflict, the same note conflicts and keeps both and settles, a rename does not
  resurrect, an unrelated empty vault downloads the repository rather than
  emptying it, and ignore rules travel to the second device.
* `site/tests/test_site.py` — the built site, and the seam nothing else watches:
  the app hard-codes a URL into this site, the Swift side compiles whatever
  string it is given, and neither knows about the other. One test resolves
  `SyncHelp.url` against the page the site actually publishes.
* `App/Support/SmokeTest.swift` — `INKSTONE_SMOKE=1` drives `Workspace`, which
  lives in the app target where the package's suite cannot reach it, and which is
  where both sync incidents happened.

Two traps found while writing them, both worth keeping:

* **`URLRequest.httpBody` is nil inside a `URLProtocol`.** URLSession converts it
  to a stream before the protocol sees it. Reading only `httpBody` made every
  fake upload store zero bytes — the listing showed the right filenames and every
  download produced an empty note, which is far more confusing than an error.
* **Spinning the run loop does not service main-actor continuations from `init`.**
  The smoke test's first version waited for indexing that way and timed out
  against work that had never been given a chance to start. `Task.sleep` yields;
  `RunLoop.run` there does not.

## Second pass: three languages, and pictures

The guide shipped in English only, and the app linked to it regardless of the
language the app was being read in.

**`site/guide.py` now holds the structure once and the words three times** — the
languages the app itself ships. Not the site's eight: that system fails the build
unless every page exists in all of them, which is right for marketing copy and
wrong here, because promising a French guide the app does not have is worse than
sending a French reader to the English one. `build.py` renders it into the same
language directories the rest of the site uses, so `SyncHelp.url(for:)` in the
app is a prefix and a filename. It matches on **script**, not region: `zh-Hans-SG`
and `zh-Hant-HK` differ in the half that decides which page a reader can read.

Two tests hold the seam that nothing else watches. One reads
`SyncHelp.directories` out of the Swift and resolves every URL it can produce
against the pages the site actually emits. The other compares the `<h2>` ids
across the three languages, so a translation that quietly loses a section fails
the build rather than waiting for a reader of that language to notice.

**The screenshots are captured, not staged.** `scripts/capture-sync-shots.sh`
drives the real app: the Sync pane with a repository set, the notice shown for a
git working copy, and a conflict copy sitting beside the note it came from.

Desensitisation is by construction, and it took two goes:

* `INKSTONE_DEMO_DEFAULTS` swaps `UserDefaults` for a scratch suite, so the vault
  list, bindings and interval on screen are the seeded ones.
* **That was not enough.** The first capture had a private repository name across
  the top of the pane — published by another device into `NSUbiquitousKeyValueStore`,
  which is iCloud and untouched by any defaults suite. `SharedSyncConfiguration`
  now reads *and writes* nothing during a demo launch; the write direction is the
  worse one, since a demo repository published into a real iCloud store would
  propagate an invented setup to the user's own devices.
* A test greps the committed PNGs for the strings that leaked, so the check
  outlives the memory of it.

Three things the capture pipeline needed, each found by the picture being wrong:

* The sandboxed build cannot open a vault outside the file picker, so the harness
  builds with `Inkstone-Dev.entitlements` — as `record-demo.sh` already did.
* The Settings window is 560×460, under `inkstone-window.py`'s size floor, so it
  was not merely deprioritised but invisible; `--title` picks it by name.
* macOS ships bash 3.2, where expanding an empty array under `set -u` is an
  error — which surfaced as an empty window id, reading as "no window" rather
  than "bad shell".

## HUMAN QUEUE

* Notarising the macOS build needs the Apple credentials; unattended packaging
  produces an unnotarised artefact.
* Uploading to App Store Connect needs a 2FA code.
