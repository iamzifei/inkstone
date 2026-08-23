# The GitHub repository is an app setting, not a vault setting

**Status:** root cause fixed 2026-08-22. Mass-deletion guard still to do.

## What was reported

Conflict files appearing in a notes vault, and a note renamed on 08-21
(an old name → a new one) reappearing under its old name at
14:34 on 08-22. Attributed in the moment to "Obsidian/iCloud sync". It is
neither. That vault has no Obsidian Sync and is not in iCloud Drive.

## What it actually is

`SyncEngine.conflictFilename` produces `<stem> (conflict <stamp>)` and
`timestamp()` is `"yyyy-MM-dd HHmm"`. The file is
`<a note> (conflict 2026-08-22 1218).md`. That is Inkstone's own format, to the
character, and `a user's notes vault/.inkstone/sync.json` confirms the vault is under
Inkstone sync — 1387 blobs, repository a private notes repository, branch `master`.

Read from both devices' actual defaults:

| | Mac | iPhone |
| --- | --- | --- |
| repository | a private notes repository | a private notes repository |
| branch | `master` | `master` |
| auto-sync | on, every 15 min | on, every 15 min |
| **vault** | a folder under `~/Dev` | `…/AppGroup/…/File Provider Storage/` |

**Two unrelated working trees, one repository, both on a 15-minute timer.** Each
run, each side sees the other's files as foreign changes. That is the whole
mechanism:

* Both sides edited since the last common base → a conflict copy. Every hour, on
  the same files: one rules note at 1420 and again at
  1716, another at 1218 and again at 1420.
* A file renamed on the Mac still exists under its old name on the other tree.
  With no base recorded there, the planner reads it as a local addition and
  uploads it. It comes back. That is the resurrection, and it will keep
  happening for as long as both trees point at one repository.

The Mac's own conflict copies carry an mtime matching their name (12:18). The
1420/1616/1716 ones all have mtime 18:04 — they were **downloaded**, not written
here. That is the second device, visible in the file system.

## Root cause

`gitHubRepository`, `gitHubBranch`, `gitHubSyncEnabled` and `gitHubAutoSync` live
in `SettingsData` — one global blob in `UserDefaults`, shared by every vault the
app has ever opened. Open a different vault and it inherits the repository, then
immediately starts making that repository look like itself.

`Workspace.startSharingSyncConfiguration` / `publishSyncConfiguration` then
broadcast that global setting to the user's other devices over iCloud. The intent
is not having to set up the second device. The effect is that a repository
configured for one vault is applied to a completely different vault elsewhere.

**This already destroyed content in a second repository.** `Samples/Inkstone
Demo/` was deleted from this repository by six `Delete … from Inkstone`
commits on 08-18, and `main`'s test suite has been failing since. Same mechanism:
a vault that did not contain those files, syncing to a repository that did.

## What is done

1. ✅ **`SettingsData.vaultSync: [String: VaultSyncBinding]`** — repository,
   branch and enabled are per vault. An unbound vault does not sync; it no
   longer borrows another vault's repository.
2. ✅ **Migration** onto the most recently opened vault only, guarded by
   `didMigrateSyncBindings`. Every other vault starts unbound and silent.
3. ✅ **Shared configuration can no longer introduce a repository.** `applyShared`
   adopts only when the open vault's binding already names the same repository;
   otherwise it becomes `pendingSharedConfiguration`, which the Sync pane offers
   as a button rather than applying.
4. ✅ **Git working copies are left alone.** `.git` at the vault root disables
   sync for that vault, with the reason stated and a per-vault "Sync it anyway"
   override. Only ever true where git exists, so a phone is unaffected.
5. ✅ **`.gitignore` syncs.** It was invisible twice over — hidden, so the
   directory walk skipped it, and extensionless, so the policy filed it under
   "other", which is off by default. A second device therefore held the same
   notes and none of the rules about which of them to carry. That is not
   hypothetical: a recordings folder and audio chunks are excluded by one vault's
   `.gitignore` and sit in its repository regardless. A vault whose `.gitignore`
   names itself still keeps it private.
