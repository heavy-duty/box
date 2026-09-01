# Changelog

History before 0.5.0 lives in git and in [drill/RUNS.md](drill/RUNS.md),
which records not just what changed but what each drill run proved.

## 0.10.0 — 2026-09-01

### Added

- `box checkup <box>` reports one guest's seed, disk and memory headroom, `/tmp`, VM or container swap posture, and OOM history without changing the guest. It distinguishes a clean kernel journal from one it could not read (#258).
- Release doors now publish a verified offline box installer and checksum sidecar from the committed release tree. (#251).
- `BOX_INSTALLED_FROM` overrides the provenance an install records, for a caller whose `BOX_INSTALL_SOURCE` is a temp directory it then deletes: a dead path names nothing, and `<version>/INSTALLED_FROM` exists to name the source (#250).
- Add a product-neutral builder for integrity-checked, offline self-extracting installer artifacts. (#249).
- `box down --force` — `incus stop --force` for a guest that has stopped answering the graceful request. Whatever it had not flushed to disk is lost; the box, its disk and its snapshots survive, and `box start` brings it back. `box down all --force` forces the fleet (#236).
- `operator`, a cross-cutting issue-owner label, and `ready` turns owner-neutral — so an issue whose evidence only a human on real hardware can produce reads `ready` + `operator` rather than a false `blocked` (#219).
- A return path for doctrine that blocks you: raise a discussion in ceremony quoting the rule at this repo's pin, and cite it wherever the local workaround lives. `.ceremony/README.md` names and links that flow (#219).
- `test/cli.sh` asserts the two rosters are the same set, naming who each file
  is missing, so the panel cannot drift silently in either direction again
  (#198).
- A box now has a stable identity: `user.box.id`, a kernel v4 UUID stamped
  at mint. `rename` moves the name and leaves the id where it was, so a
  record that kept the id can still find the box (#181).
- The id is re-minted wherever box mints — a fresh mint, a `--from` clone,
  an import — so no two boxes share one. A snapshot or a restore is the same
  box and leaves it alone (#181).
- `box info` shows the id under `NAME`; `box list` does not, and nothing is
  invented at read time, so a box minted before the key reads as blank
  (#181).
- `BOX_STORAGE_SOURCE` places the host storage pool on a disk of its own (`/dev/sdb`) or a mounted filesystem (`/data/bulk/incus`), instead of the loop-backed image Incus builds under `/var/lib/incus` — where every box's root device is charged against `/` (#180).
- `box doctor` reports the storage pool's driver and source, the device a pool built on a block device was made from, and the free space under a directory source, so "what is filling my root disk" is answered without an Incus lesson (#180).
- `box restart <box>` — one Incus restart, not a stop followed by a start
  (#179).
- The lifecycle verbs take `all` where a box name goes: `box restart all`,
  `box start all`, `box down all`. It acts on exactly the boxes `box list`
  prints for you, so an admin never reaches a restricted user's boxes. Each
  box is reported and one failure does not stop the rest (#179).
- A fleet verb treats a box already in the state you asked for as a success,
  not a failure: `down all` says so for a box that was already down, and
  `restart all` starts a stopped one. The exit status stays a real signal
  (#179).
- A fleet verb tells "no boxes" apart from "the daemon did not answer": an
  unreachable daemon fails with the diagnosis instead of reporting an empty
  fleet and exiting 0 (#179).
- `all` is now a reserved box name, refused at every door that would leave a
  box carrying it: `box new --name all`, `box import --name all` and `box
  rename <box> all` (#179).
- Every ordinary box provisions a 4GiB swapfile. Without swap every memory spike was a
  hard OOM-kill with no grace period; swap-in is observable, where a kill is a
  process that was there and then was not (#178).
- A named `box root <box>` path for an Incus-authorized root login shell that does not depend on guest sudo (#176).
- `box new --from` honours `--cpu`, `--memory` and `--disk`. They ride the
  copy itself — incus sizes the clone's volume as it creates it — so there is
  no resize, no restart, and no step inside the guest (#171).
- Every box now says what resources it came up with, clone or fresh mint, read
  back off incus. That sizing was invisible until you ran `box info` and read
  `limits.*` out of a config dump (#171).
- `changelog-assembled`, `runner-isolated` and `sha-pinned` guard steps, and a `refs-guard.yml` caller that re-checks a PR body on edit (#168).
- `ci-rerun.yml`, which services the `rerun-owed` label by starting the one rerun no fork-PR author can start themselves (#168).
- Issue events now wake the labels automation, so a queue-state change no longer waits for the next cron tick (#168).
- The emitted drill record carries the isolation audit answers in their own
  `## Audit answers` section. They used to be printed for a human to paste into
  an issue that has since closed, in a repo since renamed (#154).
- Per-phase probe counts in the drill summary, and a `DRILL_EXPECT` floor a short run fails against (#153).
- Legitimate drill skips print a `SKIP` line and lower the expected count by exactly their probes (#153).
- `drill/drill.sh --emit-record <path>` writes the release record itself — host, candidate refs and their SHAs, the numbers, the wall clock (#152).
- A shared drill run ID: `--run-id` / `DRILL_RUN_ID`, defaulting to `drill-<version>-<date>-01` and announced as soon as the install lands (#152).
- The drill refuses `--emit-record` at a path that already holds a record, rather than overwriting the prose that makes it evidence (#152).

### Changed

- Lead installation guidance with the checksummed, scp-able release artifact and spell out which channels need GitHub. (#252).
- README now treats `0.x` upgrade compatibility per release, records that `0.10.0` does not import `0.9.x` artifacts across the placement-profile rename, and preserves export/import for host rebuilds and machine moves (#240).
- Force-stopping a box no longer needs the `box incus` escape hatch, so it keeps the `user.box=1` boundary check the hatch bypassed: `--force` skips the politeness, never the check (#236).
- `box down` itself is unchanged — still graceful, still no prompt, and still never escalating to a force stop on a timer. The operator asks for the power button or does not get it (#236).
- The placement contract is now the `box-profile` profile. It was `box-net`, one hyphen from the `boxnet` bridge its NIC attaches to, which read as a typo in raw `incus` output. `boxnet` is untouched: same name, subnet, keys and ACL binding (#229).
- `setup-host` converges the rename on every run, in `default` and in each granted `user-<uid>` project. Attached boxes keep their placement across it, so a running fleet needs no restart and no reassignment (#229).
- `box doctor` reports a surviving `box-net` as drift, names every project still carrying one, and points at `box setup-host` — the lever that removes it (#229).
- `teardown-host` and the drill's wipe remove both names for one release, so a host torn down after an interrupted upgrade is left with nothing behind (#229).
- Where a box is still placed on the old name, `setup-host` converges by renaming it onto `box-profile` instead of leaving both behind; where boxes sit on each name it reports the residue and does not report the host ready (#229).
- `box revoke --purge` removes both profile names, so a purge on a host upgraded without a `setup-host` run no longer fails deleting the project and names probes that are all empty (#229).
- A daemon that will not list projects no longer reads as a host with no granted users: `setup-host` says which projects it could not check and withholds `Host ready`, and `box doctor` reports the project list as unread rather than certifying a contract it never looked at (#229).
- A listing that emits a row and then fails counts as unread too — a partial answer is not the host's inventory, so neither tool reports on the projects it did not reach (#229).
- Known boundary: an artifact exported by `0.9.x` no longer imports onto a host whose profile has been converged, or onto a fresh one. Incus resolves an artifact's profile list before it creates the instance and refuses a name it cannot find, so `box import` cannot re-home it (#229).
- The refusal is incus's own and it names the profile it could not load. Re-export the box from a source host that has been converged, or have an admin create a profile under the old name before importing (#229).
- A profile created under the old name to admit such an artifact is then reported as drift by `box doctor` until the next `setup-host` clears it. That report is the workaround's own residue rather than a fault (#229).
- `drill/drill.sh` drills the checkout it runs from: it installs through the tree's own `install.sh` with `BOX_INSTALL_SOURCE`, so `git clone && bash drill/drill.sh` finally drills what you cloned (#225).
- `--repo` and `--ref`, and the `BOX_REPO`/`BOX_REF` pass-through, are gone. There is no flag that points the drill at a tree other than the one it runs from (#225).
- An emitted record's repo, branch and SHA are measured from the working tree instead of echoing the refs that were requested (#225).
- Those fields are measured before the install and carried to the end of the run, so committing or stashing mid-drill no longer changes what the record says was drilled (#225).
- The record's repository field reduces any GitHub origin to `owner/repo` and never carries a credential out of the URL; a checkout detached exactly on a tag records the tag (#225).
- The drill refuses if the checkout changes between the moment it is measured and the moment `install.sh` finishes copying it, so the record cannot name a tree other than the one that was installed (#225).
- The drill compares every file `install.sh` copied against the checkout, by content, and refuses when they differ — so a tree edited while it was being copied cannot be drilled under a record naming the commit (#225).
- The drill refuses a checkout carrying files git ignores, listing them as `!!`: `install.sh` copies them into the box while `git status` calls the tree clean, and this repository ignores secrets (#225).
- The ceremony pin moves `0.7.4` → `0.7.6` and `.ceremony/` is re-vendored with it. No new opt-in is adopted: auto-merge, the post-merge workflow, release dispatch and the non-release tag namespace all stay off (#219).
- `labels-reconcile` marks the human review request it makes itself and withdraws only what it marked, so a maintainer's own early request is no longer mistaken for the machine's and taken back (#145, #219).
- Converge a box yourself, in four steps, and box performs none of them. First `box new --name work --size medium`, then `box root work`. `--size` is not optional: a role never implied one, so omitting it gives 2/2/20 where an agent box got 4/8/60 (#159, #214).
- Then, inside that box as root: `curl -fsSL https://raw.githubusercontent.com/heavy-duty/rig/<ref>/install.sh | RIG_REPO=heavy-duty/rig RIG_REF=<ref> bash`, and `rig bootstrap claude-box --user dev`. The README teaches the same path verbatim (#214).
- That replaces a one-command creds-free agent box, ~10 min cold, with a path whose convergence you wait through interactively (#214).
- [`crew new`](https://github.com/heavy-duty/crew) wraps `box new`, so crew pins the last box release before this one until it absorbs that path itself (#212, #214).
- The tenant seed collapses to one shape, carried unconditionally: no sudoers entry, `shellcheck`, `python3-venv`, a fixed 1GiB `/tmp`, a 4GiB swapfile, chrony. `BOX_USER` is `dev`, and `--user` overrides it (#177, #214).
- `--template staging-box` keeps its VM-only, autostarting, `ops`-with-sudo shape and loses its installer line: the server posture is operator-run now, exactly as its tailnet join always was (#69, #214).
- `box info` reads a box minted before this release without error and shows no rig or role row. The retired keys stay on the instance untouched — no migration, no rewrite (#103, #214).
- The drill mints and does not converge: its record names one candidate ref, box's own, and the reproduce line carries no pin. What it proves is what box owns (#152, #214).
- `box doctor`'s header describes the two faults it actually reports — a run's
  leftover boxes and users, and missing shipped stack pieces — instead of a
  phase D hardening rehearsal that stopped mutating the host releases ago
  (#197).
- `box doctor` names each fault by its condition, not by a culprit: NIC
  filtering is a fault because it is not shipped, and an `@internal` ACL rule
  because `@internal` is unsupported on a bridge network's ACL (#197).
- Every ordinary box caps `/tmp` at a fixed 1GiB. systemd sized it at 50% of RAM, so
  scratch competed with the guest's working set and raising `BOX_MEMORY` raised
  the ceiling with it — no memory figure fixed that, only a fixed cap (#178).
- The default seed says in `box.env`, beside the memory line, that `/tmp` is
  RAM and that swap is provisioned — the fact belongs next to the setting that
  used to cause it (#178).
- The default seed creates an unprivileged tenant — no sudoers entry — so `sudo` fails inside a fresh box. `box root <box>` is the operator's root path. This is mint-time only: cloud-init runs once, so a box minted before this keeps the sudo it was minted with (#177).
- The default seed ships `shellcheck` and `python3-venv`, the toolchain its tenant can no longer install for itself; user-local installs still work unprivileged. `staging-box` keeps its `ops` sudo — it seeds a guest its operator converges (#177).
- `--disk` on a clone whose source has no root device of its own refuses
  before anything is created: a copy-time override replaces a profile's root
  device rather than merging onto it, leaving a size with no type or path
  (#171).
- The refusal says nothing was created, that the other flags went nowhere
  either, and offers the two routes box has watched work — drop `--disk`, or
  mint fresh with it (#171).
- A source box could not read — absent, or an incus that did not answer — is
  refused the same way, and the message says so instead of blaming a profile
  box never saw (#171).
- Cloning a container with `--disk` keeps the answer it always had: the note
  that a container's root rides the pool, now on the `--from` path too, and
  the clone proceeds (#171, #57).
- `box new --help` carries what a root resize actually does: on `dir` and
  `btrfs` a running instance takes the size, reports it, and defers it to the
  next start (#171, #29).
- Release and repository governance move to the shared ceremony pinned at `0.7.4`, six minor releases on from `0.1.0` (#168).
- Changelog entries are per-issue fragments under `changelog.d/` instead of lines under a shared `## Unreleased` heading, so two open PRs no longer conflict by construction (#168).
- The labels automation is two callers: `labels.yml` carries the events, `labels-sweep.yml` carries the reconcile sweep and the hourly cron, which moved rather than being copied (#168).
- `box new` now takes named sizes: `--size small|medium|large`, resolved most-specific-first — an explicit `--cpu`/`--memory`/`--disk` flag, then the `BOX_*` environment, then the size, then the seed's own default (#159).
- Retired agent template spellings — `--template claude-box` and its siblings — refuse and teach the current mint form instead of minting something unexpected (#159).
- `drill/drill.sh --help` names every phase the drill runs. Its window cut the
  list off after four of eight, and those four described a drill two releases
  old (#154).
- `drill/README.md` documents the drill that exists: eight phases in print
  order with their probe counts, `box expose` and the migration path among
  them, and the probe floor and record emitter it never mentioned (#154).
- The drill no longer warns that it leaves `dns.mode=none` and NIC filtering
  applied to the host. Phase D stopped rehearsing the hardening when it
  shipped, so a run leaves nothing of its own to revert (#154).

### Fixed

- The release drill pins Incus to the admin `default` project, follows the automatic `pristine` snapshot contract, cleans legacy profiles across every project, and keeps summary failures out of its probe ledger (#263).
- A `BOX_INSTALLED_FROM` carrying a newline is refused before anything is installed, so the one-line `INSTALLED_FROM` contract cannot be broken into a file whose readers see only its first line (#250).
- `box import` now refuses pre-0.10.0 artifacts that name the retired `box-net` placement profile with the version boundary, re-creation advice and an unsupported manual recovery route, before Incus or the host-stack check can mislead (#241).
- Pinned ceremony workflows and doctrine to 0.7.7 so taxonomy bootstrap can create `operator` and survive its dedicated queue. (#237).
- `setup-host` now converges `boxnet`'s `ipv6.address=none` and `ipv4.nat=true` on every run, not only at create. A bridge that drifted off the isolation contract was detected by every tool and repaired by none (#227).
- `setup-host` converges a drifted `boxnet` `ipv4.address` only when no instance is attached. With boxes on the bridge it names the drift, prints the command that fixes it, changes nothing and exits 0 — renumbering a live bridge strands every lease (#227).
- `box doctor` judges `boxnet`'s `ipv4.address` instead of merely printing it, and `--fix` gained an `ipv6.address` arm. On the state measured while preparing the 0.10.0 drill, the verdict's own advice could not reach it (#227).
- `box doctor`'s verdict now separates what `--fix` can reach from what needs the boxes down first, and names the key it will not touch and why (#227).
- The drill refuses a dirty worktree and names the dirty paths; `--allow-dirty` runs anyway and stamps the record's ref field `-dirty`, so an unreproducible record says so (#225).
- The install and its verification resolve their destination by uid, the way `install.sh` does. A root run is refused up front by uid instead of failing later with a wrong diagnosis about a stale script (#225).
- CI's seven ceremony guards now run independently, so a red `drill-recorded` on a release cut no longer skips `changelog-monotonic`, `changelog-assembled`, `docs-sync`, `runner-isolated` and `sha-pinned`. A red guard still fails the job (#224).
- Every ordinary box now evicts untouched `/tmp` scratch after a day instead of Debian's ten, so the 1GiB cap stops filling with earlier sessions' leftovers. Newly minted boxes only — `write_files` runs once, so an existing box keeps the 10-day age (#208).
- The seed's `/etc/tmpfiles.d/tmp.conf` masks Debian's file rather than merging with it, so it restates `/var/tmp` at its stock 30 days; omitting that line would have silently dropped `/var/tmp`'s cleanup (#208).
- `CONTRIBUTING.md`'s review panel names the three accounts `.github/labels.conf`
  requests. It had kept a fourth, dropped from the governing file on 2026-08-19,
  so the document a contributor reads named a reviewer no PR since has had
  (#198).
- `setup-host` no longer ignores `BOX_STORAGE_SOURCE` in silence on a host that already has a pool: it names the live source and the requested one and exits non-zero. A pool is created once, so moving one is a migration, not a re-run (#180).
- A failed storage preseed no longer falls back to `incus admin init --minimal` when a placement was requested — minimal cannot carry a source, so the fallback would have put the pool on the root disk anyway (#180).
- `BOX_STORAGE_SOURCE` reaches Incus exactly as typed: it is emitted as a quoted YAML scalar, so a path containing a space or ` #` places the pool where it names rather than at the prefix before YAML's comment marker (#180).
- `setup-host` and `box doctor` read the pool's source past the first space, so a source with a space in it is reported whole rather than truncated to its first word — a wrong answer to "where do my boxes live" (#180).
- Re-running `setup-host` with a block device checks the disk that path names now, not just the path recorded when the pool was made: a device name can move between reboots, and "already placed there" about another disk is the silence this check exists to remove (#180).
- `BOX_STORAGE_SOURCE` refuses a path containing a newline or a tab. YAML folds a line break inside a quoted scalar to a space, so the value could not have reached Incus as typed (#180).
- The default seed declares `BOX_NO_CONTAINER_FALLBACK`, so every ordinary box fails on a KVM-less host instead of silently minting a container, while an explicit `--container` remains available (#175).
- Install and configure chrony in every template so guests correct multi-hour clock drift after a host suspend (#174).
- `box import` on the restricted tier is refused before the transfer, not
  after it. A restricted project rejects the low-level `volatile.*` config
  every artifact carries, and incus said so only once the whole disk had
  landed (#160, #156).
- The refusal names your tier, the project it puts you in, every key the
  artifact carries and who can land it instead — rather than an incus error
  about a key you never set (#160).
- `box import --force` skips that refusal and hands the artifact to incus
  anyway. The refusal is read off the artifact and only the VM case has been
  measured, so an inference can never be the last word on your own file
  (#160).
- That override is priced where it is offered: if the project really does
  refuse, `--force` costs the whole transfer and then incus's error — the
  cost the refusal exists to save (#160).
- `box help import` says all of this up front, so the tier's one-way export
  is known before a multi-GB copy proves it (#160).
- The drill asserts how much it ran, not only what passed: a phase that never executed was a clean sweep and exit 0 (#153).
- `DRILL_EXPECT` must be a whole number — a typo is refused by name at startup, instead of leaking a bash error into the summary (#153).
- The drill, doctor and multi-user rehearsal honour `NO_COLOR` and drop ANSI when their output is not a terminal (#152).
- The drill's group re-exec interpolates nothing into shell source, so an apostrophe or a space in a path, ref or run ID no longer kills the run (#152).
- `--keep-boxes` survives the group re-exec as `DRILL_KEEP`; it was reset to off before the stage that tears down and writes the record could read it (#152).
- A candidate ref that is an annotated tag records the commit it points at, not the tag object, which is hex and passed for one (#152).
- `bin/box` captures multi-line Incus output before line readers inspect it, preventing SIGPIPE races from turning existing state into a false absence (#134).

### Removed

- `box migrate-host` and `host/migrate-host.sh` are gone. A host still on the pre-0.4.0 stack must install box `0.9.1` or earlier and migrate with that before taking this release (#226).
- Drill phase M went with them: it built a pre-0.4.0 stack on every run to prove a transition no user is left to take. The probe floor moves from 81 to 71 (#226).
- `drill/doctor.sh` no longer reports the pre-rename profile as lingering, nor probes DNS from a pre-rename box — both named a migration the tool can no longer perform (#226).
- What leaves is the migration *feature*, not support for the old stack: `box` still recognises a pre-rename box under every verb, and `teardown-host`, `setup-host`'s coexistence guards and `drill/wipe.sh` are untouched (#226).
- **BREAKING** — box no longer installs or runs a converger. Every `box new` mints a blank box: the mint hook, its pin, the `user.box.rig.*` and `user.box.role` stamps, and the seeds' installer line are all gone (#212, #214).
- `box new --role <role>` is gone. It refuses loudly rather than reading as an unknown flag, and teaches the replacement in full; the retired `--template claude-box` and its siblings now teach a blank mint too (#159, #214).
- `RIG_REPO` and `RIG_REF` are inert: box reads neither and warns about neither. A mint makes no network request of its own, so a box mints on a host that cannot reach github.com (#150, #214).
- Removed the automatic `bootstrapped` snapshot: box no longer watches convergence, so it will not label a state it cannot validate. The `pristine` mint snapshot and existing named restores remain available. (#130, #212, #213).

## 0.9.1 — 2026-08-04

### Fixed

- `box exec` preserves newlines and command argv across its login-user boundary (#169)

### Changed

- Release and repository governance now use the shared ceremony pinned at `0.1.0` (heavy-duty/ceremony#14)

### Added

- `kimi-box` template — the Moonshot Kimi CLI agent seed (#158; rig#109's tenant)

## 0.9.0 — 2026-07-21

### Added

- `box import` stamps the trip, leaving the artifact's own mint stamp intact
  (#131)
- A minted box records how it was minted, and `box info` reads it back (#103)
- A clone re-stamps its own provenance instead of inheriting its source's
  (#103)
- `box info` grew a provenance block, blank on boxes that predate the stamp
  (#103)
- Every fresh mint marks a `pristine` snapshot, before rig converges anything
  (#104, heavy-duty/rig#62)
- A mint that converges a tenant role marks a `bootstrapped` snapshot (#130)
- CI refuses a release PR with no drill record at `drills/<version>.md`

### Changed

- `state:needs-human` is set at handoff, not by the cron (#141)
- PR labels split into two axes: `state:*` (whose ball) and `blocker:*` (what
  is in the way); `state:needs-rebase` is retired
- BREAKING: the tenant templates carry rig's family suffix — `claude` →
  `claude-box`, `codex` → `codex-box`, `grok` → `grok-box`, `staging` →
  `staging-box` (#123, heavy-duty/rig#76)
- Changelog entries are one line each, and the whole file now follows the rule
  (#147)

### Fixed

- `test/release.sh` is green on the release ceremony's own tree
- `changelog-monotonic.sh` no longer lets a duplicate heading through when it
  cannot see the base (#143)
- An unreadable check rollup no longer reads as "nothing is failing"
- `state:needs-human` no longer appears on PRs a human cannot merge (#136)
- CI's shellcheck sweep now lints `.github/scripts/*.sh` (#116)
- A PR can no longer delete or duplicate a shipped changelog section and stay
  green (#122)
- An upgrade over a pre-0.7.0 flat `/opt/box` no longer skips host setup (#115)
- Host setup runs the version it just installed, not whatever `current` points
  at (#115)
- The pre-0.7.0 migration says what it left behind, and how to keep or reap it
  (#117)
- `teardown-host.sh` refuses a terminal-less run instead of aborting mute
  (#113)
- `drill/wipe.sh` no longer carries #102's SIGPIPE shape, and the pin sweeps
  the class (#107)
- The racing-reader sweep guards the class, not one spelling, and names
  `incus config trust list` as a second writer (#124)

## 0.8.0 — 2026-07-19

### Added

- Merging the release PR is the release, and the release re-arms main itself
  (#96)

### Fixed

- The release ceremony re-arms `CHANGELOG.md`, and CI refuses to let main sit
  disarmed (#108, heavy-duty/rig#67)
- Ctrl-D at a confirmation prompt aborts out loud instead of exiting in
  silence (#111)
- `box restore` asks before it destroys, in the row's own words rather than
  `rm`'s (#105)
- `box-firewall` could hand a UFW host the no-UFW firewall, ~2% of the time
  (#102)
- A missing firewall log now diagnoses itself (#102)
- `box grant` provisions an `incus-admin` member instead of refusing them
  (#99)

## 0.7.0 — 2026-07-19

### Added

- The installer defaults to the latest release, and releases publish
  themselves (#83)
- `setup-host` auto-picks a free subnet — nested box-in-box with zero flags
  (#80)
- `setup-host` refuses a claimed subnet, and `BOX_SUBNET` picks another (#80)
- `box doctor` knows the #80 signature: a gateway held as a local address, and
  duplicate connected routes for the uplink subnet
- The `staging` template — a server-class, creds-free seed (#81)
- The `BOX_BOOTSTRAP_ROLE` template key, auto-run at mint (#81)
- The rig pin point: `RIG_REPO` / `RIG_REF` (#81)
- Server-posture template keys `BOX_REQUIRE_VM` and `BOX_AUTOSTART` (#81)
- The template test suite discovers `templates/*/` instead of hardcoding the
  list (#81)
- `box export` / `box import` — a box's state that survives the box and the
  host (#70)
- Versioned installs at `<root>/versions/<v>`, with `box versions` and
  `box use` (#66)
- A real uninstall: `box uninstall [<version>] [--all] [--purge-host]`, ending
  in an absence assert
- `BOX_INSTALL_SOURCE=<dir-or-tarball>` installs from a local tree, and CI's
  rehearsal drills the uninstall to zero residue
- `test/cli.sh` drives real installs against throwaway roots and a fake incus
  (154 checks)

### Changed

- Thin templates — box mints a creds-free seed, rig's bootstrap roles converge
  the tenant content (#81, heavy-duty/rig#31)

### Fixed

- A wedged `incus launch` fails loudly, not forever: the launch phase is
  narrated and time-boxed (#93)
- UFW's gateway carve-out converges with the bridge, and the doctor can see it
  (#86)
- The boot-time gateway fallback is gone — an unaddressed bridge leaves the
  persisted UFW rules alone (#86)
- `revoke --purge` re-checks the incus-user state, and stats it through
  `$SUDO`
- A wedged `$BINDIR/box` no longer blocks installing

## 0.6.0 — 2026-07-18

### Added

- The restricted tier: `box grant` / `box revoke` give a user their own boxes
  on the shared hardened `boxnet` (#74)
- CI runs the multi-user rehearsal on a real Incus
- Global / root install — one world-readable tree at `/opt/box` (#71)
- CI and a test suite: `.github/workflows/ci.yml` and `test/cli.sh`

### Fixed

- `box restore` never worked against Incus 6 — it dispatched `incus restore`,
  which does not exist
- `box tmux` works on every template — tmux is in each template's package list
  (#65)
- `box setup-host` finishes in one run, re-execing itself under
  `sg incus-admin` (#63)
- `setup-host` works as root, with or without `sudo`
- `setup-host` grants `incus-admin` to the human, not to root
- `box-firewall.service` reports its state honestly, via `RemainAfterExit=yes`
- `setup-host`'s apt calls can no longer hang on the dpkg lock

### Changed

- `drill.sh` asserts the post-install stack instead of building it itself
- `install.sh` asks, sets up the host, and no-ops on re-run (#64)
- `install.sh` never overwrites an existing install

## 0.5.0 — 2026-07-15

The release the project was renamed in: the repo is `heavy-duty/box`, matching
the CLI it ships. Everything legacy-facing is honored forever — the
`user.claudebox=1` tag, the `.claudebox/` runbook folder, the old symlink the
installer retires — but nothing current carries the old name.

### Added

- `codex` and `grok` templates
- `box expose <box> <port> [<host-port>]` — a loopback-only door to a port
  inside a box
- Inline resource overrides on `new`: `--cpu`, `--memory`, `--disk` (#57)
- Host lifecycle as verbs: `box setup-host`, `box teardown-host`,
  `box migrate-host`
- The `.box/` recipe convention, renamed from `.claudebox/` (both spellings
  read)

### Fixed

- VM mints no longer hang at GRUB — boxes launch with
  `security.secureboot=false`
- `box expose` actually delivers packets
- Firewall rules converge on upgrade instead of pinning a host to the release
  that first ran there
- Failed mints tell you why
- `grok` installs the binary it actually ships

### Changed

- Debrand complete — env vars, install dir, docs, template descriptions and
  the README all say `box`; the install URL is `heavy-duty/box`
- The drill grew from 47 to 84 checks
