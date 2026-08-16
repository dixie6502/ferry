# ferry

On-demand, **sparse** sync of a remote tree to/from local disk via
[rclone](https://rclone.org) — **backend-agnostic**: any rclone remote, whether
filesystem-style (Filen, SFTP) or an object store (S3, GCS). A single place for
in-progress work that lives **outside GitHub** — no collaboration, sensitive
data, large files welcome, version control optional.

Nothing runs in the background: every transfer is an explicit command. The local
tree is a **partial mirror** of the remote — a directory is present only because
you pulled or created it. Where things live is decided by `.ferry` **marker
files**, not by any fixed folder depth.

```
~/Projects/.ferry            root   → holds the remote base "Remote:Projects"
  CL03-Initech/                      grouping dir — no marker, just on the path
    site/.ferry               unit   ← a transfer unit (empty marker)
    audit/.ferry              unit
  Academic/thesis/refs/.ferry unit   ← any depth, no configuration
```

- **root** — the one directory whose `.ferry` holds the remote base. Found by
  walking **up** from `$PWD`, exactly like git finds `.git`. One per tree.
- **unit** — a leaf (an empty `.ferry`, none below it), present locally because
  you pulled or `new`ed it. The granularity of every transfer, git bundle, and
  sync record.
- Directories **between** root and unit hold no marker. They appear on the way
  down to a unit (a deep `pull`/`new` creates them) and exist only to navigate.

A node's remote path is **derived** — `<base>` + its path under the root — so you
never spell out both sides, and a rename recomputes everything beneath it for free.

## Setup

Requires `bash`, `git`, and `rclone` with a remote configured.

Configure the remote once, in rclone itself:

```sh
rclone config        # new remote → name it (e.g. "Remote") → pick any backend
rclone listremotes   # should print: Remote:
```

Credentials live in rclone's own config (`~/.config/rclone/rclone.conf`); the
`ferry` script holds none. Put `ferry` on your `PATH`, make it executable, then
mark a directory as the root of a tree:

```sh
cd ~/Projects
ferry init Remote:Projects   # writes ~/Projects/.ferry
```

## Usage

```
ferry init <base>       make $PWD a root holding <base> (no nested roots)
ferry list  [<dir>]     list a node's children on the remote (no local dir needed)
ferry status [<dir>]    drift for every unit at/under $PWD (the "fetch")
ferry resolve [<dir>]   stage the cloud side of a conflict, to compare by hand
ferry pull  [<dir>]     materialize a unit; no arg → every unit under $PWD
ferry push  [<dir>]     send a unit up;     no arg → every unit under $PWD
ferry new   <name>      start a brand-new unit (cloud prefix appears on first push)
ferry mv    <old> <new> rename/move a unit or grouping dir (cloud, then local)
ferry drop  [<dir>]     delete a unit locally; the cloud keeps everything
ferry rm    <dir>       delete a unit BOTH sides (confirmation-gated)
```

Most verbs take an optional `<dir>` (relative to `$PWD`); omitted, they act on
`$PWD`. The whole model is two walks: **up** to the root for the base, **down**
to the unit leaves for what to transfer.

### Browse, create & delete

**To browse** an existing cloud folder before pulling, point `list` at its path —
no local directory required: `ferry list CL03-Initech` shows its cloud children.
A deep `ferry pull CL03-Initech/site` then materializes just that one, creating
the intermediate `CL03-Initech/` on the way down.

**`new` creates a unit at birth.** The named folder gets an empty marker (so it
is a unit immediately — `status` sees it, `push` sends it up); any parent dirs
fall out as markerless grouping dirs. You never `new` a grouping level directly —
you `new` the leaf and the dirs above it appear. The cloud side is **not**
pre-created — the prefix materializes on first `push` (an empty folder is anyway
unrepresentable on object stores). `drop` and `rm` both act on a **local unit**
and differ on which side they destroy:

| Verb | on the cloud? | does |
| --- | --- | --- |
| `ferry new <name>`  | must **not** exist | start a brand-new unit; cloud prefix on first push |
| `ferry drop <dir>`  | — | delete the **local** unit; the cloud retains it |
| `ferry rm <dir>`    | — | delete a **unit** both sides (asks first; recovery depends on the remote's trash/versioning) |

**Adopting an existing folder** that already holds files — say one you moved in
from outside the tree — needs no `new`. `push` does not require the remote prefix
to exist (unlike `pull`, which downloads): it `rclone copy`s the files up,
creating the cloud path from scratch, then writes the marker so the folder
becomes a unit. So just move the folder under the root and push it by name:

```sh
mv ~/my-folder ~/Projects/my-folder   # bring it under the root
cd ~/Projects
ferry push my-folder                  # uploads, creates the cloud prefix, marks it a unit
```

Name the folder **explicitly** on this first push — a no-arg `ferry push` walk
only finds existing units (empty markers), so a markerless folder is skipped
until its first push gives it one. (`new` is for brand-new names and refuses a
folder that already exists locally or on the cloud; adoption goes through `push`.)

`new`/`pull <sub>` are refused inside an already-materialized unit. `drop`
(presence control) and `rm` (cloud retention) are deliberately separate verbs.
`rm` refuses anything that is not a local unit — to delete a cloud-only folder,
or a whole grouping subtree, use `rclone` directly.

### No-arg walk & flags

`ferry pull` / `ferry push` with no argument walk **down** from `$PWD` and act on
every unit found. A unit that fails is recorded and the run continues (additive
copy is idempotent, so re-running resumes), ending with an `ok/total` tally.

- `--mirror` — propagate deletions (`rclone sync`) instead of the additive
  default (`rclone copy`). **Single `<dir>` only** — refused on a walk, where an
  interrupted deletion-sync is unsafe.
- `--force` — skip the drift guard below (and the probe it costs).
- `-y` — skip confirmation prompts (`drop`, `rm`).

### Diverged units

`push` and `pull` check drift first and refuse to run when the transfer would
**overwrite** what the other side changed — the same thing git does with a
non-fast-forward push. An `rclone copy` overwrites the far side whenever the two
differ, newer or not, so a pull over an unpushed edit would destroy it.

Only files that exist on *both* sides can be overwritten, so one-sided changes
never stand in the way: deleting a file locally and then pulling just brings it
back, and an unpushed new file is not on the remote at all. `--mirror` is
stricter — it deletes on the far side, so it is refused unless the drift points
its way.

```
$ ferry status CL03-Initech/site
<>  CL03-Initech/site
    both   edit   notes.md
    remote add    refs.bib

$ ferry push CL03-Initech/site
ferry: refusing to push CL03-Initech/site — diverged: both sides changed since the last sync
    notes.md
ferry: inspect it with 'ferry resolve', or override with --force
```

A unit whose cloud side could not be read (`?`) is refused too — an unanswered
question is not a green light. On a no-arg walk the blocked unit is tallied as a
failure and the others still transfer.

`ferry resolve` then puts the cloud's version of each conflicting file where you
can diff it — **outside** the unit, in ferry's own state dir, so it never rides
back up and `drop`/`rm` take it away with the unit:

```
$ ferry resolve CL03-Initech/site
ferry: the cloud version of 2 file(s) is in
  ~/.cache/ferry/<remote>/CL03-Initech/site/conflict
    notes.md   (changed on both sides)
    refs.bib   (added on the cloud)
ferry: reconcile in place, then 'ferry push --force' to publish your result
```

It stages everything the cloud touched, not just the files both sides changed —
the ones only *you* changed are already in hand. ferry does **not** merge: it has
no third version to merge against, so it makes the other one available and leaves
the choice to you. The final `push` needs `--force`, because a merged file
matches neither side and the guard still sees a conflict until you say so. On a git unit it goes one
step further: the cloud's `history.bundle` is staged too, and the two histories
do share a merge base, so the printed `git fetch` gives you the other side as
branches to merge normally.

### Example

```sh
cd ~/Projects
ferry init Remote:Projects          # one-time: mark the tree root

ferry list                          # clients on the cloud
ferry list CL03-Initech             # browse a client's projects — no local dir needed
ferry pull CL03-Initech/site        # materialize just this one (creates CL03-Initech/)

cd CL03-Initech/site
# ... work on it ...
ferry push                          # $PWD is a unit → send it up

ferry new ../audit                  # brand-new unit (cloud prefix appears on first push)
# ... add files ...
ferry push ../audit                 # send the new unit's files up (materializes it on the cloud)

cd ~/Projects && ferry status       # drift for every unit under here:
                                    #   >   CL03-Initech/audit   (local edits to push)
                                    #   <   Academic/thesis/refs (cloud changes to pull)
ferry push                          # walk: push every local unit under here

cd ~                                # mv/rm won't run from inside the target
ferry drop CL03-Initech/site        # free local disk; cloud keeps it
ferry mv CL03-Initech CL03-Init     # rename a grouping dir (cloud, then local)
```

## Shell completion

`ferry` self-emits a bash completion script — install it by evaluating the
output of `ferry completion bash` from your shell rc (the `fzf --bash` model):

```sh
# ~/.bashrc
eval "$(ferry completion bash)"
```

It completes verbs, each verb's accepted flags (`--mirror` on `pull`/`push`,
`-y`/`--yes` on `drop`/`rm`), and directory arguments. Only bash is supported.

## Prompt indicator

`ferry-prompt.sh` adds a git-prompt-style drift indicator to your shell prompt,
fed by the per-machine sync state `ferry` records under
`${XDG_CACHE_HOME:-~/.cache}/ferry`:

```
=   in sync                                   >   local edits not yet pushed
<   cloud has changes you haven't pulled      <>  diverged (both changed)
?   never synced from this machine
```

Enable (bash):

```sh
source ~/.ferry-prompt.sh
PS1='\u@\h \W$(__ferry_ps1 " [%s]")\$ '
```

Like `ferry` itself, it walks **up** from `$PWD` to the enclosing unit — no fixed
depth. The local side (`>`) is computed offline on every prompt with a single
`find` since the last sync; the cloud side (`<`) is only as fresh as your last
`ferry status`, and gets a trailing `?` once that bit is over a day old.

## How it works

- **Additive by default** — `copy` never deletes the far side. Deletions
  propagate only with `--mirror` (`rclone sync`).
- **Presence = pulled or created** — a unit is local because you pulled it or
  `new`ed it. `drop` frees disk; the cloud is authoritative for retention (`rm`,
  which acts only on a local unit, is the explicit exception).
- **Derived paths, one root** — the remote base is stored once, at the root;
  every other path is computed from structure. Units form an antichain (no unit
  under another) and there is exactly one root per tree.
- **Rename cloud-first** — `mv` renames on the cloud (authoritative) then realigns
  local, and refuses to run from inside the path being moved.
- **Versioning** — the remote's own version history + trash (if it has them) is
  the recovery backstop; no per-project setup.
- **Git is optional, per unit** — `.git/` is never transferred. On a git unit,
  `push` bundles full history into `history.bundle` (which rides up with the
  files), and `pull` reattaches it to the working tree.
- **Backend-agnostic** — the tree lives in local markers (never transferred) and
  every cloud action is delegated to rclone, so the same commands behave the same
  on filesystem-style and object-store remotes. Nothing relies on cloud
  directories existing: presence is content. See
  [ARCHITECTURE.md](ARCHITECTURE.md#backend-agnosticism) for the details and the
  cost differences that remain (`mv`, `status`, recovery).

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design rationale.

## ToDo before going public
- [x] Bash shell completion (`ferry completion bash`)
- [ ] Review all code
- [ ] Optional flag for the rclone remote with a global env variable for a
  default (the remote is currently single-sourced from the root `.ferry`)
- [ ] Clean Readme
- [ ] Better the tree structure (graph) of root and unit. Use
  better terms, graph theory based if relevant
- [ ] Find a nice ascii draw of a ferry!
