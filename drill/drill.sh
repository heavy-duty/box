#!/usr/bin/env bash
# drill.sh — end-to-end drill for box, against a real Incus.
#
#   ⚠ DESTRUCTIVE, AND MEANT TO BE. Run it on a THROWAWAY host you can format.
#     It installs Incus, rewrites the host's firewall rules, installs a systemd
#     unit, and creates and deletes instances. Never run it on a machine you care
#     about.
#
#   git clone https://github.com/heavy-duty/box && cd box
#   bash drill/drill.sh                  # asks first
#   bash drill/drill.sh --yes            # no prompt (CI, or you've read it)
#   bash drill/drill.sh --keep-boxes     # leave the boxes up to poke at
#   bash drill/drill.sh --allow-dirty    # drill uncommitted work (see below)
#   DRILL_EXPECT=90 bash drill/drill.sh  # raise the floor (a whole number)
#   bash drill/drill.sh --emit-record drills/0.10.0.md    # write the record
#   bash drill/drill.sh --run-id drill-0.10.0-20260819-01 # share one ID
#
# THE TREE UNDER TEST IS THIS CHECKOUT, always. The drill installs box by running
# the install.sh beside it against the working tree, and no flag points it
# anywhere else: to drill a branch, check that branch out (#225). It used to take
# a repository and a ref and install over the network, so the harness came from
# your checkout and the subject came from main — standing on a branch and running
# the two lines above drilled a tree nobody was reading.
#
# A DIRTY WORKTREE IS REFUSED, and so is a run as root: the record names the
# commit, which an uncommitted edit makes a lie, and box installs by uid, which
# only a non-root drill has ever exercised. --allow-dirty runs a dirty tree
# anyway and stamps the record's ref field '-dirty' — a record that cannot be
# reproduced says so on its face.
#
# The run is short unless it emits at least the expected number of verdicts:
# a phase that never executed used to report a clean sweep (#153). A skip that
# is legitimate prints a SKIP line and lowers the floor by exactly its probes.
#
# --emit-record <path> writes drills/README.md's six-item record with every
# field the harness already knows filled in (#152): the run ID, the host, the
# repository, branch and commit MEASURED from this checkout, the numbers
# against #153's
# floor, the wall clock, the findings and the isolation audit answers, all
# uncoloured (#154). It is a SKELETON — what
# a failure means for the release is a judgement a script must not fabricate,
# so the file says it is a draft until you edit that line out. --run-id (or
# DRILL_RUN_ID) pins the ID this release set's three records share; unset, it
# generates drill-<version>-<date>-01, and either way it is printed early
# enough to hand to whoever drills rig and cast.
#
# NO_COLOR (any value), or a stdout that is not a terminal, drops the ANSI.
# The summary exists to be piped somewhere; escape codes in a pasted record
# are noise, and every record before this one was transcribed past them.
#
# The phases, in the order they PRINT. The letter is the phase's ledger key and
# the bracketed number is how many verdicts a complete run of it owes (#153):
#   I. The installer's contract — the stack install.sh left, asserted before
#      anything else here touches it (#64).                                 [1]
#   A. Incus semantics — the assumptions box is built on, probed directly.
#      These were only ever verified against a stub.                        [8]
#   B. The box surface — the whole CLI, end to end, including the boundary. [45]
#   C. Isolation baseline — does the trust boundary actually hold?
#      (#15 section A)                                                      [9]
#   E. box expose — a deliberate loopback door, opened and shut (#55).      [7]
#   D. The isolation contract, STATED — not rehearsed. What it used to apply
#      live is shipped, so C tests the real stack and a run leaves no
#      D-phase mutations behind.                                           [0]
#   T. Teardown — every box the drill minted is gone, and only those.       [1]
#
# Exit 0 = every check passed AND the run was not short of that floor (#153).
# The summary ends with the isolation audit answers; --emit-record carries them
# into the record, which is where they are read now (#154).
#
# The file is one long 'probe && ok "..." || no "..."'. ok/no always return 0, so
# the C-may-run-when-A-is-true trap SC2015 warns about cannot fire here.
# shellcheck disable=SC2015
#
# NOT -e: a failing check is data, not a crash. NOT pipefail: half the checks
# are 'refusal 2>&1 | grep -q text' where the refusal exits 1/2 BY DESIGN, and
# 'grep -q' SIGPIPEs the left side on early match — pipefail turned both into
# false FAILs on the first live run. The pipeline verdict must be grep's alone.
set -u

# >>> drill settings — extracted by test/cli.sh and DRIVEN, because every one of
# these has to survive the sg re-exec below and the only proof of that is running
# it. The rule the block embodies: --in-group carries no arguments through, so
# EVERY setting the second stage needs arrives as environment, and every one of
# them reads that environment HERE rather than being clobbered to a default the
# flag can no longer change.
# There is no --repo and no --ref, and no environment pass-through behind them:
# the two installer variables that carried a repository and a ref across the sg
# re-exec are gone with the flags, and the acceptance test for this is that
# neither name survives anywhere in this file, comments included (#225).
# The subject of the drill is the checkout the harness ships in, so the
# only thing to resolve is where that checkout is: drill/drill.sh's parent's
# parent, off SELF, which readlink has already made absolute. A flag naming a
# second tree is what let the harness and the subject come from different
# commits, and it is not replaced by a safer flag — it is removed.
YES=0
# --allow-dirty is the one escape hatch, and it buys a stamped record rather
# than a silent one: see the preflight block for what it costs (D5, #225). It
# crosses the sg re-exec as DRILL_ALLOW_DIRTY, like every other pin, because the
# second stage re-runs the same refusal.
ALLOW_DIRTY="${DRILL_ALLOW_DIRTY:-0}"
# ...and what the tree WAS when it was installed, which is a different fact from
# what the tree is now and the only one a record may use (round 2, #225). The
# checkout is local and mutable and the drill runs for forty minutes on top of
# it, so every field describing the tree is measured ONCE — beside the preflight,
# before install.sh copies anything — and then carried. These five cross the sg
# re-exec like every other pin because the shell that writes the record is not
# the shell that took the measurement.
#
# Empty TREE_DIRTY means 'not yet latched', which is how a stage-1 start looks;
# the latch in the preflight block fills all five. The second stage finds them
# already set and cannot re-answer a question whose answer has since changed.
TREE_DIRTY="${DRILL_TREE_DIRTY:-}"
TREE_DIRTY_PATHS="${DRILL_TREE_DIRTY_PATHS:-}"
# The record's three tree fields, pinned from the latch through the mechanism
# record_collect already advertises: it fills only what is not already set, so a
# caller holding a better answer than the world can give at summary time simply
# supplies it. Empty here is 'nothing latched', and collection measures instead.
REC_TREE_REPO="${DRILL_TREE_REPO:-}"
REC_TREE_REF="${DRILL_TREE_REF:-}"
REC_TREE_SHA="${DRILL_TREE_SHA:-}"
# The witness the pre- and post-install guards compare against. This one does
# NOT cross the re-exec, and that is the point: it guards the window between the
# measurement and install.sh's copy, both of which are in stage 1. Past the copy
# the checkout is free to move — the record already describes what was taken —
# so a second stage holding this value could only ever refuse something legal.
TREE_IDENT=''
# KEEP crossed the exec as a bare `KEEP=`, which this line then set to 0 before
# anything could read it: --keep-boxes was inert in the second stage — the whole
# stage — so the teardown phase always ran and the record could never say the run
# had been asked to keep its boxes (#152). It crosses as DRILL_KEEP now, like
# every other pin, because a bare KEEP in an operator's environment is not a
# request to change what the drill asserts.
KEEP="${DRILL_KEEP:-0}"
# The record's two settings survive the sg re-exec below as environment, not as
# flags. Both default empty; DRILL_RUN_ID unset means "generate one once the
# installed VERSION is known", which is not a decision this line can make yet.
RECORD="${DRILL_RECORD:-}"
RUN_ID="${DRILL_RUN_ID:-}"
SELF="$(readlink -f "$0")"
# The checkout root, and the only tree this run will install (#225). Derived
# from SELF and not from $PWD: the drill is run as `bash drill/drill.sh` from
# the repository root by every document that mentions it, but a run from
# anywhere else must still drill the tree the script belongs to rather than
# whichever directory the operator happened to be standing in.
CHECKOUT="$(cd -- "$(dirname -- "$SELF")/.." && pwd)"
# A full drill is an admin rehearsal of the host stack, and that stack lives in
# the default project. INCUS_PROJECT overrides the client's saved project
# without rewriting ~/.config/incus/config.yml, so an admin who was last using
# their restricted user-<uid> project cannot accidentally drill that weaker
# surface (the failed 0.10.0 cut did exactly that, #263).
export INCUS_PROJECT=default

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1; shift ;;
    --keep-boxes) KEEP=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --emit-record) RECORD="$2"; shift 2 ;;
    --run-id) RUN_ID="$2"; shift 2 ;;
    --in-group) shift; break ;;                       # internal: see below
    # The help IS the header block above, printed verbatim, so a line added
    # there must move this window with it — 18 → 23 for the five lines the
    # probe floor added, 23 → 39 for the sixteen the record added, 39 → 54 for
    # the phase list this window used to cut off in the middle of (#154), 54 →
    # 69 for the co-location contract and the dirty-tree refusal (#225). It
    # ended on "C. Isolation baseline" while the list ran to M, which is how a
    # tool asked directly for its phases answered with four of eight. The whole
    # list is inside the window now, and test/cli.sh asserts that by driving
    # --help against the ledger's own keys rather than against a fixed string.
    -h|--help) sed -n '2,68p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "drill: unknown option: $1" >&2; exit 2 ;;
  esac
done
# <<< drill settings

# >>> group re-exec — extracted by test/cli.sh and DRIVEN against a fake `sg`,
# because the only thing that can prove a quoting rule is executing it.
#
# `sg incus-admin -c <string>` hands its argument to a SHELL, so anything
# interpolated into that string is shell SOURCE and not data. This line used to
# read `DRILL_RECORD='$RECORD' … bash '$SELF'`, and an apostrophe — legal in a
# Unix pathname, legal in a run ID, and constrained by neither --emit-record nor
# --run-id — closed the quotes and reparsed the remainder as
# a command. It exited 127 forty minutes in, on the far side of the startup guard
# that exists to catch bad record paths early (#152).
#
# So nothing is interpolated. `sg` execs with the environment intact, which is
# how --in-group has always got its settings across; the -c string is now a fixed
# literal whose only expansion is the child shell's own "$DRILL_SELF". That also
# means it does not matter which shell `sg` picks out of /etc/passwd — there is
# no quoting in it to get wrong, and no printf %q whose $'…' output would need a
# bash on the other side.
#
# The clock MUST cross: the shell that writes the record is not the shell that
# started the run, so a $SECONDS-based duration would measure from this line
# rather than the drill's start. The tree's dirtiness crosses for the same
# reason and one more: it is not merely inconvenient to re-measure on the far
# side, it is WRONG to, because by then install.sh has already copied the tree
# and the answer describes a checkout the drill is no longer running (round 2,
# #225).
reexec_in_group() {
  export IN_GROUP=1 \
         DRILL_OWNS_SETUP="$OWNS" \
         DRILL_ALLOW_DIRTY="$ALLOW_DIRTY" \
         DRILL_TREE_DIRTY="$TREE_DIRTY" \
         DRILL_TREE_DIRTY_PATHS="$TREE_DIRTY_PATHS" \
         DRILL_TREE_REPO="$REC_TREE_REPO" \
         DRILL_TREE_REF="$REC_TREE_REF" \
         DRILL_TREE_SHA="$REC_TREE_SHA" \
         DRILL_KEEP="$KEEP" \
         DRILL_RECORD="$RECORD" \
         DRILL_RUN_ID="$RUN_ID" \
         DRILL_T0="$DRILL_T0" \
         DRILL_SELF="$SELF"
  # SC2016: not expanding here is the entire fix. "$DRILL_SELF" is expanded by
  # the shell sg starts, out of the environment exported above; expanding it in
  # THIS shell is what the apostrophe defect was.
  # shellcheck disable=SC2016
  exec sg incus-admin -c 'bash "$DRILL_SELF" --in-group'
}
# <<< group re-exec

# >>> drill verdicts — extracted by test/cli.sh together with the ledger and the
# summary below, so the run's EXIT PATH can be executed rather than grepped.
#
# The colour is resolved ONCE, here, and every verdict reads the result (#152).
# It used to be unconditional, in a script whose whole output exists to be read
# later: piping the summary to a file gave escape codes, and the operator then
# transcribed a record past them. NO_COLOR (the convention: set, any value,
# even empty) and a stdout that is not a terminal both mean plain. The variables
# stay defined either way, so nothing below has to ask a second time — which is
# what keeps this block self-contained enough for the harness to source.
if [ -n "${NO_COLOR+x}" ] || [ ! -t 1 ]; then
  C_G=''; C_R=''; C_Y=''; C_B=''; C_0=''
else
  C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_B=$'\033[1m'; C_0=$'\033[0m'
fi
pass=0; fail=0; findings=(); audit=()
ok()   { printf '  %sPASS%s  %s\n' "$C_G" "$C_0" "$*"; pass=$((pass + 1)); tally; }
no()   { printf '  %sFAIL%s  %s\n' "$C_R" "$C_0" "$*"; fail=$((fail + 1)); findings+=("FAIL: $*"); tally; }
note() { printf '  %sNOTE%s  %s\n' "$C_Y" "$C_0" "$*"; findings+=("NOTE: $*"); }
summary_no() { # a summary verdict is a failure, but not one of the phase probes
  printf '  %sFAIL%s  %s\n' "$C_R" "$C_0" "$*"
  fail=$((fail + 1)); findings+=("FAIL: $*")
}
inf()  { printf '        %s\n' "$*"; }
phase(){ PHASE="$1"; shift; printf '\n%s══ %s%s\n' "$C_B" "$*" "$C_0"; }
aud()  { audit+=("$*"); }                       # a measurement, for the record
# <<< drill verdicts

# >>> probe ledger (#153) — test/cli.sh extracts this block verbatim; keep it
# self-contained (it may assume only `findings`, declared above).
#
# The drill used to count what it RAN and never how much it SHOULD have run, so
# a phase that never executed reported a clean sweep: "71 passed, 0 failed",
# exit 0, and nothing on the line to say twelve isolation probes never fired.
# That number does not stay in a terminal — it is transcribed into
# drills/<version>.md as the evidence a release was proven, and read months
# later by someone with no way to know the run was short. A drill that silently
# drills LESS code is the same defect as one that silently drills the WRONG
# code, which this script already refuses three hundred lines down.
#
# So every phase declares how many verdicts a COMPLETE run of it emits, ok/no
# tally against whichever phase is open, and the summary asserts the numbers as
# a FLOOR — a floor and not an equality, so adding a probe does not turn the
# commit that adds it red. Bumping the number below is part of adding one,
# which is also what finally gives CONTRIBUTING's "81-probe contract" and
# drills/README.md's worked ratio something that checks them. The header block
# above states each phase's count too, and 'test/cli.sh' asserts the two
# agree by INTEGER and not merely by phase key — #214 moved B from 51 to 45
# and left the header saying 51, which is the drift a key-only check reads as
# green.
#
# Phase keys are the letters the phase headers already use; '-' is a phase that
# emits no verdicts at all (install, host setup, the summary itself). A verdict
# emitted under '-' lands in the '?' bucket and is reported, because an
# unattributed probe means this table has drifted from the script.
PHASE_ORDER=(I A B C E D T)
declare -A PHASE_EXPECT=(
  [I]=1     # install.sh left a complete host stack (#64)
  [A]=8     # A1–A6, A8, A9 — Incus semantics (A7 prints, it does not judge)
  [B]=45    # the box surface: dedicated seed/version 5 + blank 10 + #171 clone 3
            # + the drill box, its clone and the CLI contract 27. It was 51 until
            # #214 took the role axis out: the two per-role mints proved a payload
            # box no longer installs (6 probes), and the drill box's own two agent
            # probes became two seed-payload probes, which is a swap and not a cut.
  [C]=9     # C1–C7, plus archive-is-up and the peer clone
  [E]=7     # box expose: add, list, info, the door, per-port, remove, shut
  [D]=0     # D states the settled contract; it judges only a failed baseline
            # M was migration — 10 probes that built a pre-0.4.0 stack to prove
            # a transition nobody is left to take. Phase and feature retired
            # together, because a migration path with no drill behind it is a
            # claim this repo does not make (#226).
  [T]=1     # teardown: every box the drill minted is gone
)
declare -A PHASE_RAN=() PHASE_WAIVED=()
PHASE=-