6. ✅ **Mass-deletion guard.** A run that would delete more than half of the
   *recorded* blobs — measured against `state.blobs`, not against what is on
   disk now — stops with `SyncError.tooManyDeletions` and says how many, out of
   how many, and on which side. Confirming lets the same run through.

   Two thresholds, because a guard that fires on ordinary tidying is worse than
   none: people learn to click past it, and then it does not work for the case
   it exists for. Half is generous on purpose — this is not trying to catch a
   careless clean-up, it is trying to catch the shape both incidents had, where
   a vault is bound to a repository that is not its own and nearly everything on
   one side reads as deleted on the other. And below ten files the share is
   meaningless: two of three is 67% and is nobody's disaster.

   `MassDeletionGuardTests` covers both halves, plus the first sync, which has
   no recorded state to measure against and nothing it could be deleting.

A trap worth recording: `SettingsData` has a hand-written lenient `init(from:)`.
`CodingKeys` is synthesised and picks new properties up automatically, but the
decoder does not — a new property added to the struct and forgotten in the
decoder loads as its default forever. Three new keys would have meant every
vault silently losing its binding on the next launch. `VaultSyncBindingTests`
covers the round trip for that reason.

## The fix as designed

Move the repository binding to the vault:

1. `repository`, `branch`, `isEnabled`, `isAutomatic`, `intervalMinutes` become
   per-vault, keyed by vault id, not global.
2. Migration: the current global values attach to the vault that has a
   `.inkstone/sync.json` naming that repository, and to no other.
3. `canSync` requires the open vault's own binding. A vault with no binding does
   not sync, rather than borrowing one.
4. Shared configuration carries the vault identity too, and applies only to a
   vault whose recorded repository already matches. It must never be able to
   introduce a repository to a vault that had none.
5. A guard worth having regardless: refuse a run that would delete more than
   some fraction of the recorded blobs without an explicit confirmation. Both
   incidents here were mass deletions that no one asked for.

## Stopping it now, before any of that

Turn off **Sync this vault with GitHub** on the iPhone (Settings › Sync). One
toggle, and the two trees stop fighting. Then delete the conflict copies on the
Mac after checking which side each one holds — at least one is larger than the
live file it sits beside — one was 5509 bytes against 3399 — so they are not
all redundant.

## The repository was reconciled, 2026-08-22

a user's notes vault and `origin/master` had diverged to 72 local commits against 1410
remote ones, 182 files apart. Classified rather than merged blind — full report
kept with the vault it concerns, outside this public repository:

| | |
| --- | --- |
| 🔴 remote held an **older** version than local | 10 files |
| line-ending only (`core.autocrlf = input` strips a CR that Inkstone's raw PUT kept) | 9 files |
| genuine content difference, local newer | 1 file (the renamed rules note) |
| conflict copies and the resurrected old name | 9 files, deleted |
| new local work never pushed | 84 files |

Merged with `-X ours` in a throwaway worktree first, then **verified file by file**
that all ten regressions kept the local version before the result went anywhere
near the real working tree. 52 sampled raw-material files were confirmed
byte-identical to the copies already on disk, so the merge could not overwrite
them. `pre-reconcile-2026-08-22` tags the pre-merge local HEAD.

No content was lost in the incident. Everything the remote held that local did
not was either junk this cleanup deleted, or a stale copy of something local
already had newer.

## Loose ends

* Eight conflict copies as of 18:05 on 08-22.
* The note renamed on 08-21 was back on disk under its old name alongside the
  new one. The rename needs redoing once syncing is safe.
* Stray notes still at the root of this repository: `Meeting notes.md`,
  `Note.md`, `Sync check.md`, `中文笔记.md`.
