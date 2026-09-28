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
| **`ferry`** | Thin shell wrapper over rclone. Markers (`.ferry`) select a sparse local mirror; verbs pull/push units, manage tree structure, and snapshot git history. Also self-emits its bash completion (`ferry completion bash`). |
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

**Transfers compare by checksum** (`--checksum`, whenever the remote maintains
hashes): rclone's default skip rule is size+modtime, under which a same-size
preserved-mtime edit stays untransferred — while `mark_synced` would record its
hash as the shared ancestor over content that never crossed, arming a later
guard-approved transfer to overwrite the unseen edit. With `--checksum`,
"skipped" means "identical", which is exactly what the manifest records.

## `ferry` verbs

The whole model is two tree walks: **up** to the root for the base, **down** to
the unit leaves (`find . -name .ferry -empty`, keep the leaves) for what to
transfer. That replaces all depth/scope arithmetic — a unit is wherever an empty
leaf marker sits.

| Verb | rclone mapping | Purpose |
|---|---|---|
| `ferry init <base>` | — (writes `.ferry`) | Make `$PWD` a root holding `<base>`. Refused inside an existing tree (no nested roots). |
| `ferry list [<dir>]` | `rclone lsf --dirs-only --format tp` of `remote_of(dir)` | Remote children of a node (or the root); modtime + name, sorted by name. |
| `ferry status [<dir>]` | one `rclone check --combined` + one listing (`rclone lsf --format tp`) per unit, plus `rclone hashsum` of only the differing files, or none of it if the remote prefix is absent (`probe_unit`) | Drift for **every** unit at/under `$PWD`, one `= / > / < / <>` row each; for a single unit, also the per-file `local / remote / both` classification (see [Drift classification](#drift-classification)). Refreshes each unit's prompt cloud bit (see [Sync state](#sync-state--prompt-indicator)). |
| `ferry pull [<dir>]` | guard, then `rclone copy remote_of→local`, write marker | Materialize a unit (recursive). Deep `pull a/b` auto-creates parent grouping dirs. No arg → walk units under `$PWD`. Refused on a diverged unit (see [Transfer guard](#transfer-guard)). |
| `ferry push [<dir>]` | guard, bundle git, then `rclone copy local→remote`, write marker | Send a unit up; confers unit status on a fresh dir. No arg → walk units under `$PWD`. Refused on a diverged unit (see [Transfer guard](#transfer-guard)). |
| `ferry resolve [<dir>]` | `rclone copy --files-from` of the conflicting paths into the unit's state dir | Stage the cloud side of a `<>` so it can be compared with ordinary tools. Never merges, never writes into the unit (see [Transfer guard](#transfer-guard)). |
| `ferry sync [<dir>]` | probe, then two `rclone copy --files-from-raw` runs (one per direction) | Converge a unit with the cloud in one run: each side's changes cross to the other, conflicts stay put. No arg → walk units under `$PWD` (see [Converging](#converging-sync)). |
| `ferry mv <old> <new>` | `rclone moveto`, then `mv` local | Rename/move a unit or grouping dir, cloud-first. |
| `ferry completion bash` | — (prints to stdout) | Emit a bash completion script; install with `eval "$(ferry completion bash)"`. Needs no tree or rclone. |

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

**Hashes can cost a request each.** A backend may leave a file's hash out of a
directory listing and look it up per file when asked — Filen does, and a file
uploaded there without rclone has no hash to find at all. Two generic rules keep
that off the critical path, with no backend branch: every call runs with
`--fast-list` (one recursive listing, which does carry hashes, where the backend
has one; rclone otherwise lists per directory whenever a directory exclusion such
as `.git/**` is in play), and hashes are read with `rclone hashsum` — parallel —
never with a hash-carrying `lsf`, which asks one file at a time. Drift checks
read only the flagged files' hashes; a manifest still needs every file's, so a
unit full of hashless files stays slow to sync, and says so with a running count.

## Ignore rules

`.ferryignore` keeps files out of a unit — the general form of the `.git`/`.ferry`
exclusions every transfer already carries. One file may sit at the **tree root**
(rules for every unit) and one in **each unit**; both are read *relative to the
unit*, so a rule written at the root anchors at each unit's own top. A unit's file
extends the root's rather than replacing it. The unit-level file is ordinary
content and rides up with the unit; the root-level one sits outside every unit and
stays local, like the root `.ferry` itself.

**One rule set, every reader.** The design constraint is not the file format — it
is that six consumers must agree on what a unit contains: `rclone copy`/`sync`,
`rclone check`, the remote `lsf` listing, the local `find` walk, the manifest
built from those two listings, and `ferry-prompt.sh`. An exclusion that reached
one and not the others would leave a file permanently drifted: a stuck `>` in the
prompt, a `remote add` that no transfer can ever clear. So `load_ignore` compiles
each unit's rules **once**, into the two forms every consumer needs —
`UNIT_EXCLUDE` (rclone filter flags) and `UNIT_PRUNE` (`find` predicates) — and
nothing reads the base arrays directly. `--files-from-raw` is the one transfer
that carries no filters (rclone refuses to combine them); it is safe because its
path list comes from a classification that already ran under `UNIT_EXCLUDE`.

**Not `.gitignore`.** Two reasons, either sufficient:

- *Different question.* "Do not version-control this" is not "do not back this
  up". ferry exists for exactly the large and private files git is told to skip —
  the [mixed-project layout](#git-optional-per-project) below has PDFs
  `.gitignore`d and rclone-synced on purpose. Worse, `bundle_git` appends
  `history.bundle` to `.gitignore` itself, so honouring it by default would
  silently stop backing up git history — and `drop` would then destroy it.
- *Different syntax.* rclone filters are not gitignore: `build/` ≠ `build/**`,
  `!` re-inclusion has no `--exclude` equivalent, and gitignore is last-match-wins
  across nested per-directory files where rclone is a flat root-relative list.
  Honouring it correctly means writing a translator; honouring it approximately
  means silently syncing — or not syncing — the wrong files.

A tree may opt in by hand (`cat .gitignore >> .ferryignore`), which is explicit
and reviewable, and fails loudly on any pattern the grammar does not cover.

**The grammar is the intersection of `find` and rclone**, deliberately, because
both must apply it. Blank lines and `#` comments are skipped; everything else is
one of:

| Pattern | Matches | rclone | `find` |
|---|---|---|---|
| `name` | a file or directory `name`, any depth | `--exclude name` + `name/**` | `-name name -prune` |
| `name/` | a directory `name`, any depth | `--exclude 'name/**'` | `-name name -type d -prune` |
| `*.ext` | a glob (`*`, `?`, `[…]`) over a name, any depth | `--exclude '*.ext'` | `-name '*.ext' -prune` |
| `/a/b`, `/a/b/` | a literal path from the unit's top | `--exclude /a/b` (+ `/**`) | `-path <unit>/a/b -prune` |

Everything else is a **fatal** error, not a skipped line: `!` re-inclusion, `**`
(a bare name already matches at any depth), an unanchored `a/b` (gitignore anchors
it, rclone does not — write `/a/b`), and a glob inside an anchored pattern
(`find -path` lets `*` cross a `/`, rclone does not, so the two would mean
different things). Continuing past a malformed rule would transfer files the user
asked to keep out; failing the run is the cheap, loud alternative.

**Ignoring is not deleting.** A rule removes a path from ferry's view on *both*
sides. Filters apply to the destination listing too, so `--mirror` will not delete
an already-uploaded copy; the path simply leaves manifest membership at the next
successful sync. Dropping a rule hands the file back — it reappears as an ordinary
`remote add`.

**The prompt keeps its own copy of the compiler.** `ferry-prompt.sh` must stay a
single offline `find` with no `ferry` process per prompt, so it re-implements the
same restricted grammar (skipping, rather than reporting, a line it cannot
compile — a prompt must never fail loudly). The alternative — the prompt ignoring
the rules — is exactly the stuck `>` this section exists to prevent. The grammar
is small enough that the two copies are checkable against each other; the `ignore`
suite asserts they agree.

**Known limit — a pruned entry still stamps its parent.** The prompt's local half
is mtime-only, and it reads a directory's mtime as evidence of a deletion it
cannot otherwise see. Creating or removing an ignored file bumps its parent
directory, so the prompt may show `>` on a unit `ferry status` calls `=`, until
the next sync re-baselines it. This is the same over-report a bare `touch` already
produces, in the same conservative direction, and it does not arise for writes
*within* an ignored directory (the directory itself is pruned) — which is the
reason to prefer `build/` over a glob scattered at the unit's top.

## Drift classification

`status` reports drift as `= > < <>`, and the direction has to be **earned**: a
content diff alone cannot produce it. Two checks of local against cloud share no
common ancestor, so they cannot distinguish "I changed it" from "we both changed
it" — a plain modification fails a check in *both* directions and reads as
divergence. That made `<>` fire on the ordinary edit-then-push cycle, which is
precisely the state it is supposed to warn about.

Direction is therefore taken **relative to the last sync** — the role git's
merge base plays. The manifest records that sync's ancestors: every path the
two sides shared, with its content hash at that moment (`#ferry v2 <hashtype>`
header, then `<hash> <path>` lines, hashed with the remote's preferred
algorithm as rclone reports it — blake3 on Filen, md5 on Drive or S3-alikes).
A side changed a file iff its current hash differs from the recorded ancestor.
Mtimes carry no weight here, which makes the attribution immune to the lies
transfers preserve: a file edited on another machine before our baseline and
pushed after it arrives with a pre-baseline mtime, yet its hash still differs
from the ancestor — a cloud change, not silence.

`classify_unit` runs one content check (*which* files differ: `rclone check
--combined`) and one remote listing (`rclone lsf --format tp`: each cloud
file's mtime), reads the current hash of the flagged files on each side
(`rclone hashsum --files-from-raw` over only those — never the whole unit),
then labels each differing file:

| `rclone check --combined` | changed here | changed there | class |
|---|---|---|---|
| `*` on both sides, differ | ✓ | ✓ | `both` |
| `*` | ✓ | — | `local` |
| `*` | — | ✓ | `remote` |
| `*` | — | — | `both` (unattributable) |
| `!` unreadable | — | — | `both` (what is unknown blocks) |

**Fallback.** Where a hash is missing — a manifest written before hashes
existed (v1: bare paths, no header), or an entry the backend holds no hash for
(e.g. multipart objects whose ETag is no MD5) — "changed" falls back to that
side's mtime relative to the baseline (`synced_at`). rclone preserves source
mtimes on transfer, so right after a sync both sides predate the baseline and
only later writes stand out. The fallback inherits the trade-offs the hashes
remove: a preserved-mtime edit (`cp -p`, a late push from another machine) is
attributed conservatively or not at all, and clock skew between machines can
misread direction. A v1 manifest therefore degrades rather than breaks —
membership attribution stays exact, content attribution turns heuristic, and
the next push/pull rewrites it as v2.

Every line also carries a **shape** — `edit` for a file present on both sides,
`add` or `delete` for one present on a single side. The side says whose change it
is; the shape says what a transfer could do to it, which is what the
[transfer guard](#transfer-guard) acts on.

A file present on only one side is not a content question alone — whether it
*left* one side or *arrived* on the other is invisible in anything the
surviving copy carries — so presence is answered from the **manifest's
membership**, the set of paths present on both sides at the last sync:

| `rclone check --combined` | in the manifest | class |
|---|---|---|
| `+` only local | — | `local` (not shared last sync: added here, or never pushed) |
| `+` | ✓, and changed here | `both` (edited here, dropped there) |
| `+` | ✓ | `remote` (the cloud dropped it) |
| `-` only on the cloud | — | `remote` (never here: it arrived there) |
| `-` | ✓, and changed there | `both` (deleted here, changed there) |
| `-` | ✓ | `local` (deleted here) |

Both one-sided branches also ask whether the surviving copy changed since the
sync (its hash against the ancestor's, with the same mtime fallback), and for
the same reason: a file the far side dropped *and* this side edited is a
conflict, not a clean deletion, and letting it read as a plain one-way change
is enough for a `--mirror` in that direction to erase the surviving edit.

Guessing presence from mtimes instead is what makes a file pushed late from
another machine (created Monday, pushed Friday, our baseline Wednesday) look
like a local deletion — and `--mirror` would then delete it from the cloud. A
directory's mtime is no substitute: it is stamped by *any* add or remove, so
one unrelated local file forges the verdict for every remote-only file beside
it, and a directory deleted wholesale leaves no stamp to read at all.

Which side the manifest is read from follows from the transfer, and reading the
wrong one would over-count files the other side never had: an additive `push`
leaves local ⊆ cloud, so the local file list *is* the intersection; an additive
`pull` leaves cloud ⊆ local, so the cloud listing is.

**When** it is read matters as much as which side. The manifest's paths are
captured *before* the transfer and installed only once it succeeds: taken
afterwards they would enrol a file written during the transfer, which never
crossed. The hashes come from the remote's metadata (`rclone hashsum`, which
looks them up in parallel), never from local content: a `pull` reads them
beside the listing that supplies the paths, and a `push` reads them *after*
the transfer — every pre-listed path then holds the pushed content on both
sides, so no local file is ever hashed at sync time. The
baseline is stamped at completion, because the sync's own writes land after the
start — the marker, a restored `.git`, and, on a backend that cannot set a
destination modtime, the transferred objects themselves — and would otherwise
read as post-sync changes in the mtime fallback (`status` would say `<>` and
the prompt `>` on a tree that had just synced cleanly). A side that cannot be
listed fails the transfer rather than recording an empty ancestor set, which
would silently invert every later deletion into "added on the other side".

"Not in the manifest" means *not shared at the last sync* — which covers a file
added here, one never pushed, and one the far side had already removed. It does
not mean "new". That is why an additive `pull` after a cloud-side deletion leaves
the local copy classified `local`: a plain `pull` never deletes locally, so the
file legitimately survives and a later `push` restores it. Accepting a deletion
is what `--mirror` is for.

`drift_symbol` folds the classes into the unit's symbol — any `local` sets `>`,
any `remote` sets `<`, a `both` sets either half. So `<>` now means what it says,
and is rare enough to be worth blocking a transfer on (see
[Transfer guard](#transfer-guard)).

Cost is unchanged: the two one-way checks became one bidirectional check plus one
listing. Two cases short-circuit before any comparison — an absent remote prefix
(nothing on the cloud: `>` if the unit holds files, else `=`) and a missing
baseline (never synced from this machine: `<` if there is nothing local to lose,
else `<>`, since direction is unknowable).

A probe that cannot read the cloud reports **`?`**, never a symbol. `rclone check`
exits 1 both for "differences found" and for trouble, and downgrades a directory
it could not list to a stderr tally *while still reporting that whole subtree as
missing on the far side* — a forged presence change. Its error counter tallies
each difference plus each real failure, so an excess over the difference count is
the signal that something went unread. A summary those counters cannot be
parsed from is itself treated as trouble — the gate fails closed rather than
letting a reworded rclone message silently disarm it. On `?` the stored bit and
its timestamp are left alone, so the prompt's staleness marker does its job
instead of a fresh `sync` being written over an unanswered question.

Deliberate limits: a file that differs while *neither* side's hash differs from
the ancestor cannot happen honestly, so it is reported `both` rather than
guessed. The mtime fallback keeps its own precision rule: the cutoff carries
nanoseconds (`lsf --time-format max`), because truncated to the second it would
catch files written *during* the sync that set the baseline and report them as
cloud changes. And because plain `copy` never propagates deletions, a deleted
file keeps its side marked drifted until a `--mirror` run reconciles it — the
sides genuinely differ, and saying so is correct even though a plain `push`
cannot clear it.

## Transfer guard

Making `<>` truthful is what makes it worth acting on. `push`/`pull` probe the
unit first and refuse to run when the transfer would overwrite what the other
side changed since the last sync — git refusing a non-fast-forward push, with
`--force` as the same escape hatch. Without step one this would have been
unusable: the old `<>` fired on every ordinary edit, so the guard would have
blocked nearly every push.

What a transfer can destroy depends on the mode, so the rule does too. A plain
`rclone copy` overwrites the destination whenever the two differ — newer or not —
but it only ever touches a file that exists on **both** sides. A file added or
deleted on one side is beyond its reach: pulling with a locally deleted file
simply brings the file back, and an unpushed new file is not on the remote to be
overwritten. `--mirror` also *deletes* on the far side, so for it every far-side
change counts and the transfer must run with the drift.

| Far-side change | `push` / `pull` | `--mirror` |
|---|---|---|
| `edit` (on both sides, differing) | refused | refused |
| `add` (one side only) | allowed | refused |
| `delete` (one side only) | allowed | refused |
| `?` unknown, or `<>` with no detail | refused | refused |

"Far side" is the one being written over: the cloud for a `push`, local for a
`pull`. This is why the guard needs the **shape** of each difference and not just
its side — blocking a pull because a file was deleted locally protects nothing
and makes the common case (delete some noise, pull) need `--force`.

The gate cannot substitute for correct presence attribution: a misread one-sided
file *sets* the direction it would then be checked against, which is why that
answer comes from the manifest rather than from a heuristic.

### Resolving

A blocked transfer needs a way forward, and it is deliberately not a merge
engine: ferry has no third version to merge against, the tool is single-user, and
where a real merge base exists (a git unit) git already provides one. `resolve`
therefore **surfaces** rather than reconciles — it copies the cloud's version of
each conflicting file into `<state>/<unit>/conflict/` and stops there.

Staging outside the unit is what makes this safe: the copy is not in the tree, so
it cannot ride up on the next push, and `drop`/`rm` remove it with the unit's
state for free. It is rebuilt from scratch on each run, so a stale file from an
earlier conflict never lingers.

It stages **everything the cloud touched** — classes `both` and `remote` — not
only the files both sides changed. Files only you changed need no staging: your
copy is already the one in hand. This also covers the git bundle without a
special case, which matters because `push` is what rewrites the local bundle and
push is precisely what the guard blocks, so a diverged history nearly always
looks one-sided. The bundle shares a merge base with the local history, so the
`git fetch` that `resolve` prints turns the conflict into an ordinary git merge.

rclone reports "nothing to transfer" as success, so what actually landed is read
back from the staging directory rather than trusted from an exit status — a path
attributed to a cloud-side deletion is not there to stage, and saying otherwise
would point the user at a file that does not exist.

The closing advice is `push --force`, not `push`: a merged file matches neither
side, so the guard still sees a conflict. Forcing is the point — the user has now
looked at both. Advising `pull --force` first would be wrong, because `transfer`
is a plain `rclone copy` that overwrites on any difference regardless of which
side is newer, and would revert the local edits it was meant to preserve.

The guard runs in `pull_unit`/`push_unit` rather than in the verbs, so a walk
tallies a blocked unit as a failure and carries on to the rest instead of
aborting. It costs one probe per unit, which is why `--force` skips the probe as
well as the block. `drop` uses the same classifier for its unpushed-changes
warning: with two one-way checks it warned about a file changed *on the cloud*.

## Converging (`sync`)

`sync` is the daily verb: direction comes from the
[classification](#drift-classification), not from the user, so "make this
machine and the cloud agree" is one command instead of a `status`-read-symbol-
type-matching-verb round trip. Per unit it probes, partitions the drift, and
runs at most two `rclone copy --files-from-raw` transfers — `local` changes up,
`remote` changes down:

| classified | shape | direction |
|---|---|---|
| `local` | edit / add | up |
| `remote` | edit / add | down |
| `local` | delete (deleted here) | down — restored from the cloud |
| `remote` | delete (dropped there) | up — restored to the cloud |
| `both` | any | **neither** — left in place for `resolve` |

**Sync converges to the union.** It is additive both ways: a deletion on one
side is restored from the other, never propagated — `push --mirror` /
`pull --mirror` remain the only deletion paths, exactly as for the directional
verbs. A conflict blocks only itself: everything safe crosses, the unit exits
non-zero, and the conflicted paths are listed with a pointer at `resolve`.

Re-baselining with conflicts outstanding needs care in both directions. The
new manifest is the post-sync remote listing intersected with the pre-transfer
local paths (plus what came down), so a file that landed on either side *during*
the sync never enrols as shared. Conflicted paths keep their **previous**
ancestor line instead of the cloud's current hash — both sides still differ
from it, so they keep reading `both` across syncs and `resolve` keeps working —
and the prompt bit is left at `diverged`, not `sync`. Conversely, a sync that
finds content already equal still refreshes the sync point: after a conflict
reconciled by hand the ancestors are stale, and the next edit would read `both`
against them.

Two cases delegate: no cloud prefix yet → first `push`; nothing local to lose →
plain `pull`. A unit never synced from this machine is refused with the same
guidance as the guard — direction is unknowable, choose a side with
`push --force`/`pull --force`. `sync` accepts neither `--mirror` (it has no
side to delete on) nor `--force` (no side to prefer); after a hand merge the
published escape remains `push --force`.

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
| `synced_at` | `push`/`pull` (`mark_synced`) | the prompt | empty file; its **mtime** is the last sync — the baseline both sides are compared against |
| `manifest` | `push`/`pull` (`mark_synced`) | `status` | the paths present on **both** sides at that sync, with their content hash (`#ferry v2 <hashtype>` header) — the ancestor set that attributes one-sided files by membership and edits by hash (see [Drift classification](#drift-classification)) |

The key is `<remote base>/<unit path under the root>`, not the unit path alone:
two trees on one machine can hold the same unit name against different remotes,
and a shared key would let one tree's manifest and baseline answer the other's
questions — with `--mirror` acting on the answer. The base is **percent-encoded**
rather than squashed with a character substitution, which would not be injective:
`:local:/x/a_b` and `:local:/x/a/b` would land on one directory and the two trees
would silently share state. `ferry-prompt.sh` derives the same key, so the two
stay in step.
| `remote` | `status` (`probe_unit`) | the prompt | `sync`/`behind`/`diverged` + timestamp — how the cloud stood at the last check |

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
  git's `<` is only as fresh as the last `git fetch`. `probe_unit` sets the bit
  from its [classification](#drift-classification): `behind` when any file
  changed on the cloud side. A bit older than a day is rendered with a trailing
  `?` so `=` never silently claims sync with a cloud that hasn't been checked.

The prompt's own formula did not have to change: it ANDs its live local bit with
the stored cloud bit, which was always right — it was fed a wrong cloud bit, one
that also went `behind` for files *this* machine had edited. It does render the
symbol itself (the `= > < <>` table is deliberately duplicated, since the file is
sourced standalone, like `git-prompt.sh`), and it prunes `history.bundle` from
its local walk where `ferry` does not: the bundle is real transferred content and
belongs in a content diff, but a rebuild between syncs would show as a bare mtime
change the prompt cannot tell from an edit.

`diverged` is stored rather than folded into `behind` because the prompt's local
half is mtime-only. A conflict `status` found by content — including the
conservative `both` cases, unreadable files and clock skew — would otherwise be
downgraded to `<` on the surface the user reads all day, so a stored `diverged`
forces both halves.

Known trade-offs (deliberate): the size+mtime heuristic over-reports a bare
`touch` that content-hashing would call unchanged (matches git's stat-cache);
and a clean large tree is an O(tree) walk per prompt (no early exit), the same
"big repo, slow prompt" cost git has.

### Known limits

- **Newlines in filenames.** The manifest, the classification, and `rclone
  check --combined` itself are all line-based, so a filename containing a newline
  is split into two entries and can be attributed to the wrong side. Every other
  awkward character — spaces, leading spaces, `#`, `;`, tabs, `*` — round-trips.
- **Upgrading an existing tree.** A unit synced before the manifest existed has a
  baseline but no manifest, so it reads `<>` and refuses transfers until one
  `push --force`/`pull --force` re-establishes the sync point. A v1 manifest
  (paths without hashes) needs nothing: it degrades to mtime attribution and the
  next sync rewrites it as v2. The state directory is a cache; nothing in the
  tree or on the cloud is affected.
- **An unreadable parent.** rclone reports a path behind an unreadable parent
  with the same code as a path that is not there, so those two stay conflated and
  such a unit reads as "nothing on the cloud" rather than `?`.

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
  no-arg walk. `ferry sync` converges both directions additively (toward the
  union); it never propagates deletions and takes no `--mirror`/`--force`.
- A no-arg `pull`/`push` walk continues past a failed unit and exits non-zero
  with a tally; re-running resumes (additive copy is idempotent).
- `.git/` and `.ferry` are **always** excluded from transfers (`--exclude`);
  `.ferryignore` extends that per tree and per unit, and what it excludes is
  excluded from drift too — one compiled rule set, every reader.
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