tally() {   # attribute a verdict to the open phase. ok/no must still return 0.
  case "$PHASE" in
    -|'') PHASE_RAN[?]=$(( ${PHASE_RAN[?]:-0} + 1 )) ;;
    *)    PHASE_RAN[$PHASE]=$(( ${PHASE_RAN[$PHASE]:-0} + 1 )) ;;
  esac
  return 0
}

# A legitimate skip DECREMENTS the expectation and SAYS SO on its own line, and
# lands in findings so it survives into the record. The expectation is never
# quietly tuned down to whatever the weakest run happens to produce — that is
# the failure this whole ledger exists to prevent, one level in.
skipped() {   # skipped <phase-key> <n> <why>
  local k="$1" n="$2"; shift 2
  PHASE_WAIVED[$k]=$(( ${PHASE_WAIVED[$k]:-0} + n ))
  # ${C_Y:-} and not "$C_Y": the colour belongs to the verdicts block above, and
  # this one's contract is that it assumes only `findings`. Sourced alone by the
  # harness it prints plain, which is what the harness wants anyway (#152).
  printf '  %sSKIP%s  %s\n' "${C_Y:-}" "${C_0:-}" "$*"
  findings+=("SKIP: $* [$k: $n probe(s) not expected this run]")
}

ledger_want() {   # what phase <k> owes THIS run, after declared skips
  local k="$1"
  printf '%s' "$(( ${PHASE_EXPECT[$k]:-0} - ${PHASE_WAIVED[$k]:-0} ))"
}

ledger_declared() {   # the table's own total — the "85" the docs quote
  local k t=0
  for k in "${PHASE_ORDER[@]}"; do t=$(( t + ${PHASE_EXPECT[$k]:-0} )); done
  printf '%s' "$t"
}

ledger_waived() {
  local k t=0
  for k in "${PHASE_ORDER[@]}"; do t=$(( t + ${PHASE_WAIVED[$k]:-0} )); done
  printf '%s' "$t"
}

# The floor for the whole run. DRILL_EXPECT is the operator's override of the
# table's total (raise it to demand more, never to excuse a short run); declared
# skips decrement whichever total is in force.
ledger_expected() {
  printf '%s' "$(( ${DRILL_EXPECT:-$(ledger_declared)} - $(ledger_waived) ))"
}

# A typo'd override must SAY it was a typo. DRILL_EXPECT=abc used to reach the
# arithmetic above and leak 'abc: unbound variable' into the summary, printing
# "1 of  expected probes" — it failed safe (the shortfall verdict does not
# depend on the total) but left the operator to infer the cause from a mangled
# line. Checked once at startup instead, where they can still fix it.
ledger_check_expect() {
  case "${DRILL_EXPECT:-0}" in
    *[!0-9]*)
      echo "drill: DRILL_EXPECT must be a whole number, got: ${DRILL_EXPECT}" >&2
      return 2 ;;
  esac
  return 0
}

ledger_short() {   # every phase that came up short, as ' K(got/want)'
  local k want got out=""
  for k in "${PHASE_ORDER[@]}"; do
    want="$(ledger_want "$k")"; got="${PHASE_RAN[$k]:-0}"
    [ "$got" -lt "$want" ] && out="$out $k($got/$want)"
  done
  printf '%s' "$out"
}

ledger_line() {   # the per-phase counts a single total can never make obvious
  local k out="" waived=0
  for k in "${PHASE_ORDER[@]}"; do
    out="$out  $k ${PHASE_RAN[$k]:-0}/$(ledger_want "$k")"
    waived=$(( waived + ${PHASE_WAIVED[$k]:-0} ))
  done
  [ "${PHASE_RAN[?]:-0}" -gt 0 ] && out="$out  ?${PHASE_RAN[?]} (unattributed — the ledger has drifted)"
  [ "$waived" -gt 0 ] && out="$out   [$waived waived by declared skips]"
  printf '  probes %s\n' "$out"
}
# <<< probe ledger

# >>> drill record (#152) — test/cli.sh extracts this block verbatim and drives
# it, so keep it self-contained: it may assume the verdict helpers and the probe
# ledger above it, and nothing else the script declares. Everything else it
# needs arrives as an argument or as one of the REC_* variables below.
#
# drills/README.md asks a record for six things, and this harness knew five of
# them all along while printing none in that shape. So every record was retyped
# by hand out of ANSI-coloured terminal output at the end of a forty-minute run,
# by someone who then had to reconstruct what the host had been. The sixth — the
# run ID that makes box's, rig's and cast's records reassemble into one picture —
# had no mechanism at all: it was invented at write-up time, independently, three
# times, and the odds the three matched were whatever memory was worth.
#
# The split is the whole design. record_collect() touches the world (uname,
# incus, /etc/os-release, the network) and record_write() touches nothing but
# the REC_* set, so the SHAPE of a record is drivable by a test on a host with
# no Incus, no drill and no network.
#
# What the harness must never write is prose. "Judged not release-blocking: it
# affects teardown residue on a host that is about to be wiped" is a judgement,
# and a generated file that reads like a finished one is worse than no file at
# all — it invites exactly the transcription-free confidence the last two
# waivers were written under. So the emitted record ends by saying it is a
# draft, in the rendered text and not in an HTML comment nobody sees.

record_version() {   # <install-root> — the VERSION of the tree that landed
  local v
  # The root is an ARGUMENT because it is resolved by uid now (#225): a root
  # install lands in /opt/box and a per-user one in ~/.local/share/box, and a
  # function that hard-codes either reads the wrong file for half the hosts
  # that run it — silently, since a missing file becomes 'unknown'.
  v="$(cat "$1/current/VERSION" 2>/dev/null)"
  printf '%s' "${v:-unknown}"
}

# drills/README.md: "The name must match the contents of VERSION exactly", and
# the ID carries that version so a record and its run cannot drift apart. The
# trailing -01 is a sequence for a second run on the same day; bump it by hand,
# or pass --run-id, which is what a coordinated release set does anyway.
record_run_id() {   # <version> <yyyymmdd> → drill-<version>-<date>-01
  printf 'drill-%s-%s-01' "$1" "$2"
}

# "Real hardware" is the claim the record makes, so name the hardware — and name
# the virtualisation too. A drill run inside a VM is not disqualified, but a
# record that does not say so lets a reader assume bare metal, and the boundary
# this drill measures is precisely the one nested virtualisation blurs.
record_host() {
  local kernel os cpu mem virt incus
  kernel="$(uname -sr 2>/dev/null)"; kernel="${kernel:-unknown kernel}"
  # shellcheck disable=SC1091  # a data file, present on every distro box targets
  os="$( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}" )"
  os="${os:-unknown OS}"
  cpu="$(awk -F': ' '/^model name/ { print $2; exit }' /proc/cpuinfo 2>/dev/null)"
  cpu="${cpu:-unknown CPU}"
  mem="$(awk '/^MemTotal:/ { printf "%.0f GB", $2 / 1048576 }' /proc/meminfo 2>/dev/null)"
  mem="${mem:-unknown RAM}"
  virt="$(systemd-detect-virt 2>/dev/null)"; virt="${virt:-unknown}"
  incus="$(incus --version 2>/dev/null)"; incus="${incus:-not installed}"
  printf '%s / %s, %s, kernel %s, Incus %s (virt: %s)' \
    "$cpu" "$mem" "$os" "$kernel" "$incus" "$virt"
}

# The tree's own identity, MEASURED (#225). record_sha() lived here: it took a
# repo and a ref off the command line and asked a REMOTE to expand them, because
# the drill installed over the network and those two strings were the only thing
# it knew about its subject. They described what had been REQUESTED, never what
# ran — and drills/README.md's standard for a record is precisely the opposite,
# a record that does not say what it drilled proving nothing later. The subject
# is the checkout now, so the three fields are read off it with git, and the
# remote resolution, its rate-limit fallback and its 'unresolved' verdict go
# with the flag that made them necessary.
#
# All three take the checkout as an argument and none of them touch $PWD: the
# drill re-execs itself through `sg` and the shell that writes the record is not
# the shell that started the run.
record_tree_sha() {   # <dir> → the seven-char commit, or 'unresolved'
  local sha
  sha="$(git -C "$1" rev-parse --short=7 HEAD 2>/dev/null)"
  case "$sha" in
    ''|*[!0-9a-f]*) printf 'unresolved' ;;
    *)              printf '%s' "$sha" ;;
  esac
}

record_tree_ref() {   # <dir> → the branch, the tag, or 'detached' for neither
  local ref tag
  ref="$(git -C "$1" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  # A detached HEAD — which is what a `git checkout <tag>` leaves, and how a
  # release candidate is most often drilled — answers the literal string HEAD.
  # 'HEAD' names no tree to a later reader, so ask the other question git can
  # answer here: a candidate is detached ONTO something, and drills/README.md's
  # own release procedure detaches onto a release tag. That tag is the name the
  # retired --ref flag used to be handed, so recording it keeps the field
  # saying what an operator would have typed. Only an exact match counts — a
  # `describe` of "three commits past v0.10.0" is a different tree, and a
  # record that blurs the two is worse than one that admits it has no name.
  case "$ref" in
    ''|HEAD)
      tag="$(git -C "$1" describe --tags --exact-match HEAD 2>/dev/null)"
      # 'detached' at least says WHY the field names nothing, and the SHA
      # beside it is the fact that carries there anyway.
      if [ -n "$tag" ]; then printf '%s' "$tag"; else printf 'detached'; fi ;;
    *) printf '%s' "$ref" ;;
  esac
}

# The ref field a RECORD carries, which is the ref above plus the price of
# --allow-dirty: a dirty tree's record stops naming a branch anyone can check
# out and names the commit it DIVERGED from, marked. One spelling of that stamp,
# because it is produced in two places — the latch that measures the tree before
# the install, and record_collect's fallback for a caller that never latched —
# and a stamp spelled twice is a stamp that can differ (round 2, #225).
record_tree_ref_stamped() {   # <dir> <dirty:0|1> → the record's ref field
  if [ "$2" = 1 ]; then printf '%s-dirty' "$(record_tree_sha "$1")"
  else record_tree_ref "$1"
  fi
}

# The repository, off origin. A GitHub URL in any of the shapes git hands out
# reduces to the owner/repo every record before this one carried by hand, so old
# and new records stay comparable and a FORK is visible as one — the case this
# issue was measured on, where the 0.10.0 candidate lived on andriujoseba/box.
# Anything that is not a GitHub URL is carried VERBATIM rather than mangled into
# that shape: a record naming a path or a private host says so.
#
# The URL is taken APART rather than prefix-matched, and that is the whole
# subtlety. A clone made by CI or a credential helper carries `user:token@` in
# front of the host, which is still GitHub — a version of this that matched
# `https://github.com/*` sent that URL to the verbatim arm and wrote the token
# into drills/<version>.md, a file this repo COMMITS as release evidence, so
# the leak was a revocation and not a formatting slip. Splitting the authority
# off first fixes the classification and the leak with one cut, and the
# verbatim arm is rebuilt without its userinfo too: the property worth having
# is that NO credential reaches a record, not that no github.com one does.
record_tree_repo() {   # <dir> → owner/repo, the remote URL, or a stated absence
  local url host path repo bare
  url="$(git -C "$1" remote get-url origin 2>/dev/null)"
  [ -n "$url" ] || { printf 'no origin remote'; return 0; }
  case "$url" in
    *://*)   # scheme://[userinfo@]host[:port]/path
      path="${url#*://}"; host="${path%%/*}"
      case "$path" in */*) path="${path#*/}" ;; *) path='' ;; esac ;;
    *:*)     # [user@]host:path — the scp-style form, which has no scheme
      host="${url%%:*}"; path="${url#*:}" ;;
    *)       # a plain filesystem path: no authority, so nothing to take apart
      printf '%s' "$url"; return 0 ;;
  esac
  # Userinfo lives ONLY in the authority, and a literal @ inside one has to be
  # percent-encoded, so the LAST @ is the delimiter and the longest match is
  # the right cut. Everything before it is a credential and none of a record's
  # business; everything after it is the host the record should name.
  host="${host##*@}"
  # The port is matched off but kept: github.com:22 is github.com, while a
  # private host's port is part of what the verbatim arm is for. The match is
  # case-INSENSITIVE on a lowered copy, hostnames being case-insensitive: a
  # `GitHub.com` origin is the same host and its record should be as comparable
  # as any other. Only the comparison is lowered — the verbatim arm below still
  # prints the host as the remote spells it, that arm being $url minus the
  # userinfo and nothing else (round 2, #225).
  repo=''
  bare="${host%%:*}"
  if [ "${bare,,}" = github.com ]; then
    # The trailing slash comes off FIRST. Stripping '.git' before it leaves
    # 'owner/repo.git' for a `…/box.git/` origin, because the suffix the second
    # strip is looking for is no longer at the end (round 2, #225).
    repo="${path%/}"; repo="${repo%.git}"; repo="${repo%/}"
  fi
  # A reduction that produced NOTHING is not a reduction. `https://user:pw@
  # github.com` with no path yields an empty owner/repo, and an empty field in a
  # record reads as a formatting slip rather than a fact — this function's other
  # absence ('no origin remote') is a stated one. There is no owner/repo to
  # name, so the URL goes to the verbatim arm like any other URL that does not
  # reduce, credential-stripped exactly the same way (round 2, #225).
  if [ -n "$repo" ]; then
    printf '%s' "$repo"
  else
    # Rebuilt, not echoed: this is $url minus the userinfo and nothing else.
    case "$url" in
      *://*) printf '%s://%s' "${url%%://*}" "$host"
             if [ -n "$path" ]; then printf '/%s' "$path"; fi ;;
      *)     printf '%s:%s' "$host" "$path" ;;
    esac
  fi
  return 0
}

