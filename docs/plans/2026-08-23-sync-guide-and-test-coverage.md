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

## HUMAN QUEUE

* Notarising the macOS build needs the Apple credentials; unattended packaging
  produces an unnotarised artefact.
* Uploading to App Store Connect needs a 2FA code.
