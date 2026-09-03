# Contributing

This repository is governed by
[heavy-duty/ceremony](https://github.com/heavy-duty/ceremony). Agents read
[`.ceremony/AGENTS.md`](.ceremony/AGENTS.md) first, then the role file it
selects. The files under `.ceremony/` are machine-managed and must never be
edited in place.

Only triage mints issues. Everyone else opens or extends a discussion when
they find work outside an existing issue contract. Only humans merge.

## Review panel

The review panel is:

- `claude-bot-andresmgsl`
- `codex-bot-andresmgsl`
- `kimi-bot-andresmgsl`

Every PR needs a current-head verdict from the whole panel minus its author.
`dan-claude-bot` is triage-only and is never a reviewer. Draft PRs remain
invisible to the panel; when ready, request every eligible reviewer.

## Code and verification

- Bash executables use `set -euo pipefail`; test harnesses use `set -u`
  because they assert failing commands.
- Keep shellcheck clean. Run `bash test/cli.sh` and `bash test/release.sh`;
  CI also runs the Incus multi-user rehearsal.
- Match whole versions: `0.7.0` must never match `0.7.0-rc1`.
- Comments preserve the incident that bought a rule, including its issue
  number.

## Changelog

Every behavior-changing PR writes one file — `changelog.d/<issue>.md` —
carrying the exact prose that will be published, and nothing else. It does
**not** edit `CHANGELOG.md`; the release PR assembles the fragments into the
next section and consumes them. Distinct filenames never conflict, which is
the whole point: the shared `## Unreleased` anchor this replaced made two
open PRs a conflict by construction, and a rebase moves the head, so each
conflict cost a full review round.

This tree is `grouped` (the sentinel at `changelog.d/shape` says so), so a
fragment carries its own `### Added` / `### Changed` / `### Fixed` heading
above its bullets. Two rules bite on every entry, and the corpus is graded
whole — one bad file reds every PR opened after it: **at most 300
characters** per entry, and **exactly one terminal `(#N).` citation**. An
entry citing a cross-repo issue goes in `changelog.d/<repo>-<N>.md`.

Never replace or duplicate a shipped heading; the shared armed, monotonic
and assembled guards enforce every half of this rule.

## Releases

The release ceremony, merge and tag doors, version stamps, guard semantics,
and recovery paths are defined by
[heavy-duty/ceremony](https://github.com/heavy-duty/ceremony/blob/0.7.7/README.md).
Box pins the shared machinery and doctrine at `0.7.7`.

Box uses the `file` version backend, and ceremony's release-artifact hook
publishes the checksummed, self-contained `box-<version>.sh` package. GitHub's
source tarball remains the source that `install.sh` downloads; the release
artifact embeds that same tree for transfer to a server. `VERSION`,
`CHANGELOG.md`, and `drills/<version>.md` remain box-owned release inputs.

### What a box drill proves

The box drill is the 71-probe VM isolation contract: it exercises the trust
boundary on real hardware. The lighter Incus container rehearsal in CI proves
the tier mechanics but cannot substitute for that boundary measurement. The
record format and operating procedure live in [drills/README.md](drills/README.md),
and what each phase proves in [drill/README.md](drill/README.md).

**`drill/drill.sh`'s header comment is its `--help` output**, printed by a line
range (`sed -n '2,68p'`) rather than by a here-doc. So a line added above that
block truncates the help silently, and prose left stale there is not stale
documentation but the answer the tool gives when asked directly — which is how
`--help` came to name four phases of eight (#154). Edit the header and the
window together; `test/cli.sh` drives the help against the probe ledger's own
phase keys, so a phase added without a header line reds.

`drills/<version>.md` and [`drill/RUNS.md`](drill/RUNS.md) are deliberately
different artifacts. The former is per-release evidence read by the release
guard; the latter is the harness’s ongoing run log and lore. Updating one
never satisfies the purpose of the other.

The family drills are independent and may run in any order. rig’s drill pins
the candidate box ref, because rig converges a box and so consumes one. box’s
drill pins no ref of rig’s: since box#214 a mint installs no converger, so a
box run has no second ref to get wrong. The box↔rig runtime recursion is
dissolved at its source rather than pinned around, and no repository needs to
release first.

That is what finally closed box#81 — released box templates defaulting
`RIG_REF` to `main`, so a later mint consumed a rig revision other than the
one drilled. box#150 had narrowed the gap by resolving an unset `RIG_REF` to
rig’s latest release; box#214 removed the mint hook, its pin and the record’s
second ref outright and left `RIG_REF` inert, so the gap has no surface left
to reopen on. A box drill’s record names one candidate ref, box’s own.

## Scope labels

- `scope:cli` — `bin/box` and its test harness `test/cli.sh`, the command surface
- `scope:installer` — `install.sh`, versioned installs, upgrade/uninstall
- `scope:host` — host setup, teardown, firewall, and isolation stack
- `scope:tiers` — grant/revoke and multi-user boundaries
- `scope:templates` — template and profile seeds
- `scope:drill` — rehearsals, doctor, and run evidence: `drill/` and `drills/`