# The paths git reports as changed, one per line — the message the refusal
# prints, and the reason the refusal exists (D5, #225). Exit 0 means DIRTY, so a
# caller reads it as the question it asks. --porcelain covers staged, unstaged
# and untracked alike: an untracked file is not in the commit the record names
# either, and `install.sh` copies the whole tree, so it is in the box that ran.
record_tree_dirty() {   # <dir> → the dirty paths on stdout; 0 when dirty
  local out
  out="$(git -C "$1" status --porcelain 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# The paths git hides from every reader above — and copies into the box anyway
# (round 4, #225). `install.sh` acquires a local tree with
# `tar -C "$SRC" --exclude=.git` (install.sh:213): it excludes the VCS state and
# NOTHING else, so a file this repository ignores is installed exactly like a
# tracked one, while `--porcelain` reports a clean tree and the record names a
# public commit that does not contain it. The measured subject and the copied
# subject disagreed, and the copied one is the one that gets drilled.
#
# The class this repository ignores is `secrets.env` and `*.agekey`, so what
# falls through that gap is the secrets class: an operator with a secrets file
# beside their checkout installs it into $BOX_SHARE under a record calling the
# tree clean. The drill cannot narrow what install.sh copies — that copy is
# every caller's, CI included — so it widens what it measures instead, and the
# refusal below makes the operator's choice explicit either way.
#
# Emitted in git's own porcelain notation for an ignored path, '!! <path>', so
# the refusal, the NOTE and the dirty list can be read as one list.
record_tree_ignored() {   # <dir> → the ignored paths install.sh would copy; 0 when any
  local out
  out="$(git -C "$1" ls-files -o -i --exclude-standard 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^/!! /'
}

# The tree's CONTENT, as one comparable string (round 3, #225). The function
# above answers which paths differ from the commit; it cannot answer what is
# inside them, and between the moment the identity is latched and the moment
# install.sh finishes copying, that is the whole question — a rewrite inside an
# already-dirty path moves the bytes that get installed and moves nothing in a
# path list. So this digests everything the record CLAIMS about the tree:
#
#   · HEAD and the ref, so a commit or a `git switch` in the window is visible;
#   · --porcelain, so a path appearing or being cleaned is visible;
#   · the tracked diff and the untracked files' own hashes, so a change of
#     content with no change of status is visible.
#
# Content-addressed via git rather than sha256sum, because git is already the
# hard dependency the preflight refuses without.
#
# It digests the IGNORED files too (round 4, #225). This used to stop where
# git's own reporting stops — an ignored file being nothing the record ever
# claimed — which reasoned about the record and not about the box: install.sh
# copies ignored files like every other byte in the tree (record_tree_ignored,
# above), so one rewritten in the window moves the installed bytes exactly as a
# tracked one does. The subject of this digest is what gets copied.
record_tree_hashes() {   # <dir> <ls-files flags...> → '<path> <hash>' per file
  # -z, because a newline is legal in a path and a path list that cannot say so
  # is a list an operator can forge. hash-object without -w computes and writes
  # nothing: measuring the tree must not modify it.
  git -C "$1" ls-files --exclude-standard -z "${@:2}" 2>/dev/null \
    | while IFS= read -r -d '' p; do
        printf '%s ' "$p"
        git -C "$1" hash-object -- "$1/$p" 2>/dev/null || printf 'unreadable\n'
      done
}
record_tree_ident() {   # <dir> → one digest of the tree the record describes
  {
    git -C "$1" rev-parse HEAD 2>/dev/null
    record_tree_ref "$1"; printf '\n'
    git -C "$1" status --porcelain 2>/dev/null
    git -C "$1" diff HEAD --binary 2>/dev/null
    record_tree_hashes "$1" -o          # untracked, and not ignored
    record_tree_hashes "$1" -o -i       # ignored, and copied all the same
  } | git -C "$1" hash-object --stdin
}

# Is this a git checkout at all? Everything above answers 'unresolved', 'no
# origin remote' or clean-looking for a tree git cannot read, and each of those
# is a record that quietly says less than it appears to. The preflight asks this
# first and refuses, so the softer answers are only ever reached by a caller
# that already knows it is holding a checkout.
record_tree_is_git() {   # <dir> → 0 when git can read <dir> as a work tree
  command -v git >/dev/null 2>&1 || return 1
  # git answers 128 for "not a repository", and a caller reading this as a
  # question deserves a yes or a no rather than git's own exit codes.
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  return 0
}

# drills/README.md's worked example writes "41 minutes wall clock". $SECONDS
# cannot supply it: the drill re-execs itself into the incus-admin group and
# the shell that finishes is not the shell that started, so the clock is an
# epoch stamp carried across that exec (DRILL_T0).
record_wallclock() {   # <seconds> → the phrase, or an honest refusal to guess
  local s="${1:-}"
  case "$s" in
    ''|*[!0-9]*) printf 'wall clock not measured' ; return 0 ;;
  esac
  if [ "$s" -lt 60 ]; then printf 'under a minute wall clock'
  else printf '%s minutes wall clock' "$(( (s + 30) / 60 ))"; fi
}

