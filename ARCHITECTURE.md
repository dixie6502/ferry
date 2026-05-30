# Architecture

A single place for projects that live **outside GitHub**: no collaboration,
sensitive data, large files, version control optional.

## Purpose

Store and fetch in-progress projects (academic and client work) on storage I
control, choosing per project what lives on local disk. Large binaries (e.g.
PDF literature reviews) are first-class. Grouped by client / research team. The
common pattern is to pull an archived project to re-check it for insight, then
drop it again — alongside a few projects under active editing.

## Non-goals

- Not a version-control system. History, when wanted, is layered on per project
  (see [Git](#git-optional-per-project)).
- Not for collaborative or GitHub-bound work (packages, web apps, dotfiles).
  Those keep using GitHub for issues, Actions, and Railway.

## Components

| Component | Role |
|---|---|
| **Cloud remote** | Any rclone-supported backend. Ideally one with file version history + trash, which then serves as the recovery backstop. |
| **rclone** | The only transfer tool. Stateless, on-demand, single binary. No background daemon. Holds the remote and its credentials in its own config (`rclone config`). |
| **`ferry`** | Thin shell wrapper over rclone. Markers (`.ferry`) select a sparse local mirror; verbs pull/push units, manage tree structure, and snapshot git history. |
| **`ferry-prompt.sh`** | Optional sourced shell function (`__ferry_ps1`) drawing a git-prompt-style drift indicator from the per-machine sync state `ferry` records. |

## Layout

A **partial mirror** of the remote, selected by `.ferry` marker files — a sparse,
on-demand checkout. The tree shape is emergent, not fixed at any depth.

```
~/Projects/.ferry             root   → contains "Remote:Projects"
  CL03-Initech/                      grouping dir, no marker
    site/.ferry                unit   ← transfer unit (empty marker)
    audit/.ferry               unit   ← transfer unit
  Academic/                          grouping dir, no marker
    thesis/refs/.ferry         unit   ← arbitrary depth, no config
```

- **root** — the one directory whose `.ferry` holds the remote base. Found by
  walking **up** from `$PWD` (git's `.git` model). Exactly one per tree.
- **unit** — a leaf: an empty `.ferry`, with no `.ferry` below it, present locally
  because it was pulled or `new`ed. The granularity of every transfer, git bundle,
  and sync-state record.
- **grouping dirs** — the markerless directories between root and unit. They are
  created on the way down by a deep `pull`/`new` and exist only to navigate; they
  are never a sync target.

Two invariants keep discovery unambiguous: **units form an antichain** (no unit
under another — a full pull already brought everything beneath it), and **one
root per tree** (no content-bearing `.ferry` under another). A unit marker is
empty; the root marker has content — so the root is never mistaken for a unit.

### Remote mapping (derived, single-sourced)

Local names mirror remote names, so a node's remote path is purely structural:

```
remote_of(dir) = <root base> + (dir relative to root)
```

The base is stored **once**, at the root; nothing else stores a path. A `mv` of a
grouping dir recomputes every descendant's remote for free; a hand `mv` that
diverges local from remote fails loudly on the next sync rather than orphaning
silently.

## Sync model

On-demand, command-driven transfers with rclone — nothing runs in the
background. A project is on local disk only because it was pulled or created.

Chosen because usage is **mostly archive dip-in** (pull a project, re-check it,
drop it), plus a few active projects. On-demand fetch is the idiomatic fit and
matches the "something I control" goal: no daemon, no surprise propagation.

Continuous two-way sync was considered and rejected: it serves active editing
but handles the dominant dip-in mode clumsily, re-implements selective presence
on top of a full syncer (off-pattern), and depends on a pre-1.0 daemon. rclone
is mature, supports a wide range of backends, and gives a true drift check
(`rclone check`) as a `git fetch`/`status` analog.

**Transfers are additive by default** (`rclone copy`): never delete the far
side. Mirroring (`rclone sync`, where deletions propagate) is an explicit,
per-command opt-in — so a local delete never reaches the cloud unless asked.

## `ferry` verbs

The whole model is two tree walks: **up** to the root for the base, **down** to
the unit leaves (`find . -name .ferry -empty`, keep the leaves) for what to
transfer. That replaces all depth/scope arithmetic — a unit is wherever an empty
leaf marker sits.

| Verb | rclone mapping | Purpose |
|---|---|---|
| `ferry init <base>` | — (writes `.ferry`) | Make `$PWD` a root holding `<base>`. Refused inside an existing tree (no nested roots). |
| `ferry list [<dir>]` | `rclone lsf --dirs-only --format tp` of `remote_of(dir)` | Remote children of a node (or the root); modtime + name, sorted by name. |
| `ferry status [<dir>]` | two one-way `rclone check`s per unit, or none if the remote prefix is absent (`probe_unit`) | Drift for **every** unit at/under `$PWD`, one `= / > / < / <>` row each; from inside a single unit (with a remote), also the file-level diff. Refreshes each unit's prompt cloud bit (see [Sync state](#sync-state--prompt-indicator)). |
| `ferry pull [<dir>]` | `rclone copy remote_of→local`, write marker | Materialize a unit (recursive). Deep `pull a/b` auto-creates parent grouping dirs. No arg → walk units under `$PWD`. |
| `ferry push [<dir>]` | bundle git, then `rclone copy local→remote`, write marker | Send a unit up; confers unit status on a fresh dir. No arg → walk units under `$PWD`. |
| `ferry mv <old> <new>` | `rclone moveto`, then `mv` local | Rename/move a unit or grouping dir, cloud-first. |

### Browse, create & delete

**Browsing needs no local folder.** `list` derives the remote from a path and
lists it directly (`ferry list CL03-Initech`), and a deep `pull a/b` materializes
a unit while `mkdir -p` creates the grouping dirs above it. So the "mirror the
cloud shape as an empty shell" step has no dedicated verb — `list` + `pull` cover
it, and the grouping dirs fall out of the pull.

**`new` creates a unit at birth.** The named folder gets an empty marker — a unit
immediately, visible to `status` and pushable — and any parent dirs fall out as
markerless grouping dirs. A grouping level is therefore never created directly;
you `new` the leaf and the dirs above it appear. The cloud side is **not**
pre-created: an empty directory is unrepresentable on object stores, so the prefix
materializes on the first `push`. A never-pushed unit still reads correctly —
`status` shows `=` while empty, `>` once it holds files (see
[Backend agnosticism](#backend-agnosticism)). The sync baseline is recorded at
creation (empty local, empty/absent cloud → in sync). The delete verbs both act
on a **local unit** and split on which side they destroy:

| Verb | exists on cloud? | effect | cloud |
|---|---|---|---|
| `ferry new <name>` | must **not** | start a brand-new unit; cloud prefix on first push | — (push) |
| `ferry drop <dir>` | — | delete the **local** unit — presence control; cloud retains | untouched |
| `ferry rm <dir>` | — | delete a **unit** both sides — confirmation-gated; recovery depends on the remote's trash/versioning | `rclone purge` |

`rm` is restricted to a local unit: a cloud-only path or a whole grouping subtree
is out of scope — use `rclone` directly for those (the model never deletes
something it does not hold locally).

`new` / `pull <sub>` are refused inside a unit's subtree — you are already in
materialized content, there is nothing to fetch or place. `drop` and `rm` are
kept distinct deliberately: local presence control is not cloud retention, and
the two must never collapse into one ambiguous delete.

### No-arg walk

`status` and `push`/`pull` with no `<dir>` walk **down** from `$PWD` and act on
every unit — an **empty** `.ferry` with no `.ferry` descendant. Each yields
`(localdir, remote)` by derivation, run through the same single-unit path;
markerless grouping dirs and the root's content marker (`find … -empty` excludes
it) are skipped. Because units are an antichain, no node is ever both
walked-as-parent and walked-as-child, so no bytes transfer twice.

**Transfers stay additive** (`rclone copy`); `--mirror` (`rclone sync`,
deletions propagate) is an explicit, single-unit-only opt-in. A failed unit in a
walk is recorded and the run continues (additive copy is idempotent, so
re-running resumes), ending with an `ok/total` tally and non-zero exit.

### Rename (`mv`)

The cloud is authoritative, so `mv` renames there first (`rclone moveto`, a
server-side move where the backend supports it), then realigns the local copy.
Because names mirror remote and no per-node path is stored, the move recomputes
every descendant's remote for free. It refuses to run from inside the path being
moved (which would leave the shell on a dead directory). Doing the rename locally
and pushing instead would orphan the old path on the cloud, since `push` is
additive.

## Backend agnosticism

ferry runs unchanged on two structurally different remote families — **filesystem-style**
(Filen, SFTP, local, WebDAV: real directories, cheap rename, can hold empty dirs)
and **object stores** (S3, GCS, B2, R2: a flat key space, "directories" are just
key prefixes, no empty dirs, no native rename). It does so **without any
backend-type branch** in the code. Two design choices make that possible:

1. **Structure lives in local markers, never on the cloud.** The root/unit
   topology, the derived paths, and the sync state are all local; `.ferry` markers
   are excluded from every transfer. The cloud is only ever a content store keyed
   by path. `remote_of(dir) = base + path-under-root` **is** a key prefix — which
   is exactly what an object store wants and what a filesystem renders as nested
   dirs. ferry never needs the cloud to model a tree.
2. **Presence is content** — the lowest common denominator both families share.
   An empty directory cannot exist on an object store, so ferry never depends on
   one: `new` does not pre-create a cloud folder (the prefix appears on first
   `push`), and `probe_unit` treats an absent remote prefix as *no cloud content*
   (empty unit → `=`, populated → `>`) rather than as an error. This collapses the
   "empty vs missing directory" ambiguity that object stores cannot answer, so the
   same status logic is correct on both.

Everything else is delegated to rclone, which already abstracts the backends:
`copy`, `sync`, `check`, `lsf`, `moveto`, `purge` all produce identical *results*
on both families. What differs is **cost and recoverability, not behaviour** — and
those are inherent to the backend, deliberately *not* papered over with conditionals:

| Aspect | Filesystem-style | Object store |
|---|---|---|
| `mv` (`rclone moveto`) | O(1) metadata rename | server-side **copy + delete** of every object — O(data), billed, non-atomic |
| `status` / `check` | local I/O | LIST/HEAD requests per unit — metered, latency-bound |
| `new` cloud effect | prefix created lazily on push | identical (prefix on push); an empty folder is simply never represented |
| recovery backstop (`rm`) | native trash / version history | bucket **versioning** must be enabled — no trash concept |
| `rclone check` integrity | hash | hash, but **multipart** objects fall back to size+mtime (ETag ≠ MD5) |

The takeaway: ferry is generic because it leans on the semantics both backends
*share* (a keyed blob store, content = presence) and pushes everything backend-specific
down into rclone or out into operational config (enable bucket versioning) — not
because it detects the backend and adapts. Adding such a branch would be the wrong
move; the genericity is a property of the model, not of special-casing.

## Sync state & prompt indicator

A `git fetch`/`status` against the live cloud is a network round-trip — too slow
and too offline-hostile to run on every shell prompt. So `ferry` replicates the
trick that makes git's prompt fast: it keeps two **local-only** caches, the
direct analogs of git's remote-tracking ref and index stat-cache.

State lives in `${XDG_CACHE_HOME:-~/.cache}/ferry/<unit path under the root>/`,
deliberately **outside** the synced tree (like git's tracking refs in a
local-only `.git`), so it never rides up to the cloud and machines never fight
over it. `mv` carries it to the new path; `drop`/`rm` delete it.

| File | Written by | Read by | Meaning |
|---|---|---|---|
| `synced_at` | `push`/`pull` (`mark_synced`) | the prompt | empty file; its **mtime** is the last sync — the baseline the working tree is compared against |
| `remote` | `status` (`probe_unit`) | the prompt | `sync`/`behind` + timestamp — whether the cloud was ahead at the last check |

The prompt (`__ferry_ps1` in `ferry-prompt.sh`) renders `= > < <> ?` from these:

- **Local side (`>`)** — computed live and offline, no git: one `find` for any
  entry newer than `synced_at`, pruning `.git`/`history.bundle`. A deletion
  bumps its parent directory's mtime, so adds, deletes, renames and edits are
  all caught. This is git's index stat-cache (size+mtime), not content hashing —
  cheap enough per prompt. rclone preserves source mtimes on transfer, so right
  after a push/pull every file is older than the freshly-touched marker → clean
  baseline. `bundle_git` writes `history.bundle` *before* `mark_synced`, so the
  bundle never reads as a pending change.
- **Cloud side (`<`)** — only as fresh as the last `ferry status`, exactly as
  git's `<` is only as fresh as the last `git fetch`. `probe_unit` does a
  one-way `rclone check` (remote → local, ignoring local-only files) to set the
  bit. A bit older than a day is rendered with a trailing `?` so `=` never
  silently claims sync with a cloud that hasn't been checked.

Known trade-offs (deliberate): the size+mtime heuristic over-reports a bare
`touch` that content-hashing would call unchanged (matches git's stat-cache);
and a clean large tree is an O(tree) walk per prompt (no early exit), the same
"big repo, slow prompt" cost git has.

## Presence control

Native to the model: a unit is local because it was pulled or `new`ed. `ferry
drop` deletes the local copy; the cloud keeps it. Dormant projects are simply
never pulled — that is the disk-space control, no extra mechanism. `ferry rm` is
the deliberate exception that also deletes the cloud copy (confirmation-gated,
with the remote's trash as the backstop where available); like `drop` it acts
only on a local unit, and it is kept separate from `drop` so retention and
presence stay distinct.

## Versioning

Default change-tracking is the **remote's own version history + trash** (when the
backend provides them) — automatic, zero ceremony, works on prose and large
binaries alike. Overwrites via `rclone copy` still create server-side versions
where supported. It answers "what did this look like before?" without any
per-project setup.

This is distinct from semantic version control (git), which answers "show me the
deliberate checkpoint where I restructured the argument." Most needs are the
former; git is added only when a project earns it.

## Git (optional, per project)

Add git only when a project has running code, needs branching/revert, or wants a
labeled history. It is **local-only** — there is no networked git remote.

**Rule — never transfer a live `.git/`.** A file transfer can capture `.git`
mid-operation and corrupt the repository. So `.git/` is always excluded
(`rclone … --exclude '.git/**'`), or the project is structured so transfers stay
below the repo.

**Mixed projects (large binaries + versioned text)** — split by subfolder so the
two systems never touch the same bytes:

```
paper/
  refs/   → rclone-synced (large PDFs, read-mostly)
  src/    → git-tracked draft (PDFs .gitignored, .git excluded from rclone)
```

**History snapshots via `ferry push`.** Because `.git` is never transferred,
history needs an explicit trigger. On a git project, `ferry push` packs the full
history into a single file *before* pushing files, so the bundle rides up with
the rest:

```
git bundle create .history.bundle.tmp --all
mv .history.bundle.tmp history.bundle    # atomic rename; never push a partial file
rclone copy <unit dir> remote_of(<unit dir>) --exclude '.git/**' --exclude '.ferry'
```

`history.bundle` is git-ignored (the repo does not track itself). A full `--all`
bundle is used every time: the repo is text-only (PDFs are ignored), so it is
tiny, and this avoids incremental bookkeeping.

This is what makes git compatible with `drop`: since `.git` is local-only,
dropping would otherwise destroy history — but `history.bundle` lives in the
cloud, so history survives `drop` and returns on the next `pull`.

**Restore on pull** (reattach history to the pulled working tree without
overwriting it):

```
git init -q
git fetch history.bundle 'refs/*:refs/*'
git symbolic-ref HEAD refs/heads/main
git reset                                # index ← HEAD; working tree untouched
```

The bundle is "history up to the last `ferry push`"; the working tree is current.
Edits made since the last push show as uncommitted changes — correct, not a loss.

## Credentials & secrets

The remote is configured **in rclone itself**, via `rclone config`, as a named
remote (e.g. `Remote`). rclone stores the backend's credentials in its config
file (`~/.config/rclone/rclone.conf`), obscured.

```sh
rclone config        # interactive: new remote → name it → pick a backend
rclone listremotes   # confirms: Remote:
```

The `ferry` script contains **no credentials and no personal identifiers** — only
the remote name `Remote:Projects`. All authentication is delegated to rclone's
own config, so the script can be published as-is.

**Notes:**

- Protect `rclone.conf`: it holds the obscured secrets. `rclone obscure` is
  reversible and is *not* a security boundary — guard the file with filesystem
  permissions, and optionally an rclone config password
  (`rclone config` → set configuration password) to encrypt the file at rest.
- The agent machine needs its **own** `rclone config` (its own remote).
  Do not copy `rclone.conf` between machines as the sole protection.
- Rotating the backend's credentials requires re-running `rclone config` for
  the remote.

## Publishing the script

The `ferry` script can live in a public repo: it holds no secrets and no personal
identifiers — only the remote name `Remote:Projects`. To keep it that way:

- Never commit `rclone.conf`; it lives outside this tree, under
  `~/.config/rclone/`.
- Never commit real project lists or logs containing client names; project data
  lives under `~/Projects`, a separate tree.

Publishing does disclose the toolchain (rclone) and the remote name —
reconnaissance-level information, not a credential leak.

## Two-machine agent workflow

A second machine (Claude Code agent) fetches and analyzes academic documents;
the primary machine reads the results to draft a paper. A **producer → consumer**
handoff, not concurrent co-editing:

- The agent's job ends with `ferry push` (its results land in the cloud).
- The primary machine runs `ferry pull` when starting to write.

Because pull happens *after* the agent's push completes, the primary always
fetches a complete state — there is no half-synced window to guard against. Use
disjoint subfolders per producer so a later `push` from one side never
overwrites the other's work.

Only the primary machine git-tracks the draft (local-only); the agent machine
does not use git.

## Operational rules

- A **unit** is a leaf **empty** `.ferry`; units form an antichain and there is
  exactly one (content-bearing) root per tree. Discovery is walk-up (root/base) +
  walk-down (`find . -name .ferry -empty`, leaves only) — `-empty` keeps the
  root's content marker from ever being treated as a unit.
- The remote path is **derived** (`base + path-under-root`), stored only at the
  root — never per node.
- Transfers are additive (`rclone copy`) by default; mirroring (`rclone sync`)
  is an explicit per-command opt-in, allowed only on a single unit — never on a
  no-arg walk.
- A no-arg `pull`/`push` walk continues past a failed unit and exits non-zero
  with a tally; re-running resumes (additive copy is idempotent).
- `.git/` and `.ferry` are **always** excluded from transfers (`--exclude`).
- `ferry push` on a git project writes the bundle to a temp name and
  **atomically renames** it before pushing.
- A unit is born from `new` (empty marker written at creation) or `pull`; its
  parent dirs are always markerless grouping dirs, created implicitly. A grouping
  level is never created directly. `new` does not pre-create the cloud folder —
  the prefix appears on first `push` — and requires the cloud path not to exist.
  Browsing an existing cloud folder needs no verb — `list` takes a path and
  `pull` materializes it.
- `ferry drop` and `ferry rm` both act only on a **local unit**; `drop` is
  local-only, `rm` deletes both sides (confirmation-gated). A cloud-only path is
  out of scope — use `rclone`. The remote's version history + trash (where
  available) is the recovery backstop.
- Per-machine sync state lives in `${XDG_CACHE_HOME:-~/.cache}/ferry`, never in the
  synced tree, keyed by unit path; `push`/`pull` re-baseline it, `status`
  refreshes the cloud bit, `mv` carries it, `drop`/`rm` delete it.
