# drills/ — release evidence, one file per version

This directory holds the **evidence that a release was proven on real
hardware**. One file per shipped version, named exactly for the version:

```
drills/0.9.0.md
drills/0.9.0-rc1.md
```

The name must match the contents of `VERSION` exactly.
[the pinned ceremony drill-recorded action](https://github.com/heavy-duty/ceremony/tree/0.7.7/actions/drill-recorded)
refuses any tree with a bare `VERSION` that has no such file, or whose file is
blank. A `-dev` tree passes with nothing to assert.

Because each version owns a file, `0.9.0` and `0.9.0-rc1` can never be
confused for one another — they are simply different paths. That used to take
careful whole-version field matching inside one shared file; now it is free.

## The rc ladder: the record before the merge, the round after it

A release candidate's `drills/X.Y.Z-rcN.md` may be a **pending record**: it says
what the candidate is, what changed since the last drilled tree, and which phases
are owed. It is explicitly not a waiver. The gate asks for a record, not a
result. The round then runs **after the merge, against the published
`X.Y.Z-rcN` tag** (`git clone --branch X.Y.Z-rcN`), and its record is appended
to the same file. The final `X.Y.Z` is promoted only once a candidate's round is
appended and green. A pending record is never carried forward as evidence for
the final. This matches heavy-duty/crew's ladder; the ladder itself is
[`.ceremony/RELEASES.md`](../.ceremony/RELEASES.md)'s.

## This is not `drill/RUNS.md`

Two different artifacts, and the distinction is load-bearing:

| | what it is |
|---|---|
| [`drill/RUNS.md`](../drill/RUNS.md) | the **harness's own history** — every run of `drill/drill.sh`, the traps table, the lore about what broke and why. It is not release-scoped and it is not going anywhere. |
| `drills/<version>.md` | **release evidence** — the record that *this version* was drilled before it shipped. Release-scoped, one file, gated by CI. |

Appending to `drill/RUNS.md` does not satisfy the release gate, and is not
meant to. Keep using it for what it has always been for.

## What a record should contain

- **What ran** — which drill, how many probes, `drill/drill.sh` invocation.
- **On what host** — the machine, the OS, the Incus version. "Real hardware"
  is the claim; name the hardware.
- **The candidate refs** — the exact box checkout ref / `CAST_REF` under test,
  and the other repos' commit SHAs. A drill that does not say what it drilled
  proves nothing later. Box's is no longer a ref anyone pins: since #225 the
  drill measures repo, ref and SHA off the checkout it runs from, so the
  record names the tree that ran rather than the one an operator meant to
  name. And box's record names no converger ref since #214: box installs
  nothing into a guest, so there is no such ref to pin and naming one would
  claim a dependency box does not have.
- **The shared run ID**, so this record reconciles with the sibling repos'.
- **The numbers** — passed, failed, how long it took.
- **What failed**, plainly.

**A failed drill is still a valid record.** The gate wants *evidence*, not
success. A record saying "83/85, criterion (m) regressed, here is the issue"
is a good record. So is a maintainer's written waiver explaining why this
release shipped without a full drill. What the gate refuses is silence — #95,
#114 and #148 all shipped unproven because a skip left no trace.

## The drill writes the first draft

Everything above except the prose is a field `drill/drill.sh` already knows, so
it emits them rather than leaving them to be retyped out of coloured terminal
output at the end of a forty-minute run (#152):

```
git checkout release/0.10.0
bash drill/drill.sh --emit-record drills/0.10.0.md
```

The checkout is the subject: the drill installs the tree it runs from and there
is no ref to pass it, so the `git checkout` above is what selects the candidate
and the record's ref fields are measured back off it (#225).

- **`--run-id <id>`** (or `DRILL_RUN_ID`) pins the ID this release set's three
  records share. Unset, the drill generates `drill-<version>-<date>-01` — bump
  the trailing sequence by hand for a second run the same day. Either way it is
  printed as soon as the install lands, not at exit, so whoever drills rig and
  cast can use the same string while their runs are still ahead of them. This
  is the field that had no mechanism at all before: it was invented at write-up
  time, three times, and the odds the three matched were whatever memory was
  worth.
- **The numbers are the probe floor's**, not what happened to run: `72/81`, not
  `72/72`. A phase that did not run is recorded as a shortfall, and a phase
  *declared* skipped is recorded as a `SKIP` line that lowers the floor by
  exactly its probes (#153). Passing and skipped never look alike.
- **The isolation audit answers come with it**, as their own `## Audit
  answers` section: what phases A, C and E *measured* — sibling reachability,
  the DNS enumeration leak, IPv6, inbound, `incus copy`'s treatment of
  `user.*`. They are measurements and not verdicts, which is why they sit
  apart from the findings: whether `A4 dns enumeration: LEAKS` is a failure is
  what the probe beside it already decided. The drill printed them for a human
  to paste into an issue that has since closed; the record is where they are
  read now (#154).
- **`NO_COLOR=1`, or piping anywhere, drops the ANSI** from the drill, the
  doctor and the multi-user rehearsal.
- **The emitted file is refused if one already exists there.** A record is
  edited by hand after it is emitted, and overwriting one destroys the
  judgement calls that make it evidence.

**What it emits is a skeleton, not a finished record.** The judgement calls in
the worked example below — "judged not release-blocking: it affects teardown
residue on a host that is about to be wiped" — are exactly what a script must
not fabricate. So the emitted file ends with a paragraph saying it is a draft;
write what the findings mean for the release, then delete that paragraph. A
record still carrying it has not been read by anyone.

## Worked example

The version below is a **placeholder that can never be a real release**.
Copy the shape, not the number.

```markdown
# Release drill — 9.9.9

- **Run ID:** `drill-9.9.9-20260721-01` (shared with rig, cast)
- **Host:** bare Debian 13, Ryzen 7 5800X / 64 GB, Incus 6.0.2
- **Date:** 2026-07-21
- **Candidate refs:**
  - box `release/9.9.9` @ `abc1234`
  - cast `release/2.2.2` @ `9abcdef`

## What ran

`bash drill/drill.sh` — run from a checkout of `release/9.9.9`, the full
end-to-end: install the
stack, mint every template cold, snapshot and restore, uninstall to zero
residue. Then `drill/multiuser.sh` for the two-user grant matrix.

## Result

**80/81 passed, 1 failed.** 41 minutes wall clock.

- Failed: `multiuser.sh` criterion (m) — the raw instance kept a stale route
  after teardown. Filed as #999. Judged not release-blocking: it affects
  teardown residue on a host that is about to be wiped, not the trust
  boundary itself.
- The VM boundary probes (the 81-probe isolation contract) passed clean,
  which is the assertion this repo's drill exists to make.

## Audit answers

What the isolation probes measured, uninterpreted.

- A1/A5 egress + public DNS: PASS
- A2 box→host: dropped
- A3 sibling: BLOCKED — tcp dropped + no icmp reply (security.port_isolation)
- A4 dns enumeration: blocked (dns.mode=none)
- A6 ipv6: none, as contract requires
- A7 inbound host→box: dropped
- B2 copy preserves user.*: YES — #17's metadata-stamp design holds
```