# Refuse a bad record path BEFORE the drill starts formatting a host, exactly as
# the DRILL_EXPECT guard does: an operator who typo'd it must find out now, not
# in the summary forty minutes on.
#
# The overwrite refusal is the load-bearing half. The emitted file is a skeleton
# the operator then writes prose into, and that edited file is the release
# evidence the gate reads. A second run pointed at the same path would silently
# eat those judgements, so it does not get to: remove the file or name another.
record_check_path() {   # <path> — empty path means no record was asked for
  local path="$1" dir
  [ -n "$path" ] || return 0
  case "$path" in */*) dir="${path%/*}" ;; *) dir='.' ;; esac
  [ -d "$dir" ]  || { echo "drill: --emit-record: no such directory: $dir" >&2; return 2; }
  [ -w "$dir" ]  || { echo "drill: --emit-record: not writable: $dir" >&2; return 2; }
  if [ -s "$path" ]; then
    echo "drill: --emit-record: $path already exists and is not empty." >&2
    echo "  A record is edited by hand after it is emitted, so overwriting one" >&2
    echo "  destroys the judgement calls that make it evidence. Remove it, or" >&2
    echo "  emit somewhere else and merge the two by hand." >&2
    return 2
  fi
  return 0
}

# drill_stamp() lived here (#150): one key off a box's mint stamp, used to read
# back WHICH converger the mint had installed into the guest. #214 removed both
# the installation and the stamp, and it was that function's only caller — a
# reader with nothing to read is not a helper, it is a place for the question
# to come back.

# Fill the REC_* set from the world. Every field is ${...:-} against itself, so
# a caller (the test, or an operator scripting around this) can pin any one of
# them and have the rest collected around it.
record_collect() {   # <checkout-dir> <install-root> <keep-boxes:0|1> <tree-dirty:0|1>
  local prefix='' inv
  REC_VERSION="${REC_VERSION:-$(record_version "$2")}"
  REC_DATE="${REC_DATE:-$(date -I 2>/dev/null)}"
  REC_RUN_ID="${REC_RUN_ID:-$(record_run_id "$REC_VERSION" "${REC_DATE//-/}")}"
  REC_HOST="${REC_HOST:-$(record_host)}"
  # The three fields the issue exists for (D4, #225). They are MEASUREMENTS of
  # the tree that ran, not the arguments that asked for one, which is why they
  # are collected here — in the world-touching half — rather than passed in.
  REC_TREE_REPO="${REC_TREE_REPO:-$(record_tree_repo "$1")}"
  REC_TREE_SHA="${REC_TREE_SHA:-$(record_tree_sha "$1")}"
  # A dirty tree reaches this line only through --allow-dirty, the preflight
  # having refused it otherwise, and the stamp is the whole price of that flag.
  #
  # $4 is the latched INSTALL-TIME fact and not a fresh reading, which is the
  # difference between a record and a guess: this runs at the END of a
  # forty-minute drill, and the checkout it can see here is not necessarily the
  # tree that was copied into the box (round 2, #225). In the drill all three
  # fields above arrive latched and none of these fallbacks fire; they stay for a
  # caller holding no latch, for which a live reading is the only answer there
  # is — and which is only correct before anything has been installed.
  REC_TREE_REF="${REC_TREE_REF:-$(record_tree_ref_stamped "$1" "$4")}"
  # ONE candidate ref, box's own (#214). The record used to carry a second —
  # the converger the mint installed into every guest, read off the mint's own
  # stamp — because box pinned it and a drill has to name what it drilled.
  # Box installs nothing into a guest now, so there is no second ref, no stamp
  # to read it off, and nothing here to fall back to. The shared RUN ID stays:
  # it is a cross-repo record convention that lets box's, rig's and cast's
  # records reassemble into one picture, and it never was a dependency.
  REC_ELAPSED="${REC_ELAPSED:-}"
  if [ -z "$REC_ELAPSED" ] && [ -n "${DRILL_T0:-}" ]; then
    REC_ELAPSED="$(( $(date +%s) - DRILL_T0 ))"
  fi
  # The command that reproduces this run, env pins included — the flags alone
  # would name a different drill than the one that ran. The converger pin is
  # gone from this prefix with the thing it pinned (#214): box reads no such
  # variable at mint, so carrying one here would name an environment that
  # changes nothing and read as a dependency box no longer has.
  #
  # It names no repo and no ref any more, and that is the point rather than an
  # omission: the tree is the checkout, so the line that reproduces the run is
  # the line the quickstart already prints, run from the commit the field above
  # names. A --repo/--ref pair here described the request and not the run (#225).
  [ -n "${DRILL_EXPECT:-}" ] && prefix="${prefix}DRILL_EXPECT=$DRILL_EXPECT "
  inv="${prefix}bash drill/drill.sh"
  [ "$3" = 1 ] && inv="$inv --keep-boxes"
  # --allow-dirty changes what was drilled at least as much as --keep-boxes
  # does, so it is in the line too — off the latched reading of the TREE rather
  # than off the flag the operator typed, for the same reason every other field
  # here is a measurement.
  [ "$4" = 1 ] && inv="$inv --allow-dirty"
  REC_INVOCATION="${REC_INVOCATION:-$inv}"
  return 0
}

# The backticks below are MARKDOWN, in single-quoted printf formats whose only
# expansions are %s. SC2016 reads them as command substitutions that will not
# expand, which is exactly right and exactly not the point.
# shellcheck disable=SC2016
record_write() {   # <path> — composes the REC_* set and the ledger into a record
  local path="$1"
  {
    printf '# Release drill — %s\n\n' "$REC_VERSION"
    printf -- '- **Run ID:** `%s`\n' "$REC_RUN_ID"
    printf -- '- **Host:** %s\n' "$REC_HOST"
    printf -- '- **Date:** %s\n' "$REC_DATE"
    printf -- '- **Candidate refs:**\n'
    printf -- '  - box `%s` @ `%s` (%s)\n' "$REC_TREE_REF" "$REC_TREE_SHA" "$REC_TREE_REPO"
    printf '\n## What ran\n\n'
    printf '`%s`\n\n' "$REC_INVOCATION"
    # The denominator is the FLOOR, never pass+fail. #153 is the whole reason:
    # a run that emitted 76 of 85 and failed none is not "76/76 passed", and a
    # record carrying that fraction is the exact artifact that issue exists to
    # stop being written. Declared skips are subtracted and named below.
    # Two facts, not a fraction: DRILL_EXPECT can raise the floor ABOVE the
    # table's own total, and "90 of the 85 declared" reads like an error where
    # it is the operator deliberately demanding more than the table admits.
    printf 'Probe floor: %s expected this run; the table declares %s.\n\n' \
      "$(ledger_expected)" "$(ledger_declared)"
    printf '```\n%s\n```\n' "$(ledger_line)"
    printf '\n## Result\n\n'
    printf '**%s/%s passed, %s failed.** %s.\n\n' \
      "$pass" "$(ledger_expected)" "$fail" "$(record_wallclock "$REC_ELAPSED")"
    # SKIP lines land here beside FAIL and NOTE, each carrying its own prefix,
    # so a phase that did not run is recorded as skipped and is never mistaken
    # for one that passed.
    if [ "${#findings[@]}" -gt 0 ]; then
      printf -- '- %s\n' "${findings[@]}"
    else
      printf -- '- Nothing to report: no FAIL, no NOTE, no declared skip.\n'
    fi
    # The audit answers, in the record rather than only on a terminal. They were
    # printed for a human to paste into an issue that is now closed, in a repo
    # that has been renamed, while the record they belong in was being written
    # forty lines away — the same retyping-from-ANSI defect this emitter exists
    # to close, one field further in (#152, #154).
    #
    # Their own section and NOT more findings, for two reasons. They are
    # measurements, not verdicts: "A4 dns enumeration: LEAKS" is a fact about
    # the host, and whether it is a failure is what the ok/no beside it already
    # decided. And folding them into `findings` would mean the list is never
    # empty on a real run, retiring the "Nothing to report" line that is the
    # only way a record says a clean run was clean.
    if [ "${#audit[@]}" -gt 0 ]; then
      printf '\n## Audit answers\n\n'
      printf 'What the isolation probes measured, uninterpreted.\n\n'
      printf -- '- %s\n' "${audit[@]}"
    fi
    printf '\n> **Draft — a generated skeleton, not yet a record.** Every field\n'
    printf '> above is what the harness observed. What each finding MEANS for\n'
    printf '> the release is a judgement it must not fabricate: write that, then\n'
    printf '> delete this paragraph (#152).\n'
  } > "$path"
}
# <<< drill record

# >>> drill preflight (#225) — extracted by test/cli.sh and DRIVEN. Everything
# here is a refusal, and a refusal that has never been executed is a guess about
# what the script does. Keep it self-contained: it may assume the record block
# above it (record_tree_*) and nothing else.
#
# All three guards answer the same question — is the tree in front of us the
# tree this run will install and name? — and all three run BEFORE the consent
# prompt, beside the DRILL_EXPECT and record-path guards, because an operator
# who cannot run this must find out in the first second and not in the summary
# forty minutes on.

# Where install.sh will put the tree, resolved the way install.sh resolves it
# (install.sh:39-45). The drill used to wipe and then verify ~/.local/share/box
# unconditionally while the installer chose by uid, so a root run installed to
# /opt/box, the verification file it read never existed, and the mismatch fired
# a FATAL that told the operator their local drill.sh was stale — a confidently
# wrong diagnosis of a path bug. BOX_HOME and BOX_BIN win here exactly as they
# win there; a drill that ignored them would verify a directory the install had
# been told not to use.
resolve_install_paths() {   # <uid> — sets BOX_SHARE and BOX_BINDIR
  if [ "$1" -eq 0 ]; then
    BOX_SHARE="${BOX_HOME:-/opt/box}"
    BOX_BINDIR="${BOX_BIN:-/usr/local/bin}"
  else
    BOX_SHARE="${BOX_HOME:-$HOME/.local/share/box}"
    BOX_BINDIR="${BOX_BIN:-$HOME/.local/bin}"
  fi
}

# ...and then refuse uid 0 anyway, up front and by name. Resolving the paths is
# not the same as supporting the run: every phase below assumes the operator is
# a non-root member of incus-admin — that is what the sg re-exec is for, what
# `sudo` is used for, and the tier `box` reports for uid 0 is admin, not the
# restricted one phases C and E measure. No root run has ever been drilled, and
# a drill that half-works is the failure mode this whole issue is about. So the
# answer is a refusal that says which uid it saw and what to do instead, never
# a diagnosis about a stale script (D6, #225).
preflight_uid() {   # <uid> — 0 to proceed
  [ "$1" -eq 0 ] || return 0
  echo "drill: REFUSING to run as root (uid 0)." >&2
  echo "  box installs by uid — root installs globally to /opt/box, a normal" >&2
  echo "  user to ~/.local/share/box — and every phase here assumes the second:" >&2
  echo "  the incus-admin re-exec, the sudo calls, and the tier box reports." >&2
  echo "  Run it as the ordinary operator account you would use box from:" >&2
  echo "    bash drill/drill.sh --yes        # NOT under sudo" >&2
  echo "  It calls sudo itself for the parts that need root." >&2
  return 2
}

# One printer for both path lists, and the reason it counts (round 4, #225). An
# ignored tree can be thousands of files — a node_modules, a build directory —
# where a dirty one rarely is, and a refusal that prints all of them buries its
# own explanation. So the LISTING is capped and says that it is. Nothing about
# the measurement is: the refusal itself, TREE_DIRTY and the witness are over
# everything git can see.
TREE_PATHS_MAX=20
preflight_paths() {   # <paths> — print them indented, at most TREE_PATHS_MAX
  local n
  n="$(printf '%s\n' "$1" | grep -c .)"
  printf '%s\n' "$1" | head -n "$TREE_PATHS_MAX" | sed 's/^/    /' >&2
  if [ "$n" -gt "$TREE_PATHS_MAX" ]; then
    echo "    …and $((n - TREE_PATHS_MAX)) more" >&2
  fi
}

# The tree, and the one new failure mode co-location introduces (D5, #225).
# Before this change the ref was a name the operator typed and the tree was
# whatever the network served; now the tree is local and mutable, so an
# uncommitted edit would put a SHA in the record that is not what ran — the
# same class of untruth this issue closes, re-entered by the back door.
preflight_tree() {   # <dir> <allow-dirty:0|1> — 0 to proceed
  local paths ign headline
  if ! record_tree_is_git "$1"; then
    echo "drill: $1 is not a git checkout, or git is not installed." >&2
    echo "  The drill installs the tree it runs from and the record names that" >&2
    echo "  tree's commit, so a tree with no commit to name cannot be drilled:" >&2
    echo "    git clone https://github.com/heavy-duty/box && cd box" >&2
    echo "    bash drill/drill.sh --yes" >&2
    return 2
  fi
  # Two questions with one answer: is anything here not in the commit the
  # record will name? git answers it in two lists — the paths it reports as
  # changed, and the paths it hides but install.sh copies (round 4, #225) —
  # and a tree carrying either is a tree the record cannot describe. They are
  # gathered before either is printed, because a tree that is BOTH dirty and
  # carrying ignored files used to return on the first list and never name the
  # second, which is the half that can be a secrets file.
  paths="$(record_tree_dirty "$1")" || paths=''
  ign="$(record_tree_ignored "$1")" || ign=''
  [ -n "$paths$ign" ] || return 0
  # The headline is about what is actually there. "Dirty worktree" for a clean
  # tree with a secrets.env beside it would send the operator to `git status`,
  # which is precisely the reader that cannot see it.
  if [ -n "$paths" ]; then headline="a dirty worktree"
  else headline="a tree git is not showing you"; fi
  if [ "$2" = 1 ]; then
    echo "drill: --allow-dirty: this tree is not the commit, and the run will go ahead." >&2
    echo "  The record's ref field will be stamped '-dirty': it names a commit" >&2
    echo "  that is NOT what ran, and the run cannot be reproduced from it." >&2
    [ -n "$paths" ] && preflight_paths "$paths"
    if [ -n "$ign" ]; then
      echo "  '!!' is a file git IGNORES and install.sh copies anyway — it will be" >&2
      echo "  installed into the box, and this repository ignores secrets:" >&2
      preflight_paths "$ign"
    fi
    return 0
  fi
  echo "drill: REFUSING to drill $headline." >&2
  echo "  The tree under test is this checkout, and the record names its commit." >&2
  echo "  These paths are not in that commit, so the record would be a lie:" >&2
  [ -n "$paths" ] && preflight_paths "$paths"
  if [ -n "$ign" ]; then
    preflight_paths "$ign"
    echo "  '!!' is git's mark for a file it IGNORES. install.sh excludes .git" >&2
    echo "  and nothing else, so these are copied into the box while every" >&2
    echo "  reader of the record says the tree is clean — and this repository" >&2
    echo "  ignores secrets.env and *.agekey. Move them out of the checkout." >&2
  fi
  echo "  Commit or stash them, or re-run with --allow-dirty, which drills them" >&2
  echo "  anyway and stamps the record's ref field '-dirty'." >&2
  return 2
}

# The one moment the tree's identity has an answer (round 2, #225).
#
# A record describes what was INSTALLED AND DRILLED, and install.sh copies the
# tree in stage 1, forty minutes before the record is written. Every field
# describing the tree used to re-ask git at summary time instead, and by then
# git is answering about a different tree than the one in the box. The
# reproduced case: a run starts dirty under --allow-dirty, the operator stashes
# or commits during the drill, and collection reads a clean checkout — so the
# record names a branch with no '-dirty' stamp and drops --allow-dirty from the
# line that claims to reproduce it, while the installed tree still holds the
# uncommitted work that actually ran. A record naming a commit anyone can check
# out and that is NOT what ran is the exact untruth #225 closes, re-entered
# through the one door left open. The SHA and the ref go the same way for the
# same reason: a mid-run commit or branch switch moves both.
#
# So the tree is read ONCE, here, before anything is installed, and the answers
# are latched. An already-set TREE_DIRTY is the stage-1 measurement arriving over
# the sg re-exec, and re-answering any of this in the second stage is the defect
# itself. The dirty PATHS are latched with the flag, because the NOTE that names
# them is raised in that second stage and git cannot be asked for them there.
#
# It is still a measurement and never a flag — it reads the tree, not
# $ALLOW_DIRTY — it is simply taken at the moment it describes.
tree_ident_latch() {   # <dir> — the tree fields a record carries, measured once
  local ign n
  [ -z "$TREE_DIRTY" ] || return 0
  TREE_DIRTY_PATHS="$(record_tree_dirty "$1")" || TREE_DIRTY_PATHS=''
  # An ignored file is dirtiness the record has to declare, for the reason the
  # preflight refuses one (round 4, #225): install.sh copies it, so the tree in
  # the box is not the commit, and a run carrying one cannot be reproduced by
  # checking that commit out. It reaches this line only through --allow-dirty,
  # and the flag it costs is the one that says so.
  if ign="$(record_tree_ignored "$1")"; then
    TREE_DIRTY_PATHS="${TREE_DIRTY_PATHS:+$TREE_DIRTY_PATHS$'\n'}$ign"
  fi
  if [ -n "$TREE_DIRTY_PATHS" ]; then TREE_DIRTY=1; else TREE_DIRTY=0; fi
  # What crosses the sg re-exec is an ENVIRONMENT VARIABLE, and with ignored
  # files in the list it can now be thousands of paths where it used to be a
  # handful (round 4, #225). The list exists to be read in a NOTE, and its
  # carrier has a size limit, so it is capped exactly like the refusal's is —
  # and the flag above it, which is the part that changes what the record says,
  # is measured over all of them before the cap applies.
  n="$(printf '%s\n' "$TREE_DIRTY_PATHS" | grep -c .)"
  if [ "$n" -gt "$TREE_PATHS_MAX" ]; then
    TREE_DIRTY_PATHS="$(printf '%s\n' "$TREE_DIRTY_PATHS" | head -n "$TREE_PATHS_MAX")
…and $((n - TREE_PATHS_MAX)) more"
  fi
  REC_TREE_REPO="$(record_tree_repo "$1")"
  REC_TREE_SHA="$(record_tree_sha "$1")"
  REC_TREE_REF="$(record_tree_ref_stamped "$1" "$TREE_DIRTY")"
  # The witness the two guards below compare against. Latched here with the
  # fields it protects, because a witness taken at any other moment describes a
  # tree the record does not.
  TREE_IDENT="$(record_tree_ident "$1")"
  return 0
}

# THE WINDOW BETWEEN THE MEASUREMENT AND THE COPY (round 3, #225). The latch runs
# before the consent prompt; install.sh copies the tree minutes later. In between
# the checkout is an ordinary directory, and nothing else notices it move:
# stage 2's preflight re-runs, but --allow-dirty waves a newly dirty tree
# through, and a `git commit` or `git switch` leaves a CLEAN tree it passes with
# nothing to say. Either way the box holds one tree and the record names another
# — the untruth this issue exists to close, through the last door left open.
#
# It cannot be closed by measuring EARLIER; every earlier moment has the same
# window after it. It is closed by measuring AGAIN once the bytes are settled and
# refusing when the two answers differ. Called on both sides of the install,
# because the window has two halves and only one of them can be refused cheaply:
# before it, the operator's think-time, where the host is still untouched; after
# it, the copy itself, which no earlier check can cover.
tree_ident_verify() {   # <dir> <when> — 0 when the tree is still the latched one
  local now
  # An empty witness is not "nothing to check": it is the latch bypassed, which
  # is the guard disabled by silence. It fails like a mismatch.
  if [ -z "$TREE_IDENT" ]; then
    echo "drill: FATAL — the tree's identity was never latched ($2)." >&2
    echo "  tree_ident_latch runs beside the preflight and must precede any" >&2
    echo "  install; reaching this line without it is a bug in drill.sh." >&2
    return 1
  fi
  now="$(record_tree_ident "$1")"
  [ "$now" = "$TREE_IDENT" ] && return 0
  echo "drill: FATAL — $1 changed $2." >&2
  echo "  The record names the tree measured before the install: $REC_TREE_REF" >&2
  echo "  ($REC_TREE_SHA). The checkout is no longer that tree, so a record" >&2
  echo "  written now would name a commit that is NOT what ran — including" >&2
  echo "  under --allow-dirty, where the stamp describes the paths as they" >&2
  echo "  were when they were measured." >&2
  echo "  Leave the checkout alone for the length of the run, and re-run:" >&2
  echo "    bash drill/drill.sh --yes" >&2
  return 1
}

# THE BYTES THAT LANDED (round 4, #225). Everything above watches the SOURCE: the
# tree is measured, measured again on both sides of the install, and refused if
# the two answers differ. Two equal endpoints do not make a constant interval.
# install.sh reads the checkout ACROSS that gap, so a change made after the first
# verify and reverted before the second is copied into the box and then made
# invisible to the only thing looking. codex reproduced exactly that with a `tar`
# shim: both witnesses matched, INSTALLED_FROM was right, the checkout ended with
# no marker in it, and the installed README.md had one.
#
# No check on the source closes that, because the source is not the subject. What
# the record claims is about the COPY, so the copy is what gets attested: every
# file the installer copies, on both sides, by content. That catches a divergence
# whatever produced it — a race, a shim, a truncated tar, an install that fell
# back to another tree — without anticipating any of them, and it is the one
# comparison whose subject is the bytes the drill is about to run.
#
# What it deliberately does NOT compare, each because it is not payload:
#   · .git ANYWHERE in the tree. install.sh's `tar --exclude=.git`
#     (install.sh:213) is an unanchored pattern, so it matches any path
#     component and a vendored repository is never copied; pruning only the
#     top-level one would red an install that was faithful (round 5, #225);
#   · INSTALLED_FROM, which the installer WRITES into the version directory —
#     the installer's own note about itself, asserted separately just above;
#   · file MODES: install.sh chmods bin/box +x deliberately, and a mode is not
#     a byte the drill runs;
#   · empty directories, which carry no bytes either.
#
# THE MANIFEST IS NUL-DELIMITED, AND IT IS A FILE (round 5, #225). This began as
# one `<path> <hash>` LINE per file, and a newline is legal in a path, so the
# line could not say where a record ended: codex built a source whose only file
# sat under a directory named `a <hash-of-alpha>` + newline + `.` against a
# destination holding top-level `a` and `b`, and the two printed the SAME
# listing. Different payloads, identical verdict, on the one check whose whole
# claim is that these bytes are those bytes. Three NUL-terminated fields per
# record — kind, value, path — so no field can contain its own delimiter, and
# the path goes last because it is the field with the fewest guarantees. It has
# to be a file rather than a string because bash drops NUL bytes from a command
# substitution, which is what left the ambiguous encoding as the only option.
payload_list() {   # <dir> <manifest> — NUL-delimited '<kind>\0<value>\0<path>\0'
  ( cd "$1" 2>/dev/null || exit 1
    # -print0 and a -z sort, because a newline is legal in a path. hash-object
    # needs no repository (it is a content hash) and writes nothing without -w,
    # which is what lets the same reader run over an install root. --no-filters
    # because one side IS a repository and the other is not: a .gitattributes
    # `text` or `filter` attribute would otherwise hash the same bytes two ways
    # and red every honest install, in the voice of the defect this exists to
    # catch. box carries no .gitattributes today; the symmetry should not rest
    # on that staying true (round 5, #225).
    find . -name .git -prune -o -path ./INSTALLED_FROM -prune -o \
         \( -type f -o -type l \) -print0 2>/dev/null \
      | LC_ALL=C sort -z \
      | while IFS= read -r -d '' p; do
          if [ -L "$p" ]; then
            # $( ) strips trailing newlines and a target may end in one, so the
            # sentinel keeps the target's bytes exactly; then the single newline
            # readlink itself adds comes off.
            t="$(readlink -- "$p" && printf x)"; t="${t%x}"; t="${t%$'\n'}"
            printf 'l\0%s\0%s\0' "$t" "$p"
          else
            printf 'f\0%s\0%s\0' \
              "$(git hash-object --no-filters -- "$p" 2>/dev/null || echo unreadable)" "$p"
          fi
        done ) > "$2"
}

payload_render() {   # <manifest> → one line per record, for the DELTA only
  # A view of the manifest and never what the verdict is taken from — that is
  # `cmp` on the manifests themselves. The path is escaped, so a newline in one
  # cannot forge a line here either, and the operator still reads a file name.
  local kind value path
  while IFS= read -r -d '' kind && IFS= read -r -d '' value \
     && IFS= read -r -d '' path; do
    if [ "$kind" = l ]; then printf '%q -> %q\n' "$path" "$value"
    else                     printf '%q %s\n'    "$path" "$value"; fi
  done < "$1"
}

payload_attest() {   # <checkout> <install root> — 0 when what landed IS the checkout
  local a b delta
  a="$(mktemp)"; b="$(mktemp)"
  payload_list "$1" "$a"
  payload_list "$2" "$b"
  [ -s "$a" ] || { echo "drill: FATAL — $1 holds no files to attest." >&2
                   rm -f "$a" "$b"; return 1; }
  cmp -s "$a" "$b" && { rm -f "$a" "$b"; return 0; }
  echo "drill: FATAL — the installed tree is not the tree this checkout holds." >&2
  echo "  Every file install.sh copies was compared by content. '<' is the" >&2
  echo "  checkout, '>' is $2:" >&2
  delta="$(diff <(payload_render "$a") <(payload_render "$b") 2>/dev/null \
           | grep -E '^[<>]' | head -20)"
  rm -f "$a" "$b"
  printf '%s\n' "${delta:-  (the two listings differ; diff is unavailable to say where)}" \
    | sed 's/^/    /' >&2
  echo "  The record would name a commit whose bytes are not the ones installed." >&2
  echo "  The usual cause is the checkout being edited while install.sh copied" >&2
  echo "  it — including an edit that was undone again, which the guards above" >&2
  echo "  cannot see and this can. Leave the checkout alone for the length of" >&2
  echo "  the run, and re-run:" >&2
  echo "    bash drill/drill.sh --yes" >&2
  return 1
}
# <<< drill preflight

resolve_install_paths "$(id -u)"
preflight_uid "$(id -u)" || exit 2
preflight_tree "$CHECKOUT" "$ALLOW_DIRTY" || exit 2
# After the refusal and before the install: a tree that got past the line above
# is one this run will drill, and this is what it looked like when it did.
tree_ident_latch "$CHECKOUT"
ledger_check_expect || exit 2
record_check_path "$RECORD" || exit 2

wait_box() {   # poll until exec answers (the VM agent can take a while), ~4 min
  # 2 min was too short: run 17's box came up AFTER the window closed — the
  # drill called it dead, and then every check on it passed anyway. The phase
  # that bought this window (M, migration) is gone (#226); the measurement it
  # paid for is not, so the window stays generous.
  local b="$1" _i
  for _i in $(seq 1 120); do
    box exec "$b" -- true >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# Read from inside a box WITHOUT ever hanging the drill.
#
# Two traps, both hit for real:
#   · 'box exec' crosses a login-user shell boundary. Fine for a person,
#     needless machinery for a probe.
#   · $( ) waits for stdout to CLOSE, not for the command to exit. A grandchild
#     inheriting the exec session's stdout keeps the substitution open forever,
#     and 'timeout' does not save you: it kills the wrapper, not the holder of
#     the pipe. Run 4 hung 10+ minutes on exactly this.
# So: talk to 'incus exec' directly, pin stdin to /dev/null, land the output in
# a file (never a pipe), and hard-kill on timeout.
in_box() {
  local b="$1"; shift
  local out; out="$(mktemp)"
  timeout -k 5 20 incus exec "$b" -- "$@" >"$out" 2>/dev/null </dev/null
  local rc=$?
  cat "$out"; rm -f "$out"
  return "$rc"
}

# The box's address ON BOXNET. Three ways to get this wrong, all of them hit:
#   · 'incus list' name filters are NOT regexes ("^b$" silently matches nothing)
#   · its CSV quotes a multi-address box across lines
#   · and the interface is NOT called eth0. The PROFILE names the device eth0,
#     but inside a VM guest predictable naming renames it enp5s0. Six runs of
#     A3 "not probed" were this, not the network.
# So: read it from inside the box, and select by SUBNET (what boxnet hands
# out — read off the network, never hardcoded: BOX_SUBNET moves it, #80)
# rather than by interface name — docker0 (172.17.x) is the decoy, and the
# NIC's name is the guest's business, not ours.
boxnet_gw() { incus network get boxnet ipv4.address 2>/dev/null | cut -d/ -f1; }
boxnet_ip() {
  local b="$1" ip _i pfx
  pfx="$(boxnet_gw)"; pfx="${pfx%.*}."
  for _i in $(seq 1 15); do
    ip="$(in_box "$b" ip -4 -o addr show scope global \
          | awk -v p="$pfx" '{ for (i = 1; i < NF; i++) if ($i == "inet" && index($(i+1), p) == 1) { split($(i+1), a, "/"); print a[1]; exit } }')"
    [ -n "$ip" ] && { printf '%s\n' "$ip"; return 0; }
    sleep 2
  done
  return 1
}

# The probe. Its verdict comes from curl's MESSAGE, never from its exit code.
#
# curl exit 7 is "failed to connect" — and it covers BOTH of these:
#   · "Connection refused"  → a RST came back. The packet ARRIVED. Reachable.
#   · "Could not connect to server" / "No route to host" → nothing came back at
#     all. The frame went nowhere. ISOLATED.
# Opposite conclusions, one exit code. The drill mapped 7 → "it arrived" and so
# reported a WORKING boundary as a broken one, run after run, while the kernel
# had 'isolated on' the bridge ports the whole time. A refusal is instant; an
# unreachable host burns the timeout. The words say which; the number cannot.
#
# Never hangs: incus exec directly (no login shell), stdin pinned, output landed
# in a file rather than a pipe, hard kill on timeout.
box_probe() {   # box_probe <box> <url> [timeout] → reachable | refused | dropped
  local b="$1" url="$2" t="${3:-5}" out rc msg
  out="$(mktemp)"
  timeout -k 5 $((t + 15)) incus exec "$b" -- curl -sS -m "$t" -o /dev/null "$url" \
    >/dev/null 2>"$out" </dev/null
  rc=$?
  msg="$(cat "$out")"; rm -f "$out"
  if [ "$rc" -eq 0 ]; then echo reachable; return; fi
  case "$msg" in
    *"Connection refused"*) echo refused ;;   # it ARRIVED, and was rejected
    *)                      echo dropped ;;   # nothing came back
  esac
}

box_pings() {   # box_pings <box> <ip> → 0 if it answers ICMP
  timeout -k 5 20 incus exec "$1" -- ping -c1 -W2 "$2" >/dev/null 2>&1 </dev/null
}

# Mint with a heartbeat. box new's own narration lands in the log; a dot every
# 5s on the drill's terminal proves the run is ALIVE — a silent multi-minute
# mint is indistinguishable from a wedge, and that ambiguity has cost whole
# evenings. The log line says where to watch the real progress.
# A failed mint leaves a forensic bundle behind now (#266). The log's tail is
# the symptom; the bundle is the evidence — and a finding that names only the
# symptom is exactly how the 0.10.0 cut's two lost clones came to be
# reconstructed from four lines. So the FINDING carries the path, not just the
# terminal: findings are what the emitted drills/<version>.md record keeps, and
# a path printed only to a terminal is gone with the terminal.
#
# THE BUNDLE THIS MINT MADE, and no other (#266 round 1). This used to test
# whether /tmp/box-forensics-<box> existed — a fixed name, so an earlier
# attempt's leftovers were attributed to this failure, and a mint that died
# BEFORE the forensics ran (a copy or start failure) got a bundle it never
# produced. In drills/<version>.md, which is the release certification record.
# box now mints the bundle with mktemp and prints where it went, so the path
# comes out of this mint's own log or the finding names none.
mint_evidence() {   # mint_evidence <log> → one line, for a finding
  local extra="" dir=""
  dir="$(sed -n 's/^box: forensics kept in \([^ ]*\) .*/\1/p' "$1" 2>/dev/null | tail -1)" || dir=""
  if [ -n "$dir" ] && [ -d "$dir" ]; then
    extra=" — forensics kept: $dir"
  fi
  printf '%s%s' "$(tail -3 "$1" 2>/dev/null | tr '\n' ' ')" "$extra"
}

