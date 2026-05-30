# ferry

On-demand, **sparse** sync of a remote tree to/from local disk via
[rclone](https://rclone.org) — built for [Filen](https://filen.io) but backend
-agnostic. A single place for in-progress work that lives **outside GitHub** —
no collaboration, sensitive data, large files welcome, version control optional.

Nothing runs in the background: every transfer is an explicit command. The local
tree is a **partial mirror** of the remote — a directory is present only because
you pulled it. Where things live is decided by `.ferry` **marker files**, not by
any fixed folder depth.

```
~/Projects/.ferry            root   → holds the remote base "FilenRemote:Projects"
  CL03-Initech/               stub   (a grouping dir — no marker)
    site/.ferry               unit   ← a transfer unit (empty marker)
    audit/.ferry              unit
  Academic/thesis/refs/.ferry unit   ← any depth, no configuration
```

- **root** — the one directory whose `.ferry` holds the remote base. Found by
  walking **up** from `$PWD`, exactly like git finds `.git`. One per tree.
- **stub** — a bare grouping directory. Exists only to navigate into.
- **unit** — a materialized leaf (an empty `.ferry`, none below it). The
  granularity of every transfer, git bundle, and sync record.

A node's remote path is **derived** — `<base>` + its path under the root — so you
never spell out both sides, and a rename recomputes everything beneath it for free.

## Setup

Requires `bash`, `git`, `jq`, and `rclone` (v1.73+, native `filen` backend).

Configure the remote once, in rclone itself:

```sh
rclone config        # new remote → name it "FilenRemote" → type "filen"
rclone listremotes   # should print: FilenRemote:
```

Credentials live in rclone's own config (`~/.config/rclone/rclone.conf`); the
`ferry` script holds none. Put `ferry` on your `PATH`, make it executable, then
mark a directory as the root of a tree:

```sh
cd ~/Projects
ferry init FilenRemote:Projects   # writes ~/Projects/.ferry
```

## Usage

```
ferry init <base>       make $PWD a root holding <base> (no nested roots)
ferry list  [<dir>]     list a node's children on the remote
ferry status [<dir>]    show drift for the unit at/above $PWD (the "fetch")
ferry pull  [<dir>]     materialize a unit; no arg → every unit under $PWD
ferry push  [<dir>]     send a unit up;     no arg → every unit under $PWD
ferry stub  <name>      mirror an existing cloud folder as an empty local shell
ferry new   <name>      create a brand-new folder, both sides
ferry mv    <old> <new> rename/move a stub or unit (cloud, then local)
ferry drop  [<dir>]     delete the local copy; the cloud keeps everything
ferry rm    <dir>       delete BOTH sides (confirmation-gated)
```

Most verbs take an optional `<dir>` (relative to `$PWD`); omitted, they act on
`$PWD`. The whole model is two walks: **up** to the root for the base, **down**
to the unit leaves for what to transfer.

### Create & delete — by cloud precondition

**Creating a folder never marks it.** `stub` and `new` both leave a markerless
grouping dir; a folder becomes a *unit* only when content first flows through it
(`pull`/`push`). The two creation verbs differ on whether the folder already
exists on the cloud; the two delete verbs differ on which side they destroy:

| Verb | on the cloud? | does |
| --- | --- | --- |
| `ferry stub <name>` | **must exist** (errors otherwise) | mirror it locally as an empty shell — "browse, then pull" |
| `ferry new <name>`  | must **not** exist | create it fresh, both sides |
| `ferry drop <dir>`  | — | delete **local only**; the cloud retains it |
| `ferry rm <dir>`    | — | delete **both sides** (asks first; Filen trash is the backstop) |

`stub`/`new`/`pull <sub>` are refused inside an already-materialized unit. `drop`
(presence control) and `rm` (cloud retention) are deliberately separate verbs.

### No-arg walk & flags

`ferry pull` / `ferry push` with no argument walk **down** from `$PWD` and act on
every unit found. A unit that fails is recorded and the run continues (additive
copy is idempotent, so re-running resumes), ending with an `ok/total` tally.

- `--mirror` — propagate deletions (`rclone sync`) instead of the additive
  default (`rclone copy`). **Single `<dir>` only** — refused on a walk, where an
  interrupted deletion-sync is unsafe.
- `-y` — skip confirmation prompts (`drop`, `rm`).

### Example

```sh
cd ~/Projects
ferry init FilenRemote:Projects     # one-time: mark the tree root

ferry list                          # clients on the cloud
ferry stub CL03-Initech             # empty local shell of an existing client
cd CL03-Initech
ferry list                          # its projects on the cloud
ferry pull site                     # materialize just this one → CL03-Initech/site

cd site
# ... work on it ...
ferry push                          # $PWD is a unit → send it up
ferry status                        # drift vs the cloud

ferry new audit                     # brand-new folder (created on the cloud too)
# ... add files ...
ferry push audit                    # first push confers unit status

cd ~/Projects && ferry push         # walk: push every local unit under here

cd ~                                # mv/rm won't run from inside the target
ferry drop CL03-Initech/site        # free local disk; cloud keeps it
ferry mv CL03-Initech CL03-Init     # rename a stub (cloud, then local)
```

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
- **Presence = pulled** — a unit is local iff you pulled it. `drop` frees disk;
  the cloud is authoritative for retention (`rm` is the explicit exception).
- **Derived paths, one root** — the remote base is stored once, at the root;
  every other path is computed from structure. Units form an antichain (no unit
  under another) and there is exactly one root per tree.
- **Rename cloud-first** — `mv` renames on the cloud (authoritative) then realigns
  local, and refuses to run from inside the path being moved.
- **Versioning** — Filen's built-in version history + trash is the recovery
  backstop; no per-project setup.
- **Git is optional, per unit** — `.git/` is never transferred. On a git unit,
  `push` bundles full history into `history.bundle` (which rides up with the
  files), and `pull` reattaches it to the working tree.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design rationale.

## ToDo before going public
- [ ] Review all code
- [ ] Remove filen references, use a flag for rclone remote with
  a global env variable for a default
- [ ] Clean Readme
- [ ] Better the tree structure (graph) of root, stub and unit. Use
  better terms, graph theory based if relevant
- [ ] Find a nice ascii draw of a ferry!
