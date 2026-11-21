# box

**Headless, trust-less, throwaway dev VMs.** One command mints a fresh,
network-isolated Incus box. **box provisions and manages VMs, and it does not
converge them** ([#214](https://github.com/heavy-duty/box/issues/214)): every
box comes up blank — one thin tenant seed, an unprivileged user, nobody home —
and what it becomes is installed inside it, by you, afterwards. The box is the
product — you log in and work; destroying it loses nothing you didn't push.

**Strictly creds-free.** A box ships with a thin seed and **no** credentials —
no agent token, no git PAT, nothing. What converges it is yours to run, and you
authenticate interactively _inside_ the box. The tool never stores or injects a
secret. That
means there's nothing shared or committed, so it's safe for multiple operators
out of the box.

**Sizes say what a box gets.** `--size small|medium|large` is a resource
bundle and explicit resource flags win. The network and every security flag
live in a shared profile neither can touch, so a blank box has nobody home —
not a box with the safety off.

**The tool knows nothing about your projects.** You just `git clone` inside a
box. A repo can ship an optional [`.box/`](docs/box-recipe.md)
runbook that the coding agent you converged onto the box reads and acts on —
there is no `install` step and no host-run setup. See
[docs/box-design.md](docs/box-design.md) for the design rationale.

> **0.6.0**: multi-user support.

> **0.5.0**: two new templates (`codex`, `grok`), `box expose` — a
> loopback-only door to a box port, for seeing a dev server — and the host
> lifecycle as first-class verbs: `box setup-host` and `box teardown-host`.
> It also added a host-migration verb for pre-0.4.0 hosts; that one was
> **retired**, with the drill phase that proved it, once every user had moved
> (#226). To migrate a host that is still on the old stack, install `0.9.1` or
> earlier first.
>
> **0.4.0's clean cut stands**: the CLI is `box` (no legacy shim), the
> host stack is `boxnet`/`box-isolate`/`box-firewall` on 10.88.0.0/24, and
> the default template is `blank`. Boxes minted by any earlier version keep
> working under every verb — their legacy tag is honored forever.

## Install

### Release artifact (recommended)

Starting with `0.10.0`, every release publishes `box-<version>.sh`, a
self-contained installer, beside `box-<version>.sh.sha256`. Download both
files from the [release page](https://github.com/heavy-duty/box/releases) on a
workstation that can reach GitHub. Copy the two files to the server, replacing
the example login and host:

```sh
scp box-0.10.0.sh box-0.10.0.sh.sha256 operator@server.example:
```

On the server, from the directory that received the files, verify the external
checksum, verify the installer's embedded payload, inspect the version, and
run it:

```sh
sha256sum -c box-0.10.0.sh.sha256
bash box-0.10.0.sh --check
bash box-0.10.0.sh --version
bash box-0.10.0.sh
```

Run the last command as root for one global install or as a normal account for
a per-user install. The artifact contains the box tree and uses that tree's own
`install.sh`; the server needs neither GitHub nor `curl` to install box.

This is a **no-GitHub install**, not a fully offline host. If you accept the
installer's host-setup prompt, `box setup-host` still installs Incus through
`apt`. Later, `box new` still pulls its base image from an Incus remote. Move
the artifact onto the server by scp, USB, or another trusted route when GitHub
is private, blocked, or unreachable; that removes the GitHub dependency from
installing box, not the network requirements of host setup or image pulls.

### Network install

The smaller bootstrap downloads `install.sh` and then the selected source tree
from GitHub. By default it installs the **latest release** — the installer
resolves the release tag from GitHub's `releases/latest` redirect (no API, no
token) and downloads exactly that tree, so two operators running it get the
same box. If resolution fails it says so and stops; it never silently hands
out `main`. `BOX_REF` picks another channel (a set ref is tried as a tag first,
then as a branch — [#83](https://github.com/heavy-duty/box/issues/83)):

```sh
curl -fsSL https://raw.githubusercontent.com/heavy-duty/box/main/install.sh | bash
curl -fsSL https://raw.githubusercontent.com/heavy-duty/box/main/install.sh | BOX_REF=0.6.0 bash
curl -fsSL https://raw.githubusercontent.com/heavy-duty/box/main/install.sh | BOX_REF=main bash
```

A dev tree's `VERSION` carries a `-dev` suffix, so it lands beside your
releases under `versions/`, never on top of one.

### Local checkout or tarball

An already-present checkout can run the same installer without a download:

```sh
BOX_INSTALL_SOURCE="$PWD" bash install.sh
```

`BOX_INSTALL_SOURCE` also accepts a local source tarball. This path, like the
release artifact, does not require `curl` or a GitHub route; the caller must
already have both `install.sh` and the named source on the server.

### Network boundary

The network boundary is the download, not the installation logic:

| Channel | What must reach GitHub | Private repository or no GitHub route |
| --- | --- | --- |
| `box-<version>.sh` release artifact | Only the machine that obtains the two release assets | Transfer the authorized download to the server; installation itself needs no GitHub access. |
| `curl .../install.sh \| bash` with `BOX_REF` unset | The server fetches raw `install.sh`, follows `releases/latest`, then downloads the tagged source archive. | The unauthenticated public URLs fail; use a transferred artifact or local source. |
| `BOX_REF=<tag>` | The server fetches raw `install.sh` and the named tag archive. | The unauthenticated public URLs fail; transfer the release artifact or source instead. |
| `BOX_REF=<branch>` | The server fetches raw `install.sh` and the named branch archive. | The unauthenticated public URLs fail; transfer a checkout or source tarball instead. |
| `BOX_INSTALL_SOURCE=<dir-or-tarball>` | Nothing, once `install.sh` and the source are local. | Works without GitHub; `curl` is not even a prerequisite. |

Making `heavy-duty/box` private therefore breaks the documented unauthenticated
`raw.githubusercontent.com` and archive downloads. It does not break an
artifact or local-source install after an authorized user has moved those
bytes onto the server.

The installer asks first — **"Install box?"** — then uses the selected tree
for a **versioned** install (the way plenty of CLIs manage theirs), links `box`
onto your `PATH`, and on a fresh host asks a second question: **"Set up this
machine as a box host now?"** Say yes and it builds the whole isolation stack
for you (it may ask for `sudo`); say no and you can run `box setup-host` later.
(No `git clone` needed.)

The layout, under the install root (`~/.local/share/box`, or `/opt/box` for a
root install):

```
versions/<version>/          one full tree per installed version
current -> versions/<v>      the tracked default
$BINDIR/box -> current/bin/box    the PATH entry, riding the chain
```

**Re-running is a safe converge.** Installing a version you already have
changes nothing and says so (`BOX_REINSTALL=1` replaces that version's tree);
a stray re-run can never clobber your install or rebuild the stack under your
boxes. Installing a **new** version lands it side by side and flips `current`
only when you have **no boxes** — under existing boxes the flip is refused
(never change versions under a user's boxes,
[#66](https://github.com/heavy-duty/box/issues/66)) and switching stays a
deliberate act: preserve what you care about — `box down <box>`, then
`box export <box>` (one portable file per box, snapshots included —
[#70](https://github.com/heavy-duty/box/issues/70)), then `box rm <box>`
(which deletes the box _and_ its snapshots) — then:

```sh
box versions        # what is installed, which is current, which is running
box use <version>   # flip the default (same refusal while boxes exist)
```

While box is `0.x`, compatibility is decided **release by release**. When
carrying existing hosts or artifacts forward is cheap, the release includes
that path; when it is unusually expensive, the release may skip it and says so
in both the changelog and the failure. Read the target release's changelog
before switching. This is not a blanket promise that any `0.x` release may
break anything. At `1.0.0` this per-release policy ends and box must publish
the compatibility promise it will support; this paragraph does not choose that
promise in advance.

`0.10.0` is one skipped boundary. It renames the placement profile from
its former name to `box-profile`, while an artifact exported by `0.9.x` still
names the former profile. On a converged `0.10.0` host, Incus refuses that
missing profile before box can reassign it; on an unconverged host, box may
instead report that the `box-profile` host stack is missing and suggest
`box setup-host`, which does not make the old artifact importable.
[#241](https://github.com/heavy-duty/box/issues/241) tracks the loud
version-boundary refusal. The supported path across this boundary is to
uninstall the old box installation, install `0.10.0`, and re-create the boxes.

If the old artifact's data must be recovered anyway, an administrator can use
the unsupported manual route recorded in the `0.10.0` changelog: create the old
placement profile under the name recorded in the artifact, import so box can
re-home the instance onto `box-profile`, then let `box doctor` report the
old-name residue before `box setup-host` clears it.

A pre-0.7.0 flat install is migrated into `versions/` automatically on the
next installer run — the tree is moved, not re-downloaded, and your boxes are
untouched. After switching versions, import an exported box only when the
target release declares that artifact compatible; across a skipped boundary,
re-create it instead. A version-aware upgrade that migrates boxes instead of
asking you to is [#67](https://github.com/heavy-duty/box/issues/67). For
unattended installs (CI, images), `BOX_YES=1` answers every prompt yes,
`BOX_SKIP_SETUP_HOST=1` declines the host-setup step, and
`BOX_INSTALL_SOURCE=<dir-or-tarball>` installs from a local tree instead of
downloading (how CI proves the installer under review, and how the drill can
install an unpushed branch).

### Global vs per-user install

Where box lands depends on **who runs the installer**, because on a shared host
box's tree is _executed by other users_ — so it cannot hide in one user's home:

- **As root → global.** The tree goes to `/opt/box` (world-readable) and the
  `box` symlink to `/usr/local/bin` (already on every login `PATH`). One
  install, every operator on the host runs the same `box`. This is the fleet
  path: [rig](https://github.com/heavy-duty/rig)'s `box` role
  ([rig#24](https://github.com/heavy-duty/rig/issues/24)) installs box once at
  host bootstrap ([#71](https://github.com/heavy-duty/box/issues/71)).
- **As a normal user → per-user.** The tree goes to `~/.local/share/box` and
  the symlink to `~/.local/bin` — the solo path, unchanged. Nobody else needs
  to run your box.

`BOX_HOME` / `BOX_BIN` override the destination on either path. A per-user
install under `/root` would be `0700` and unreadable to everyone else — which
is exactly the bug the root branch fixes. When both tiers are installed, PATH
order decides which `box` wins — the installer warns when it sees the other
tier's tree.

## One-time host setup (Ubuntu 24.04 / Debian 13)

The installer already does this. Run it directly to set up a host you
installed with `BOX_SKIP_SETUP_HOST=1`, or to re-apply the stack by hand:

```sh
box setup-host   # one run is enough
```

Idempotent. Installs Incus and creates the isolation stack: the `boxnet` NAT
bridge (sibling-name resolution off, resolver pinned to public upstreams —
`BOX_DNS` overrides), the `box-isolate` ACL (drops all RFC1918/CGNAT/
link-local egress), the `box-profile` profile (port-isolated NICs — boxes can't
reach each other), and firewall rules blocking instance → host. All rules
re-apply at boot via `box-firewall.service` — no post-reboot ritual. If
the host lacks `dnsmasq-base` (Debian cloud images skip Recommends):
`sudo apt-get install -y dnsmasq-base`.

The stack's subnet is `10.88.0.0/24` when free. setup-host **never builds on
a subnet something else already claims** — most tellingly when this machine's
own default gateway sits inside it, which means it is being run *inside a
box*: a nested `boxnet` on the guest's own uplink subnet captures its gateway
address and blackholes the guest's egress in intermittent,
maddening-to-attribute blackouts
([#80](https://github.com/heavy-duty/box/issues/80)). Instead of refusing, a
bare `box setup-host` decides for itself: an existing `boxnet` bridge is
converged on as-is (the bridge is the pin — it is never re-addressed), and a
claimed default triggers an auto-pick of the first free `/24` from
`10.89.0.0/24` through `10.127.0.0/24`, announced loudly — so drills and
rehearsals *inside a box* work with zero flags. `BOX_SUBNET=<a.b.c.0/24>`
pins the subnet explicitly for scripted hosts (the bridge address, the ACL's
gateway carve-out and the firewall all derive from it); a pin is honored or
refused, never silently overridden. `box doctor` recognizes the poisoned
state (a gateway held as a local address, duplicate uplink routes) on the
machine it runs on and inside every box it probes.

**Where the boxes live.** The storage pool carries every box's root device,
and with no `source:` Incus builds it as a loop-backed image inside its own
state directory — on the root filesystem. A fleet of 60GiB boxes is then
charged against `/`, competing with the operating system for one partition
([#180](https://github.com/heavy-duty/box/issues/180)).
`BOX_STORAGE_SOURCE=/dev/sdb box setup-host` places the pool on a disk of its
own (Incus formats and owns it outright — the recommended form), and
`BOX_STORAGE_SOURCE=/data/bulk/incus` places it on an already-mounted
filesystem. Unset is exactly today's pool, so upgrading changes nothing. The
value must be an absolute path and reaches Incus exactly as typed, so a
directory whose name contains a space or a `#` is placed — and reported —
as the path you named rather than as the part before it. The one shape it
refuses is a path containing a newline or a tab: the preseed carries the
source as a YAML scalar and YAML folds a line break inside one to a space, so
that value cannot be transmitted faithfully and is declined rather than
quietly changed.

This is a **fresh-host** setting: a pool is created once, and setting the
variable never moves one that exists. On a host that already has a pool
setup-host refuses when the variable disagrees with the live source — naming
both — and re-runs clean when it agrees; moving a pool that already carries
boxes means moving every box's root device, which is a migration rather than
a re-run. Agreement is judged against the source Incus was *handed*, not the
one it reports: on a block device it formats the disk and then records the new
filesystem's UUID as the pool's source, so `BOX_STORAGE_SOURCE=/dev/sdb`
re-runs clean rather than refusing at its own pool.

That recorded path is a string kept at creation, though, and a device *name*
is assigned in enumeration order — it can move to another disk across a
reboot, an added controller or a hot-plug, while the filesystem UUID cannot.
So a re-run naming a block device is checked against what that path holds
**now**: same disk, it re-runs clean; another disk, or a device this run
cannot read at all, it refuses and names the live UUID, the path the pool was
made from, and what that path holds instead. `lsblk -o NAME,UUID` finds the
disk that does hold it; unsetting `BOX_STORAGE_SOURCE` re-runs the script
against the host as it stands. Mounted-path sources are unaffected — Incus
keeps those verbatim, so the path itself is the current fact.

`box doctor` prints the pool's driver and its source — and, where those
differ, the path it was built from, with the same caveat about device names —
which is what answers "what is filling my root disk" without an Incus lesson.

A host still carrying the pre-0.4.0 stack has no migration path in this
release: install box `0.9.1` or earlier, migrate with it, then upgrade. The
verb and the drill phase that proved it were retired together once every user
had moved off the old stack (#226).

## Multi-user hosts: the restricted tier

One host, several people, and not everyone should hold the daemon. Incus's
socket is all-or-nothing — `incus-admin` group members own every instance on
the machine — so box layers a second tier on
[incus-user](https://linuxcontainers.org/incus/docs/main/projects/):

| tier           | who                              | what they hold                                                    |
| -------------- | -------------------------------- | ----------------------------------------------------------------- |
| **admin**      | root, or the `incus-admin` group | everything: all boxes, the stack, `setup-host`, `expose`, `grant` |
| **restricted** | the `incus` group                | their **own** boxes only, on the same hardened network            |
| none           | everyone else                    | no socket, nothing                                                |

An admin hands the tier out per user, and takes it back:

```sh
box grant dev1              # dev1 can now: box new / list / shell / snapshot / rm — their boxes only
box revoke dev1             # tier removed; their boxes survive (grant again restores).
                            #   a session they already hold keeps the socket until it
                            #   ends — revoke warns and names the loginctl command
box revoke dev1 --purge     # ...or end their sessions and delete everything they had
```

`grant` is an idempotent convergence, not a flag flip, because incus-user's
defaults miss box's contract three ways (measured on Debian 13 / Incus 6.0.4,
see [the plan doc](docs/plans/2026-07-18-restricted-tier.md)): it pins each
user to a private _unhardened_ NAT bridge, it blocks snapshots, and it cannot
see the `box-profile` profile. Granting rewires all three: the user's project is
restricted to `boxnet` **and only boxnet** — the hardened network is not their
default placement but the only one their certificate can express — snapshots
and backups are allowed (the clone and `box export` workflows), and the
shipped profile is installed into their project. Re-run
`box grant <user>` after upgrading box to refresh the profile, like
`setup-host` for the stack.

**Services get the same tier** (#281). `box grant --service garm` grants a
no-login system account a daemon runs as: its project is fenced exactly like a
person's, plus managed disks only (`restricted.devices.disk=managed`, so a
service never mounts host paths into an instance) and the
`user.box.service=true` marker. The grant needs no home for the account, and
it refuses an `incus-admin` member, whom nothing could fence. The service
reaches its project through incus-user's socket (`unix.socket.user`) with
`project=user-<uid>`. **Grant first, then start the service:** a service reads
its groups once at start, and one that reaches incus-user before the grant
creates an unhardened project. This is how other tools mint instances under
box's contract without admin rights (heavy-duty/handbook proposal 0011).

What a restricted user gets is the full contract: same ACL, same DNS
isolation, same pinned resolver, same port isolation, same box↔box drop —
and their boxes cannot reach another user's box, which is the same
box↔box drop doing its one job. What they can't do stays honest: `box
expose` (daemon-global state) says to ask an admin, `box setup-host` and
`box doctor` answer at their tier instead of failing at it.

`drill/multiuser.sh` rehearses all of it live — two users, real grants, real
boxes, probes from inside — and CI runs it on every PR (container mode; the
VM boundary itself is proven on real hardware, like the rest of the drill).

## Quick start

```sh
box new --name work --size medium   # a blank box, nothing converged
box shell work                      # enter as the tenant user (default: dev)
```

**That box is blank, and blank is literal.** The seed carries a tenant user, a
fixed 1GiB `/tmp`, swap, chrony, `tmux`, `curl`, `ca-certificates`,
`python3-venv` and `shellcheck` — that list is the whole of it. There is no
coding agent on it, and **no `gh`**; the tenant has no sudo, so it cannot
`apt install` one either. Authenticating is therefore not the first thing you
do on a fresh box. Converging is.

**Box mints; you converge.** Turning a box into a coding-agent box, a server,
or anything else is four steps, and box performs none of them
([#214](https://github.com/heavy-duty/box/issues/214)):

```sh
box new --name work --size medium        # a blank box, nothing converged
box root work                            # root inside it, authorized by the host's Incus socket
# then, inside the box, as root:
curl -fsSL https://raw.githubusercontent.com/heavy-duty/rig/<ref>/install.sh \
  | RIG_REPO=heavy-duty/rig RIG_REF=<ref> bash
rig bootstrap claude-box --user dev
```

Once your converger has put a toolchain on the box, authenticate inside it —
box never handles the credential, before or after:

```sh
gh auth login                    # or drop a PAT in — your git credentials, your call
git clone https://github.com/you/project && cd project
```

**Read the cold-start promise honestly.** Box used to sell a creds-free
coding-agent box as one command, ~10 minutes cold. It does not any more: this
is a four-step path whose convergence you wait through interactively, in a
shell you opened. What you get for it is a tool with one job — box provisions
and manages the VM, and the thing that converges it is yours to choose,
version and run.

Three details in that block are load-bearing:

- **`--size medium` is not decoration.** A role never implied a size, and
  omitting it gives you 2/2/20 where an agent box used to get 4/8/60.
- **`box root`, not `box shell` + `sudo`.** The tenant an ordinary mint
  creates is unprivileged and has no sudoers entry (see below), and `box root`
  authorizes through the host's Incus socket rather than through anything in
  the guest ([#176](https://github.com/heavy-duty/box/issues/176)).
- **`box root` is a login shell**, so `$HOME` is set and a converger that
  reads it needs no workaround.

## Sizes and seeds

There is no role axis and no `--role` flag. The public mint shapes are:

| Mint shape | Meaning |
|---|---|
| `box new --name <box>` | The tenant seed: an unprivileged user, a thin toolchain, nobody home |
| `box new --user <name>` | The same seed with a tenant user other than `dev` |
| `--template staging-box` | Dedicated server seed: VM-only and autostarting |

**The seed is thin and it is the whole of what box installs.** It carries the
tenant user, `tmux`, `curl`, `ca-certificates`, `chrony`, `python3-venv` and
`shellcheck`, caps `/tmp` at a fixed 1GiB and lays a 4GiB swapfile in VM mode
— and nothing that joins a tailnet or admits a credential. `curl` and
`ca-certificates` are there for **your** installer, not box's: the first line
of the converge above is a `curl … | bash` inside the box, and a bare cloud
image is not guaranteed to ship either.

**The tenant is unprivileged inside its own box; the operator enters as root
from the host** ([#177](https://github.com/heavy-duty/box/issues/177)). The
seed creates the tenant user with no sudoers entry, so `sudo` inside a box
fails — and `box root <box>` still lands as root, authorized by
the host's Incus socket rather than by anything in the guest
([#176](https://github.com/heavy-duty/box/issues/176)). Root was never what
contained a coding agent; the VM is. What it cost was the ability to add any
control *inside* a box later — an egress allowlist, a read-only mount, an
audit trail — each of which is one `sudo` away from being switched off while
the tenant holds it. The seed ships the toolchain instead, user-local installs
still work unprivileged — `python3 -m venv`, `cargo`, `uv`, and
`npm install --prefix <dir>` (a *global* `npm -g` writes to `/usr`, so point
it somewhere the tenant owns once: `npm config set prefix ~/.local`) — and
anything genuinely needing `apt` is one `box root` away. `staging-box` keeps
sudo on purpose: it seeds a guest that converges *itself*, from the inside.
This is **mint-time only** — cloud-init runs once, so boxes minted before this
change still have their sudoers entry.

**Anything that joins or admits stays yours, and now so does everything
else.** The `staging-box` tenant's tailnet workload join holds a pre-auth key
and was always operator-run ([#69](https://github.com/heavy-duty/box/issues/69)'s
split); since #214 the server posture beside it is too. Both run inside the
box, through `box root <name>`:

```sh
box root staging1
# then, inside the box, as root — after installing your converger as above:
rig bootstrap staging-box
rig bootstrap workload-server --hostname staging1
```

**Box reads no converger pin.** `RIG_REPO` and `RIG_REF` used to select which
revision box installed into every guest it minted
([#81](https://github.com/heavy-duty/box/issues/81),
[#150](https://github.com/heavy-duty/box/issues/150)). Box installs nothing
now, so it does not read them: exporting either changes nothing about what is
rendered or minted, and box says nothing about it — the variables belong to
the installer you run inside the box, which is where you pass them. A mint
makes no network request of its own for a pin, so minting works offline.

```sh
box templates                    # list dedicated non-agent templates
box new --name scratch           # the DEFAULT: bare Debian + the thin seed,
                                 #   same isolation, nobody home
```

A seed **cannot** name a network, a profile, or a `security.*` flag —
there is no key for them. Every box launches with the shared `box-profile`
profile (the isolated NIC + root disk), so every template gets the identical
trust boundary. `--size small|medium|large` selects a resource bundle (small
is the default), overridable at mint time — inline
(`--cpu 2 --memory 3GiB --disk 20GiB`) or via
`BOX_CPU` / `BOX_MEMORY` / `BOX_DISK` environment variables (the scripting
form). Resolution is `--cpu/--memory/--disk` > `BOX_*` environment >
`--size` > seed/default values:

| Size | CPU | Memory | Disk |
|---|---:|---:|---:|
| `small` | 2 | 2GiB | 20GiB |
| `medium` | 4 | 8GiB | 60GiB |
| `large` | 8 | 16GiB | 120GiB |

The default mint path defaults to `small`. The dedicated
`staging-box` seed keeps its existing medium resources when no size is given.
Named sizes apply to fresh mints; `--from` clones keep the explicit
`--cpu`/`--memory`/`--disk` override surface.
The selected seed, its generation and the resolved user are stamped onto the
instance, so `shell`, `exec` and `tmux` land in the right user — and a clone
still knows, because `incus copy` carries the metadata. `box checkup <box>`
reports that generation; an older box with no marker says it is unknown rather
than guessing from the guest's current contents.

## Log in once, reuse via snapshots

Because every fresh box is creds-free, re-authenticating each time would be
toil. Snapshot an authenticated box and clone from it instead:

```sh
box snapshot work authed   # checkpoint after you've logged in
box new --name feature --from work/authed   # clone the authed state into a new box
```

`--from` copies the whole box (agent login, git creds, clones and all) while
preserving isolation. You can also `box new --name x --from work` to clone
a box's live state, or roll a box back with `box restore work authed` — which
asks first, since a rollback discards everything since the snapshot (`--force`
skips the prompt, and scripts must pass it: with no terminal to ask on, box
refuses rather than assuming yes).

Forgotten what you called a checkpoint? `box info work` prints the box's
snapshot labels and the `--from` line to clone one.

### `pristine` — the one checkpoint box takes for you

Every fresh mint marks a snapshot called `pristine`
([#104](https://github.com/heavy-duty/box/issues/104)) at the one moment it
is true: **after cloud-init, before anything converges the box.** At that
instant the guest is pristine Debian plus box's thin seed — the tenant user,
tmux, the toolchain — and nothing else. It exists for a few seconds on every
mint, so box captures it rather than asking you to be quick.

```sh
box restore work pristine   # undo the convergence and everything since
```

That is a complete undo for a convergence run: what one installs — docker,
node, an agent CLI, a context file, a role marker — is box-local and
file-shaped, so a filesystem rollback reaches all of it, without paying a
re-mint.

Three things it deliberately does not do:

- **It is an undo, not a backup.** Snapshots die with their box: `box rm`
  deletes a box _and_ every snapshot it has. `box export` is the only state
  that outlives the box — see below.
- **It cannot reach off-box state.** A tailnet join, a GitHub runner
  registration, a pushed commit: those are records held somewhere else, and
  no filesystem rollback undoes them.
- **A `--from` clone gets no `pristine` of its own.** A clone skips
  cloud-init entirely, so it has no pristine moment to capture, and
  box will not label a source's worked-in state as one. Cloning a _box_
  inherits the source's snapshots (a real `pristine` among them, if the
  source had one); cloning a _snapshot_ starts with none. `box new` says
  which of the two you got.

On a host whose storage pool uses the `dir` driver, a snapshot is a full
multi-GB copy rather than a near-free copy-on-write mark, so the mint
**skips** `pristine` and says so loudly — take it by hand with `box snapshot
<box> pristine` if you want it anyway. btrfs is what `box setup-host`
installs by default precisely so snapshots are cheap. `BOX_SNAPSHOT_PRISTINE=0`
skips the mark on any host.

## Survive the host: `box export` / `box import`

Snapshots live _inside_ a box, and `box rm` deletes the box **and** its
snapshots. `box new --from` clones — but the clone still lives on the same
host, under the same stack. `box export` is the way out
([#70](https://github.com/heavy-duty/box/issues/70)): one portable file that
outlives the box, the host stack, and the machine.

```sh
box down work                        # export wants a settled disk
box export work                      # → work-<UTC stamp>.tar.gz, snapshots included
box rm work                          # nothing is lost anymore
# ...rebuild the host / carry the file to another machine...
box import work-<stamp>.tar.gz       # the box is back — snapshots, logins and all
box import work-<stamp>.tar.gz --name work2   # or under a new name
```

This flow survives `box rm`, a host rebuild, and a move to another machine; it
does not promise migration across box releases. Everything `incus import`
restores is the artifact's truth (disk, config, snapshots); what box re-stamps
on import is _this_ host's truth — the `user.box=1` boundary tag, the
`box-profile` placement when every profile named by the artifact already exists
on this host, and a fresh machine identity, the same move a clone gets. If the
artifact names a profile this host lacks, Incus refuses it before box is
consulted. An imported box can therefore never collide with the box it was
exported from. Import also refuses a name any existing instance already holds.
`--instance-only` exports the live state without the snapshots.

**The file is a credential.** A box's disk carries everything inside it —
agent logins, git PATs, SSH keys, shell history. Export scrubs nothing (a
"scrubbed" disk image would be a lie) and shouts instead, every time. Store
and move the file like the secret it is.

## See a dev server: `box expose`

The isolation contract says no inbound path exists — which is one "no" too
many when you're coding in a box and want its dev server in your browser.
`box expose` is the deliberate exception:

```sh
box expose work 3000             # http://127.0.0.1:3000 → work:3000
box expose work 3000 8080        # or pick the host port: 127.0.0.1:8080 → work:3000
box expose work --list           # what doors are open
box expose work --remove 3000    # close one
```

The listen side is **always the host's own loopback** — never the network, no
flag to widen it — so no other machine gains a path to the box. The in-box
server must listen on `0.0.0.0`, not its own loopback (safe inside the
isolation stack: only this door can reach it). A box with a hole says so:
`box info` lists open exposures. Everything else on the box stays dropped —
the door is per-port, punched and removable at runtime.

## Commands

```
box new --name <box> [--size small|medium|large] [--user <user>] [--from <src>[/<snap>]] [--cpu <n>] [--memory <size>] [--disk <size>] [--vm|--container]
box templates                # list dedicated non-agent templates
box list                     # list your boxes
box info <box>               # one box: state, IP, exposures, provenance, snapshots
box shell <box>              # enter as the stamped tenant user
box root <box>               # enter as root through the host's Incus authorization
box exec <box> -- <cmd...>   # run a command in the box
box tmux <box> [session]     # attach/create a tmux session — survives disconnects
box snapshot <box> [label]   # checkpoint (label defaults to manual-<epoch>)
box restore <box> <snap> [--force]
                             # roll back to a snapshot — destructive, asks first
                             # 'pristine' is auto-marked at mint: back to
                             # pristine Debian + box's seed, before anything
                             # converged it
box export <box> [<file>] [--instance-only]
                             # one portable file (snapshots incl.) — survives rm & host
box import <file> [--name <box>]
                             # mint a box back from an exported file, re-stamped
box rename <box> <new>       # rename a box (stop it first)
box down <box>|all [--force]
                             # stop (state kept; `start` resumes) — `--force`
                             # pulls the plug on a guest that will not stop
box start <box>|all          # start a stopped box
box restart <box>|all        # restart — one incus call, not down-then-start
box rm <box> [--force]       # delete the box + its snapshots (asks first)
box expose <box> <port> [<host-port>] | --list | --remove <port>
                             # forward a box port to host loopback — see a dev server
box incus <box> -- <args...> # escape hatch: any incus command, box resolved
box checkup <box>            # is this guest fit for work? read-only fitness report
box doctor [--fix|--pin-dns] # is this host fit to mint boxes? diagnose from ground truth
box setup-host               # one-time host setup: Incus, the boxnet stack, the firewall
box teardown-host [--purge-incus]   # remove the host stack (both name generations)
box status                   # deprecated alias for `list`
box help [<command>]         # full help, or one command's page
```

Every command takes `--help`, and options come after the command
(`box list --json`). Exit status: `0` ok, `1` it went wrong, `2` you asked
wrong.

The three lifecycle verbs also take `all` where a box name goes — `box
restart all`, `box start all`, `box down all`. `all` means exactly the boxes
`box list` prints for you, so it respects the tier boundary already in force:
an admin's `all` never reaches a restricted user's boxes, and a restricted
user's never reaches anything but their own. Each box is reported on its own
line, one failing box does not stop the others, and the exit status is
non-zero if any of them failed; with no boxes it succeeds and says so. The
fleet forms do not prompt — they are reversible acts on your own boxes — and
`rm` deliberately has no `all` form. Because the word is taken, `all` is not
a legal box name: `box new --name all` is refused, and so are `box import
--name all` and `box rename <box> all` — every door that would leave a box
carrying the word.

A fleet is usually mixed, so a box already in the state you asked for counts
as a success: `box down all` reports the ones that were already down and
`box restart all` starts a stopped box instead of erroring on it. That keeps
the exit status meaningful — non-zero means something went wrong, not that a
box had nothing to do.

A guest that stops answering the graceful stop hangs there, so `box down`
takes `--force` — `incus stop --force`, the power button. **Anything the
guest had not flushed to disk is lost**; the box itself, its disk and its
snapshots survive, and `box start` brings it back. It never happens on its
own: there is no timeout after which a graceful stop escalates, because a
`down` that is slow because the guest is flushing a large write is doing what
you asked. The boundary holds under it exactly as without it — box only acts
on an instance it tagged, so forcing skips the politeness, never the check.
`box down all --force` forces the fleet; the boxes already stopped are still
reported as the successes they are, untouched.

`new` fresh-launches a small blank box by default, or with `--from` clones an
existing box or snapshot.
VM mode (`--vm`, the default where
`/dev/kvm` exists) is the trust-less target; container mode (auto-fallback,
`security.nesting=true`) is for hosts without nested virt — weaker isolation,
dev/test only.

## What minted this box: `box info`

A box outlives the release that minted it, the template that shaped it and the
image build it came from — and until
[#103](https://github.com/heavy-duty/box/issues/103) it recorded none of them.
There is no host-side per-box store; the Incus instance config _is_ the
database, so a fact not written at mint time is simply gone. `box new` now
stamps what it knew, and `box info` reads it back:

```
NAME       work
ID         3f2504e0-4f89-41d3-9a0c-0305e82c3301
STATE      RUNNING
TYPE       VM
IPV4       10.x.x.x

MINTED     2026-07-19T14:22:07Z by box 0.8.1
TEMPLATE   tenant (user dev)
IMAGE      images:debian/13/cloud @ 8a2f1c9d4e5b…
MODE       vm (asked: auto)
ORIGIN     mint
```

The image line carries both halves on purpose: the template names an
_unpinned alias on a moving remote_, so what it resolved to at that mint is the
only reproducible fact. `box info --json` carries every key verbatim — they
ride `incus list --format json` in `config`.

**`ID` is which box this is; `NAME` only looks like it**
([#181](https://github.com/heavy-duty/box/issues/181)). `box rename` is a
passthrough Incus is right to accept — same instance, every key riding along —
but to a script, a log or a note that kept the name, a rename is
indistinguishable from an `rm` and a fresh mint. Names are not unique either:
two restricted users each hold their own `work` in their own `user-<uid>`
project, and an admin a third. So `box new` stamps `user.box.id`, a kernel v4
UUID drawn on the **host**, and the name becomes an alias — the container
id + name shape, or Kubernetes' `uid` + `metadata.name`.

Host-side is the whole design, and the guest's `/etc/machine-id` is the
tempting answer that fails four ways: it is unreadable while the box is
**stopped** (the boxes an inventory most cares about), it does not exist until
systemd's first boot, the agents inside the box can rewrite it, and it
duplicates on exactly the operations box already guards — snapshot, export,
import, clone. Instance config is readable while stopped, invisible and
unwritable from inside the box, and re-stampable with one `incus config set`.
There is deliberately **no map file**: Incus config _is_ the map, and a
name↔id file on disk would be a second source of truth with no writer for the
paths that bypass box.

**Anything that mints, re-stamps.** A fresh mint, a `--from` clone and an
import each draw their own id — for a clone, inheriting it would be the bug,
since it would claim to _be_ its source — while a snapshot and a restore leave
it alone, because a restore is the same box. `box list` never shows it (that
table is for humans; the id is for machines), and the id **authorises
nothing**: `user.box=1` stays the ownership boundary.

**A clone re-stamps.** `incus copy` preserves `user.*` keys, so a clone inherits
its source's template and user for free — but inheriting the mint stamp would
not make it stale, it would make it **false**: the clone was not present at that
mint. `box new --from` therefore re-stamps the four keys that describe _this_
instance's coming into being (`ORIGIN clone of work/authed`, a fresh time, the
box version that cloned it) and leaves the lineage keys alone, because the
clone's disk genuinely did come from that image, template and user. `origin.from`
records one hop: a clone of a clone names its parent, not its grandparent.

**An import records the trip, and rewrites nothing but the id**
([#131](https://github.com/heavy-duty/box/issues/131)). Everything `incus
import` restores is the _artifact's_ truth, so an imported box keeps its mint
stamp verbatim — the mint time, the box version, the image and the origin
belong to the originating host and survive the trip on purpose. What `box
import` adds is the one fact the artifact cannot carry: that the trip happened.

```
MINTED     2026-06-01T10:00:00Z by box 0.7.0
IMPORTED   2026-07-20T09:14:03Z by box 0.8.1 (the mint above predates it)
ORIGIN     clone of work/authed
```

It is **not** `origin=import`, and the difference is the whole point. `origin`
answers how the instance came into _being_ — mint or clone — and overwriting it
would destroy that: the clone above would come back claiming to be an import,
with nothing left saying it was ever a clone and an `origin.from` naming a
lineage no key explains. The import is a _third_ fact, orthogonal to the first
two, so it takes its own keys and leaves every other one alone.

The `ID` is the one exception, and it is not really one: an id is not a fact
about the artifact but about a box on a host, and the box this artifact came
from may still be running — quite possibly on _this_ host, which is what the
MAC regeneration on the same path already exists to survive. Importing is
minting, so the id is re-minted; the old one is not kept, because lineage is
[#131](https://github.com/heavy-duty/box/issues/131)'s question and this key
owes only the identity itself.

The `IMPORTED` line sits directly under `MINTED` because that adjacency is what
stops the mint time being misread as this host's. Note what it does not claim:
box has no record of _which_ host minted the box, and a box can be exported and
re-imported onto the same host during a rebuild, so the line
states only the ordering — the one thing box actually knows.

**A box can make the trip more than once**, and both ends are kept: the first
import is pinned forever, the latest is refreshed on every arrival, and a count
says how many. Last-wins alone would erase the evidence of the earlier trips,
which is the same mistake `origin=import` makes one level up. (The shape
follows [heavy-duty/rig#61](https://github.com/heavy-duty/rig/issues/61)'s
manifest: a birth pair plus a latest pair.)

**Boxes minted before this stamp existed keep working**, under this verb and
every other — they render as a box with blanks and say `MINTED (not recorded)`
rather than erroring. `user.box.schema` names the stamp's _shape_ (an integer,
not the box version) so a box minted by a later release reads back on an older
box as "here is what I understand, and there is more I don't".

## Boxes are just Incus instances

A box is an ordinary Incus instance tagged `user.box=1` (pre-0.4.0 boxes
carry `user.claudebox=1`, honored forever). box wraps the box lifecycle and
the isolation model — not all of Incus. It owns a command
when it must enforce something Incus can't see: that tag (it will not stop,
rename or delete an instance it didn't mint), the isolation stack, or the
creds-free snapshot workflow. For everything else, there's the door:

```sh
box incus work -- config show        # instance name appended
box incus work -- file push x.tar {}/tmp/   # or placed with {}
```

The box is resolved and tag-checked; the rest is passed to `incus` verbatim, and
the command is echoed before it runs. If it can move the box off the isolation
stack (profile, network, device, `security.*`), box warns and proceeds —
the trust boundary is then yours to keep. See
[docs/box-design.md](docs/box-design.md) for the rule and why the
command surface is a table.

## Isolation

The contract: **a box reaches the public internet and nothing else.** Not the
host, not your LAN, not another box, not even another box's _name_. What
enforces it, layer by layer:

- **Dedicated NAT bridge** `boxnet`, IPv6 off. Every rule below is
  IPv4-only, so IPv6 would be an uncovered path — off is part of the
  contract, not a default.
- **`box-isolate` ACL** — drops all egress to private space (RFC1918,
  CGNAT, link-local), with a single carve-out to the gateway so DNS works.
- **Sibling isolation, at L2** — two boxes on one bridge are _switched_,
  never routed, so no L3 rule can separate them (learned the hard way; see
  below). `security.port_isolation` on every box NIC plus an nft
  bridge-family drop mean box A cannot exchange frames with box B at all.
- **No name-level reconnaissance** — `dns.mode=none` stops the gateway
  resolving sibling names, and the bridge's resolver is pinned to public
  upstreams (`no-resolv`), so tailnet names and split-DNS zones from a
  host-level VPN don't resolve inside a box either.
- **Host firewall** — instance → host is dropped except DNS/DHCP, including
  the host's public IPs. Entry is `incus exec` over the local socket only —
  **no inbound path exists** — unless you punch one with `box expose`, and
  that door only ever opens onto the host's own loopback (`127.0.0.1`), never
  the network.

The VM is the trust boundary: whatever runs inside — the coding agent, or
anything a template ships — can run arbitrary code and touch nothing you care
about.

### Measured, not claimed

Every clause above is probed live by an end-to-end drill, because the one time
this contract was reasoned about instead of measured, the reasoning was wrong:
box→box traffic was "covered" by an L3 drop that L2-switched frames never
meet — a hole found by probing, not by reading the rules. On a bare host the
drill installs the whole stack, mints both templates cold — `tenant` and
`staging-box`, which since #214 is the whole set — snapshots and
clones, probes every boundary from inside the boxes, opens and shuts the
`expose` door (and checks the contract survives it), and removes what it
minted — currently **71 checks, 71 passing**. [drill/RUNS.md](drill/RUNS.md) is the full
history, including every trap that fooled a run into a wrong verdict.

### Run the drill yourself

The drill ships in the repo, not the installed tree — run it from a checkout.
Two versions used to be in play, the harness and the tree it fetched from
GitHub; now there is one: **the checkout you run it from is the code under
test** (#225). The drill installs that tree through its own `install.sh`, and
before issuing any verdict it asserts that what landed is byte-for-byte what
the checkout holds — so a stale checkout can only judge itself.

```sh
git clone https://github.com/heavy-duty/box && cd box   # or refresh an existing
git log --oneline -1                                    #   checkout — this commit is
                                                        #   the drill that will judge
bash drill/doctor.sh    # read-only: is this host healthy and the stack live?
bash drill/drill.sh     # FULL end-to-end — mutates the host; use a machine you own
bash drill/wipe.sh      # scorched earth: strip BOTH name generations, images and
                        #   (--purge-storage) the pool, so a run starts from bare
```

To drill something other than latest `main` — a release ref, or a PR branch
on a fork — **check it out and run the drill there**. The drill installs the
tree it runs from and takes no ref (#225):

```sh
git checkout <branch-or-tag>                       # a release candidate
git clone https://github.com/<fork-owner>/box && cd box && git checkout <branch>
bash drill/drill.sh                                #   a PR under review, from its fork
```

The record's repository field is this checkout's `origin`, so drilling a fork's
branch from a clone **of the fork** records the fork — which is the point of
the field. Fetching that branch into a `heavy-duty/box` clone drills the right
commit and records the wrong repository, because `origin` is still upstream.

The doctor reads ground truth, not config claims — the kernel's `isolated on`
flag per bridge port, the process table, the resolver actually in use — and
diagnoses the host faults that have actually happened: a wedged Incus daemon,
a dnsmasq that silently isn't serving, a VPN resolver that boxes would
inherit.

`box doctor` answers whether the **host** is fit to mint and isolate boxes.
`box checkup <box>` answers whether one **guest** is fit to do its work. It
enters the named guest as root through the host's existing Incus authorization
and only reads: seed generation, numeric disk and memory headroom, `/tmp`, VM
swap or a container's host-managed swap policy, and kernel OOM history. It
never remounts, provisions, deletes, writes a file or changes configuration.

An empty readable kernel journal is reported explicitly as “no OOM kill
logged”; an unreadable journal is reported as unknown, never clean. A legacy
ordinary VM with no swap or a 50%-of-memory `/tmp` points to the current #178
seed and reminting, not to a `--fix`: those findings can have different owners,
and `checkup` does not guess which state it may change.

`checkup` exits `0` when every check is clean and `1` when it reports a
finding or could not run a check, so scripts can distinguish a clean guest.

## Recipes: the `.box/` convention

A repo that wants to be easy to stand up in a box ships an optional `.box/`
folder — a runbook the agent you converged onto the box reads and follows
(install deps, start services, template env, seed data, smoke-test). It is
agent-facing documentation, not a host-executed script. See
[docs/box-recipe.md](docs/box-recipe.md).

## Uninstall

`box uninstall` is the real uninstall, and it runs in the safe order — boxes
first, then the stack, then the tree — and **ends with an absence assert**:
every path it removed is re-checked, and any survivor makes it exit 1 naming
the leftovers instead of reporting a clean uninstall that wasn't (the same
discipline as `box revoke --purge`).

```sh
box uninstall <version>            # one non-current version (side-by-side cleanup)
box uninstall --all --purge-host   # everything: teardown-host (all boxes, the
                                   #   boxnet stack, the firewall), then every
                                   #   version, the symlinks, legacy claudebox crumbs
box uninstall                      # just the install — refuses while boxes exist
                                   #   (and names them); run teardown-host first,
                                   #   or use --purge-host
```

The full-removal order on a multi-user host: `box revoke <user> --purge` each
granted user (it asserts its own zero-residue, including the incus-user state
under `/var/lib/incus/users/`), then `box teardown-host` (add `--purge-incus`
to drop Incus itself, `--yes`/`BOX_YES=1` for automation), then
`box uninstall`. CI drills exactly this sequence and asserts zero residue —
no networks, profiles, nft tables, systemd units, files or symlinks.

## Non-goals

- **No unattended/CI bring-up.** The flow is interactive (log in, clone, ask
  the agent). Reproducible-by-construction provisioning is out of scope.
- **No credential storage or injection by the tool.** Boxes are creds-free;
  snapshots are the reuse mechanism, not a secrets store.