mint_box() {   # mint_box <log> <box-new args...> → box new's exit code
  local log="$1"; shift
  inf "watch it live in another terminal:  tail -f $log"
  box new "$@" >"$log" 2>&1 </dev/null &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do printf '.'; sleep 5; done
  printf '\n'
  wait "$pid"
}

# --- stage 1: consent, install, then re-enter inside the incus-admin group ---
if [ "${IN_GROUP:-0}" != 1 ]; then
  if [ "$YES" -ne 1 ]; then
    cat <<EOF
This will, ON THIS HOST ($(hostname)):
  · install Incus and a systemd unit
  · create a network (boxnet), an ACL, and a profile
  · rewrite firewall rules (nft or UFW, and Docker's DOCKER-USER chain)
  · create and destroy instances named: drill, clone, archive, peer, payroll, cbprobe, cbcopy, tpl, codex, grok
Only do this on a machine you can format.
EOF
    [ -t 0 ] || { echo "drill: no TTY to confirm on — pass --yes if you mean it." >&2; exit 2; }
    printf 'Continue? [y/N] '
    read -r reply
    case "$reply" in y|Y|yes) ;; *) echo "stopped."; exit 1 ;; esac
  fi

  # The wall clock starts HERE, after the consent prompt, and is an epoch stamp
  # rather than $SECONDS: this shell is about to exec itself into the
  # incus-admin group, and $SECONDS restarts at zero in the shell that actually
  # finishes the run (#152). Operator think-time at the prompt is not the
  # drill's duration, which is why the stamp is taken below it and not above.
  DRILL_T0="$(date +%s)"

  # The LATCHED sha, not a fresh one: the header and the record name the same
  # tree or the header is the first thing in the log that is wrong about which
  # tree this run drilled (round 3, #225).
  phase - "Installing box from this checkout ($CHECKOUT @ $REC_TREE_SHA)"
  inf "Incus project: $INCUS_PROJECT (pinned for this run; saved client configuration untouched)"

  # Sudo, up front and out loud. Later calls run unattended, and a password
  # prompt swallowed by a '-qq' redirect looks exactly like a hang. This now
  # has to precede the install too: install.sh runs the host setup itself, so
  # the first thing needing root is no longer further down — it is inside the
  # very next command.
  sudo -v || { echo "drill: need sudo (the host setup installs packages and firewall rules)"; exit 1; }

  # Pre-setup observations must be READ BEFORE install.sh, because install.sh
  # is now what runs setup-host. Read after it and setup has already had its
  # chance to act, so the observation says nothing.
  # setup-host.sh installs nftables itself when neither nft nor UFW exists
  # (a stock Debian 13 cloud image ships neither). This is a tripwire: if it
  # fires, that fix regressed.
  fw_absent_pre=0
  if ! command -v nft >/dev/null 2>&1 && ! command -v ufw >/dev/null 2>&1; then
    fw_absent_pre=1
  fi

  # DRILL_OWNS_SETUP=1 opts out of the installer's automatic setup and puts the
  # drill back in charge of sequencing it (install, then clean, then converge).
  # The DEFAULT deliberately does not: a drill that runs setup-host itself right
  # after installing cannot tell you whether install.sh did its job, because the
  # drill's own call would build the stack either way. The default path exercises
  # what a user actually runs, and asserts the result in-group below.
  OWNS="${DRILL_OWNS_SETUP:-0}"
  if [ "$OWNS" = 1 ]; then
    export BOX_SKIP_SETUP_HOST=1
  fi

  # The first of the two window guards runs HERE, above the rm -rf, and not
  # beside the install below it. It is the whole of the operator's think-time —
  # the consent prompt and `sudo -v` — and its comment claims it refuses with
  # the host still untouched; below the rm -rf that sentence was false, because
  # a refusal would already have destroyed the operator's previous install
  # (round 4, #225). Nothing between here and the install reads the checkout, so
  # the guard is as good here and the claim becomes true.
  tree_ident_verify "$CHECKOUT" "between its measurement and the install" || exit 1

  # The installer converges when a version is already installed (0.7.0's
  # versioned layout: re-running the same version is a no-op, and an upgrade
  # lands side-by-side without flipping under boxes). The drill re-proves a
  # tree from SCRATCH every run — a fresh host, not a converged one — so it
  # removes the whole install root and symlink first.
  rm -rf "$BOX_SHARE" "$BOX_BINDIR/box"

  # The installer prompts (install? set up host?) and reads /dev/tty. The drill
  # runs unattended with no tty, so it answers yes to everything via BOX_YES.
  # OWNS still suppresses the setup prompt via BOX_SKIP_SETUP_HOST above.
  export BOX_YES=1

  # THE change (D1, D2, #225). This used to curl install.sh out of
  # raw.githubusercontent.com at $REPO@$REF and install whatever the network
  # served, so the harness came from the checkout and the subject came from
  # somewhere else — usually main, because that was the default nothing on the
  # documented command line overrode. Now the checkout supplies both: its own
  # install.sh, run against its own tree through BOX_INSTALL_SOURCE, which is
  # the mechanism install.sh already carries for exactly this (install.sh:23)
  # and the one CI installs through. Phase I is untouched in substance —
  # install.sh still runs the host setup itself, which is the whole of what
  # #64's contract asserts.
  #
  # The two guards around it close the window between the latch and the copy
  # (round 3, #225). The first one ran above the rm -rf, where the host is still
  # untouched, so a tree that moved during the operator's think-time is never
  # installed at all.
  BOX_INSTALL_SOURCE="$CHECKOUT" bash "$CHECKOUT/install.sh" \
    || { echo "install failed"; exit 1; }
  # ...and the second is the copy itself, the only half of the window no earlier
  # check can reach: install.sh reads the tree while this line's subject is free
  # to be edited, and the bytes that landed are then neither answer. There is a
  # wasted install behind this refusal, which is the price of catching it at all
  # — and a wasted install is cheaper than a record nobody can trust.
  tree_ident_verify "$CHECKOUT" "while install.sh was copying it" || exit 1
  export PATH="$BOX_BINDIR:$PATH"

  # ASSERT WHAT LANDED — never trust that the install obeyed us.
  # The original assertion compared INSTALLED_FROM against the repo@ref pair the
  # drill had been asked for, and it was written for two incidents where that
  # pair was not what arrived: a lagged CDN tarball, and a stale drill.sh passing
  # retired CLAUDEBOX_* vars to an install.sh reading BOX_* — main was installed
  # and the run drilled the wrong tree while reporting success. There is no ref
  # to mismatch any more, so that purpose is gone; what survives is the half that
  # keeps earning its place, THE INSTALL LANDED WHERE WE THINK IT DID, and it now
  # has a second reason to exist: the destination is chosen by uid, so this read
  # is the only thing standing between a mis-resolved path and forty minutes of
  # drilling a tree nobody chose. It reads the path the install actually used
  # (D6, #225), and it diagnoses nothing it has not measured.
  want="local:$CHECKOUT"
  got="$(cat "$BOX_SHARE/current/INSTALLED_FROM" 2>/dev/null || echo '<unknown>')"
  if [ "$got" != "$want" ]; then
    echo "drill: FATAL — installed from '$want', but $BOX_SHARE/current says '$got'." >&2
    echo "  The install root is resolved by uid, the way install.sh resolves it:" >&2
    echo "    uid $(id -u) → $BOX_SHARE (BOX_HOME/BOX_BIN override both)" >&2
    echo "  Either the install went somewhere else, or a previous install is" >&2
    echo "  still in the way. Inspect it, remove it, and re-run:" >&2
    echo "    ls -l $BOX_SHARE/current" >&2
    exit 1
  fi
  # ...and that what landed is byte-for-byte the checkout's, which is the
  # criterion the flags could never satisfy: INSTALLED_FROM records the source
  # that was NAMED, and comparing the delivered CLI against the one in the tree
  # is the drill asserting the tree it drilled rather than reading its own log.
  if ! cmp -s "$CHECKOUT/bin/box" "$BOX_SHARE/current/bin/box"; then
    echo "drill: FATAL — the installed bin/box is not this checkout's." >&2
    echo "    checkout:  $CHECKOUT/bin/box" >&2
    echo "    installed: $BOX_SHARE/current/bin/box" >&2
    echo "  The install reported success, so something rewrote or replaced the" >&2
    echo "  tree afterwards. Nothing below this line would be drilling your code." >&2
    exit 1
  fi
  # ...and then the same question about the WHOLE payload, which is the one the
  # record answers (round 4, #225). The two lines above ask whether the install
  # obeyed the source and whether the CLI is the checkout's; neither can see a
  # file that was moved during the copy and moved back, or any other divergence
  # outside bin/box. This compares every file that was copied, by content, and
  # it is the last thing between a mixed tree and forty minutes of drilling it.
  payload_attest "$CHECKOUT" "$BOX_SHARE/current" || exit 1
  inf "installed tree confirms: $got, and every copied file matches the checkout byte for byte"

  # The run ID is resolved HERE and not at the end, because its whole purpose is
  # to be handed to whoever drills rig and cast — and they need it while their
  # runs are still ahead of them, not after this one finishes forty minutes
  # later. It needs the installed VERSION, which is why it cannot be resolved
  # any earlier than this line (#152).
  if [ -z "$RUN_ID" ]; then
    RUN_ID="$(record_run_id "$(record_version "$BOX_SHARE")" "$(date +%Y%m%d)")"
  fi
  inf "run ID: $RUN_ID   ← rig's and cast's records for this release use this exact string"
  [ -n "$RECORD" ] && inf "record will be written to: $RECORD"

  phase - "Host setup (Incus, boxnet, ACL, profile, firewall)"
  if [ "$fw_absent_pre" = 1 ]; then
    note "neither nft nor ufw present pre-setup — setup-host.sh must install nftables itself (it fixed this once; watch that it still does)"
  fi

  # apt's lock is held by apt-daily / unattended-upgrades on a fresh cloud
  # image, and 'apt-get -qq >/dev/null' waits for it in COMPLETE SILENCE —
  # which is how run 5 looked stuck for minutes right after this header.
  # Say what we are waiting for, and give up rather than hang forever.
  if ! command -v incus >/dev/null 2>&1; then
    inf "installing incus (waiting for the apt lock if a background upgrade holds it)…"
    if ! sudo DEBIAN_FRONTEND=noninteractive timeout 600 \
           apt-get -o DPkg::Lock::Timeout=300 install -y incus; then
      echo "drill: 'apt-get install incus' failed or timed out." >&2
      echo "  a background apt job usually holds the lock. check with:" >&2
      echo "    sudo fuser -v /var/lib/dpkg/lock-frontend" >&2
      echo "    systemctl status unattended-upgrades apt-daily.service" >&2
      exit 1
    fi
  else
    inf "incus already installed — skipping apt"
  fi

  # No setup-host call here any more. It used to run a full "first pass" that
  # the comment described as "may only add you to incus-admin" — behaviour that
  # no longer exists (setup-host converges in one run now, #63) and that, since
  # install.sh runs setup itself (#64), was simply the stack being built a
  # second time before the drill had asserted the first.
  if [ "$OWNS" = 1 ]; then
    # We opted out of the installer's setup, so nobody has joined us to the
    # group yet. usermod ONLY: the stack build waits until after the clean
    # below, which is the entire reason for owning the sequence.
    inf "DRILL_OWNS_SETUP=1 — the drill owns the host setup"
    id -nG | grep -qw incus-admin || sudo usermod -aG incus-admin "$USER"
  else
    inf "install.sh ran the host setup — asserting what it left, in-group, next"
  fi
  # setup-host's own sg re-exec was a CHILD of install.sh; this shell's
  # credentials are untouched, so we still have to enter the group ourselves —
  # once, for the remainder of the drill.
  inf "re-entering inside the incus-admin group…"
  reexec_in_group
fi

export PATH="$BOX_BINDIR:$PATH"

# The dirty-tree note is raised HERE and not beside the refusal that let the run
# through, because `findings` does not cross the sg re-exec: the array belongs to
# the shell that `exec`s away, so anything recorded in stage 1 is gone before the
# record is written. This is the first line of the stage that writes it. A NOTE
# and not a FAIL — the operator asked for this with --allow-dirty and the record
# is stamped for it; what the note adds is WHICH paths, which the stamp cannot
# carry (D5, #225).
#
# It is NOT a second read of the tree. This line and the record's stamp are one
# measurement, taken by tree_ident_latch before install.sh copied anything and
# carried here over the sg re-exec, which is why the paths are a variable and not
# a `git status` — asking again from this stage was the defect (round 2, #225).
# An earlier version read the tree twice and called the two reads deliberately
# independent; a run that started dirty and was cleaned mid-drill then emitted an
# unstamped record with no note, describing a checkout nobody had installed. The
# tree that matters stopped existing the moment it was copied, so remembering
# once beats measuring twice: there is only one moment this note is true about.
if [ "$TREE_DIRTY" = 1 ]; then
  note "the worktree was DIRTY and --allow-dirty was given: this run drilled work that is not in the commit — uncommitted paths, and '!!' paths git ignores and install.sh copied into the box regardless — and the record's ref field is stamped '-dirty' because it cannot be reproduced from the commit it names — $(printf '%s' "$TREE_DIRTY_PATHS" | tr '\n' ';')"
fi

# PROVE THE INSTALLER'S CONTRACT (#64) — first, before the clean or anything
# else on this host mutates the stack, and before the drill runs setup-host
# itself further down. That ordering is the whole point: the old flow ran
# setup-host immediately after installing, so the stack existed by the drill's
# own hand and the run passed identically whether or not install.sh had done a
# thing. This is read-only, so it is safe with a previous run's boxes still
# attached.
if [ "${DRILL_OWNS_SETUP:-0}" != 1 ]; then
  phase I "Asserting the stack that install.sh built"
  missing=""
  incus network show boxnet        >/dev/null 2>&1 || missing="$missing boxnet"
  incus network acl show box-isolate >/dev/null 2>&1 || missing="$missing box-isolate"
  incus profile show box-profile       >/dev/null 2>&1 || missing="$missing box-profile"
  # Last thing setup-host does, so it doubles as "it ran to the end".
  sudo nft list table bridge box   >/dev/null 2>&1 || missing="$missing nft-bridge-box"
  if [ -n "$missing" ]; then
    echo "drill: FATAL — install.sh reported success but left an INCOMPLETE stack:$missing" >&2
    echo "  install.sh is supposed to run the host setup itself (#64), and setup-host" >&2
    echo "  is supposed to converge in one run (#63). One of those did not happen." >&2
    echo "  reproduce with the output visible:" >&2
    echo "    $BOX_SHARE/current/host/setup-host.sh" >&2
    echo "  or hand setup back to the drill:  DRILL_OWNS_SETUP=1 $SELF" >&2
    exit 1
  fi
  ok "install.sh left a complete host stack (boxnet, box-isolate, box-profile, nft bridge drop) — no second setup needed"
else
  skipped I 1 "DRILL_OWNS_SETUP=1 — the drill built the stack itself, so install.sh's own contract (#64) was NOT asserted this run"
fi

# CLEAN BEFORE SETUP, not after. setup-host.sh reconfigures the network's ACLs,
# and a previous run's boxes are still ATTACHED to that network — 'incus network
# set' then has to push the change onto every live NIC, which is how run 6
# stalled. An aborted run also leaves the D-phase mutations (dns.mode=none, NIC
# filtering) in place, so setup would be converging against a moving target.
# Take the boxes down and revert the mutations FIRST; then the host is a
# clean-ish slate and setup-host is the no-op it should be.
# A host still carrying a previous run's phase-D mutations mints boxes with no
# DNS, and then reports the resulting breakage as a finding. Refuse to run.
# NOTE: dns.mode=none is now part of the SHIPPED stack (it closes the sibling
# DNS-enumeration leak), so it is no longer "dirt" from a rehearsal — do not
# revert it. Only the vetoed NIC filtering counts as leftover.
# box-profile alone since #226 retired the migration path: the pre-rename ancestor
# profile was swept beside it, and nothing on a drill host builds one now.
dirty=""
[ -n "$(incus profile device get box-profile eth0 security.ipv4_filtering 2>/dev/null)" ] && dirty="$dirty box-profile:ipv4_filtering"
[ -n "$(incus profile device get box-profile eth0 security.mac_filtering 2>/dev/null)" ] && dirty="$dirty box-profile:mac_filtering"
if [ -n "$dirty" ]; then
  note "this host carries the VETOED NIC filtering from an old rehearsal:$dirty — reverting"
  incus profile device unset box-profile eth0 security.mac_filtering >/dev/null 2>&1
  incus profile device unset box-profile eth0 security.ipv4_filtering >/dev/null 2>&1
fi

inf "clearing anything a previous run left behind…"
# One name at a time — 'incus delete -f a b c' aborts at the first MISSING name,
# which is how run 2 inherited run 1's boxes and cascaded five false FAILs.
for n in drill clone archive peer payroll cbprobe cbcopy cbnotours tpl codex grok; do
  timeout -k 5 60 incus delete -f "$n" >/dev/null 2>&1
done
if incus network show boxnet >/dev/null 2>&1; then
  timeout -k 5 30 incus network unset boxnet dns.mode >/dev/null 2>&1
fi
if incus profile show box-profile >/dev/null 2>&1; then
  timeout -k 5 30 incus profile device unset box-profile eth0 security.mac_filtering >/dev/null 2>&1
  timeout -k 5 30 incus profile device unset box-profile eth0 security.ipv4_filtering >/dev/null 2>&1
fi
left="$(incus list --format csv --columns n 2>/dev/null | tr '\n' ' ')"
[ -n "$left" ] && inf "instances still on this host (not ours, left alone): $left"

# This call stays, and it is NOT the install's setup repeated for its own sake:
# the clean above deliberately unsets dns.mode, which is part of the SHIPPED
# stack, and drops a previous run's phase-D mutations. Something has to put the
# host back together afterwards, and setup-host is that something — this is the
# "converge against a clean slate" the block above is ordered for. On the
# default path the install's setup has already been asserted, so what this
# proves is idempotency: a second run over a cleaned host is a no-op that
# restores the stack rather than a fresh build.
inf "running setup-host.sh (post-clean convergence: restores dns.mode and any reverted mutations)…"
if ! timeout -k 10 300 "$BOX_SHARE/current/host/setup-host.sh"; then
  echo "drill: setup-host.sh failed or timed out (>5 min)." >&2
  echo "  it should take seconds on a host that already has incus. usual causes:" >&2
  echo "    · instances still attached to boxnet while its ACLs are reconfigured" >&2
  echo "        incus list" >&2
  echo "    · the firewall unit not completing" >&2
  echo "        systemctl status box-firewall.service --no-pager" >&2
  echo "    · the incus daemon wedged by an earlier aborted run" >&2
  echo "        systemctl status incus --no-pager; journalctl -u incus -n 30 --no-pager" >&2
  exit 1
fi
inf "host setup complete"

# A real server has room for the medium role resources (8GiB/4cpu), and
# drilling the real numbers is worth more than drilling shrunken ones. Only
# shrink if we must. Since 0.4.0 resources are per-box, stamped from the
# seed at mint — a profile edit no longer reaches them; the supported
# override is the BOX_* environment, which every 'box new' below inherits.
ram="$(awk '/MemTotal/{print int($2/1024/1024)}' /proc/meminfo)"
if [ "$ram" -lt 20 ]; then
  export BOX_MEMORY=3GiB BOX_CPU=2
  note "host has ${ram}GiB RAM — minting at 3GiB/2cpu via BOX_MEMORY/BOX_CPU (the medium role's 8GiB/4cpu is what was NOT drilled)"
else
  inf "host has ${ram}GiB RAM — drilling the medium role resources (8GiB/4cpu) unchanged"
fi

KVM=0; [ -e /dev/kvm ] && KVM=1
[ "$KVM" = 1 ] && inf "/dev/kvm present — boxes will be VMs (the real trust boundary)" \
               || note "NO /dev/kvm on this host — box will fall back to CONTAINER mode, so this run does NOT validate the VM trust boundary"

# ===========================================================================
phase A "A. Incus semantics — the assumptions box is built on"
# ===========================================================================
incus launch images:debian/13 cbprobe --config user.box=1 >/dev/null 2>&1
incus launch images:debian/13 cbnotours >/dev/null 2>&1      # untagged: not ours
sleep 3

# A1 — the tag read. #13 puts this on the path of EVERY box command.
t="$(incus config get cbprobe user.box 2>&1)"
[ "$t" = "1" ] && ok "config get user.box → '1'" \
               || no "config get user.box → '$t' (expected '1'; every box command would fail closed)"

# A2 — the list filter, and that it EXCLUDES an instance we didn't mint
f="$(incus list user.box=1 --format csv --columns nstS 2>&1)"
if echo "$f" | grep -q '^cbprobe,' && ! echo "$f" | grep -q '^cbnotours,'; then
  ok "list filter user.box=1 selects ours, excludes theirs"
else
  no "list filter user.box=1 is wrong — got: $(echo "$f" | tr '\n' ' ')"
fi

# A3 — four fields, no commas/newlines to mangle the awk table
n="$(echo "$f" | grep '^cbprobe,' | awk -F, '{print NF}')"
[ "$n" = 4 ] && ok "--columns nstS → 4 clean CSV fields" || no "--columns nstS → $n fields (the list table would garble)"

# A4 — the state string require_stopped compares against
s="$(incus list cbprobe --format csv --columns s 2>&1 | head -1)"
[ "$s" = RUNNING ] && ok "state column → 'RUNNING'" || no "state column → '$s' (require_stopped compares against RUNNING/STOPPED)"

# A5 — does rename REFUSE a running instance? #13's precondition bets it does.
if r="$(incus rename cbprobe cbprobe2 2>&1)"; then
  no "incus renamed a RUNNING instance — #13's 'stopped' precondition is unnecessary (merely conservative)"
  incus rename cbprobe2 cbprobe >/dev/null 2>&1
else
  ok "incus refuses to rename a running instance → $(echo "$r" | head -1 | cut -c1-60)"
fi

# A6 — snapshot list CSV: 'info' reads field 1 as the label
incus snapshot create cbprobe authed >/dev/null 2>&1
s1="$(incus snapshot list cbprobe --format csv 2>&1 | head -1)"
[ "$(echo "$s1" | cut -d, -f1)" = authed ] && ok "snapshot list csv → field 1 is the label" \
                                           || no "snapshot list csv field 1 ≠ label — got: $s1"

# A7 — the IPv4 column. #9 assumes it can be quoted/multi-line, hence fetching it apart.
inf "ipv4 column raw: $(incus list cbprobe --format csv --columns 4 2>&1 | tr '\n' '|')"

# A8 — unset config keys read as EMPTY with exit 0 (#15 B4). The '|| echo root'
# fallback #12 first proposed could never fire if so; #17's lookup depends on this.
u="$(incus config get cbprobe user.never-set 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$u" ]; then
  ok "config get on an unset key → empty string, exit 0"
  aud "B4 config-get unset key: empty + exit 0 — #17 fallbacks must use \${var:-}, never ||"
else
  note "config get on an unset key → rc=$rc out='$u' (not the documented empty+0 — #17's lookup adapts)"
  aud "B4 config-get unset key: rc=$rc out='$u'"
  skipped A 1 "A8 recorded an observation, not a verdict — incus did not answer the documented empty+0"
fi

# A9 — 'incus copy' preserves user.* keys (#15 B2). #17's whole metadata design:
# a clone must still know what it is without consulting the template.
incus config set cbprobe user.box.user claude 2>/dev/null
incus stop -f cbprobe >/dev/null 2>&1
incus copy cbprobe cbcopy >/dev/null 2>&1
c="$(incus config get cbcopy user.box.user 2>/dev/null)"
if [ "$c" = claude ]; then
  ok "incus copy preserves user.* keys (a clone knows what it is)"
  aud "B2 copy preserves user.*: YES — #17's metadata-stamp design holds"
else
  no "incus copy DROPPED user.* keys (got '$c') — #17's metadata design fails without them"
  aud "B2 copy preserves user.*: NO — #17 blocked as designed"
fi
incus delete -f cbcopy >/dev/null 2>&1

incus delete -f cbprobe cbnotours >/dev/null 2>&1

# ===========================================================================
phase B "B. The box surface"
# ===========================================================================
# Compare against the installed tree's VERSION file, not a hardcoded number —
# a pinned literal here would fail the drill on every release.
expected="$(cat "$BOX_SHARE/current/VERSION" 2>/dev/null || echo '?')"
v="$(box --version 2>&1)"
case "$v" in *"$expected"*) ok "box --version → $v" ;; *) no "version mismatch: CLI says '$v', VERSION file says '$expected'" ;; esac

# The drill must not require an empty host: operator boxes tagged
# user.box=1 are legitimate tenants, and the teardown below deliberately
# refuses to touch them. The empty-host message is only TESTABLE when the host
# is actually empty — on a shared host, skip it instead of failing it.
tenants="$(incus list user.box=1 --format csv --columns n 2>/dev/null | sort -u | tr '\n' ' ')"
if [ -n "${tenants% }" ]; then
  skipped B 1 "host already has boxes (${tenants% }) — the empty-host message is not testable on a shared host"
else
  box list >/dev/null 2>&1 && box list 2>&1 | grep -q 'no boxes yet' \
    && ok "empty host: 'no boxes yet', exit 0" || no "empty-host message wrong"
fi

# --- the template axis is gone (#288): its spellings refuse, teaching -------
box templates 2>&1 | grep -q 'box has no templates since 0.11.0' \
  && ok "box templates refuses, saying box has no templates (#288)" || no "'box templates' did not refuse with the removal"
box new --name tpl --template staging-box 2>&1 | grep -q -- '--autostart --require-vm' \
  && ok "--template staging-box refuses, teaching the --autostart --require-vm line (#288)" \
  || no "--template staging-box did not teach its replacement"
# The one rule that keeps the seed honest: no key can name a network. Plant a
# bad key in the INSTALLED seed (the drill owns this host), expect the parser to
# reject it BY NAME, restore the file.
seedenv="$BOX_SHARE/current/seed/box.env"
cp "$seedenv" /tmp/cbdrill-seed.env && printf 'BOX_NETWORK="lan"\n' >>"$seedenv"
box new --name tpl 2>&1 | grep -q "unknown key 'BOX_NETWORK'" \
  && ok "the seed cannot name a network — BOX_NETWORK rejected by name" \
  || no "a box.env key outside the allowlist was ACCEPTED — the seed could weaken isolation"
cp /tmp/cbdrill-seed.env "$seedenv" && rm -f /tmp/cbdrill-seed.env

# Inline resource flags: honored on a mint, and — since #171 — on a clone too.
# The mint proof rides the blank box below, and because this drill exports
# BOX_CPU/BOX_MEMORY on small hosts, it is also the precedence proof
# (flag > env > size > seed/default). The CLONE proof rides that same box a few
# lines later, once there is a real source to copy: it needs one, which is why
# it is not here.
#
# What used to be here was #57's proof of the opposite — that --from REFUSED
# --cpu, on the premise that a clone carries its source's resources. #171's
# retitle overturned that premise (the override rides 'incus copy', applied
# before the volume is created), so the refusal is gone and the probe went with
# it. It could stand here at all only because the refusal fired before box
# touched incus, which made '--from nowhere' a usable source; nothing about
# that trick survives the ruling, so this is a re-point and not a string swap.

printf '\n  minting a blank box (the generic seed, no role auto-run)…\n'
t0=$SECONDS
if mint_box /tmp/mint-tpl.log --name tpl --cpu 1 --memory 1GiB; then
  ok "box new --name tpl, the one seed  ($((SECONDS - t0))s)"
  tt="$(incus config get tpl user.box.template 2>/dev/null)"
  [ -z "$tt" ] && ok "a new mint stamps no template — there is none (#288)" \
               || no "a new mint stamped user.box.template='$tt'"
  rc="$(incus config get tpl limits.cpu 2>/dev/null)/$(incus config get tpl limits.memory 2>/dev/null)"
  [ "$rc" = "1/1GiB" ] && ok "inline --cpu/--memory landed (limits = $rc, beating BOX_* env)" \
                       || no "inline resource flags did not land — limits are $rc, expected 1/1GiB"
  [ "$(incus config get tpl user.box.user 2>/dev/null)" = dev ] \
    && ok "template user stamped on the instance (user.box.user=dev)" || no "user.box.user not stamped"
  incus config show tpl 2>/dev/null | grep -q '^- box-profile' \
    && ok "blank box launched with the box-profile profile — same placement contract" \
    || no "blank box is NOT on box-profile — a template picked its own placement?!"
  u="$(timeout -k 5 30 box exec tpl -- whoami </dev/null 2>/dev/null | tr -d '[:space:]')"
  [ "$u" = dev ] && ok "exec lands in the template's user ($u) — nothing hardcodes claude" \
                 || no "exec landed in '${u:-<nothing>}', expected dev"
  timeout -k 5 30 box exec tpl -- sh -lc 'command -v claude' </dev/null >/dev/null 2>&1 \
    && no "the blank box has claude installed — 'blank' is not blank" \
    || ok "blank box has no claude — nobody home, as designed"
  box_pings tpl 1.1.1.1 && ok "blank box reaches the internet (same egress as any template)" \
                        || no "blank box has NO egress — isolation parity broken"
  in_box tpl getent hosts deb.debian.org >/dev/null 2>&1 \
    && ok "blank box resolves public names (pinned resolver serves every template)" \
    || no "blank box cannot resolve — DNS parity broken"
  # --- the clone half of #171 D1, on a real daemon -------------------------
  # tpl was minted at --cpu 1 --memory 1GiB above, so it is a source whose
  # sizing is KNOWN, and a clone of it with --cpu 2 measures the one thing no
  # shim can: that the override reaches the volume incus actually creates. This
  # is also D6's read-back proved live — every figure below is read off the
  # daemon, not echoed from what box was asked for.
  #
  # Stopped first: box's clone path copies the instance itself (it stops
  # nothing on your behalf), and the drill's other clones dodge this by copying
  # a SNAPSHOT. This one wants the live instance's config, so it stops it.
  # tpl is finished with by here — the removal is the next line but one.
  incus stop -f tpl >/dev/null 2>&1
  # Deliberately NOT wrapped in 'if mint_box; then …probes… else no; fi', which
  # is the shape above: that arm runs a different NUMBER of probes depending on
  # the outcome, and PHASE_EXPECT is a count. Read the config unconditionally
  # instead — a clone that never came up answers '<unset>' and reds both probes
  # for the right reason, and the ledger still balances.
  mint_box /tmp/mint-cbcopy.log --name cbcopy --from tpl --cpu 2 \
    || inf "clone tail: $(tail -3 /tmp/mint-cbcopy.log | tr '\n' ' ')"
  cc="$(incus config get cbcopy limits.cpu 2>/dev/null)"
  [ "$cc" = 2 ] && ok "--cpu rides a CLONE: the copy came up at 2, not the source's 1 (#171 D1)" \
                || no "--cpu did not ride the copy — the clone's limits.cpu is '${cc:-<unset>}', expected 2"
  # The other half of D1, and the state D6 was ruled for: a flag NOT passed
  # contributes no override, so memory is still whatever the source had. A
  # clone that is PARTLY overridden is the case no intent-side value knows and
  # the read-back line exists to say out loud.
  cm="$(incus config get cbcopy limits.memory 2>/dev/null)"
  [ "$cm" = 1GiB ] && ok "...and a flag not passed keeps the source's value (memory = $cm) — a partly overridden clone (#171 D1/D6)" \
                   || no "the clone's memory is '${cm:-<unset>}', expected the source's 1GiB"
  box rm cbcopy --force >/dev/null 2>&1 || incus delete -f cbcopy >/dev/null 2>&1
  # D2/D3 fail-closed, on the arm that needs no VM. box refuses --disk when it
  # cannot read what root device the source has, BEFORE the copy, and creates
  # nothing. The other entrance to D3 — a VM source whose root comes from a
  # profile — cannot be reached from box's own surface at all: every VM mint
  # attaches '--device root,size=' (bin/box), so no box box mints lacks a root
  # device of its own. Making one would mean an 'incus init --empty --vm' on a
  # host this drill does not require to have KVM, so the probe takes the
  # entrance that is always there.
  cbout="$(box new --name cbcopy --from nowhere --disk 20GiB </dev/null 2>&1 || true)"
  if printf '%s\n' "$cbout" | grep -q 'could not be read' && ! incus info cbcopy >/dev/null 2>&1; then
    ok "--disk refuses a source box cannot read, before the copy, creating nothing (#171 D2/D3)"
  else
    no "--disk on an unreadable source did not fail closed (or left an instance behind) — said: $(printf '%s' "$cbout" | head -2 | tr '\n' ' ')"
  fi
  box rm tpl --force >/dev/null 2>&1 && ok "blank box removed" || no "could not remove the blank box"
else
  no "blank mint FAILED — tail: $(tail -3 /tmp/mint-tpl.log | tr '\n' ' ')"
  # Tear the stuck box down — a failed mint that lingers starves the next one.
  timeout -k 5 60 incus delete -f tpl >/dev/null 2>&1
fi

# The per-role mints lived here (#159): one cold mint each for codex and grok,
# proving that role's own payload — the CLI installs, lands on the
# non-interactive exec PATH, and answers --version. #214 removed the role axis
# and with it box's claim to install anything, so there is no payload of box's
# left to prove and no --role to pass. The generic mechanic those mints rode
# on (metadata, placement, user, isolation parity) is proven by the blank mint
# above and by the drill box below, which is now the same blank shape.

printf '\n  minting the drill box (cold)…\n'
t0=$SECONDS
if mint_box /tmp/mint-drill.log --name drill --size medium; then
  ok "box new --name drill --size medium  ($((SECONDS - t0))s)"
else
  no "box new FAILED — tail: $(tail -3 /tmp/mint-drill.log | tr '\n' ' ')"
  timeout -k 5 60 incus delete -f drill >/dev/null 2>&1
  echo; echo "── cannot continue without a box"; printf '  %s\n' "${findings[@]}"; exit 1
fi

typ="$(box list | awk '$1 == "drill" { print $3 }')"
if [ "$KVM" = 1 ]; then
  [ "$typ" = VM ] && ok "the box is a VM — the trust boundary is real" \
                  || no "the box is '$typ' but /dev/kvm exists — it should have been a VM"
else
  note "the box is '$typ' (no /dev/kvm on this host)"
  skipped B 1 "no /dev/kvm — the box is a container, so 'is it a VM?' has no verdict and the VM trust boundary was NOT validated"
fi

box info drill | grep -q '^IPV4' && ok "info shows an IPv4" || no "info has no IPV4 row"
box info drill | grep -q 'pristine' && ok "info lists the automatic pristine snapshot" || no "info lacks the automatic pristine snapshot"

# The agent-payload probes lived here: 'claude --version' and 'gh --version'
# inside the drill box, with a PATH diagnosis behind them. Both asked whether
# what box installed had landed, and box installs neither any more (#214) — a
# blank box is SUPPOSED to answer no, and the blank mint above already probes
# that directly ("blank box has no claude — nobody home, as designed"). What
# the tenant seed itself ships is the thin floor, so probe THAT instead: it is
# box's own payload, and the one the seed can still be held to.
box exec drill -- sh -c 'command -v tmux' >/dev/null 2>&1 \
  && no "tmux is still in a fresh mint — the seed should carry none since #289" \
  || ok "a fresh mint carries no tmux — 'box tmux' left with the package (#289)"
box exec drill -- shellcheck --version >/dev/null 2>&1 \
  && ok "the seed's unprivileged toolchain landed (shellcheck, #177 decision 3)" \
  || no "'shellcheck --version' failed inside the box — the seed's toolchain did not land"

# --- the snapshot → clone workflow, which is the whole point of the tool ---
box snapshot drill authed 2>&1 | grep -q authed && ok "snapshot drill authed" || no "snapshot failed"
box info drill | grep -q 'authed' && ok "info lists the snapshot label" || no "info does not show the label"
box info drill | grep -q -- '--from drill/pristine' && ok "info's clone hint names the first snapshot it displays (pristine)" || no "info clone hint does not name drill/pristine"

# --- the boundary: an instance box did NOT mint ----------------------
incus launch images:debian/13 payroll >/dev/null 2>&1   # somebody else's instance
sleep 2
box down payroll 2>&1 | grep -q 'no such box' && ok "boundary: 'down' refuses an untagged instance" || no "boundary: 'down' touched an instance box didn't mint!"
box rm payroll --force 2>&1 | grep -q 'no such box' && ok "boundary: 'rm' refuses an untagged instance" || no "boundary: 'rm' would DELETE a foreign instance!"
box incus payroll -- config show 2>&1 | grep -q 'no such box' && ok "boundary: the escape hatch refuses it too" || no "boundary: the hatch reached a foreign instance!"
incus list payroll --format csv --columns ns | grep -q '^payroll,RUNNING' && ok "…and payroll is still running, untouched" || no "payroll was harmed — the boundary leaked"
incus delete -f payroll >/dev/null 2>&1

# --- rename, and its precondition -----------------------------------------
box rename drill archive 2>&1 | grep -qi 'RUNNING' && ok "rename refuses a running box, and says how to fix it" || no "rename did not refuse a running box"
box down drill >/dev/null 2>&1 && ok "down drill" || no "down failed"
box rename drill archive 2>&1 | grep -q 'renamed drill to archive' && ok "rename drill → archive (stopped)" || no "rename failed on a stopped box"
box list | grep -q '^archive' && ok "list shows the new name" || no "list still shows the old name"
box info archive | grep -q authed && ok "the snapshot followed the rename" || no "snapshot lost across the rename"

# --- clone from a snapshot of a renamed box --------------------------------
printf '\n  cloning from the snapshot…\n'
if mint_box /tmp/mint-clone.log --name clone --from archive/authed; then
  ok "new --from archive/authed (clone of a snapshot of a renamed box)"
  box exec clone -- true >/dev/null 2>&1 && ok "the clone is alive and enterable" || no "the clone is not enterable"
else
  no "clone FAILED — tail: $(mint_evidence /tmp/mint-clone.log)"
fi

# --- the escape hatch ------------------------------------------------------
box incus archive -- config show 2>/dev/null | grep -q 'user.box' && ok "hatch: 'incus archive -- config show', instance appended" || no "hatch passthrough failed"
h="$(box incus archive -- config device add {} scratch disk source=/tmp path=/mnt/scratch 2>&1)"
echo "$h" | grep -q 'isolation stack' && ok "hatch warns when a command can break isolation" || no "hatch did not warn on a device add"
box incus archive -- config device remove {} scratch >/dev/null 2>&1

# --- rm, and the guard that did not used to exist --------------------------
box rm clone </dev/null 2>&1 | grep -q 'refusing' && ok "rm with no TTY and no --force refuses (exit 2)" || no "rm destroyed a box with no confirmation!"
box rm clone --force 2>&1 | grep -q 'removed' && ok "rm --force removes the clone" || no "rm --force failed"

# --- the CLI contract ------------------------------------------------------
box lst 2>&1 | grep -q "did you mean 'list'" && ok "typo → did-you-mean, exit 2" || no "unknown command not suggested"
box list archive 2>&1 | grep -q 'box info archive' && ok "'list <box>' points at info" || no "'list <box>' does not point at info"
box snapshot archive --labl x 2>&1 | grep -q 'unknown option' && ok "typo'd flag rejected (not swallowed as a label)" || no "unknown flag was swallowed"

# ===========================================================================
phase C "C. Isolation baseline — does the boundary actually hold? (#15 section A)"
# ===========================================================================
box start archive >/dev/null 2>&1
wait_box archive && ok "archive is back up (agent answering)" \
                 || no "archive did not come back within 2 min of start"

# Sibling isolation needs a sibling. Clone from the snapshot — fast, no cold mint.
printf '\n  cloning a peer for the sibling probes…\n'
if mint_box /tmp/mint-peer.log --name peer --from archive/authed && wait_box peer; then
  ok "peer minted from archive/authed and answering"
else
  no "peer clone failed or never answered — tail: $(mint_evidence /tmp/mint-peer.log)"
fi

# C1 — public egress (#15 A1; resolving the hostname also proves A5, gateway DNS)
BASELINE_OK=1
if [ "$(box_probe archive https://api.github.com 20)" = reachable ]; then
  ok "box reaches the public internet (and gateway DNS resolves public names)"
  aud "A1/A5 egress + public DNS: PASS"
else
  BASELINE_OK=0
  no "box cannot reach the internet (a box that can't is useless)"
  aud "A1/A5 egress: FAIL"
fi

# C2 — box → host (#15 A2). The host DOES listen on the gateway: dnsmasq is on
# :53 by design (that carve-out is what makes egress DNS work). So probe a port
# nothing serves and read refused-vs-dropped — refused would mean the box's
# packet reached the host's stack, which is the thing the firewall must prevent.
# (No background listener: one less process to leak, one less way to wedge.)
gw="$(boxnet_gw)"
hv="$(box_probe archive "http://$gw:8099")"
case "$hv" in
  reachable|refused)
    no "THE BOX'S PACKETS REACH THE HOST on $gw:8099 [$hv] — the firewall rules are not holding"
    aud "A2 box→host: FAIL — $hv (the packet reached the host's stack)" ;;
  dropped)
    ok "box → host is blocked (no path to the machine's sockets)"
    aud "A2 box→host: dropped" ;;
  # Unreachable today: box_probe answers reachable|refused|dropped and nothing
  # else. The arm is pre-existing insurance for the day it grows a fourth
  # outcome; the `skipped` is here so that day costs the ledger nothing rather
  # than silently shortening C by one. Not live wiring — read it as a seatbelt.
  *)
    note "box→host probe inconclusive ($hv)"
    aud "A2 box→host: INCONCLUSIVE ($hv)"
    skipped C 1 "C2 box→host was inconclusive ($hv) — no verdict on the firewall" ;;
esac

# C3 — RFC1918 (#15 A2)
case "$(box_probe archive http://192.168.1.1)" in
  reachable|refused)
    no "box REACHED a private-range address — the ACL is not dropping RFC1918"
    aud "A2 RFC1918: FAIL" ;;
  *)
    ok "box → RFC1918 is dropped by the ACL"
    aud "A2 RFC1918: dropped" ;;
esac

# C4 — SIBLING isolation (#15 A3): the central claim of #12, and the one probe
# three runs failed to fire. NO listener on the peer, deliberately — a closed
# port answers the question just as well (refused = the packet arrived), and
# the listener was what kept wedging the run. Ping corroborates: if the two
# disagree, say so rather than pick one.
PEER_IP="$(boxnet_ip peer)"
ARCH_IP_PRE="$(boxnet_ip archive)"
if [ -n "$PEER_IP" ] && [ "$PEER_IP" = "$ARCH_IP_PRE" ]; then
  # Guard, because this actually happened: a clone inherited its source's
  # machine-id, hence its DHCP lease, hence its ADDRESS. Probing "archive →
  # peer" was archive probing itself, and would have reported a cheerful
  # "reachable" as a sibling-isolation failure. Never let A3 answer this.
  no "archive and peer hold the SAME address ($PEER_IP) — the clone did not get its own identity; A3 cannot be probed"
  aud "A3 sibling: NOT PROBED — clone/source IP collision (see the clone-identity fix)"
elif [ -n "$PEER_IP" ]; then
  inf "probing archive ($ARCH_IP_PRE) → peer ($PEER_IP): a REFUSAL means it arrived; silence means it was dropped"
  v="$(box_probe archive "http://$PEER_IP:8088")"
  box_pings archive "$PEER_IP"; png=$?

  if [ "$v" = reachable ] || [ "$v" = refused ]; then
    no "BOX A REACHES BOX B ($PEER_IP) — sibling isolation does NOT hold [tcp: $v]"
    aud "A3 sibling: FAIL — tcp $v (the packet arrived)"
  elif [ "$png" -eq 0 ]; then
    no "TCP to box B goes nowhere, but it ANSWERS ICMP — sibling isolation is only partial"
    aud "A3 sibling: PARTIAL — tcp dropped, ping replies"
  else
    ok "box A cannot reach box B: TCP goes nowhere, ICMP unanswered"
    aud "A3 sibling: BLOCKED — tcp dropped + no icmp reply (security.port_isolation)"
  fi
else
  no "could not read peer's boxnet address — the sibling probe never ran"
  aud "A3 sibling: NOT PROBED (no boxnet address on peer)"
fi

# C5 — DNS enumeration (#15 A4). Now a CONTRACT, not an observation: setup-host
# sets dns.mode=none precisely so a box cannot enumerate its siblings.
e1="$(in_box archive getent hosts peer)"
e2="$(in_box archive getent hosts peer.incus)"
if [ -n "$e1$e2" ]; then
  no "a box can still RESOLVE its sibling ($(printf '%s' "$e1$e2" | head -1 | cut -c1-40)) — dns.mode=none is not holding"
  aud "A4 dns enumeration: LEAKS — the fix is not in effect"
else
  ok "a box cannot resolve its sibling's name (no DNS enumeration)"
  aud "A4 dns enumeration: blocked (dns.mode=none)"
fi

# C6 — IPv6 off (#15 A6): every ACL rule is IPv4-only; off is the only cover.
[ "$(incus network get boxnet ipv6.address 2>/dev/null)" = none ] \
  && { ok "boxnet ipv6.address = none (the IPv4-only ACLs have no uncovered path)"; aud "A6 ipv6: none, as contract requires"; } \
  || { no "boxnet has IPv6 enabled — and not one ACL rule covers IPv6"; aud "A6 ipv6: ENABLED and uncovered"; }

# C7 — inbound, host → box (#15 A7): the ACL's default ingress drop. Same
# listener-free logic, run from the host this time.
ARCH_IP="$(boxnet_ip archive)"
if [ -n "$ARCH_IP" ]; then
  hmsg="$(curl -sS -m 5 -o /dev/null "http://$ARCH_IP:8087" 2>&1)"; hrc=$?
  if [ "$hrc" -eq 0 ]; then hv=reachable
  elif printf '%s' "$hmsg" | grep -q 'Connection refused'; then hv=refused
  else hv=dropped
  fi
  case "$hv" in
    reachable|refused)
      no "the HOST's packets REACH the box ($ARCH_IP) — the default ingress drop is not holding [$hv]"
      aud "A7 inbound host→box: FAIL — $hv (the packet arrived)" ;;
    dropped)
      ok "host → box is dropped (entry is 'incus exec' only, as designed)"
      aud "A7 inbound host→box: dropped" ;;
    # Unreachable today, same as C2's: the if/elif/else above covers exactly the
    # three values box_probe returns. Seatbelt, not live wiring — the `skipped`
    # keeps the ledger honest if that ever stops being true.
    *)
      note "inbound probe inconclusive ($hv)"
      aud "A7 inbound host→box: INCONCLUSIVE ($hv)"
      skipped C 1 "C7 host→box was inconclusive ($hv) — no verdict on the ingress drop" ;;
  esac
else
  no "could not read archive's boxnet address — the inbound probe never ran"
  aud "A7 inbound host→box: NOT PROBED"
fi

# ===========================================================================
phase E "E. box expose — a deliberate loopback door (#55)"
# ===========================================================================
# archive is a running box. Start a DETACHED listener on 0.0.0.0 inside it,
# expose the port, and prove the door works from the HOST's loopback. Then
# prove removing it closes the door, and that a NON-exposed port still obeys
# the ingress drop — the feature must not globally weaken A7.
#
# python3, not node (#214). The listener used to be four lines of node,
# available because the box had been converged into an agent box; box converges
# nothing now, so this phase would have died on a missing interpreter. python3
# is on the guest unconditionally — cloud-init is written in it, so a cloud
# image that boots has it — and 'http.server' serves the response body out of
# a file, which is what the probe below greps for.
EP=8091; EHP=18091
srv="$(mktemp)"
printf 'box-expose-ok\n' >"$srv"
if incus file push "$srv" archive/tmp/expose-www/index.html --create-dirs >/dev/null 2>&1; then
  rm -f "$srv"
  # Detached: setsid + all fds redirected so 'incus exec' returns at once and
  # nothing holds its stdout (trap 2/3). The listener outlives the exec.
  timeout -k 5 20 incus exec archive -- sh -c "setsid python3 -m http.server $EP --bind 0.0.0.0 --directory /tmp/expose-www >/tmp/srv.log 2>&1 </dev/null &" </dev/null
  sleep 3
  xlog="$(mktemp)"
  if box expose archive "$EP" "$EHP" >"$xlog" 2>&1; then
    ok "box expose archive $EP $EHP — the device was added"
    box expose archive --list 2>/dev/null | grep -q "$EP" \
      && ok "expose --list shows the open door" || no "expose --list does not show the exposure"
    box info archive 2>/dev/null | grep -qi "$EP" \
      && ok "box info surfaces the exposure (a box with a hole says so)" \
      || { note "box info does not mention the exposure (nice-to-have)"
           skipped E 1 "box info does not surface the exposure — recorded as a NOTE, so E owes one verdict less"; }
    # THE test: does the host's loopback reach the box's server?
    sleep 2
    if curl -sS -m 6 "http://127.0.0.1:$EHP" 2>/dev/null | grep -q box-expose-ok; then
      ok "127.0.0.1:$EHP reaches the box's server — the door WORKS"
    else
      no "127.0.0.1:$EHP does NOT reach the box — the proxy/ACL mechanism needs work (#55)"
      inf "srv.log inside the box: $(in_box archive cat /tmp/srv.log 2>/dev/null | tail -2 | tr '\n' ' ')"
    fi
    # A NON-exposed port must still be dropped — the feature is per-port, not a
    # global ingress opening.
    nemsg="$(curl -sS -m 5 -o /dev/null "http://$ARCH_IP:9099" 2>&1)"
    printf '%s' "$nemsg" | grep -q 'Connection refused' \
      && no "a non-exposed port answered on the box — expose opened ingress too wide" \
      || ok "a non-exposed port is still dropped — expose is per-port, A7 survives"
    # Close it, and confirm the door shuts.
    box expose archive --remove "$EP" >/dev/null 2>&1 && ok "box expose --remove closed the device" || no "expose --remove failed"
    sleep 2
    curl -sS -m 5 -o /dev/null "http://127.0.0.1:$EHP" 2>/dev/null \
      && no "the host still reaches the box after --remove — the door did not shut" \
      || ok "after --remove, 127.0.0.1:$EHP is dead — the door shut"
  else
    no "box expose failed to add the device"
    inf "what box and incus actually said:"
    sed 's/^/          /' "$xlog" 2>/dev/null
    rm -f "$srv" 2>/dev/null
  fi
  rm -f "$xlog" 2>/dev/null
  timeout -k 5 15 incus exec archive -- pkill -f 'http.server' </dev/null >/dev/null 2>&1
else
  rm -f "$srv"
  no "could not push the test server into archive — expose phase did not run"
fi

# ===========================================================================
phase D "D. The isolation contract, stated"
# ===========================================================================
# Phase D used to REHEARSE the hardening on a throwaway host, because nobody
# knew whether it would work. That question is settled: the hardening now ships
# in setup-host.sh and box-firewall.sh, so phase C tests the real thing
# and there is nothing left to rehearse. What the rehearsal established, kept
# here so it is not re-litigated:
#
#   · @internal is REJECTED as an ACL destination on a bridge network
#     ("Unsupported nftables subject") — so the sibling drop is an nftables
#     bridge-family rule, not an ACL rule. It has to be: an L3 ACL never sees
#     frames switched between two ports of one bridge, which is why box→box was
#     wide open while the ACL looked airtight.
#   · dns.mode=none closes the enumeration leak and public egress survives it.
#   · security.ipv4_filtering BREAKS the box's networking (dockerd comes up but
#     cannot pull or run a container). VETOED — it is not in the shipped stack.
#
inf "@internal: unsupported on bridge ACLs ⇒ the sibling drop is an nft bridge rule"
inf "dns.mode=none: shipped (closes DNS enumeration, egress unaffected)"
inf "security.ipv4_filtering: VETOED — it breaks the box. Not shipped."
inf "the contract is now tested in phase C against the real stack, not rehearsed"

# The lesson that cost the most: a verdict measured on a broken box is not a
# verdict. Run 7 reported "L2 filtering BREAKS the box" from a box whose network
# was already dead, and #16 was nearly redesigned around it. If the baseline
# failed, say plainly that phase C's isolation results cannot be trusted.
if [ "$BASELINE_OK" -ne 1 ]; then
  no "the box could not reach the internet AT ALL — every isolation result above is suspect, not a pass"
  inf "a boundary that 'holds' on a box with no network holds nothing. fix the baseline, re-run."
  inf "start with:  bash drill/doctor.sh"
fi

# ===========================================================================
if [ "$KEEP" = 1 ]; then
  phase - "Boxes left up (--keep-boxes)"
  box list
  # This line used to warn that "the D-phase mutations (dns.mode=none, NIC
  # filtering) are still applied". D stopped mutating anything when the
  # hardening shipped — dns.mode=none is part of the stack setup-host builds,
  # and the NIC filtering was vetoed and never shipped — so the warning was
  # spending an operator's caution on a phantom, on a script whose header says
  # run it on a machine you can format (#154).
  inf "note: they ride the ordinary shipped stack — the drill leaves no mutations of its own"
  skipped T 1 "--keep-boxes — the boxes stay up on purpose, so teardown is not asserted this run"
else
  phase T "T. Teardown — every box the drill minted is gone"
  # every name the drill can have left, whatever branch a partial run took
  for n in drill clone archive peer tpl codex grok; do box rm "$n" --force >/dev/null 2>&1; done
  # Assert OUR boxes are gone — not that the host is empty. The rm loop above
  # already embodies the discipline (only names the drill minted); demanding
  # 'no boxes yet' here would flag any pre-existing operator box as a failure.
  leftover="$(box list 2>/dev/null | grep -E '^(drill|clone|archive|peer|tpl|codex|grok)([[:space:]]|$)' || true)"
  [ -z "$leftover" ] && ok "teardown: every box the drill minted is gone" \
                     || no "a drill box survived teardown: $(printf '%s' "$leftover" | awk '{print $1}' | tr '\n' ' ')"
fi

# >>> ledger summary (#153) — test/cli.sh extracts this block verbatim, down to
# and INCLUDING the exit gate at the end of the file, and executes it. Grepping
# for the shortfall verdict proves only that the line is written; #153's whole
# criterion is an EXIT STATUS, so the exit status is what has to be driven. Keep
# the block self-contained: it may assume the verdict helpers, the ledger and
# the record block above it — all three are extracted alongside it — plus the
# four settings the record needs from around it: RECORD and KEEP off the command
# line, CHECKOUT off the script's own path and BOX_SHARE off the uid (#225).
phase - "Summary"
# Everything the floor grades on is read BEFORE the floor's own verdict, which
# would otherwise count itself: the shortfall FAIL lands under phase '-' and so
# in the '?' bucket, deliberately, and the per-phase line is already printed by
# the time it fires. What it does move is `fail`, which is the point — a short
# run leaves here non-zero.
expected="$(ledger_expected)"
ran=$(( pass + fail ))
short="$(ledger_short)"
ledger_line
if [ "$ran" -lt "$expected" ] || [ -n "$short" ]; then
  # "never ran" is the common road here, not the only one: a block that failed
  # early emits its one `no` and leaves the rest of its phase unasserted, which
  # is short too. The verdict names both rather than diagnosing the wrong one.
  summary_no "the drill ran SHORT: $ran of $expected expected probes${short:+ — short in:$short} — a phase, or a block that depends on one, never ran, or failed before emitting the rest. This is not a clean sweep, whatever the pass count says (#153)."
fi
printf '  %s/%s passed, %s failed\n' "$pass" "$expected" "$fail"
if [ "${#findings[@]}" -gt 0 ]; then
  echo
  printf '  %s\n' "${findings[@]}"
fi

# This block was headed "paste this block into heavy-duty/claudebox#15" — an
# issue that is complete, in a repo that has been renamed. The mechanism outlived
# its addressee, and it is worth keeping: these are the closest thing the harness
# has to structured output. So it is retargeted rather than deleted, at the one
# reader it has left — the record, which --emit-record now carries them into, two
# lines below (#154).
if [ "${#audit[@]}" -gt 0 ]; then
  phase - "Isolation audit answers — the measurements, as the record carries them"
  printf '  %s\n' "${audit[@]}"
fi

# The record, last, so it carries the shortfall verdict above it — a record
# emitted before that `no` fires would report a clean sweep on a short run,
# which is the defect #153 closed and this must not reopen (#152).
#
# It cannot move the exit status, and that is deliberate rather than incidental:
# the status is the floor's verdict on the DRILL, and a full disk has no opinion
# about whether the trust boundary held. The path was already checked writable
# before the run started, so reaching the failure branch here means something
# changed underfoot — loud on stderr, in the findings, and never silent.
if [ -n "${RECORD:-}" ]; then
  REC_RUN_ID="${REC_RUN_ID:-${RUN_ID:-}}"
  record_collect "$CHECKOUT" "$BOX_SHARE" "$KEEP" "$TREE_DIRTY"
  if record_write "$RECORD"; then
    echo
    inf "record written: $RECORD"
    inf "it is a SKELETON — write what the findings mean for the release, then delete its draft line."
    inf "run ID $REC_RUN_ID goes in rig's and cast's records for this release too."
  else
    echo "drill: FAILED to write the record to $RECORD" >&2
    note "the record could not be written to $RECORD — the numbers above are the only copy"
  fi
fi

echo
inf "this host still has Incus, boxnet, the ACL, the profile and the firewall rules"
# It used to add "(plus, unless re-run: dns.mode=none and NIC filtering from the
# D phase)" — residue from a rehearsal that no longer runs. dns.mode=none is the
# shipped stack's, not the drill's, and the NIC filtering was vetoed (#154).
inf "— the shipped stack, as setup-host.sh leaves it; the drill adds nothing of its own."
inf "to undo:  box uninstall --purge-host   (or $BOX_SHARE/current/host/teardown-host.sh)"
[ "$fail" -eq 0 ]
# <<< ledger summary
