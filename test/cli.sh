#!/usr/bin/env bash
# Dependency-free CLI assertions for box. Run: bash test/cli.sh
#
# Runnable by a NON-root user with NO Incus installed — that is the whole point.
# Anything that needs a real incus daemon (every lifecycle command) is proven the
# way rig proves its root-only paths: source the pure function and drive it against
# a fixture, or grep the load-bearing line so a deleted guard cannot ship green.
# Deliberately no `set -e` — the harness asserts on failing commands.
set -u
# BOX_YES is this family's documented automation switch, so an operator's CI
# wrapper may well export it. Checks that drive a destructive script for real
# would then take the CONSENT arm instead of the refusal they are asserting —
# turning this suite into `box uninstall --purge-host` on the host it runs on.
# Individual call sites use `env -u BOX_YES`; this is the belt to that braces,
# so the header's "runnable anywhere" promise cannot be broken by one export.
unset BOX_YES
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0 FAIL=0

# check <desc> <want_exit> <want_substr> <cmd...>
# Runs cmd, asserts exit code and (if non-empty) that combined output
# contains want_substr.
check() {
  local desc="$1" want="$2" substr="$3"; shift 3
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL: $desc — exit $rc, wanted $want"
    printf '%s\n' "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1)); return
  fi
  if [ -n "$substr" ] && ! printf '%s' "$out" | grep -qF -e "$substr"; then
    echo "FAIL: $desc — output missing '$substr'"
    printf '%s\n' "$out" | sed 's/^/    /'
    FAIL=$((FAIL + 1)); return
  fi
  echo "ok: $desc"; PASS=$((PASS + 1))
}

BOX="$ROOT/bin/box"

# ---------------------------------------------------------------------------
# The CLI contract: dispatch, help, usage errors. No incus needed — these all
# resolve before any daemon call. Exit codes are box's own (0 ok / 1 wrong /
# 2 you-asked-wrong), read straight from bin/box and confirmed by running it.
# ---------------------------------------------------------------------------
# box with no args is 'help' (cmd="${1:-help}"), which prints the general usage
# and exits 0 — NOT rig's exit-2 bare-usage. Assert box's actual contract.
check "no args → general help, exit 0"        0 "USAGE"            "$BOX"
check "no args help names the command form"   0 "box <command>"   "$BOX"
check "--help exits 0"                         0 "USAGE"            "$BOX" --help
check "-h exits 0"                             0 "USAGE"            "$BOX" -h
check "help exits 0"                           0 "USAGE"            "$BOX" help
check "help <command> → that command's usage"  0 "usage: box new"  "$BOX" help new
check "--version exits 0"                       0 "box"             "$BOX" --version
# Unknown command is a usage error (2), and it says so — the suggester may add a
# 'did you mean', but the stem is stable.
check "unknown command exits 2"                2 "unknown command" "$BOX" frobnicate
check "unknown command points at help"         2 "box help"        "$BOX" zzzzzz
# Options before the command are the classic mistake; box names the fix.
check "option before command exits 2"          2 "options come after the command" "$BOX" --json list
# A missing required positional is a usage error carrying that command's synopsis.
check "new without --name exits 2"             2 "usage: box new"    "$BOX" new
check "shell without a box exits 2"            2 "usage: box shell"  "$BOX" shell
check "root without a box exits 2"             2 "usage: box root"   "$BOX" root
check "checkup without a box exits 2"          2 "usage: box checkup" "$BOX" checkup
check "restore without arg2 needs a box first" 2 "usage: box restore" "$BOX" restore
# An unknown flag is refused, not swallowed as a positional (the --labl bug).
check "unknown flag on list exits 2"           2 "unknown option"   "$BOX" list --nope
# A flag that needs a value and gets none.
check "--name with no value exits 2"           2 "--name needs a value" "$BOX" new --name
# #159's hard cut is resolved before the Incus preflight, so every retired
# spelling teaches its replacement even on a machine with no daemon.
check "new: --template blank hard-cuts to the argumentless blank mint (#159)" 2 \
  "omit --template" "$BOX" new --name work --template blank
check "new: --template tenant hard-cuts the internal seed (#159)" 2 \
  "omit --template, that IS the default mint" \
  "$BOX" new --name work --template tenant
for retired in claude-box codex-box grok-box kimi-box; do
  check "new: --template $retired hard-cuts to a blank mint (#159, #214)" 2 \
    "every box is blank now" "$BOX" new --name work --template "$retired"
done
# --role is a HARD CUT and refuses LOUDLY (#214): unrecognized would be an
# "unknown option", which teaches nothing to the operator who typed the flag
# this release removed. Every arm of the message is asserted, because the
# message IS the replacement path — the issue's criterion names 'box root' and
# the bootstrap step, and a message missing either sends the operator nowhere.
check "new: --role is refused, not unrecognized (#214)" 2 \
  "--role is gone" "$BOX" new --name work --role claude-box
check "new: --role's refusal names 'box root' (#214)" 2 \
  "box root work" "$BOX" new --name work --role claude-box
check "new: --role's refusal names the bootstrap step (#214)" 2 \
  "rig bootstrap claude-box --user dev" "$BOX" new --name work --role anything-at-all
check "new: --role's refusal keeps --size in the taught line (#214)" 2 \
  "box new --name work --size medium" "$BOX" new --name work --role claude-box
check "new: --role refuses with no value too (#214)" 2 \
  "--role is gone" "$BOX" new --name work --role
check "new: --user is a plain Linux user name (#159)" 2 \
  "--user must be a plain Linux user name" "$BOX" new --name work --user 'bad user'
check "new: --user rides the default mint, not a dedicated template (#214)" 2 \
  "declares its own user" "$BOX" new --name work --template staging-box --user dev
check "new: --from keeps named sizes on the fresh-mint side (#159)" 2 \
  "explicit --cpu/--memory/--disk overrides, not --size" \
  "$BOX" new --name copy --from work --size medium
check "new: an unknown named size is refused (#159)" 2 \
  "--size must be small, medium, or large" "$BOX" new --name work --size huge
check "help new: publishes the large size row (#159)" 0 "large       8    16GiB  120GiB" \
  "$BOX" help new

# ---------------------------------------------------------------------------
# box checkup — the guest-side fitness report (#258). doctor remains the host
# report; this path enters one named guest as root and only reads state.
# ---------------------------------------------------------------------------
check "help checkup: asks whether one guest is fit" 0 "guest is fit" "$BOX" help checkup
check "help checkup: documents its finding exit status" 0 "exits 0" "$BOX" help checkup
checkup_row() {
  local row; row="$(grep -F '"checkup^' "$BOX")"
  case "$row" in *"fn:cmd_checkup"*) printf checkup ;; *) return 1 ;; esac
}
check "checkup: is a separate command from doctor" 0 "checkup" checkup_row
check "checkup: current mints carry the #178 seed generation" 0 "user.box.seed" \
  grep -F 'user.box.seed=' "$BOX"
check "checkup: tenant is the #178 generation" 0 "tenant/2" \
  grep -F 'seed_generation=tenant/2' "$BOX"

CHECKUP="$ROOT/guest/checkup.sh"
check "checkup: guest probe exists" 0 "" test -f "$CHECKUP"
check "checkup: guest probe is valid bash" 0 "" bash -n "$CHECKUP"
check "checkup: OOM history covers every retained boot, not only journalctl -k" 0 \
  "_TRANSPORT=kernel" grep -F '_TRANSPORT=kernel' "$CHECKUP"
check "checkup: guest probe contains no mutation command" 1 "" \
  grep -nE '(^|[;&|[:space:]])(touch|mkdir|rm|mv|cp|install|truncate|mount|swapon|swapoff|systemctl|sed -i)([;&|[:space:]]|$)|(^|[[:space:]])>[^&]' "$CHECKUP"
checkup_host_mutates() {
  awk '/^cmd_checkup\(\) \{/,/^\}/' "$BOX" \
    | grep -qE 'incus (config set|config unset|file push)'
}
check "checkup: host wrapper does not change instance config" 1 "" checkup_host_mutates

CKWORK="$(mktemp -d)"
CKSHIM="$CKWORK/shim"; mkdir -p "$CKSHIM"
cat > "$CKSHIM/free" <<'SHIM'
#!/usr/bin/env bash
[ "${FAKE_FREE_RC:-0}" -eq 0 ] || { printf '%s\n' "${FAKE_FREE_ERROR:-free failed}" >&2; exit "${FAKE_FREE_RC}"; }
printf 'Mem: %s 0 0 0 0 %s\nSwap: %s 0 %s\n' \
  "${FAKE_MEM_TOTAL:?}" "${FAKE_MEM_AVAILABLE:?}" \
  "${FAKE_SWAP_TOTAL:-0}" "${FAKE_SWAP_TOTAL:-0}"
SHIM
cat > "$CKSHIM/df" <<'SHIM'
#!/usr/bin/env bash
[ "${FAKE_DF_RC:-0}" -eq 0 ] || { printf '%s\n' "${FAKE_DF_ERROR:-df failed}" >&2; exit "${FAKE_DF_RC}"; }
printf '1B-blocks Avail Use%%\n%s %s %s\n' \
  "${FAKE_DISK_TOTAL:?}" "${FAKE_DISK_AVAILABLE:?}" "${FAKE_DISK_USED:?}"
SHIM
cat > "$CKSHIM/findmnt" <<'SHIM'
#!/usr/bin/env bash
[ "${FAKE_FINDMNT_RC:-0}" -eq 0 ] || { printf '%s\n' "${FAKE_FINDMNT_ERROR:-}" >&2; exit "${FAKE_FINDMNT_RC}"; }
printf '%s %s %s\n' "${FAKE_TMP_FSTYPE:?}" "${FAKE_TMP_SIZE:?}" "${FAKE_TMP_OPTIONS:-rw}"
SHIM
cat > "$CKSHIM/journalctl" <<'SHIM'
#!/usr/bin/env bash
[ "${FAKE_JOURNAL_RC:-0}" -eq 0 ] || { printf '%s\n' "${FAKE_JOURNAL_ERROR:-permission denied}" >&2; exit "${FAKE_JOURNAL_RC}"; }
printf '%s' "${FAKE_JOURNAL_OUTPUT:-}"
SHIM
cat > "$CKSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
case "$1" in
  config)
    case "${*: -1}" in
      user.box) printf '1\n' ;;
      user.box.seed) printf 'tenant/2\n' ;;
      limits.memory.swap) printf 'allowed\n' ;;
    esac ;;
  list) printf 'virtual-machine\n' ;;
  exec)
    while [ "$1" != -- ]; do shift; done
    shift
    exec "$@" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "$CKSHIM"/*

run_checkup() { # run_checkup <vm|container> <seed> [swap-policy]
  env PATH="$CKSHIM:$PATH" \
    FAKE_MEM_TOTAL="${FAKE_MEM_TOTAL:-4294967296}" \
    FAKE_MEM_AVAILABLE="${FAKE_MEM_AVAILABLE:-2147483648}" \
    FAKE_SWAP_TOTAL="${FAKE_SWAP_TOTAL:-0}" \
    FAKE_FREE_RC="${FAKE_FREE_RC:-0}" \
    FAKE_DISK_TOTAL="${FAKE_DISK_TOTAL:-42949672960}" \
    FAKE_DISK_AVAILABLE="${FAKE_DISK_AVAILABLE:-8589934592}" \
    FAKE_DISK_USED="${FAKE_DISK_USED:-80%}" \
    FAKE_DF_RC="${FAKE_DF_RC:-0}" \
    FAKE_TMP_FSTYPE="${FAKE_TMP_FSTYPE:-tmpfs}" \
    FAKE_TMP_SIZE="${FAKE_TMP_SIZE:-2147483648}" \
    FAKE_TMP_OPTIONS="${FAKE_TMP_OPTIONS:-rw,nosuid,nodev}" \
    FAKE_FINDMNT_RC="${FAKE_FINDMNT_RC:-0}" \
    FAKE_JOURNAL_RC="${FAKE_JOURNAL_RC:-0}" \
    FAKE_JOURNAL_OUTPUT="${FAKE_JOURNAL_OUTPUT:-}" \
    FAKE_JOURNAL_ERROR="${FAKE_JOURNAL_ERROR:-}" \
    bash "$CHECKUP" "$@"
}

run_checkup_command() {
  env PATH="$CKSHIM:$PATH" \
    FAKE_MEM_TOTAL=4294967296 FAKE_MEM_AVAILABLE=2147483648 \
    FAKE_SWAP_TOTAL=4294967296 \
    FAKE_DISK_TOTAL=42949672960 FAKE_DISK_AVAILABLE=8589934592 \
    FAKE_DISK_USED=80% FAKE_TMP_FSTYPE=tmpfs FAKE_TMP_SIZE=1073741824 \
    FAKE_TMP_OPTIONS=rw,nosuid,nodev FAKE_JOURNAL_RC=0 \
    "$BOX" checkup fixture
}
check "checkup: full CLI resolves the box and streams the guest probe" 0 \
  "8.0 GiB available of 40.0 GiB" run_checkup_command

check "checkup: legacy VM names missing swap and #178's seed as the fix" 1 "seed #178" \
  run_checkup vm unknown
check "checkup: legacy VM names the 50%-of-RAM /tmp finding" 1 "50% of VM memory" \
  run_checkup vm unknown
check "checkup: reports disk headroom as numbers" 1 "8.0 GiB available of 40.0 GiB" \
  run_checkup vm unknown
check "checkup: reports memory headroom as numbers" 1 "2.0 GiB available of 4.0 GiB" \
  run_checkup vm unknown
check "checkup: an empty readable kernel journal is explicitly clean" 1 "no OOM kill logged" \
  run_checkup vm unknown

checkup_unknown_seed_finds_only_seed() {
  local out rc=0
  out="$(FAKE_TMP_SIZE=1073741824 FAKE_SWAP_TOTAL=4294967296 \
    run_checkup vm unknown)" || rc=$?
  [ "$rc" -eq 1 ] \
    && grep -q '^SEED.*unknown' <<<"$out" \
    && ! grep -q '^FIX' <<<"$out"
}
check "checkup: an otherwise-clean unknown seed is a finding" 0 "" \
  checkup_unknown_seed_finds_only_seed

checkup_current_vm() {
  FAKE_TMP_SIZE=1073741824 FAKE_SWAP_TOTAL=4294967296 run_checkup vm tenant/2
}
checkup_current_vm_quiet() {
  local out; out="$(checkup_current_vm)"
  ! grep -q "FIX" <<<"$out" && grep -q "4.0 GiB" <<<"$out" && grep -q "1.0 GiB" <<<"$out"
}
check "checkup: current VM seed is quiet on swap and /tmp" 0 "" checkup_current_vm_quiet
checkup_current_small_vm_quiet() {
  local out
  out="$(FAKE_MEM_TOTAL=2147483648 FAKE_MEM_AVAILABLE=1073741824 \
    checkup_current_vm)"
  ! grep -q '^FIX' <<<"$out" && grep -q '^TMP.*1.0 GiB' <<<"$out"
}
check "checkup: current 2 GiB VM keeps the fixed 1 GiB /tmp quiet" 0 "" \
  checkup_current_small_vm_quiet

checkup_larger_legacy_tmp() {
  FAKE_TMP_SIZE=2576980378 FAKE_SWAP_TOTAL=4294967296 run_checkup vm unknown
}
check "checkup: a larger legacy /tmp cannot escape the finding window" 1 \
  "50% of VM memory" checkup_larger_legacy_tmp

checkup_container() { FAKE_TMP_SIZE=1073741824 run_checkup container tenant/2 allowed; }
check "checkup: container swap is host-managed, never a missing-swap fault" 0 "host-managed" \
  checkup_container
checkup_container_no_vm_fault() {
  local out; out="$(checkup_container)"
  ! grep -q "missing swap" <<<"$out"
}
check "checkup: container with no swap has no VM swap finding" 0 "" \
  checkup_container_no_vm_fault
check "checkup: legacy container branches the /tmp finding at its own mode" 1 \
  "50% of the container's reported memory" run_checkup container unknown allowed

checkup_unmounted_tmp_continues() {
  local out rc=0
  out="$(FAKE_FINDMNT_RC=1 FAKE_TMP_SIZE=1073741824 FAKE_SWAP_TOTAL=4294967296 \
    run_checkup vm tenant/2)" || rc=$?
  [ "$rc" -eq 1 ] \
    && grep -q "TMP.*could not determine /tmp's mount" <<<"$out" \
    && grep -q '^SWAP.*4.0 GiB total' <<<"$out" \
    && grep -q '^OOM.*no OOM kill logged' <<<"$out"
}
check "checkup: an unmounted /tmp is explicit and later checks still run" 0 "" \
  checkup_unmounted_tmp_continues

checkup_unreadable_metrics_continue() {
  local out rc=0
  out="$(FAKE_DF_RC=1 FAKE_FREE_RC=1 FAKE_TMP_SIZE=1073741824 \
    run_checkup container tenant/2 allowed)" || rc=$?
  [ "$rc" -eq 1 ] \
    && grep -q '^DISK.*could not determine disk headroom' <<<"$out" \
    && grep -q '^MEMORY.*could not determine memory headroom' <<<"$out" \
    && grep -q '^SWAP.*host-managed' <<<"$out" \
    && grep -q '^OOM.*no OOM kill logged' <<<"$out"
}
check "checkup: unreadable headroom is explicit and later checks still run" 0 "" \
  checkup_unreadable_metrics_continue

checkup_unreadable_journal() {
  FAKE_TMP_SIZE=1073741824 FAKE_SWAP_TOTAL=4294967296 \
    FAKE_JOURNAL_RC=1 FAKE_JOURNAL_ERROR="permission denied" run_checkup vm tenant/2
}
check "checkup: unreadable OOM history is not reported clean" 1 "could not read kernel journal" \
  checkup_unreadable_journal
checkup_unreadable_not_clean() {
  local out; out="$(checkup_unreadable_journal 2>&1 || true)"
  ! grep -q "no OOM kill logged" <<<"$out"
}
check "checkup: unreadable OOM history does not claim none" 0 "" \
  checkup_unreadable_not_clean

checkup_permission_words_are_data() {
  FAKE_TMP_SIZE=1073741824 FAKE_SWAP_TOTAL=4294967296 \
    FAKE_JOURNAL_OUTPUT="kernel audit: permission denied to pid 7" run_checkup vm tenant/2
}
check "checkup: readable journal content does not impersonate a read failure" 0 \
  "no OOM kill logged" checkup_permission_words_are_data

rm -rf "$CKWORK"

# ---------------------------------------------------------------------------
# box exec — preserve command argv across the login-environment boundary
# (#169). `sudo -i <command...>` joins argv into one shell string; its escaped
# newline becomes a continuation, so a multi-line body can fuse into a
# different valid command and still return 0. Drive cmd_exec through a fake
# incus boundary that validates the wrapper shape and then executes it. This
# test therefore fails against the old -i implementation before trusting the
# marker files.
# ---------------------------------------------------------------------------
EXECFN="$(mktemp)"
grep '^cmd_exec()' "$BOX" > "$EXECFN"
check "box exec: cmd_exec extracted (guards the grep)" 0 "exec \"\$@\"" cat "$EXECFN"
check "box exec: extracted function is valid bash" 0 "" bash -n "$EXECFN"
check "box exec: command argv never rides sudo -i" 1 "" grep -q -- ' -i ' "$EXECFN"

exec_fixture() { # exec_fixture <command> [arg...]
  bash -c '
    set -e
    . "$0"
    box_user() { printf "%s\n" fixture-user; }
    incus() {
      [ "$1" = exec ] && [ "$2" = fixture ] && [ "$3" = -- ]
      shift 3
      [ "$1" = sudo ] && [ "$2" = -u ] && [ "$3" = fixture-user ] &&
        [ "$4" = -H ]
      shift 4
      "$@"
    }
    inst=fixture
    args=(fixture "$@")
    cmd_exec
  ' "$EXECFN" "$@"
}

EXEC_STATE="$(mktemp -d)"
exec_body="set -euo pipefail
touch '$EXEC_STATE/step-one'
touch '$EXEC_STATE/step-two'"
check "box exec: silent-success multiline body executes each statement" 0 "" \
  exec_fixture bash -lc "$exec_body"
check "box exec: multiline step one was not fused into set argv" 0 "" \
  test -f "$EXEC_STATE/step-one"
check "box exec: multiline step two was not fused into set argv" 0 "" \
  test -f "$EXEC_STATE/step-two"
check "box exec: plain argv remains separate" 0 "one argument" \
  exec_fixture printf '%s\n' "one argument"
rm -rf "$EXEC_STATE"
rm -f "$EXECFN"

# ---------------------------------------------------------------------------
# A shim `id` on PATH: lets us drive install.sh's DEST branch with a canned uid +
# group output, exactly the way rig drives assert_runner_repo against fixtures.
# ---------------------------------------------------------------------------
SHIMDIR="$(mktemp -d)"
cat > "$SHIMDIR/id" <<'SHIM'
#!/usr/bin/env bash
# Fake `id`: -u prints $FAKE_UID, -nG prints $FAKE_GROUPS. Just enough for
# install.sh's DEST branch, which only ever asks these two.
case "${1:-}" in
  -u)  printf '%s\n' "${FAKE_UID:-1000}" ;;
  -nG) printf '%s\n' "${FAKE_GROUPS:-}" ;;
  *)   exit 0 ;;
esac
SHIM
chmod +x "$SHIMDIR/id"

# ---------------------------------------------------------------------------
# install.sh — #71 global/root install. bash -n first, then drive the actual
# DEST/BINDIR branch with the shim id (the functional proof the contract asks
# for), then grep the root-only pieces that a daemon-free run cannot exercise.
# ---------------------------------------------------------------------------
check "install.sh is valid bash" 0 "" bash -n "$ROOT/install.sh"
# Extract EXACTLY the DEST/BINDIR if/else/fi (the first `id -u -eq 0` block) and
# print what it resolved — the same "run the pure block in isolation" trick rig
# uses for its embedded dump script. Fail closed: a mangled extraction is caught
# by the /opt/box grep below before any resolution is trusted.
# Written as functions because the drill's own preflight is checked against this
# same block 6,000 lines below, and $DBLOCK does not survive that far (it is
# removed the moment this section is done with it). Two spellings of one
# extraction is the thing that drifts, so there is one spelling.
extract_dest_block() {   # → path to a runnable copy of install.sh's uid block
  local f; f="$(mktemp)"
  awk '/id -u.*-eq 0/{f=1} f{print} f&&/^fi$/{exit}' "$ROOT/install.sh" > "$f"
  # The $DEST/$BINDIR here are LITERAL text appended into the extracted block —
  # they must expand when that block RUNS, not when this printf writes it. Hence
  # single quotes; SC2016 is the intent.
  # shellcheck disable=SC2016
  printf '\nprintf "DEST=%%s BINDIR=%%s\\n" "$DEST" "$BINDIR"\n' >> "$f"
  printf '%s' "$f"
}
run_dest_block() {   # run_dest_block <block> <uid> [extra env assignments...]
  local block="$1" uid="$2"; shift 2
  FAKE_UID="$uid" HOME=/home/tester PATH="$SHIMDIR:$PATH" env "$@" bash "$block"
}
DBLOCK="$(extract_dest_block)"
check "install.sh: DEST block extracted (guards the awk)" 0 "/opt/box" cat "$DBLOCK"
check "install.sh: the extracted DEST block is valid bash" 0 "" bash -n "$DBLOCK"

dest() { # dest <uid> [extra env assignments...] — resolve DEST/BINDIR
  run_dest_block "$DBLOCK" "$@"
}
# Root: the global path — a system tree other users can read (#71).
check "install.sh: root → DEST=/opt/box"           0 "DEST=/opt/box"          dest 0
check "install.sh: root → BINDIR=/usr/local/bin"   0 "BINDIR=/usr/local/bin"  dest 0
# Non-root: unchanged, the solo path.
check "install.sh: non-root → DEST=\$HOME/.local"  0 "DEST=/home/tester/.local/share/box" dest 1000
check "install.sh: non-root → BINDIR=\$HOME/.local" 0 "BINDIR=/home/tester/.local/bin"    dest 1000
# BOX_HOME / BOX_BIN still win on BOTH branches — the scripting override.
check "install.sh: BOX_HOME overrides the root default" 0 "DEST=/srv/box"     dest 0    BOX_HOME=/srv/box
check "install.sh: BOX_BIN overrides the root default"  0 "BINDIR=/srv/bin"    dest 0    BOX_BIN=/srv/bin
check "install.sh: BOX_HOME overrides the non-root default" 0 "DEST=/srv/box"  dest 1000 BOX_HOME=/srv/box
rm -f "$DBLOCK"
# The root-only world-readable chmod (#71): the tree is EXECUTED by other users,
# so root must open read+traverse. Grep it, and that it is root-guarded so the
# per-user install stays byte-identical to before.
# $DEST is a LITERAL in the grep pattern (install.sh's own variable) — single
# quotes intended.
# shellcheck disable=SC2016
check "install.sh: root makes the tree world-readable (a+rX)" 0 "" \
  grep -qF 'chmod -R a+rX "$DEST"' "$ROOT/install.sh"
check "install.sh: the a+rX is root-guarded" 0 "" \
  bash -c 'grep -B2 "chmod -R a+rX" "'"$ROOT"'/install.sh" | grep -q "id -u.*-eq 0"'
# #66's flow, preserved: confirm-before-download, and no-op if already installed.
check "install.sh: still confirms before downloading (#66)" 0 "" \
  grep -qF 'confirm "Install box from' "$ROOT/install.sh"
check "install.sh: still no-ops on an existing install (#66)" 0 "" \
  grep -qF 'already installed' "$ROOT/install.sh"

# ---------------------------------------------------------------------------
# Self-extracting installer builder — #249's offline transport contract. Drive
# it with a throwaway product so a box-specific source/provenance variable, path
# or entrypoint cannot hide behind this repository's own happy path.
# ---------------------------------------------------------------------------
MAKE_INSTALLER="$ROOT/dist/make-installer.sh"
ARTWORK="$(mktemp -d)"
ARTTREE="$ARTWORK/widget-tree"
ARTIFACT="$ARTWORK/widget-1.2.3.sh"
ARTLOG="$ARTWORK/installed"
mkdir -p "$ARTTREE"
printf '1.2.3\n' > "$ARTTREE/VERSION"
cat > "$ARTTREE/install-widget.sh" <<'WIDGET'
#!/usr/bin/env bash
set -euo pipefail
: "${WIDGET_INSTALL_SOURCE:?}"
: "${WIDGET_INSTALLED_FROM:?}"
printf 'source=%s\nprovenance=%s\n' \
  "$WIDGET_INSTALL_SOURCE" "$WIDGET_INSTALLED_FROM" > "$WIDGET_OUTPUT"
WIDGET
chmod +x "$ARTTREE/install-widget.sh"

check "self-installer: builder is valid bash (#249)" 0 "" \
  bash -n "$MAKE_INSTALLER"
for product_arg in --name --version --root --out --entrypoint --srcvar; do
  check "self-installer: help names $product_arg (#249)" 0 "$product_arg" \
    "$MAKE_INSTALLER" --help
done
# shellcheck disable=SC2016  # $1 expands in the inner bash, by design
check "self-installer: help carries no box-specific product fact (#249)" 1 "" \
  bash -c '"$1" --help | grep -qi box' _ "$MAKE_INSTALLER"

check "self-installer: builds a differently named throwaway tree (#249)" 0 \
  "make-installer: wrote $ARTIFACT" \
  "$MAKE_INSTALLER" --name widget --version 1.2.3 --root "$ARTTREE" \
  --out "$ARTIFACT" --entrypoint install-widget.sh
check "self-installer: generated artifact is executable (#249)" 0 "" \
  test -x "$ARTIFACT"
# shellcheck disable=SC2016  # $1 expands in the inner bash, by design
check "self-installer: widget stub carries no box string (#249)" 1 "" \
  bash -c 'sed "/^__SELF_INSTALLER_PAYLOAD__$/q" "$1" | grep -qi box' \
  _ "$ARTIFACT"

check "self-installer: --version identifies without installing (#249)" 0 \
  "widget 1.2.3" env WIDGET_OUTPUT="$ARTLOG" bash "$ARTIFACT" --version
check "self-installer: --version touches no install output (#249)" 1 "" \
  test -e "$ARTLOG"
check "self-installer: --check verifies without installing (#249)" 0 \
  "payload intact" env WIDGET_OUTPUT="$ARTLOG" bash "$ARTIFACT" --check
check "self-installer: --check touches no install output (#249)" 1 "" \
  test -e "$ARTLOG"

check "self-installer: artifact installs the throwaway tree (#249)" 0 \
  "installing widget 1.2.3" env WIDGET_OUTPUT="$ARTLOG" bash "$ARTIFACT"
check "self-installer: source variable is derived from product name (#249)" 0 \
  "source=" grep -F 'source=' "$ARTLOG"
check "self-installer: provenance variable is derived from product name (#249)" 0 \
  "provenance=artifact:widget-1.2.3.sh sha256:" \
  grep -F 'provenance=artifact:widget-1.2.3.sh sha256:' "$ARTLOG"

# Damage the payload while keeping the complete shell stub. The checksum must
# refuse it before the execution path creates an unpack directory or runs the
# throwaway entrypoint.
ARTSIZE="$(wc -c < "$ARTIFACT" | tr -d ' ')"
TRUNCATED="$ARTWORK/widget-truncated.sh"
head -c "$((ARTSIZE - 1))" "$ARTIFACT" > "$TRUNCATED"
chmod +x "$TRUNCATED"
rm -f "$ARTLOG"
ARTTMP="$ARTWORK/exec-tmp"
mkdir -p "$ARTTMP"
check "self-installer: truncated payload is refused by --check (#249)" 1 \
  "payload checksum MISMATCH" env TMPDIR="$ARTTMP" WIDGET_OUTPUT="$ARTLOG" \
  bash "$TRUNCATED" --check
check "self-installer: truncated install is refused before unpacking (#249)" 1 \
  "payload checksum MISMATCH" env TMPDIR="$ARTTMP" WIDGET_OUTPUT="$ARTLOG" \
  bash "$TRUNCATED"
check "self-installer: refusal runs no entrypoint (#249)" 1 "" \
  test -e "$ARTLOG"
# shellcheck disable=SC2016  # $1 expands in the inner bash, by design
check "self-installer: refusal unpacks nothing (#249)" 1 "" \
  bash -c 'find "$1" -mindepth 1 -print -quit | grep -q .' _ "$ARTTMP"

# The issue's box-shaped smoke command is intentionally check-only: the
# throwaway tree above is the stronger proof that the builder logic is generic.
BOX_ARTIFACT="$ARTWORK/box-0.0.0-test.sh"
check "self-installer: repository tree builds with the documented command (#249)" 0 \
  "make-installer: wrote $BOX_ARTIFACT" \
  "$MAKE_INSTALLER" --name box --version 0.0.0-test --root "$ROOT" \
  --out "$BOX_ARTIFACT"
check "self-installer: repository artifact passes --check (#249)" 0 \
  "payload intact" bash "$BOX_ARTIFACT" --check
rm -rf "$ARTWORK"

# ---------------------------------------------------------------------------
# Templates — DYNAMIC over templates/*/ (#68): the loop discovers every
# template directory, so a new template cannot ship without passing these (the
# old hardcoded blank/claude/codex/grok list let exactly that happen). The
# box.env parse is proven against the REAL allowlist: load_template is
# extracted from bin/box and DRIVEN against each template — the same
# source-the-pure-function trick install.sh's DEST block and box_tier get
# below — so an unknown key, a missing BOX_IMAGE/BOX_USER, or a line that is
# not KEY="value" fails HERE, not at mint time on a host.
# ---------------------------------------------------------------------------
TPLFN="$(mktemp)"
awk '/^load_template\(\) \{/,/^\}/' "$ROOT/bin/box" > "$TPLFN"
check "load_template: extracted from bin/box (guards the awk)" 0 "unknown key" cat "$TPLFN"
check "load_template: the extracted function is valid bash"    0 "" bash -n "$TPLFN"

# tpl <root> <template> — run the real parser against <root>/templates/, print
# what it resolved. $0 carries the extracted-function file into the subshell.
tpl() {
  root="$1" bash -c '
    die() { echo "box: $*" >&2; exit 1; }
    . "$0"; load_template "$1"
    printf "IMAGE=%s USER=%s REQUIRE_VM=%s NO_FALLBACK=%s AUTOSTART=%s\n" \
      "$T_IMAGE" "$T_USER" "$T_REQUIRE_VM" "$T_NO_CONTAINER_FALLBACK" \
      "$T_AUTOSTART"
  ' "$TPLFN" "$2"
}

# The allowlist itself is load-bearing: a template must not be able to grow a
# network key, and the required keys must still be required. Fixture-driven,
# against a throwaway root — exactly the dies a green parse cannot prove.
EVILROOT="$(mktemp -d)"; mkdir -p "$EVILROOT/templates/evil"
printf 'BOX_IMAGE="images:debian/13/cloud"\nBOX_USER="dev"\nBOX_NETWORK="lan"\n' \
  > "$EVILROOT/templates/evil/box.env"
check "load_template: an unknown key dies (no template grows a network)" 1 "unknown key" \
  tpl "$EVILROOT" evil
printf 'BOX_USER="dev"\n' > "$EVILROOT/templates/evil/box.env"
check "load_template: a missing BOX_IMAGE dies" 1 "required" tpl "$EVILROOT" evil
# The boot demands' green path, kept as a fixture even now that staging sets
# them in-tree: fixtures survive a template rename, and a deleted case arm
# must fail HERE, through the real parser, not at first use on a host.
mkdir -p "$EVILROOT/templates/server"
printf 'BOX_IMAGE="images:debian/13/cloud"\nBOX_USER="ops"\nBOX_REQUIRE_VM="1"\nBOX_AUTOSTART="1"\n' \
  > "$EVILROOT/templates/server/box.env"
check "load_template: REQUIRE_VM and AUTOSTART round-trip (accepted + surfaced)" \
  0 "REQUIRE_VM=1 NO_FALLBACK= AUTOSTART=1" tpl "$EVILROOT" server
# The softer demand is independently parsed. Keeping it a second boolean key
# means a typo cannot quietly degrade into an unpinned template (#175).
mkdir -p "$EVILROOT/templates/tenant-vm-default"
printf 'BOX_IMAGE="images:debian/13/cloud"\nBOX_USER="dev"\nBOX_NO_CONTAINER_FALLBACK="1"\n' \
  > "$EVILROOT/templates/tenant-vm-default/box.env"
check "load_template: NO_CONTAINER_FALLBACK round-trips (accepted + surfaced)" \
  0 "REQUIRE_VM= NO_FALLBACK=1" tpl "$EVILROOT" tenant-vm-default
# BOX_BOOTSTRAP_ROLE (#81) named the role box auto-ran after mint. #214 cut the
# hook it fed, so the key is no longer in the allowlist and a box.env carrying
# it now dies BY NAME at parse time — the loud shape, not a silently ignored
# key that would leave an operator believing their template still converges.
mkdir -p "$EVILROOT/templates/tenant"
printf 'BOX_IMAGE="images:debian/13/cloud"\nBOX_USER="claude"\nBOX_BOOTSTRAP_ROLE="claude"\n' \
  > "$EVILROOT/templates/tenant/box.env"
check "load_template: BOX_BOOTSTRAP_ROLE is refused by name (#214)" \
  1 "unknown key 'BOX_BOOTSTRAP_ROLE'" tpl "$EVILROOT" tenant
check "load_template: ...and the refusal says a template does not converge (#214)" \
  1 "none for convergence" tpl "$EVILROOT" tenant
rm -rf "$EVILROOT"

# ---------------------------------------------------------------------------
# THE STRONG FORM (#214). box provisions and manages VMs, and it does not
# converge them — so after this release bin/box and templates/ name the
# converger nowhere they ACT, and the four pin helpers do not exist.
#
# This guard owns the comment-stripping rule, so it cannot be argued with
# later. A line is a comment when its first non-blank character is '#'; every
# other line is checked whole, trailing comments included, because a rule that
# tried to strip an inline '#' from shell or YAML would have to know which ones
# are inside a string. Prose may name the converger — that is what the issue
# blesses — so comments are stripped, and so is exactly ONE region of bin/box:
# --role's refusal message, which the issue's own criteria require to name
# 'box root' AND the bootstrap step. That region is delimited by the sentinel
# pair below and the guard asserts there is exactly one of it, so widening the
# exception means adding a visible sentinel pair and turning this red.
#
# The word boundary is not decoration: 'origin' and 'right' both contain the
# three letters, and a substring match would red the whole file for saying
# 'origin=mint'.
strongform() {   # <file> — the non-comment, non-prose body
  awk '
    /^# box-strong-form-prose-begin$/ { prose = 1; next }
    /^# box-strong-form-prose-end$/   { prose = 0; next }
    prose { next }
    $0 ~ /^[[:space:]]*#/ { next }
    { print }
  ' "$1"
}
# Called from THIS shell, never through 'bash -c': a helper that is not
# exported comes back 127 from a child, and 127 is a non-zero exit — which is
# what an absence assertion wants, so the guard would pass by not existing.
sf_names_converger() { strongform "$1" | grep -qwE 'rig'; }
sf_names_pin()       { strongform "$1" | grep -qE 'RIG_REPO|RIG_REF'; }
check "strong form: bin/box carries exactly one prose exception (#214)" 0 "1" \
  grep -c "^# box-strong-form-prose-begin$" "$ROOT/bin/box"
check "strong form: ...and it is closed" 0 "1" \
  grep -c "^# box-strong-form-prose-end$" "$ROOT/bin/box"
check "strong form: no acting line in bin/box names the converger (#214)" 1 "" \
  sf_names_converger "$ROOT/bin/box"
check "strong form: bin/box names no pin variable where it acts (#214)" 1 "" \
  sf_names_pin "$ROOT/bin/box"
for f in "$ROOT"/templates/*/box.env "$ROOT"/templates/*/user-data.yaml; do
  rel="templates/$(basename "$(dirname "$f")")/$(basename "$f")"
  check "strong form: $rel names the converger nowhere at all (#214)" 1 "" \
    grep -qwE 'rig|RIG_REPO|RIG_REF' "$f"
  check "strong form: $rel has no prose exception of its own (#214)" 1 "" \
    grep -q 'box-strong-form-prose' "$f"
done
# The four pin helpers are UNDEFINED, by name. The seed no longer carries a pin
# to resolve, so nothing reads them — and a resolver left behind is a mint that
# can still make a HEAD request nobody asked for.
for h in rig_repo rig_ref rig_latest_release rig_pin_resolve; do
  check "strong form: $h is undefined in bin/box (#214)" 1 "" \
    grep -qE "^$h\\(\\)" "$ROOT/bin/box"
done
# The guard must FAIL where it is supposed to. Drive it against a fixture that
# names the converger on an acting line: a guard nobody has watched go red is
# a guard asserting nothing.
SFPROBE="$(mktemp)"
printf '# a comment naming rig is fine\necho "rig bootstrap claude-box"\n' > "$SFPROBE"
check "strong form: the guard reds on an acting line (the guard's own test)" 0 "" \
  sf_names_converger "$SFPROBE"
printf '# box-strong-form-prose-begin\necho "rig bootstrap claude-box"\n# box-strong-form-prose-end\n' > "$SFPROBE"
check "strong form: ...and passes the same line inside the prose region" 1 "" \
  sf_names_converger "$SFPROBE"
# A word boundary, not a substring: 'origin=mint' and 'the right side' both
# carry the three letters, and a substring guard would red the whole file for
# saying either.
printf 'echo "user.box.origin=mint  # the right side to fail on"\n' > "$SFPROBE"
check "strong form: ...and does not red 'origin' or 'right' (the boundary)" 1 "" \
  sf_names_converger "$SFPROBE"
rm -f "$SFPROBE"

# THE PRE-CUT TREE, not a fixture. The three tests above prove the helper can
# match a line someone invented for it; the issue's test plan asks for the
# exact guard driven against the ACTUAL tree this PR cut, and observed RED
# there. The difference is not pedantry: a guard tuned to its own fixture is
# the failure this repo keeps refusing, and only the real tree can show the
# guard would have caught the thing it was written for.
#
# The pre-cut commit is LOCATED, never named. A hard-coded SHA rots the moment
# the branch rebases, and a SKIP on "SHA not found" is a guard that silently
# stops guarding — so this walks back from HEAD and asks the guard itself which
# ancestor is the pre-cut one. Unreachable history is a FAILURE and not a skip;
# CI checks out at fetch-depth 0 for exactly this class of check.
sf_precut_ancestor() {
  local c out="$1"
  while read -r c; do
    git -C "$ROOT" show "$c:bin/box" > "$out" 2>/dev/null || continue
    if sf_names_converger "$out"; then printf '%s' "$c"; return 0; fi
  done < <(git -C "$ROOT" rev-list --max-count=500 HEAD 2>/dev/null)
  return 1
}
SFPRE="$(mktemp)"
SFPRECOMMIT="$(sf_precut_ancestor "$SFPRE" || true)"
if [ -n "$SFPRECOMMIT" ]; then
  check "strong form: the guard reds on the real pre-cut tree (${SFPRECOMMIT:0:7}) (#214)" 0 "" \
    sf_names_converger "$SFPRE"
  check "strong form: ...and the pin guard reds on that same tree" 0 "" \
    sf_names_pin "$SFPRE"
  # The other half of a negative control: the same two helpers, same shell,
  # green at HEAD. Red-there-and-green-here is the pair that means something;
  # either alone is satisfied by a guard that is simply broken.
  check "strong form: ...and both are green at HEAD (the control's other half)" 1 "" \
    sf_names_converger "$ROOT/bin/box"
else
  check "strong form: a pre-cut ancestor is reachable to drive the guard against" 0 \
    "" false
fi
rm -f "$SFPRE"

# The extent of the exception, not just its count. The guard asserts there is
# exactly ONE prose region, so a SECOND one cannot appear quietly — but it said
# nothing about the first one GROWING, and an acting line added between the
# existing sentinels passed silently. Bound it by the property the exception
# was granted for: box may name the converger where it TEACHES, never where it
# ACTS, so everything inside the region is a comment, the refusal function's
# own frame, or a line that only prints or exits. A line count would red on a
# reformat and pass on a curl; this reds on the curl.
sf_region_only_prints() {
  local stray
  stray="$(awk '/^# box-strong-form-prose-begin$/,/^# box-strong-form-prose-end$/' "$1" \
    | grep -vE '^#|^[[:space:]]*$|^refuse_role\(\)[[:space:]]*\{$|^\}$|^[[:space:]]+echo([[:space:]]|$)|^[[:space:]]+exit[[:space:]]+[0-9]+$')"
  [ -z "$stray" ] || { printf 'acting line inside the prose region:\n%s\n' "$stray"; return 1; }
}
check "strong form: the prose region only prints and exits (#214)" 0 "" \
  sf_region_only_prints "$ROOT/bin/box"
SFPROBE="$(mktemp)"
printf '# box-strong-form-prose-begin\nrefuse_role() {\n  echo "box: teaching is fine" >&2\n  curl -fsSL https://example.invalid/install.sh | bash\n}\n# box-strong-form-prose-end\n' > "$SFPROBE"
check "strong form: ...and an acting line added INSIDE it reds (the guard's own test)" 1 "" \
  sf_region_only_prints "$SFPROBE"
rm -f "$SFPROBE"

# ---------------------------------------------------------------------------
# THE CORPUS, not one fragment (#214 §5, amended by triage 2026-08-22).
#
# changelog.d/ is assembled WHOLE into a release's section, so the unit that
# reaches the tag is the DIRECTORY and not the file this PR adds. A fragment
# already sitting here announcing what this cut removes ships alongside the
# fragment announcing the removal, however carefully the new one is worded —
# and a record that reports a fact the tree no longer has is the #153 defect
# class, in the one directory whose entire output is the release notes.
#
# So the rule is the corpus: no surviving fragment announces --role, a pin, a
# converger, or a seed set that does not exist. Every tracked file is swept;
# exceptions consumed by a release disappear with the files that carried them.
# A future fragment that needs an exception must earn and exercise it then.
#
# The pattern is the acceptance criterion's, verbatim and case-insensitive, so
# what the suite enforces and what the panel greps cannot drift apart.
CL_PATTERN='\brig\b|RIG_RE(PO|F)|--role|agent (box|boxes|seed|seeds|template|templates)|blank template'
cl_announces_removed() {          # <file>
  grep -qEi "$CL_PATTERN" "$1"
}
# Every tracked file in the directory, not a *.md glob: the criterion greps
# changelog.d/ whole, and README.md and shape assemble into nothing but are
# read by the same people.
#
# The walk is 'git ls-files', so it asserts over TRACKED files and a checkout
# without git would hand it an empty list — and an absence sweep over an empty
# list passes by having nothing to look at, which is the exact failure mode the
# sweep is written to avoid. So the walk proves it reached something before it
# sweeps. The directory furniture survives every release cut by design, so it
# is the era-free proof that the walk reached the corpus.
CL_TRACKED="$(git -C "$ROOT" ls-files changelog.d 2>/dev/null)"
cl_walk_reaches() { printf '%s\n' "$CL_TRACKED" | grep -qxF "$1"; }
check "corpus: the walk reaches README.md — an empty walk sweeps nothing (#214, #271)" 0 "" \
  cl_walk_reaches changelog.d/README.md
check "corpus: ...and shape, the directory's second permanent anchor (#271)" 0 "" \
  cl_walk_reaches changelog.d/shape
#
# ---- the two trees this block runs on (#222 D6) ---------------------------
#
# A release cut CONSUMES every fragment, so no control may key liveness or
# content to a fragment from one release. The permanent furniture proves the
# walk on either arm; a cut tree proves its assembled section structurally.
#
# The branch is derived from the TREE and from nothing else: the fragments'
# absence, and the assembled section's presence. Not an environment variable,
# not a --release argument, not a VERSION read. A control the builder of a
# release can switch off is not a control, and the whole reason this block is
# in the cut's own diff is that the cut must not be able to buy its way past
# it.
#
# 'shape' and README.md are the directory's furniture and survive the
# consumption by design (they are what changelog-armed refuses a tree
# without), so they are not fragments and do not keep the ordinary path alive.
CL_FRAGMENTS="$(printf '%s\n' "$CL_TRACKED" \
  | grep -vxF -e changelog.d/README.md -e changelog.d/shape -e '')"
# The section is located structurally — the top '## ' heading and everything
# under it — so nothing here reads a version out of VERSION or matches one by
# name.
cl_release_heading() { grep -m1 '^## ' "$ROOT/CHANGELOG.md"; }
cl_release_section() { awk '/^## /{n++; if (n>1) exit; next} n==1' "$ROOT/CHANGELOG.md"; }
cl_release_section_is_stamped() {
  cl_release_heading \
    | grep -qE '^## [0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)? — [0-9]{4}-[0-9]{2}-[0-9]{2}$'
}
cl_release_section_has_entries() { cl_release_section | grep -q '^- '; }
if [ -z "$CL_FRAGMENTS" ]; then
  # ---- the release tree: exercised by the cut PR itself -------------------
  # This is the liveness guarantee moved, not dropped. On the ordinary tree
  # the 'git ls-files' walk proves the sweep reached something before it swept
  # an empty directory; here the directory IS empty by design, so the proof
  # moves to the artefact the fragments became. A missing, unstamped or empty
  # section reds — which is the whole point, because an absence sweep that
  # reaches nothing must red rather than pass.
  check "corpus/release: CHANGELOG.md's top section is a stamped release heading (#214, #222)" 0 "" \
    cl_release_section_is_stamped
  check "corpus/release: ...and it is not empty — a section that assembled nothing reds" 0 "" \
    cl_release_section_has_entries
fi
while read -r rel; do
  [ -n "$rel" ] || continue
  check "corpus: $rel announces nothing this release removes (#214)" 1 "" \
    cl_announces_removed "$ROOT/$rel"
done <<< "$CL_TRACKED"
# The guard's own test, on the two shapes it exists to tell apart: a stale
# SUBJECT — true in substance, naming a seed set #209 collapsed — and the same
# claim repaired onto the tree that exists. The repair is the ruling's, D1
# restated: the hygiene four fragments called an agent-box property is now
# every ordinary box's, which is why 'Agent boxes' → 'Every ordinary box' and
# not 'Agent boxes' → 'Tenant boxes'.
CLPROBE="$(mktemp)"
printf -- '- Agent boxes cap /tmp at a fixed 1GiB (#178).\n' > "$CLPROBE"
check "corpus: the guard reds on a stale subject (the guard's own test)" 0 "" \
  cl_announces_removed "$CLPROBE"
printf -- '- Every ordinary box caps /tmp at a fixed 1GiB (#178).\n' > "$CLPROBE"
check "corpus: ...and passes the repaired line" 1 "" \
  cl_announces_removed "$CLPROBE"
# A word boundary here too, and it matters more than in bin/box: 'rigid' and
# 'origin' are both ordinary changelog English.
printf -- '- A rigid schema, checked at origin, for the right reasons.\n' > "$CLPROBE"
check "corpus: ...and does not red 'rigid', 'origin' or 'right' (the boundary)" 1 "" \
  cl_announces_removed "$CLPROBE"
rm -f "$CLPROBE"
# The real pre-amendment fragment, not a fixture — the same negative control
# the strong form gets, and for the same reason: a guard tuned to a line
# someone invented for it has not shown it would have caught the line that was
# actually there. 177.md is the one with content to remove rather than a
# subject to repair, so it is the one worth driving. The ancestor is the strong
# form's located pre-cut commit; an unreachable one FAILS above and is not
# re-diagnosed here.
if [ -n "$SFPRECOMMIT" ]; then
  CLPRE="$(mktemp)"
  git -C "$ROOT" show "$SFPRECOMMIT:changelog.d/177.md" > "$CLPRE" 2>/dev/null || true
  check "corpus: the guard reds on the real pre-amendment 177.md (${SFPRECOMMIT:0:7}) (#214)" 0 "" \
    cl_announces_removed "$CLPRE"
  # This half reads git history and is indifferent to the cut, so it is
  # unchanged. The green direction is the unconditional repaired-line fixture
  # above; keying it to the consumed 177.md path made the next fragment red.
  rm -f "$CLPRE"
fi

# ---------------------------------------------------------------------------
# THE CLAIM, not the word (#214). The strong form above matches 'rig' — so it
# is blind BY CONSTRUCTION to the sentence that survived it:
#
#   box — trust-less, network-isolated Incus VMs with Claude Code, creds-free.
#
# That line names no converger and no pin, and it stood in bin/box's header and
# in the FIRST line of 'box --help' through a sweep that went green. It makes
# the one claim #214 falsifies — that a mint lands an agent on the box — and it
# is the copy an operator reaches without opening a file. So the claim gets its
# own guard, in the surface the claim is made in: everything 'box --help' and
# 'box help <verb>' print, for every verb the help itself lists.
#
# Driven, not read. The help is rendered from the CMDS table at runtime, so a
# text guard over bin/box would be asserting the source of the output instead
# of the output; this runs the real thing and greps what an operator sees.
#
# The rule is word-bounded 'claude|codex|grok', case-insensitively, and the
# boundary is the whole design. box's legacy surface is full of honest ones —
# 'user.claudebox=1', the 'claudenet' network, the pre-0.4.0 'claudebox' stack,
# 'legacy claudebox crumbs' — and every one is an IDENTIFIER of something that
# exists on a disk somewhere, not a claim about what a mint lands. None is a
# word 'claude'. What -w catches is the bare product name, and in this surface
# a bare product name is only ever the claim.
#
# Two live places this guard does NOT reach, both deliberate: the mint's ready
# hint, which fires off a LEGACY template stamp and nothing else (its own
# comment argues that at the call site), and 'box export's warning that the
# tarball holds 'agent logins (Claude, Codex, Grok)' — which describes what an
# operator's own converge may have left on the disk, and stays true precisely
# because box no longer decides what is there.
help_verbs() {  # the verbs the help lists, out of the help itself
  bash "$1" --help | awk '/^COMMANDS$/{c=1;next} c && /^[A-Z]/{c=0} c && /^  [a-z]/{print $1}'
}
help_surface() {  # <box> — every line box prints when asked what it is
  local v
  bash "$1" --help || return 1
  for v in $(help_verbs "$1"); do bash "$1" help "$v" || return 1; done
}
help_sells_an_agent()   { help_surface "$1" 2>&1 | grep -qwiE 'claude|codex|grok'; }
header_sells_an_agent() { sed -n '2p' "$1"       | grep -qwiE 'claude|codex|grok'; }
check "help surface: box's own help sells no agent it does not install (#214)" 1 "" \
  help_sells_an_agent "$BOX"
# An absence assertion over an EMPTY surface passes by having nothing to look
# at, so prove the surface is the whole of it: 'usage: box exec' is printed by
# a per-verb help and by nothing else, so it is red if the verb walk breaks.
check "help surface: ...over every verb's help and not just the banner" 0 \
  "usage: box exec" help_surface "$BOX"
# The header repeats the same sentence one line above the shebang, where no
# invocation reaches it. Same claim, same guard, read as text.
check "help surface: ...and neither does bin/box's header line (#214)" 1 "" \
  header_sells_an_agent "$BOX"
# The negative control, and it is the real pre-cut tree rather than a fixture —
# located by the strong form's own walk, so this cannot rot into a hard-coded
# SHA. An old bin/box renders its help from its own CMDS table and needs
# nothing of the tree around it, so it can be run from a temp path: what comes
# out is exactly what that release printed. Red there, green at HEAD.
if [ -n "$SFPRECOMMIT" ]; then
  SFPREBOX="$(mktemp)"; git -C "$ROOT" show "$SFPRECOMMIT:bin/box" > "$SFPREBOX"
  check "help surface: the guard reds on the real pre-cut help (${SFPRECOMMIT:0:7}) (#214)" 0 "" \
    help_sells_an_agent "$SFPREBOX"
  check "help surface: ...and on that tree's header line too" 0 "" \
    header_sells_an_agent "$SFPREBOX"
  rm -f "$SFPREBOX"
fi
# ...and it does not red the legacy identifiers, which is the boundary doing
# the work rather than the pattern being lucky. These four are live in the
# help at HEAD; a substring guard would red every one of them.
SFPROBE="$(mktemp)"
printf 'the boxnet/claudenet networks\nuser.claudebox=1 stays honored\nany legacy claudebox crumbs\nthe pre-0.4.0 %s stack\n' "'claudebox'" > "$SFPROBE"
check "help surface: ...and the legacy claudebox/claudenet names pass (the boundary)" 1 "" \
  grep -qwiE 'claude|codex|grok' "$SFPROBE"
rm -f "$SFPROBE"

# ---------------------------------------------------------------------------
# THE PAGES AN OPERATOR IS SENT TO (#214). Three rounds of this PR have ended
# the same way: the mechanism cut complete, and one more prose surface still
# selling the box the cut stops minting. Round 1 was CONTRIBUTING.md, round 2
# bin/box's header and the first line of 'box --help', round 3
# docs/box-recipe.md — a file this diff does not otherwise touch, linked by
# name from README.md's lede, in the paragraph right after the new cold-start
# promise. Each was invisible to the guards above BY CONSTRUCTION: the strong
# form reads bin/box and templates/, and the help guard drives the help. A
# fourth round of the same finding is a guard nobody wrote, so here it is.
#
# The set is the CLAIM, not the pages the last three rounds happened to land
# on — bounding it to those four would be this issue's own defect written into
# the fixture built to end it. It is every operator-facing page this repo
# ships: the README, the contributor's page, the file every agent entering the
# repo reads first, both design pages, and the drill's two. The last of those
# are not padding — drill/README.md and drills/README.md are pages round 1
# swept BY HAND for retired agent and role claims, so leaving them out holds
# two already-failed surfaces with nothing but somebody's memory.
#
# Three exclusions, and they stay a comment only because the list is explicit;
# if this ever becomes a glob they have to be enforced in code. docs/plans/ is
# out — dated design records, true of the day they were written, the same
# "history is correct as history" rule that excepts 159.md's one clause in the
# corpus sweep above. .ceremony/ is out as vendored from another repo.
# CHANGELOG.md and drills/0.9.*.md are out as released history, which this cut
# does not reach back into.
#
# Two rules, because the defect had two shapes.
DOC_PAGES="README.md CONTRIBUTING.md AGENTS.md docs/box-recipe.md docs/box-design.md"
DOC_PAGES="$DOC_PAGES drill/README.md drills/README.md"
#
# RULE 0 — EVERY PAGE IN THE CORPUS EXISTS.
#
# Both rules below are ABSENCE assertions: they pass when nothing matches. A
# path that is missing or misspelled matches nothing, so grep exits 1 and awk
# exits 1 and both rules go green on a file that was never read. That makes the
# corpus silently shrinkable — rename a page and its guard evaporates with it,
# reporting ok. This is the same defect the two guards in the commit above had,
# so the corpus asserts itself first and the absence rules mean something.
for rel in $DOC_PAGES; do
  check "docs: $rel is in the corpus and exists to be read (#214)" 0 "" \
    test -f "$ROOT/$rel"
done
#
# RULE 1 — NO PAGE CLAIMS A BOX SHIPS OR HAS AN AGENT AS A PROPERTY OF THE MINT.
#
# The criterion names two verbs and the first draft of this guard built one.
# 'Ships' is what a mint DELIVERS; 'has' is what a mint LEAVES BEHIND, and the
# second is the same claim in the tense an operator actually reads it in — 'a
# freshly minted box has a coding agent', 'every box comes with one', 'the
# template includes one'. All four of those stayed green against the ships-only
# pattern, so the fourth arm below is the criterion's other half.
#
# The retired seed names are in the pattern: after #209 collapsed those four
# directories, 'claude-box' in these pages is a box template that does not
# exist. With exactly one exception — where 'rig bootstrap' LEADS it,
# '<name>-box' is a RIG ROLE and the text is the four-step path this release
# documents. That is the boundary doing the work: the same token, told apart by
# whose noun it is. The prefix is INSIDE the pattern, so the exemption reads the
# match rather than the line it sits on; filtering whole lines first (which this
# did) drops any honest-looking line entirely, and a false claim sharing a line
# with the documented converge went with it.
#
# The file is folded to one line before matching, because prose wraps and the
# sentence that failed round 3 wrapped between 'agent already' and 'installed'.
#
# Two boundaries the arms are shaped around, both of them lines triage ruled
# STANDING and neither of them exempted by name:
#
#   - 'gets' is not a verb here, on purpose. What a box SHIPS or HAS is a claim
#     about the mint; what a CONVERGED box GETS is a claim about that box's
#     state, which is still true and is how box-design.md:143 states it, four
#     lines above 'box does not write that file and never did'.
#   - the ownership arm binds its object TO the verb — determiner, one optional
#     adjective, then the noun — rather than merely near it. 'A box the operator
#     HAS CONVERGED WITH a coding agent' (box-recipe.md:33) puts a participle
#     where the determiner must be, so it does not match, and neither does any
#     other sentence whose agent arrives by a verb of its own.
#
# 'agents?([^-A-Za-z]|$)' and not '\bagent\b': a hyphen is a word boundary, so
# '\bagent\b' matches inside 'agent-context' and would have reded both of the
# sentences above for naming the FILE a converged box gets.
DOC_PATTERN='(rig[ \t]+bootstrap[ \t]+)?\b(claude|codex|grok|kimi)-box\b|whichever template you minted'
DOC_PATTERN="$DOC_PATTERN"'|\bagent\b[^.]{0,40}already installed|already installed[^.]{0,40}\bagent\b'
DOC_PATTERN="$DOC_PATTERN"'|\b(box|boxes|mint|mints|minted|seed|seeds|template|templates)\b[^.]{0,40}\b(ships?|each ship)\b[^.]{0,40}\bagents?\b'
DOC_PATTERN="$DOC_PATTERN"'|\b(box|boxes|mint|mints|minted|seed|seeds|template|templates)\b[^.]{0,60}'
DOC_PATTERN="$DOC_PATTERN"'\b(has|have|comes? with|includes?|carries|carry|brings?|arrives? with|ships? with|minted[ \t]+with|leaves?[^.]{0,20} with)'
DOC_PATTERN="$DOC_PATTERN"'[ \t]+(an?|one|the|its|your|another)?[ \t]*([A-Za-z]+[ \t]+)?agents?([^-A-Za-z]|$)'
#
# The one exemption left, and it reads the MATCH and never the line: the
# documented converge, anchored so it has to LEAD the match.
DOC_EXEMPT='^rig[ \t]+bootstrap'
#
# DENIAL IS NOT AN EXEMPTION ANY MORE — it is blanked from the text BEFORE the
# claim arms ever read it, and that is the round-6 fix. Denial is what most of
# this corpus says about agents, so a pattern this broad has to hear it; the
# question is only when. Read afterwards it cuts both ways at once and has to be
# stopped from cutting the wrong one, and two rounds running it was caught
# cutting the wrong one anyway:
#
#   round 5, the TRAILING denial. ERE matching is leftmost-LONGEST, so the ships
#   arm ran its window on to the LAST 'agent' it could reach and swallowed the
#   denial in between:
#     The box ships an agent and no agent token.
#     match [box ships an agent and no agent] -> exempt -> green
#   Answered by truncating the match at its FIRST 'agent'...
#
#   round 6, the LEADING denial, which that truncation left standing and in one
#   sense created: with the first noun deciding, a denial that PRECEDES the
#   claim takes the claim away with the discarded tail:
#     A box with no agent token still ships a coding agent.
#     match truncated to [box with no agent] -> exempt -> green
#
# Both are the same bug: a denial of one noun deciding another noun's claim. No
# ordering of a post-hoc exemption fixes that, because the exemption is reading
# a window that contains two nouns and can only vote once. Blanked first, the
# denied noun is not there to be matched, every 'agents?' the arms can still see
# is one nothing denies, and the arms decide on their own merits:
#
#   A box with [denied] token still ships a coding agent.   -> reds, correctly
#   A box ships an agent and [denied] token.                -> reds, correctly
#   A box ships a thin seed and no credentials, [denied].   -> greens, correctly
#
# README.md's creds-free line greens because it makes no surviving claim, not
# because a window was too narrow (round 4) and not because a truncation landed
# on the right noun (round 5). The exemption stopped cutting one way only by
# ceasing to be a cut.
DOC_DENIAL='\b(no|not|never|neither|nor|without)[ \t]+([a-z]+[ \t]+){0,2}agents?\b'
doc_sells_a_minted_agent() {  # <file>
  tr '\n' ' ' < "$1" | sed -E "s/$DOC_DENIAL/[denied]/gI" \
    | grep -oEi "$DOC_PATTERN" \
    | grep -qvEi "$DOC_EXEMPT"
}
for rel in $DOC_PAGES; do
  check "docs: $rel claims no agent a mint does not land (#214)" 1 "" \
    doc_sells_a_minted_agent "$ROOT/$rel"
done
#
# RULE 2 — NO RUNNABLE FLOW MINTS A BOX AND THEN RUNS AN AGENT ON IT.
#
# The sharper half, and it survived rule 1 in the very file that failed round
# 3: a fenced block reading 'box new' / 'box shell' / 'git clone' / 'claude'
# makes no claim in prose at all, and ends by invoking a binary that is not on
# the box — the same shape as the Quick start's 'gh auth login', which three
# reviewers took as blocking in round 1. A block that mints and invokes an
# agent must converge in between. The discriminator is the FIRST WORD of the
# line, which is what makes it cheap and exact: 'claude' alone is an
# invocation, 'rig bootstrap claude-box' is the converge that earns it.
#
# The converge arm names the CONVERGER'S installer and not any installer. A
# bare 'install\.sh' counted box's own — the line at README.md:44 that puts box
# on the HOST — so a block that curled box's installer, minted, and then ran
# 'claude' passed on a convergence that never happened. Nothing in the corpus
# sits in that hole today; the four-step path's installer is rig's and still
# counts.
doc_flow_skips_the_converge() {  # <file>
  awk '
    /^```/ {
      if (inb) {
        if (mint && agent && !conv)
          { bad = 1; print FILENAME ": a block mints a box, then invokes an agent, and never converges it" }
        inb = 0; mint = 0; agent = 0; conv = 0
      } else inb = 1
      next
    }
    inb {
      if ($0  ~ /box[ \t]+new/)                       mint  = 1
      if ($1  ~ /^(claude|codex|grok|kimi)$/)         agent = 1
      if ($0  ~ /rig[ \t]+bootstrap|rig\/[^ ]*install\.sh/) conv = 1
    }
    END { exit(bad ? 0 : 1) }
  ' "$1"
}
for rel in $DOC_PAGES; do
  check "docs: $rel runs no agent on a box it just minted blank (#214)" 1 "" \
    doc_flow_skips_the_converge "$ROOT/$rel"
done
#
# RULE 3 — NO PAGE CALLS A BOX'S AGENT "THE BOX'S".
#
# §4's amendment binds three shapes and the two rules above implement two. The
# third — 'may call a box's agent "the box's"' — was caught by hand at da6eb05,
# by a triage grep, on a clause that stood twice in README.md and once here.
# The possessive is the whole defect: an agent an operator installed is the
# OPERATOR'S, running in a box that box does not own, and calling it the box's
# is how the retired promise survives a sweep of every sentence that names a
# mint. A hand-grep somebody remembers is what this guard exists to replace, so
# it gets a rule at the same cost as the other two. Widening, and §4 permits it.
DOC_OWNS="\\bbox['’]?s\\b[^.]{0,20}\\b(coding[ \\t]+)?agents?([^-A-Za-z]|\$)"
doc_calls_the_agent_the_box_s() {  # <file>
  tr '\n' ' ' < "$1" | grep -qEi "$DOC_OWNS"
}
for rel in $DOC_PAGES; do
  check "docs: $rel calls no agent the box's (#214)" 1 "" \
    doc_calls_the_agent_the_box_s "$ROOT/$rel"
done
#
# RULE 4 — A RUNNABLE CONVERGE PINS THE TREE, NOT JUST THE INSTALLER.
#
# §4 spells the canonical replacement as 'curl … rig/<ref>/install.sh |
# RIG_REPO=heavy-duty/rig RIG_REF=<ref> bash' and binds the README to teach it
# verbatim. The recipe abbreviated it to '| bash' and the page three lines
# below still called <ref> "a rig release you pin there" — which is the defect:
# the <ref> in the URL pins WHICH COPY of install.sh executes, and that
# installer reads REF="${RIG_REF:-}" and resolves an unset value through the
# latest-release channel. So the abbreviated line downloads an old release's
# installer and then installs whatever is newest, and the page's own pin claim
# is false. An operator who pinned deliberately gets an unpinned box, silently.
#
# Rules 1-3 could not see it: it makes no claim about a mint, invokes no agent,
# and owns no agent. It is a claim about the CONVERGE, which is the other half
# of what this cut moved to the operator — so if box no longer converges, the
# one thing box's docs still owe is a converge line that does what it says.
#
# Scoped to rig's installer BY REPO and not by exemption: box's own installer
# (README.md:44 and :55-57) pins with BOX_REF and is a different contract, and
# 'rig/' simply is not in its URL. bin/box joins the corpus here because
# refuse_role prints this same command and is the surface an operator hits
# without reading a page at all; changelog.d/214.md teaches it too but is
# consumed at release, so guarding a file that legitimately disappears would
# make this rule the silent-skip the corpus rule 0 exists to prevent.
#
# Read on the MATCH and not the line — N1's lesson from the round above, and
# here it also does the wrapping: the canonical form wraps with a trailing '\'
# in a page and with '\\" >&2' inside bin/box's echo, and folding the file to
# one line makes both of those the same window instead of two special cases.
#
# ...and the match is ANCHORED ON THE PIPE, which is the same lesson one rule
# further on and the thing 'read the match' does not buy by itself. The claim
# this rule makes is that the pin rides the pipe the curl FEEDS; a window of
# 'somewhere in the next 120 characters' of a file folded to one line is a
# different and weaker claim, because the window crosses fences, sentences and
# paragraphs freely:
#
#   curl … rig/<ref>/install.sh | bash
#   Set RIG_REPO=heavy-duty/rig RIG_REF=0.3.0 in your environment first.
#   -> green: an unpinned converge laundered by a sentence ABOUT the pin
#
# So the pin must follow the pipe with nothing but whitespace between, and the
# window before the pipe cannot cross one ('[^|]'). The pipe group is OPTIONAL
# rather than required, and that is deliberate: made mandatory, a converge that
# never pipes at all -- 'curl … rig/<ref>/install.sh > /tmp/i.sh' -- emits no
# match, the inverted grep reads empty input, and the rule reports green on a
# line carrying no pin whatsoever. Optional, that line matches without a pipe,
# finds no pin, and reds. A guard must not go quiet on the shape it never
# anticipated; both halves of this rule are the same rule 0 lesson.
PIN_PAGES="$DOC_PAGES bin/box"
doc_curls_rig_without_the_pin() {  # <file>
  tr '\n' ' ' < "$1" \
    | grep -oE 'rig/[^ ]*install\.sh[^|]{0,80}(\|[ \t]*[^|]{0,60})?' \
    | grep -qvE '\|[ \t]*RIG_REPO=[^ ]+[ \t]+RIG_REF='
}
for rel in $PIN_PAGES; do
  check "docs: $rel is in the pin corpus and exists to be read (#214)" 0 "" \
    test -f "$ROOT/$rel"
  check "docs: $rel pins the rig tree and not just the installer (#214)" 1 "" \
    doc_curls_rig_without_the_pin "$ROOT/$rel"
done
# The negative control, and it is the real pre-cut docs/box-recipe.md rather
# than a fixture — the same standard rounds 1 and 2 set for the strong form and
# the corpus sweep. That file is untouched by this branch until this round, so
# the located pre-cut ancestor carries exactly the page that shipped: red on
# both rules there, green on both here.
if [ -n "$SFPRECOMMIT" ]; then
  DOCPRE="$(mktemp)"
  git -C "$ROOT" show "$SFPRECOMMIT:docs/box-recipe.md" > "$DOCPRE" 2>/dev/null || true
  check "docs: rule 1 reds on the real pre-cut box-recipe.md (${SFPRECOMMIT:0:7}) (#214)" 0 "" \
    doc_sells_a_minted_agent "$DOCPRE"
  check "docs: rule 2 reds on that same page's four-line flow (the sharper half)" 0 \
    "never converges it" doc_flow_skips_the_converge "$DOCPRE"
  # Rule 3's control is the real pre-cut README.md, which carried the clause
  # twice — :26 and :799 — and is the page triage's hand-grep caught it on.
  git -C "$ROOT" show "$SFPRECOMMIT:README.md" > "$DOCPRE" 2>/dev/null || true
  check "docs: rule 3 reds on the real pre-cut README.md's \"the box's coding agent\"" 0 "" \
    doc_calls_the_agent_the_box_s "$DOCPRE"
  rm -f "$DOCPRE"
fi
# ...and the boundary, which is where a pattern this broad earns its keep. All
# seven of these are live at HEAD or in the corpus verbatim, and every one of
# them is honest: a rig role in the documented converge, two agent-context
# paths, a legacy stamp key, the one template that still exists, the 'gets'
# sentence rule 1 must not touch, the 'has converged with' sentence the
# ownership arm must not touch, and the creds-free line, which is a DENIAL that
# names both a mint verb and the noun.
DOCPROBE="$(mktemp)"
{ printf 'rig bootstrap claude-box --user dev\n'
  printf 'the file at ~/.claude/CLAUDE.md, or ~/.codex/AGENTS.md\n'
  printf 'user.claudebox=1 stays honored forever\n'
  printf 'box new --template staging-box mints the server seed\n'
  printf 'A box with a coding agent on it gets a global agent-context file.\n'
  printf 'A box the operator has converged with a coding agent gets a context file.\n'
  printf 'A box ships with a thin seed and no credentials — no agent token, nothing.\n'; } > "$DOCPROBE"
check "docs: ...and the rig role, the agent-context paths and staging-box pass (the boundary)" 1 "" \
  doc_sells_a_minted_agent "$DOCPROBE"
# The guard's own test on the claim it exists for, in every shape it has been
# made in, so a green sweep above is a sweep that would have gone red. The four
# 'has' shapes are the mutations round 4 drove against the ships-only pattern
# and watched stay green; each is its own probe, so a narrowing of the arm shows
# up as a named failure rather than one check that used to pass for two reasons.
printf 'The claude-box template ships a CLI agent, so a fresh box has one.\n' > "$DOCPROBE"
check "docs: rule 1 reds on the claim itself (the guard's own test)" 0 "" \
  doc_sells_a_minted_agent "$DOCPROBE"
printf 'box mints VMs with a coding agent already\ninstalled — nothing to do.\n' > "$DOCPROBE"
check "docs: ...including across the line wrap the round-3 sentence had" 0 "" \
  doc_sells_a_minted_agent "$DOCPROBE"
printf 'A freshly minted box has a coding agent.\n' > "$DOCPROBE"
check "docs: rule 1 reds on 'has' — the criterion's other verb (#214)" 0 "" \
  doc_sells_a_minted_agent "$DOCPROBE"
printf 'Every box comes with a coding agent.\n' > "$DOCPROBE"
check "docs: ...and on 'comes with'" 0 "" doc_sells_a_minted_agent "$DOCPROBE"
printf 'A mint leaves the box with a coding agent.\n' > "$DOCPROBE"
check "docs: ...and on 'leaves the box with'" 0 "" doc_sells_a_minted_agent "$DOCPROBE"
printf 'The template includes a coding agent.\n' > "$DOCPROBE"
check "docs: ...and on 'includes'" 0 "" doc_sells_a_minted_agent "$DOCPROBE"
# Denial launders nothing, in either position, and these are the probes that
# say so. A negation that is the AGENT'S makes the sentence honest; a negation
# of something else standing beside a live claim does not, wherever it stands.
# Every one of these was green on some earlier head of this branch, which is
# why each is written out rather than folded into one case.
printf 'A box ships a coding agent, and no credentials.\n' > "$DOCPROBE"
check "docs: ...and a denial beside the claim does not launder it" 0 "" \
  doc_sells_a_minted_agent "$DOCPROBE"
# TRAILING, the round-5 shape: a denial of the SAME noun after the claim and
# inside the arm's reach, so leftmost-longest ran the match on to it and the
# exemption dropped the claim with it.
printf 'The box ships an agent and no agent token.\n' > "$DOCPROBE"
check "docs: ...and a trailing denial of the same noun does not launder it either" 0 "" \
  doc_sells_a_minted_agent "$DOCPROBE"
printf 'A minted box ships a coding agent; there is no agent token.\n' > "$DOCPROBE"
check "docs: ...including across a semicolon, which is not a sentence end here" 0 "" \
  doc_sells_a_minted_agent "$DOCPROBE"
# LEADING, the round-6 shape, and the one the truncation that answered the two
# above could not reach: with the FIRST noun deciding, a denial placed before
# the claim took the claim away with the discarded tail. Blanking the denial
# first is what reds these; a post-hoc exemption cannot, whichever noun it is
# pointed at, because the window holds two nouns and votes once.
printf 'A box with no agent token still ships a coding agent.\n' > "$DOCPROBE"
check "docs: ...and a LEADING denial does not launder the claim after it (#214)" 0 "" \
  doc_sells_a_minted_agent "$DOCPROBE"
printf 'With no agent token and no PAT, a minted box has a coding agent.\n' > "$DOCPROBE"
check "docs: ...including two leading denials in front of the 'has' arm" 0 "" \
  doc_sells_a_minted_agent "$DOCPROBE"
# ...and the boundary that keeps the blanking honest in the other direction: a
# sentence whose ONLY agent noun is the denied one still greens, because after
# the blanking there is no claim left for the arms to find. This is
# README.md's creds-free line reduced to its shape, and it passes on its merits
# rather than on a window width or a truncation landing well.
printf 'A box ships with a thin seed and no credentials — no agent token, nothing.\n' > "$DOCPROBE"
check "docs: ...and a sentence whose only agent noun is denied still passes" 1 "" \
  doc_sells_a_minted_agent "$DOCPROBE"
# The subject alternation knows the noun this PR's own prose adopted. 'Seed' is
# what README.md:265 calls what a mint lands, so a guard blind to the word is
# blind to the page's own vocabulary -- and these three matched NOTHING, which
# is a different failure from matching and being exempted.
printf 'The tenant seed includes a coding agent.\n' > "$DOCPROBE"
check "docs: rule 1 reds on 'seed', the noun the page itself uses (#214)" 0 "" \
  doc_sells_a_minted_agent "$DOCPROBE"
printf 'The seed carries a coding agent.\n' > "$DOCPROBE"
check "docs: ...and on 'the seed carries'" 0 "" doc_sells_a_minted_agent "$DOCPROBE"
printf 'A fresh box is minted with a coding agent.\n' > "$DOCPROBE"
check "docs: ...and on the passive 'is minted with'" 0 "" \
  doc_sells_a_minted_agent "$DOCPROBE"
# ...and the boundary the widening had to keep: README.md:265's own sentence,
# whose subject IS 'seed' and whose verb IS 'carries', and which is honest
# because its object is a tenant user. Binding the object to the verb is what
# keeps it green; if the arm ever drifts back to "noun near verb", this reds.
printf 'The seed carries a tenant user, a fixed 1GiB /tmp, swap and chrony.\n' > "$DOCPROBE"
check "docs: ...and passes the real 'seed carries' sentence, whose object is not an agent" 1 "" \
  doc_sells_a_minted_agent "$DOCPROBE"
# Rule 1's converge boundary is now anchored to the match, so a false claim
# sharing a line with the documented converge no longer leaves with it — the
# hole the old whole-line 'grep -v' had.
printf 'rig bootstrap claude-box --user dev, because the claude-box template ships an agent.\n' \
  > "$DOCPROBE"
check "docs: ...and a claim sharing a line with 'rig bootstrap' still reds (the match, not the line)" 0 "" \
  doc_sells_a_minted_agent "$DOCPROBE"
# Rule 3, both ways: the retired possessive, and the two shapes that must pass —
# the agent an operator converged, named as theirs, and the box's own files.
printf "a runbook that the box's coding agent reads and acts on\n" > "$DOCPROBE"
check "docs: rule 3 reds on \"the box's coding agent\"" 0 "" \
  doc_calls_the_agent_the_box_s "$DOCPROBE"
printf "the coding agent you converged onto the box reads the box's .box/ runbook\n" > "$DOCPROBE"
check "docs: ...and passes the converged agent named as the operator's" 1 "" \
  doc_calls_the_agent_the_box_s "$DOCPROBE"
printf '%s\n' '```' 'box new' 'box shell' 'claude   # brings the project up' '```' > "$DOCPROBE"
check "docs: rule 2 reds on a mint-then-agent block" 0 "never converges it" \
  doc_flow_skips_the_converge "$DOCPROBE"
printf '%s\n' '```' 'box new' 'box root work' 'rig bootstrap claude-box' 'box shell' 'claude' '```' \
  > "$DOCPROBE"
check "docs: ...and passes the same block with the converge in it" 1 "" \
  doc_flow_skips_the_converge "$DOCPROBE"
printf '%s\n' '```' 'box new' 'box shell' 'git clone <repo>' '```' > "$DOCPROBE"
check "docs: ...and does not red a block that mints without invoking an agent" 1 "" \
  doc_flow_skips_the_converge "$DOCPROBE"
# ...and the converge is the CONVERGER'S installer. Box's own puts box on the
# host and converges nothing, so a block carrying it is not excused; rig's is
# the four-step path's third line and still is.
printf '%s\n' '```' 'curl -fsSL https://raw.githubusercontent.com/heavy-duty/box/main/install.sh | bash' \
  'box new' 'box shell' 'claude' '```' > "$DOCPROBE"
check "docs: rule 2 reds on a block whose only installer is box's own" 0 "never converges it" \
  doc_flow_skips_the_converge "$DOCPROBE"
printf '%s\n' '```' 'curl -fsSL https://raw.githubusercontent.com/heavy-duty/rig/main/install.sh | bash' \
  'box new' 'box shell' 'claude' '```' > "$DOCPROBE"
check "docs: ...and passes the same block with rig's installer in it" 1 "" \
  doc_flow_skips_the_converge "$DOCPROBE"
# Rule 4, both ways, starting with the literal the whole control is anchored on:
# docs/box-recipe.md:45 exactly as it stood at 8dcf19c, the line round 5 blocked
# on. It is written once, here, and every assertion below refers to THIS string
# rather than retyping it, so the fixture and the control cannot drift apart.
DOC_PRE_FIX_CONVERGE='curl -fsSL https://raw.githubusercontent.com/heavy-duty/rig/<ref>/install.sh | bash'
printf '%s\n' "$DOC_PRE_FIX_CONVERGE" > "$DOCPROBE"
check "docs: rule 4 reds on a converge that pins the installer but not the tree (#214)" 0 "" \
  doc_curls_rig_without_the_pin "$DOCPROBE"
# Double-quoted with '\\' rather than single-quoted with a trailing '\': the
# byte wanted is one literal backslash at end of line, and writing it inside
# single quotes reads to shellcheck as a botched quote escape (SC1003).
printf '%s\n' "curl -fsSL https://raw.githubusercontent.com/heavy-duty/rig/<ref>/install.sh \\" \
  '  | RIG_REPO=heavy-duty/rig RIG_REF=<ref> bash' > "$DOCPROBE"
check "docs: ...and passes the canonical form, wrapped as the README wraps it" 1 "" \
  doc_curls_rig_without_the_pin "$DOCPROBE"
# ...and bin/box's wrap, which is a backslash inside an echo's quotes and not a
# shell continuation at all. Folding the file to one line is what makes these
# the same case; a line-oriented rule would have to special-case it, and a rule
# with a special case per surface is a rule that misses the next surface.
printf '%s\n' '  echo "  curl -fsSL https://raw.githubusercontent.com/heavy-duty/rig/<ref>/install.sh \\" >&2' \
  '  echo "    | RIG_REPO=heavy-duty/rig RIG_REF=<ref> bash" >&2' > "$DOCPROBE"
check "docs: ...and passes bin/box's echo-wrapped copy of the same command" 1 "" \
  doc_curls_rig_without_the_pin "$DOCPROBE"
# ...and box's own installer is out by REPO. It pins with BOX_REF, it is a
# different contract, and 'rig/' is not in its URL -- so the rule never sees it
# and needs no exemption to say so. An exemption would be the thing that later
# gets widened; a scope cannot be.
printf '%s\n' 'curl -fsSL https://raw.githubusercontent.com/heavy-duty/box/main/install.sh | bash' \
  'curl -fsSL .../install.sh | BOX_REF=0.6.0 bash' > "$DOCPROBE"
check "docs: ...and never fires on box's own installer, which pins with BOX_REF" 1 "" \
  doc_curls_rig_without_the_pin "$DOCPROBE"
# ...and the two shapes the pipe anchor exists for. The first is the round-6
# probe: the defect line with a sentence ABOUT the pin after it, which the
# 120-char window read as a pin and reported green. Written from the same
# DOC_PRE_FIX_CONVERGE literal as every other assertion here, so it cannot
# drift away from the line it is supposed to be.
printf '%s\n' "$DOC_PRE_FIX_CONVERGE" \
  'Set RIG_REPO=heavy-duty/rig RIG_REF=0.3.0 in your environment first.' > "$DOCPROBE"
check "docs: rule 4 reds on an unpinned converge laundered by a sentence about the pin (#214)" 0 "" \
  doc_curls_rig_without_the_pin "$DOCPROBE"
# The second is what makes the pipe group optional rather than required: a
# converge that never pipes carries no pin either, and a rule that emits no
# match on it would report green on the loudest possible miss.
printf '%s\n' 'curl -fsSL https://raw.githubusercontent.com/heavy-duty/rig/<ref>/install.sh > /tmp/i.sh' \
  > "$DOCPROBE"
check "docs: ...and on a converge that pipes nowhere at all, so the anchor cannot go quiet" 0 "" \
  doc_curls_rig_without_the_pin "$DOCPROBE"
rm -f "$DOCPROBE"

# RULE 4'S NEGATIVE CONTROL, and it is a real page rather than a fixture.
#
# §4's 2026-08-22 amendment asks for "the same guard run against the real
# pre-cut docs/box-recipe.md". That object does not exist, and the measurement
# is the answer rather than an argument: at the pre-cut ancestor the whole tree
# carries ONE file matching 'rig/[^ ]*install.sh' -- test/cli.sh's pin group,
# which this branch deletes -- box's own three installer curls pin with BOX_REF
# and are out by repo, and templates/tenant/user-data.yaml:133 already piped
# through RIG_REPO="@RIG_REPO@" RIG_REF="@RIG_REF@". The repo has only ever
# taught the pinned form. The unpinned line was introduced by THIS branch's own
# prose at da6eb05, when the command moved from a seed box substitutes into a
# page an operator copies, so no pre-cut object can red this rule.
#
# The criterion's STANDARD is satisfiable where its object is not, and the
# standard is what the other rules actually meet: a real file, located and
# never hard-coded, red there and green here, loud rather than skipped. So the
# control MUTATES the live pages -- fold the continuation, strip the pin off
# the pipe -- and drives the guard at the result. Not a walk to 8dcf19c's blob,
# which would be more literal and worse: rules 0-3 walk to a commit on
# permanent history, while 8dcf19c is this branch's own, so that control's
# survival would depend on how a human merges, and a walk that finds nothing
# must fail loudly -- a red main for a history reason. A mutation has no
# history dependency in either direction.
doc_unpin_the_converge() {  # <file> -> the same page with rig's pin abbreviated off
  awk '
    hold != "" {                                  # the pipe under a folded curl
      sub(/^[ \t]*/, ""); sub(/RIG_REPO=[^ ]+[ \t]+RIG_REF=[^ ]+[ \t]+/, "")
      print hold " " $0; hold = ""; next
    }
    /rig\/[^ ]*install\.sh/ && /\\[ \t]*$/ {      # a page wrap: join it first
      hold = $0; sub(/[ \t]*\\[ \t]*$/, "", hold); next
    }
    /rig\/[^ ]*install\.sh/ { pend = NR + 1 }     # bin/box wraps inside an echo
    NR <= pend { sub(/RIG_REPO=[^ ]+[ \t]+RIG_REF=[^ ]+[ \t]+/, "") }
    { print }
    END { if (hold != "") print hold }
  ' "$1"
}
# The mutation corpus is NAMED, not discovered, and every member is asserted to
# carry a converge before it is mutated -- rule 0's lesson: a page that silently
# drops out of a data-driven list takes its own control with it. These are the
# three PIN_PAGES entries that curl rig's installer at HEAD; the other five make
# no converge claim, which the loop above already proves by reading them.
DOCMUT="$(mktemp)"
for rel in README.md docs/box-recipe.md bin/box; do
  check "docs: $rel carries a rig converge for the control to mutate (#214)" 0 "" \
    grep -qE 'rig/[^ ]*install\.sh' "$ROOT/$rel"
  doc_unpin_the_converge "$ROOT/$rel" > "$DOCMUT"
  # The half that stops this becoming a fixture with extra steps: if the
  # canonical form is ever reshaped past the mutation's reach, this reds rather
  # than quietly no-opping into a control that asserts nothing.
  check "docs: ...and the control's mutation actually bites $rel" 1 "" \
    cmp -s "$ROOT/$rel" "$DOCMUT"
  check "docs: rule 4 reds on the real $rel with its pin abbreviated away (#214)" 0 "" \
    doc_curls_rig_without_the_pin "$DOCMUT"
done
# ...and the assertion that earns the word REAL: on the two prose pages the
# mutation does not merely produce something the guard dislikes, it reproduces
# docs/box-recipe.md:45 at 8dcf19c byte for byte -- the exact line round 5
# blocked on, derived mechanically from the live page. bin/box is excluded here
# and only here: its copy is wrapped inside an echo, so the abbreviation lands
# as 'echo "    | bash" >&2' and there is no single line to compare.
for rel in README.md docs/box-recipe.md; do
  doc_unpin_the_converge "$ROOT/$rel" > "$DOCMUT"
  check "docs: ...and $rel's abbreviation is the round-5 line byte for byte" 0 "" \
    grep -qxF -e "$DOC_PRE_FIX_CONVERGE" "$DOCMUT"
done
rm -f "$DOCMUT"

# ---------------------------------------------------------------------------
# render_userdata (#81, #214) — the seed's ONE substitution, and after the cut
# @BOX_USER@ is the whole of it. What used to live here was the pin group: a
# shim curl serving canned releases/latest redirects, the default-is-latest
# assertions, the hostile-value gates. All of it went with the pin. What
# replaces it is the opposite assertion, and it is the sharper one: the pin
# tokens are INERT TEXT now, the pin environment changes nothing, and a mint
# makes no network request at all — so a box mints on a host that cannot reach
# github.com, which the pin probe had quietly taken away.
# ---------------------------------------------------------------------------
# A curl that cannot be called without saying so. Every invocation is logged
# and every invocation fails: 'no network call' is then proven twice over, by
# an empty log and by a render that did not die.
NETSHIM="$(mktemp -d)"
NETLOG="$(mktemp)"
cat > "$NETSHIM/curl" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_CURL_LOG:-/dev/null}"
exit 77
SHIM
chmod +x "$NETSHIM/curl"

RUFN="$(mktemp)"
awk '/^render_userdata\(\) \{/,/^\}/' "$ROOT/bin/box" > "$RUFN"
check "render_userdata: extracted from bin/box (guards the awk)" 0 "@BOX_USER@" cat "$RUFN"
check "render_userdata: the extracted function is valid bash" 0 "" bash -n "$RUFN"

SEED="$(mktemp)"
printf '#cloud-config\nusers:\n  - name: "@BOX_USER@"\nruncmd:\n  - curl -fsSL https://raw.githubusercontent.com/@RIG_REPO@/@RIG_REF@/install.sh | RIG_REPO="@RIG_REPO@" RIG_REF="@RIG_REF@" bash\n' > "$SEED"
SEEDFILE="$SEED"
# shellcheck disable=SC2016  # $0/$1 expand in the child shell, by design
rud() { # rud [VAR=val ...] — render the fixture seed through the real function
  : > "$NETLOG"
  env T_USER=fixture FAKE_CURL_LOG="$NETLOG" PATH="$NETSHIM:$PATH" "$@" \
      bash -c 'die() { echo "box: $*" >&2; exit 1; }; . "$0"; render_userdata "$1"' "$RUFN" "$SEEDFILE"
}
check "render_userdata: the tenant user reaches cloud-init (#159)" 0 \
  'name: "custom"' rud T_USER=custom
# The token is INERT TEXT (#214). A test that still expected resolution here
# would be asserting the thing this release removed, so what is asserted is
# that the seed comes out carrying its own bytes.
check "render_userdata: @RIG_REPO@ renders into itself — the token is inert (#214)" 0 \
  '@RIG_REPO@/@RIG_REF@/install.sh' rud
check "render_userdata: ...and RIG_REF in the environment does not touch it (#214)" 0 \
  '@RIG_REPO@/@RIG_REF@/install.sh' rud RIG_REF=main
check "render_userdata: ...nor does a pinned release (#214)" 0 \
  '@RIG_REPO@/@RIG_REF@/install.sh' rud RIG_REF=0.3.0
check "render_userdata: ...nor does an overridden repo (#214)" 0 \
  '@RIG_REPO@/@RIG_REF@/install.sh' rud RIG_REPO=you/rig
# The pin environment produces no warning either: box has no standing to
# comment on a variable that is now somebody else's (#214).
rud_is_silent() { local out; out="$(rud "$@" 2>&1 >/dev/null)"; [ -z "$out" ]; }
check "render_userdata: a set pin says nothing on stderr (#214)" 0 "" \
  rud_is_silent RIG_REF=main RIG_REPO=you/rig
# A value that used to DIE on the host — the tokens landed inside a runcmd
# shell line, so a smuggled quote had to be refused before it reached the YAML
# — now cannot die, because nothing reads it. The seed renders, untouched.
HOSTILE="$(mktemp)"
printf '#cloud-config\npackages:\n  - tmux\n' > "$HOSTILE"
rud_hostile() { SEEDFILE="$HOSTILE" rud 'RIG_REPO=evil"; rm -rf /; "/rig'; }
check "render_userdata: a hostile pin value cannot die on the host any more (#214)" 0 \
  'packages:' rud_hostile
rm -f "$HOSTILE"
check "render_userdata: the render makes NO network call (#214)" 1 "" \
  grep -q . "$NETLOG"

# The one seed renders into ONE measured shape (#214): the agent-class hygiene,
# unconditionally. Drive it through the real renderer, then make every
# assertion against what cloud-init receives rather than against source.
SEEDLOG="$(mktemp)"
SEEDFILE="$ROOT/templates/tenant/user-data.yaml"
rud T_USER=dev > "$SEEDLOG"
check "render_userdata: the tenant render makes no network call either (#214)" 1 "" \
  grep -q . "$NETLOG"
check "render_userdata: no sentinel survives into cloud-init (#159, #214)" 1 "" \
  grep -q '^# box-.*-only-' "$SEEDLOG"
check "render_userdata: source-only comments do not inflate Incus user-data (#159, #209)" 1 "" \
  sed '1d' "$SEEDLOG" | grep -qE '^[[:space:]]*#'
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "render_userdata: the payload stays below one 4KiB overflow page (#209)" 0 "" \
  bash -c '[ "$(wc -c < "$1")" -lt 4096 ]' _ "$SEEDLOG"
check "render_userdata: no token survives the render (#214)" 1 "" \
  grep -qE '@(RIG|BOX)_' "$SEEDLOG"
# The six rows of the seed's one hygiene (#214 section 2), each asserted
# against the RENDERED payload — the thing cloud-init is handed.
check "tenant seed: the tenant has no sudoers entry (#177)" 1 "" \
  grep -qE '^[[:space:]]*sudo:' "$SEEDLOG"
check "tenant seed: shellcheck ships (#177 decision 3)" 0 "" \
  grep -qE '^[[:space:]]*-[[:space:]]+shellcheck$' "$SEEDLOG"
check "tenant seed: python3-venv ships (#177 decision 3)" 0 "" \
  grep -qE '^[[:space:]]*-[[:space:]]+python3-venv$' "$SEEDLOG"
check "tenant seed: /tmp is capped at a FIXED 1GiB (#178)" 0 "" \
  grep -q 'size=1G' "$SEEDLOG"
check "tenant seed: a 4GiB swapfile is laid on the disk (#178)" 0 "" \
  grep -q 'fallocate -l 4G /swapfile' "$SEEDLOG"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "tenant seed: chrony and its makestep drop-in ship (#174)" 0 "" \
  bash -c 'grep -q "box-makestep.conf" "$1" && grep -qE "^[[:space:]]*-[[:space:]]+chrony$" "$1"' _ "$SEEDLOG"
check "tenant seed: the container-aware chrony start survives (#174)" 0 "" \
  grep -q 'systemd-detect-virt --quiet --container || systemctl start chrony' "$SEEDLOG"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "tenant seed: tmux, curl and ca-certificates ship (#65, #214)" 0 "" \
  bash -c 'for pkg in tmux curl ca-certificates; do
             grep -qE "^[[:space:]]*-[[:space:]]+$pkg\$" "$1" || exit 1; done' _ "$SEEDLOG"
check "tenant seed: package_update is on — the seed installs packages (#214)" 0 "" \
  grep -qE '^package_update: true$' "$SEEDLOG"
# The one default spelled in two files. bin/box needs a user before
# load_template has read one, so BOX_USER cannot be the single source — which
# makes 'they agree' something to assert rather than to hope.
# shellcheck disable=SC2016  # $1/$2 expand in the child shell, by design
check "tenant seed: BOX_USER and bin/box's default are the same 'dev' (#214)" 0 "" \
  bash -c 'grep -qx '"'"'BOX_USER="dev"'"'"' "$1" && grep -qF '"'"'user="${user:-dev}"'"'"' "$2"' \
  _ "$ROOT/templates/tenant/box.env" "$ROOT/bin/box"
rm -f "$RUFN" "$SEED"

# YAML well-formedness needs python3 + pyyaml; the CI runner has both. Skip
# gracefully (never silently) where they are missing.
HAVE_YAML=0
command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null && HAVE_YAML=1
if [ "$HAVE_YAML" = 1 ]; then
  check "tenant seed: the rendered payload is well-formed YAML (#159)" 0 "" \
    python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$SEEDLOG"
else
  echo "skip: rendered payload YAML well-formedness (no python3+pyyaml here; CI has both)"
fi

for d in "$ROOT"/templates/*/; do
  t="$(basename "$d")"
  # The parse itself asserts the allowlist AND the required keys (the driven
  # function dies without BOX_IMAGE/BOX_USER); the greps pin both keys to the
  # FILE, so neither can quietly become an inherited default.
  check "template '$t': box.env parses against the real allowlist" 0 "USER=" tpl "$ROOT" "$t"
  check "template '$t': box.env sets BOX_IMAGE" 0 "" grep -q '^BOX_IMAGE=' "$d/box.env"
  check "template '$t': box.env sets BOX_USER"  0 "" grep -q '^BOX_USER='  "$d/box.env"
  # #175: every shipped seed defaults to the VM trust boundary. Discovery is
  # deliberate: a new template that forgets the pin must fail this same loop.
  check "template '$t': declares one of the two no-fallback demands (#175)" \
    0 "" grep -Eq '^BOX_(REQUIRE_VM|NO_CONTAINER_FALLBACK)="1"$' "$d/box.env"
  # cloud-init is passed to Incus verbatim (modulo @BOX_USER@, the one
  # substitution left after #214), so it must exist, declare itself, and be
  # well-formed — a mint is far too late to learn about a typo.
  check "template '$t': user-data.yaml exists" 0 "" test -f "$d/user-data.yaml"
  # shellcheck disable=SC2016  # $1 expands in the child shell, by design
  check "template '$t': user-data.yaml begins with #cloud-config" 0 "" \
    bash -c 'head -1 "$1" | grep -qx "#cloud-config"' _ "$d/user-data.yaml"
  if [ "$HAVE_YAML" = 1 ]; then
    check "template '$t': user-data.yaml is well-formed YAML" 0 "" \
      python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$d/user-data.yaml"
  else
    echo "skip: template '$t' YAML well-formedness (no python3+pyyaml here; CI has both)"
  fi
  # #177: the tenant is UNPRIVILEGED, and the default is no sudoers entry at
  # all. Root was never the confidentiality boundary — the agent runs AS the
  # tenant — but it forecloses every in-guest control one might later add and
  # lets a box rewrite the evidence of its own contents; the operator path is
  # 'box root', which authorizes host-side and needs no sudoers entry (#176).
  # The two exceptions are NAMED here rather than inferred, so a new template
  # that ships a sudo line goes red in this loop until someone puts it on the
  # list deliberately — the same fail-closed shape as the absence block below.
  case "$t" in
    staging-box)
      # Self-converging fleet guests keep root: that guest's own first act,
      # run by its operator from inside, needs it. Tenants lose root,
      # self-converging guests keep it — two traits, two answers, and #175's
      # BOX_REQUIRE_VM is the one meant to be inherited.
      check "template '$t': keeps NOPASSWD sudo — a self-converging seed (#177)" 0 "" \
        grep -qE '^[[:space:]]*sudo: "ALL=\(ALL\) NOPASSWD:ALL"$' "$d/user-data.yaml" ;;
    tenant)
      # One shape since #214, so the SOURCE is the effective shape: there is no
      # conditional arm left for a sudo line to hide in.
      check "template 'tenant': has NO sudoers entry (#177, #214)" 1 "" \
        grep -qE '^[[:space:]]*sudo:' "$d/user-data.yaml" ;;
    *)
      # shellcheck disable=SC2016  # $1 expands in the child shell, by design
      check "template '$t': the tenant has NO sudoers entry (#177)" 1 "" \
        bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qE "^[[:space:]]*sudo:"' _ "$d/user-data.yaml" ;;
  esac
  # #177 decision 6: where a seed keeps sudo it is ALL or nothing. A partial
  # allowlist ('NOPASSWD: /usr/bin/apt-get') reintroduces most of the risk —
  # apt alone installs a package that owns the box — while feeling safer,
  # which is the worst combination. So the only permitted value is the full
  # one, in any template, and the grep runs over EFFECTIVE lines because the
  # comments above it name the shape they refuse.
  # shellcheck disable=SC2016  # $1 expands in the child shell, by design
  check "template '$t': a sudoers entry is ALL or nothing (#177)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -E "^[[:space:]]*sudo:" \
               | grep -qvE "^[[:space:]]*sudo: \"ALL=\(ALL\) NOPASSWD:ALL\"$"' _ "$d/user-data.yaml"
  # The half of the seed's user block that #177 did NOT change: no password
  # login, in every template. Dropping sudo while leaving the account
  # unlocked would trade one door for another.
  check "template '$t': the tenant password stays locked (#177)" 0 "" \
    grep -qE '^[[:space:]]*lock_passwd: true$' "$d/user-data.yaml"
  # #65: 'box tmux' runs 'tmux new-session' INSIDE the box, so every
  # template's package list must carry tmux or the verb dies inside.
  check "template '$t': installs tmux (#65)" 0 "" \
    grep -qE '^[[:space:]]*-[[:space:]]+tmux$' "$d/user-data.yaml"
  # #174: host suspend can leave a guest hours adrift. Every discovered
  # template therefore installs chrony, gives it an unlimited post-start
  # step window, and explicitly leaves the service enabled and running.
  check "template '$t': installs chrony (#174)" 0 "" \
    grep -qE '^[[:space:]]*-[[:space:]]+chrony$' "$d/user-data.yaml"
  check "template '$t': writes the chrony step drop-in (#174)" 0 "" \
    grep -qE '^[[:space:]]*-[[:space:]]+path:[[:space:]]+/etc/chrony/conf\.d/box-makestep\.conf$' "$d/user-data.yaml"
  check "template '$t': permits steps after every update (#174)" 0 "" \
    grep -qE '^[[:space:]]+makestep[[:space:]]+1\.0[[:space:]]+-1$' "$d/user-data.yaml"
  check "template '$t': enables chrony (#174)" 0 "" \
    grep -qE '^[[:space:]]*-[[:space:]]+systemctl enable chrony$' "$d/user-data.yaml"
  check "template '$t': starts chrony on clock-owning VM guests (#174)" 0 "" \
    grep -qE '^[[:space:]]*-[[:space:]]+systemd-detect-virt --quiet --container \|\| systemctl start chrony$' "$d/user-data.yaml"
  # #178: /tmp is RAM and systemd's stock tmp.mount sizes it at 50% of it, so
  # scratch and the agent's working set compete for the same BOX_MEMORY — and
  # raising that line raises the scratch ceiling with it, which is why the cap
  # has to be a fixed figure and not a smaller share. Measured live: a
  # claude-box at 8GiB carried a 3.9GB /tmp, and heavy-duty/incubator#214 lost
  # a test suite to ENOSPC on it against scratch left by earlier sessions.
  # Scoped to the AGENT seeds by the issue's own deliverables, and named
  # fail-closed in the same shape as the sudo block above: the exceptions are
  # listed, so a fifth agent seed inherits the requirement without an edit and
  # a fleet guest that grows a cap goes red until someone lists it deliberately.
  case "$t" in
    staging-box)
      # A self-converging fleet guest. A workload server's /tmp at 1GiB is a
      # decision #178 did not make, and swap on a guest that is not running
      # untrusted agent code is a different question; assert the ABSENCE so
      # the scoping is pinned rather than merely true today.
      # shellcheck disable=SC2016  # $1 expands in the child shell, by design
      check "template '$t': no /tmp cap and no swapfile — a fleet guest, outside #178" 1 "" \
        bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qE "tmp\.mount|swapfile"' _ "$d/user-data.yaml"
      # #208 D7: the shortened eviction age goes where the cap goes, and this
      # seed has no cap. The scoping is not the cap's own reasoning repeated —
      # an unneeded cap costs disk, where a shortened age DELETES FILES, and
      # on a long-lived fleet guest with no ceiling squeezing anything there
      # is nothing reclaimed in exchange. Opposite sign, so it stops here.
      # Asserted as an absence, like the cap's, so the scoping is pinned
      # rather than merely true today.
      # shellcheck disable=SC2016  # $1 expands in the child shell, by design
      check "template '$t': no tmpfiles age drop-in — a fleet guest, outside #208" 1 "" \
        bash -c 'grep -v "^[[:space:]]*#" "$1" |
                 grep -qE "tmpfiles\.d|^[[:space:]]+q[[:space:]]+/(var/)?tmp[[:space:]]"' _ "$d/user-data.yaml" ;;
    *)
      check "template '$t': writes the /tmp size drop-in (#178)" 0 "" \
        grep -qE '^[[:space:]]*-[[:space:]]+path:[[:space:]]+/etc/systemd/system/tmp\.mount\.d/box-size\.conf$' "$d/user-data.yaml"
      check "template '$t': caps /tmp at a fixed 1GiB (#178)" 0 "" \
        grep -qE '^[[:space:]]+Options=.*,size=1G,' "$d/user-data.yaml"
      # The cap is DECOUPLED from BOX_MEMORY, which is the whole of #178: a
      # percentage here would restore the coupling while looking like a fix.
      # shellcheck disable=SC2016  # $1 expands in the child shell, by design
      check "template '$t': the /tmp cap is a figure, not a share of BOX_MEMORY (#178)" 1 "" \
        bash -c 'grep -E "^[[:space:]]+Options=" "$1" | grep -q "size=[0-9]*%"' _ "$d/user-data.yaml"
      # A systemd drop-in REPLACES Options= rather than merging into it, so a
      # rewrite that forgets a flag silently unhardens /tmp — mode=1777 is what
      # makes it a shared scratch directory at all, and nosuid/nodev are the
      # reason a world-writable one is safe. Asserted per flag, so a later size
      # change touches only the check above.
      for o in mode=1777 strictatime nosuid nodev nr_inodes=1m; do
        check "template '$t': the /tmp drop-in keeps stock '$o' (Options= is replaced, #178)" 0 "" \
          grep -qE "^[[:space:]]+Options=(.*,)?$o(,|\$)" "$d/user-data.yaml"
      done
      # The drop-in is read at the next boot; the remount is what makes the cap
      # true on the mint boot, and it resizes a live tmpfs in place rather than
      # unmounting /tmp out from under cloud-init.
      check "template '$t': applies the /tmp cap on the mint boot too (#178)" 0 "" \
        grep -qE '^[[:space:]]*-[[:space:]]+test "\$\(findmnt -no FSTYPE /tmp\)" != tmpfs \|\| mount -o remount,size=1G /tmp$' "$d/user-data.yaml"
      # #208: the cap above is a SIZE decision and nothing reclaims what it
      # bounds. Debian's stock age is TEN DAYS and its daily cleaner was
      # measured evicting nothing while 2.8GB of earlier sessions' scratch sat
      # inside the window, so the seed states its own age. Three greps, because
      # the three halves fail independently: the file, the /tmp age, and the
      # /var/tmp restatement. There is deliberately no mint-boot counterpart to
      # the remount above — the age is read by the next timer firing, and a box
      # minted an hour ago has nothing to clean.
      check "template '$t': writes the tmpfiles age drop-in (#208)" 0 "" \
        grep -qE '^[[:space:]]*-[[:space:]]+path:[[:space:]]+/etc/tmpfiles\.d/tmp\.conf$' "$d/user-data.yaml"
      # Pinned to 1d exactly: it is derived from the 1GiB cap against a 672MB
      # observed peak and a daily cleaner, so a revert to Debian's 10d — or any
      # other figure — reds here rather than silently restoring the defect.
      check "template '$t': evicts /tmp scratch at 1d, not Debian's 10d (#208)" 0 "" \
        grep -qE '^[[:space:]]+q[[:space:]]+/tmp[[:space:]]+1777[[:space:]]+root[[:space:]]+root[[:space:]]+1d$' "$d/user-data.yaml"
      # systemd-tmpfiles reads the FIRST file of a name across its search path
      # and /etc/tmpfiles.d outranks /usr/lib/tmpfiles.d, so the drop-in MASKS
      # Debian's file rather than merging with it. A drop-in naming only /tmp
      # therefore removes /var/tmp's cleanup on every box, with no error
      # message anywhere — the silent regression this check exists for (#208).
      check "template '$t': restates /var/tmp at its stock 30d — the file MASKS Debian's (#208)" 0 "" \
        grep -qE '^[[:space:]]+q[[:space:]]+/var/tmp[[:space:]]+1777[[:space:]]+root[[:space:]]+root[[:space:]]+30d$' "$d/user-data.yaml"
      # #178 D2: no swap means every spike is a hard OOM-kill with no grace
      # period. Four greps, because the four halves fail independently — a
      # swapfile that is not made, not sized, not activated at boot, or made
      # in a container that cannot swapon at all.
      # shellcheck disable=SC2016  # $1 expands in the child shell, by design
      check "template '$t': provisions a 4GiB swapfile (#178)" 0 "" \
        bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qF "fallocate -l 4G /swapfile"' _ "$d/user-data.yaml"
      # shellcheck disable=SC2016
      check "template '$t': the swapfile is formatted and activated (#178)" 0 "" \
        bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qF "mkswap /swapfile" &&
                 grep -v "^[[:space:]]*#" "$1" | grep -qF "swapon /swapfile"' _ "$d/user-data.yaml"
      # shellcheck disable=SC2016
      check "template '$t': the swapfile survives a reboot (fstab, #178)" 0 "" \
        bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qF "/swapfile none swap sw 0 0"' _ "$d/user-data.yaml"
      # Guarded for chrony's reason, not a different one: a container shares
      # the host's swap and cannot swapon at all, so an unguarded seed writes
      # 4GiB of nothing into every container mint — CI's own rehearsal
      # included — and adds an fstab line that fails at every boot.
      # shellcheck disable=SC2016
      check "template '$t': swap provisioning is container-guarded (#174's guard, #178)" 0 "" \
        bash -c 'grep -v "^[[:space:]]*#" "$1" |
                 grep -qF "! systemd-detect-virt --quiet --container && [ ! -e /swapfile ]"' _ "$d/user-data.yaml"
      # #178 D3: the fact belongs next to the line that causes it. box.env
      # already carries a long explanatory header; this asserts it names both
      # halves and cites the incident, per CONTRIBUTING's comment rule.
      # shellcheck disable=SC2016
      check "template '$t': box.env states the /tmp and swap shape it causes (#178)" 0 "" \
        bash -c 'grep -qE "^#.*/tmp" "$1" && grep -qE "^#.*swap" "$1" && grep -qF "#178" "$1"' _ "$d/box.env" ;;
  esac
  # A dedicated seed duplicates BOX_USER into cloud-init. box's own tenant seed
  # instead carries exactly the token render_userdata replaces at mint.
  if [ "$t" = tenant ]; then
    check "template 'tenant': cloud-init carries the tenant user token (#159)" 0 "" \
      grep -qE '^[[:space:]]*-[[:space:]]+name:[[:space:]]+"@BOX_USER@"$' "$d/user-data.yaml"
  else
    tuser="$(tpl "$ROOT" "$t" | sed -n 's/.*USER=\([^ ]*\).*/\1/p')"
    check "template '$t': user-data.yaml creates BOX_USER ('$tuser')" 0 "" \
      grep -qE "^[[:space:]]*-[[:space:]]+name:[[:space:]]+$tuser\$" "$d/user-data.yaml"
  fi

  # ------------------------------------------------------------------------
  # The thin-template contract (#81, #214). It used to have two halves: a seed
  # that named a role had to preinstall the converger carrying both pin tokens,
  # on the installer URL and on the installer's own env. box installs nothing
  # into a guest now, so that half inverts — NO seed carries an installer line,
  # and the assertion is its absence.
  #
  # curl and ca-certificates stay, and their reason changed rather than
  # vanished: they carry the OPERATOR's installer, whose first line is a
  # 'curl … | bash' run inside the box. A seed that dropped them would break
  # the path this release replaced the mint hook with — so the packages are
  # required and the install LINE is refused, which is a narrower assertion
  # than "no curl" and the only one that is true.
  # ------------------------------------------------------------------------
  # shellcheck disable=SC2016  # $1 expands in the child shell, by design
  check "template '$t': the seed installs no converger (#214)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -q "install.sh"' _ "$d/user-data.yaml"
  # shellcheck disable=SC2016
  check "template '$t': ...and pipes nothing into a shell at all (#214)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qE "\\| *(HOME=[^ ]* )?(bash|sh)\\b"' _ "$d/user-data.yaml"
  for pkg in curl ca-certificates; do
    check "template '$t': keeps '$pkg' for the operator's installer (#214)" 0 "" \
      grep -qE "^[[:space:]]*-[[:space:]]+$pkg\$" "$d/user-data.yaml"
  done
  # ------------------------------------------------------------------------
  # THE ABSENCE — no tenant content in ANY template, ever again. What a box
  # becomes is converged inside it by its operator (#214); a template that
  # grows an agent CLI, docker, node, a tailnet join or a context-file heredoc
  # is the regression this suite exists to refuse. Greps run over EFFECTIVE
  # cloud-init lines (comments may name what they refuse — #69's idiom), and
  # they fail CLOSED: the want-exit is 1, so re-adding any of it goes red.
  # ------------------------------------------------------------------------
  # shellcheck disable=SC2016  # $1 expands in the child shell, by design
  check "template '$t': no agent CLI install (not box's job, #214)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qiE "claude\.ai|x\.ai|@openai|npm|nodesource|nodejs"' _ "$d/user-data.yaml"
  # shellcheck disable=SC2016
  check "template '$t': no docker (not box's job, #214)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qi docker' _ "$d/user-data.yaml"
  # shellcheck disable=SC2016
  check "template '$t': nothing that joins or admits (no tailscale/authkey/ssh)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qiE "tailscale|authkey|ssh"' _ "$d/user-data.yaml"
  # shellcheck disable=SC2016
  check "template '$t': no context file (box does not write one, #80, #214)" 1 "" \
    bash -c 'grep -v "^[[:space:]]*#" "$1" | grep -qiE "CLAUDE\.md|AGENTS\.md"' _ "$d/user-data.yaml"
done

# The staging seed's boot demands are part of its contract (#68/#69): the VM
# is its trust boundary (its guest runs docker, once converged) and a server
# returns from a host reboot without an operator. Pinned to the FILE so neither
# can quietly vanish in a rewrite.
check "staging-box: demands VM mode (BOX_REQUIRE_VM=1)" 0 "" \
  grep -qx 'BOX_REQUIRE_VM="1"' "$ROOT/templates/staging-box/box.env"
check "staging-box: demands autostart (BOX_AUTOSTART=1)" 0 "" \
  grep -qx 'BOX_AUTOSTART="1"' "$ROOT/templates/staging-box/box.env"
check "staging-box: keeps its 'ops' user (#214 kept the whole server shape)" 0 "USER=ops" tpl "$ROOT" staging-box
check "staging-box: its ops user still creates itself in cloud-init" 0 "" \
  grep -qE '^[[:space:]]*-[[:space:]]+name:[[:space:]]+ops$' "$ROOT/templates/staging-box/user-data.yaml"
check "staging-box: BOX_BOOTSTRAP_ROLE is gone from the file (#214)" 1 "" \
  grep -q 'BOX_BOOTSTRAP_ROLE' "$ROOT/templates/staging-box/box.env"
# #175's five softer declarations are pinned separately from the discovery
# guard above: the loop catches a future unpinned seed, while this catches one
# of today's seeds accidentally inheriting staging-box's stronger policy.
check "tenant: permits only an explicit container override (BOX_NO_CONTAINER_FALLBACK=1)" \
  0 "" grep -qx 'BOX_NO_CONTAINER_FALLBACK="1"' "$ROOT/templates/tenant/box.env"
# box's one tenant seed carries the unprivileged tool floor unconditionally
# (#214): there is no second shape and no role that could select one.
for p in python3-venv shellcheck; do
  check "tenant: ships '$p' — an unprivileged tenant cannot apt-install it (#177)" 0 "" \
    grep -qE "^[[:space:]]*-[[:space:]]+$p\$" "$ROOT/templates/tenant/user-data.yaml"
done
for retired in claude-box codex-box grok-box kimi-box; do
  check "templates: retired '$retired' seed is deleted (#159)" 1 "" \
    test -e "$ROOT/templates/$retired"
done
check "templates: retired 'blank' seed is deleted (#159)" 1 "" \
  test -e "$ROOT/templates/blank"

rm -f "$TPLFN" "$SEEDLOG"

# The keys' cmd_new half, grepped the way the expose guard is (line order —
# a daemon-free run cannot mint). Both refusals must read the EFFECTIVE mode,
# i.e. come after pick_mode: refusing on a template key alone would refuse
# valid VM mints, and a guard deleted in a refactor must not ship green.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the REQUIRE_VM refusal orders after pick_mode" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  pick="$(printf "%s\n" "$fn" | grep -n "pick_mode"    | head -1 | cut -d: -f1)"
  guard="$(printf "%s\n" "$fn" | grep -n "T_REQUIRE_VM" | head -1 | cut -d: -f1)"
  [ -n "$pick" ] && [ -n "$guard" ] && [ "$pick" -lt "$guard" ]'
# Order is necessary, not sufficient: the policy call must receive $m, the
# effective pick_mode result, rather than the raw requested mode.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the template policy receives both demands and effective mode (\$m)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "template_mode_allowed" \
    | grep -qF "\"\$T_REQUIRE_VM\" \"\$T_NO_CONTAINER_FALLBACK\" \"\$m\" \"\$mode\""'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the soft KVM-less refusal names KVM and the explicit weaker override (#175)" \
  0 "" bash -c '
  line="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep "defaults to the VM boundary")"
  printf "%s\n" "$line" | grep -q -- "--container" &&
    printf "%s\n" "$line" | grep -q "weaker isolation"'
# #68 is byte-for-byte behavior, not merely an equivalent refusal. Pin both
# messages so #175 cannot advertise an override staging-box does not permit.
check "new: REQUIRE_VM keeps the explicit-container refusal wording (#68)" 0 "" \
  grep -Fq "usage_error \"template '\$t' requires VM mode — it will not mint as a container (drop --container)\"" "$ROOT/bin/box"
check "new: REQUIRE_VM keeps the KVM-less refusal wording (#68)" 0 "" \
  grep -Fq "die \"template '\$t' requires VM mode and this host has no /dev/kvm — mint it on a KVM-capable host (or via --remote)\"" "$ROOT/bin/box"
check "new: boot.autostart is stamped under the T_AUTOSTART guard" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -F "boot.autostart=true" | grep -q "T_AUTOSTART"'

# Drive mode selection with a stubbed host predicate: the suite must cover
# both KVM answers regardless of the machine it happens to run on (#175).
PICKFN="$(mktemp)"
sed -n '/^pick_mode() {/,/^}/p' "$ROOT/bin/box" > "$PICKFN"
pick_mode_case() {
  bash -c '
    . "$0"
    mode="$1"; remote="$2"
    if [ "$3" = yes ]; then
      host_has_kvm() { return 0; }
    else
      host_has_kvm() { return 1; }
    fi
    pick_mode
  ' "$PICKFN" "$@"
}
check "pick_mode: automatic mode chooses VM when KVM is present (#175)" \
  0 "vm" pick_mode_case auto "" yes
check "pick_mode: automatic mode falls back when KVM is absent (#175)" \
  0 "container" pick_mode_case auto "" no
check "pick_mode: explicit --container survives a KVM-less host (#175)" \
  0 "container" pick_mode_case container "" no
check "pick_mode: explicit --vm survives a KVM-less host (#175)" \
  0 "vm" pick_mode_case vm "" no
check "pick_mode: a remote mint remains VM mode without local KVM (#175)" \
  0 "vm" pick_mode_case auto "remote:" no
rm -f "$PICKFN"

# Drive the template policy separately from mode selection. Composed with the
# discovery assertion above, this simulates the required KVM-less paths for
# every shipped template without trusting the runner's hardware (#175).
POLICYFN="$(mktemp)"
sed -n '/^template_mode_allowed() {/,/^}/p' "$ROOT/bin/box" > "$POLICYFN"
template_mode_case() { bash -c '. "$0"; template_mode_allowed "$@"' "$POLICYFN" "$@"; }
check "template mode: REQUIRE_VM refuses an automatic container fallback (#68)" \
  1 "" template_mode_case 1 "" container auto
check "template mode: REQUIRE_VM permits a VM (#175)" \
  0 "" template_mode_case 1 "" vm auto
check "template mode: REQUIRE_VM refuses explicit --container on either host shape (#68)" \
  1 "" template_mode_case 1 "" container container
check "template mode: NO_CONTAINER_FALLBACK refuses an automatic fallback (#175)" \
  1 "" template_mode_case "" 1 container auto
check "template mode: NO_CONTAINER_FALLBACK permits a VM (#175)" \
  0 "" template_mode_case "" 1 vm auto
check "template mode: NO_CONTAINER_FALLBACK permits explicit --container (#175)" \
  0 "" template_mode_case "" 1 container container
check "template mode: REQUIRE_VM wins when both keys are set (#175)" \
  1 "" template_mode_case 1 1 container container
check "template mode: an unpinned template keeps the ordinary fallback" \
  0 "" template_mode_case "" "" container auto
rm -f "$POLICYFN"

# Compose the real selector and policy for the host/request matrix. The two
# explicit staging cases look redundant only after the host fact is discarded;
# keeping both pins criterion 8 to KVM-present and KVM-less hosts separately.
MATRIXFN="$(mktemp)"
sed -n '/^pick_mode() {/,/^}/p' "$ROOT/bin/box" > "$MATRIXFN"
sed -n '/^template_mode_allowed() {/,/^}/p' "$ROOT/bin/box" >> "$MATRIXFN"
template_request_case() { # require no-fallback requested remote has-kvm
  bash -c '
    . "$0"
    require_vm="$1"; no_fallback="$2"; mode="$3"; remote="$4"
    if [ "$5" = yes ]; then
      host_has_kvm() { return 0; }
    else
      host_has_kvm() { return 1; }
    fi
    effective="$(pick_mode)"
    template_mode_allowed "$require_vm" "$no_fallback" "$effective" "$mode"
  ' "$MATRIXFN" "$@"
}
check "staging policy: --container is refused on a KVM-capable host (#68, #175)" \
  1 "" template_request_case 1 "" container "" yes
check "staging policy: --container is refused on a KVM-less host (#68, #175)" \
  1 "" template_request_case 1 "" container "" no
check "staging policy: an automatic KVM-less mint is refused (#68, #175)" \
  1 "" template_request_case 1 "" auto "" no
check "agent policy: an automatic KVM-less mint is refused (#175)" \
  1 "" template_request_case "" 1 auto "" no
check "agent policy: explicit --container succeeds on a KVM-less host (#175)" \
  0 "" template_request_case "" 1 container "" no
check "agent policy: an automatic mint uses a VM when KVM exists (#175)" \
  0 "" template_request_case "" 1 auto "" yes
rm -f "$MATRIXFN"

# The seed still reaches Incus through render_userdata and not through a raw
# cat — that is the one thing the substitution half of #81 leaves behind. The
# auto-run half is GONE (#214): what used to sit here asserted that the
# convergence exec ordered after the cloud-init wait, sat under the
# T_BOOTSTRAP_ROLE guard, and named 'box root' in its failure hint. There is no
# exec, no guard and no failure hint, so the assertions invert — a mint emits
# no convergence exec at all, at any position, under any guard.
check "new: cloud-init user-data goes through render_userdata" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -F "cloud-init.user-data" | grep -q "render_userdata"'
check "new: no mint path execs a converger in the guest (#214)" 1 "" bash -c '
  grep -E "^[[:space:]]*[^#]" "'"$ROOT"'/bin/box" | grep "incus exec" | grep -qw "rig"'
# On ACTING lines, the same rule the strong form uses: the comment that says
# what BOX_BOOTSTRAP_ROLE was and why it went is exactly the prose a reader
# arriving at the allowlist needs, and deleting it would delete the record.
sf_names() { strongform "$1" | grep -q -- "$2"; }
check "new: T_BOOTSTRAP_ROLE is gone from bin/box's code (#214)" 1 "" \
  sf_names "$ROOT/bin/box" 'T_BOOTSTRAP_ROLE'
check "new: BOX_BOOTSTRAP_ROLE is gone from bin/box's code (#214)" 1 "" \
  sf_names "$ROOT/bin/box" 'BOX_BOOTSTRAP_ROLE'

# The launch phase, narrated and time-boxed (#93) — grepped the way the other
# mint-path guards are (a daemon-free run cannot mint). Twice in the
# 2026-07-19 release drill the child 'incus launch' wedged silently before
# the create was even accepted, once for 56 minutes. The narration must order
# BEFORE the launch call (a wedge after the line is visible at a glance; a
# wedge before it is the old silent hang), the call itself must sit under
# 'timeout -k' with the BOX_LAUNCH_TIMEOUT override and pinned stdin (RUNS.md
# trap 13: bare 'timeout N' cannot kill an incus call that owns a TTY), and
# the budget's failure must be LOUD — no server-side operation, the measured
# retry-succeeds hint, and the doctor as the next move.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the launch narration orders before incus launch (#93)" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  say="$(printf "%s\n" "$fn" | grep -n "launching instance" | head -1 | cut -d: -f1)"
  run="$(printf "%s\n" "$fn" | grep -n "timeout -k.*incus launch" | head -1 | cut -d: -f1)"
  [ -n "$say" ] && [ -n "$run" ] && [ "$say" -lt "$run" ]'
check "new: incus launch is time-boxed (timeout -k on the budget)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "timeout -k" | grep "budget" | grep -q "incus launch"'
check "new: the budget is BOX_LAUNCH_TIMEOUT, default 600s (the BOX_CPU knob shape)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "budget=" | grep -q "BOX_LAUNCH_TIMEOUT:-600"'
check "new: the launch pins stdin (RUNS.md trap 13)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -F "extra[@]" | grep -qF "</dev/null"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the wedge failure is loud — retry hint, the doctor, and #93" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  printf "%s\n" "$fn" | grep -A6 "WEDGED" | grep -q "observed to succeed" &&
  printf "%s\n" "$fn" | grep -q "box doctor" &&
  printf "%s\n" "$fn" | grep "did not finish inside" | grep -q "#93"'
# timeout proves only that the CLIENT overran the budget: launch is
# create-then-start, so a slow launch may have REGISTERED the instance and a
# blind "never created, retry" would send the operator into 'Instance already
# exists' (#94 round-1, all three reviewers). The timeout path must probe the
# instance, tell the two stories apart, and best-effort delete either way so
# the retry advice is safe in both worlds.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the timeout path probes before claiming never-created (#94 r1)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "incus info" | grep -q "\$instance"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the timeout path best-effort deletes, so retry is always clean" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "incus delete --force" | grep -q "|| true"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: the overran-but-registered branch says so (not the wedge story)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep "OVERRAN" | grep -q "budget"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "new: BOX_LAUNCH_TIMEOUT is documented in box help new" 0 "" bash -c '
  "'"$ROOT"'/bin/box" help new | grep "BOX_LAUNCH_TIMEOUT" | grep -q 600'
# staging-box's creds-holding join stayed OPERATOR-run from #69 onwards, and
# since #214 so does everything beside it. box neither runs nor prints a
# convergence command now, so the assertion is the strongest form of the one
# that was here: no template names a convergence role at all.
# shellcheck disable=SC2016  # the path expands in the child shell, by design
check "templates: no template names a convergence role at all (#214)" 1 "" bash -c '
  grep -h "^BOX_BOOTSTRAP_ROLE=" "'"$ROOT"'"/templates/*/box.env | grep -q .'
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "new: the ready hint offers 'box root' for a server-class box (#176, #214)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -A10 "eff. = staging-box" | grep -q "box root \$name"'

# ---------------------------------------------------------------------------
# The 'pristine' mark (#104). The whole feature is a MOMENT: the guest after
# cloud-init and before anything converges it. Get the position wrong by one
# step and the mark is a lie — a 'pristine' taken after a convergence run is a
# converged box wearing the wrong label, and nothing at runtime would ever say
# so. Since #214 box hands the box over at exactly this point, so the mark is
# the LAST thing a fresh mint does rather than the second to last. So the position is pinned by line
# order, the way the other mint-path guards are (a daemon-free run cannot
# mint), and the policy half is DRIVEN against a stubbed incus.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "pristine: the mark is taken in the fresh-mint branch" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "snapshot_pristine \"\$instance\""'
# AFTER cloud-init: before it, the guest is mid-install and the mark is not
# pristine Debian, it is a half-provisioned one.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "pristine: the mark orders AFTER the cloud-init wait" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  wait="$(printf "%s\n" "$fn" | grep -n "cloud-init status --wait" | head -1 | cut -d: -f1)"
  snap="$(printf "%s\n" "$fn" | grep -n "snapshot_pristine " | head -1 | cut -d: -f1)"
  [ -n "$wait" ] && [ -n "$snap" ] && [ "$wait" -lt "$snap" ]'
# The mark used to have to order BEFORE the convergence hook — the assertion
# the whole of #104 rested on. There is no hook to order against since #214, so
# what replaces it is the fact that produced that ordering: nothing in the
# fresh-mint branch touches the guest AFTER the mark. A step added below it
# would converge the box and leave 'pristine' describing a state that no longer
# existed when it was taken, which is exactly the lie the ordering prevented.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "pristine: nothing touches the guest after the mark (#104, #214)" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  snap="$(printf "%s\n" "$fn" | grep -n "snapshot_pristine " | head -1 | cut -d: -f1)"
  after="$(printf "%s\n" "$fn" | tail -n "+$((snap + 1))" | grep -c "incus exec")"
  [ -n "$snap" ] && [ "$after" -eq 0 ]'
# Unconditional, and now unconditionally so: there is no role to gate it on,
# and "box restore <box> pristine" means one thing on every box box mints.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "pristine: the mark is gated on nothing at all (#104, #214)" 1 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" \
    | grep -B4 "snapshot_pristine " | grep -qE "^[[:space:]]*if \["'

# THE CLONE TRAP. --from skips cloud-init entirely, so the
# pristine moment never happens on that path. A mark taken there would be
# "whatever the source was" — converged, worked-in — wearing a label that
# promises pristine Debian, which is strictly worse than no mark. Pin the
# ABSENCE: extract the clone branch alone (up to its 'else') and assert
# nothing in it takes the mark.
CLONEBR="$(mktemp)"
awk '/if \[ -n "\$from" \]; then/,/^  else$/' "$ROOT/bin/box" > "$CLONEBR"
check "pristine: the clone branch extracted from bin/box (guards the awk)" 0 "incus copy" cat "$CLONEBR"
check "pristine: a --from clone takes NO mark of its own (the correctness trap)" 1 "" \
  grep -q "snapshot_pristine" "$CLONEBR"
check "pristine: nothing on the clone path creates a snapshot at all" 1 "" \
  grep -q "incus snapshot create" "$CLONEBR"
# Inheritance is the other half of the decision, and it must be SAID: a clone
# of a box carries the source's snapshots (a real pristine among them), a
# clone of a snapshot carries none. Silence there sends the operator to
# 'box info' to find out which world they are in.
check "pristine: the clone narrates whether a pristine rode along" 0 "" \
  grep -q "no 'pristine' mark here" "$CLONEBR"
# ...and it reads the snapshot list CAPTURE-FIRST (#124's class). Piping a
# multi-line incus writer into an early-exit reader lets the reader close the
# pipe, SIGPIPE incus, and hand pipefail a 141 — which on THIS line reads as
# "no pristine" and narrates the wrong inheritance shape on a clone that has
# one. Pin the shape, not the instance spelling: no 'incus snapshot list'
# feeding grep/head/sed/awk/read directly.
check "pristine: the clone's inheritance read is capture-first, not a piped early-exit reader" 1 "" \
  grep -Eq 'incus snapshot list[^|]*\| *(grep|head|sed|awk|read)' "$CLONEBR"
rm -f "$CLONEBR"

# The policy half, DRIVEN not grepped: extract storage_driver +
# snapshot_pristine and run them against a stubbed incus, so every branch is
# actually executed on a host with no daemon.
PRISFN="$(mktemp)"
awk '/^storage_driver\(\) \{/,/^\}/;/^snapshot_mark\(\) \{/,/^\}/;/^mark_taken\(\)/;/^snapshot_pristine\(\) \{/,/^\}/' "$ROOT/bin/box" > "$PRISFN"
check "pristine: the functions extracted from bin/box (guards the awk)" 0 "BOX_SNAPSHOT_PRISTINE" cat "$PRISFN"
check "pristine: the extracted functions are valid bash" 0 "" bash -n "$PRISFN"

# storage_driver's probes must survive a REFUSAL, and not by accident. Today
# command substitution strips errexit, so a failing probe falls through to the
# fallback; add 'shopt -s inherit_errexit' to bin/box — the robustness tweak
# #107 describes sailing through review — and under pipefail that same refusal
# becomes a fatal abort mid-mint, inside the function whose contract is NEVER
# fatal. Drive it with inherit_errexit ON and a tier that refuses both probes:
# the function must return empty (the unreadable-pool case) and the caller
# must still be alive afterwards.
driver_under_inherit_errexit() {
  # shellcheck disable=SC2016  # the body is the stub's source, expanded by the
  # inner bash, never by this shell.
  env PRISFN="$PRISFN" bash -c '
    set -euo pipefail
    shopt -s inherit_errexit
    incus() {
      case "$*" in
        "profile device get box-profile root pool") printf "boxpool\n" ;;
        *) printf "incus: not authorized\n" >&2; return 1 ;;
      esac
    }
    . "$PRISFN"
    d="$(storage_driver)"
    printf "SURVIVED driver=[%s]\n" "$d"
  ' 2>&1
}
check "pristine: a refused storage probe is an answer, not a fatal (survives inherit_errexit)" 0 "SURVIVED driver=[]" \
  driver_under_inherit_errexit

# pris <driver> [env...] — drive snapshot_pristine against a fake pool of
# <driver>. 'none' makes both probes answer nothing (the unreadable-pool
# case). Every incus call the function can make is stubbed and echoed, so the
# assertions read the real control flow, not a mock's opinion of it.
pris() { # pris <driver> <instance> [VAR=VAL...]
  local driver="$1" instance="$2"; shift 2
  # shellcheck disable=SC2016  # the body is the stub's source, expanded by the
  # inner bash from the environment 'env' sets up — never by this shell.
  env "$@" DRIVER="$driver" INSTANCE="$instance" PRISFN="$PRISFN" bash -c '
    incus() {
      case "$*" in
        "profile device get box-profile root pool") printf "boxpool\n" ;;
        "storage show boxpool")
          [ "$DRIVER" = none ] && return 1
          printf "name: boxpool\ndriver: %s\n" "$DRIVER" ;;
        "storage list --format csv")
          [ "$DRIVER" = none ] && return 1
          printf "boxpool,%s,,0,CREATED\n" "$DRIVER" ;;
        "snapshot create inst-x pristine") printf "STUB: snapshot created\n" ;;
        "snapshot create fail-x pristine") printf "STUB: incus refused\n" >&2; return 1 ;;
        *) printf "STUB: unexpected incus call: %s\n" "$*" >&2; return 1 ;;
      esac
    }
    . "$PRISFN"
    snapshot_pristine "$INSTANCE" boxname
  ' 2>&1
}
# The absence assertions need a command 'check' can run, not a pipeline.
pris_took_mark() { pris "$@" | grep -q "STUB: snapshot created"; }
check "pristine: btrfs (the designed backend) takes the mark" 0 "STUB: snapshot created" \
  pris btrfs inst-x
check "pristine: btrfs names the restore command for the operator" 0 "box restore boxname pristine" \
  pris btrfs inst-x
# The 'dir' fallback (host/setup-host.sh:294) has no CoW: the mark would be a
# full multi-GB copy of the root on EVERY mint. Skip — and LOUDLY, naming the
# by-hand command, because a silent skip teaches an operator to expect a mark
# that is not there.
check "pristine: a 'dir' pool SKIPS the mark (no CoW — it would be a full copy)" 0 "NOT taking" \
  pris dir inst-x
check "pristine: the dir skip is loud and names the by-hand command" 0 "box snapshot boxname pristine" \
  pris dir inst-x
check "pristine: the dir skip never reaches incus snapshot create" 1 "" \
  pris_took_mark dir inst-x
# Neither probe answers (an unusual host, or a tier that cannot read the
# pool). The two mistakes are not symmetric — a mark taken on 'dir' wastes
# disk the operator can see and delete, a mark NOT taken is the moment gone
# for good. So proceed, and say what was assumed.
check "pristine: an unreadable pool takes the mark anyway (the asymmetry)" 0 "STUB: snapshot created" \
  pris none inst-x
check "pristine: ...and says what it assumed rather than pretending it knew" 0 "could not read the storage driver" \
  pris none inst-x
# The escape hatch is an environment knob (the BOX_LAUNCH_TIMEOUT shape), not
# another flag on 'new'.
check "pristine: BOX_SNAPSHOT_PRISTINE=0 skips it anywhere" 0 "BOX_SNAPSHOT_PRISTINE=0" \
  pris btrfs inst-x BOX_SNAPSHOT_PRISTINE=0
check "pristine: the opt-out never reaches incus snapshot create" 1 "" \
  pris_took_mark btrfs inst-x BOX_SNAPSHOT_PRISTINE=0
# A failed snapshot must NOT fail the mint. The mark is an undo, not the
# mint's product: a mint that worked must not be failed by a checkpoint that
# didn't.
check "pristine: a failed snapshot warns and returns 0 (never fails a good mint)" 0 "WARNING" \
  pris btrfs fail-x

# The durability caveat, pinned in the help text: a snapshot dies with its
# box, so nothing box says may let anyone read 'pristine' as a backup (#104's
# closing note; 'box export' is the durable path).
check "pristine: 'box help snapshot' refuses to sell snapshots as backups" 0 "not a backup" \
  bash -c '"'"$ROOT"'/bin/box" help snapshot'
check "pristine: 'box help restore' documents the mark and its off-box blind spot" 0 "off-box" \
  bash -c '"'"$ROOT"'/bin/box" help restore'
check "pristine: 'box help new' documents the mark and the opt-out" 0 "BOX_SNAPSHOT_PRISTINE" \
  bash -c '"'"$ROOT"'/bin/box" help new'

# The retired convergence mark must stay gone from implementation and help.
# This fails on the parent commit, where both spellings are live (#213).
check "snapshots: the retired convergence mark cannot reappear in bin/box (#213)" 1 "" \
  grep -qE 'bootstrapped|BOX_SNAPSHOT_BOOTSTRAPPED' "$ROOT/bin/box"

# One auto-mark policy and the explicit snapshot verb are the only two create
# sites. A second automatic mark would make this count three.
check "pristine: exactly one auto-mark policy — 'incus snapshot create' twice in bin/box" 0 "2" \
  bash -c 'grep -c "incus snapshot create" "'"$ROOT"'/bin/box"'

# --- only offer a rollback that EXISTS -------------------------------------
# The never-fatal contract means snapshot_mark returns 0 whether it took the
# mark, skipped it, or was refused — so the exit status cannot answer "is
# there something to restore?" and any message offering one must ask 'marks'.
# Driven per path rather than asserted once: the three no-mark paths fail
# differently and a single case would let the other two regress silently.
took() { # took <driver> <label> [VAR=VAL...] — did THIS run create the mark?
  local driver="$1" label="$2"; shift 2
  # shellcheck disable=SC2016  # the body is the stub's source, expanded by the
  # inner bash from the environment 'env' sets up — never by this shell.
  env "$@" DRIVER="$driver" LABEL="$label" PRISFN="$PRISFN" bash -c '
    incus() {
      case "$*" in
        "profile device get box-profile root pool") printf "boxpool\n" ;;
        "storage show boxpool")
          [ "$DRIVER" = none ] && return 1
          printf "name: boxpool\ndriver: %s\n" "$DRIVER" ;;
        "storage list --format csv")
          [ "$DRIVER" = none ] && return 1
          printf "boxpool,%s,,0,CREATED\n" "$DRIVER" ;;
        "snapshot create fail-x "*) return 1 ;;
        "snapshot create "*) printf "STUB: snapshot created\n" ;;
        *) return 1 ;;
      esac
    }
    marks=""
    . "$PRISFN"
    snapshot_mark "$INSTANCE_X" boxname "$LABEL" "${ENABLED:-1}" "some state" >/dev/null 2>&1
    mark_taken "$LABEL" && echo TAKEN || echo ABSENT
  ' 2>&1
}
check "rollback: a mark that WAS created is remembered" 0 "TAKEN" \
  took btrfs pristine INSTANCE_X=inst-x
check "rollback: a 'dir' skip is NOT remembered (no CoW, no mark)" 0 "ABSENT" \
  took dir pristine INSTANCE_X=inst-x
check "rollback: the opt-out knob is NOT remembered" 0 "ABSENT" \
  took btrfs pristine INSTANCE_X=inst-x ENABLED=0
check "rollback: a REFUSED create is not remembered (incus said no)" 0 "ABSENT" \
  took btrfs pristine INSTANCE_X=fail-x
# One label's mark must not answer for another's.
check "rollback: marks do not bleed between labels" 0 "ABSENT" \
  bash -c 'marks=" manual "; . "'"$PRISFN"'"; mark_taken pristine && echo TAKEN || echo ABSENT'
# The one CALLER of mark_taken was the convergence hook's failure message: on a
# 'dir' host every hook failure reached that line with no pristine mark, so an
# unconditional offer was a copy-pasteable command that errored at the one
# moment the operator was standing there. #214 removed the hook and the message
# with it, so cmd_new offers no restore at all — and the assertion inverts to
# that absence, which is what keeps a future offer from shipping ungated.
# mark_taken() itself stays: it is the honest reader of `marks` (the never-fatal
# contract makes the exit status unusable), and the next caller needs it.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "rollback: cmd_new offers no restore it cannot promise (#104, #214)" 1 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "box restore .* pristine. is still there"'
check "rollback: mark_taken survives for the next caller (#104)" 0 "" \
  grep -q '^mark_taken()' "$ROOT/bin/box"
rm -f "$PRISFN"

# ---------------------------------------------------------------------------
# The restricted tier (#74). box_tier() is the decision the whole tier hangs
# on, so it is DRIVEN, not grepped: extracted from bin/box, sourced, and run
# against a shim id for every case — including the one that bites (a user in
# BOTH groups is admin: membership wins at the socket, and the function must
# not substring-match 'incus' inside 'incus-admin').
# ---------------------------------------------------------------------------
TIERFN="$(mktemp)"
awk '/^box_tier\(\) \{/,/^\}/' "$ROOT/bin/box" > "$TIERFN"
check "box_tier: extracted from bin/box (guards the awk)" 0 "incus-admin" cat "$TIERFN"
check "box_tier: the extracted function is valid bash"    0 "" bash -n "$TIERFN"

tier() { # tier <uid> <groups...>
  local uid="$1"; shift
  FAKE_UID="$uid" FAKE_GROUPS="$*" PATH="$SHIMDIR:$PATH" \
    bash -c ". '$TIERFN'; box_tier"
}
check "box_tier: uid 0 → admin"                    0 "admin"      tier 0
check "box_tier: incus-admin → admin"              0 "admin"      tier 1000 "users incus-admin"
check "box_tier: incus only → restricted"          0 "restricted" tier 1000 "users incus"
check "box_tier: both groups → admin (membership wins at the socket)" \
                                                    0 "admin"      tier 1000 "users incus incus-admin"
check "box_tier: neither → none"                   0 "none"       tier 1000 "users dialout"
rm -f "$TIERFN"

# setup-host.sh must decide the tier BEFORE any install tree exists, so it
# carries its own copy — and a drifted copy is two tiers pretending to be one.
# Byte-identical, asserted.
BINFN="$(mktemp)"; HOSTFN="$(mktemp)"
awk '/^box_tier\(\) \{/,/^\}/' "$ROOT/bin/box"            > "$BINFN"
awk '/^box_tier\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$HOSTFN"
check "box_tier: bin/box and setup-host.sh copies are byte-identical" 0 "" \
  diff "$BINFN" "$HOSTFN"
rm -f "$BINFN" "$HOSTFN"

# The tier scripts parse and refuse bad usage without a daemon — drive them.
check "grant: no argument is a usage error"      2 "usage: box grant"  bash "$ROOT/host/grant-user.sh"
check "grant: a flag is not a user"              2 "usage: box grant"  bash "$ROOT/host/grant-user.sh" --frob
check "revoke: no argument is a usage error"     2 "usage: box revoke" bash "$ROOT/host/revoke-user.sh"
check "revoke: two users is a usage error"       2 "usage: box revoke" bash "$ROOT/host/revoke-user.sh" a b
check "box grant with no user exits 2 (via the CLI table)"  2 "usage: box grant"  "$BOX" grant
check "box revoke with no user exits 2 (via the CLI table)" 2 "usage: box revoke" "$BOX" revoke
check "help grant names the hardened network" 0 "boxnet" "$BOX" help grant
check "help revoke names --purge"             0 "purge"  "$BOX" help revoke

# The help is the PRE-RUN CONTRACT: an operator reads it to decide whether to
# run the command at all, so it must not promise a mutation that will not
# happen (or deny one that will). Round 1 of #101 changed what grant/revoke
# mutate for an incus-admin member and left this prose describing the
# superseded design — these pins are why that cannot happen silently again.
# Both directions: the current sentence must be present, and the superseded
# one must be gone.
check "help grant: the admin member's group step is a real add, not a no-op" \
  0 "like anyone else" "$BOX" help grant
check "help revoke: a bare revoke of a granted admin member is 'partial:'" \
  0 "partial:" "$BOX" help revoke
check "help grant no longer calls the admin group step a no-op" 0 "" \
  bash -c '! "'"$BOX"'" help grant | grep -q "reported no-op"'
check "help revoke no longer claims there is no membership to drop" 0 "" \
  bash -c '! "'"$BOX"'" help revoke | grep -q "no membership to drop"'

# Load-bearing lines a daemon-free run cannot exercise — grepped so a deleted
# guard cannot ship green (the house test discipline).
# The expose guard must fire before ANY incus call in cmd_expose: line order.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "expose: the restricted guard precedes the first incus call" 0 "" bash -c '
  fn="$(awk "/^cmd_expose\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  guard="$(printf "%s\n" "$fn" | grep -n "box_tier" | head -1 | cut -d: -f1)"
  first="$(printf "%s\n" "$fn" | grep -n "incus config" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] && [ -n "$first" ] && [ "$guard" -lt "$first" ]'
# cmd_new refuses before minting when the placement contract is absent, and
# the message is tier-aware (a restricted user is sent to 'box grant', not
# to setup-host they cannot run). The pre-flight lives in require_stack()
# since #70 gave it a second caller (import lands on the same contract), so
# assert both halves: the helper holds the probe, and cmd_new calls it.
check "require_stack: probes the box-profile profile" 0 "" bash -c '
  awk "/^require_stack\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "incus profile show box-profile"'
check "require_stack: the restricted fix names box grant" 0 "" bash -c '
  awk "/^require_stack\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "box grant"'
check "new: pre-flights the stack (require_stack)" 0 "" bash -c '
  awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "require_stack"'
# grant converges to boxnet and ONLY boxnet — "boxnet,incusbr" would keep the
# unhardened private bridge one --network flag away (the #74 measured hole).
check "grant: narrows access to boxnet alone" 0 "" \
  grep -qE 'restricted\.networks\.access boxnet($| )' "$ROOT/host/grant-user.sh"
check "grant: never grants the private bridge" 1 "" \
  grep -qE 'networks\.access[^#]*incusbr' "$ROOT/host/grant-user.sh"
check "grant: allows snapshots (the clone workflow)" 0 "" \
  grep -qF 'restricted.snapshots allow' "$ROOT/host/grant-user.sh"
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "grant: installs the SHIPPED profile into the project" 0 "" \
  grep -qF 'profile edit box-profile < "$here/profiles/box-profile.yaml"' "$ROOT/host/grant-user.sh"
check "grant: unpins the private-bridge eth0 from the default profile" 0 "" \
  grep -qF 'profile device remove default eth0' "$ROOT/host/grant-user.sh"
check "grant: an incus-admin member is provisioned, not refused (#99)" 1 "" \
  grep -qF 'there is nothing tighter to grant' "$ROOT/host/grant-user.sh"
check "revoke: group removal is the lockout" 0 "" \
  grep -qF 'gpasswd -d' "$ROOT/host/revoke-user.sh"
# Group membership is read at login: purge must terminate live sessions (a
# stale-group process could recreate the project unhardened AFTER the purge),
# and a bare revoke must say the socket survives in held sessions.
check "revoke: purge terminates live sessions first" 0 "" \
  grep -qF 'loginctl terminate-user' "$ROOT/host/revoke-user.sh"
check "revoke: purge refuses under unkillable sessions" 0 "" \
  grep -qF 'refusing to purge under them' "$ROOT/host/revoke-user.sh"
check "revoke: bare revoke warns about held sessions" 0 "" \
  grep -qF 'live sessions' "$ROOT/host/revoke-user.sh"
check "revoke: the purge asserts the certificate's absence too" 0 "" \
  bash -c 'awk "/Assert absence/,0" "'"$ROOT"'/host/revoke-user.sh" | grep -q "config trust list"'
# A failed grant must not leave a half-granted user: if THIS run added the
# group, the exit path takes it back (and the trap disarms only on success).
check "grant: backs out its own group-add on failure" 0 "" \
  grep -qF 'trap backout EXIT' "$ROOT/host/grant-user.sh"
check "grant: the back-out disarms on success" 0 "" \
  grep -qF 'trap - EXIT' "$ROOT/host/grant-user.sh"
# The backout must VERIFY the removal and scream when it cannot — an
# unverified rollback printing a security guarantee is the review's A2.
check "grant: the backout verifies against the group database" 0 "" \
  bash -c 'awk "/^backout\(\) \{/,/^\}/" "'"$ROOT"'/host/grant-user.sh" | grep -q "id -nG"'
check "grant: an unverifiable rollback screams" 0 "" \
  grep -qF 'ROLLBACK INCOMPLETE' "$ROOT/host/grant-user.sh"
check "grant: a failed re-grant warns the pre-existing member is untouched" 0 "" \
  grep -qF 'still holding socket access' "$ROOT/host/grant-user.sh"
check "grant: the mid-grant login window is named" 0 "" \
  bash -c 'awk "/^backout\(\) \{/,/^\}/" "'"$ROOT"'/host/grant-user.sh" | grep -q "loginctl terminate-user"'
# The scoped guarantee (raw --network boxnet) is measured, not prose:
check "rehearsal: measures the raw boxnet attach (criterion m)" 0 "" \
  grep -qF -- '--network boxnet' "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "rehearsal: injects grant failures (criterion n)" 0 "" \
  grep -qF 'grant-user.sh" "$U3"' "$ROOT/drill/multiuser.sh"
# Criterion o is the real-Incus half of #101: the shim cannot model an EACCES
# on the user socket, so the admin-only grant is measured where the socket has
# a real owning group. Pinned so it cannot quietly leave the rehearsal.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "rehearsal: grants an incus-admin-ONLY member on real Incus (criterion o)" 0 "" \
  grep -qF 'usermod -aG incus-admin "$U5"' "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # ditto
check "rehearsal: ...and opens the user socket as them, not just the daemon" 0 "" \
  grep -qF 'INCUS_SOCKET="$sockdir/unix.socket.user"' "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "revoke: purge deletes instances one at a time" 0 "" \
  grep -qF 'delete -f "$inst"' "$ROOT/host/revoke-user.sh"
check "revoke: purge removes the trust-store certificate" 0 "" \
  grep -qF 'config trust remove' "$ROOT/host/revoke-user.sh"

# ---------------------------------------------------------------------------
# #99: an incus-admin member is PROVISIONED, not refused. The distinction the
# old refusal missed is permission (the 'incus' group — theirs already, and
# stronger) versus provisioning (the user-<uid> project, the boxnet narrowing,
# snapshots, backups, the box-profile profile — theirs not at all). Grepping the
# new prose would prove only that the prose exists, so both tier scripts are
# DRIVEN end to end under shims, the same seam setup-host is driven through:
# every incus and sudo call is logged, and the assertions are made against
# those logs — what the run did, not what the source says it would do.
# ---------------------------------------------------------------------------
GSHIM="$(mktemp -d)"; W99="$(mktemp -d)"
cat > "$GSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the driven grant/revoke: logs every call, answers the
# existence probes from FAKE_*, and models the two state changes the scripts
# depend on — the project appearing after the incus-user touch, and
# disappearing after a purge deletes it.
[ -n "${FAKE_INCUS_LOG:-}" ] && printf 'incus %s\n' "$*" >> "$FAKE_INCUS_LOG"
case "$*" in *"profile edit"*) cat >/dev/null ;; esac
case "$*" in
  "network show boxnet")  [ -n "${FAKE_HAVE_BOXNET:-}" ] || exit 1 ;;
  "project show "*)
    [ -e "$FAKE_STATE/deleted" ] && exit 1
    if [ -n "${FAKE_PROJECT_LAZY:-}" ]; then
      # Lazy creation: absent on the first look, present afterwards — i.e.
      # the touch worked. n counts the looks this run has taken.
      n=0; [ -e "$FAKE_STATE/looks" ] && n="$(cat "$FAKE_STATE/looks")"
      printf '%s\n' "$((n + 1))" > "$FAKE_STATE/looks"
      [ "$n" -ge 1 ] || exit 1
    else
      [ -n "${FAKE_HAVE_PROJECT:-}" ] || exit 1
    fi ;;
  "project delete "*) : > "$FAKE_STATE/deleted" ;;
  *"restricted.networks.access"*)
    [ -z "${FAKE_FAIL_NARROW:-}" ] || { echo 'Instance "old" is on incusbr-1000' >&2; exit 1; } ;;
  *"network show "*) exit 1 ;;   # the private bridge: never there in these runs
esac
exit 0
SHIM
cat > "$GSHIM/sudo" <<'SHIM'
#!/usr/bin/env bash
# Fake sudo: logs and swallows — EXCEPT 'sudo test', which is run for real.
# Both scripts route filesystem probes through it on purpose (/var/lib/incus
# is not traversable by a non-root admin, so an unprivileged stat lies), and
# both directions matter here: revoke's absence assert must see incus-user's
# state directory as genuinely absent on a clean machine, and grant's socket
# check must see the shimmed unix.socket.user as genuinely present.
[ -n "${FAKE_SUDO_LOG:-}" ] && printf 'sudo %s\n' "$*" >> "$FAKE_SUDO_LOG"
case "${1:-}" in test) shift; test "$@"; exit $? ;; esac
exit 0
SHIM
printf '#!/usr/bin/env bash\nexit 0\n'                > "$GSHIM/getent"
printf '#!/usr/bin/env bash\nexit 0\n'                > "$GSHIM/systemctl"
printf '#!/usr/bin/env bash\nexit 1\n'                > "$GSHIM/pgrep"
chmod +x "$GSHIM/incus" "$GSHIM/sudo" "$GSHIM/getent" "$GSHIM/systemctl" "$GSHIM/pgrep"

# The pinned incus-user socket. box grant resolves it through INCUS_DIR (the
# client's own first choice), so a directory here is the whole seam.
mkdir -p "$W99/incusdir"; : > "$W99/incusdir/unix.socket.user"

rungrant() { # rungrant <groups> <state-dir> [VAR=val ...] — the real grant, shimmed
  local groups="$1" state="$2"; shift 2
  mkdir -p "$state"
  env FAKE_UID=1000 FAKE_GROUPS="$groups" FAKE_STATE="$state" \
      FAKE_HAVE_BOXNET=1 FAKE_PROJECT_LAZY=1 INCUS_DIR="$W99/incusdir" \
      FAKE_INCUS_LOG="$state/incus.log" FAKE_SUDO_LOG="$state/sudo.log" \
      PATH="$GSHIM:$SHIMDIR:$PATH" "$@" bash "$ROOT/host/grant-user.sh" dev1
}

# --- the admin member: full convergence, no group change, honest caveat -----
A="$W99/admin"
check "grant: an incus-admin member CONVERGES (exit 0, no refusal)" 0 "granted:" \
  rungrant "users incus-admin" "$A"
check "grant: ...and the group step is a real convergence, named as one" 0 "added dev1 to 'incus'" \
  rungrant "users incus-admin" "$W99/a2"
check "grant: ...saying WHY (the socket is a file, group 'incus', not a privilege)" 0 "mode 0660" \
  rungrant "users incus-admin" "$W99/a2b"
check "grant: ...the caveat calls it a default placement, not a confinement" 0 "DEFAULT PLACEMENT" \
  rungrant "users incus-admin" "$W99/a3"
check "grant: ...and names the group that has to go for it to bind" 0 "gpasswd -d dev1 incus-admin" \
  rungrant "users incus-admin" "$W99/a4"
# The logs: what the run actually did to the machine.
# #101's decision, pinned at the seam that broke: an incus-admin member IS
# usermod'ed into 'incus'. It buys them no API privilege they lack — but
# incus-user's socket is a FILE, group 'incus' mode 0660, and without the
# membership the pinned touch below takes EACCES, the '|| true' eats it, and
# the grant dies blaming a healthy incus-user. The shim cannot model that
# EACCES (it ignores INCUS_SOCKET and permissions entirely), so the decision
# is pinned here and MEASURED on real Incus in drill/multiuser.sh criterion o.
check "grant: the admin member IS added to 'incus' — the user socket's group (#101)" 0 "" \
  grep -qF 'usermod -aG incus dev1' "$A/sudo.log"
check "grant: their project is still narrowed to boxnet" 0 "" \
  grep -qF 'project set user-1000 restricted.networks.access boxnet' "$A/incus.log"
check "grant: their project still gets snapshots" 0 "" \
  grep -qF 'project set user-1000 restricted.snapshots allow' "$A/incus.log"
check "grant: their project still gets backups" 0 "" \
  grep -qF 'project set user-1000 restricted.backups allow' "$A/incus.log"
check "grant: box-profile is still installed INTO their project" 0 "" \
  grep -qF -- '--project user-1000 profile edit box-profile' "$A/incus.log"
# The socket pin (#99's teeth): incus's client takes the DAEMON socket when it
# is writable, and only falls back to unix.socket.user when it is not — so for
# an incus-admin member an unpinned touch never reaches incus-user at all, and
# the project it was supposed to create never appears.
check "grant: the touch is pinned at incus-user's socket (the admin socket would win)" 0 "" \
  grep -qF "INCUS_SOCKET=$W99/incusdir/unix.socket.user" "$A/sudo.log"
check "grant: the user-side proof names their project (an unqualified show proves nothing)" 0 "" \
  grep -qF -- '--project user-1000 profile show box-profile' "$A/sudo.log"
# The socket existence probe rides $SUDO, like revoke's: /var/lib/incus is not
# traversable by a non-root admin, and a bare [ -e ] there false-fails into an
# exit that blames incus-user for a socket that is present (#101 review).
check "grant: the socket probe goes through sudo, not a bare [ -e ]" 0 "" \
  grep -qF "test -e $W99/incusdir/unix.socket.user" "$A/sudo.log"

# --- the restricted user: unchanged, and unpinned ---------------------------
R="$W99/restricted"
check "grant: a plain user is still added to 'incus'" 0 "added dev1 to 'incus'" \
  rungrant "users" "$R"
check "grant: ...via usermod (the log, not the prose)" 0 "" \
  grep -qF 'usermod -aG incus dev1' "$R/sudo.log"
check "grant: ...and their client is left to its own socket fallback" 1 "" \
  grep -qF 'INCUS_SOCKET' "$R/sudo.log"

# --- the failure path: what this run added comes back, and says what didn't --
F="$W99/failed"
check "grant: a failed grant for an admin member exits 1" 1 "FAILED" \
  rungrant "users incus-admin" "$F" FAKE_FAIL_NARROW=1
check "grant: ...says their admin socket was neither granted nor removed here" 1 "neither granted nor removed" \
  rungrant "users incus-admin" "$W99/f2" FAKE_FAIL_NARROW=1
# The membership IS this run's now, so the backout IS its business (#101).
check "grant: ...and DOES roll the 'incus' membership back (this run added it)" 0 "" \
  grep -qF 'gpasswd -d dev1 incus' "$F/sudo.log"
check "grant: ...while refusing to call that rollback a lockout" 1 "closed incus-user's socket, NOT" \
  rungrant "users incus-admin" "$W99/f3" FAKE_FAIL_NARROW=1

# --- revoke, the mirror: it cannot take what it never gave ------------------
# BOX_YES=1 throughout: --purge is destructive and refuses without a terminal
# to confirm on, and this suite has none. It changes nothing for a bare revoke.
runrevoke() { # runrevoke <groups> <state-dir> [script args...]
  local groups="$1" state="$2"; shift 2
  mkdir -p "$state"
  env FAKE_UID=1000 FAKE_GROUPS="$groups" FAKE_STATE="$state" BOX_YES=1 \
      FAKE_HAVE_PROJECT=1 FAKE_INCUS_LOG="$state/incus.log" FAKE_SUDO_LOG="$state/sudo.log" \
      PATH="$GSHIM:$SHIMDIR:$PATH" bash "$ROOT/host/revoke-user.sh" dev1 "$@"
}
# The granted admin member is in BOTH groups — that is what 'box grant' leaves
# behind now (#101) — so revoke has a real membership to take back. It takes
# it, and still refuses to call the result a lockout: 'incus-admin' holds the
# daemon and is not this script's to remove.
GRANTED="users incus incus-admin"
V="$W99/revoke"
check "revoke: a bare revoke of a granted admin member is 'partial', not 'revoked'" 0 "partial:" \
  runrevoke "$GRANTED" "$V"
check "revoke: ...and refuses to call it a lockout" 0 "is NOT locked out" \
  runrevoke "$GRANTED" "$W99/v2"
check "revoke: ...naming the group that would actually lock them out" 0 "gpasswd -d dev1 incus-admin" \
  runrevoke "$GRANTED" "$W99/v3"
# The mirror of grant's flip: there IS a privileged call now, and it is the
# membership grant added — asserted against the log, not the prose.
check "revoke: ...having actually dropped the 'incus' membership (the log)" 0 "" \
  grep -qF 'gpasswd -d dev1 incus' "$V/sudo.log"
check "revoke: ...calling that key incus-user's, not their daemon access" 0 "NOT their daemon access" \
  runrevoke "$GRANTED" "$W99/v4"
# An admin member who was never granted: nothing to take, and it still says so
# rather than reporting a revocation it did not perform.
N="$W99/revoke-ungranted"
check "revoke: an UNgranted admin member is still a named no-op" 0 "no-op:" \
  runrevoke "users incus-admin" "$N"
check "revoke: ...saying their access is incus-admin's, untouched here" 0 "which this does not touch" \
  runrevoke "users incus-admin" "$W99/n2"
# Absence of the LOG, not of a line in it: an ungranted admin member's bare
# revoke makes no privileged call whatsoever, so the file is never created.
check "revoke: ...having made NO privileged call at all (no membership to drop)" 1 "" \
  test -e "$N/sudo.log"
P="$W99/purge"
check "revoke --purge: still unmakes the provisioning" 0 "purged:" \
  runrevoke "$GRANTED" "$P" --purge
check "revoke --purge: ...and refuses to call an admin member 'out'" 0 "is NOT out" \
  runrevoke "$GRANTED" "$W99/p2" --purge
check "revoke --purge: ...the project really was deleted (the log, not the summary)" 0 "" \
  grep -qF 'project delete user-1000' "$P/incus.log"
# #229 D7 — both names, for one release, and read off the call log rather than
# the file's text: a comment naming the old name satisfies the corpus guard,
# and only the call satisfies this. install.sh skips host setup on an upgrade,
# so an upgraded host still carries box-net in every granted project until an
# admin runs setup-host by hand; a project holding one is not empty, so the
# project delete above fails and names three probes that are all empty,
# because the blocker is a profile none of them shows.
check "revoke --purge: ...deleting the contract by its current name" 0 "" \
  grep -qF 'profile delete box-profile' "$P/incus.log"
check "revoke --purge: ...and by the pre-0.10.0 name an upgraded host still has (#229)" 0 "" \
  grep -qF 'profile delete box-net' "$P/incus.log"
rm -rf "$GSHIM" "$W99"
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "setup-host: the restricted gate precedes the sudo resolution" 0 "" bash -c '
  gate="$(grep -n "restricted tier" "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  sudo="$(grep -n "^elif command -v sudo" "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  [ -n "$gate" ] && [ -n "$sudo" ] && [ "$gate" -lt "$sudo" ]'
check "setup-host: enables incus-user.socket for the tier" 0 "" \
  grep -qF 'incus-user.socket' "$ROOT/host/setup-host.sh"
check "doctor: honors BOX_TIER" 0 "" \
  grep -qF 'BOX_TIER' "$ROOT/drill/doctor.sh"
check "box exports BOX_TIER to the doctor" 0 "" \
  grep -qF 'export BOX_TIER' "$ROOT/bin/box"
# 'box restore' must speak incus 6 ('snapshot restore'); bare 'incus restore'
# does not exist and the verb was broken for everyone until #74's rehearsal hit it.
check "restore: dispatches 'incus snapshot restore'" 0 "" \
  grep -qF '^incus:snapshot restore^' "$ROOT/bin/box"

# ---------------------------------------------------------------------------
# The confirm gate (#105) — DRIVEN, not grepped.
#
# Until #105 the only coverage restore had was the two argument-validation
# checks above: neither ever reached dispatch, so the verb spent four releases
# handing a running box straight to 'incus snapshot restore' with no prompt
# and no --force, and nothing in this suite could have noticed. Both halves of
# the gate are now exercised against a fake incus that logs what it was asked
# to do — refusing must leave the log EMPTY (an assertion about an absence is
# the only way to prove a gate held), and --force must produce the restore.
#
# Stdin is closed on every run on purpose: confirm() branches on '[ -t 0 ]',
# and a suite run from a terminal would otherwise inherit one and sit there
# waiting for a human to type 'y'.
# ---------------------------------------------------------------------------
CSHIM="$(mktemp -d)"; CWORK="$(mktemp -d)"
cat > "$CSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the destructive-path drive. Logs every call, and answers the
# one probe resolve_box makes so a box called 'work' exists and is ours.
[ -n "${FAKE_INCUS_LOG:-}" ] && printf 'incus %s\n' "$*" >> "$FAKE_INCUS_LOG"
case "$*" in
  "config get work user.box") echo 1 ;;
  "exec work -- bash -l")
    if [ "${FAKE_ROOT_STOPPED:-0}" = 1 ]; then
      echo "Error: Instance is not running" >&2
      exit 1
    fi ;;
  "config get "*)             exit 1 ;;
esac
exit 0
SHIM
chmod +x "$CSHIM/incus"

runbox() {  # runbox <logfile> <args...> — the real box, shimmed, no TTY
  local log="$1" rc; shift
  : > "$log"
  # Output is kept in <log>.out as well as replayed, so a check can assert on
  # what the run PRINTED after the fact — check() swallows the output of a run
  # it passes, and the "the prompt does not say 'delete'" assertion is exactly
  # that: a claim about text from a run that already passed on its exit code.
  env FAKE_INCUS_LOG="$log" PATH="$CSHIM:$PATH" "$BOX" "$@" </dev/null >"$log.out" 2>&1
  rc=$?
  cat "$log.out"
  return "$rc"
}

# --- root: a named host-authorized path that never depends on guest sudo ----
ROOTLOG="$CWORK/root.log"
check "root: help explains Incus-socket authorization" 0 "Authorization comes from the host's" \
  "$BOX" help root
check "root: help says guest sudo is not required" 0 "does not use or require sudo" \
  "$BOX" help root
check "root: dispatches a root login shell" 0 "" runbox "$ROOTLOG" root work
check "root: reaches Incus directly as root, without guest sudo" 0 "" \
  grep -qFx 'incus exec work -- bash -l' "$ROOTLOG"
check "root: a nonexistent box fails through the shared box guard" 1 "no such box" \
  runbox "$CWORK/root-missing.log" root missing
root_stopped() { FAKE_ROOT_STOPPED=1 runbox "$CWORK/root-stopped.log" root work; }
check "root: a stopped box preserves Incus's failure" 1 "Instance is not running" \
  root_stopped
# shellcheck disable=SC2016  # $inst and the command substitution are literal bin/box source.
check "root: shell implementation remains the tenant-user contract" 0 "" \
  grep -qFx 'cmd_shell() { incus exec "$inst" -- sudo -u "$(box_user "$inst")" -i; }' "$BOX"
check "root: live rehearsal removes the tenant sudoers entry" 0 "" \
  grep -qF 'box root precondition:' "$ROOT/drill/multiuser.sh"
check "root: live rehearsal measures tenant and root entry identities" 0 "" \
  grep -qF 'entry identities after removing' "$ROOT/drill/multiuser.sh"
check "root: live rehearsal refuses a foreign root shell" 0 "" \
  grep -qF 'cannot box root' "$ROOT/drill/multiuser.sh"

# --- restore: the gate refuses, and nothing is destroyed --------------------
RLOG="$CWORK/restore.log"
check "restore: refuses without --force when there is no terminal (#105)" \
  2 "refusing to roll work back to snapshot 'authed'" \
  runbox "$RLOG" restore work authed
# The exact no-TTY wording, pinned. This is the regression test for the CI
# failure this PR produced: the multi-user rehearsal drives restore unattended
# on real Incus, took this refusal, and recorded '(b) restore failed' — a
# 40-minute job catching what a 15-second suite should have. box refuses
# rather than assuming consent, and it says which of the two ways out applies.
check "restore: ...and the refusal names the missing terminal, not a bad usage (#105)" \
  2 "no terminal to confirm on" \
  runbox "$CWORK/r-tty.log" restore work authed
# The load-bearing assertion: the refusal actually PREVENTED the rollback.
# 'grep -q' on an absence, so an empty log passes and a logged restore fails.
check "restore: ...and the refusal reached incus with no restore (#105)" 1 "" \
  grep -qF 'snapshot restore' "$RLOG"
# The prompt must name the SNAPSHOT and the loss, not rm's wording. This is
# the entire point of making the prompt row-driven: adding the 'confirm' token
# alone would have asked the operator to confirm deleting the box.
check "restore: the prompt names what is lost, not a deletion (#105)" \
  2 "discard everything in the box since it was taken" \
  runbox "$CWORK/r2.log" restore work authed
check "restore: the prompt does NOT offer to delete the box (#105)" 1 "" \
  grep -qF 'delete work' "$CWORK/r2.log.out"

# --- restore: --force is the way through, and it still restores -------------
FLOG="$CWORK/force.log"
check "restore --force: skips the prompt and restores (#105)" 0 "restored work to authed" \
  runbox "$FLOG" restore work authed --force
check "restore --force: ...and incus was really asked for the rollback (#105)" 0 "" \
  grep -qF 'incus snapshot restore work authed' "$FLOG"
# Removing an automatic label does not reserve it: restore remains a generic
# snapshot-name passthrough so existing boxes keep their old restore point.
LEGACY_RESTORE_LOG="$CWORK/legacy-restore.log"
check "restore: a retired automatic label remains a generic passthrough (#213)" 0 "" \
  runbox "$LEGACY_RESTORE_LOG" restore work bootstrapped --force
check "restore: the legacy name reaches Incus unchanged (#213)" 0 "" \
  grep -qF 'incus snapshot restore work bootstrapped' "$LEGACY_RESTORE_LOG"

# --- rm: its wording is unchanged, and its gate still holds -----------------
# #105 moved the prompt out of the dispatch line and into the rows. rm's text
# was the string that lived there, so it is pinned verbatim: a refactor that
# rewords the ONE verb that already asked correctly is a regression.
MLOG="$CWORK/rm.log"
check "rm: still refuses without --force, in its own words (#105 refactor)" \
  2 "refusing to delete work and all its snapshots" \
  runbox "$MLOG" rm work
check "rm: ...and nothing was deleted" 1 "" grep -qF 'delete' "$MLOG"
check "rm --force: still deletes" 0 "removed work" runbox "$CWORK/rmf.log" rm work --force
check "rm --force: ...via 'incus delete -f'" 0 "" \
  grep -qF 'incus delete -f work' "$CWORK/rmf.log"

# --- the table invariant: a confirm row must carry its own words ------------
# Fail-closed on the shape itself, so a future 'confirm' row cannot ship with
# an empty prompt field and inherit whatever the dispatch happens to say.
# shellcheck disable=SC2016  # $3/$7/$1 are awk's fields, not the shell's
check "table: every 'confirm' row supplies a prompt (#105)" 0 "" \
  awk -F'^' '
    /^CMDS=\(/ { in_t = 1; next }
    in_t && /^\)/ { exit }
    in_t && /^  "/ && $3 ~ /(^|,)confirm(,|$)/ {
      seen = 1
      if (NF < 7) { print "row for " $1 " is marked confirm with no prompt field"; bad = 1; next }
      p = $7; sub(/"$/, "", p)
      if (p == "") { print "row for " $1 " has an empty confirm prompt"; bad = 1 }
    }
    END { if (!seen) { print "no confirm rows found — the pin is not reading the table"; bad = 1 }
          exit (bad ? 1 : 0) }
  ' "$ROOT/bin/box"
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "dispatch: the confirm prompt comes from the row, not a constant (#105)" 0 "" \
  grep -qF 'confirm "$(fill "$cnf" "$inst")"' "$ROOT/bin/box"
# The rehearsal drives restore unattended on real Incus, so it must consent
# EXPLICITLY — the gate is only real if the one automated caller had to change.
# Pinned here because the rehearsal itself needs a daemon and this suite has none.
check "rehearsal: the unattended restore passes --force (#105)" 0 "" \
  grep -qF 'box restore mine s1 --force' "$ROOT/drill/multiuser.sh"
# --- the three answers a human can give — DRIVEN ON A REAL PTY (#111) -------
# Everything above stops at the no-TTY refusal, because confirm() branches on
# '[ -t 0 ]' and this suite has no terminal. So the interactive half — 'y',
# 'n', and Ctrl-D — had never been executed here at all, which is precisely
# how #111 survived: an unguarded 'read' returns non-zero on EOF, 'set -e'
# ends the run before the 'case', and the abort happens in total silence.
#
# 'script' from util-linux gives the child a pty, so box takes the interactive
# branch for real and reads the answer we write to the master side. This does
# NOT hang a suite run from a terminal: script's own stdin is a file or
# /dev/null on every run below, never the developer's tty, so the answer (or
# the EOF) is always already waiting.
if command -v script >/dev/null 2>&1 && script --version 2>/dev/null | grep -q util-linux; then
  PWORK="$(mktemp -d)"; PLOG="$PWORK/pty.log"
  printf 'y\n' > "$PWORK/yes"; printf 'n\n' > "$PWORK/no"
  # Invoked through a file so 'script -c' needs no quoting of its own; the log
  # path and the shim PATH ride the environment script hands to the child.
  cat > "$PWORK/run" <<RUNNER
#!/usr/bin/env bash
exec env PATH="$CSHIM:\$PATH" "$BOX" rm work
RUNNER
  chmod +x "$PWORK/run"
  ptybox() {  # ptybox <answers-file> — 'box rm work' on a pty, answered
    : > "$PLOG"
    FAKE_INCUS_LOG="$PLOG" script -qec "$PWORK/run" /dev/null < "$1"
  }
  # The load-bearing assertion is the MESSAGE, not the exit code: before the
  # fix Ctrl-D also exited 1, just without ever saying why. Asserting on the
  # code alone would pass against the bug.
  check "rm: Ctrl-D at the prompt aborts OUT LOUD, not in silence (#111)" \
    1 "aborted." ptybox /dev/null
  check "rm: ...and the Ctrl-D abort really deleted nothing (#111)" 1 "" \
    grep -qF 'incus delete' "$PLOG"
  check "rm: 'n' at the prompt aborts (#111)" 1 "aborted." ptybox "$PWORK/no"
  check "rm: ...and 'n' really deleted nothing (#111)" 1 "" \
    grep -qF 'incus delete' "$PLOG"
  # The accept path, so the pty rig is proven to be able to reach the work —
  # three checks that can only ever refuse would pass against a box that
  # refuses everything.
  check "rm: 'y' at the prompt goes through (#111)" 0 "removed work" \
    ptybox "$PWORK/yes"
  check "rm: ...and 'y' really reached 'incus delete -f' (#111)" 0 "" \
    grep -qF 'incus delete -f work' "$PLOG"
  rm -rf "$PWORK"
else
  echo "skip: the interactive confirm answers (no util-linux 'script' here; CI has it)"
fi

# --- the sweep: no prompt-shaped 'read' under 'set -e' may go unguarded (#111)
# The pty checks above prove the two 'bin/box' gates. This proves the CLASS,
# repo-wide, and it exists because the class is exactly what the first pass at
# #111 missed: 'host/revoke-user.sh' and 'host/teardown-host.sh' carried the
# identical defect and survived, because nothing here was looking for the shape.
#
# The shape: a 'read' at the start of a statement, fed from the script's own
# stdin (so a human, or an EOF), inside a file that turns on errexit. On EOF
# 'read' returns non-zero and 'set -e' ends the run BEFORE the 'case' that was
# going to name the abort — the tool goes mute at the moment it asked.
#
# What is deliberately NOT flagged, because it is not the shape:
#   · 'while IFS= read -r' loops — fed by a redirect at 'done', and a non-zero
#     read is how the loop is supposed to end;
#   · '<<<' herestring reads — fed from a string, never from a human;
#   · files without errexit ('drill/wipe.sh', 'drill/drill.sh',
#     'drill/multiuser.sh' run under 'set -u' only, wipe.sh documents why), where
#     EOF simply falls through to the '*)' arm and aborts out loud on its own.
# A guard is any '||' on the read's own line: '|| die', '|| reply=""',
# '|| { echo …; exit 1; }' — the spelling is each script's to choose, the
# guard is not.
eof_guard_sweep() {
  local f n line bad=0 files
  # dotglob alongside globstar for the same reason CI's shellcheck step carries
  # it (#116): globstar descends, but a glob does not MATCH a dot-prefixed name,
  # so this sweep skipped '.github/scripts/*.sh' — the release path — exactly as
  # the linter did. Those three set errexit, so they are in scope for this class
  # by construction; today none of them reads at all, which is why widening the
  # set is a no-op on current code rather than a bug fix.
  files="$(cd "$ROOT" && shopt -s globstar dotglob && printf '%s\n' bin/* ./**/*.sh | sed 's|^\./||' | sort -u)"
  while IFS= read -r f; do
    [ -f "$ROOT/$f" ] || continue
    grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e' "$ROOT/$f" || continue
    while IFS=: read -r n line; do
      case "$line" in
        *'<<<'*) continue ;;   # herestring, not a prompt
        *'||'*)  continue ;;   # guarded — the whole point
      esac
      echo "$f:$n: prompt-shaped 'read' under 'set -e' with no '||' guard:$line"
      bad=1
    done < <(grep -nE '^[[:space:]]*(IFS=[^[:space:]]+[[:space:]]+)?read([[:space:]]|$)' "$ROOT/$f")
  done <<<"$files"
  return "$bad"
}
check "no prompt-shaped 'read' under 'set -e' goes unguarded, repo-wide (#111)" \
  0 "" eof_guard_sweep

rm -rf "$CSHIM" "$CWORK"

# ---------------------------------------------------------------------------
# export / import (#70) — a box's state that survives the box and the host.
# Usage errors and the pure pre-incus refusals are DRIVEN; every daemon-gated
# invariant is grep-guarded or line-order-asserted (fail-closed: an empty
# grep is a FAIL, so a deleted guard cannot ship green).
# ---------------------------------------------------------------------------
check "export without a box exits 2"           2 "usage: box export" "$BOX" export
check "export of an unknown box exits 1"       1 "no such box"       "$BOX" export nosuchbox
check "import without a file exits 2"          2 "usage: box import" "$BOX" import
check "import of a missing file exits 1"       1 "no such file"      "$BOX" import /nope/nothing.tar.gz
check "import --name with no value exits 2"    2 "--name needs a value" "$BOX" import x.tar.gz --name
# A file that is not an export artifact is named as such, before any incus
# call — pure (tar + awk), so it is driven, not grepped.
NOTATARBALL="$(mktemp)"; echo "not a tarball" > "$NOTATARBALL"
check "import: a non-artifact file is refused" 1 "not an incus/box export" "$BOX" import "$NOTATARBALL"
rm -f "$NOTATARBALL"
check "help export names the credential risk"  0 "CREDENTIAL"        "$BOX" help export
check "help import names the re-stamping"      0 "user.box=1"        "$BOX" help import
# Export refuses a running box — require_stopped fires BEFORE incus export
# (line order inside cmd_export, fail-closed on either grep missing).
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "export: requires the box stopped, before exporting" 0 "" bash -c '
  fn="$(awk "/^cmd_export\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  guard="$(printf "%s\n" "$fn" | grep -n "require_stopped" | head -1 | cut -d: -f1)"
  run="$(printf "%s\n" "$fn" | grep -n "incus export" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] && [ -n "$run" ] && [ "$guard" -lt "$run" ]'
# Snapshots ride along by default; --instance-only is the explicit opt-out.
check "export: snapshots included unless --instance-only" 0 "" bash -c '
  awk "/^cmd_export\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q -- "--instance-only"'
# The credential SHOUT (#70's scrub-or-shout decision: box shouts).
check "export: shouts that the file is a credential" 0 "" bash -c '
  awk "/^cmd_export\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "treat the file itself as a credential"'
# Import re-stamps the boundary tag onto the current stack.
check "import: re-stamps user.box=1" 0 "" bash -c '
  awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "user.box=1"'
# The name-collision guard fires BEFORE incus import — the resolve_box
# boundary from the other side: never occupy an existing instance's name.
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "import: the collision guard precedes the import" 0 "" bash -c '
  fn="$(awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  guard="$(printf "%s\n" "$fn" | grep -n "already exists" | head -1 | cut -d: -f1)"
  run="$(printf "%s\n" "$fn" | grep -n "incus import" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] && [ -n "$run" ] && [ "$guard" -lt "$run" ]'
# Import lands on the placement contract: same pre-flight as a mint.
check "import: pre-flights the stack (require_stack)" 0 "" bash -c '
  awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "require_stack"'
# The artifact's MAC comes back verbatim, and a re-import beside a sibling
# collides at start (measured live: "MAC address already defined on another
# NIC") — the hwaddr unset must precede the start. Line order, fail-closed.
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "import: regenerates the NIC MAC before the start" 0 "" bash -c '
  fn="$(awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  mac="$(printf "%s\n" "$fn" | grep -n "hwaddr" | head -1 | cut -d: -f1)"
  start="$(printf "%s\n" "$fn" | grep -n "incus start" | head -1 | cut -d: -f1)"
  [ -n "$mac" ] && [ -n "$start" ] && [ "$mac" -lt "$start" ]'
# reset_identity runs AFTER the imported box is started — the clone trust
# boundary (machine-id → DHCP lease), line-order-asserted, fail-closed.
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "import: reset_identity follows the start" 0 "" bash -c '
  fn="$(awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  start="$(printf "%s\n" "$fn" | grep -n "incus start" | head -1 | cut -d: -f1)"
  reset="$(printf "%s\n" "$fn" | grep -n "reset_identity" | head -1 | cut -d: -f1)"
  [ -n "$start" ] && [ -n "$reset" ] && [ "$start" -lt "$reset" ]'
# The restricted tier can export: grant converges restricted.backups (the
# backup API is what 'incus export' rides; blocked by default — #70).
check "grant: allows backups (the export workflow)" 0 "" \
  grep -qF 'restricted.backups allow' "$ROOT/host/grant-user.sh"

# ---------------------------------------------------------------------------
# The mint stamp (#103) — DRIVEN on both halves, write and read.
#
# There is no host-side per-box store: the Incus instance config IS the
# database, so the only proof that a fact survives the mint is the argument
# list box hands 'incus launch'. A fake incus logs every call verbatim and
# answers just enough for cmd_new and cmd_info to run to completion with no
# daemon anywhere — the same trick the confirm-gate drive uses above.
#
# The read half matters as much as the write half, and legacy boxes most of
# all: every box minted before this stamp existed carries none of these keys,
# and a box outlives the release that minted it. 'incus config get' on an
# unset key prints EMPTY and exits 0 (audit B4), so "no stamp" and "daemon
# said no" arrive identically — 'box info' must render both as a box with
# blanks, never as an error.
# ---------------------------------------------------------------------------
MSHIM="$(mktemp -d)"; MWORK="$(mktemp -d)"
cat > "$MSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the mint-stamp drive. Knobs, all optional:
#   FAKE_BASE_IMAGE  what 'config get <i> volatile.base_image' resolves to;
#                    empty = incus does not know it (the degraded mint)
#   FAKE_CFG         a file of "<key> <value>" lines answering 'config get'
#   FAKE_ROW         the csv row 'list --columns nstS' returns
#   FAKE_TYPE        what 'list --columns t' returns — the instance type the
#                    #171 disk refusal branches on; empty = incus did not say
#   FAKE_SHOW        what 'config show <ref>' returns — the source's devices,
#                    which decide whether --disk can ride the copy (#171)
#   FAKE_SHOW_RC     the STATUS 'config show' exits with, default 0. Separate
#                    from FAKE_SHOW because the pair that matters is stdout
#                    that looks fine and a status that does not: a read box
#                    must not believe (#171 D2, review round 1)
#   FAKE_ROOT_SIZE   what 'config device get <i> root size' returns; empty =
#                    no per-instance root override (the container answer)
#   FAKE_SNAPS       the csv 'snapshot list <i>' returns for the COPIED
#                    instance — the two clone paths' one observable difference
#                    in what incus hands back (#266): copying an instance
#                    carries its snapshots, copying a snapshot carries none
# The launch carries a whole cloud-init seed, so the call is logged with its
# newlines flattened — an assertion about "the launch line" must see one line.
printf 'incus %s\n' "$*" | tr '\n' ' ' >> "$FAKE_INCUS_LOG"
printf '\n' >> "$FAKE_INCUS_LOG"
case "$*" in
  snapshot\ create\ *\ pristine)
    if [ "${FAKE_PRISTINE_FAIL:-0}" = 1 ]; then
      echo "incus: snapshot refused" >&2
      exit 1
    fi ;;
  *volatile.base_image) printf '%s\n' "${FAKE_BASE_IMAGE-}" ;;
  # Both 'config get <i> <key>' and its --expanded form (#171 reads what the
  # instance will RUN with, profiles included) — the key is the last word
  # either way, so one arm answers both.
  "config get "*)
    [ -n "${FAKE_CFG:-}" ] || exit 0
    key="$*"; key="${key##* }"
    awk -v k="$key" '$1 == k { $1 = ""; sub(/^ /, ""); print }' "$FAKE_CFG" ;;
  "snapshot list "*)     printf '%s' "${FAKE_SNAPS-}" ;;
  "config device get "*) printf '%s\n' "${FAKE_ROOT_SIZE-}" ;;
  "config show "*)       printf '%s\n' "${FAKE_SHOW-}"; exit "${FAKE_SHOW_RC:-0}" ;;
  *"--columns nstS") printf '%s\n' "${FAKE_ROW-}" ;;
  *"--columns t")    printf '%s\n' "${FAKE_TYPE-}" ;;
  *"--columns 4")    echo '10.1.2.3 (enp5s0)' ;;
esac
exit 0
SHIM
chmod +x "$MSHIM/incus"

export FAKE_BASE_IMAGE=deadbeefcafe0123456789   # what the alias resolves to
# The mint drive carries the same failing, logging shim curl the
# render_userdata drive does. It used to serve canned releases/latest redirects
# because a mint resolved a pin off the network (#150); since #214 a mint
# resolves nothing, so the shim's job inverted — every call is logged and every
# call fails, and $log.curl staying empty is how "a mint makes no network
# request" becomes an assertion instead of a claim.
# The one host fact box_id() reads (#181), made to fail on demand: a shim 'cat'
# that refuses ONLY the kernel's uuid file and execs the real one for every
# other path. A blanket refusal would break box_version() — which reads VERSION
# through cat — and fail the mint for a reason that is not the one under test.
# Prepended to PATH via SHIM_PREFIX, so the degraded runs share every other
# knob with the ordinary ones.
NOUUID="$(mktemp -d)"
cat > "$NOUUID/cat" <<'SHIM'
#!/usr/bin/env bash
[ "${1:-}" = /proc/sys/kernel/random/uuid ] && exit 1
for real in /bin/cat /usr/bin/cat; do [ -x "$real" ] && exec "$real" "$@"; done
exit 127
SHIM
chmod +x "$NOUUID/cat"

mintbox() {  # mintbox <logfile> <args...> — the real box, shimmed, no TTY
  local log="$1"; shift
  : > "$log"; : > "$log.curl"
  env FAKE_INCUS_LOG="$log" FAKE_CURL_LOG="$log.curl" \
      PATH="${SHIM_PREFIX:+$SHIM_PREFIX:}$MSHIM:$NETSHIM:$PATH" \
      "$BOX" "$@" </dev/null >"$log.out" 2>&1
  local rc=$?
  cat "$log.out"
  return "$rc"
}
# The launch line, isolated: every assertion below is about ONE incus call, and
# grepping the whole log would let a key stamped by some other call pass.
launchline() { grep -m1 '^incus launch ' "$1"; }
# launch_has/restamp_has <log> <ere> — a matcher per surface, so the ABSENCE
# assertions (a key that must not be stamped) are a plain non-zero exit rather
# than a nest of quoting.
launch_has()  { launchline "$1" | grep -qE "$2"; }
restamp_has() { grep -F 'config set' "$1" | grep -qE "$2"; }

# --- the write half: a fresh mint ------------------------------------------
MLOG="$MWORK/mint.log"
check "mint: a shimmed 'box new' runs to completion" 0 "ready" \
  mintbox "$MLOG" new --name w1 --user claude --container
# shellcheck disable=SC2016  # $1 expands in the child shell, by design.
check "mint: a fresh mint creates exactly one snapshot (#213)" 0 "1" \
  bash -c 'grep -c "^incus snapshot create " "$1"' _ "$MLOG"
check "mint: that sole automatic snapshot is pristine (#213)" 0 "" \
  grep -qE '^incus snapshot create w1 pristine *$' "$MLOG"

PRISTINE_OFF_LOG="$MWORK/pristine-off.log"
BOX_SNAPSHOT_PRISTINE=0 \
  mintbox "$PRISTINE_OFF_LOG" new --name pristine-off --container >/dev/null 2>&1
check "mint: BOX_SNAPSHOT_PRISTINE=0 still suppresses the sole mark (#213)" 1 "" \
  grep -q '^incus snapshot create ' "$PRISTINE_OFF_LOG"

RETIRED_KNOB_LOG="$MWORK/retired-knob.log"
BOX_SNAPSHOT_BOOTSTRAPPED=0 \
  mintbox "$RETIRED_KNOB_LOG" new --name retired-knob --container >/dev/null 2>&1
# shellcheck disable=SC2016  # $1 expands in the child shell, by design.
check "mint: the retired knob cannot change the one-pristine result (#213)" 0 "1" \
  bash -c 'grep -c "^incus snapshot create .* pristine *$" "$1"' _ "$RETIRED_KNOB_LOG"

PRISTINE_FAIL_LOG="$MWORK/pristine-fail.log"
pristine_failure_mint() {
  FAKE_PRISTINE_FAIL=1 \
    mintbox "$PRISTINE_FAIL_LOG" new --name pristine-fail --container
}
check "mint: a refused pristine snapshot still leaves the mint successful (#104, #213)" 0 "ready" \
  pristine_failure_mint
check "mint: the refused pristine snapshot remains a loud warning (#104, #213)" 0 "WARNING" \
  pristine_failure_mint
# Each key on its own check: a single grep for the whole block would go green
# on a partial stamp, and "which fact was dropped" is the useful failure.
check "mint: stamps the schema — the stamp's SHAPE, not the box version (#103)" \
  0 "user.box.schema=1" launchline "$MLOG"
# Still 1 AFTER #214 removed three stamped keys, and that is a decision rather
# than an oversight — so it is pinned here with its reasoning, or the next
# remover re-argues it from the constant's comment alone. 'user.box.role',
# 'user.box.rig.repo' and 'user.box.rig.ref' are gone, and what survives is a
# strict SUBSET every older reader can still read: a 0.9.x 'box info' on a
# 0.10.0 box prints no RIG row, exactly as it would for a key that was never
# set. Bumping to 2 would have fired "stamp schema '2' is newer than this box
# reads" on every newly minted box, warning every operator about nothing. The
# rule that DOES bump is repurposing a key, or a removal that leaves a survivor
# unreadable; bin/box's comment now states all three cases.
# The three retired keys are asserted absent by their own block below; what is
# asserted HERE is that their removal did not move the schema.
check "mint: ...and #214's key REMOVAL did not bump it — a subset is not a new shape" \
  1 "" launch_has "$MLOG" 'user\.box\.schema=[^1]'
check "stamp schema: bin/box's rule names the removal case its first wording got wrong (#214)" \
  0 "" grep -qE '^# .*strict SUBSET of the old shape' "$ROOT/bin/box"
check "mint: stamps the box version that minted it (#103)" \
  0 "user.box.version=$(cat "$ROOT/VERSION")" launchline "$MLOG"
check "mint: stamps the base image ALIAS asked for (#103)" \
  0 "user.box.image=images:debian/13/cloud" launchline "$MLOG"
check "mint: stamps the mode it minted as (#103)" \
  0 "user.box.mode=container" launchline "$MLOG"
# The demand, not just the outcome: TYPE already says CT afterwards, but only
# the mint knew whether a container was ASKED for or fallen back into.
check "mint: stamps the mode that was ASKED, not only the outcome (#103)" \
  0 "user.box.mode.asked=container" launchline "$MLOG"
# The three RETIRED keys, asserted by their absence (#214). They are the whole
# of what the cut removed from the stamp, and an absence assertion is the only
# shape that catches one creeping back: a positive test for the six survivors
# would stay green beside a fourth key nobody wanted.
check "mint: stamps NO tenant role (#214)" 1 "" \
  launch_has "$MLOG" 'user\.box\.role='
check "mint: stamps NO converger repo (#214)" 1 "" \
  launch_has "$MLOG" 'user\.box\.rig\.repo='
check "mint: stamps NO converger ref (#214)" 1 "" \
  launch_has "$MLOG" 'user\.box\.rig\.ref='
check "mint: execs no converger in the guest (#214)" 1 "" \
  grep -q '^incus exec .* bootstrap' "$MLOG"
check "mint: the default path takes the small cpu row (#159)" 0 "" \
  launch_has "$MLOG" 'limits\.cpu=2'
check "mint: the default path takes the small memory row (#159)" 0 "" \
  launch_has "$MLOG" 'limits\.memory=2GiB'
check "mint: --user reaches cloud-init (#159, #214)" 0 "" \
  launch_has "$MLOG" 'name: "claude"'
check "mint: --user reaches the stamp (#159, #214)" 0 "" \
  launch_has "$MLOG" 'user\.box\.user=claude'
# THE OFFLINE PROOF, at the mint rather than at the renderer (#214). A mint of
# a pin-bearing seed used to make a HEAD request and DIE if it failed; the shim
# curl fails every call, so a surviving probe would both log a line and take
# the mint down with it.
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "mint: makes NO network request of its own (#214)" 0 "0" \
  bash -c 'grep -c . "$1" || true' _ "$MLOG.curl"
check "mint: stamps the origin (#103)" 0 "user.box.origin=mint" launchline "$MLOG"
# THE PLACEMENT CONTRACT, DRIVEN AT THE MINT (#229). Everything else that holds
# 'box new' to 'box-profile' is a text search: the corpus guard reds on a stray
# old name anywhere, and the drill catches it on metal once a release. Neither
# watches the flag this call actually launches with, which is the one line the
# whole rename exists to move — so a mint launching onto a profile the host no
# longer has would ship green. The negative is its pair: the flag must not name
# the old profile, and an assertion that only looked for the new name would stay
# green beside a second --profile that re-introduced it.
check "mint: launches ON the box-profile profile — the placement contract (#229)" 0 "" \
  launch_has "$MLOG" ' --profile box-profile( |$)'
check "mint: ...and the launch names the old profile nowhere (#229)" 1 "" \
  launch_has "$MLOG" 'box-net'
# The six keys that SURVIVED, named together: the absence block above says what
# went, and this says what must not have gone with it.
for k in schema version image mode created origin; do
  check "mint: still stamps user.box.$k (#103, #214)" 0 "" \
    launch_has "$MLOG" "user\.box\.$k="
done

# The one surviving dedicated template must keep the values load_template
# read from its seed. Runtime role/user variables are empty on this path, so
# this drive catches any later assignment that erases staging's identity and
# silently skips convergence (#159 review round 1).
STAGINGLOG="$MWORK/staging-template.log"
mintbox "$STAGINGLOG" new --name staging --template staging-box --vm >/dev/null 2>&1
check "mint staging: keeps the seed user stamp (#159)" 0 "" \
  launch_has "$STAGINGLOG" 'user\.box\.user=ops'
check "mint staging: keeps the server autostart demand (#68, #159)" 0 "" \
  launch_has "$STAGINGLOG" 'boot\.autostart=true'
check "mint staging: launches as a VM (#68, #159)" 0 "" \
  launch_has "$STAGINGLOG" ' --vm '
check "mint staging: keeps its 60GiB VM root device (#68, #159)" 0 "" \
  launch_has "$STAGINGLOG" 'root,size=60GiB'
check "mint staging: disables VM secure boot (#159)" 0 "" \
  launch_has "$STAGINGLOG" 'security\.secureboot=false'
# The dedicated seed converges NOTHING at mint (#214) — the whole server
# posture is operator-run now, exactly as its tailnet join always was.
check "mint staging: execs no converger of its own (#214)" 1 "" \
  grep -qE '^incus exec staging .* bootstrap' "$STAGINGLOG"
check "mint staging: renders no installer line into its seed (#214)" 1 "" \
  launch_has "$STAGINGLOG" 'install\.sh'
check "mint staging: keeps the ops sudo line in the rendered seed (#214)" 0 "" \
  launch_has "$STAGINGLOG" 'NOPASSWD:ALL'
# The retired keys are absent HERE too: staging-box was the one seed that
# actually declared BOX_BOOTSTRAP_ROLE, so it is the one whose stamp would
# still carry a role if the cut had been made only on the tenant path.
check "mint staging: stamps no tenant role either (#214)" 1 "" \
  launch_has "$STAGINGLOG" 'user\.box\.role='
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "mint staging: makes no network request either (#214)" 0 "0" \
  bash -c 'grep -c . "$1" || true' _ "$STAGINGLOG.curl"

# The public size table and its two higher precedence rungs, driven through a
# real shimmed mint. VM mode makes the disk device visible on the launch argv.
MEDIUMLOG="$MWORK/medium-size.log"
mintbox "$MEDIUMLOG" new --name medium --size medium --vm >/dev/null 2>&1
check "mint size: medium resolves to 4 cpu (#159)" 0 "" \
  launch_has "$MEDIUMLOG" 'limits\.cpu=4'
check "mint size: medium resolves to 8GiB memory (#159)" 0 "" \
  launch_has "$MEDIUMLOG" 'limits\.memory=8GiB'
check "mint size: medium resolves to a 60GiB disk (#159)" 0 "" \
  launch_has "$MEDIUMLOG" 'root,size=60GiB'
LARGELOG="$MWORK/large-size.log"
mintbox "$LARGELOG" new --name large --size large --vm >/dev/null 2>&1
check "mint size: large resolves to 8 cpu (#159)" 0 "" \
  launch_has "$LARGELOG" 'limits\.cpu=8'
check "mint size: large resolves to 16GiB memory (#159)" 0 "" \
  launch_has "$LARGELOG" 'limits\.memory=16GiB'
check "mint size: large resolves to a 120GiB disk (#159)" 0 "" \
  launch_has "$LARGELOG" 'root,size=120GiB'
FLAGBEATS="$MWORK/flag-beats-size.log"
mintbox "$FLAGBEATS" new --name flagbeats \
  --size medium --cpu 2 --container >/dev/null 2>&1
check "mint size: --cpu beats --size medium (#159)" 0 "" \
  launch_has "$FLAGBEATS" 'limits\.cpu=2'
ENVBEATS="$MWORK/env-beats-size.log"
BOX_CPU=1 mintbox "$ENVBEATS" new --name envbeats \
  --size medium --container >/dev/null 2>&1
check "mint size: BOX_CPU beats --size medium (#159)" 0 "" \
  launch_has "$ENVBEATS" 'limits\.cpu=1'

# --user rides the ordinary mint on its own (#214 D2): the tenant user was
# never the role's to derive, so removing the role removes nothing from it.
USERLOG="$MWORK/user-override.log"
mintbox "$USERLOG" new --name ada --user ada --container >/dev/null 2>&1
check "mint: --user reaches the instance stamp with no role at all (#214)" 0 "" \
  launch_has "$USERLOG" 'user\.box\.user=ada'
check "mint: --user reaches cloud-init with no role at all (#214)" 0 "" \
  launch_has "$USERLOG" 'name: "ada"'
check "mint: an unnamed user still defaults to dev (#214)" 0 "" \
  launch_has "$MEDIUMLOG" 'user\.box\.user=dev'
# The pin environment is INERT at the mint, not merely at the renderer: box
# reads neither variable, so neither reaches the seed, the stamp or the network.
PINENVLOG="$MWORK/pin-env.log"
RIG_REPO=you/rig RIG_REF=0.3.0 \
  mintbox "$PINENVLOG" new --name pinned --container >/dev/null 2>&1
check "mint: a set pin changes nothing about the seed (#214)" 1 "" \
  launch_has "$PINENVLOG" 'you/rig|0\.3\.0'
check "mint: a set pin stamps nothing (#214)" 1 "" \
  launch_has "$PINENVLOG" 'user\.box\.rig'
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "mint: a set pin probes nothing (#214)" 0 "0" \
  bash -c 'grep -c . "$1" || true' _ "$PINENVLOG.curl"
check "mint: a set pin warns about nothing (#214)" 1 "" \
  grep -qiE 'RIG_RE(PO|F)' "$PINENVLOG.out"

# --- the identity (#181) ----------------------------------------------------
# The SHAPE, not merely the presence: a hostname, the box's own name or a
# counter would all satisfy a bare "is set", and none of them is stable across
# the rename this key exists for. The assertion is stricter than box_id()'s own
# parser on purpose — the parser accepts any well-formed UUID because its job
# is to refuse garbage, while what the kernel actually hands out is a v4, and
# a source that quietly stopped being one is worth a red.
check "mint: stamps a stable identity — a v4 UUID (#181)" 0 "" \
  launch_has "$MLOG" 'user\.box\.id=[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
# Drawn on the HOST, and the function that draws it never speaks to a guest.
# That is the whole argument against /etc/machine-id: a guest-side identity is
# unreadable while the box is stopped, absent until first boot, and writable by
# the agents the box runs.
check "mint: the id comes from the host kernel (#181)" 0 "" \
  grep -qF '/proc/sys/kernel/random/uuid' "$ROOT/bin/box"
box_id_never_asks_the_guest() {
  ! awk '/^box_id\(\) \{/,/^\}/' "$ROOT/bin/box" | grep -q 'incus'
}
check "mint: ...and box_id() never asks the box for it (#181)" 0 "" \
  box_id_never_asks_the_guest
# An id every box shares is not an identity. Two mints, two ids.
MLOG2="$MWORK/mint2.log"
check "mint: a second mint runs to completion" 0 "ready" \
  mintbox "$MLOG2" new --name w1b --user claude --container
stamped_id() { launchline "$1" | grep -oE 'user\.box\.id=[0-9a-f-]+' | head -1 | cut -d= -f2; }
mint_ids_differ() {
  local a b; a="$(stamped_id "$1")"; b="$(stamped_id "$2")"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]
}
check "mint: two boxes minted on one host get DIFFERENT ids (#181)" 0 "" \
  mint_ids_differ "$MLOG" "$MLOG2"
# A host that cannot answer gets no id — never a dead mint over a metadata
# key, and never an empty 'user.box.id=' that a config grep would find. This is
# the same absence every box minted before #181 carries, and every reader
# already tolerates it.
export SHIM_PREFIX="$NOUUID"
NOIDLOG="$MWORK/noid.log"
check "mint: a host with no UUID source still mints (#181)" 0 "ready" \
  mintbox "$NOIDLOG" new --name w7 --container
check "mint: ...and says out loud that this box has no stable id (#181)" 0 "no stable id" \
  mintbox "$NOIDLOG" new --name w7 --container
check "mint: ...stamping no id at all, rather than an empty key (#181)" 1 "" \
  launch_has "$NOIDLOG" 'user\.box\.id'
unset SHIM_PREFIX
# The timestamp's SHAPE, so a local-time or seconds-since-epoch spelling fails
# here: UTC ISO 8601, which is the only form that sorts and travels.
check "mint: stamps the mint time as UTC ISO 8601 (#103)" 0 "" \
  launch_has "$MLOG" 'user\.box\.created=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
# The existing three keys are UNTOUCHED — the stamp extends the namespace, it
# does not rewrite it, and box_user()/the login hint read two of them.
check "mint: the pre-existing boundary tag still rides the same line" \
  0 "user.box=1" launchline "$MLOG"
check "mint: stamps the internal tenant seed every mint renders (#159, #214)" \
  0 "user.box.template=tenant" launchline "$MLOG"
check "mint: the pre-existing user stamp is untouched" \
  0 "user.box.user=claude" launchline "$MLOG"
# Deliberately NOT stamped. limits.* already hold cpu/memory and a duplicate
# drifts the first time someone edits a limit by hand; a container's disk does
# not exist (its root rides the pool); and the tier is a fact about whoever is
# ASKING. Absence assertions, so a well-meant addition has to argue here first.
check "mint: does NOT duplicate cpu into the user.box namespace (#103)" 1 "" \
  launch_has "$MLOG" 'user\.box\.cpu'
check "mint: does NOT duplicate memory into the user.box namespace (#103)" 1 "" \
  launch_has "$MLOG" 'user\.box\.memory'
check "mint: does NOT stamp a disk — a container's does not exist (#103)" 1 "" \
  launch_has "$MLOG" 'user\.box\.disk'
check "mint: does NOT stamp the tier — it describes the asker, not the box (#103)" 1 "" \
  launch_has "$MLOG" 'user\.box\.tier'

# --- the resolved fingerprint: the alias is not a reproducible fact ---------
# $T_IMAGE is an unpinned alias on a moving remote. Incus resolves it during
# the launch and records what it landed on; box reads that back and pins it.
check "mint: pins the RESOLVED image fingerprint after the launch (#103)" 0 "" \
  grep -qF "config set w1 user.box.image.fingerprint=$FAKE_BASE_IMAGE" "$MLOG"
check "mint: ...and it is a SECOND call, not something the launch could know" 1 "" \
  launch_has "$MLOG" 'image\.fingerprint'
# The load-bearing half of that design: a box that exists and boots must never
# be failed over a provenance field. With no fingerprint to be had, the mint
# still succeeds and the alias stands alone as the honest partial answer.
NOFP="$MWORK/nofp.log"
FAKE_BASE_IMAGE=""   # exported above; incus does not know what the alias resolved to
check "mint: an unknowable fingerprint does not fail the mint (#103)" 0 "ready" \
  mintbox "$NOFP" new --name w4 --container
check "mint: ...and it stamped no empty fingerprint key either (#103)" 1 "" \
  grep -q 'image.fingerprint' "$NOFP"
FAKE_BASE_IMAGE=deadbeefcafe0123456789

# --- one seed, one shape, no pin --------------------------------------------
# The #159 ruling kept a pin in both of the seed's shapes and made only the
# auto-run conditional. #214 removed both the pin and the second shape, so what
# used to be asserted here — the stamped repo, the stamped resolved ref, the
# one-probe-per-mint count — has no subject. The argumentless mint is now the
# ONLY mint, and its stamp carries none of the three retired keys.
check "mint: an argumentless mint stamps no converger repo (#214)" 1 "" \
  launch_has "$NOFP" 'user\.box\.rig\.repo'
check "mint: an argumentless mint stamps no converger ref (#214)" 1 "" \
  launch_has "$NOFP" 'user\.box\.rig\.ref'
check "mint: ...and no role either (#103, #214)" 1 "" \
  launch_has "$NOFP" 'user\.box\.role'
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "mint: an argumentless mint probes nothing at all (#214)" 0 "0" \
  bash -c 'grep -c . "$1" || true' _ "$NOFP.curl"
# The seed it shipped carries no installer line either — the stamp and the
# payload are two different surfaces, and the cut had to reach both.
check "mint: ...and the seed it shipped installs nothing (#214)" 1 "" \
  launch_has "$NOFP" 'install\.sh'
# THE MINT WITH NO NETWORK, end to end (#214). This is the single clearest
# proof the pin is gone: with the shim curl failing every call, a mint that
# still resolved a pin would die where this one succeeds. It deserves its own
# case rather than riding an assertion about a stamp.
OFFLINE="$MWORK/offline.log"
check "mint: a mint with the network down still succeeds (#214)" 0 "ready" \
  mintbox "$OFFLINE" new --name offline --container
check "mint: ...having launched a box, not died before the launch (#214)" 0 "" \
  grep -q '^incus launch ' "$OFFLINE"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "mint: ...and having asked the network nothing (#214)" 0 "0" \
  bash -c 'grep -c . "$1" || true' _ "$OFFLINE.curl"

# --- the clone: the sharpest edge of the whole stamp ------------------------
# 'incus copy' carries every user.* key forward (audit B2) — which is what
# makes a clone know its template for free, and is exactly why the stamp
# cannot ride along untouched. An inherited stamp does not go stale, it goes
# FALSE: the clone would claim a mint time it was not present for, by a box
# version that never saw it.
CLONELOG="$MWORK/clone.log"
check "clone: a shimmed 'box new --from' runs to completion" 0 "cloned" \
  mintbox "$CLONELOG" new --name w2 --from work/authed
check "clone: re-stamps the origin as a clone, not a mint (#103)" 0 "" \
  grep -qF 'user.box.origin=clone' "$CLONELOG"
check "clone: names the source it was taken from — one hop (#103)" 0 "" \
  grep -qF 'user.box.origin.from=work/authed' "$CLONELOG"
check "clone: re-stamps the box version that made THIS instance (#103)" 0 "" \
  grep -qF "user.box.version=$(cat "$ROOT/VERSION")" "$CLONELOG"
check "clone: re-stamps a fresh created time (#103)" 0 "" \
  grep -qE 'user\.box\.created=[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$CLONELOG"
# The other half of the decision, and the reason it is a decision at all: the
# LINEAGE keys are left alone on purpose. The clone's disk genuinely came from
# that image, that template and that user — re-stamping them from the
# cloning process's own template lookup would be the actual lie, and would
# break the login hint that reads user.box.template off the instance.
check "clone: does NOT re-stamp the template — it is inherited lineage (#103)" 1 "" \
  restamp_has "$CLONELOG" 'user\.box\.template'
check "clone: does NOT re-stamp the user — box_user() reads the source's (#103)" 1 "" \
  restamp_has "$CLONELOG" 'user\.box\.user'
check "clone: does NOT re-stamp the image — the disk really came from it (#103)" 1 "" \
  restamp_has "$CLONELOG" 'user\.box\.image'
# A pre-#214 source still carries user.box.role and user.box.rig.*; the clone
# neither re-stamps nor strips them. They are not box's keys any more, and an
# artifact of a mint that happened is not a thing to bring up to date.
check "clone: does NOT re-stamp a retired role key (#103, #214)" 1 "" \
  restamp_has "$CLONELOG" 'user\.box\.role'
# The third column, and the one review found: 'mode.asked' is neither lineage
# nor re-stampable. It is a mint-event fact whose asker was the SOURCE's
# operator, and a clone refuses --vm/--container, so nobody was asked anything
# here. It is CLEARED — there is no true value to give it.
check "clone: clears the inherited mode.asked — nobody asked THIS box (#103)" 0 "" \
  grep -qF 'config unset w2 user.box.mode.asked' "$CLONELOG"
check "clone: ...and does not re-stamp it with a fabricated answer (#103)" 1 "" \
  restamp_has "$CLONELOG" 'user\.box\.mode\.asked'
# Cleared, never set-to-empty: an empty value is still a key on the instance.
check "clone: clears it rather than setting it empty (#103)" 1 "" \
  grep -qE 'config set .*user\.box\.mode\.asked=($|[[:space:]])' "$CLONELOG"
# Order: the re-stamp lands on the copied instance BEFORE it is started, so a
# clone is never observable wearing its source's provenance. Fail-closed — an
# absent line makes the arithmetic fail, not pass.
restamp_precedes_start() {
  local set start
  set="$(grep -n 'config set .* user.box.origin=clone' "$1" | head -1 | cut -d: -f1)"
  start="$(grep -n '^incus start ' "$1" | head -1 | cut -d: -f1)"
  [ -n "$set" ] && [ -n "$start" ] && [ "$set" -lt "$start" ]
}
check "clone: the re-stamp precedes the start (#103)" 0 "" \
  restamp_precedes_start "$CLONELOG"
# The clear rides the same rule for the same reason: a clone must never be
# observable — not for one moment, not to 'box info' — wearing an 'asked' its
# operator never gave. Fail-closed the same way.
clear_precedes_start() {
  local unset_ln start
  unset_ln="$(grep -n 'config unset .* user.box.mode.asked' "$1" | head -1 | cut -d: -f1)"
  start="$(grep -n '^incus start ' "$1" | head -1 | cut -d: -f1)"
  [ -n "$unset_ln" ] && [ -n "$start" ] && [ "$unset_ln" -lt "$start" ]
}
check "clone: the mode.asked clear precedes the start too (#103)" 0 "" \
  clear_precedes_start "$CLONELOG"

# The identity is the sharpest case of the sharpest edge (#181). Every OTHER
# inherited key is either lineage that stays true or a fact box re-stamps;
# an inherited id is a clone asserting it IS its source, to every reader that
# trusts the id to mean one box.
check "clone: re-stamps a fresh id — a clone is a different box (#181)" 0 "" \
  restamp_has "$CLONELOG" 'user\.box\.id=[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
restamp_id() { grep -F 'config set' "$1" | grep -oE 'user\.box\.id=[0-9a-f-]+' | head -1 | cut -d= -f2; }
clone_id_is_its_own() {
  local c m; c="$(restamp_id "$CLONELOG")"; m="$(stamped_id "$MLOG")"
  [ -n "$c" ] && [ "$c" != "$m" ]
}
check "clone: ...and not a constant this build hands every box (#181)" 0 "" \
  clone_id_is_its_own
# It rides the SAME 'config set' as origin=clone, so the ordering assertion
# above covers it: the clone is never observable, not for a moment, wearing
# its source's identity.
check "clone: the id lands on the same pre-start re-stamp as the origin (#181)" 0 "" \
  restamp_precedes_start "$CLONELOG"
# The degraded clone is the one case where doing nothing is wrong. No id can be
# drawn, and 'incus copy' has already carried the source's in — so it is UNSET,
# the same call mode.asked gets, for a stronger reason: a false identity is
# worse than none.
export SHIM_PREFIX="$NOUUID"
NOIDCLONE="$MWORK/noid-clone.log"
check "clone: a host with no UUID source still clones (#181)" 0 "cloned" \
  mintbox "$NOIDCLONE" new --name w8 --from work/authed
check "clone: ...and UNSETS the id it inherited from the source (#181)" 0 "" \
  grep -qF 'config unset w8 user.box.id' "$NOIDCLONE"
check "clone: ...rather than letting it claim to BE its source (#181)" 1 "" \
  restamp_has "$NOIDCLONE" 'user\.box\.id'
check "clone: ...and says out loud that this clone has no stable id (#181)" 0 "no stable id" \
  mintbox "$NOIDCLONE" new --name w8 --from work/authed
# Before the start, like every other identity write on this path. Fail-closed:
# an absent line makes the arithmetic fail, not pass.
id_unset_precedes_start() {
  local u s
  u="$(grep -n 'config unset .* user.box.id' "$1" | head -1 | cut -d: -f1)"
  s="$(grep -n '^incus start ' "$1" | head -1 | cut -d: -f1)"
  [ -n "$u" ] && [ -n "$s" ] && [ "$u" -lt "$s" ]
}
check "clone: the inherited-id clear precedes the start (#181)" 0 "" \
  id_unset_precedes_start "$NOIDCLONE"
unset SHIM_PREFIX
# ...and the ordinary clone does NOT unset it: it was re-stamped, and an unset
# landing after the set would leave the clone with no identity at all.
check "clone: an ordinary clone never unsets the id it just re-stamped (#181)" 1 "" \
  grep -qE 'config unset .* user\.box\.id' "$CLONELOG"

# --- a clone's SIZING: the flags that ride the copy, and the silent case ----
# Two halves of one defect (#171). The flags were refused on --from on #57's
# premise that honouring them meant a post-hoc resize; they do not — 'incus
# copy' takes -c/-d and the root override is applied before the volume is
# created, so nothing is ever resized. And the refusal only ever fired if the
# flags were PASSED: drop them and the box came up sized by its source or its
# template with nothing saying what that size was — true of the fresh mint as
# much as the clone, which is why D6 narrates both.
#
# What box prints is DRIVEN, never matched. The issue's own proposed message
# read 'box incus <box> -- config set limits.cpu 2', which cmd_incus turns
# into 'incus config set limits.cpu 2 <inst>' — the instance in the value's
# place, because it is appended when no {} appears. A text assertion would
# have shipped that verbatim.
#
# A source with its own root device, which is what box's VM mints produce.
LOCALROOT="$MWORK/localroot.yaml"
cat > "$LOCALROOT" <<'YAML'
architecture: x86_64
config:
  limits.cpu: "4"
  limits.memory: 8GiB
devices:
  root:
    path: /
    pool: default
    size: 60GiB
    type: disk
name: work
YAML
# ...and one whose root comes from the profile: the case copy.go cannot serve.
PROFROOT="$MWORK/profroot.yaml"
cat > "$PROFROOT" <<'YAML'
architecture: x86_64
config:
  limits.cpu: "4"
devices:
  eth0:
    name: eth0
    type: nic
name: work
YAML

copyline() { grep -m1 '^incus copy ' "$1"; }
SIZELOG="$MWORK/size.log"
FAKE_SHOW="$(cat "$LOCALROOT")"; export FAKE_SHOW
check "clone sizing: --from WITH the size flags now mints (#171 D1)" 0 "cloned" \
  mintbox "$SIZELOG" new --name w9 --from work --cpu 2 --memory 4GiB --disk 20GiB
# The whole mechanism on one line: the override rides the copy, so the volume
# is created at the size asked for. A second call fixing it up afterwards would
# be the post-hoc resize #57 ruled out, and is not this.
check "clone sizing: the cpu override rides the copy (#171 D1)" 0 "-c limits.cpu=2" \
  copyline "$SIZELOG"
check "clone sizing: the memory override rides the copy (#171 D1)" 0 "-c limits.memory=4GiB" \
  copyline "$SIZELOG"
check "clone sizing: the root size rides it as a DEVICE override (#171 D1)" \
  0 "-d root,size=20GiB" copyline "$SIZELOG"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "clone sizing: ...in ONE copy call, not a copy and a fix-up (#171 D1)" 0 "1" \
  bash -c 'grep -c "^incus copy " "$1"' _ "$SIZELOG"
check "clone sizing: ...and nothing resizes it afterwards (#57, #171 D1)" 1 "" \
  restamp_has "$SIZELOG" 'limits\.'
# -s beside -d root,size= silently DROPS the sizing: applyStoragePool's
# fallback rebuilds the root device as {type, path, pool} and discards the
# size. box passes no pool flag today and this is what stops one arriving.
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "clone sizing: the copy argv never carries -s/--storage (#171 D2)" 1 "" \
  bash -c 'grep -m1 "^incus copy " "$1" | grep -qE " (-s|--storage) "' _ "$SIZELOG"
# Only a flag actually passed contributes an argument.
SIZELOG2="$MWORK/size-cpu.log"
check "clone sizing: one flag, one override (#171 D1)" 0 "cloned" \
  mintbox "$SIZELOG2" new --name w9 --from work --cpu 2
check "clone sizing: ...the cpu override is there (#171 D1)" 0 "-c limits.cpu=2" \
  copyline "$SIZELOG2"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "clone sizing: ...and no memory the caller never asked for (#171 D1)" 1 "" \
  bash -c 'grep -m1 "^incus copy " "$1" | grep -qF "limits.memory"' _ "$SIZELOG2"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "clone sizing: ...and no root device the caller never asked for (#171 D1)" 1 "" \
  bash -c 'grep -m1 "^incus copy " "$1" | grep -qF "root,size"' _ "$SIZELOG2"
# A plain clone is untouched by all of it: no flags, no overrides.
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "clone sizing: a flagless clone passes no overrides at all (#171 D1)" 1 "" \
  bash -c 'grep -m1 "^incus copy " "$1" | grep -qE " -[cd] "' _ "$CLONELOG"

# The pre-flight (D2). incus's copy.go does not merge a -d override onto a
# profile-inherited device the way create.go does — it installs the override AS
# the device, so a profile-rooted source would be copied with a root of 'size'
# and nothing else: no type, no path, not a root disk at all.
check "clone sizing: box reads the source's OWN devices (#171 D2)" 0 "" \
  grep -qE '^incus config show work *$' "$SIZELOG"
check "clone sizing: ...never --expanded, which folds the profile back in (#171 D2)" 1 "" \
  grep -qF 'config show --expanded' "$SIZELOG"
# D3: die BEFORE the copy. Not a warning-and-proceed — the caller asked for a
# 20GiB clone, and handing them the source's size with a note beside it is the
# silent wrong-sizing this issue opened on.
SIZELOG3="$MWORK/size-profroot.log"
FAKE_SHOW="$(cat "$PROFROOT")"; export FAKE_SHOW
check "clone sizing: a profile-rooted VM source DIES, exit 1 (#171 D3)" \
  1 "no root device of its own" \
  mintbox "$SIZELOG3" new --name w9 --from work --cpu 2 --disk 20GiB
# Asserted on the shim's record, not on the message: a message that says
# nothing was created, while the copy ran, is the failure mode #160 named.
check "clone sizing: ...and NO copy ran at all (#171 D3)" 1 "" \
  grep -q '^incus copy ' "$SIZELOG3"
check "clone sizing: ...it says nothing was created (#171 D3)" \
  0 "NOTHING WAS CREATED" cat "$SIZELOG3.out"
check "clone sizing: ...and that --cpu/--memory went nowhere either (#171 D3)" \
  0 "were not applied" cat "$SIZELOG3.out"
check "clone sizing: ...names the condition it refused on (#171 D3)" \
  0 "comes from a profile" cat "$SIZELOG3.out"
check "clone sizing: ...and offers the two measured routes (#171 D3)" \
  0 "drop --disk" cat "$SIZELOG3.out"
check "clone sizing: ...the second being a fresh mint (#171 D3)" \
  0 "mint fresh with --disk" cat "$SIZELOG3.out"
# The house rule, asserted the way #160's wall asserts it: ANCHORED. A line
# that begins 'incus ' or 'box ' reads as a command to run, and the verb that
# would fix the source is triage's inference off the copy.go divergence — a
# route nobody here has watched work. Naming a mechanism mid-sentence is fine;
# the anchor is exactly what draws that line.
no_command_lines() {   # no_command_lines <output-file>
  ! sed 's/^box: *//' "$1" | grep -qE '^(incus|box) '
}
check "clone sizing: the refusal prints NO runnable line, anchored (#171 D3)" 0 "" \
  no_command_lines "$SIZELOG3.out"
# ...and specifically not the override verb, which is the one it must not hand
# out however it is phrased.
check "clone sizing: ...and never the unwatched override verb (#171 D3)" 1 "" \
  grep -qF 'config device override' "$SIZELOG3.out"
# Not forceable, unlike #160's wall: --force cannot buy a device that is not a
# root disk, so there is no door through this one.
SIZELOG4="$MWORK/size-forced.log"
check "clone sizing: --force does NOT buy past it (#171 D3)" \
  1 "no root device of its own" \
  mintbox "$SIZELOG4" new --name w9 --from work --disk 20GiB --force
check "clone sizing: ...and forced or not, no copy ran (#171 D3)" 1 "" \
  grep -q '^incus copy ' "$SIZELOG4"
# D4: container mode keeps the answer it has had since #57 — note, no -d, and
# the copy PROCEEDS. The difference from D3 is principled: here the flag is
# categorically inapplicable, there it is merely unservable for this source.
SIZELOG5="$MWORK/size-ct.log"
export FAKE_TYPE=CONTAINER
check "clone sizing: a container source fires the note and CLONES (#171 D4)" \
  0 "--disk applies to VM mode only" \
  mintbox "$SIZELOG5" new --name w9 --from work --cpu 2 --disk 20GiB
check "clone sizing: ...the copy really ran (#171 D4)" 0 "" \
  grep -q '^incus copy ' "$SIZELOG5"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "clone sizing: ...carrying no -d, because there is no size to set (#171 D4)" 1 "" \
  bash -c 'grep -m1 "^incus copy " "$1" | grep -qF "root,size"' _ "$SIZELOG5"
check "clone sizing: ...while --cpu still rides it (#171 D4)" 0 "-c limits.cpu=2" \
  copyline "$SIZELOG5"
unset FAKE_TYPE
# Fail CLOSED on an unreadable source: no answer is not a yes. A false negative
# costs a refusal and a rerun; a false positive writes a non-root-disk device
# onto a fresh clone.
SIZELOG6="$MWORK/size-blind.log"
export FAKE_SHOW=""
check "clone sizing: an unreadable source refuses rather than guessing (#171 D2)" \
  1 "could not be read" \
  mintbox "$SIZELOG6" new --name w9 --from work --disk 20GiB
check "clone sizing: ...and no copy ran on the blind read either (#171 D2)" 1 "" \
  grep -q '^incus copy ' "$SIZELOG6"
# The one the pre-flight is FOR, and the one an earlier cut of this branch got
# wrong: stdout that parses as a local root device, and a STATUS that says the
# read failed. 'config show || true' discards the status and then believes the
# bytes — which attaches -d root,size= to a copy from a source box never
# actually read, the exact false positive D2 exists to prevent. The stanza here
# is the GOOD one, so nothing but the status can be what refuses it.
SIZELOG8="$MWORK/size-readfail.log"
FAKE_SHOW="$(cat "$LOCALROOT")"; export FAKE_SHOW
export FAKE_SHOW_RC=1
check "clone sizing: a FAILED read refuses, however good its stdout looked (#171 D2)" \
  1 "could not be read" \
  mintbox "$SIZELOG8" new --name w9 --from work --cpu 2 --disk 20GiB
check "clone sizing: ...and NO copy ran at all (#171 D2)" 1 "" \
  grep -q '^incus copy ' "$SIZELOG8"
# Belt and braces on the thing that actually breaks: the argv, not the prose.
# A helper that failed open would put this on the copy line.
check "clone sizing: ...so no -d rode a copy box never read (#171 D2)" 1 "" \
  grep -qF 'root,size=20GiB' "$SIZELOG8"
unset FAKE_SHOW_RC
# The cause line is the ONE thing that varies between the two refusals, and it
# varies because box knows the difference. A profile is what box saw; it is not
# what box says when it saw nothing.
check "clone sizing: an unread source is not blamed on a profile (#171 D3)" 1 "" \
  grep -qF 'comes from a profile' "$SIZELOG8.out"
check "clone sizing: ...and the profile-rooted source still is (#171 D3)" 0 \
  "comes from a profile" cat "$SIZELOG3.out"
# Everything else D3 was ruled to carry is identical on both arms — the
# situation is identical, only the cause differs.
check "clone sizing: ...the unread arm still says nothing was created (#171 D3)" \
  0 "NOTHING WAS CREATED" cat "$SIZELOG8.out"
check "clone sizing: ...still offers the two measured routes (#171 D3)" \
  0 "drop --disk" cat "$SIZELOG8.out"
check "clone sizing: ...and still prints no runnable line, anchored (#171 D3)" 0 "" \
  no_command_lines "$SIZELOG8.out"
export FAKE_SHOW=""
# ...while the flags with no precondition are untouched by any of it.
SIZELOG7="$MWORK/size-nodisk.log"
mintbox "$SIZELOG7" new --name w9 --from work --cpu 2 >/dev/null 2>&1 || true
check "clone sizing: ...and -c needs no pre-flight to ride the copy (#171 D2)" \
  0 "-c limits.cpu=2" copyline "$SIZELOG7"
unset FAKE_SHOW

# D6 — BOTH branches narrate, from the same helper, read off the daemon. The
# issue argued the clone was silent where the mint spoke; the mint speaks no
# more than the clone does, so ruling the clone alone would have left the same
# asymmetry pointing the other way.
SIZECFG="$MWORK/clone-sized.cfg"
cat > "$SIZECFG" <<'CFG'
user.box 1
limits.cpu 6
limits.memory 12GiB
CFG
SIZEDCLONE="$MWORK/sized-clone.log"
export FAKE_CFG="$SIZECFG" FAKE_ROOT_SIZE=80GiB
check "clone: narrates the resources it actually carries (#171 D6)" \
  0 "resources, read back from incus: cpu=6 mem=12GiB disk=80GiB" \
  mintbox "$SIZEDCLONE" new --name w10 --from work/authed
# The mint half of D6, which is the part the issue's false comparison hid.
SIZEDMINT="$MWORK/sized-mint.log"
check "mint: narrates them too, from the same helper (#171 D6)" \
  0 "resources, read back from incus: cpu=6 mem=12GiB disk=80GiB" \
  mintbox "$SIZEDMINT" new --name w14 --container
# One helper, one call site, after the branches rejoin — so the parity is
# structural and a third way of minting cannot ship silent about its sizing.
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "mint: the narration is ONE call, after the branches rejoin (#171 D6)" 0 "" bash -c '
  fn="$(awk "/^cmd_new\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  [ "$(printf "%s\n" "$fn" | grep -c "narrate_resources ")" -eq 1 ]'
# --expanded, because the question is what the instance will RUN with: a
# profile added by hand is as real as box's own per-instance stamp, and a bare
# 'config get' would report only the override.
check "clone: reads the limits with --expanded, not just the override (#171 D6)" 0 "" \
  grep -qF 'incus config get --expanded w10 limits.cpu' "$SIZEDCLONE"
# The root size is a DEVICE key, not a config one — its absence is how the
# container case answers, so it must never be read off limits.*.
check "clone: reads the root size as a device key (#171 D6)" 0 "" \
  grep -qE '^incus config device get w10 root size *$' "$SIZEDCLONE"
unset FAKE_ROOT_SIZE
# No per-instance root override — the container answer — prints no disk figure
# rather than inventing one from the pool or from a template it never loaded.
CTCLONE="$MWORK/ct-clone.log"
check "clone: no root override → the figures it HAS, and no disk guess (#171 D6)" \
  0 "resources, read back from incus: cpu=6 mem=12GiB" \
  mintbox "$CTCLONE" new --name w11 --from work/authed
check "clone: ...and says nothing at all about a disk (#171 D6)" 1 "" \
  grep -qF 'disk=' "$CTCLONE.out"
unset FAKE_CFG
# The fully degraded read: incus answers none of the three. Silence here is
# indistinguishable from the bug this line exists to fix, so it says so and
# names the verb that has the whole config.
check "clone: an unreadable read-back says so rather than going quiet (#171 D6)" \
  0 "incus reported no resource figures" \
  mintbox "$MWORK/blind-clone.log" new --name w12 --from work/authed
check "mint: ...and the mint path degrades the same way (#171 D6)" \
  0 "incus reported no resource figures" \
  mintbox "$MWORK/blind-mint.log" new --name w15 --container

# D5 — the post-copy handle, where box does print one, carries what incus
# actually does. 'box new --help' is that place now: the D3 refusal prints no
# command at all, so the handle lives here and nowhere else.
check "new --help: says explicit resource flags work on --from (#171 D1)" 0 \
  "explicit --cpu/--memory/--disk flags" "$BOX" help new
check "new --help: ...that they ride the copy rather than resize (#171 D1)" 0 \
  "no resize, no restart" "$BOX" help new
check "new --help: ...and carries --disk's precondition (#171 D2)" 0 \
  "a root device of its own" "$BOX" help new
check "new --help: the disk handle demands a stopped box (#171 D5)" 0 \
  "STOP THE BOX" "$BOX" help new
check "new --help: ...and names the pools that defer the quota (#171 D5)" 0 \
  "'dir' or 'btrfs'" "$BOX" help new
check "new --help: ...and that no local driver shrinks a root (#171 D7)" 0 \
  "will shrink one" "$BOX" help new
# Every 'box incus' line box prints, RUN back through cmd_incus — the help's
# three handles and the narration's one. This is the assertion the issue's own
# proposal fails, and it fails the day cmd_incus's substitution changes.
HINTCFG="$MWORK/hints.cfg"; printf 'user.box 1\n' > "$HINTCFG"
HINTLOG="$MWORK/hints.log"
run_printed_hints() {  # run_printed_hints <output-file> <incus-log>
  local line
  : > "$2"
  # Capture first, THEN read (#124's class) — and it is box's own printed
  # words being word-split here, never anything a caller supplied.
  grep -oE 'box incus .*' "$1" > "$MWORK/hints.txt" || true
  while IFS= read -r line; do
    local words; read -r -a words <<<"$line"
    env FAKE_INCUS_LOG="$2" FAKE_CFG="$HINTCFG" \
        PATH="$MSHIM:$NETSHIM:$PATH" "$BOX" "${words[@]:1}" </dev/null >/dev/null 2>&1
  done < "$MWORK/hints.txt"
}
"$BOX" help new > "$MWORK/help-new.out" 2>&1
run_printed_hints "$MWORK/help-new.out" "$HINTLOG"
# Position, not presence: 'config set <inst> limits.cpu 4' is the contract, and
# 'config set limits.cpu 4 <inst>' is the bug the issue's message would have
# shipped. '<box>' is the help's own placeholder and resolves like any name.
check "new --help: the printed cpu handle RUNS, instance first (#171 D5)" 0 "" \
  grep -qE '^incus config set <box> limits\.cpu 4 *$' "$HINTLOG"
check "new --help: the memory handle lands the same way (#171 D5)" 0 "" \
  grep -qE '^incus config set <box> limits\.memory 8GiB *$' "$HINTLOG"
check "new --help: and the root device handle too (#171 D5)" 0 "" \
  grep -qE '^incus config device set <box> root size=60GiB *$' "$HINTLOG"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "new --help: ...those three and no fourth (#171 D5)" 0 "3" \
  bash -c 'grep -cE "^incus config (set|device set) " "$1"' _ "$HINTLOG"
# The narration's own handle, driven the same way.
NARRHINT="$MWORK/narr-hints.log"
export FAKE_CFG="$SIZECFG"
mintbox "$MWORK/hint-clone.log" new --name w16 --from work/authed >/dev/null 2>&1 || true
unset FAKE_CFG
run_printed_hints "$MWORK/hint-clone.log.out" "$NARRHINT"
check "clone: the narration's own handle RUNS, instance first (#171 D5)" 0 "" \
  grep -qE '^incus config set w16 limits\.cpu <n> *$' "$NARRHINT"

# ---------------------------------------------------------------------------
# THE TWO CLONE PATHS, TOLD APART (#266)
#
# The 0.10.0 cut drill cloned a stopped, renamed box's explicit 'authed'
# snapshot twice and lost both to the agent wait, while an ordinary clone of a
# running blank box stayed green in the same run. Nothing in this suite reaches
# a KVM guest, so what is provable here is not the guest's behaviour: it is
# that the two paths ARE two paths in box's own argv, stamp and narration. That
# matters twice over — a later change cannot quietly merge them, and a failure
# record can name WHICH of the two produced the box it is describing, which is
# the thing #266's records could not do.
# ---------------------------------------------------------------------------
SNAPCLONE="$MWORK/snap-clone.log"
INSTCLONE="$MWORK/inst-clone.log"
check "clone paths: a snapshot-derived clone runs to completion (#266)" 0 "cloned" \
  mintbox "$SNAPCLONE" new --name s1 --from work/authed
check "clone paths: a running-source clone runs to completion (#266)" 0 "cloned" \
  mintbox "$INSTCLONE" new --name s2 --from work
# The copy argv is the fork itself. One ref names the snapshot; the other must
# name the bare instance, and must never reach for a snapshot nobody asked for.
check "clone paths: the snapshot path copies <instance>/<snapshot> (#266)" \
  0 "incus copy work/authed s1" copyline "$SNAPCLONE"
check "clone paths: the instance path copies the bare instance (#266)" \
  0 "incus copy work s2" copyline "$INSTCLONE"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "clone paths: ...and names no snapshot the caller never gave it (#266)" 1 "" \
  bash -c 'grep -m1 "^incus copy " "$1" | grep -q "work/"' _ "$INSTCLONE"
# The stamp is the fork made durable, and it is what agent_forensics reads back
# off a failed clone: origin.from carries a '/' for a snapshot source and none
# for an instance one, so a bundle can name the shape without asking anything.
check "clone paths: the snapshot path stamps the snapshot it used (#266)" 0 "" \
  restamp_has "$SNAPCLONE" 'user\.box\.origin\.from=work/authed'
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "clone paths: the instance path stamps the instance, with no '/' (#266)" 0 "" \
  bash -c 'grep -F "config set" "$1" | grep -qE "user\.box\.origin\.from=work([[:space:]]|$)"' _ "$INSTCLONE"
# Both paths reach the same 'incus start' and the same wait — the boundary the
# drill lost both clones at. If one path ever stops passing through it, the
# forensics this issue bought stop covering half the surface they were built for.
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "clone paths: both reach the start that precedes the agent wait (#266)" 0 "" \
  bash -c 'grep -q "^incus start s1 " "$1" && grep -q "^incus start s2 " "$2"' _ "$SNAPCLONE" "$INSTCLONE"
# The narration is the fork an operator actually reads, and the shim answers
# 'snapshot list' with what incus really hands back in each case: copying an
# INSTANCE carries the source's snapshots, copying a SNAPSHOT carries none.
# Both are honest, they are different, and each path has to say its own (#104).
export FAKE_SNAPS='pristine,2026-08-30 11:02 UTC,NO,NO
'
check "clone paths: a running-source clone inherits the snapshots, and says so (#266)" \
  0 "it inherited the source's snapshots, 'pristine' among them" \
  mintbox "$INSTCLONE" new --name s2 --from work
export FAKE_SNAPS=''
check "clone paths: a snapshot-derived clone has none, and says THAT instead (#266)" \
  0 "no 'pristine' mark here" \
  mintbox "$SNAPCLONE" new --name s1 --from work/authed
unset FAKE_SNAPS

# ---------------------------------------------------------------------------
# THE FORENSIC BUNDLE (#266)
#
# Driven, not asserted on the source. The whole defect was a failure that
# printed something true-looking and useless — "(last non-blank lines: none)"
# for two clones whose consoles nobody could prove were ever read — so the only
# proof that matters is the text box actually emits. wait_agent's five minutes
# cannot be driven, but the function that writes the record can: lifted out of
# bin/box the way the line-order checks lift cmd_import, and run against a stub
# incus that answers exactly as the drill's host did.
# ---------------------------------------------------------------------------
FSHIM="$(mktemp -d)"
cat > "$FSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the forensics drive. Knobs, all optional:
#   FAKE_CONSOLE_RC   the status 'console --show-log' exits with (default 0)
#   FAKE_CONSOLE      what it writes to stdout — default empty, which is the
#                     drill's own observation and the case under test
#   FAKE_CONSOLE_ERR  what it writes to stderr, i.e. incus's own refusal
#   FAKE_INSTLOG      what 'info --show-log' returns (the host side)
#   FAKE_CONFIG       what 'config show --expanded' returns
#   FAKE_CONFIG_ERR   what it writes to stderr, with FAKE_CONFIG_RC its status
case "$*" in
  console\ *--show-log*)
    printf '%s' "${FAKE_CONSOLE-}"
    printf '%s' "${FAKE_CONSOLE_ERR-}" >&2
    exit "${FAKE_CONSOLE_RC:-0}" ;;
  info\ *--show-log*) printf '%s' "${FAKE_INSTLOG-}" ;;
  config\ show\ *)
    printf '%s' "${FAKE_CONFIG-}"
    printf '%s' "${FAKE_CONFIG_ERR-}" >&2
    exit "${FAKE_CONFIG_RC:-0}" ;;
  info\ *)            printf 'Name: %s\nStatus: STOPPED\n' "${2-}" ;;
esac
exit 0
SHIM
chmod +x "$FSHIM/incus"
# The real function, evaluated out of the real file — so a rewrite of either
# helper is driven here rather than described. 'set -euo pipefail' is bin/box's
# own header and is load-bearing to one of the cases below: the empty-console
# tail used to end the run inside the diagnostic, and a drive under laxer
# options could not have caught it.
#
# The bundle's root is TMPDIR, so the drive gets its own and the tests can hand
# the function a root it cannot use. Nothing here knows the bundle's NAME: it is
# mktemp-fresh per attempt (#266 round 1), so every assertion about its contents
# goes through bundle_of, which reads the path back out of box's own report —
# exactly as drill's finding does.
FTMP="$(mktemp -d)"
forensics() {   # forensics <instance> [bundle-root] — agent_forensics, out of bin/box
  # shellcheck disable=SC2016  # $1/$2 expand in the child shell, by design
  env PATH="$FSHIM:$PATH" TMPDIR="${2:-$FTMP}" bash -c '
    set -euo pipefail
    die() { echo "box: $*" >&2; exit 1; }
    eval "$(awk "/^strip_ansi\(\) \{/,/^\}/" "$1")"
    eval "$(awk "/^forensic_line\(\) \{/,/^\}/" "$1")"
    eval "$(awk "/^agent_forensics\(\) \{/,/^\}/" "$1")"
    agent_forensics "$2" "the finding this bundle was opened for."
  ' _ "$BOX" "$1" 2>&1
}
bundle_of() {   # bundle_of <instance> — drive it, and echo the bundle it reports
  forensics "$1" | sed -n 's/^box: forensics kept in \([^ ]*\) .*/\1/p' | tail -1
}
F1=f266empty F2=f266read F3=f266guest F4=f266inst
# THE DEFECT ITSELF. An empty console must not silence the report of the empty
# console: before #266 the 'grep -v | tail | sed' exited 1 on a blank file,
# pipefail made that the pipeline's status, and set -e ended the run there —
# after the "(last non-blank lines:)" header and before every conclusion box
# had to offer. The exit status is the assertion.
export FAKE_CONSOLE='' FAKE_CONSOLE_RC=0 FAKE_CONSOLE_ERR='' FAKE_INSTLOG='' FAKE_CONFIG=''
check "forensics: an empty console does not kill the run reporting it (#266)" \
  0 "the finding this bundle was opened for." forensics "$F1"
check "forensics: ...and it reaches the state file, which is what is left (#266)" \
  0 "state.txt is what is left" forensics "$F1"
# WHICH empty it is — the distinction the drill's two records could not draw.
# Half one: incus refused, so the blank file is box's failure to look.
export FAKE_CONSOLE_RC=1 FAKE_CONSOLE_ERR='Error: Instance is not running'
check "forensics: a console that could not be READ says so (#266)" \
  0 "THE CONSOLE COULD NOT BE READ" forensics "$F2"
check "forensics: ...quoting incus's own refusal rather than a blank tail (#266)" \
  0 "Instance is not running" forensics "$F2"
# And when it fails SILENTLY — 'timeout' killing it leaves status 124 and no
# stderr at all — the report still runs to its end. This is the exact shape
# that used to die inside the diagnostic: a tail over a file with no lines in
# it, exiting 1 under pipefail with set -e watching. Drop the guard on that
# tail and this pair reds while every other case here stays green.
export FAKE_CONSOLE_RC=124 FAKE_CONSOLE_ERR=''
check "forensics: a console capture that fails SILENTLY still reports (#266)" \
  0 "exited 124" forensics "$F2"
check "forensics: ...reaching its conclusion rather than dying in the tail (#266)" \
  0 "state.txt is what is left" forensics "$F2"
# Half two: incus answered, and the answer was nothing. A different finding,
# with a different next step, and it must never be worded like the first.
export FAKE_CONSOLE_RC=0 FAKE_CONSOLE_ERR='' \
  FAKE_INSTLOG='Error: Failed to start device "vsock": address already in use'
check "forensics: a guest that wrote nothing is a finding of its own (#266)" \
  0 "THE GUEST WROTE NOTHING" forensics "$F3"
check "forensics: ...and the host-side log is where it sends the reader (#266)" \
  0 'Failed to start device "vsock"' forensics "$F3"
forensics_says() { forensics "$1" | grep -qF -e "$2"; }
check "forensics: ...never calling incus's silence a read failure (#266)" 1 "" \
  forensics_says "$F3" "COULD NOT BE READ"
# The bundle is FILES, because the caller tears the box down: a tail on a
# terminal nobody kept is how #266 came to be reconstructed from four lines.
bundle_has() { local d; d="$(bundle_of "$1")"; [ -n "$d" ] && [ -s "$d/$2" ]; }
check "forensics: the host-side log is kept on disk (#266)" 0 "" bundle_has "$F3" instance.log
export FAKE_CONFIG='config:
  user.box.origin.from: work/authed
'
check "forensics: the expanded config is kept — volatile keys and all (#266)" 0 "" \
  bundle_has "$F3" config.yaml
check "forensics: 'incus info' is kept beside it (#266)" 0 "" bundle_has "$F3" state.txt
# Naming the SHAPE. This is the same discriminator the clone-path checks above
# pin from the writing end, read back here from a failed box's own config.
check "forensics: a snapshot-derived clone is named as one (#266)" \
  0 "THIS IS A CLONE OF THE SNAPSHOT work/authed" forensics "$F3"
check "forensics: ...and the running-source control is named as the control (#266)" \
  0 "an ordinary clone of a running source is the control" forensics "$F3"
export FAKE_CONFIG='config:
  user.box.origin.from: work
'
check "forensics: an instance-source clone is NOT called a snapshot clone (#266)" 1 "" \
  forensics_says "$F4" "CLONE OF THE SNAPSHOT"
export FAKE_CONFIG=''
check "forensics: and a fresh mint, which has no origin.from, claims neither (#266)" 1 "" \
  forensics_says "$F4" "CLONE OF THE SNAPSHOT"
# The console still gets read and still gets triaged — the pre-existing image
# diagnoses ride the same bundle rather than being replaced by it. And nothing
# raw ever reaches a terminal: the escapes are stripped on the way to the file.
export FAKE_CONSOLE=$'\x1b[1m\x1b[37mLoading\x1b[0m\nFailed to decompress kernel\n'
check "forensics: a console that DID answer is tailed (#266)" \
  0 "console, last non-blank lines" forensics "$F2"
check "forensics: ...and the image triage still fires off it (#266)" \
  0 "THE KERNEL WOULD NOT DECOMPRESS" forensics "$F2"
# Byte-counted rather than pattern-matched: 'grep -P' is a GNU extension and
# this suite's header promises it runs anywhere. The file is clean exactly when
# stripping it to printable ASCII, tab and newline removes nothing.
console_is_clean() {
  local d f; d="$(bundle_of "$1")" || return 1
  [ -n "$d" ] || return 1
  f="$d/console.log"
  [ "$(wc -c <"$f")" -eq "$(LC_ALL=C tr -cd '\11\12\40-\176' <"$f" | wc -c)" ]
}
check "forensics: the kept console carries no escape bytes at all (#266)" 0 "" \
  console_is_clean "$F2"
# ---------------------------------------------------------------------------
# The bundle's OWNERSHIP (#266 round 1). It used to be /tmp/box-forensics-<box>
# taken with 'mkdir -p', and box's restricted tier puts each tenant in their own
# user-<uid> project — so two tenants legitimately hold a box called 'work' and
# share one sticky /tmp. Everything below is that fixed name's three failures,
# and none of them could red while the fixtures started from 'rm -rf'.
# ---------------------------------------------------------------------------
export FAKE_CONSOLE='' FAKE_CONSOLE_RC=0 FAKE_CONSOLE_ERR='' FAKE_INSTLOG='' FAKE_CONFIG=''
# Fresh per attempt, and never at a name anyone could have prepared. Two drives
# of the same box must not land in one directory: a bundle shared between
# attempts is how an EARLIER failure's evidence gets read as this one's.
bundle_is_fresh() {
  local a b; a="$(bundle_of "$1")"; b="$(bundle_of "$1")"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] &&
  [ "$a" != "$FTMP/box-forensics-$1" ] && [ "$b" != "$FTMP/box-forensics-$1" ]
}
check "forensics: every attempt gets its own bundle, at no guessable name (#266)" \
  0 "" bundle_is_fresh "$F1"
# ADOPTION, which is what 'mkdir -p' did. A directory already sitting at the old
# fixed name is not taken over, not written into, and not reported: a squatter
# on a multi-tenant /tmp cannot make box quote their file as this box's evidence.
squat_survives() {
  local d
  rm -rf "$FTMP/box-forensics-$1"
  mkdir -p "$FTMP/box-forensics-$1"
  printf 'SOMEONE ELSE RAN HERE\n' > "$FTMP/box-forensics-$1/console.err"
  d="$(bundle_of "$1")"
  [ -n "$d" ] && [ "$d" != "$FTMP/box-forensics-$1" ] &&
  [ "$(cat "$FTMP/box-forensics-$1/console.err")" = "SOMEONE ELSE RAN HERE" ] &&
  [ ! -e "$FTMP/box-forensics-$1/state.txt" ]
}
check "forensics: a directory at the old fixed name is never adopted (#266)" \
  0 "" squat_survives "$F1"
rm -rf "$FTMP/box-forensics-$F1"
# PRIVATE TO ITS OWNER. The expanded config carries the tenant's user.box.user
# and their rendered cloud-init.user-data; under the ordinary umask 0002 the old
# bundle was 0775/0664, readable across exactly the boundary the restricted tier
# exists to enforce. Read with ls -ld, not stat: 'stat -c' is a GNU flag and
# this suite's header promises it runs anywhere.
bundle_is_private() {   # under the umask that measured 0775/0664 on the old one
  ( umask 0002
    local d; d="$(bundle_of "$1")" || return 1
    # shellcheck disable=SC2012  # 'stat -c' is a GNU flag; the mode column of
    # 'ls -ld' is the portable read, and the path is a mktemp name, not a glob.
    [ -n "$d" ] && [ "$(ls -ld "$d" | cut -c1-10)" = "drwx------" ] )
}
check "forensics: the bundle is readable by its owner and nobody else (#266)" \
  0 "" bundle_is_private "$F1"
# NEVER FATAL, on the one path that used to be. With the bundle unreachable the
# old code's fallback ': >$clog' could not open it either, and set -e ended the
# run inside the diagnostic — the same four-line record #266 opened on, from a
# different cause. The exit status is the assertion; a file where the root
# should be fails identically for root and non-root, so the case is the same
# case on every runner.
: > "$FTMP/not-a-dir"
check "forensics: an unusable bundle root does not kill the run (#266)" \
  0 "NO FORENSICS COULD BE KEPT" forensics "$F1" "$FTMP/not-a-dir"
check "forensics: ...and it sends the reader to the live guest instead (#266)" \
  0 "incus console $F1 --show-log" forensics "$F1" "$FTMP/not-a-dir"
forensics_says_in() { forensics "$1" "$2" | grep -qF -e "$3"; }
check "forensics: ...and claims no bundle it could not write (#266)" 1 "" \
  forensics_says_in "$F1" "$FTMP/not-a-dir" "forensics kept in"
# CLAIM ONLY WHAT WAS CAPTURED. A line naming a file that holds nothing is the
# same false record as the bundle that reported four captures into a directory
# it could not write. An empty capture is reported as empty, with the reason
# where there is one.
check "forensics: a capture that produced nothing is reported as missing (#266)" \
  0 "not captured — 'incus info --show-log'" forensics "$F1"
export FAKE_CONFIG_RC=1 FAKE_CONFIG_ERR='Error: Instance not found'
check "forensics: ...and a capture that FAILED is reported with its reason (#266)" \
  0 "not captured — the expanded config, volatile keys and all: Error: Instance not found" \
  forensics "$F1"
unset FAKE_CONFIG_RC FAKE_CONFIG_ERR
export FAKE_INSTLOG='qemu: the host side said this'
check "forensics: ...while a capture that succeeded is named by its path (#266)" \
  0 "instance.log   'incus info --show-log'" forensics "$F1"
unset FAKE_CONSOLE FAKE_CONSOLE_RC FAKE_CONSOLE_ERR FAKE_INSTLOG FAKE_CONFIG
rm -rf "$FTMP" "$FSHIM"
# Both exits from the wait produce a bundle, and the early one exists at all.
# Line-order and call-site assertions, fail-closed: the timeout path is five
# minutes of sleeps and cannot be driven, so its wiring is pinned on the source.
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "wait_agent: BOTH ways out leave a bundle (#266)" 0 "2" bash -c '
  awk "/^wait_agent\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -c "agent_forensics "'
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "wait_agent: a stopped instance ends the wait early (#266)" 0 "" bash -c '
  awk "/^wait_agent\(\) \{/,/^\}/" "'"$ROOT"'/bin/box" | grep -q "! instance_is_running"'
# Fails OPEN, and that is the load-bearing half: this check can cut a wait
# short, so a daemon that hiccups for one poll must never end a boot that was
# going to succeed. Only a state incus actually named ends it.
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "wait_agent: an unreadable state is not a stopped instance (#266)" 0 "" bash -c '
  fn="$(awk "/^instance_is_running\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  printf "%s\n" "$fn" | grep -qE "STOPPED\|ERROR\) return 1" &&
  printf "%s\n" "$fn" | grep -qE "\*\)\s+return 0"'
# The drill's half of the same rule (#266). A bundle in /tmp that no finding
# names is evidence only for whoever is still sitting at that terminal, and the
# finding is what the emitted drills/<version>.md keeps — so the path rides the
# finding. Driven out of drill.sh, not asserted on it.
#
# And it reads the path out of THIS mint's log rather than testing a fixed name
# (#266 round 1): a name-existence test hands a leftover bundle to whichever
# failure comes next, including one that died before box ever wrote forensics.
drill_evidence() {   # drill_evidence <log-body> — mint_evidence, out of drill.sh
  # shellcheck disable=SC2016  # $1..$3 expand in the child shell, by design
  bash -c '
    set -u
    eval "$(awk "/^mint_evidence\(\) \{/,/^\}/" "$1")"
    printf "log-line-one\n%s\nlog-line-two\n" "$2" > "$3/mint-evidence.log"
    mint_evidence "$3/mint-evidence.log"
  ' _ "$ROOT/drill/drill.sh" "$1" "$MWORK"
}
drill_evidence_says() { drill_evidence "$1" | grep -qF -e "$2"; }
DBUNDLE="$MWORK/box-forensics-d266.aBcDeF"
rm -rf "$DBUNDLE" /tmp/box-forensics-d266
check "drill: a failed-clone finding still tails the log it always did (#266)" \
  0 "log-line-two" drill_evidence ""
check "drill: ...and invents no bundle when the mint left none (#266)" 1 "" \
  drill_evidence_says "" "forensics kept:"
mkdir -p "$DBUNDLE"
check "drill: ...but NAMES the bundle in the finding when there is one (#266)" \
  0 "forensics kept: $DBUNDLE" \
  drill_evidence "box: forensics kept in $DBUNDLE — they outlive the teardown this failure triggers:"
# A mint that died BEFORE the forensics ran — a copy or start failure — names
# none, and a directory sitting at the old fixed name does not change that. This
# is the stale-attribution case: the finding is what drills/<version>.md keeps,
# so a bundle nobody in this run produced would land in the release record as
# evidence of a failure it never saw.
mkdir -p /tmp/box-forensics-d266
check "drill: a mint that died before the forensics names no bundle (#266)" 1 "" \
  drill_evidence_says "" "forensics kept:"
rmdir /tmp/box-forensics-d266
# And a path that has since been cleaned away is not offered either: the log
# said it, the disk disagrees, and the disk wins.
check "drill: a bundle named by the log but gone from disk is not offered (#266)" 1 "" \
  drill_evidence_says \
  "box: forensics kept in $MWORK/box-forensics-d266.deleted — they outlive the teardown this failure triggers:" \
  "forensics kept:"
rm -rf "$DBUNDLE"
# Both clone findings carry it. The sibling peer clone failed the same way in
# the same run, and a record naming one bundle and not the other is half a
# record — which is the shape of #266's own evidence.
# shellcheck disable=SC2016  # the $-string is a literal inside bash -c
check "drill: BOTH clone findings carry the evidence line (#266)" 0 "2" bash -c '
  grep -c "mint_evidence /tmp/mint-" "'"$ROOT"'/drill/drill.sh"'

# --- the read half: 'box info' surfaces it ---------------------------------
# A stamp nothing can read is not done. cmd_info printed NAME/STATE/TYPE/IPV4
# and surfaced none of the keys that already existed.
STAMPED="$MWORK/stamped.cfg"
cat > "$STAMPED" <<'CFG'
user.box 1
user.box.schema 1
user.box.created 2026-07-19T14:22:07Z
user.box.version 0.8.0
user.box.image images:debian/13/cloud
user.box.image.fingerprint 8a2f1c9d4e5b6a7c8d9e
user.box.mode vm
user.box.mode.asked auto
user.box.template claude
user.box.user claude
user.box.role claude
user.box.rig.repo heavy-duty/rig
user.box.rig.ref main
user.box.origin mint
CFG
infobox() {  # infobox <cfg-file> — 'box info work' against a canned config
  env FAKE_INCUS_LOG=/dev/null FAKE_CFG="$1" FAKE_ROW='work,RUNNING,VIRTUAL-MACHINE,0' \
    PATH="$MSHIM:$PATH" "$BOX" info work </dev/null 2>&1
}
check "info: surfaces the mint time and the box that minted it (#103)" \
  0 "MINTED     2026-07-19T14:22:07Z by box 0.8.0" infobox "$STAMPED"
check "info: surfaces the image alias AND what it resolved to (#103)" \
  0 "IMAGE      images:debian/13/cloud @ 8a2f1c9d4e5b" infobox "$STAMPED"
check "info: surfaces the template with its user (#103)" \
  0 "TEMPLATE   claude (user claude)" infobox "$STAMPED"
check "info: surfaces the origin (#103)" 0 "ORIGIN     mint" infobox "$STAMPED"
# THE LEGACY STAMP (#214). $STAMPED deliberately still carries user.box.role,
# user.box.rig.repo and user.box.rig.ref: that is exactly what every box minted
# before this release has on it, and no migration rewrites them. box must read
# such a box without error and print none of the three — the keys are simply
# not box's any more, so they are not box's to report.
info_shows() { infobox "$1" | grep -qE "$2"; }   # (info_has, defined once, early)
check "info: a legacy stamp reads without error (#214)" 0 "NAME       work" \
  infobox "$STAMPED"
check "info: ...printing its provenance block as usual (#214)" 0 "MINTED     " \
  infobox "$STAMPED"
check "info: ...and no RIG row for the retired keys (#214)" 1 "" \
  info_shows "$STAMPED" '^RIG '
check "info: ...nor the role in the TEMPLATE parenthesis (#214)" 1 "" \
  info_shows "$STAMPED" 'role claude'
check "info: ...and it exits 0 rather than choking (#214)" 0 "" \
  infobox "$STAMPED"

# The identity reads back in the HEADER, not in the provenance block (#181).
# The block below answers how this box came to BE; the id answers which box it
# IS — the fact the NAME line only appears to carry, since a rename moves the
# name and leaves the id exactly where it was.
IDCFG="$MWORK/identified.cfg"
{ cat "$STAMPED"; echo 'user.box.id 3f2504e0-4f89-41d3-9a0c-0305e82c3301'; } > "$IDCFG"
check "info: surfaces the id (#181)" \
  0 "ID         3f2504e0-4f89-41d3-9a0c-0305e82c3301" infobox "$IDCFG"
# Adjacency is the point: NAME and ID are one statement of identity, and an id
# printed below the mint block would read as one more provenance field.
id_follows_name() {
  local out; out="$(infobox "$1")"
  [ "$(printf '%s\n' "$out" | grep -cE '^(NAME|ID)')" -eq 2 ] &&
  [ "$(printf '%s\n' "$out" | grep -nE '^ID' | head -1 | cut -d: -f1)" -eq 2 ]
}
check "info: ...directly under NAME, which is the alias it outlives (#181)" 0 "" \
  id_follows_name "$IDCFG"
check "info: ...and the state block it always printed is untouched (#181)" \
  0 "IPV4       10.1.2.3" infobox "$IDCFG"
# Still the box it always was: the new block is additive, above the snapshots.
check "info: still prints the state block it always did" 0 "IPV4       10.1.2.3" infobox "$STAMPED"

# A clone reads back as a clone, naming its source. Modelled on what the
# --from branch actually leaves behind: origin re-stamped, mode.asked cleared.
CLONECFG="$MWORK/clone.cfg"
{ grep -v -e '^user.box.origin ' -e '^user.box.mode.asked ' "$STAMPED"
  echo 'user.box.origin clone'
  echo 'user.box.origin.from work/authed'; } > "$CLONECFG"
check "info: a clone says so, and names the box it came from (#103)" \
  0 "ORIGIN     clone of work/authed" infobox "$CLONECFG"
# ...and stays silent about a demand nobody made of it. The MODE line is gated
# on 'asked' precisely so absence renders as silence rather than as a guess;
# TYPE above still reports VM off the instance type, so nothing is lost.
info_has_mode() { infobox "$1" | grep -q '^MODE'; }
check "info: a clone prints no MODE line — nobody asked IT anything (#103)" 1 "" \
  info_has_mode "$CLONECFG"
check "info: ...while TYPE still reports what it actually is (#103)" \
  0 "TYPE       VM" infobox "$CLONECFG"
# The mint keeps its MODE line — there, the operator really was asked.
check "info: a MINT still surfaces what was asked for (#103)" \
  0 "MODE       vm (asked: auto)" infobox "$STAMPED"

# --- legacy boxes: the promise that they keep working under every verb ------
# A box carrying the boundary tag and NOTHING else — every box minted before
# this stamp existed. It must still render, exit 0, and say plainly that the
# mint was not recorded rather than inventing one or erroring out.
LEGACY="$MWORK/legacy.cfg"; printf 'user.box 1\n' > "$LEGACY"
check "info: a box with NO stamp at all still renders, exit 0 (#103)" \
  0 "NAME       work" infobox "$LEGACY"
check "info: ...and says the mint was not recorded, rather than inventing one" \
  0 "predates the mint stamp" infobox "$LEGACY"
info_has() { infobox "$1" | grep -qE "$2"; }
check "info: ...and prints no half-empty IMAGE/ORIGIN lines for keys it lacks" 1 "" \
  info_has "$LEGACY" '^(IMAGE|ORIGIN|RIG|MODE) '
# Every box minted before #181 has no id, and nothing synthesises one at read
# time: an id a reader invents is not stable, which is the whole point of
# having one. Absence renders as silence, the same rule the block above keeps.
check "info: a box minted before the id prints no ID line (#181)" 1 "" \
  info_has "$LEGACY" '^ID '
check "info: ...and neither does a stamped box that predates the key (#181)" 1 "" \
  info_has "$STAMPED" '^ID '
check "info: ...while the box itself still renders, exit 0 (#181)" \
  0 "NAME       work" infobox "$STAMPED"
# 'list' is the human table and stays four narrow columns: a full UUID would
# dominate it, and the audience that wants an id is reading --json or 'info'.
# Driven, not asserted on the source — the fixture carries an id and the table
# must simply never show one.
listbox() {  # listbox <cfg-file> — 'box list' against a canned config
  env FAKE_INCUS_LOG=/dev/null FAKE_CFG="$1" FAKE_ROW='work,RUNNING,VIRTUAL-MACHINE,0' \
    PATH="$MSHIM:$PATH" "$BOX" list </dev/null 2>&1
}
list_has_id() { listbox "$1" | grep -qE '(^|[[:space:]])ID([[:space:]]|$)|[0-9a-f]{8}-[0-9a-f]{4}-'; }
check "list: still prints the box it always did (#181)" 0 "work" listbox "$IDCFG"
check "list: ...and never the id — that is what --json and 'info' are for (#181)" 1 "" \
  list_has_id "$IDCFG"
# A snapshot and a restore are the SAME box, so neither writes the key. cmd_new
# and cmd_import are the only minting doors, and only they re-stamp.
snapshot_leaves_id_alone() {
  ! awk '/^cmd_snapshot\(\) \{/,/^\}/' "$ROOT/bin/box" | grep -q 'user\.box\.id'
}
check "snapshot: leaves the id alone — a snapshot is the same box (#181)" 0 "" \
  snapshot_leaves_id_alone
# 'restore' is a table row straight to 'incus snapshot restore', so there is no
# function to inspect: what proves it is that the row has no re-stamp in it.
check "restore: is a passthrough row, so it cannot rewrite the id (#181)" 0 "" \
  bash -c 'grep -F "\"restore^" "'"$ROOT"'/bin/box" | grep -qv "user.box.id"'
# A pre-rename box carries user.claudebox=1 and no metadata at all, and is
# always a Claude box — the same mapping box_user() makes, honored forever.
PRERENAME="$MWORK/prerename.cfg"; printf 'user.claudebox 1\n' > "$PRERENAME"
check "info: a pre-rename box still reads as the claude template (#103)" \
  0 "TEMPLATE   claude" infobox "$PRERENAME"

# --- a schema from the future is not a broken box --------------------------
# A box outlives the release that minted it, so an OLDER box will one day read
# a NEWER box's stamp. It shows what it understands and says so; refusing to
# describe a box a later release minted perfectly well is the wrong answer.
FUTURE="$MWORK/future.cfg"
{ grep -v '^user.box.schema ' "$STAMPED"; echo 'user.box.schema 99'; } > "$FUTURE"
check "info: an unrecognised (newer) schema is noted, not refused (#103)" \
  0 "NOTE" infobox "$FUTURE"
check "info: ...and it still shows every key it DOES understand (#103)" \
  0 "MINTED     2026-07-19T14:22:07Z" infobox "$FUTURE"
check "info: ...and it still exits 0 — a future box is not a broken box (#103)" \
  0 "ORIGIN" infobox "$FUTURE"
# A non-integer schema lands on the same side: noted, never fatal under set -e.
GARBAGE="$MWORK/garbage.cfg"
{ grep -v '^user.box.schema ' "$STAMPED"; echo 'user.box.schema not-a-number'; } > "$GARBAGE"
check "info: a non-integer schema is noted, not fatal (#103)" 0 "NOTE" infobox "$GARBAGE"

# VERSION has ONE reader in bin/box — box_version() — and both 'box --version'
# and the mint stamp go through it. A second 'cat $root/VERSION' is how the two
# would eventually disagree about what minted a box.
# shellcheck disable=SC2016  # '$root' is bin/box's variable, matched literally
one_version_reader() {
  [ "$(grep -cF 'cat "$root/VERSION"' "$ROOT/bin/box")" -eq 1 ]
}
check "the tree's VERSION has a single reader, box_version() (#103)" 0 "" \
  one_version_reader

# ---------------------------------------------------------------------------
# The import event (#131) — DRIVEN, on both halves, like the mint stamp above.
#
# An imported box keeps the artifact's mint stamp verbatim: the mint time, the
# box version, the image and the origin belong to the originating host and
# survive the trip on purpose (#129). What was missing is any record that the
# trip HAPPENED — and the obvious fix, 'origin=import', is the wrong one: it
# would overwrite whether the thing was a mint or a clone before it was
# exported, and leave 'origin.from' naming a lineage nothing explains. So the
# import takes its own keys, and the assertions that matter most here are the
# ABSENCE ones: every key the artifact carried must come out the far side
# untouched.
#
# The write half needs its own shim, because cmd_import reads 'incus config
# show <target>' as the name-collision guard and must see the name FREE — the
# opposite answer from the one the mint shim gives.
ISHIM="$(mktemp -d)"; IWORK="$(mktemp -d)"
cat > "$ISHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the import drive. FAKE_CFG answers 'config get' with a file
# of "<key> <value>" lines — it stands in for the config that rode inside the
# artifact and that 'incus import' has just restored.
printf 'incus %s\n' "$*" | tr '\n' ' ' >> "$FAKE_INCUS_LOG"
printf '\n' >> "$FAKE_INCUS_LOG"
case "$*" in
  "profile show box-profile")
    [ "${FAKE_STACK_PRESENT:-1}" = 1 ] || exit 1 ;;
  # The import boundary, and it is a REFUSAL and not a formality (#229 round 4).
  # incus resolves every name in the artifact's profile list before it creates
  # the instance — createFromBackup -> internalImportFromBackup
  # (cmd/incusd/instances_post.go:859) -> tx.GetProfiles
  # (cmd/incusd/api_internal.go:840-847) -> GetProfilesIfEnabled, which returns
  # on the first name GetProfile cannot find (internal/server/db/cluster/
  # profiles.go:111-116, mapper :389-391 ErrNotFound). So an artifact naming a
  # profile this host lacks never reaches bin/box's re-home comparison at all.
  # FAKE_HOST_PROFILES is what this host has; FAKE_ART_PROFILES is what the
  # artifact asks for. A shim that imported unconditionally is what let 1805
  # green tests miss the boundary, so it models the refusal now.
  "import "*)
    for _p in ${FAKE_ART_PROFILES:-box-profile}; do
      case " ${FAKE_HOST_PROFILES:-box-profile} " in
        *" $_p "*) ;;
        *) echo "Error: Failed importing backup: Failed loading profiles ($_p) for instance: Profile not found" >&2
           exit 1 ;;
      esac
    done ;;
  # Nothing exists under that name: the collision guard passes. The same call
  # enumerates volatile hwaddrs later, where an empty answer is also correct.
  "config show "*) exit 1 ;;
  "config get "*)
    [ -n "${FAKE_CFG:-}" ] || exit 0
    key="$*"; key="${key##* }"
    awk -v k="$key" '$1 == k { $1 = ""; sub(/^ /, ""); print }' "$FAKE_CFG" ;;
  # The profile list the artifact rode in with. Default: already on the
  # contract, so no re-home. FAKE_ART_PROFILES drives the artifacts that are
  # not — which is how a pre-rename export is tested without new code (#229).
  # The quoting is the shim's, not the caller's: incus quotes a CSV cell, and
  # bin/box strips those quotes on the way in. Keeping them here means the
  # variable holds a bare profile name, the way an artifact names one.
  *"--columns P") printf '"%s"\n' "${FAKE_ART_PROFILES:-box-profile}" ;;
esac
# A serialized stand-in for the destination project. Successful mutating
# calls change it; pre-flight refusals must leave it byte-for-byte untouched.
case "$*" in
  "import "*|"profile assign "*|"profile create "*|"profile delete "*|\
  "profile rename "*|"config set "*|"config unset "*|"start "*)
    [ -z "${FAKE_PROJECT_STATE:-}" ] || printf '%s\n' "$*" >> "$FAKE_PROJECT_STATE" ;;
esac
exit 0
SHIM
chmod +x "$ISHIM/incus"

# One realistic index writer drives both the #241 profile boundary and the
# #160 restricted-tier reader. Incus marshals the instance beneath config;
# profile definitions are a sibling of the instance-use list and deliberately
# carry the same names so indentation-blind parsing fails visibly.
write_import_index() {  # write_import_index <path> <container|instance> <used> [defined]
  local path="$1" record_key="$2" used="$3" defined="${4:-$3}"
  {
    echo 'name: work'
    echo 'backend: dir'
    echo 'pool: default'
    echo 'type: virtual-machine'
    echo 'config:'
    printf '  %s:\n' "$record_key"
    echo '    architecture: x86_64'
    echo '    config:'
    echo '      image.os: Debian'
    echo '      limits.cpu: "4"'
    echo '      volatile.base_image: 5b1f9d0c4a'
    echo '      volatile.cloud-init.instance-id: 3d0b7e11'
    echo '      volatile.eth0.hwaddr: 00:16:3e:2f:11:aa'
    echo '      volatile.last_state.power: RUNNING'
    echo '      volatile.uuid: 8f4a1c22-0000-4000-8000-000000000000'
    echo '      volatile.uuid.generation: 8f4a1c22-0000-4000-8000-000000000000'
    echo '    profiles:'
    local profile
    for profile in $used; do printf '    - %s\n' "$profile"; done
    echo '    devices:'
    echo '      root:'
    echo '        path: /'
    echo '        pool: default'
    echo '        type: disk'
    echo '  profiles:'
    for profile in $defined; do printf '  - name: %s\n' "$profile"; done
  } > "$path"
}

# A real tarball, because cmd_import reads the instance name out of the
# artifact with tar before incus is ever called — a stub cannot fake that.
# Keep this name-only artifact untouched: #160 uses it to prove that no
# readable config degrades to the old path instead of guessing.
ARTIFACT="$IWORK/work-20260718T120000Z.tar.gz"
mkdir -p "$IWORK/backup" && printf 'name: work\n' > "$IWORK/backup/index.yaml"
tar -czf "$ARTIFACT" -C "$IWORK" backup/index.yaml

# Profile cases mutate only this independent realistic artifact.
PROFILE_ARTIFACT="$IWORK/profile-work.tar.gz"
PROFILE_INDEX="$IWORK/profile-index.yaml"
mkdir -p "$IWORK/profile-art/backup"

# importbox <logfile> <cfg-file|""> [artifact-profiles] [host-profiles]
# The last two default to a same-release artifact landing on a converged host,
# which is every caller but #229's pair below. They are arguments and not an
# exported-in-a-subshell idiom because two callers overriding them that way is
# what SC2030/SC2031 are for, and CI's shellcheck is not advisory here.
importbox() {  # the real box, shimmed
  local log="$1" cfg="$2" art="${3:-box-profile}" host="${4:-box-profile}"
  local stack="${5:-1}" project_state="${FAKE_PROJECT_STATE:-}"
  local flags=()
  if [ "$#" -gt 5 ]; then shift 5; flags=("$@"); fi
  : > "$log"
  write_import_index "$PROFILE_INDEX" container "$art"
  cp "$PROFILE_INDEX" "$IWORK/profile-art/backup/index.yaml"
  tar -czf "$PROFILE_ARTIFACT" -C "$IWORK/profile-art" backup/index.yaml
  env FAKE_INCUS_LOG="$log" FAKE_CFG="$cfg" \
    FAKE_ART_PROFILES="$art" FAKE_HOST_PROFILES="$host" \
    FAKE_STACK_PRESENT="$stack" FAKE_PROJECT_STATE="$project_state" \
    PATH="${SHIM_PREFIX:+$SHIM_PREFIX:}$ISHIM:$PATH" \
    "$BOX" import "$PROFILE_ARTIFACT" "${flags[@]}" </dev/null >"$log.out" 2>&1
  local rc=$?
  cat "$log.out"
  return "$rc"
}
# One matcher per surface, so an absence assertion is a plain non-zero exit.
# 'config set' is the ONLY call that can write a key, so grepping it is what
# separates "box stamped this" from "the artifact carried it".
import_set() { grep -F 'config set' "$1" | grep -qE "$2"; }

# --- the first trip ---------------------------------------------------------
# The artifact of a box that was MINTED elsewhere and never imported before.
# The id it carried is a fixed, obviously-fake one so the re-mint below can be
# asserted by INEQUALITY: a drawn id that happened to equal the artifact's is
# the one way "re-minted" and "carried through" look alike (#181).
MINTED_ART="$IWORK/minted.cfg"
cat > "$MINTED_ART" <<'CFG'
user.box 1
user.box.schema 1
user.box.created 2026-06-01T10:00:00Z
user.box.version 0.7.0
user.box.template claude
user.box.user claude
user.box.origin mint
user.box.id 11111111-1111-4111-8111-111111111111
CFG
ILOG="$IWORK/import.log"
check "import: a shimmed 'box import' runs to completion (#131)" 0 "imported work" \
  importbox "$ILOG" "$MINTED_ART"
check "import: records WHEN the box landed here, UTC ISO 8601 (#131)" 0 "" \
  import_set "$ILOG" 'user\.box\.imported\.last=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
check "import: records WHICH box version performed the import (#131)" 0 "" \
  import_set "$ILOG" "user\\.box\\.imported\\.last\\.by=$(cat "$ROOT/VERSION")"
check "import: pins the FIRST trip as its own key (birth pair, rig#61) (#131)" 0 "" \
  import_set "$ILOG" 'user\.box\.imported=[0-9]{4}-'
check "import: ...with the box version that made it (#131)" 0 "" \
  import_set "$ILOG" "user\\.box\\.imported\\.by=$(cat "$ROOT/VERSION")"
check "import: counts the trip — the first one is 1 (#131)" 0 "" \
  import_set "$ILOG" 'user\.box\.imported\.count=1'

# --- the absence assertions: this is the whole point of the issue -----------
# 'origin=import' is the road not taken. 'origin' says how the instance came
# into BEING — mint or clone — and the import is a third, orthogonal fact.
check "import: does NOT overwrite origin — an import is not a coming-into-being (#131)" 1 "" \
  import_set "$ILOG" 'user\.box\.origin='

# The identity is the ONE stamp key this path rewrites (#181), and it is not an
# exception to "the artifact's truth survives": an id is not a fact about the
# artifact but about a box on a host, and the box this one was exported from
# may still be running — quite possibly on this same host, which is what the
# MAC regeneration already exists to survive. Importing is minting.
check "import: re-mints the id — importing is minting (#181)" 0 "" \
  import_set "$ILOG" 'user\.box\.id=[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}'
check "import: ...so the artifact's id does not survive the trip (#181)" 1 "" \
  import_set "$ILOG" 'user\.box\.id=11111111-1111-4111-8111-111111111111'
# It rides the same pre-start 'config set' as the import record, so an imported
# box is never observable wearing the identity of the box it came from.
import_id_precedes_start() {
  local s t
  s="$(grep -n 'config set .*user.box.id=' "$1" | head -1 | cut -d: -f1)"
  t="$(grep -n '^incus start ' "$1" | head -1 | cut -d: -f1)"
  [ -n "$s" ] && [ -n "$t" ] && [ "$s" -lt "$t" ]
}
check "import: the re-mint precedes the start (#181)" 0 "" \
  import_id_precedes_start "$ILOG"
# Degraded, and the same call the clone makes: the artifact's id rode in
# unchallenged, and an id two live boxes share is worse than an id one lacks.
export SHIM_PREFIX="$NOUUID"
NOIDIMP="$IWORK/noid-import.log"
check "import: a host with no UUID source still imports (#181)" 0 "imported work" \
  importbox "$NOIDIMP" "$MINTED_ART"
check "import: ...and unsets the id the artifact carried (#181)" 0 "" \
  grep -qF 'config unset work user.box.id' "$NOIDIMP"
check "import: ...rather than letting two boxes wear one id (#181)" 1 "" \
  import_set "$NOIDIMP" 'user\.box\.id='
check "import: ...and says out loud that this box has no stable id (#181)" 0 "no stable id" \
  importbox "$NOIDIMP" "$MINTED_ART"
unset SHIM_PREFIX
check "import: does NOT restamp the mint time — it is the origin host's (#131)" 1 "" \
  import_set "$ILOG" 'user\.box\.created='
check "import: does NOT restamp the box version that MINTED it (#131)" 1 "" \
  import_set "$ILOG" 'user\.box\.version='
check "import: does NOT restamp the template — lineage rides in the artifact (#131)" 1 "" \
  import_set "$ILOG" 'user\.box\.template='
check "import: does NOT restamp the image the artifact was built on (#131)" 1 "" \
  import_set "$ILOG" 'user\.box\.image'
check "import: does NOT restamp the rig that converged it (#131)" 1 "" \
  import_set "$ILOG" 'user\.box\.rig\.'
# Adding a key is not a breaking change (#103's schema contract), so the schema
# does not move — and is not written here at all: stamping schema=1 onto a
# legacy artifact would claim a mint stamp shape it does not have.
check "import: does NOT touch user.box.schema — adding a key is not breaking (#131)" 1 "" \
  import_set "$ILOG" 'user\.box\.schema'
# Before the start, like the clone re-stamp: an imported box is never
# observable without the record of how it got here. Fail-closed — a missing
# line makes the arithmetic fail, not pass.
import_stamp_precedes_start() {
  local set start
  set="$(grep -n 'config set .* user.box.imported.last=' "$1" | head -1 | cut -d: -f1)"
  start="$(grep -n '^incus start ' "$1" | head -1 | cut -d: -f1)"
  [ -n "$set" ] && [ -n "$start" ] && [ "$set" -lt "$start" ]
}
check "import: the import stamp precedes the start (#131)" 0 "" \
  import_stamp_precedes_start "$ILOG"

# --- a CLONE that was exported and re-imported ------------------------------
# The case that makes 'origin=import' indefensible: it would come back
# claiming to be an import, with nothing left saying it was ever a clone and
# an origin.from pointing at a lineage no key explains.
CLONE_ART="$IWORK/clone-artifact.cfg"
{ grep -v '^user.box.origin ' "$MINTED_ART"
  echo 'user.box.origin clone'
  echo 'user.box.origin.from work/authed'; } > "$CLONE_ART"
CLOG="$IWORK/clone-import.log"
check "import: an exported CLONE imports cleanly (#131)" 0 "imported work" \
  importbox "$CLOG" "$CLONE_ART"
check "import: ...and is still a clone afterwards — origin untouched (#131)" 1 "" \
  import_set "$CLOG" 'user\.box\.origin='
check "import: ...and still names the box it was cloned from (#131)" 1 "" \
  import_set "$CLOG" 'user\.box\.origin\.from'
check "import: ...while still recording that the trip happened (#131)" 0 "" \
  import_set "$CLOG" 'user\.box\.imported\.last='

# --- the second trip: first-wins, last-wins, and a count --------------------
# The artifact of a box that has already been imported twice. Last-wins alone
# would erase the evidence of the first trip, which is the same mistake
# 'origin=import' makes one level up.
TWICE="$IWORK/twice.cfg"
{ cat "$MINTED_ART"
  echo 'user.box.imported 2026-06-15T08:00:00Z'
  echo 'user.box.imported.by 0.7.0'
  echo 'user.box.imported.last 2026-07-01T09:00:00Z'
  echo 'user.box.imported.last.by 0.8.0'
  echo 'user.box.imported.count 2'; } > "$TWICE"
RLOG="$IWORK/reimport.log"
check "re-import: an already-imported artifact imports again (#131)" 0 "imported work" \
  importbox "$RLOG" "$TWICE"
check "re-import: the FIRST trip is pinned, never rewritten (#131)" 1 "" \
  import_set "$RLOG" 'user\.box\.imported=[0-9]'
check "re-import: ...nor is the version that made it (#131)" 1 "" \
  import_set "$RLOG" 'user\.box\.imported\.by='
check "re-import: the LATEST trip IS refreshed (#131)" 0 "" \
  import_set "$RLOG" 'user\.box\.imported\.last=[0-9]{4}-'
check "re-import: ...by this box version (#131)" 0 "" \
  import_set "$RLOG" "user\\.box\\.imported\\.last\\.by=$(cat "$ROOT/VERSION")"
check "re-import: the count advances 2 → 3 (#131)" 0 "" \
  import_set "$RLOG" 'user\.box\.imported\.count=3'
# A count that is not an integer (hand-edited config, a foreign key) must not
# fail an import that has already happened — arithmetic under 'set -e' would.
BADN="$IWORK/badcount.cfg"
{ cat "$MINTED_ART"; echo 'user.box.imported.count not-a-number'; } > "$BADN"
BLOG="$IWORK/badcount.log"
check "re-import: a non-integer count does not fail the import (#131)" 0 "imported work" \
  importbox "$BLOG" "$BADN"
check "re-import: ...it restarts the count rather than inventing a total (#131)" 0 "" \
  import_set "$BLOG" 'user\.box\.imported\.count=1'
# A leading zero is the hole the non-integer fixture CANNOT catch: '08' passes
# an -eq guard (test parses decimal) and then dies in arithmetic, which reads
# it as octal. That abort would land after the physical 'incus import' and
# before the stamp, the placement fix and the start — the exact window the
# degrade-never-die contract exists to protect. A zero-padded count is not
# exotic either: it is what any external tool that formats numbers writes.
ZEROPAD="$IWORK/zeropad.cfg"
{ cat "$MINTED_ART"; echo 'user.box.imported.count 08'; } > "$ZEROPAD"
ZLOG="$IWORK/zeropad.log"
check "re-import: a zero-padded count does not fail the import (#131)" 0 "imported work" \
  importbox "$ZLOG" "$ZEROPAD"
# Counted as decimal 8, not degraded to 0 and not read as octal: '08' is a
# real previous total, so the honest next value is 9.
check "re-import: ...and counts it as decimal, so 08 advances to 9 (#131)" 0 "" \
  import_set "$ZLOG" 'user\.box\.imported\.count=9'

# --- a legacy artifact with no stamp at all ---------------------------------
# A pre-stamp box export, or a hand-rolled 'incus export' of an unmanaged VM.
# It must import cleanly, get the boundary tag, get the import record — and NOT
# acquire a fabricated mint, which is what 'not recorded' exists to say.
LLOG="$IWORK/legacy-import.log"
check "import: a legacy artifact with NO stamp imports cleanly (#131)" 0 "imported work" \
  importbox "$LLOG" /dev/null
check "import: ...it still gets the boundary tag (importing is minting) (#131)" 0 "" \
  grep -qF 'config set work user.box=1' "$LLOG"
check "import: ...and the import record (#131)" 0 "" \
  import_set "$LLOG" 'user\.box\.imported\.last='
check "import: ...but NO invented mint time (#131)" 1 "" \
  import_set "$LLOG" 'user\.box\.created='
check "import: ...and no invented mint version either (#131)" 1 "" \
  import_set "$LLOG" 'user\.box\.version='

# --- the restricted tier's import wall (#160, reported as #156) -------------
# The measured failure: a box exported on the admin tier, imported by a
# restricted user, unpacks to 100% — 1.38GB — and is THEN rejected on
# "volatile.uuid.generation ... in project user-1000 is forbidden". The key is
# incus's own, stamped on every instance it mints; the project is restricted
# because that is what the tier IS. So the whole transfer is spent to learn a
# fact box could read out of the artifact's index.yaml before starting.
#
# This is the round-trip the acceptance shape asks for, taken mocked: the
# export half is already proven above and on the admin tier, and what has
# never been exercised is the way back IN under a restricted identity. The
# fake incus logs every call it receives, so "before the transfer" is asserted
# as the ABSENCE of an 'incus import' line — the strongest form available
# here, and the one that fails if the wall is ever moved below the transfer.
RESTRICTED="$(mktemp -d)"
cat > "$RESTRICTED/id" <<'SHIM'
#!/usr/bin/env bash
# A non-root user in 'incus' and NOT in 'incus-admin' — box_tier()'s restricted
# arm, decided from live credentials exactly as it is on a real host.
case "${1:-}" in
  -u)  echo 1000 ;;
  -nG) echo "boxuser incus" ;;
  -un) echo boxuser ;;
  *)   echo "uid=1000(boxuser) gid=1000(boxuser) groups=1000(boxuser),988(incus)" ;;
esac
SHIM
chmod +x "$RESTRICTED/id"

# An artifact whose index.yaml embeds the instance config, which is where the
# forbidden keys ride. The bare ARTIFACT above carries a name and nothing else
# — deliberately kept, because it is also the no-evidence fixture below.
VM_IDX="$IWORK/vm-index.yaml"
write_import_index "$VM_IDX" instance box-profile
VM_ART="$IWORK/vm-work.tar.gz"
mkdir -p "$IWORK/vmart/backup" && cp "$VM_IDX" "$IWORK/vmart/backup/index.yaml"
tar -czf "$VM_ART" -C "$IWORK/vmart" backup/index.yaml

importfile() {  # importfile <logfile> <artifact> [flags...] — the real box, shimmed
  local log="$1" art="$2"; shift 2
  : > "$log"
  env FAKE_INCUS_LOG="$log" FAKE_CFG="" \
    PATH="${SHIM_PREFIX:+$SHIM_PREFIX:}$ISHIM:$PATH" \
    "$BOX" import "$art" "$@" </dev/null >"$log.out" 2>&1
  local rc=$?
  cat "$log.out"
  return "$rc"
}
# The transfer itself. Every incus call lands in the log, so its absence is
# proof the multi-GB copy never began — not proof that a message was printed.
import_transferred() { grep -qE '^incus import ' "$1"; }

RESTLOG="$IWORK/restricted-import.log"
export SHIM_PREFIX="$RESTRICTED"
check "import: the restricted tier is refused, not left to incus (#160)" 1 \
  "REFUSED BEFORE THE TRANSFER" importfile "$RESTLOG" "$VM_ART"
# The six things D2 requires the refusal to name: the tier, the project, the
# offending key, that nothing was transferred, who can land it, and --force
# with its price. One check each, so a regression names which clause went.
check "import: ...the refusal names the TIER (#160 D2)" 1 "your tier is 'restricted'" \
  importfile "$RESTLOG" "$VM_ART"
check "import: ...and the project the tier puts you in (#160 D2)" 1 "user-1000" \
  importfile "$RESTLOG" "$VM_ART"
check "import: ...the refusal names the KEY incus would have died on (#160 D2)" 1 \
  "volatile.uuid.generation" importfile "$RESTLOG" "$VM_ART"
# The sentence that distinguishes this failure from the reported one: there,
# the whole 1.38GB had landed before incus spoke.
check "import: ...that NOTHING was transferred (#160 D2)" 1 "nothing was transferred" \
  importfile "$RESTLOG" "$VM_ART"
check "import: ...and the WAY OUT — who can land it instead (#160 D2)" 1 "incus-admin" \
  importfile "$RESTLOG" "$VM_ART"
check "import: ...and --force, the override (#160 D2, D3)" 1 "--force" \
  importfile "$RESTLOG" "$VM_ART"
# Priced, not merely offered: --force costs the full transfer and then incus's
# error if the project really does refuse. A message naming the escape hatch
# without its price would sell the very transfer this wall exists to save.
check "import: ...priced honestly rather than merely offered (#160 D2, D3)" 1 \
  "full transfer" importfile "$RESTLOG" "$VM_ART"
# Naming the way out is not the same as inventing one. The admin-side route
# into a restricted project is unmeasured (#160 direction 4), so the message
# says so and hands over no command nobody has run.
check "import: ...and says that route is unmeasured rather than promising it (#160 D2)" 1 \
  "unmeasured" importfile "$RESTLOG" "$VM_ART"
# The absence assertion, ANCHORED. D2 forbids printing an 'incus'/'box'
# command line asserting a route nobody has run, and the readable form of that
# is: no line of the message may begin with a command. Anchoring is what lets
# the message still say 'incus config set' mid-sentence — that names the
# MECHANISM incus applies, and explaining a mechanism is not offering a route.
# An unanchored grep would have to choose between the two, and it would choose
# by banning the explanation, which is the honest half.
check "import: ...offering no command line to run (#160 D2)" 1 "" \
  grep -qE '^box: +(sudo )?(incus|box) ' "$RESTLOG.out"
# And belt-and-braces on the specific incantations an admin-assist route would
# have to be written with, wherever in a line they appear.
check "import: ...naming no admin-assist incantation at all (#160 D2)" 1 "" \
  grep -qE 'incus (import|move|copy|admin) |box (grant|import) |--project' "$RESTLOG.out"
# The whole point of the issue, and the assertion that fails if the wall ever
# drifts below the transfer: incus was never asked to import anything.
check "import: ...BEFORE the transfer — incus import is never reached (#160)" 1 "" \
  import_transferred "$RESTLOG"
# And box never announced a transfer it was about to refuse.
check "import: ...so it never announces an import it will not perform (#160)" 1 "" \
  grep -qF 'box: importing' "$RESTLOG.out"
# EVERY key, not a sample. The keys sort alphabetically and the one incus
# actually died on sorts last of the six this artifact carries, so a head -N
# drops precisely the key the message exists to name. Assert both ends.
check "import: ...listing every key it carries, not a sample (#160)" 1 "volatile.base_image" \
  importfile "$RESTLOG" "$VM_ART"
check "import: ...and counting them (#160)" 1 "carries 6 such keys" \
  importfile "$RESTLOG" "$VM_ART"
# One key is not a special case of six, under 'set -euo pipefail': the
# singular arm is where an '&& noun=key' would end the run on the plural
# branch, silently and mid-message. Drive it, rather than reasoning about it.
ONE_ART="$IWORK/one-key.tar.gz"
mkdir -p "$IWORK/oneart/backup"
printf 'name: work\nconfig:\n  instance:\n    config:\n      volatile.uuid: 8f4a\n' \
  > "$IWORK/oneart/backup/index.yaml"
tar -czf "$ONE_ART" -C "$IWORK/oneart" backup/index.yaml
ONELOG="$IWORK/one-key.log"
check "import: an artifact carrying ONE such key still refuses cleanly (#160)" 1 \
  "carries 1 such key" importfile "$ONELOG" "$ONE_ART"
check "import: ...reaching the end of the message, not dying inside it (#160)" 1 \
  "THE WAY OUT" importfile "$ONELOG" "$ONE_ART"
# No evidence is not evidence of trouble. An artifact whose index.yaml embeds
# no config tells box nothing about what it carries, and refusing there would
# refuse artifacts nothing is known about — so it takes the old path.
BAREREST="$IWORK/bare-restricted.log"
check "import: an artifact with no readable config is NOT refused (#160)" 0 \
  "imported work" importfile "$BAREREST" "$ARTIFACT"
check "import: ...it degrades to the old path rather than guessing (#160)" 0 "" \
  import_transferred "$BAREREST"

# Config that is READ and cleared, which is the stronger half of the same
# point: the fixture above has no config at all, so it proves only that box
# refuses to guess. This one embeds a config section box parses in full and
# finds nothing low-level in — an artifact a restricted project has no reason
# to reject — and it goes through. Without it, a reader that swept up every
# key it saw would still pass every test above.
CLEAN_IDX="$IWORK/clean/backup/index.yaml"
mkdir -p "$IWORK/clean/backup"
cat > "$CLEAN_IDX" <<'IDX'
name: work
backend: dir
pool: default
type: container
config:
  instance:
    architecture: x86_64
    config:
      image.os: Debian
      limits.cpu: "4"
      limits.memory: 4GiB
      user.box: "1"
    devices:
      root:
        path: /
        pool: default
        type: disk
IDX
CLEAN_ART="$IWORK/clean-work.tar.gz"
tar -czf "$CLEAN_ART" -C "$IWORK/clean" backup/index.yaml
CLEANLOG="$IWORK/clean-import.log"
check "import: restricted tier + an artifact with no low-level keys imports (#160)" 0 \
  "imported work" importfile "$CLEANLOG" "$CLEAN_ART"
check "import: ...reaching the transfer like any other (#160)" 0 "" \
  import_transferred "$CLEANLOG"
check "import: ...so the wall is the KEYS and not the tier alone (#160 D1)" 1 "" \
  grep -qF 'REFUSED BEFORE THE TRANSFER' "$CLEANLOG.out"

# --force is the door (#160 D3). It exists because the refusal is an
# INFERENCE — read off the artifact's keys, with only the VM case measured —
# and an inference must never be the last word on a supported tier's own
# file. Same artifact, same tier, same keys as the refusal above: the only
# difference is the flag, so what these assert is the flag and nothing else.
FORCELOG="$IWORK/force-import.log"
check "import: --force skips the pre-flight on the restricted tier (#160 D3)" 0 \
  "imported work" importfile "$FORCELOG" "$VM_ART" --force
check "import: ...and really does reach 'incus import' (#160 D3)" 0 "" \
  import_transferred "$FORCELOG"
check "import: ...printing no refusal it just overrode (#160 D3)" 1 "" \
  grep -qF 'REFUSED BEFORE THE TRANSFER' "$FORCELOG.out"
# -f is the same flag, and the OPTIONS block promises both spellings.
check "import: ...under its short spelling too (#160 D3)" 0 "imported work" \
  importfile "$IWORK/force-short.log" "$VM_ART" -f
# The door swings one way. --force does not disable the wall for the next
# import, and it is not a mode: re-run without it and the refusal is back.
check "import: ...leaving the wall standing for the next import (#160 D3)" 1 \
  "REFUSED BEFORE THE TRANSFER" importfile "$RESTLOG" "$VM_ART"
unset SHIM_PREFIX

# The wall is tier-scoped, and this is what stops it becoming an import ban:
# the SAME artifact, same keys, on the admin tier, goes through.
ADMINLOG="$IWORK/admin-import.log"
check "import: the admin tier imports that same artifact (#160)" 0 "imported work" \
  importfile "$ADMINLOG" "$VM_ART"
check "import: ...and its transfer really does start (#160)" 0 "" \
  import_transferred "$ADMINLOG"
check "import: ...with no restricted-tier refusal anywhere in sight (#160)" 1 "" \
  grep -qF 'REFUSED BEFORE THE TRANSFER' "$ADMINLOG.out"

# Ordering, asserted against the source too: a runtime absence proves the wall
# fired on THIS fixture, and this proves it cannot be reordered under one that
# does not. Same shape as the collision guard's assertion above.
# shellcheck disable=SC2016  # the $-strings are literals inside bash -c
check "import: the wall precedes 'incus import' in cmd_import (#160)" 0 "" bash -c '
  fn="$(awk "/^cmd_import\(\) \{/,/^\}/" "'"$ROOT"'/bin/box")"
  wall="$(printf "%s\n" "$fn" | grep -n "artifact_lowlevel_keys" | head -1 | cut -d: -f1)"
  run="$(printf "%s\n" "$fn" | grep -n "incus import" | head -1 | cut -d: -f1)"
  [ -n "$wall" ] && [ -n "$run" ] && [ "$wall" -lt "$run" ]'

# The key reader on its own. It decides what the wall refuses, so it is worth
# proving it reads the artifact's keys and not merely something shaped like a
# key: a restricted project blocks the low-level namespaces and nothing else,
# and a reader that swept up ordinary config would refuse every artifact for
# the wrong reason.
LLKEYS="$(mktemp)"
awk '/^artifact_lowlevel_keys\(\) \{/,/^\}/' "$BOX" > "$LLKEYS"
check "import: the key reader was extracted (guards the awk)" 0 "volatile" cat "$LLKEYS"
check "import: the extracted key reader is valid bash" 0 "" bash -n "$LLKEYS"
lowlevel_keys() { bash -c '. "$0"; artifact_lowlevel_keys' "$LLKEYS" < "$1"; }
lowlevel_has() { lowlevel_keys "$1" | grep -qE "$2"; }
check "import: the key reader finds the key incus refused (#160)" 0 "" \
  lowlevel_has "$VM_IDX" '^volatile\.uuid\.generation$'
check "import: ...and the rest of the volatile set with it (#160)" 0 "" \
  lowlevel_has "$VM_IDX" '^volatile\.eth0\.hwaddr$'
check "import: ...but not config a restricted project allows (#160)" 1 "" \
  lowlevel_has "$VM_IDX" '^image\.os$'
check "import: ...nor the limits an operator legitimately sets (#160)" 1 "" \
  lowlevel_has "$VM_IDX" '^limits\.'
# 'raw.*' is the other low-level namespace a restricted project blocks. No box
# artifact carries it today; a hand-rolled export can, and the wall should not
# have to be rediscovered when one does.
RAW_IDX="$IWORK/raw-index.yaml"
printf 'name: work\nconfig:\n  instance:\n    config:\n      raw.qemu: -smbios foo\n' > "$RAW_IDX"
check "import: the key reader also catches the raw.* namespace (#160)" 0 "" \
  lowlevel_has "$RAW_IDX" '^raw\.qemu$'
# An index with no config section yields nothing at all — the silent degrade
# above, at the level of the reader rather than the command.
check "import: an index with no config yields no keys (#160)" 1 "" \
  lowlevel_has "$IWORK/backup/index.yaml" '.'
rm -f "$LLKEYS"

# The help says so before you spend the transfer to find out.
check "help import warns the restricted tier off (#160)" 0 "ON THE RESTRICTED TIER" \
  "$BOX" help import
check "help import names the key class, not just the tier (#160)" 0 "volatile" \
  "$BOX" help import
check "help import keeps export one-way rather than implying parity (#160)" 0 "Export still works" \
  "$BOX" help import
# The override is documented where it is used and where it is listed, and in
# both places with its price. A flag a user only ever meets in an error
# message is a flag they meet at the worst possible moment.
check "help import documents --force (#160 D3)" 0 "--force overrides that refusal" \
  "$BOX" help import
check "help import prices it there too, not just in the refusal (#160 D3)" 0 \
  "pay the whole transfer" "$BOX" help import
check "the OPTIONS block lists --force for import (#160 D3)" 0 \
  "pre-flight refusal (import)" "$BOX" help

# --- the read half: 'box info' must not let the mint be misread -------------
# The whole hazard: MINTED carries a time that is deliberately NOT this host's,
# and a reader who meets it alone will take it for one. The IMPORTED line sits
# directly under it and states the only thing box actually knows — the
# ORDERING. It does not claim another host: a box can be exported and
# re-imported onto the SAME host (#66's upgrade advice), and nothing records
# which host minted it.
IMPCFG="$MWORK/imported.cfg"
{ cat "$STAMPED"
  echo 'user.box.imported 2026-07-20T09:14:03Z'
  echo 'user.box.imported.by 0.8.1'
  echo 'user.box.imported.last 2026-07-20T09:14:03Z'
  echo 'user.box.imported.last.by 0.8.1'
  echo 'user.box.imported.count 1'; } > "$IMPCFG"
check "info: surfaces when the box arrived, and by which box (#131)" \
  0 "IMPORTED   2026-07-20T09:14:03Z by box 0.8.1" infobox "$IMPCFG"
check "info: ...and says the mint above is NOT this arrival (#131)" \
  0 "the mint above predates it" infobox "$IMPCFG"
check "info: ...while the artifact's mint time still reads unchanged (#131)" \
  0 "MINTED     2026-07-19T14:22:07Z by box 0.8.0" infobox "$IMPCFG"
# It must not invent a location for the mint — box has no record of one.
check "info: ...and never claims the mint happened on another host (#131)" 1 "" \
  info_has "$IMPCFG" 'another host|elsewhere|remote host'
# A single trip prints ONE line: both pairs hold the same values and a
# 'first was...' continuation would be noise.
check "info: a single import prints no redundant 'first was' line (#131)" 1 "" \
  info_has "$IMPCFG" 'the first was'

# A box that made the trip more than once shows both ends and the count.
IMPCFG2="$MWORK/imported-twice.cfg"
{ cat "$STAMPED"
  echo 'user.box.imported 2026-06-15T08:00:00Z'
  echo 'user.box.imported.by 0.7.0'
  echo 'user.box.imported.last 2026-07-20T09:14:03Z'
  echo 'user.box.imported.last.by 0.8.1'
  echo 'user.box.imported.count 3'; } > "$IMPCFG2"
check "info: a repeat traveller shows the latest trip (#131)" \
  0 "IMPORTED   2026-07-20T09:14:03Z by box 0.8.1" infobox "$IMPCFG2"
check "info: ...and the first one, with the count (#131)" \
  0 "import 3 — the first was 2026-06-15T08:00:00Z by box 0.7.0" infobox "$IMPCFG2"

# An imported CLONE reads as a clone that also travelled — the two facts sit
# side by side, neither having eaten the other.
IMPCLONE="$MWORK/imported-clone.cfg"
# mode.asked is dropped, not merely unasserted: since #129 the clone path
# clears it (nobody asked THIS box anything), so a fixture built from the mint
# shape that kept the key would describe a box the clone path cannot produce.
# No assertion here reads it — which is exactly why it would rot unnoticed.
{ grep -v '^user.box.origin ' "$IMPCFG" | grep -v '^user.box.mode.asked '
  echo 'user.box.origin clone'
  echo 'user.box.origin.from work/authed'; } > "$IMPCLONE"
check "info: an imported clone is still a clone (#131)" \
  0 "ORIGIN     clone of work/authed" infobox "$IMPCLONE"
check "info: ...and still says it was imported (#131)" 0 "IMPORTED" infobox "$IMPCLONE"

# A box that was never imported says nothing at all — no empty IMPORTED line,
# the same rule every other key in the block follows.
check "info: a never-imported box prints no IMPORTED line (#131)" 1 "" \
  info_has "$STAMPED" '^IMPORTED'
# And a legacy box with no stamp whatsoever still reads as 'not recorded'.
check "info: a stampless box still says the mint was not recorded (#131)" \
  0 "predates the mint stamp" infobox "$LEGACY"
check "info: ...and prints no IMPORTED line for a key it does not have (#131)" 1 "" \
  info_has "$LEGACY" '^IMPORTED'

check "help import: names the import record it writes (#131)" 0 "import EVENT" \
  "$BOX" help import
check "help import: says the mint stamp is NOT rewritten (#131)" 0 "does not overwrite" \
  "$BOX" help import
# The help is where an operator meets the id, and 'rename' is where they need
# it: the verb's own text is what says the name is an alias and the id is not.
check "help rename: says the id follows the box (#181)" 0 "user.box.id" \
  "$BOX" help rename
check "help info: says the id outlives a rename (#181)" 0 "outlives a rename" \
  "$BOX" help info
check "help import: names the fresh id it draws (#181)" 0 "fresh box id" \
  "$BOX" help import

# --- #241: refuse the known pre-0.10.0 placement boundary ourselves ---------
# The known former name is read from container.profiles in the artifact, and
# it is refused before require_stack or incus import can offer the wrong fix.
CONVLOG="$IWORK/converged.log"
check "import: box refuses a pre-rename artifact itself (#241)" 1 \
  "artifact was exported by a box release that used 'box-net'" \
  importbox "$CONVLOG" "$MINTED_ART" box-net box-profile

# The measured #160 fixture used config.instance while current Incus marshals
# config.container. Both are instance-record spellings at the same nesting;
# keep the compatibility explicit rather than letting only one fixture shape
# exercise the parser.
INSTANCE_OLD_ART="$IWORK/instance-old-profile.tar.gz"
mkdir -p "$IWORK/instance-old/backup"
write_import_index "$IWORK/instance-old/backup/index.yaml" instance box-net
tar -czf "$INSTANCE_OLD_ART" -C "$IWORK/instance-old" backup/index.yaml
check "import: ...also reads the measured config.instance shape (#241)" 1 \
  "artifact was exported by a box release that used 'box-net'" \
  importfile "$IWORK/instance-old.log" "$INSTANCE_OLD_ART"

# Embedded profile definitions are config.profiles, a sibling of the
# instance-use list. A stale definition alone says nothing about what the
# artifact uses and must not trigger the release-boundary refusal.
DEFINITION_OLD_ART="$IWORK/definition-only-old-profile.tar.gz"
mkdir -p "$IWORK/definition-old/backup"
write_import_index "$IWORK/definition-old/backup/index.yaml" \
  container box-profile "box-profile box-net"
tar -czf "$DEFINITION_OLD_ART" -C "$IWORK/definition-old" backup/index.yaml
check "import: an embedded box-net definition alone does not trigger (#241)" 0 \
  "imported work" importfile "$IWORK/definition-old.log" "$DEFINITION_OLD_ART"
check "import: ...because only the instance-use list is the boundary" 1 "" \
  grep -qF "used 'box-net'" "$IWORK/definition-old.log.out"
check "import: ...names the 0.10.0 boundary and unsupported migration" 1 \
  "0.10.0 renamed that profile to 'box-profile'" \
  importbox "$CONVLOG" "$MINTED_ART" box-net box-profile
check "import: ...says to re-create the box" 1 \
  "Re-create the box on this host" \
  importbox "$CONVLOG" "$MINTED_ART" box-net box-profile
check "import: ...names the unsupported manual recovery route" 1 \
  "create 'box-net' transiently" \
  importbox "$CONVLOG" "$MINTED_ART" box-net box-profile
check "import: ...fires before require_stack can offer setup-host" 1 \
  "artifact was exported by a box release" \
  importbox "$CONVLOG" "$MINTED_ART" box-net box-profile 0
check "import: ...does not offer setup-host as the fix" 1 "" \
  grep -qF 'the host stack is missing. Build it: box setup-host' "$CONVLOG.out"
check "import: ...never hands the artifact to incus" 1 "" \
  grep -qF 'incus import' "$CONVLOG"

PROJECT_STATE="$IWORK/project.state"
printf 'profile=box-profile\ninstance-count=0\n' > "$PROJECT_STATE"
cp "$PROJECT_STATE" "$PROJECT_STATE.before"
FAKE_PROJECT_STATE="$PROJECT_STATE" \
  importbox "$CONVLOG" "$MINTED_ART" box-net box-profile >/dev/null 2>&1 || true
check "import: ...leaves the destination project byte-identical (#241 D4)" 0 "" \
  cmp "$PROJECT_STATE.before" "$PROJECT_STATE"

# --force is the manual route: if an admin has created the former name, incus
# can admit the artifact and box's existing placement branch re-homes it.
OLDLOG="$IWORK/oldname.log"
check "import: --force admits the manual old-profile recovery route (#241)" 0 \
  "re-homed onto the box-profile profile" \
  importbox "$OLDLOG" "$MINTED_ART" box-net "box-profile box-net" 1 --force
check "import: ...uses the existing profile assignment" 0 "" \
  grep -qF 'profile assign work box-profile' "$OLDLOG"

# A profile box has never used is not this version-boundary diagnosis. It
# reaches incus, whose own missing-profile error remains the right answer.
UNKNOWNLOG="$IWORK/unknown-profile.log"
check "import: an unknown profile still gets incus's own error (#241 D5)" 1 \
  "Failed loading profiles (other-profile) for instance" \
  importbox "$UNKNOWNLOG" "$MINTED_ART" other-profile box-profile
check "import: ...is not mislabeled as the box-net boundary" 1 "" \
  grep -qF "used 'box-net'" "$UNKNOWNLOG.out"
# The other side of the same branch: an artifact already on the contract is
# left alone, so 're-home' is a response to a mismatch and not something every
# import does.
check "import: an artifact already on the contract is not re-homed" 1 "" \
  grep -qF 'profile assign' "$ILOG"

rm -rf "$ISHIM" "$IWORK"

rm -rf "$MSHIM" "$MWORK"

# The rehearsal itself stays runnable: syntax-checked here, run on real hosts.
check "multiuser.sh is valid bash" 0 "" bash -n "$ROOT/drill/multiuser.sh"
check "multiuser.sh refuses without the env gate" 2 "opt in" \
  bash "$ROOT/drill/multiuser.sh" --yes
check "grant-user.sh is valid bash"  0 "" bash -n "$ROOT/host/grant-user.sh"
check "revoke-user.sh is valid bash" 0 "" bash -n "$ROOT/host/revoke-user.sh"
check "teardown-host.sh is valid bash" 0 "" bash -n "$ROOT/host/teardown-host.sh"

# ---------------------------------------------------------------------------
# Revoke leaves NOTHING (the grant/revoke cleanliness pass). The gap this
# closes: --purge removed /var/lib/incus/users/<uid> but never RE-CHECKED it —
# the one path its own absence assert did not cover. And the stat must ride
# $SUDO: /var/lib/incus is not traversable by a non-root admin, so a bare
# [ -d ] answers "absent" for a directory that is very much there.
# ---------------------------------------------------------------------------
check "revoke: purge removes the incus-user state directory" 0 "" \
  grep -qF '/var/lib/incus/users/' "$ROOT/host/revoke-user.sh"
check "revoke: the absence assert covers the incus-user state too" 0 "" \
  bash -c 'awk "/Assert absence/,0" "'"$ROOT"'/host/revoke-user.sh" | grep -q "/var/lib/incus/users/"'
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "revoke: the state checks go through \$SUDO test (an unprivileged stat lies)" 0 "" \
  grep -qF '$SUDO test -d "/var/lib/incus/users/$uid"' "$ROOT/host/revoke-user.sh"

# ---------------------------------------------------------------------------
# The #80 guard and BOX_SUBNET. setup-host run inside a box used to build a
# nested boxnet on the guest's own uplink subnet — captured gateway, duplicate
# routes, intermittent egress blackouts. The guard's two pure functions are
# extracted and DRIVEN (a shim ip serves canned route tables, the same seam as
# the shim id), and then the WHOLE script is driven end to end under shims:
# the refusal paths must exit 1 having touched nothing (the incus/sudo shims
# log every call, and the log must not exist), the converge path must still
# run, and BOX_SUBNET must plumb through to every derived value.
# ---------------------------------------------------------------------------
cat > "$SHIMDIR/ip" <<'SHIM'
#!/usr/bin/env bash
# Fake `ip`: canned tables for the #80 guard and signature — just the reads
# setup-host and doctor make. Specific patterns first: case takes the first hit.
case "$*" in
  "-4 -o addr show dev boxnet") printf '%s\n' "${FAKE_IP4_BOXNET:-}" ;;
  "-4 route show default")      printf '%s\n' "${FAKE_IP4_DEFAULT:-}" ;;
  "-4 route show")              printf '%s\n' "${FAKE_IP4_ROUTES:-}" ;;
  "-4 -o addr show")            printf '%s\n' "${FAKE_IP4_ADDRS:-}" ;;
esac
exit 0
SHIM
chmod +x "$SHIMDIR/ip"

# The route tables, verbatim from issue #80's capture (the poisoned guest) and
# from the states around it.
D_INBOX='default via 10.88.0.1 dev enp5s0 proto dhcp src 10.88.0.202 metric 1024'
D_LAN='default via 192.168.1.1 dev eno1 proto dhcp metric 100'
A_GUEST='2: enp5s0    inet 10.88.0.202/24 metric 1024 brd 10.88.0.255 scope global dynamic enp5s0'
A_HOSTSTACK='2: eno1    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic eno1
5: boxnet    inet 10.88.0.1/24 scope global boxnet'
A_FOREIGN='2: eno1    inet 192.168.1.50/24 brd 192.168.1.255 scope global dynamic eno1
3: virbr7    inet 10.88.0.7/24 brd 10.88.0.255 scope global virbr7'

SUBFN="$(mktemp)"
awk '/^valid_subnet\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$SUBFN"
check "valid_subnet: extracted from setup-host.sh (guards the awk)" 0 "return 1" cat "$SUBFN"
check "valid_subnet: the extracted function is valid bash" 0 "" bash -n "$SUBFN"
vsub() { bash -c ". '$SUBFN'; valid_subnet \"\$1\"" _ "$1"; }
check "valid_subnet: the default is valid"                 0 "" vsub 10.88.0.0/24
check "valid_subnet: the documented escape hatch is valid" 0 "" vsub 10.89.0.0/24
check "valid_subnet: any a.b.c.0/24 is valid"              0 "" vsub 192.168.7.0/24
check "valid_subnet: not-a-/24 is refused"                 1 "" vsub 10.88.0.0/16
check "valid_subnet: a nonzero host octet is refused"      1 "" vsub 10.88.0.5/24
check "valid_subnet: an octet past 255 is refused"         1 "" vsub 300.88.0.0/24
check "valid_subnet: a bare address is refused"            1 "" vsub 10.88.0.0
check "valid_subnet: garbage is refused"                   1 "" vsub banana
check "valid_subnet: an empty value is refused"            1 "" vsub ""
rm -f "$SUBFN"

CLMFN="$(mktemp)"
awk '/^subnet_claimant\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$CLMFN"
check "subnet_claimant: extracted from setup-host.sh (guards the awk)" 0 "DEFAULT GATEWAY" cat "$CLMFN"
check "subnet_claimant: the extracted function is valid bash" 0 "" bash -n "$CLMFN"
claim() { # claim <subnet> <default-route> <addrs>
  FAKE_IP4_DEFAULT="$2" FAKE_IP4_ADDRS="$3" PATH="$SHIMDIR:$PATH" \
    bash -c ". '$CLMFN'; subnet_claimant \"\$1\"" _ "$1"
}
check "claimant: the default gateway inside the target is the smoking gun" \
  0 "DEFAULT GATEWAY" claim 10.88.0.0/24 "$D_INBOX" "$A_GUEST"
check "claimant: a foreign interface inside the target is named" \
  0 "virbr7" claim 10.88.0.0/24 "$D_LAN" "$A_FOREIGN"
check "claimant: boxnet's own prior claim is the converge path — CLEAN" \
  1 "" claim 10.88.0.0/24 "$D_LAN" "$A_HOSTSTACK"
check "claimant: a free subnet is clean" \
  1 "" claim 10.89.0.0/24 "$D_LAN" "$A_HOSTSTACK"
check "claimant: 10.8.0.0/24 does not prefix-match 10.88.x (the dot terminates)" \
  1 "" claim 10.8.0.0/24 "$D_INBOX" "$A_GUEST"
rm -f "$CLMFN"

# --- choose_subnet: the four-case decision, driven case by case -------------
# 1 explicit pin: honored or refused, never overridden. 2 no pin + bridge:
# converge to the bridge (the bridge IS the pin) — the scan never runs with a
# bridge present. 3 no pin, no bridge, default free: default. 4 default
# claimed: scan 10.89…10.127, first free wins, loudly; refuse when all claimed.
PICKFN="$(mktemp)"
awk '/^(valid_subnet|subnet_claimant|choose_subnet)\(\) \{/,/^\}/' \
  "$ROOT/host/setup-host.sh" > "$PICKFN"
check "choose_subnet: extracted with its helpers (guards the awk)" 0 "auto-picked" cat "$PICKFN"
check "choose_subnet: subnet_claimant came along" 0 "DEFAULT GATEWAY" cat "$PICKFN"
check "choose_subnet: the extracted functions are valid bash" 0 "" bash -n "$PICKFN"
pick() { # pick <pin> <default-route> <addrs> [boxnet-addr]
  FAKE_IP4_DEFAULT="$2" FAKE_IP4_ADDRS="$3" FAKE_IP4_BOXNET="${4:-}" PATH="$SHIMDIR:$PATH" \
    bash -c ". '$PICKFN'; choose_subnet \"\$1\"" _ "$1"
}
pickout()   { pick "$@" 2>/dev/null; }          # stdout only: the choice itself
pickquiet() { [ -z "$(pick "$@" 2>&1 >/dev/null)" ]; }  # stderr must be EMPTY
picknoscan(){ ! pick "$@" 2>&1 | grep -qF auto-picked; }

# The bridge lines and the both-claimed / all-claimed address tables.
B_88='5: boxnet    inet 10.88.0.1/24 scope global boxnet'
B_89='5: boxnet    inet 10.89.0.1/24 scope global boxnet'
A_TWOCLAIM="$A_GUEST
3: virbr7    inet 10.89.0.7/24 brd 10.89.0.255 scope global virbr7"
A_ALLCLAIM="$(for b in $(seq 88 127); do
  printf '%d: virbr%d    inet 10.%d.0.7/24 brd 10.%d.0.255 scope global virbr%d\n' \
    "$((b - 85))" "$((b - 87))" "$b" "$b" "$((b - 87))"
done)"

# Case 1 — the pin. Refusals identical in spirit to the pre-autopick gate.
check "pick: pinned + gw-in-subnet REFUSES, names issue #80" \
  1 "issue #80" pick 10.88.0.0/24 "$D_INBOX" "$A_GUEST"
check "pick: pinned + foreign interface REFUSES, names it" \
  1 "virbr7" pick 10.88.0.0/24 "$D_LAN" "$A_FOREIGN"
check "pick: a pinned refusal still names BOX_SUBNET" \
  1 "BOX_SUBNET" pick 10.88.0.0/24 "$D_INBOX" "$A_GUEST"
check "pick: pinned against a disagreeing bridge REFUSES (never re-addresses)" \
  1 "never re-addresses" pick 10.88.0.0/24 "$D_LAN" "$A_HOSTSTACK" "$B_89"
check "pick: a garbage pin is refused by name" \
  1 "not a sane subnet" pick banana "$D_LAN" "$A_HOSTSTACK"
check "pick: a pin that clears the gate is used verbatim" \
  0 "10.89.0.0/24" pickout 10.89.0.0/24 "$D_INBOX" "$A_GUEST"
check "pick: ...silently — a pin is the operator talking, not us" \
  0 "" pickquiet 10.89.0.0/24 "$D_INBOX" "$A_GUEST"

# Case 2 — no pin, a bridge: converge to ITS subnet. No refusal, no scan —
# even when the default is claimed (THIS machine: nested stack, uplink on
# 10.88, bridge remapped to 10.89 — the #80 workaround host, bare re-run).
check "pick: bridge present converges to the bridge's own subnet" \
  0 "10.89.0.0/24" pickout "" "$D_INBOX" "$A_GUEST
$B_89" "$B_89"
check "pick: ...announcing the convergence (an off-default bridge is worth a line)" \
  0 "converging" pick "" "$D_INBOX" "$A_GUEST
$B_89" "$B_89"
check "pick: ...and the scan never ran (case 2 precedes case 4)" \
  0 "" picknoscan "" "$D_INBOX" "$A_GUEST
$B_89" "$B_89"
check "pick: bridge on the DEFAULT subnet converges silently (plain re-run)" \
  0 "" pickquiet "" "$D_LAN" "$A_HOSTSTACK" "$B_88"
check "pick: ...to the default" \
  0 "10.88.0.0/24" pickout "" "$D_LAN" "$A_HOSTSTACK" "$B_88"
# The poisoned state (#80 verbatim: bridge AND uplink both on 10.88) must not
# converge — rebuilding there re-arms the blackouts. Refuse, name the fix.
check "pick: a bridge on a FOREIGN-claimed subnet refuses (the poisoned state)" \
  1 "poisoned" pick "" "$D_INBOX" "$A_GUEST
$B_88" "$B_88"
check "pick: ...naming the bridge move as the fix" \
  1 "ipv4.address" pick "" "$D_INBOX" "$A_GUEST
$B_88" "$B_88"

# Case 3 — no pin, no bridge, default free: the default, silently.
check "pick: a free default host gets 10.88.0.0/24" \
  0 "10.88.0.0/24" pickout "" "$D_LAN" ""
check "pick: ...with no announcement" 0 "" pickquiet "" "$D_LAN" ""

# Case 4 — no pin, no bridge, default claimed: the nested case. First free
# candidate wins, the announcement names the claimant and the pin.
check "pick: default claimed by the gateway auto-picks 10.89.0.0/24" \
  0 "10.89.0.0/24" pickout "" "$D_INBOX" "$A_GUEST"
check "pick: ...saying so loudly" \
  0 "auto-picked 10.89.0.0/24" pick "" "$D_INBOX" "$A_GUEST"
check "pick: ...naming WHY (the machine's own gateway = inside a box)" \
  0 "DEFAULT GATEWAY" pick "" "$D_INBOX" "$A_GUEST"
check "pick: ...and how to pin it for scripts" \
  0 "BOX_SUBNET=10.89.0.0/24" pick "" "$D_INBOX" "$A_GUEST"
check "pick: default AND 10.89 claimed skips to 10.90.0.0/24" \
  0 "10.90.0.0/24" pickout "" "$D_INBOX" "$A_TWOCLAIM"
check "pick: every candidate claimed → the old refusal" \
  1 "refusing to build boxnet" pick "" "$D_LAN" "$A_ALLCLAIM"
check "pick: ...naming the end of the scan range" \
  1 "10.127.0.0/24" pick "" "$D_LAN" "$A_ALLCLAIM"
check "pick: ...and BOX_SUBNET as the way out" \
  1 "BOX_SUBNET" pick "" "$D_LAN" "$A_ALLCLAIM"
rm -f "$PICKFN"

# --- the whole script, driven: refuse-before-mutation, converge, plumb-through
SETUPSHIM="$(mktemp -d)"
cat > "$SETUPSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the driven setup-host: records every call (and, for the
# stdin verbs, the stdin) to $FAKE_INCUS_LOG, answers the existence probes
# from FAKE_HAVE_*, and never goes near a daemon.
[ -n "${FAKE_INCUS_LOG:-}" ] && printf 'incus %s\n' "$*" >> "$FAKE_INCUS_LOG"
case "$*" in
  *"admin init --preseed"*|*"acl edit"*|*"profile edit"*)
    if [ -n "${FAKE_INCUS_LOG:-}" ]; then sed 's/^/  | /' >> "$FAKE_INCUS_LOG"; else cat >/dev/null; fi ;;
esac
# The #229 convergence is the first thing setup-host says in project scope, so
# the shim learns the '--project <name>' prefix here and every pattern below
# stays written in the bare form the rest of the script uses. Logged above
# first, so the assertions still read the exact command line that was sent.
proj=default
if [ "${1:-}" = --project ]; then proj="$2"; shift 2; fi
# 'project list' is answered ABOVE the stateful profile store, because the
# question it has to be able to pose belongs to both halves: FAKE_PROJECT_LIST_FAIL
# is a daemon that refuses to answer — non-zero, nothing on stdout — which is
# not the same host as one with no grants. Unset, it answers what a working
# daemon on a grant-less host says: 'default (current)', never an empty stream.
# A test that wants the empty one asks for it with FAKE_PROJECTS= (#229 round 2).
# FAKE_PROJECT_LIST_PARTIAL is the third answer, and the one neither of the
# other two can stand in for: a row on stdout and a non-zero exit after it. A
# condition that reads emptiness alone passes it, so it is what keeps the
# status check in this file's 'if' from being deleted as redundant (#229 round 3).
case "$*" in
  "project list --format csv")
    [ -z "${FAKE_PROJECT_LIST_FAIL:-}" ] || { echo "Error: not authorized" >&2; exit 1; }
    [ -z "${FAKE_PROJECT_LIST_PARTIAL:-}" ] || {
      printf 'default (current)\n'; echo "Error: connection reset" >&2; exit 1; }
    printf '%s\n' "${FAKE_PROJECTS-default (current)}" ; exit 0 ;;
esac
# The profile store is STATEFUL, and only when FAKE_PROFILE_STATE says so —
# every case that predates #229 leaves it unset and keeps answering from
# FAKE_HAVE_*. It has to be stateful because the claims under test are "the
# old name is gone after", "the second run is a no-op" and "every project,
# not just default", and none of those can be read off a log of calls made
# against a store that never changes. Incus's own two refusals are modelled:
# a rename onto an existing name fails (cmd/incusd/profiles.go), and an
# in-use profile cannot be deleted.
if [ -n "${FAKE_PROFILE_STATE:-}" ]; then
  pf() { printf '%s/%s.%s' "$FAKE_PROFILE_STATE" "$proj" "$1"; }
  case "$*" in
    "profile show "*)   [ -f "$(pf "$3")" ] || exit 1 ; exit 0 ;;
    "profile create "*) : > "$(pf "$3")" ; exit 0 ;;
    "profile rename "*)
      # The daemon that simply errors. Incus's own two refusals are below and
      # are modelled from its source; this one models neither, and exists for
      # the one window they cannot reach — a rename failing after the delete
      # that freed its target name (#229 round 2).
      [ -z "${FAKE_RENAME_FAIL:-}" ] || { echo "Error: rename failed" >&2; exit 1; }
      [ -f "$(pf "$3")" ] || exit 1
      if [ -f "$(pf "$4")" ]; then
        echo "Error: Profile \"$4\" already exists" >&2; exit 1
      fi
      mv "$(pf "$3")" "$(pf "$4")" ; exit 0 ;;
    "profile delete "*)
      # In-use is PER PROFILE, not per store: the convergence's whole question
      # is which of the two names something is placed on, and a shim that
      # refuses every delete alike cannot pose it (#229, round 1).
      case " ${FAKE_PROFILES_IN_USE:-} " in
        *" $3 "*) echo "Error: Profile \"$3\" is currently in use" >&2; exit 1 ;;
      esac
      rm -f "$(pf "$3")" ; exit 0 ;;
  esac
fi
case "$*" in
  "storage show default")         [ -n "${FAKE_HAVE_STORAGE:-}" ] || exit 1 ;;
  # The live pool's placement (#180): FAKE_POOL_SOURCE unset answers the way a
  # pool whose source was never recorded does — an empty line, not a refusal.
  "storage get default source")   printf '%s\n' "${FAKE_POOL_SOURCE:-}" ;;
  # ...and the source Incus was HANDED, which for a block device is not the one
  # above: btrfs formats the device and overwrites 'source' with the new
  # filesystem's UUID. Unset answers as a 'dir' pool does — this key absent.
  "storage get default volatile.initial_source")
                                  printf '%s\n' "${FAKE_POOL_INITIAL_SOURCE:-}" ;;
  *"admin init --preseed"*)       [ -z "${FAKE_PRESEED_FAIL:-}" ] || exit 1 ;;
  # 'show' answers with the network's yaml, which is where used_by lives — the
  # read that decides whether ipv4.address may be converged at all (#227). An
  # existence probe that wants no body just leaves FAKE_BOXNET_SHOW unset.
  "network show boxnet")          [ -n "${FAKE_HAVE_BOXNET:-}" ]  || exit 1
                                  printf '%s\n' "${FAKE_BOXNET_SHOW:-}" ;;
  "network get boxnet ipv4.address") printf '%s\n' "${FAKE_BOXNET_IPV4:-}" ;;
  "network acl show box-isolate") [ -n "${FAKE_HAVE_ACL:-}" ]     || exit 1 ;;
  "profile show box-profile")         [ -n "${FAKE_HAVE_PROFILE:-}" ] || exit 1 ;;
esac
exit 0
SHIM
cat > "$SETUPSHIM/sudo" <<'SHIM'
#!/usr/bin/env bash
# Fake sudo: logs to $FAKE_SUDO_LOG and swallows everything — the driven
# setup-host must never mutate the machine running this suite.
[ -n "${FAKE_SUDO_LOG:-}" ] && printf 'sudo %s\n' "$*" >> "$FAKE_SUDO_LOG"
exit 0
SHIM
cat > "$SETUPSHIM/lsblk" <<'SHIM'
#!/usr/bin/env bash
# Fake lsblk: what filesystem UUID does the requested path hold RIGHT NOW
# (#180, panel round 3)? FAKE_DEV_UUID answers for the device named in
# FAKE_DEV_UUID_FOR (default /dev/sdb); every other path, and an unset
# FAKE_DEV_UUID, exit non-zero with no output — the way lsblk answers for a
# path that is not a block device. Without this shim the matcher could not be
# contradicted, which is how the class it guards survived two rounds.
[ -n "${FAKE_INCUS_LOG:-}" ] && printf 'lsblk %s\n' "$*" >> "$FAKE_INCUS_LOG"
dev="${*: -1}"
[ -n "${FAKE_DEV_UUID:-}" ] || exit 32
[ "$dev" = "${FAKE_DEV_UUID_FOR:-/dev/sdb}" ] || exit 32
printf '%s\n' "$FAKE_DEV_UUID"
SHIM
chmod +x "$SETUPSHIM/incus" "$SETUPSHIM/sudo" "$SETUPSHIM/lsblk"

runsetup() { # runsetup [VAR=val ...] — the real setup-host, under shims
  env FAKE_UID=1000 FAKE_GROUPS="users incus-admin" \
      PATH="$SETUPSHIM:$SHIMDIR:$PATH" "$@" bash "$ROOT/host/setup-host.sh"
}

W80="$(mktemp -d)"
# Refusal 1: an EXPLICIT pin on the subnet the default gateway sits inside —
# the inside of a box, and the operator said 10.88 out loud. A pin is never
# silently overridden, so this refuses exactly as it did pre-autopick.
check "setup-host: a pinned gw-claimed subnet REFUSES and names issue #80" 1 "issue #80" \
  runsetup BOX_SUBNET=10.88.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W80/g1.log" FAKE_SUDO_LOG="$W80/s1.log"
check "setup-host: ...naming BOX_SUBNET as the way out" 1 "BOX_SUBNET" \
  runsetup BOX_SUBNET=10.88.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: the refusal made NO incus call (refuse precedes mutation)" 1 "" \
  test -e "$W80/g1.log"
check "setup-host: the refusal made NO sudo call either" 1 "" \
  test -e "$W80/s1.log"
# Refusal 2: a pin on a subnet a foreign interface owns an address inside.
check "setup-host: a pinned foreign-claimed subnet REFUSES" 1 "virbr7" \
  runsetup BOX_SUBNET=10.88.0.0/24 FAKE_IP4_DEFAULT="$D_LAN" FAKE_IP4_ADDRS="$A_FOREIGN"
# Refusal 3: garbage BOX_SUBNET dies at the gate.
check "setup-host: a garbage BOX_SUBNET is refused by name" 1 "not a sane subnet" \
  runsetup BOX_SUBNET=banana
check "setup-host: a /16 BOX_SUBNET is refused" 1 "not a sane subnet" \
  runsetup BOX_SUBNET=10.88.0.0/16
# Refusal 4: an existing bridge on ANOTHER subnet is never re-addressed.
check "setup-host: a bridge on another subnet refuses (converge, don't re-address)" \
  1 "never re-addresses" \
  runsetup FAKE_IP4_DEFAULT="$D_LAN" FAKE_IP4_ADDRS="$A_HOSTSTACK" \
           FAKE_IP4_BOXNET='5: boxnet    inet 10.89.0.1/24 scope global boxnet' \
           BOX_SUBNET=10.88.0.0/24
# The legitimate re-run: boxnet itself owns the subnet — setup-host converges.
check "setup-host: a prior boxnet claiming the subnet CONVERGES (no false positive)" \
  0 "Host ready" \
  runsetup FAKE_IP4_DEFAULT="$D_LAN" FAKE_IP4_ADDRS="$A_HOSTSTACK" \
           FAKE_IP4_BOXNET='5: boxnet    inet 10.88.0.1/24 scope global boxnet' \
           FAKE_HAVE_STORAGE=1 FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1
# BOX_SUBNET plumbs through: a fresh build on 10.89.0.0/24 must derive EVERY
# value from it — the bridge address and the ACL's gateway carve-out.
check "setup-host: BOX_SUBNET drives a fresh build to completion" 0 "Host ready" \
  runsetup BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W80/g2.log" FAKE_SUDO_LOG="$W80/s2.log"
check "setup-host: ...the bridge derives from BOX_SUBNET" 0 "" \
  grep -qF 'network create boxnet ipv4.address=10.89.0.1/24' "$W80/g2.log"
check "setup-host: ...and so does the ACL's gateway carve-out" 0 "" \
  grep -qF 'destination: 10.89.0.1/32' "$W80/g2.log"
# The nested case with ZERO flags — #80's tables, no pin, no bridge: the
# auto-pick must land the whole build on 10.89, announced, and every derived
# value must follow the pick, not the default.
check "setup-host: nested with no flags auto-picks and completes" 0 "Host ready" \
  runsetup FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W80/g3.log" FAKE_SUDO_LOG="$W80/s3.log"
check "setup-host: ...announcing the auto-pick" 0 "auto-picked 10.89.0.0/24" \
  runsetup FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: ...the bridge follows the pick" 0 "" \
  grep -qF 'network create boxnet ipv4.address=10.89.0.1/24' "$W80/g3.log"
check "setup-host: ...the ACL carve-out follows the pick" 0 "" \
  grep -qF 'destination: 10.89.0.1/32' "$W80/g3.log"
# The create path writes the contract keys itself, so it must not converge on
# top of its own create — a fresh host is one write, not two.
check "setup-host: ...and the fresh path does not converge on top of its create" 1 "" \
  grep -qF 'network set boxnet ipv6.address' "$W80/g3.log"

# --- used_by_instances: is anything ATTACHED to the bridge? (#227) ----------
# The read that decides whether setup-host may converge ipv4.address, and
# whether doctor's --fix may. Pure text in, names out — the valid_subnet seam,
# driven against canned 'incus network show' output.
UBFN="$(mktemp)"
awk '/^used_by_instances\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$UBFN"
check "used_by_instances: extracted from setup-host.sh (guards the awk)" 0 "used_by" cat "$UBFN"
check "used_by_instances: the extracted function is valid bash" 0 "" bash -n "$UBFN"
# doctor.sh carries the same function, as it carries yaml_scalar. The two
# scripts ship and run independently, so the copies are diffed rather than
# trusted — a drift here makes the two tools disagree about whether a bridge
# may be renumbered, which is the one question they must not disagree on.
UBFN2="$(mktemp)"
awk '/^used_by_instances\(\) \{/,/^\}/' "$ROOT/drill/doctor.sh" > "$UBFN2"
check "used_by_instances: doctor.sh carries it too" 0 "used_by" cat "$UBFN2"
check "used_by_instances: the two copies are byte-identical" 0 "" cmp -s "$UBFN" "$UBFN2"
rm -f "$UBFN2"

ub()          { bash -c ". '$UBFN'; used_by_instances \"\$1\"" _ "$1"; }
ubempty()     { [ -z "$(ub "$1")" ]; }
ubis()        { [ "$(ub "$1")" = "$2" ]; }
ubcount()     { [ "$(ub "$1" | wc -l)" -eq "$2" ]; }
ubnoprofile() { ! ub "$1" | grep -q box-profile; }

# The measured 2026-08-27 shape: three profile entries, no instance. The
# restricted tier's per-user profile copies are why the bridge cannot simply be
# deleted and rebuilt — and they are NOT instances, so they do not block a
# converge.
UB_PROFILES='config:
  ipv4.address: 10.88.0.1/24
name: boxnet
used_by:
- /1.0/profiles/box-profile
- /1.0/profiles/box-profile?project=user-1000
- /1.0/profiles/box-profile?project=user-1001
managed: true'
UB_ATTACHED='name: boxnet
used_by:
- /1.0/instances/work
- /1.0/profiles/box-profile
- /1.0/instances/scratch?project=user-1000
managed: true'
check "used_by_instances: profiles alone are not an attachment" 0 "" ubempty "$UB_PROFILES"
check "used_by_instances: an empty list is not an attachment" 0 "" ubempty 'name: boxnet
used_by: []
managed: true'
check "used_by_instances: no used_by key at all is not an attachment" 0 "" \
  ubempty 'name: boxnet
managed: true'
check "used_by_instances: nothing at all in is nothing out" 0 "" ubempty ""
check "used_by_instances: an attached instance is named" 0 "work" ub "$UB_ATTACHED"
check "used_by_instances: ...project-qualified where Incus qualifies it" 0 \
  "scratch (project user-1000)" ub "$UB_ATTACHED"
check "used_by_instances: ...and the profile beside them is not reported as one" 0 "" \
  ubnoprofile "$UB_ATTACHED"
check "used_by_instances: ...two instances in, two lines out" 0 "" ubcount "$UB_ATTACHED" 2
# A list that ENDS is a list that ends: a later top-level key with its own
# entries must not read as more of used_by.
check "used_by_instances: a later list does not leak into the answer" 0 "" ubis 'used_by:
- /1.0/instances/work
locations:
- /1.0/instances/not-a-user' work
rm -f "$UBFN"

# --- boxnet's contract keys are CONVERGED, not written once (#227) ----------
# The create arguments used to be the only place ipv4.address, ipv4.nat and
# ipv6.address were ever written, so a drifted bridge was detected by every
# tool here and repaired by none. Driven through the same shims as the #80
# cases above: an existing bridge must come out at contract.
W227="$(mktemp -d)"
# Nothing attached: every key converges, and the bridge is not re-created.
check "setup-host: an existing boxnet is converged, not left alone" 0 "Host ready" \
  runsetup FAKE_IP4_DEFAULT="$D_LAN" FAKE_IP4_ADDRS="$A_HOSTSTACK" FAKE_IP4_BOXNET="$B_88" \
           FAKE_HAVE_STORAGE=1 FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1 \
           FAKE_BOXNET_SHOW="$UB_PROFILES" FAKE_INCUS_LOG="$W227/drift.log"
check "setup-host: ...ipv6.address=none is set on the EXISTING bridge" 0 "" \
  grep -qF 'network set boxnet ipv6.address=none ipv4.nat=true' "$W227/drift.log"
check "setup-host: ...and the drifted ipv4.address is converged to the pick" 0 "" \
  grep -qF 'network set boxnet ipv4.address=10.88.0.1/24' "$W227/drift.log"
check "setup-host: ...without re-creating the bridge" 1 "" \
  grep -qF 'network create boxnet' "$W227/drift.log"
check "setup-host: ...and dns.mode=none with it, so both drifted keys land at contract" 0 "" \
  grep -qF 'network set boxnet dns.mode=none' "$W227/drift.log"
check "setup-host: ...saying so, with the value it replaced" 0 "converged <unset> -> 10.88.0.1/24" \
  runsetup FAKE_IP4_DEFAULT="$D_LAN" FAKE_IP4_ADDRS="$A_HOSTSTACK" FAKE_IP4_BOXNET="$B_88" \
           FAKE_HAVE_STORAGE=1 FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1 \
           FAKE_BOXNET_SHOW="$UB_PROFILES"

# Idempotence: the second consecutive run finds the key at contract and does
# not write it. The file's header claims idempotence; converging must not cost
# it. (ipv6/ipv4.nat are set unconditionally by design — setting a key to the
# value it already holds is what 'converge' means here, as for the ACL.)
runsetup FAKE_IP4_DEFAULT="$D_LAN" FAKE_IP4_ADDRS="$A_HOSTSTACK" FAKE_IP4_BOXNET="$B_88" \
         FAKE_HAVE_STORAGE=1 FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1 \
         FAKE_BOXNET_SHOW="$UB_PROFILES" FAKE_BOXNET_IPV4=10.88.0.1/24 \
         FAKE_INCUS_LOG="$W227/again.log" >/dev/null 2>&1
check "setup-host: a second run leaves ipv4.address alone (idempotence)" 1 "" \
  grep -qF 'network set boxnet ipv4.address' "$W227/again.log"
check "setup-host: ...and says nothing about it" 1 "" \
  grep -qF 'ipv4.address converged' "$W227/again.log"
check "setup-host: ...while still converging the unconditional keys" 0 "" \
  grep -qF 'network set boxnet ipv6.address=none ipv4.nat=true' "$W227/again.log"

# Attached: the renumber is refused, out loud, and the run still succeeds. A
# tool that silently renumbers a running fleet is worse than one that will not.
RUNATT=(runsetup FAKE_IP4_DEFAULT="$D_LAN" FAKE_IP4_ADDRS="$A_HOSTSTACK" FAKE_IP4_BOXNET="$B_88"
        FAKE_HAVE_STORAGE=1 FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1
        FAKE_BOXNET_SHOW="$UB_ATTACHED")
check "setup-host: a drifted ipv4.address with boxes attached still exits 0" 0 "Host ready" \
  "${RUNATT[@]}" FAKE_INCUS_LOG="$W227/att.log"
check "setup-host: ...having changed the address not at all" 1 "" \
  grep -qF 'network set boxnet ipv4.address' "$W227/att.log"
check "setup-host: ...while the unconditional keys were converged anyway" 0 "" \
  grep -qF 'network set boxnet ipv6.address=none ipv4.nat=true' "$W227/att.log"
check "setup-host: ...naming the drift" 0 "boxnet's ipv4.address is <unset>" "${RUNATT[@]}"
check "setup-host: ...naming what is attached" 0 "work" "${RUNATT[@]}"
check "setup-host: ...including the one in another project" 0 "scratch (project user-1000)" \
  "${RUNATT[@]}"
check "setup-host: ...and the exact command that converges it once they are down" 0 \
  "incus network set boxnet ipv4.address 10.88.0.1/24" "${RUNATT[@]}"
check "setup-host: ...restated at the end, where it has not scrolled away" 0 \
  "is still <unset>" "${RUNATT[@]}"

# A 'show' that answers nothing is not an empty used_by list: the safe reply to
# "may I renumber?" under ignorance is no, and it is said out loud.
RUNBLIND=(runsetup FAKE_IP4_DEFAULT="$D_LAN" FAKE_IP4_ADDRS="$A_HOSTSTACK" FAKE_IP4_BOXNET="$B_88"
          FAKE_HAVE_STORAGE=1 FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1)
check "setup-host: an unreadable 'network show' does not read as 'nothing attached'" 0 \
  "what is attached to the bridge is unknown" "${RUNBLIND[@]}" FAKE_INCUS_LOG="$W227/blind.log"
check "setup-host: ...so the address is left alone" 1 "" \
  grep -qF 'network set boxnet ipv4.address' "$W227/blind.log"
check "setup-host: ...and the run still completes" 0 "Host ready" "${RUNBLIND[@]}"

# --- Where the pool LIVES (#180) -------------------------------------------
# pool_block is pure — driver and source in, the preseed's storage block out —
# so it is extracted and driven, the valid_subnet seam. The unset case is
# compared BYTE-FOR-BYTE against the block that shipped before the knob
# existed: "the pool is byte-for-byte the pool created today" is the issue's
# own named regression, and a substring match would not prove it.
W180="$(mktemp -d)"
POOLFN="$(mktemp)"
awk '/^pool_block\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$POOLFN"
check "pool_block: extracted from setup-host.sh (guards the awk)" 0 "storage_pools" cat "$POOLFN"
check "pool_block: the extracted function is valid bash" 0 "" bash -n "$POOLFN"
pblock() { bash -c ". '$POOLFN'; pool_block \"\$1\" \"\$2\"" _ "$1" "${2:-}"; }
printf 'storage_pools:\n- name: default\n  driver: btrfs\n' > "$W180/pre180.yaml"
pblock btrfs "" > "$W180/unset.yaml"
check "pool_block: with no source, byte-for-byte the pre-#180 block" 0 "" \
  cmp -s "$W180/pre180.yaml" "$W180/unset.yaml"
check "pool_block: a source is emitted verbatim" 0 "  source: '/dev/sdb'" pblock btrfs /dev/sdb
check "pool_block: ...and the driver line is untouched beside it" 0 "  driver: btrfs" pblock btrfs /dev/sdb
# shellcheck disable=SC2016  # the $() runs in the inner bash, not this one
check "pool_block: ...as a key OF the pool, i.e. under the driver" 0 "" bash -c '
  . "'"$POOLFN"'"; [ "$(pool_block btrfs /dev/sdb | tail -1)" = "  source: '"'"'/dev/sdb'"'"'" ]'
# AC6: the dir fallback is a DRIVER decision and placement is not — a host that
# cannot do btrfs still places its pool where it was told to.
check "pool_block: the dir fallback carries the source too" 0 "  source: '/data/bulk/incus'" \
  pblock dir /data/bulk/incus
check "pool_block: ...and is still the dir driver" 0 "  driver: dir" pblock dir /data/bulk/incus

# "Verbatim" is a claim about the value INCUS PARSES, not about the bytes on
# the line, and a substring check cannot tell the two apart. A plain YAML
# scalar ends at ' #' — so '/data/bulk/a #archive', a legal directory name and
# a legal Incus source, used to reach the daemon as '/data/bulk/a' and the pool
# was built somewhere nobody named, silently: the very defect #180 exists to
# close, arriving through the front door (panel round 2).
#
# Held from both sides. First WITHOUT a parser, so a runner missing pyyaml
# still fails on the regression rather than skipping it: the emitted source
# must be a QUOTED scalar, which is exactly what makes the value survive.
# shellcheck disable=SC2016  # the $() runs in the inner bash, not this one
check "pool_block: the source is emitted as a QUOTED yaml scalar" 0 "" bash -c '
  . "'"$POOLFN"'"; [ "$(pool_block btrfs "/data/bulk/a #archive" | tail -1)" \
     = "  source: '"'"'/data/bulk/a #archive'"'"'" ]'
check "pool_block: ...so the comment marker is inside the quotes, not opening one" 0 "" bash -c '
  . "'"$POOLFN"'"; pool_block btrfs "/data/bulk/a #archive" | tail -1 | grep -qE "^  source: .*archive.$"'
# shellcheck disable=SC2016  # the $() runs in the inner bash, not this one
check "pool_block: a quote in the source is doubled, as yaml escapes it" 0 "" bash -c '
  . "'"$POOLFN"'"; [ "$(pool_block btrfs "/data/o'"'"'brien" | tail -1)" \
     = "  source: '"'"'/data/o'"'"''"'"'brien'"'"'" ]'
# ...then WITH one, which is the assertion that actually means it: parse the
# block Incus is handed and compare the source it would read against the value
# the operator set. Every shape a plain scalar mangles, round-tripped.
if [ "$HAVE_YAML" = 1 ]; then
  roundtrip() { # roundtrip <value> — emitted, parsed, compared
    bash -c '. "'"$POOLFN"'"; pool_block btrfs "$1" > "$2"' _ "$1" "$W180/rt.yaml" \
      && python3 -c '
import sys, yaml
want = sys.argv[1]
got = yaml.safe_load(open(sys.argv[2]))["storage_pools"][0]["source"]
if got != want:
    print("parsed %r, wanted %r" % (got, want)); sys.exit(1)
' "$1" "$W180/rt.yaml"
  }
  check "pool_block: a source containing ' #' round-trips through a yaml parser" 0 "" \
    roundtrip '/data/bulk/a #archive'
  check "pool_block: ...and one containing a space" 0 "" roundtrip '/data/bulk/box pool'
  check "pool_block: ...and one containing a quote" 0 "" roundtrip "/data/o'brien/pool"
  check "pool_block: ...and one containing ': ', which used to break the preseed" 0 "" \
    roundtrip '/data/bulk/a: b'
  check "pool_block: ...and the documented block device, unchanged by any of it" 0 "" \
    roundtrip /dev/sdb
  # The preseed as a WHOLE still parses with the source quoted — the block is
  # spliced into a larger document, and a broken scalar there fails the run.
  check "pool_block: the block is well-formed yaml on its own" 0 "" bash -c '
    . "'"$POOLFN"'"; pool_block btrfs "/data/bulk/a #archive" > "'"$W180"'/whole.yaml"
    python3 -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "'"$W180"'/whole.yaml"'
else
  echo "skip: pool_block yaml round-trip (no python3+pyyaml here; CI has both)"
fi

# The other half of verbatim: reading one back. yaml_scalar is pure — a 'key:'
# line's value in, the value YAML means out — so it is extracted and driven
# like every other seam here. awk's $2 answered "/data/bulk/box" for a pool on
# "/data/bulk/box pool", which is a wrong answer that looks like a right one.
YSFN="$(mktemp)"
awk '/^yaml_scalar\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$YSFN"
awk '/^yaml_value\(\) \{/,/^\}/'  "$ROOT/host/setup-host.sh" >> "$YSFN"
check "yaml_scalar: extracted from setup-host.sh (guards the awk)" 0 "printf" cat "$YSFN"
check "yaml_scalar: the extracted functions are valid bash" 0 "" bash -n "$YSFN"
ys() { bash -c ". '$YSFN'; yaml_scalar \"\$1\"; echo" _ "$1"; }
yv() { bash -c ". '$YSFN'; yaml_value \"\$1\" \"\$2\"; echo" _ "$1" "$2"; }
check "yaml_scalar: a plain scalar is itself" 0 "/dev/sdb" ys " /dev/sdb"
check "yaml_scalar: a plain scalar keeps its spaces" 0 "/data/bulk/box pool" ys " /data/bulk/box pool"
check "yaml_scalar: a single-quoted scalar loses only its quotes" 0 "/data/bulk/a #archive" \
  ys " '/data/bulk/a #archive'"
check "yaml_scalar: a doubled quote inside one is a single quote" 0 "/data/o'brien" \
  ys " '/data/o''brien'"
check "yaml_scalar: a double-quoted scalar is unescaped too" 0 '/data/a"b' ys ' "/data/a\"b"'
# shellcheck disable=SC2016  # the $() runs in the inner bash, not this one
check "yaml_scalar: trailing whitespace is yaml's, not the value's" 0 "" bash -c '
  . "'"$YSFN"'"; [ "$(yaml_scalar "  /dev/sdb   ")" = "/dev/sdb" ]'
# The recorded-but-empty value every loop-backed pool carries, in both
# spellings: absence, not a source named '""'. One normalisation, every key.
# shellcheck disable=SC2016  # the $() runs in the inner bash, not this one
check "yaml_scalar: a bare pair of quotes is absence" 0 "" bash -c '
  . "'"$YSFN"'"; [ -z "$(yaml_scalar "\"\"")" ] && [ -z "$(yaml_scalar "'"''"'")" ]'
check "yaml_scalar: a lone quote is not a quoted scalar" 0 "'" ys "'"
check "yaml_value: reads the value past the first colon, whole" 0 "/data/bulk/a #archive" \
  yv source "config:
  source: '/data/bulk/a #archive'"
check "yaml_value: ...and a value containing a colon survives it" 0 "/data/a: b" \
  yv source "config:
  source: '/data/a: b'"
check "yaml_value: a key it cannot find reads as absent" 0 "" \
  yv volatile.initial_source "config:
  source: /dev/sdb"
check "yaml_value: the driver comes off the same read" 0 "btrfs" \
  yv driver "name: default
driver: btrfs"
rm -f "$YSFN"

# The re-run's match test, pure (requested, live, initial → exit status), and
# driven directly rather than only through the shim — because the shim is
# exactly what hid this. Handed a BLOCK DEVICE, Incus's btrfs driver records
# what it was given in volatile.initial_source, formats the device, and then
# overwrites 'source' with the new filesystem's UUID (lxc/incus@90429bf,
# driver_btrfs.go). So the live source of the DOCUMENTED form is a bare UUID
# forever after, and a match test reading only 'source' refuses every re-run of
# a pool it had just placed correctly.
# The identity probe itself, pure-ish: two tools, either of which answers, and
# NOTHING is not an answer. lsblk first because it needs no privilege — a
# non-root run must not be silently identity-blind — and blkid behind it
# because that is the read Incus itself does to fill 'source'. The fallback is
# driven here rather than only through the end-to-end shim, which uses the
# primary: an untested fallback is a fallback that works until it is needed.
UUIDFN="$(mktemp)"
awk '/^dev_fs_uuid\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$UUIDFN"
check "dev_fs_uuid: extracted from setup-host.sh (guards the awk)" 0 "lsblk" cat "$UUIDFN"
check "dev_fs_uuid: the extracted function is valid bash" 0 "" bash -n "$UUIDFN"
UUIDSHIM="$(mktemp -d)"
mkdir -p "$UUIDSHIM/both" "$UUIDSHIM/none"
cat > "$UUIDSHIM/both/lsblk" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_LSBLK_UUID:-}"
SHIM
cat > "$UUIDSHIM/both/blkid" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_BLKID_UUID:-}"
SHIM
cat > "$UUIDSHIM/driver" <<'SHIM'
#!/usr/bin/env bash
# dev_fs_uuid, run with no privilege escalation and a PATH holding only what
# the caller put there. Prints the answer and nothing else. PATH is set HERE
# rather than through env, so 'no tools at all' does not also mean 'no bash'.
PATH="$1"
. "$2"
SUDO=""
dev_fs_uuid /dev/sdb
echo
SHIM
chmod +x "$UUIDSHIM/both/lsblk" "$UUIDSHIM/both/blkid" "$UUIDSHIM/driver"
devuuid() { # devuuid <PATH> [VAR=val ...] — dev_fs_uuid under a chosen PATH
  local p="$1"; shift
  env "$@" bash "$UUIDSHIM/driver" "$p" "$UUIDFN"
}
# The shim dir comes FIRST, so the shims win wherever a real lsblk or blkid
# also exists; the rest of PATH is there only so their '#!/usr/bin/env bash'
# can find a bash.
check "dev_fs_uuid: lsblk answers when it can, without any privilege" 0 "u-from-lsblk" \
  devuuid "$UUIDSHIM/both:/usr/bin:/bin" FAKE_LSBLK_UUID=u-from-lsblk FAKE_BLKID_UUID=u-from-blkid
check "dev_fs_uuid: ...and blkid answers when lsblk says nothing" 0 "u-from-blkid" \
  devuuid "$UUIDSHIM/both:/usr/bin:/bin" FAKE_LSBLK_UUID= FAKE_BLKID_UUID=u-from-blkid
check "dev_fs_uuid: with neither tool present the answer is NOTHING, not a guess" 0 "" \
  devuuid "$UUIDSHIM/none"
rm -rf "$UUIDSHIM"; rm -f "$UUIDFN"

PLACEDFN="$(mktemp)"
awk '/^pool_placed_at\(\) \{/,/^\}/' "$ROOT/host/setup-host.sh" > "$PLACEDFN"
check "pool_placed_at: extracted from setup-host.sh (guards the awk)" 0 "initial" cat "$PLACEDFN"
check "pool_placed_at: the extracted function is valid bash" 0 "" bash -n "$PLACEDFN"
placed() { bash -c ". '$PLACEDFN'; pool_placed_at \"\$1\" \"\$2\" \"\$3\" \"\$4\"" _ "$1" "${2:-}" "${3:-}" "${4:-}"; }
UUID=4ff9b8f1-6e6a-4d0f-9a3c-0d1f2e3a4b5c
UUID_B=0e1d2c3b-4a59-4687-b1a2-c3d4e5f60718
# The regression round 1 found: same device, same request, second run — the
# fourth argument being what /dev/sdb resolves to NOW, which on the honest
# re-run is the filesystem Incus wrote onto it.
check "pool_placed_at: a UUID live source MATCHES the device it was made from" \
  0 "" placed /dev/sdb "$UUID" /dev/sdb "$UUID"
check "pool_placed_at: ...and a DIFFERENT device still does not" \
  1 "" placed /dev/sdc "$UUID" /dev/sdb "$UUID"
# The regression round 3 found, and the reason the fourth argument exists: an
# initial source is a STRING RECORDED AT CREATION, not a claim about what that
# name points at today. Enumeration reuses /dev/sdb for another disk; the pool
# is still on the first one; the documented identical invocation used to say
# "already placed there" about a disk it is not on.
check "pool_placed_at: the device NAME moved — same string, different disk — refuses" \
  2 "" placed /dev/sdb "$UUID" /dev/sdb "$UUID_B"
check "pool_placed_at: ...and the same name still on the same disk re-runs clean" \
  0 "" placed /dev/sdb "$UUID" /dev/sdb "$UUID"
# Fail CLOSED where identity cannot be established at all: the device is gone,
# it is not a block device, or the host has neither lsblk nor blkid. Silence
# there would be the same silence one layer down.
check "pool_placed_at: a request whose identity cannot be read refuses" \
  2 "" placed /dev/sdb "$UUID" /dev/sdb ""
# ...and it is a distinct refusal from "placed somewhere else entirely",
# because they are distinct facts and the way out of each one differs.
check "pool_placed_at: that refusal is NOT the placed-elsewhere one" \
  1 "" placed /dev/sdb /var/lib/incus/disks/default.img "" ""
# Where Incus mangled nothing, identity is not consulted and nothing changes:
# live 'source' is the path itself, so the string IS the current fact. Every
# 'dir' pool and every mounted-path source lands here.
check "pool_placed_at: a path-shaped live source never needs a device identity" \
  0 "" placed /data/bulk/incus /var/lib/incus/x /data/bulk/incus ""
# The 'dir' driver sets no initial source and mangles nothing: the fall back to
# live 'source' is the only correct read there, not a courtesy for old pools.
check "pool_placed_at: with no initial source, live source decides" \
  0 "" placed /data/bulk/incus /data/bulk/incus ""
check "pool_placed_at: ...and decides against a pool placed elsewhere" \
  1 "" placed /dev/sdb /var/lib/incus/disks/default.img ""
check "pool_placed_at: the path shape, where Incus mangles nothing, matches on both" \
  0 "" placed /data/bulk/incus /data/bulk/incus /data/bulk/incus
# A trailing slash is not a mismatch — on either source.
check "pool_placed_at: a trailing slash on the request is not a mismatch" \
  0 "" placed /data/bulk/incus/ /data/bulk/incus ""
check "pool_placed_at: ...nor one on the initial source" \
  0 "" placed /data/bulk/incus /var/lib/incus/x /data/bulk/incus/
# Fail closed: nothing requested, or nothing known, is never a match.
check "pool_placed_at: an empty request never matches" 1 "" placed "" /dev/sdb /dev/sdb
check "pool_placed_at: a pool that reports nothing at all never matches" \
  1 "" placed /dev/sdb "" ""
# An initial source must not match ACROSS pools: it is read, not assumed.
check "pool_placed_at: a loop-backed pool does not match a requested device" \
  1 "" placed /dev/sdb /var/lib/incus/disks/default.img ""

# Driven, end to end under the shims. A fresh host that sets nothing must send
# a preseed with no source: key at all — anything else changes an upgraded
# host's pool.
check "setup-host: a fresh host with no BOX_STORAGE_SOURCE completes" 0 "Host ready" \
  runsetup BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W180/p1.log"
check "setup-host: ...and its preseed carries NO source: key" 1 "" \
  grep -qE '^  \|   source:' "$W180/p1.log"
check "setup-host: ...while the storage block is the one that always shipped" 0 "" \
  grep -qF '  | - name: default' "$W180/p1.log"
check "setup-host: a fresh host places the pool where BOX_STORAGE_SOURCE says" 0 "Host ready" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" FAKE_INCUS_LOG="$W180/p2.log"
check "setup-host: ...the preseed carrying it verbatim" 0 "" \
  grep -qF "  |   source: '/dev/sdb'" "$W180/p2.log"
# ...and the shape a plain scalar silently truncated, driven all the way to the
# preseed's stdin: the pool must be asked for at the path the operator typed,
# not at the prefix before its comment marker.
check "setup-host: a source containing ' #' reaches the preseed whole" 0 "Host ready" \
  runsetup "BOX_STORAGE_SOURCE=/data/bulk/a #archive" BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" FAKE_INCUS_LOG="$W180/p10.log"
check "setup-host: ...quoted, so yaml does not read the rest as a comment" 0 "" \
  grep -qF "  |   source: '/data/bulk/a #archive'" "$W180/p10.log"
if [ "$HAVE_YAML" = 1 ]; then
  # The preseed as the daemon receives it: the shim logs every stdin verb's
  # input under its own call line with a '  | ' prefix, so take the block that
  # follows the preseed call, strip the prefix, and parse what Incus was handed.
  # shellcheck disable=SC2016  # $1/$2 are the inner bash's positional args
  check "setup-host: ...and the preseed Incus was handed parses to that source" 0 "" bash -c '
    awk "/^incus admin init --preseed/ { f = 1; next }
         f && /^  \\| / { sub(/^  \\| /, \"\"); print; next }
         f { exit }" "$1" > "$2"
    [ -s "$2" ] || { echo "no preseed block found in $1"; exit 1; }
    python3 -c "
import sys, yaml
got = yaml.safe_load(open(sys.argv[1]))[\"storage_pools\"][0][\"source\"]
want = \"/data/bulk/a #archive\"
if got != want:
    print(\"preseed carried %r, wanted %r\" % (got, want)); sys.exit(1)
" "$2"' _ "$W180/p10.log" "$W180/p10.yaml"
else
  echo "skip: setup-host preseed yaml parse (no python3+pyyaml here; CI has both)"
fi
# D3, the defect: the pool is created once, so a re-run cannot move it. It used
# to skip in silence; now it names both sources and dies.
check "setup-host: an existing pool placed ELSEWHERE refuses" 1 "already exists somewhere else" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_HAVE_STORAGE=1 \
           FAKE_POOL_SOURCE=/var/lib/incus/storage-pools/default \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W180/p3.log"
check "setup-host: ...naming the LIVE source" 1 "live:      /var/lib/incus/storage-pools/default" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_HAVE_STORAGE=1 \
           FAKE_POOL_SOURCE=/var/lib/incus/storage-pools/default \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: ...and the REQUESTED one" 1 "requested: /dev/sdb" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_HAVE_STORAGE=1 \
           FAKE_POOL_SOURCE=/var/lib/incus/storage-pools/default \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: ...pointing at the migration it is NOT (D4)" 1 "that is a migration, not a re-run" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_HAVE_STORAGE=1 \
           FAKE_POOL_SOURCE=/var/lib/incus/storage-pools/default \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: ...and the refusal never reached a preseed" 1 "" \
  grep -q 'admin init' "$W180/p3.log"
check "setup-host: ...nor the bridge it would have built after it" 1 "" \
  grep -q 'network create' "$W180/p3.log"
# The pool exists and IS where it was asked to be: an ordinary clean re-run.
check "setup-host: an existing pool that MATCHES re-runs clean" 0 "Host ready" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_HAVE_STORAGE=1 FAKE_POOL_SOURCE=/dev/sdb \
           FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1 \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: ...saying the pool is already placed there" 0 "already placed there" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_HAVE_STORAGE=1 FAKE_POOL_SOURCE=/dev/sdb \
           FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1 \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: a trailing slash is not a mismatch" 0 "Host ready" \
  runsetup BOX_STORAGE_SOURCE=/data/bulk/incus/ FAKE_HAVE_STORAGE=1 \
           FAKE_POOL_SOURCE=/data/bulk/incus FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 \
           FAKE_HAVE_PROFILE=1 BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
# The BLOCK-DEVICE re-run, end to end: the shape the docs recommend, on the
# second run. Incus reports the filesystem UUID it wrote onto /dev/sdb as the
# live source and keeps the device in volatile.initial_source, so this used to
# refuse to re-run against the pool it had itself just placed.
# FAKE_DEV_UUID is what /dev/sdb resolves to NOW: on the honest re-run that is
# the filesystem Incus wrote onto it, which is what makes the recorded initial
# source proof rather than a hopeful string (panel round 3). Overridable, so
# the moved-name and unreadable shapes drive the same path.
runblockdev() { # runblockdev <requested> [extra=val ...]
  local want="$1"; shift
  runsetup "BOX_STORAGE_SOURCE=$want" FAKE_HAVE_STORAGE=1 \
           "FAKE_POOL_SOURCE=$UUID" FAKE_POOL_INITIAL_SOURCE=/dev/sdb \
           "FAKE_DEV_UUID=$UUID" \
           FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1 \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" \
           FAKE_IP4_ADDRS="$A_GUEST" "$@"
}
check "setup-host: a block-device pool re-runs clean against the SAME device" \
  0 "Host ready" runblockdev /dev/sdb FAKE_INCUS_LOG="$W180/p8.log"
check "setup-host: ...saying the pool is already placed there" \
  0 "already placed there" runblockdev /dev/sdb
check "setup-host: ...naming the DEVICE the operator gave, not the UUID" \
  0 "source = /dev/sdb" runblockdev /dev/sdb
check "setup-host: ...with the UUID Incus records named beside it" \
  0 "Incus records it as '$UUID'" runblockdev /dev/sdb
check "setup-host: ...having actually asked for the initial source" 0 "" \
  grep -qF 'storage get default volatile.initial_source' "$W180/p8.log"
check "setup-host: ...and having actually PROBED the device's identity" 0 "" \
  grep -qF 'lsblk --nodeps -rno UUID -- /dev/sdb' "$W180/p8.log"
# The round-3 regression, end to end: the operator types the same command on
# the same host, and /dev/sdb is a different disk than the one the pool is on.
# 'already placed there' would be a lie with a success exit code.
check "setup-host: a block-device pool refuses when the NAME moved to another disk" \
  1 "does not name the disk the pool is on now" \
  runblockdev /dev/sdb "FAKE_DEV_UUID=$UUID_B" FAKE_INCUS_LOG="$W180/p11.log"
check "setup-host: ...naming the filesystem the pool actually is on" \
  1 "live:      $UUID" runblockdev /dev/sdb "FAKE_DEV_UUID=$UUID_B"
check "setup-host: ...and what that path holds instead" \
  1 "now holds: $UUID_B" runblockdev /dev/sdb "FAKE_DEV_UUID=$UUID_B"
check "setup-host: ...saying why a device name is not an identity" \
  1 "assigned in enumeration order" runblockdev /dev/sdb "FAKE_DEV_UUID=$UUID_B"
check "setup-host: ...and how to find the disk that does hold it" \
  1 "lsblk -o NAME,UUID" runblockdev /dev/sdb "FAKE_DEV_UUID=$UUID_B"
check "setup-host: ...that refusal reaching no preseed" 1 "" \
  grep -q 'admin init' "$W180/p11.log"
check "setup-host: ...nor the bridge it would have built after it" 1 "" \
  grep -q 'network create' "$W180/p11.log"
# Fail closed, not open: no device, not a block device, or no lsblk/blkid to
# ask. The old code called that a match; it is the absence of an answer.
check "setup-host: a device whose identity cannot be read refuses too" \
  1 "does not name the disk the pool is on now" \
  runblockdev /dev/sdb FAKE_DEV_UUID= FAKE_INCUS_LOG="$W180/p12.log"
check "setup-host: ...saying that is what happened, not that it mismatched" \
  1 "holds no filesystem this run could read" runblockdev /dev/sdb FAKE_DEV_UUID=
check "setup-host: ...and offering the unset way out" \
  1 "unset BOX_STORAGE_SOURCE" runblockdev /dev/sdb FAKE_DEV_UUID=
check "setup-host: ...that refusal reaching no preseed either" 1 "" \
  grep -q 'admin init' "$W180/p12.log"
# The path shapes are untouched by any of it: where live 'source' is a path,
# Incus mangled nothing, and no device identity is consulted or needed.
check "setup-host: a path-source re-run never probes a device identity" 0 "Host ready" \
  runsetup BOX_STORAGE_SOURCE=/data/bulk/incus FAKE_HAVE_STORAGE=1 \
           FAKE_POOL_SOURCE=/data/bulk/incus FAKE_POOL_INITIAL_SOURCE=/data/bulk/incus \
           FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1 \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
# The FRESH run reports the same way, and this is the run where it matters
# most: the operator has just typed /dev/sdb, and btrfs has just written a
# filesystem UUID over 'source'. Answering with the UUID alone names no disk
# on the host — it was the last line still doing so.
check "setup-host: a fresh placed host reports the DEVICE, not the UUID it became" \
  0 "source = /dev/sdb" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb BOX_SUBNET=10.89.0.0/24 \
           "FAKE_POOL_SOURCE=$UUID" FAKE_POOL_INITIAL_SOURCE=/dev/sdb \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: ...with the UUID Incus wrote named beside it" \
  0 "Incus records it as '$UUID'" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb BOX_SUBNET=10.89.0.0/24 \
           "FAKE_POOL_SOURCE=$UUID" FAKE_POOL_INITIAL_SOURCE=/dev/sdb \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
# ...and where Incus mangled nothing — every dir pool, every path source — it
# is the one line it always was, with no parenthetical to explain.
check "setup-host: a fresh path-source host reports that path plainly" \
  0 "source = /data/bulk/incus" \
  runsetup BOX_STORAGE_SOURCE=/data/bulk/incus BOX_SUBNET=10.89.0.0/24 \
           FAKE_POOL_SOURCE=/data/bulk/incus FAKE_IP4_DEFAULT="$D_INBOX" \
           FAKE_IP4_ADDRS="$A_GUEST"
# shellcheck disable=SC2016  # $PATH and $@ belong to the inner bash
check "setup-host: ...saying nothing about a UUID it does not have" 1 "" bash -c '
  runsetup() { env FAKE_UID=1000 FAKE_GROUPS="users incus-admin" \
      PATH="'"$SETUPSHIM:$SHIMDIR"':$PATH" "$@" bash "'"$ROOT"'/host/setup-host.sh"; }
  runsetup BOX_STORAGE_SOURCE=/data/bulk/incus BOX_SUBNET=10.89.0.0/24 \
           FAKE_POOL_SOURCE=/data/bulk/incus FAKE_IP4_DEFAULT="'"$D_INBOX"'" \
           FAKE_IP4_ADDRS="'"$A_GUEST"'" 2>&1 | grep -q "Incus records it as"'
check "setup-host: ...and it reached the rest of the run, not a refusal" 0 "" \
  grep -q 'network show boxnet' "$W180/p8.log"
# ...and it is a READ of that key, not an assumption: another device still
# refuses, and the refusal names the disk rather than only the UUID.
check "setup-host: a block-device pool still refuses a DIFFERENT device" \
  1 "already exists somewhere else" runblockdev /dev/sdc FAKE_INCUS_LOG="$W180/p9.log"
check "setup-host: ...naming the device it was made from" 1 "made from: /dev/sdb" \
  runblockdev /dev/sdc
check "setup-host: ...and saying why the live source is not a path" \
  1 "records the new filesystem's UUID" runblockdev /dev/sdc
check "setup-host: ...that refusal reaching no preseed either" 1 "" \
  grep -q 'admin init' "$W180/p9.log"
# Fail closed: a live pool whose source cannot be read cannot be proven to
# match, and proceeding would be the silence this whole change removes.
check "setup-host: an existing pool with no readable source refuses" 1 "reports NO source at all" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_HAVE_STORAGE=1 \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
# An unset variable on an existing pool is today's behaviour exactly: no read,
# no refusal, nothing said.
check "setup-host: with the variable unset an existing pool is not judged at all" 0 "Host ready" \
  runsetup FAKE_HAVE_STORAGE=1 FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 FAKE_HAVE_PROFILE=1 \
           BOX_SUBNET=10.89.0.0/24 FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" \
           FAKE_INCUS_LOG="$W180/p4.log"
check "setup-host: ...not even reading the live source" 1 "" \
  grep -q 'storage get' "$W180/p4.log"
# The value dies at the gate, before anything is touched: a relative path would
# be resolved by the DAEMON, somewhere nobody named.
check "setup-host: a relative BOX_STORAGE_SOURCE is refused by name" 1 "must be an absolute path" \
  runsetup BOX_STORAGE_SOURCE=bulk/incus BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" FAKE_INCUS_LOG="$W180/p5.log"
check "setup-host: ...having made no incus call at all" 1 "" test -e "$W180/p5.log"
# The one shape quoting cannot carry: YAML FOLDS a line break inside a quoted
# scalar to a space, so '/data/a<newline>b' would reach the daemon as
# '/data/a b'. That is the #180 defect through a third door, and the gate
# refuses it rather than mangling it (panel round 3). This is not the gate
# second-guessing a placement Incus would accept — it is declining to transmit
# a value it would transmit WRONG.
check "setup-host: a newline in BOX_STORAGE_SOURCE is refused by name" 1 "control character" \
  runsetup "BOX_STORAGE_SOURCE=$(printf '/data/a\nb')" BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" FAKE_INCUS_LOG="$W180/p13.log"
check "setup-host: ...saying WHY, in terms of what yaml would do to it" \
  1 "folds a line break inside one to a space" \
  runsetup "BOX_STORAGE_SOURCE=$(printf '/data/a\nb')" BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
check "setup-host: ...and having made no incus call at all" 1 "" test -e "$W180/p13.log"
check "setup-host: a tab is the same class and refused the same way" 1 "control character" \
  runsetup "BOX_STORAGE_SOURCE=$(printf '/data/a\tb')" BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
# ...and every shape that IS carried verbatim still passes the gate: the
# refusal is one class wide, not a general tightening of what a source may be.
check "setup-host: a space, a quote and a ' #' still pass the gate untouched" 0 "Host ready" \
  runsetup "BOX_STORAGE_SOURCE=/data/o'brien/a #archive b" BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST"
# The --minimal fallback creates the pool under /var/lib/incus and cannot carry
# a source, so honouring one is impossible there: refuse rather than build a
# host whose boxes live somewhere the operator did not name.
check "setup-host: a failed preseed with a placement requested refuses" 1 "cannot be honored" \
  runsetup BOX_STORAGE_SOURCE=/dev/sdb FAKE_PRESEED_FAIL=1 BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" FAKE_INCUS_LOG="$W180/p6.log"
check "setup-host: ...never falling back to --minimal" 1 "" \
  grep -q 'admin init --minimal' "$W180/p6.log"
check "setup-host: a failed preseed with NO placement still falls back" 0 "falling back to --minimal" \
  runsetup FAKE_PRESEED_FAIL=1 BOX_SUBNET=10.89.0.0/24 \
           FAKE_IP4_DEFAULT="$D_INBOX" FAKE_IP4_ADDRS="$A_GUEST" FAKE_INCUS_LOG="$W180/p7.log"
check "setup-host: ...and reaches --minimal to do it" 0 "" \
  grep -q 'admin init --minimal' "$W180/p7.log"
rm -f "$POOLFN" "$PLACEDFN"
rm -rf "$W180"

# ---------------------------------------------------------------------------
# #229 — the placement contract's rename, converged. Driven end to end against
# the stateful profile store rather than grepped, because every claim here is
# about what the host HOLDS afterwards: the old name gone, the new one there,
# in every project, and a second run silent. A log of calls cannot say that.
#
# What these cases deliberately do NOT assert is that attached boxes keep their
# placement across the rename. That is Incus's behaviour, not this script's,
# and it was answered where it lives (#229 D6): instances_profiles stores the
# association by profile id and the rename is an UPDATE of the name column
# alone, on main and on the stable-6.0 line setup-host installs. What IS
# asserted here is the consequence for this script — that it makes no
# reassignment pass, because none is owed.
# ---------------------------------------------------------------------------
# The sweep's own guard, first. A mechanical rename's correctness is exactly
# what a grep can assert, and what goes wrong if one occurrence survives is a
# box that will not mint — 'incus launch --profile box-net' against a host that
# has no such profile, found at the far end of a release. So a survivor reds
# HERE, which is the must-fail this change was specified with.
#
# The exceptions are the record classes and the scripts that handle the old
# name ON PURPOSE, and each is asserted to still contain it rather than merely
# permitted to — an exception nobody checks is how a list like this rots into a
# hole. The teardown and wipe halves come out one release after this one (D7),
# and these lines are what makes that removal a stated act instead of a drift.
# changelog.d/ is exempt for the reason CHANGELOG.md is: a fragment IS the next
# CHANGELOG.md section, staged, and an entry announcing a rename that may not
# name what was renamed announces nothing. drills/ is exempt for the reason
# drill/RUNS.md is: a release record says what that release actually carried,
# and rewriting one would have 0.9.1 shipping a profile it never had.
OLDNAME_KEEP='^(CHANGELOG\.md|changelog\.d/.*\.md|drill/RUNS\.md|drills/.*\.md|host/setup-host\.sh|host/teardown-host\.sh|host/revoke-user\.sh|drill/doctor\.sh|drill/wipe\.sh|test/cli\.sh)$'
OLDSWEEP="$(mktemp)"
git -C "$ROOT" ls-files | grep -vE "$OLDNAME_KEEP" > "$OLDSWEEP"
oldname_survivors() { # oldname_survivors [root] — prints offenders; 0 if any
  local root="${1:-$ROOT}" f rc=1
  while IFS= read -r f; do
    [ -e "$root/$f" ] || continue
    # #241 deliberately diagnoses the retired name inside cmd_import. Keep the
    # rest of bin/box under this corpus guard: an acting occurrence outside
    # that bounded refusal block is still the half-rename this sweep catches.
    if [ "$f" = bin/box ]; then
      if awk '/^  # 0\.10\.0 renamed box/{skip=1} skip && /^  fi$/{skip=0; next} !skip' \
        "$root/$f" | grep -qw -- 'box-net'; then
        printf '%s\n' "$f"; rc=0
      fi
    elif grep -qw -- 'box-net' "$root/$f" 2>/dev/null; then
      printf '%s\n' "$f"; rc=0
    fi
  done < "$OLDSWEEP"
  return $rc
}
oldname_boundary_present() {
  awk '/^  # 0\.10\.0 renamed box/{keep=1} keep{print} keep && /^  fi$/{exit}' \
    "$ROOT/bin/box" | grep -qw -- box-net
}
check "rename: the sweep reaches bin/box — an empty walk sweeps nothing (#229)" 0 "" \
  grep -qx 'bin/box' "$OLDSWEEP"
check "rename: ...and profiles/, which is where the renamed file landed" 0 "" \
  grep -qx 'profiles/box-profile.yaml' "$OLDSWEEP"
check "rename: no tracked file outside the exceptions still says the old name" 1 "" \
  oldname_survivors
check "rename: bin/box's bounded #241 refusal is the deliberate exception" 0 "" \
  oldname_boundary_present
# The guard's own test: one occurrence left in bin/box, the way the sweep
# would fail, and the guard has to red on it.
OLDFIX="$(mktemp -d)"; mkdir -p "$OLDFIX/bin"
printf 'incus launch the-image the-box --profile box-net\n' > "$OLDFIX/bin/box"
check "rename: ...and the guard reds on one left in bin/box (the guard's own test)" 0 \
  "bin/box" oldname_survivors "$OLDFIX"
# ...and does not red on the word it is one hyphen from, which is the whole
# reason this rename happened.
printf 'incus network create boxnet ipv4.address=10.88.0.1/24\n' > "$OLDFIX/bin/box"
check "rename: ...while 'boxnet' itself is untouched by it (the boundary)" 1 "" \
  oldname_survivors "$OLDFIX"
rm -rf "$OLDFIX"
for f in host/setup-host.sh host/teardown-host.sh host/revoke-user.sh drill/doctor.sh drill/wipe.sh; do
  check "rename: $f handles the old name on purpose, and still does" 0 "" \
    grep -qw -- 'box-net' "$ROOT/$f"
done
rm -f "$OLDSWEEP"

W229="$(mktemp -d)"
s229() { # s229 <name> <profile-file...> — a fresh store; 'project.profile' each
  local d="$W229/$1"; shift
  rm -rf "$d"; mkdir -p "$d"
  local p; for p; do : > "$d/$p"; done
  printf '%s' "$d"
}
run229() { # run229 <store> <log> [VAR=val ...] — the real setup-host over it
  local store="$1" log="$2"; shift 2
  rm -f "$log"
  runsetup "FAKE_PROFILE_STATE=$store" "FAKE_INCUS_LOG=$log" \
           FAKE_HAVE_STORAGE=1 FAKE_HAVE_BOXNET=1 FAKE_HAVE_ACL=1 \
           BOX_SUBNET=10.89.0.0/24 "FAKE_IP4_DEFAULT=$D_INBOX" "FAKE_IP4_ADDRS=$A_GUEST" \
           "$@"
}
# The listing a granted host answers with: Incus marks the session's own
# project by appending " (current)" to the name.
P229="$(printf 'default (current)\nuser-1000')"

# The upgrade: a 0.9.x host, one granted user, both projects on the old name.
S229="$(s229 up default.box-net user-1000.box-net)"
run229 "$S229" "$W229/up.log" "FAKE_PROJECTS=$P229" > "$W229/up.out" 2>&1
check "setup-host: an upgrading host renames the contract in 'default' (#229)" 0 \
  "renamed box-net -> box-profile in the default project" cat "$W229/up.out"
check "setup-host: ...and in the granted user's project too, not just 'default'" 0 \
  "renamed box-net -> box-profile in project user-1000" cat "$W229/up.out"
check "setup-host: ...leaving box-profile in 'default'" 0 "" test -f "$S229/default.box-profile"
check "setup-host: ...and no box-net anywhere" 1 "" \
  bash -c 'ls "'"$S229"'" | grep -q "\.box-net$"'
check "setup-host: ...the user project's copy converged as well" 0 "" \
  test -f "$S229/user-1000.box-profile"
check "setup-host: ...and the run still finished" 0 "Host ready" cat "$W229/up.out"
# No reassignment pass is owed, and none is made — the rename carries every
# attached box with it (D6). A 'profile assign' here would be the second
# mechanism D3 refuses, arrived at from the other direction.
check "setup-host: ...making no reassignment pass, because none is owed (D6)" 1 "" \
  grep -q 'profile assign' "$W229/up.log"
# Order is load-bearing: the convergence runs BEFORE the create-if-missing and
# the edit, or the edit lands on a profile the rename is about to collide with.
rename_before_edit() { # rename_before_edit <log> — the convergence ran first
  local log="$1" r e
  r="$(grep -n 'profile rename box-net box-profile' "$log" | head -1 | cut -d: -f1)"
  e="$(grep -n 'profile edit box-profile' "$log" | head -1 | cut -d: -f1)"
  [ -n "$r" ] && [ -n "$e" ] && [ "$r" -lt "$e" ]
}
check "setup-host: the rename precedes the profile edit it feeds" 0 "" \
  rename_before_edit "$W229/up.log"
# The second run is the acceptance criterion in one line.
run229 "$S229" "$W229/again.log" "FAKE_PROJECTS=$P229" > "$W229/again.out" 2>&1
check "setup-host: a second consecutive run says nothing about the rename" 1 "" \
  grep -q "box-net" "$W229/again.out"
check "setup-host: ...and makes no rename or delete call at all" 1 "" \
  grep -q -e "profile rename" -e "profile delete" "$W229/again.log"

# The " (current)" strip. The listing below marks a user project current, which
# a real admin run never produces — what it drives is the strip itself, and
# unstripped the name reaches no project at all, so BOTH renames vanish
# silently. That silence is the failure this case exists to make loud.
S229C="$(s229 cur user-1000.box-net user-1001.box-net)"
run229 "$S229C" "$W229/cur.log" \
  "FAKE_PROJECTS=$(printf 'user-1000 (current)\nuser-1001')" > "$W229/cur.out" 2>&1
check "setup-host: the ' (current)' marker is stripped before the name is used" 0 "" \
  test -f "$S229C/user-1000.box-profile"
check "setup-host: ...and the unmarked project beside it converges too" 0 "" \
  test -f "$S229C/user-1001.box-profile"

# The interrupted upgrade: both names present. The new one wins, and the case
# is decided before any rename is attempted — Incus refuses a rename onto an
# existing name, so the other order would die here under 'set -e'.
S229B="$(s229 both default.box-net default.box-profile)"
run229 "$S229B" "$W229/both.log" "FAKE_PROJECTS=default (current)" > "$W229/both.out" 2>&1
check "setup-host: both names present — the stale box-net is removed (#229 D4)" 0 \
  "removed the stale box-net in the default project" cat "$W229/both.out"
check "setup-host: ...and the run does not die on the rename incus would refuse" 0 \
  "Host ready" cat "$W229/both.out"
check "setup-host: ...having attempted no rename at all in that case" 1 "" \
  grep -q 'profile rename' "$W229/both.log"
check "setup-host: ...leaving only box-profile" 1 "" test -f "$S229B/default.box-net"

# ...and when the stale one cannot be deleted, something is still placed on it.
# This is not the rare case: 'box grant' installs a fresh box-profile beside
# the in-use box-net on every upgraded host, so it is where an ordinary grant
# lands. The convergence runs the other way round — the unused copy goes and
# the in-use one is RENAMED onto the name, carrying its boxes with it (D6) —
# and the postcondition is D4's either way: one name afterwards.
S229U="$(s229 inuse default.box-net default.box-profile)"
run229 "$S229U" "$W229/inuse.log" "FAKE_PROJECTS=default (current)" \
  FAKE_PROFILES_IN_USE=box-net > "$W229/inuse.out" 2>&1
check "setup-host: an in-use box-net converges by the reverse order (#229 D4)" 0 \
  "renamed it onto box-profile" cat "$W229/inuse.out"
check "setup-host: ...deleting the unused copy, never the one boxes are on" 0 "" \
  grep -q 'profile delete box-profile' "$W229/inuse.log"
check "setup-host: ...leaving only box-profile, which is the postcondition" 1 "" \
  test -f "$S229U/default.box-net"
check "setup-host: ...and box-profile is what survives, not nothing" 0 "" \
  test -f "$S229U/default.box-profile"
check "setup-host: ...making no reassignment pass to do it (D4 is not migration)" 1 "" \
  grep -q 'profile assign' "$W229/inuse.log"
check "setup-host: ...and the run converged, so it may say so" 0 "Host ready" \
  cat "$W229/inuse.out"

# Both names in use: boxes placed on each, and no ordering of delete and
# rename converges that — only moving instances between profiles would, which
# is the reassignment pass D4 rules out. So the run reports the residue and
# does NOT report ready: a host still carrying two names has not converged the
# rename, however well the rest of the stack went.
S229M="$(s229 mixed default.box-net default.box-profile)"
check "setup-host: both names in use — the run REFUSES to report ready (#229)" 1 \
  "NOT converged" run229 "$S229M" "$W229/mixed.log" "FAKE_PROJECTS=default (current)" \
  FAKE_PROFILES_IN_USE="box-net box-profile"
run229 "$S229M" "$W229/mixed.log" "FAKE_PROJECTS=default (current)" \
  FAKE_PROFILES_IN_USE="box-net box-profile" > "$W229/mixed.out" 2>&1 || true
check "setup-host: ...naming both names and the project that carries them" 0 \
  "carries BOTH box-profile and box-net" cat "$W229/mixed.out"
check "setup-host: ...and the command that says which box is on which" 0 \
  "profile assign" cat "$W229/mixed.out"
check "setup-host: ...never printing Host ready over an unconverged rename" 1 "" \
  grep -q "Host ready" "$W229/mixed.out"
check "setup-host: ...leaving the old name where it is, reported not removed" 0 "" \
  test -f "$S229M/default.box-net"
check "setup-host: ...having converged the rest of the stack first" 0 "" \
  grep -q 'profile edit box-profile' "$W229/mixed.log"

# ...and the same state in TWO projects. The comment at PROFILE_UNCONVERGED
# says one project that cannot converge must not stop the next from trying and
# must not be forgotten by the time the run reports; that is behaviour, so it
# is asserted rather than claimed (#229 round 2).
S229M2="$(s229 mixed2 default.box-net default.box-profile \
                      user-1000.box-net user-1000.box-profile)"
run229 "$S229M2" "$W229/mixed2.log" "FAKE_PROJECTS=$P229" \
  FAKE_PROFILES_IN_USE="box-net box-profile" > "$W229/mixed2.out" 2>&1 || true
check "setup-host: two unconvergeable projects are both named, not just the first" 0 \
  "in: default user-1000" cat "$W229/mixed2.out"
check "setup-host: ...the second still probed after the first failed" 0 "" \
  grep -qF -- '--project user-1000 profile show box-net' "$W229/mixed2.log"
check "setup-host: ...and neither one lets the run report ready" 1 "" \
  grep -q "Host ready" "$W229/mixed2.out"

# The half-done window: the unused box-profile is deleted to make room and the
# rename onto it then fails. Not a state Incus's own refusals produce — the
# target is free by then — so it is a transient daemon error, and what makes it
# worth driving is that the project is left carrying box-net ALONE, with no
# profile for 'box new'. The report must say that, not "boxes are placed on
# each", which is the message this path used to fall through to (#229 round 2).
#
# Driven in a user-<uid> project, where the consequence is real: the
# create-if-missing below the loop is 'default'-only, so nothing puts a
# box-profile back there. 'default' is already converged in this store, so the
# one rename this run attempts is the one under test.
S229H="$(s229 half default.box-profile user-1000.box-net user-1000.box-profile)"
run229 "$S229H" "$W229/half.log" "FAKE_PROJECTS=$P229" \
  FAKE_PROFILES_IN_USE=box-net FAKE_RENAME_FAIL=1 > "$W229/half.out" 2>&1 || true
check "setup-host: a rename that fails after the delete says what it actually left" 0 \
  "the rename onto it then failed" cat "$W229/half.out"
check "setup-host: ...and does not claim boxes are placed on each name" 1 "" \
  grep -q "placed on each" "$W229/half.out"
check "setup-host: ...naming the project in the end-of-run report" 0 \
  "rename then failed, in: user-1000" cat "$W229/half.out"
check "setup-host: ...withholding Host ready, because that is not converged" 1 "" \
  grep -q "Host ready" "$W229/half.out"
check "setup-host: ...and the state it describes is the state it left" 0 "" \
  bash -c 'test -f "'"$S229H"'/user-1000.box-net" && ! test -f "'"$S229H"'/user-1000.box-profile"'

# A 'project list' that FAILS is not a host with no grants. Piped straight into
# the loop the two are the same empty stream, and the run converges no
# user-<uid> project and says Host ready anyway — a claim about every granted
# user made by a run that looked at none of them. Same rule as the bridge's
# unreadable 'network show' (#227), one file over (#229 round 2).
S229N="$(s229 nolist default.box-net user-1000.box-net)"
check "setup-host: an unreadable project list is not an empty one — the run refuses" 1 \
  "NOT converged" run229 "$S229N" "$W229/nolist.log" "FAKE_PROJECTS=$P229" \
  FAKE_PROJECT_LIST_FAIL=1
run229 "$S229N" "$W229/nolist.log" "FAKE_PROJECTS=$P229" FAKE_PROJECT_LIST_FAIL=1 \
  > "$W229/nolist.out" 2>&1 || true
check "setup-host: ...saying the granted projects could not be listed" 0 \
  "could not be listed" cat "$W229/nolist.out"
check "setup-host: ...and never printing Host ready over projects it did not check" 1 "" \
  grep -q "Host ready" "$W229/nolist.out"
check "setup-host: ...having converged the default project it COULD read" 0 "" \
  test -f "$S229N/default.box-profile"
check "setup-host: ...and left the user project it could not name alone" 0 "" \
  test -f "$S229N/user-1000.box-net"
# The other shape of the same ignorance: the daemon exits 0 and answers
# nothing. A daemon that can list projects at all lists 'default', so an empty
# listing is a broken read, never a host without grants.
S229E="$(s229 emptylist default.box-net user-1000.box-net)"
check "setup-host: an EMPTY project list is the same ignorance, not a grant-less host" 1 \
  "could not be listed" run229 "$S229E" "$W229/empty.log" "FAKE_PROJECTS="
check "setup-host: ...and the user project's old name is still there, unexamined" 0 "" \
  test -f "$S229E/user-1000.box-net"
# And the third: a listing that emits a row and THEN fails. Neither case above
# reaches it — one is non-zero with nothing on stdout, the other is zero with
# nothing — so a condition that tests emptiness alone passes both and lets this
# one through, converging 'default' off a partial answer and reporting on the
# granted users as though they had been enumerated. The doctor carried exactly
# that gap into round 3; the same case is driven on both tools now, because the
# two loops are a pair and the shape has to be held in both (#229 round 3).
S229P="$(s229 partlist default.box-net user-1000.box-net)"
check "setup-host: a project list that fails AFTER a row is unread too, not partial truth" 1 \
  "could not be listed" run229 "$S229P" "$W229/part.log" "FAKE_PROJECTS=$P229" \
  FAKE_PROJECT_LIST_PARTIAL=1
run229 "$S229P" "$W229/part.log" "FAKE_PROJECTS=$P229" FAKE_PROJECT_LIST_PARTIAL=1 \
  > "$W229/part.out" 2>&1 || true
check "setup-host: ...never printing Host ready over the row it did not get" 1 "" \
  grep -q "Host ready" "$W229/part.out"
check "setup-host: ...and the granted project the listing never reached is untouched" 0 "" \
  test -f "$S229P/user-1000.box-net"

# The fresh host never sees the rename branch at all.
S229F="$(s229 fresh)"
run229 "$S229F" "$W229/fresh.log" "FAKE_PROJECTS=default (current)" > "$W229/fresh.out" 2>&1
check "setup-host: a fresh host creates box-profile and never renames" 1 "" \
  grep -q 'profile rename' "$W229/fresh.log"
check "setup-host: ...saying nothing about an old name it never had" 1 "" \
  grep -q 'box-net' "$W229/fresh.out"
check "setup-host: ...and the contract is there afterwards" 0 "" \
  test -f "$S229F/default.box-profile"
rm -rf "$W229"

rm -rf "$W80" "$SETUPSHIM"

# The decision must be the FIRST effective act — before the incus install, the
# usermod, every apt call. Line order, fail-closed on either grep missing.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "setup-host: the subnet decision precedes the first mutation" 0 "" bash -c '
  guard="$(grep -n "^BOX_SUBNET=\"\$(choose_subnet " "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  mut="$(grep -n "^if ! command -v incus" "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] && [ -n "$mut" ] && [ "$guard" -lt "$mut" ]'
# The placement gate says "Nothing was changed" too, and that is only true
# ABOVE the apt calls — the suite's shim pre-installs incus, so no driven check
# can tell the difference on a FRESH host. Held by line order, like the one
# above it.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "setup-host: the placement gate precedes the first mutation too (#180)" 0 "" bash -c '
  guard="$(grep -n "^case \"\$BOX_STORAGE_SOURCE\" in" "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  mut="$(grep -n "^if ! command -v incus" "'"$ROOT"'/host/setup-host.sh" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] && [ -n "$mut" ] && [ "$guard" -lt "$mut" ]'
# box-firewall follows the bridge, wherever BOX_SUBNET put it.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "box-firewall: the gateway is read off the live bridge, not hardcoded" 0 "" \
  grep -qF 'addr show dev "$NET"' "$ROOT/host/box-firewall.sh"
# The drill and migrate probes derive the prefix from the network — a
# BOX_SUBNET host must not fail its own rehearsals.
check "drill: derives the boxnet prefix from the network" 0 "" \
  grep -qF 'network get boxnet ipv4.address' "$ROOT/drill/drill.sh"
check "multiuser: derives the boxnet prefix from the network" 0 "" \
  grep -qF 'network get boxnet ipv4.address' "$ROOT/drill/multiuser.sh"

# ---------------------------------------------------------------------------
# The doctor's #80 signature. gw_squat_signature is pure text → findings, so
# it is extracted and driven against synthetic route tables — including the
# EXACT poisoned state from the issue, the workaround state (bridge remapped:
# clean), and a healthy host running the stack (clean).
# ---------------------------------------------------------------------------
SIGFN="$(mktemp)"
awk '/^gw_squat_signature\(\) \{/,/^\}/' "$ROOT/drill/doctor.sh" > "$SIGFN"
check "gw_squat_signature: extracted from doctor.sh (guards the awk)" 0 "default" cat "$SIGFN"
check "gw_squat_signature: the extracted function is valid bash" 0 "" bash -n "$SIGFN"
sig()   { bash -c ". '$SIGFN'; gw_squat_signature \"\$1\" \"\$2\"" _ "$1" "$2"; }
nosig() { [ -z "$(sig "$1" "$2")" ]; }

# The poisoned guest, verbatim from #80: gateway held locally AND duplicated
# connected routes for the uplink subnet.
R_POISON="$D_INBOX
10.88.0.0/24 dev boxnet proto kernel scope link src 10.88.0.1 linkdown
10.88.0.0/24 dev enp5s0 proto kernel scope link src 10.88.0.202 metric 1024
10.88.0.1 dev enp5s0 proto dhcp scope link src 10.88.0.202 metric 1024"
A_POISON="$A_GUEST
17: boxnet    inet 10.88.0.1/24 scope global boxnet"
check "signature: poisoned guest — the gateway is held as a LOCAL address" \
  0 "held as a LOCAL address" sig "$R_POISON" "$A_POISON"
check "signature: poisoned guest — duplicate connected routes for the uplink" \
  0 "duplicate connected routes" sig "$R_POISON" "$A_POISON"
# The workaround state (#80's fix: bridge remapped off the uplink subnet) —
# both signature lines must be ABSENT.
R_REMAP="$D_INBOX
10.88.0.0/24 dev enp5s0 proto kernel scope link src 10.88.0.202 metric 1024
10.88.0.1 dev enp5s0 proto dhcp scope link src 10.88.0.202 metric 1024
10.89.0.0/24 dev boxnet proto kernel scope link src 10.89.0.1 linkdown"
A_REMAP="$A_GUEST
17: boxnet    inet 10.89.0.1/24 scope global boxnet"
check "signature: the remapped-bridge workaround is CLEAN" 0 "" nosig "$R_REMAP" "$A_REMAP"
# A healthy HOST running the stack: boxnet legitimately owns its subnet, and
# the uplink is elsewhere — clean, or every host would cry wolf.
R_HOST="$D_LAN
192.168.1.0/24 dev eno1 proto kernel scope link src 192.168.1.50
10.88.0.0/24 dev boxnet proto kernel scope link src 10.88.0.1"
check "signature: a healthy host running the stack is CLEAN" 0 "" nosig "$R_HOST" "$A_HOSTSTACK"
check "signature: no default route → nothing to judge (clean)" 0 "" \
  nosig "10.88.0.0/24 dev boxnet proto kernel scope link src 10.88.0.1" "$A_HOSTSTACK"
# Each line fires on its own: a captured gateway without duplicate routes...
R_GWONLY="$D_INBOX
10.88.0.0/24 dev enp5s0 proto kernel scope link src 10.88.0.202 metric 1024"
check "signature: a captured gateway alone still fires" \
  0 "held as a LOCAL address" sig "$R_GWONLY" "$A_POISON"
# ...and duplicate routes without the gateway captured (nested bridge on .5).
A_DUPONLY="$A_GUEST
17: boxnet    inet 10.88.0.5/24 scope global boxnet"
check "signature: duplicate routes alone still fire" \
  0 "duplicate connected routes" sig "$R_POISON" "$A_DUPONLY"
rm -f "$SIGFN"

# ---------------------------------------------------------------------------
# The doctor's placement report (#180). pool_findings is the same seam: pure
# 'incus storage show' text in, report lines out, driven against canned pool
# config. The question it exists to answer without an Incus lesson is "my
# boxes filled the root disk" — so the loop-backed default must be RECOGNISED
# and named, and a placed pool must not carry that warning.
# ---------------------------------------------------------------------------
PFFN="$(mktemp)"
# The two readers come with it: pool_findings reads its scalars through them,
# and extracting the report without them would drive a function this file
# assembled rather than the one doctor.sh ships.
awk '/^yaml_scalar\(\) \{/,/^\}/'   "$ROOT/drill/doctor.sh" > "$PFFN"
awk '/^yaml_value\(\) \{/,/^\}/'    "$ROOT/drill/doctor.sh" >> "$PFFN"
awk '/^pool_findings\(\) \{/,/^\}/' "$ROOT/drill/doctor.sh" >> "$PFFN"
check "pool_findings: extracted from doctor.sh (guards the awk)" 0 "driver = " cat "$PFFN"
check "pool_findings: the extracted function is valid bash" 0 "" bash -n "$PFFN"
pf() { bash -c ". '$PFFN'; pool_findings \"\$1\"" _ "$1"; }

# What a stock host looks like today: btrfs, and a source Incus chose itself
# inside its own state directory — i.e. on '/'.
P_LOOP="name: default
driver: btrfs
status: Created
config:
  size: 30GiB
  source: /var/lib/incus/storage-pools/default"
# What #180 buys: the pool on a disk of its own.
P_DEV="name: default
driver: btrfs
config:
  source: /dev/sdb"
# A pool that reports no source at all, on the driver with no CoW.
P_BARE="name: default
driver: dir
config: {}"
# What #180 buys AS INCUS ACTUALLY RECORDS IT: handed /dev/sdb, the btrfs
# driver formats the disk and replaces 'source' with the new filesystem's UUID,
# keeping the device in volatile.initial_source. A doctor that printed only the
# UUID would answer "where do my boxes live" with a string naming no disk.
P_UUID="name: default
driver: btrfs
config:
  size: 60GiB
  source: 4ff9b8f1-6e6a-4d0f-9a3c-0d1f2e3a4b5c
  volatile.initial_source: /dev/sdb"
check "pool_findings: the driver is reported" 0 "driver = btrfs" pf "$P_LOOP"
check "pool_findings: ...and so is the source" \
  0 "source = /var/lib/incus/storage-pools/default" pf "$P_LOOP"
check "pool_findings: the loop-backed default is named as the ROOT filesystem" \
  0 "charged against" pf "$P_LOOP"
check "pool_findings: ...and the way out is a FRESH host, not a re-run" \
  0 "BOX_STORAGE_SOURCE=/dev/sdb box setup-host" pf "$P_LOOP"
check "pool_findings: ...saying so, because a re-run cannot move a pool" \
  0 "migration, not a re-run" pf "$P_LOOP"
check "pool_findings: a placed pool reports its device" 0 "source = /dev/sdb" pf "$P_DEV"
check "pool_findings: ...and carries no root-disk warning" 1 "" bash -c '
  . "'"$PFFN"'"; pool_findings "'"$P_DEV"'" | grep -q "charged against"'
check "pool_findings: a pool with no source at all is still reported" \
  0 "source = <none reported>" pf "$P_BARE"
check "pool_findings: ...and named as the root filesystem too" 0 "ROOT filesystem" pf "$P_BARE"
check "pool_findings: dir is named as the driver with no copy-on-write" \
  0 "no copy-on-write" pf "$P_BARE"
check "pool_findings: btrfs is not" 1 "" bash -c '
  . "'"$PFFN"'"; pool_findings "'"$P_LOOP"'" | grep -q "copy-on-write"'
check "pool_findings: an unreadable pool says so rather than inventing a driver" \
  0 "driver = <unreadable>" pf ""
# The block-device pool as Incus really reports it: the UUID is what 'source'
# says, and the device it was built on is named beside it.
check "pool_findings: a UUID source is reported as the source Incus holds" \
  0 "source = 4ff9b8f1-6e6a-4d0f-9a3c-0d1f2e3a4b5c" pf "$P_UUID"
check "pool_findings: ...with the DEVICE it was made from named too" \
  0 "made from = /dev/sdb" pf "$P_UUID"
check "pool_findings: ...saying which of the two is the filesystem UUID" \
  0 "the source above is the filesystem UUID" pf "$P_UUID"
# ...in the PAST tense, and that is the point rather than the grammar: this
# function probes nothing, so 'made from' is the path Incus was HANDED at
# creation and not a claim about what that name points at today. setup-host
# refuses a re-run it cannot bind back to this filesystem for exactly that
# reason; the report says which fact it has instead of borrowing the other
# one (#180, panel round 3).
check "pool_findings: ...as the path Incus was GIVEN, not a claim about today" \
  0 "the path Incus was given when this pool was created" pf "$P_UUID"
check "pool_findings: ...warning that a device name can move and a UUID cannot" \
  0 "can move between reboots" pf "$P_UUID"
check "pool_findings: ...and naming the command that settles it" \
  0 "lsblk -o NAME,UUID" pf "$P_UUID"
# The caveat belongs to the two-fact case only: a pool whose source Incus kept
# has no second name to be confused about.
check "pool_findings: a pool Incus did not mangle gets no device-name caveat" 1 "" bash -c '
  . "'"$PFFN"'"; pool_findings "'"$P_DEV"'" | grep -q "can move between reboots"'
check "pool_findings: ...and carrying no root-disk warning" 1 "" bash -c '
  . "'"$PFFN"'"; pool_findings "'"$P_UUID"'" | grep -q "charged against"'
# It is a report of a DIFFERENCE, not an echo: where Incus kept the path it was
# given (every dir pool, every path source, and a block device whose by-uuid
# symlink never appeared), there is no second line to read.
check "pool_findings: a source Incus did not mangle gets no 'made from' line" 1 "" bash -c '
  . "'"$PFFN"'"; pool_findings "name: default
driver: btrfs
config:
  source: /data/bulk/incus
  volatile.initial_source: /data/bulk/incus" | grep -q "made from"'
check "pool_findings: ...and neither does a pool with no initial source at all" 1 "" bash -c '
  . "'"$PFFN"'"; pool_findings "'"$P_DEV"'" | grep -q "made from"'
# A loop-backed pool carries the key RECORDED AND EMPTY, which YAML renders as
# a bare pair of quotes. That is absence, not a device named '"'"'""'"'"'.
check "pool_findings: an empty initial source is absence, not a device" 1 "" bash -c '
  . "'"$PFFN"'"; pool_findings "name: default
driver: btrfs
config:
  source: /var/lib/incus/disks/default.img
  volatile.initial_source: \"\"" | grep -q "made from"'
check "pool_findings: ...and the root-disk warning still fires under it" 0 "charged against" \
  pf "name: default
driver: btrfs
config:
  source: /var/lib/incus/disks/default.img
  volatile.initial_source: \"\""
# AC5 on a source with a space in it. This section exists to answer "my boxes
# filled the root disk" with a path the operator can act on, and reading the
# line with awk's $2 answered it with a DIFFERENT path — '/data/bulk/box' for a
# pool on '/data/bulk/box pool' — which is worse than not answering, because
# nothing about it looks wrong. Both shapes Incus emits: plain for a space,
# quoted once the value contains ' #'.
P_SPACE="name: default
driver: btrfs
config:
  source: /data/bulk/box pool"
P_HASH="name: default
driver: btrfs
config:
  source: '/data/bulk/a #archive'"
check "pool_findings: a source containing a space is reported WHOLE" \
  0 "source = /data/bulk/box pool" pf "$P_SPACE"
check "pool_findings: a quoted source is reported without its quotes" \
  0 "source = /data/bulk/a #archive" pf "$P_HASH"
check "pool_findings: ...and neither is mistaken for the root filesystem" 1 "" bash -c '
  . "'"$PFFN"'"; { pool_findings "'"$P_SPACE"'"; pool_findings "'"$P_HASH"'"; } | grep -q "charged against"'
# The device a quoted-and-mangled pool was made from is read the same way: this
# is the line that names the disk, so truncating it names the wrong disk.
check "pool_findings: a quoted initial source names the whole device" \
  0 "made from = /dev/disk/by-id/scsi-0QEMU disk2" pf "name: default
driver: btrfs
config:
  source: 4ff9b8f1-6e6a-4d0f-9a3c-0d1f2e3a4b5c
  volatile.initial_source: '/dev/disk/by-id/scsi-0QEMU disk2'"
rm -f "$PFFN"

# The wiring, and the judgement inside it: the pool is read off the profile
# that PLACES every box, and the whole section is informational. Placement is
# a choice, not a fault — a DIRTY line here would red every stock host on the
# day it shipped, and the verdict is what the drill reads.
check "doctor: the pool is read off the box-profile profile, not guessed" 0 "" \
  grep -qF 'incus profile device get box-profile root pool' "$ROOT/drill/doctor.sh"
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "doctor: the placement section reports through pool_findings" 0 "" \
  grep -qF 'pool_findings "$POOL_SHOW"' "$ROOT/drill/doctor.sh"
check "doctor: the placement section judges nothing (no DIRTY line in it)" 1 "" bash -c '
  awk "/^head_ \"Storage pool/,/^head_ \"ACL/" "'"$ROOT"'/drill/doctor.sh" | grep -qE "^ *no \""'
# The 'df' line measures the pool's own filesystem, so it reads the source the
# same way the report does: '$2' of "  source: /data/bulk/box pool" is
# "/data/bulk/box", and '[ -d ]' on that either says nothing or measures a
# DIFFERENT filesystem and labels it this pool's.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "doctor: the df line reads the source through yaml_value too" 0 "" \
  grep -qF 'src="$(yaml_value source "$POOL_SHOW")"' "$ROOT/drill/doctor.sh"
# A drift guard on all five reads: nothing in either script may go back to
# taking a source line's second FIELD, which is what threw half of a path away.
#
# Widened from a pattern that required the KEY and 'print $2' to be ADJACENT.
# That one was narrower than its own name: it missed 'awk "/^  source:/ {print
# $2}"' and 'grep "^  source:" | awk "{print $2}"' (@claude-bot-andresmgsl,
# panel round 3). The offered widening was a BARE 'print $2' over both files,
# on the grounds that neither has another one — but doctor.sh has two, the ACL
# destination read and the resolv.conf nameserver read, and a guard that reds
# on unrelated correct code gets deleted rather than obeyed. So: the key and
# 'print $2' on one LINE, in any order and any distance apart, which catches
# every spelling named and neither innocent one. A read split across two lines
# is out of a grep's reach and is not claimed here.
# shellcheck disable=SC2016  # the $2 is the pattern being searched FOR
check "the source is never read as awk's second field again (#180)" 1 "" \
  grep -nE 'source.*print[[:space:]]*\$2' "$ROOT/drill/doctor.sh" "$ROOT/host/setup-host.sh"
# ...and a guard is only worth its name if it can see those spellings, so hold
# it against them rather than trusting the regex by eye. The first two are the
# ones the narrow pattern let through; the third is the one it caught.
DRIFTF="$(mktemp)"
cat > "$DRIFTF" <<'DRIFT'
awk '/^  source:/ {print $2}' "$show"
grep '^  source:' <<<"$show" | awk '{print $2}'
awk -v k=source: '$1 == k { print $2 }' <<<"$show"
DRIFT
# shellcheck disable=SC2016  # the $2 is the pattern being searched FOR
driftcount() { grep -cE 'source.*print[[:space:]]*\$2' "$1"; }
check "...and that guard catches all three spellings, not just the adjacent one" \
  0 "3" driftcount "$DRIFTF"
# ...while leaving doctor.sh's two unrelated second-field reads alone, which is
# why the pattern is not the bare one.
# shellcheck disable=SC2016  # the $2 is the pattern being searched FOR
check "...and does not red on the reads that are nothing to do with a source" \
  0 "" grep -qE 'nameserver.*print[[:space:]]*\$2' "$ROOT/drill/doctor.sh"
rm -f "$DRIFTF"

# The wiring: the signature is judged on THIS machine before any daemon call
# (the daemon answering could be the nested impostor), probed INSIDE boxes on
# both tiers, and the egress-broken-DNS-fine split names the fingerprint.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "doctor: this machine's signature precedes the daemon checks" 0 "" bash -c '
  sig="$(grep -n "is a nested box stack squatting" "'"$ROOT"'/drill/doctor.sh" | head -1 | cut -d: -f1)"
  daemon="$(grep -n "timeout 10 incus list" "'"$ROOT"'/drill/doctor.sh" | head -1 | cut -d: -f1)"
  [ -n "$sig" ] && [ -n "$daemon" ] && [ "$sig" -lt "$daemon" ]'
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "doctor: the signature is probed inside boxes on BOTH tiers" 0 "" bash -c '
  [ "$(grep -c "probe_sig \"\$probe\"" "'"$ROOT"'/drill/doctor.sh")" -eq 2 ]'
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "doctor: the egress-broken-DNS-fine fingerprint is named on both tiers" 0 "" bash -c '
  [ "$(grep -c "fingerprint" "'"$ROOT"'/drill/doctor.sh")" -ge 2 ]'
check "doctor: the ACL carve-out is checked against the live gateway" 0 "" \
  grep -qF "does NOT match boxnet's gateway" "$ROOT/drill/doctor.sh"

# ---------------------------------------------------------------------------
# The phase-D phantom, retired from the third file that carried it (#197).
# Phase D stopped rehearsing the #16 hardening when the hardening shipped —
# drill.sh's phase D is a block of `inf` lines with no `incus` call of any
# kind — so doctor's header and two of its findings were blaming a mechanism
# that does not exist, in the file bin/box points five other failure paths at.
# These two cases pin the false claims OUT.
check "doctor: the header does not claim the drill mutates the host" 1 "" \
  grep -qF 'MUTATES the host in phase D' "$ROOT/drill/doctor.sh"
check "doctor: no finding blames phase D for a mutation" 1 "" \
  grep -qE 'phase D left this behind|survived phase D' "$ROOT/drill/doctor.sh"
# ...and these pin the BEHAVIOUR in. #197 moves prose only, so every one of
# them passes BEFORE the rewrite as well as after — which is what makes the two
# cases above safe to write, a rewrite that quietly dropped a --fix branch
# reddening here. Nothing asserts the header's new wording: a text match on a
# comment the same change writes proves only that the change agrees with
# itself, and the reader needs the two claims out and these five in.
check "doctor: --fix still restores dns.mode=none" 0 "" \
  grep -qF 'incus network set boxnet dns.mode=none' "$ROOT/drill/doctor.sh"
check "doctor: --fix still removes an @internal ACL rule" 0 "" \
  grep -qF 'incus network acl rule remove box-isolate' "$ROOT/drill/doctor.sh"
check "doctor: --fix still deletes all eight leftover drill boxes" 0 "" \
  grep -qF 'for b in drill clone archive peer payroll cbprobe cbcopy cbnotours; do' \
    "$ROOT/drill/doctor.sh"
# The #16 incident is the file's best argument for running it at all, and D2
# re-attributes it to the fault rather than deleting it with the phase. Carried
# prose, not new, so this case passes on both sides of the rewrite too.
check "doctor: the #16 incident survives the re-attribution" 0 "" \
  grep -qF 'Temporary failure resolving deb.debian.org' "$ROOT/drill/doctor.sh"
# D6: doctor has no --help and gained none. A bad argument is still one line
# and exit 2, resolved before any daemon call — so this runs anywhere.
check "doctor: a bad argument still exits 2 with the one-line usage" 2 "usage: doctor.sh" \
  bash "$ROOT/drill/doctor.sh" --nonsense

# ---------------------------------------------------------------------------
# The doctor's boxnet keys, and whether its VERDICT is reachable (#227). The
# whole script is DRIVEN under shims — the setup-host and box-firewall seam —
# because the claim under test is about the verdict a host gets, and no grep
# can hold that: "3 problem(s), run --fix" where --fix could only reach one is
# advice that sends the operator round a loop the tool already knew the end of.
#
# The incus shim is STATEFUL on purpose: 'network set' writes the key and
# 'network get' reads it back, so --fix followed by a fresh run is the same
# measurement an operator makes, not a claim about what --fix logged.
# ---------------------------------------------------------------------------
DOCSHIM="$(mktemp -d)"
DOCSTATE="$(mktemp -d)"
cat > "$DOCSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the driven doctor: a healthy host except for boxnet's keys,
# which live in $FAKE_NET_STATE as one file per key so a 'set' is visible to
# the next 'get'. Everything else answers the way a clean stack does.
key_file() { printf '%s/%s' "$FAKE_NET_STATE" "$(printf '%s' "$1" | tr / _)"; }
case "$1 $2" in
  "network get")
    f="$(key_file "$4")"; [ -f "$f" ] && cat "$f"; exit 0 ;;
  "network set")
    shift 3
    for kv; do printf '%s' "${kv#*=}" > "$(key_file "${kv%%=*}")"; done
    exit 0 ;;
esac
case "$*" in
  "network show boxnet")  printf '%s\n' "${FAKE_BOXNET_SHOW:-}" ;;
  "network acl show box-isolate")
    printf 'egress:\n- action: allow\n  destination: %s/32\n- action: drop\n  destination: 10.0.0.0/8\n' \
      "${FAKE_ACL_GW:-10.88.0.1}" ;;
  # FAKE_DOC_NO_PROFILE is the restricted tier's project WITHOUT the contract in
  # it — either never granted, or granted under the old name. Unset (every case
  # above and the whole admin path) the profile is there, which is what those
  # cases mean by a healthy host (#229 round 5).
  "profile show box-profile") [ -z "${FAKE_DOC_NO_PROFILE:-}" ] || exit 1 ;;
  "profile device get box-profile eth0 security.port_isolation") printf 'true\n' ;;
  "profile device get box-profile root pool")                    printf 'default\n' ;;
  # #229's drift probe, per project. FAKE_DOC_STALE names the projects that
  # still carry the old profile; unset, no project does and the doctor says so
  # — which is the answer every case above this one wants. FAKE_DOC_PROJECTS_FAIL
  # is the daemon that will not answer at all, which is a different host from
  # one with nothing to report (#229 round 2).
  #
  # FAKE_DOC_PROJECTS_PARTIAL is the OTHER way the read fails, and the one an
  # emptiness test cannot see: a row on stdout and a non-zero exit after it.
  # It answers 'default (current)' — the row a listing that dies mid-write is
  # likeliest to have already emitted, and the one that walks the doctor into
  # its success arm with the user-<uid> projects never enumerated (#229 round 3).
  "project list --format csv")
    [ -z "${FAKE_DOC_PROJECTS_FAIL:-}" ] || { echo "Error: not authorized" >&2; exit 1; }
    [ -z "${FAKE_DOC_PROJECTS_PARTIAL:-}" ] || {
      printf 'default (current)\n'; echo "Error: connection reset" >&2; exit 1; }
    printf '%s\n' "${FAKE_DOC_PROJECTS:-default (current)}" ;;
  *"profile show box-net")
    p=default; [ "$1" = --project ] && p="$2"
    case " ${FAKE_DOC_STALE:-} " in *" $p "*) exit 0 ;; esac
    exit 1 ;;
  "storage show default") printf 'config: {}\ndriver: dir\nname: default\n' ;;
  "config show "*)        exit 1 ;;   # no leftover drill boxes
  "list"|"list "*)        ;;          # daemon answers; no instances to probe
esac
exit 0
SHIM
cat > "$DOCSHIM/pgrep" <<'SHIM'
#!/usr/bin/env bash
# A dnsmasq IS serving boxnet: that check is not what these cases are about,
# and a real pgrep here would put a fourth problem in every verdict below.
exit 0
SHIM
cat > "$DOCSHIM/sudo" <<'SHIM'
#!/usr/bin/env bash
# nft table present (exit 0), 'bridge -d link show' empty (no attached taps),
# ufw absent from its own answer. The doctor must never touch this machine.
exit 0
SHIM
chmod +x "$DOCSHIM/incus" "$DOCSHIM/pgrep" "$DOCSHIM/sudo"

rundoctor() { # rundoctor <state-dir> [--fix] — the real doctor, under shims
  local state="$1"; shift
  env FAKE_NET_STATE="$state" FAKE_BOXNET_SHOW="${DOC_SHOW:-}" \
      FAKE_IP4_ROUTES="$D_LAN" FAKE_IP4_ADDRS="$A_HOSTSTACK" \
      FAKE_IP4_BOXNET="${DOC_LIVE-5: boxnet    inet 10.88.0.1/24 scope global boxnet}" \
      NO_COLOR=1 PATH="$DOCSHIM:$SHIMDIR:$PATH" \
      bash "$ROOT/drill/doctor.sh" "$@"
}
drifted() { # drifted <dir> — the host measured on 2026-08-27, restored
  rm -rf "$1"; mkdir -p "$1"
  printf 'no-resolv;server=1.1.1.1' > "$1/raw.dnsmasq"   # the resolver IS pinned
  printf '2001:db8::1/64'           > "$1/ipv6.address"  # …and these three are not
}
# The operator's own measurement: --fix, then look again. Every assertion about
# what --fix achieved is made on the SECOND run, never on what the first logged.
docfixed()  { rundoctor "$1" --fix >/dev/null 2>&1; rundoctor "$1"; }
dockey()    { rundoctor "$1" --fix >/dev/null 2>&1; [ "$(cat "$1/$2" 2>/dev/null)" = "$3" ]; }
dounwritten() { rundoctor "$1" --fix >/dev/null 2>&1; [ ! -f "$1/$2" ]; }
docnohold() { ! rundoctor "$1" | grep -qF -e "--fix cannot reach" -e "need the boxes down"; }
# A bridge that is up but holds no address: DOC_LIVE empty, in a subshell so
# the emptiness cannot leak into the next case.
docnolive() { ( DOC_LIVE=""; rundoctor "$@" ); }
docnolive_unwritten() { ( DOC_LIVE=""; rundoctor "$1" --fix >/dev/null 2>&1 ); [ ! -f "$1/ipv4.address" ]; }

# The measured state, verbatim: dns.mode unset, ipv4.address empty, ipv6 set.
# Nothing is attached — the used_by that host reported held profiles only.
DOC_SHOW="$UB_PROFILES"
D1="$DOCSTATE/measured"; drifted "$D1"
check "doctor: the 2026-08-27 host state is 3 problems, as measured" 1 "3 problem(s)" \
  rundoctor "$D1"
check "doctor: ...ipv4.address is JUDGED now, not just printed" 1 "DIRTY ipv4.address = <unset>" \
  rundoctor "$D1"
check "doctor: ...naming what an unrecorded address costs" 1 "silently passes" rundoctor "$D1"
check "doctor: ...ipv6 is still caught" 1 "IPv6 is on and NOT covered" rundoctor "$D1"
check "doctor: ...and with nothing held, --fix is offered without qualification" 1 \
  "run:  bash drill/doctor.sh --fix" rundoctor "$D1"
check "doctor: ...no line claims --fix cannot reach a key" 0 "" docnohold "$D1"
# The acceptance criterion in one line: --fix on that state, then a fresh run.
drifted "$D1"
check "doctor: --fix reduces the measured state to zero" 0 "clean" docfixed "$D1"
drifted "$D1"
check "doctor: ...having converged ipv4.address to the address the bridge holds" 0 \
  "ipv4.address = 10.88.0.1/24" docfixed "$D1"
drifted "$D1"
check "doctor: ...and ipv6.address to none" 0 "ipv6.address = none" docfixed "$D1"
drifted "$D1"
# The key probe C6 reads, left at the value it reads for — the failure that
# motivated the issue, observable without a full drill run.
check "doctor: ...so 'incus network get boxnet ipv6.address' answers C6 correctly" 0 "" \
  dockey "$D1" ipv6.address none

# Attached: --fix must NOT renumber, and must say which key it left and why —
# the doctor's version of a declared skip. The verdict has to distinguish the
# two classes, because they need different next moves: one is a flag, the
# other is stopping the boxes.
DOC_SHOW="$UB_ATTACHED"
D2="$DOCSTATE/attached"; drifted "$D2"
check "doctor: --fix leaves ipv4.address alone while boxes are attached" 1 "2 instance(s) attached" \
  rundoctor "$D2" --fix
check "doctor: ...naming it as the key --fix cannot reach" 1 "--fix cannot reach this: ipv4.address" \
  rundoctor "$D2" --fix
check "doctor: ...and the verdict counts it apart from the rest" 1 \
  "1 of them need the boxes down first" rundoctor "$D2" --fix
check "doctor: ...the state is genuinely unchanged, so the count only drops by two" 1 \
  "1 problem(s)" docfixed "$D2"
drifted "$D2"
check "doctor: ...while the safe keys were fixed anyway" 0 "" dockey "$D2" ipv6.address none
drifted "$D2"
check "doctor: ...and the address was not written" 0 "" dounwritten "$D2" ipv4.address
# The refusal is a property of the HOST, not of the flag: a plain report must
# name it too, or the operator reaches for --fix to find out.
drifted "$D2"
check "doctor: the refusal is stated without --fix as well" 1 "need the boxes down first" \
  rundoctor "$D2"

# The bridge with no address at all: there is nothing to converge TO, and the
# doctor never decides a subnet — choose_subnet does, in setup-host (D3).
DOC_SHOW="$UB_PROFILES"
D3="$DOCSTATE/noaddr"; drifted "$D3"
check "doctor: with no live bridge address, --fix refuses and says who decides" 1 \
  "'box setup-host' decides the subnet" docnolive "$D3" --fix
check "doctor: ...and invents no address of its own" 0 "" docnolive_unwritten "$D3"

# The same ignorance rule setup-host holds: a 'show' that answers nothing is
# not an empty used_by list, and --fix may not renumber on it.
DOC_SHOW=""
D5="$DOCSTATE/blind"; drifted "$D5"
check "doctor: an unreadable 'network show' holds the key rather than renumbering" 1 \
  "what is attached is unknown" rundoctor "$D5" --fix
check "doctor: ...and writes nothing" 0 "" dounwritten "$D5" ipv4.address

# A bridge whose config and kernel disagree — the other half of the check. The
# ACL carve-out reads the config key, so the two disagreeing is not cosmetic.
DOC_SHOW="$UB_PROFILES"
D4="$DOCSTATE/disagree"; drifted "$D4"
printf '10.89.0.1/24' > "$D4/ipv4.address"
check "doctor: config and kernel disagreeing about the gateway is a finding" 1 \
  "but the bridge holds 10.88.0.1/24" rundoctor "$D4"
check "doctor: ...and --fix converges the config to the kernel" 0 "" \
  dockey "$D4" ipv4.address 10.88.0.1/24

# #229 — a surviving box-net is drift, and the doctor's job is to name it AND
# name the lever. The distinction being asserted is the one the code makes:
# claude-dev goes unreported because the tool that could fix it is retired
# (#226), box-net is reported because setup-host converges it, so the report
# points at something the operator can actually run.
D229="$DOCSTATE/oldname"; drifted "$D229"
check "doctor: a clean host says the contract has one name (#229)" 1 \
  "no stale box-net" rundoctor "$D229"
docstale() { ( FAKE_DOC_PROJECTS="$1"; FAKE_DOC_STALE="$2"; export FAKE_DOC_PROJECTS FAKE_DOC_STALE
               rundoctor "$D229" ) }
check "doctor: a surviving box-net is DIRTY, not a shrug" 1 \
  "DIRTY box-net still exists" docstale "default (current)" "default"
check "doctor: ...and it names the lever that removes it" 1 \
  "fix:  box setup-host" docstale "default (current)" "default"
check "doctor: ...saying the boxes on it are still isolated (the fault is the name)" 1 \
  "still isolated" docstale "default (current)" "default"
# Every project, or the check repeats the residue it exists to catch: the stale
# copy that matters most is the one in a granted user's project, which is the
# one nobody re-runs a grant for.
check "doctor: ...reaching a granted user's project, not just 'default'" 1 \
  "user-1000" docstale "$(printf 'default (current)\nuser-1000')" "user-1000"
check "doctor: ...and naming both when both carry it" 1 \
  "in: default user-1000" docstale "$(printf 'default (current)\nuser-1000')" "default user-1000"
# ...and no wider than setup-host converges, because the two loops are a pair.
# A box-net in a project outside 'default' and 'user-*' is a state box does not
# create, and reporting it would offer 'box setup-host' as the fix for
# something that run never touches — a lever that cannot clear what it is
# named for is worse than silence (#229, round 1).
docsays() { docstale "$1" "$2" | grep -q "$3"; }
check "doctor: ...and no wider than the convergence reaches (the loops are a pair)" 1 "" \
  docsays "$(printf 'default (current)\nscratch')" "scratch" "scratch"
check "doctor: ...the same listing still catching the project that IS in scope" 0 "" \
  docsays "$(printf 'default (current)\nuser-1000')" "user-1000" "user-1000"
# ...and 'default' is the literal project, anchored at both ends: an operator's
# own 'default-archive' is no more in setup-host's reach than 'scratch' is, so
# reporting one would name the same lever that cannot clear it (#229, round 2).
check "doctor: ...'default' is the project of that name, not a prefix" 1 "" \
  docsays "$(printf 'default (current)\ndefault-archive')" "default-archive" "default-archive"
# --fix cannot reach it, and says so rather than passing silently: converging
# the rename is setup-host's, and a second mechanism for one convergence is
# exactly what this change refused to add.
check "doctor: ...registering a STATED refusal, since --fix cannot reach it" 1 \
  "--fix cannot reach this: the rename" docstale "default (current)" "default"

# A 'project list' the daemon will not answer is not a host with nothing to
# report. Piped into the loop the two are the same empty stream, and the OK
# below it — "the placement contract has one name on this host" — would be a
# clean bill of health for a question nobody asked. The doctor's own rule from
# #227, one check over: an unreadable read is not an empty result.
docblind()    { ( FAKE_DOC_PROJECTS_FAIL=1; export FAKE_DOC_PROJECTS_FAIL; rundoctor "$D229" ) }
docblindfix() { ( FAKE_DOC_PROJECTS_FAIL=1; export FAKE_DOC_PROJECTS_FAIL; rundoctor "$D229" --fix ) }
check "doctor: an unreadable project list is DIRTY, not 'no stale box-net' (#229)" 1 \
  "the project list could not be read" docblind
docblindsays() { docblind | grep -q "$1"; }
check "doctor: ...and it does NOT claim the contract has one name" 1 "" \
  docblindsays "no stale box-net"
check "doctor: ...naming the daemon, not the host, as what to check" 1 \
  "incus project list" docblind
check "doctor: ...and --fix holds rather than reporting on projects it cannot name" 1 \
  "--fix cannot reach this: the box-net check" docblindfix

# The second shape of the same ignorance, and the one an emptiness test cannot
# see: a listing that writes a row and THEN fails. The fake above exits
# non-zero with nothing on stdout, so a condition that reads emptiness alone
# still catches it — this one exits non-zero having already printed
# 'default (current)', which is a NONEMPTY answer from a daemon that never
# finished enumerating. Read by emptiness, the doctor sweeps that one project,
# finds no box-net in it, and certifies a host whose user-<uid> projects were
# never listed. So the status is checked as well as the output, and this is the
# case that holds it (#229 round 3).
docpart()    { ( FAKE_DOC_PROJECTS_PARTIAL=1; export FAKE_DOC_PROJECTS_PARTIAL; rundoctor "$D229" ) }
docpartfix() { ( FAKE_DOC_PROJECTS_PARTIAL=1; export FAKE_DOC_PROJECTS_PARTIAL; rundoctor "$D229" --fix ) }
check "doctor: a project list that fails AFTER a row is unread too, not clean (#229)" 1 \
  "the project list could not be read" docpart
docpartsays() { docpart | grep -q "$1"; }
check "doctor: ...and the nonempty partial answer earns no 'no stale box-net'" 1 "" \
  docpartsays "no stale box-net"
check "doctor: ...saying a partial listing is not the host's inventory" 1 \
  "not the host's inventory" docpart
check "doctor: ...and --fix holds on it exactly as on the silent refusal" 1 \
  "--fix cannot reach this: the box-net check" docpartfix

# THE RESTRICTED TIER, DRIVEN (#229 round 5, @claude-bot-andresmgsl's N2). Its
# three arms were read and not run: the tier exits at its own verdict long
# before the admin sweep above, so not one of the cases above enters it. The
# middle arm is the one that matters and the one nothing was holding — a
# granted user whose project did not converge carries the tier under the OLD
# name, and the obvious reading ("no profile, so not granted") sends them at a
# re-grant, which installs box-profile BESIDE the stale copy instead of
# converging it. That is a wrong fix offered to the person least able to see it
# is wrong.
docres()    { ( BOX_TIER=restricted; export BOX_TIER; rundoctor "$D229" ) }
docresfix() { ( BOX_TIER=restricted; export BOX_TIER; rundoctor "$D229" --fix ) }
docresold() { ( BOX_TIER=restricted FAKE_DOC_NO_PROFILE=1 FAKE_DOC_STALE=default
                export BOX_TIER FAKE_DOC_NO_PROFILE FAKE_DOC_STALE
                rundoctor "$D229" ) }
docresnone() { ( BOX_TIER=restricted FAKE_DOC_NO_PROFILE=1
                 export BOX_TIER FAKE_DOC_NO_PROFILE
                 rundoctor "$D229" ) }
# -e, because one of the strings asserted absent begins with a dash.
docresoldsays() { docresold | grep -q -e "$1"; }
# Arm 1 — the tier is granted under the new name, and this is the clean run.
check "doctor restricted: a granted project reports the contract by its new name (#229)" 0 \
  "the box-profile profile is in your project" docres
check "doctor restricted: ...and that host is clean on this tier" 0 "clean" docres
check "doctor restricted: ...with the admin levers named as admin's, not run" 0 \
  "admin levers — ignored on this tier" docresfix
# Arm 2 — granted, unconverged: the tier IS granted, wearing the pre-0.10.0 name.
check "doctor restricted: a project still on box-net is DIRTY, not ungranted (#229)" 1 \
  "the pre-0.10.0 name for the placement contract" docresold
check "doctor restricted: ...saying the tier IS granted, this project did not converge" 1 \
  "the tier is granted, but this project did not converge" docresold
check "doctor restricted: ...naming setup-host, the lever that converges every project" 1 \
  "box setup-host" docresold
# The wrong fix, asserted absent. 'box grant' here would install box-profile
# beside the survivor and tell the user nothing about what was left behind.
check "doctor restricted: ...and NOT the re-grant, which would leave the old copy" 1 "" \
  docresoldsays "the restricted tier is granted per user"
# 'inf' and not 'hold', deliberately: HELD is rendered by the admin verdict this
# tier exits before reaching, so a hold line here would be written and never
# printed — and the banner has already said --fix is ignored on this tier.
check "doctor restricted: ...registering no hold, which this tier could never print" 1 "" \
  docresoldsays "--fix cannot reach"
# Arm 3 — neither name: genuinely not granted, and here the re-grant IS the fix.
check "doctor restricted: no profile at all is the ungranted case (#229)" 1 \
  "no box-profile profile in your project" docresnone
check "doctor restricted: ...and THAT one is fixed by a re-grant" 1 \
  "box grant" docresnone
unset DOC_SHOW

# ---------------------------------------------------------------------------
# box-firewall's UFW converge and the fail-closed boot window (#86 review,
# items 1–2). The whole script is DRIVEN under shims (the setup-host seam):
# a fake ufw serves canned `ufw status` tables and logs every mutation, fake
# nft/sysctl/iptables swallow the rest, and the shim ip answers the
# live-bridge read. Stale gateway allows must converge to the live gateway,
# a fresh UFW host must get exactly the rule set it always did, a no-UFW
# host must keep its nft path, and the no-bridge-address boot window must
# mutate NOTHING — the old GW=10.88.0.1 fallback built the carve-out for
# the wrong gateway on every BOX_SUBNET host that hit it.
# ---------------------------------------------------------------------------
FWSHIM="$(mktemp -d)"; UFWSHIM="$(mktemp -d)"; WFW="$(mktemp -d)"
cat > "$UFWSHIM/ufw" <<'SHIM'
#!/usr/bin/env bash
# Fake ufw: 'status' prints $FAKE_UFW_STATUS; every call is logged to
# $FAKE_UFW_LOG. Mutations mutate nothing, of course.
[ -n "${FAKE_UFW_LOG:-}" ] && printf 'ufw %s\n' "$*" >> "$FAKE_UFW_LOG"
case "${1:-}" in status) printf '%s\n' "${FAKE_UFW_STATUS:-Status: inactive}" ;; esac
exit 0
SHIM
cat > "$FWSHIM/nft" <<'SHIM'
#!/usr/bin/env bash
# Fake nft: logs to $FAKE_NFT_LOG. The bridge-table probe answers "absent"
# so the creation path runs (and is logged) instead of being skipped.
[ -n "${FAKE_NFT_LOG:-}" ] && printf 'nft %s\n' "$*" >> "$FAKE_NFT_LOG"
case "$*" in "list table bridge box") exit 1 ;; esac
exit 0
SHIM
cat > "$FWSHIM/sysctl" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
cat > "$FWSHIM/iptables" <<'SHIM'
#!/usr/bin/env bash
# Fake iptables: the DOCKER-USER probe answers "no such chain", so the
# docker block is deterministically skipped whether or not this runner
# happens to have docker.
exit 1
SHIM
chmod +x "$UFWSHIM/ufw" "$FWSHIM/nft" "$FWSHIM/sysctl" "$FWSHIM/iptables"

runfw() { # runfw <ufw|noufw> [VAR=val ...] — the real box-firewall, under shims
  local mode="$1" p rc=0; shift
  p="$FWSHIM:$SHIMDIR:$PATH"
  [ "$mode" = ufw ] && p="$UFWSHIM:$p"
  # Stderr is captured to a file AND re-emitted, rather than only passed
  # through. The driving `check` swallows the output of a run that passes, so
  # when a later grep over the log fails there is nothing left to read — which
  # is precisely the hole #102 fell into. Keeping a copy on disk lets
  # fwlog_ready below show what the run actually said. Overwritten per call by
  # design: every fwlog_ready sits immediately after its own runfw, so "the
  # last run" is always the run being diagnosed.
  env PATH="$p" "$@" bash "$ROOT/host/box-firewall.sh" 2>"$WFW/last-run.err" || rc=$?
  cat "$WFW/last-run.err" >&2
  return "$rc"
}

# fwlog_ready <log> — the shimmed ufw actually logged mutations to <log>.
#
# Why this exists (#102): every grep in the blocks below reads a log written by
# the shimmed ufw during the driving `runfw` check. When something stops the
# UFW branch of box-firewall.sh from running at all, that log is missing — or,
# as it turned out, present but holding nothing except the `ufw status` probe.
# The greps then fail four-at-a-time with empty output: a signature that looks
# alarmingly specific and carries no information whatsoever. #102 was filed
# reading it as "the log is not written", which was a reasonable inference from
# four blank failures and was also wrong; the file was there, the mutations
# were not, and that distinction is the entire diagnosis. So assert the
# precondition explicitly, before the content greps, and on failure print what
# IS in $WFW, what the log itself holds, and what the run wrote to stderr. The
# fix below should mean this never fires — it is here for the next cause, not
# this one, and its whole job is to hand over the evidence instead of making
# the next person re-derive it from a re-run loop.
fwlog_ready() {
  local log="$1" muts
  if [ -f "$log" ]; then
    muts="$(grep -vc "^ufw status" "$log")"
    [ "$muts" -gt 0 ] && return 0
    echo "DIAGNOSIS: $log exists but logs no ufw MUTATION (only 'ufw status')."
    echo "  => box-firewall.sh took its no-UFW branch; the UFW carve-out never ran."
  else
    echo "DIAGNOSIS: $log does not exist — the shimmed ufw was never invoked."
  fi
  echo "  \$WFW ($WFW) holds:"
  # shellcheck disable=SC2012  # a human-read diagnostic dump, not parsed: `ls -la`
  # shows sizes and mtimes, which is the whole point here (a zero-byte log and a
  # log that was never created are different failures). $WFW is our own mktemp -d.
  ls -la "$WFW" 2>&1 | sed 's/^/    /'
  echo "  contents of $(basename "$log"):"
  { [ -f "$log" ] && cat "$log" || echo "(absent)"; } 2>&1 | sed 's/^/    /'
  echo "  stderr of the run that should have written it:"
  { [ -s "$WFW/last-run.err" ] && cat "$WFW/last-run.err" || echo "(empty)"; } 2>&1 | sed 's/^/    /'
  return 1
}

# Canned `ufw status` tables, modeled on the real output shape.
U_HDR='Status: active

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW       Anywhere'
U_FRESH="$U_HDR"
U_OLDGW="$U_HDR
Anywhere on boxnet         DENY        Anywhere
10.88.0.1 53/tcp on boxnet ALLOW       Anywhere
10.88.0.1 53/udp on boxnet ALLOW       Anywhere
67/udp on boxnet           ALLOW       Anywhere
Anywhere on boxnet         ALLOW FWD   Anywhere"
U_LIVEGW="$U_HDR
Anywhere on boxnet         DENY        Anywhere
10.89.0.1 53/tcp on boxnet ALLOW       Anywhere
10.89.0.1 53/udp on boxnet ALLOW       Anywhere
67/udp on boxnet           ALLOW       Anywhere
Anywhere on boxnet         ALLOW FWD   Anywhere"
BX88='5: boxnet    inet 10.88.0.1/24 scope global boxnet'
BX89='5: boxnet    inet 10.89.0.1/24 scope global boxnet'

# The remapped host (#80's escape hatch): bridge on 10.89, UFW still carrying
# 10.88's carve-out — the stale allows go, the live gateway's land.
check "box-firewall: a remapped bridge CONVERGES the UFW carve-out" 0 "" \
  runfw ufw FAKE_IP4_BOXNET="$BX89" FAKE_UFW_STATUS="$U_OLDGW" FAKE_UFW_LOG="$WFW/remap.log"
check "box-firewall: ...the run logged ufw mutations at all" 0 "" fwlog_ready "$WFW/remap.log"
check "box-firewall: ...the stale tcp allow is deleted" 0 "" \
  grep -qF 'ufw delete allow in on boxnet to 10.88.0.1 port 53 proto tcp' "$WFW/remap.log"
check "box-firewall: ...and the stale udp allow" 0 "" \
  grep -qF 'ufw delete allow in on boxnet to 10.88.0.1 port 53 proto udp' "$WFW/remap.log"
check "box-firewall: ...the live gateway gains its tcp allow" 0 "" \
  grep -qF 'ufw insert 1 allow in on boxnet to 10.89.0.1 port 53 proto tcp' "$WFW/remap.log"
check "box-firewall: ...and its udp allow" 0 "" \
  grep -qF 'ufw insert 1 allow in on boxnet to 10.89.0.1 port 53 proto udp' "$WFW/remap.log"
check "box-firewall: ...the live gateway's rules are never deleted" 1 "" \
  grep -qF 'delete allow in on boxnet to 10.89.0.1' "$WFW/remap.log"

# The agreeing host: rules already match the live gateway — nothing deleted
# (ufw itself skips the re-adds as existing rules).
check "box-firewall: an agreeing UFW host deletes nothing" 0 "" \
  runfw ufw FAKE_IP4_BOXNET="$BX89" FAKE_UFW_STATUS="$U_LIVEGW" FAKE_UFW_LOG="$WFW/agree.log"
# This one matters more than it looks: "no delete was issued" is an ASSERT-ABSENT
# check, so a run that issued nothing at all passes it for the wrong reason.
# fwlog_ready is what keeps the absence meaningful.
check "box-firewall: ...the run logged ufw mutations at all" 0 "" fwlog_ready "$WFW/agree.log"
check "box-firewall: ...no delete was issued" 1 "" grep -qF ' delete ' "$WFW/agree.log"

# The fresh host: no boxnet rules yet — exactly the five historical commands,
# aimed at the live gateway, and nothing else (unchanged behavior).
check "box-firewall: a fresh UFW host runs clean" 0 "" \
  runfw ufw FAKE_IP4_BOXNET="$BX88" FAKE_UFW_STATUS="$U_FRESH" FAKE_UFW_LOG="$WFW/fresh.log"
check "box-firewall: ...the run logged ufw mutations at all" 0 "" fwlog_ready "$WFW/fresh.log"
check "box-firewall: ...the deny lands" 0 "" \
  grep -qF 'ufw insert 1 deny in on boxnet' "$WFW/fresh.log"
check "box-firewall: ...the DNS allows aim at the live gateway" 0 "" \
  grep -qF 'ufw insert 1 allow in on boxnet to 10.88.0.1 port 53 proto tcp' "$WFW/fresh.log"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "box-firewall: ...DHCP and the route allow land too" 0 "" bash -c '
  grep -qF "ufw insert 1 allow in on boxnet to any port 67 proto udp" "$1" &&
  grep -qF "ufw route allow in on boxnet" "$1"' _ "$WFW/fresh.log"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "box-firewall: ...exactly the five historical mutations, no more" 0 "" \
  bash -c '[ "$(grep -vc "^ufw status" "$1")" -eq 5 ]' _ "$WFW/fresh.log"

# The boot window (#86 review item 2): bridge not yet addressed → NO guessed
# gateway, NO mutation at all — the persisted rules are left exactly as they
# are, and the skip says so. (The old fallback built 10.88.0.1 rules on a
# BOX_SUBNET host here — a latent DNS drop.)
check "box-firewall: an unaddressed bridge FAILS CLOSED on a UFW host" 0 "left as-is" \
  runfw ufw FAKE_IP4_BOXNET= FAKE_UFW_STATUS="$U_OLDGW" FAKE_UFW_LOG="$WFW/boot.log"
# shellcheck disable=SC2016  # $1 expands in the child shell, by design
check "box-firewall: ...not one ufw mutation was issued" 0 "" \
  bash -c '[ "$(grep -vc "^ufw status" "$1")" -eq 0 ]' _ "$WFW/boot.log"
check "box-firewall: the hardcoded gateway fallback is GONE (comments aside)" 1 "" \
  grep -qE '^[^#]*GW=10' "$ROOT/host/box-firewall.sh"

# The no-UFW host: untouched semantics — the nft input carve-out is
# interface-scoped, so it needs no gateway and applies even in the boot
# window where the UFW path now declines to guess.
check "box-firewall: a no-UFW host keeps its nft path" 0 "" \
  runfw noufw FAKE_IP4_BOXNET="$BX89" FAKE_NFT_LOG="$WFW/nft.log"
check "box-firewall: ...the DNS/DHCP accept is interface-scoped" 0 "" \
  grep -qF 'add rule inet box input iifname boxnet udp dport { 53, 67 } accept' "$WFW/nft.log"
check "box-firewall: ...and the input drop lands" 0 "" \
  grep -qF 'add rule inet box input iifname boxnet drop' "$WFW/nft.log"
check "box-firewall: the nft path survives the boot window too" 0 "" \
  runfw noufw FAKE_IP4_BOXNET= FAKE_NFT_LOG="$WFW/nftboot.log"
check "box-firewall: ...with the same interface-scoped carve-out" 0 "" \
  grep -qF 'add rule inet box input iifname boxnet udp dport { 53, 67 } accept' "$WFW/nftboot.log"

# ---------------------------------------------------------------------------
# The doctor's UFW blind spot (#86 review item 1, second half): the ACL
# check alone gave a remapped UFW host a clean bill while the stale UFW
# allow dropped box DNS. ufw_dns_findings is pure text → findings, the
# gw_squat_signature seam: extracted and driven against canned tables.
# ---------------------------------------------------------------------------
UFWFN="$(mktemp)"
awk '/^ufw_dns_findings\(\) \{/,/^\}/' "$ROOT/drill/doctor.sh" > "$UFWFN"
check "ufw_dns_findings: extracted from doctor.sh (guards the awk)" 0 "DNS allow" cat "$UFWFN"
check "ufw_dns_findings: the extracted function is valid bash" 0 "" bash -n "$UFWFN"
ufwsig()   { bash -c ". '$UFWFN'; ufw_dns_findings \"\$1\" \"\$2\" \"\$3\"" _ "$1" "$2" "$3"; }
noufwsig() { [ -z "$(ufwsig "$1" "$2" "$3")" ]; }

check "ufw findings: agreement is SILENT" 0 "" noufwsig "$U_LIVEGW" boxnet 10.89.0.1
check "ufw findings: a stale carve-out is flagged as NOT the live gateway" \
  0 "NOT boxnet's live gateway" ufwsig "$U_OLDGW" boxnet 10.89.0.1
check "ufw findings: ...naming the address it points at" \
  0 "10.88.0.1" ufwsig "$U_OLDGW" boxnet 10.89.0.1
# Our deny with no DNS allow at all is a drop — say so.
U_DENYONLY="$U_HDR
Anywhere on boxnet         DENY        Anywhere"
check "ufw findings: a deny with NO DNS allow is a drop" \
  0 "NO DNS allow" ufwsig "$U_DENYONLY" boxnet 10.89.0.1
# A UFW host box-firewall never touched has nothing to judge — clean.
check "ufw findings: an untouched UFW host is CLEAN" 0 "" noufwsig "$U_FRESH" boxnet 10.89.0.1
# A stale allow left BESIDE the live one still gets named (residue, not a drop).
U_BOTH="$U_LIVEGW
10.88.0.1 53/tcp on boxnet ALLOW       Anywhere"
check "ufw findings: a stale allow beside the live one is named" \
  0 "stale UFW DNS allow" ufwsig "$U_BOTH" boxnet 10.89.0.1
# Rules on OTHER interfaces are not boxnet's problem.
U_OTHERIF="$U_LIVEGW
10.88.0.1 53/tcp on eth0   ALLOW       Anywhere"
check "ufw findings: another interface's DNS allow is ignored" 0 "" \
  noufwsig "$U_OTHERIF" boxnet 10.89.0.1

# The wiring: doctor judges UFW's own table where UFW is active, and the fix
# points at the converging box-firewall.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "doctor: reads UFW's table through ufw_dns_findings" 0 "" \
  grep -qF 'ufw_dns_findings "$ufw_out"' "$ROOT/drill/doctor.sh"
check "doctor: the UFW fix names the converge" 0 "" \
  grep -qF 'converges the UFW allows' "$ROOT/drill/doctor.sh"
rm -f "$UFWFN"; rm -rf "$FWSHIM" "$UFWSHIM" "$WFW"

# ---------------------------------------------------------------------------
# The drill's probe ledger (#153). drill.sh counted what it RAN and never how
# much it SHOULD have run, so a skipped phase reported a clean sweep — and that
# number is transcribed into drills/<version>.md as the evidence a release was
# proven. The ledger is a self-contained block in drill.sh precisely so it can
# be extracted and DRIVEN here: the drill itself needs real hardware, but the
# arithmetic that decides "this run was short" must not.
# ---------------------------------------------------------------------------
LEDGERFN="$(mktemp)"
awk '/^# >>> probe ledger/,/^# <<< probe ledger/' "$ROOT/drill/drill.sh" > "$LEDGERFN"
check "probe ledger: extracted from drill.sh (guards the awk)" 0 "PHASE_EXPECT" cat "$LEDGERFN"
check "probe ledger: the extracted block is valid bash" 0 "" bash -n "$LEDGERFN"

# Drive the block for real. `findings` is the one thing it assumes from the
# script around it, so the harness supplies it, exactly as the drill does.
led() { bash -c "set -u; findings=(); . '$LEDGERFN'; $1"; }
# A complete run: every phase emits what it declared.
FULL='PHASE_RAN=([I]=1 [A]=8 [B]=45 [C]=9 [E]=7 [D]=0 [T]=1)'

# shellcheck disable=SC2016  # the snippet is evaluated by led(), not here
check "probe ledger: the declared total is 71" 0 "[71]" led 'printf "[%s]" "$(ledger_declared)"'
# The number CONTRIBUTING and drills/README.md have quoted all along with
# nothing checking it. If a phase gains probes, both move together or this reds.
check "probe ledger: ...which is the contract CONTRIBUTING states" 0 "" \
  grep -qF '71-probe' "$ROOT/CONTRIBUTING.md"
# The README quotes the total too, and it was the ONE copy nothing checked —
# so it sat at "84 checks, 84 passing" through a cut that moved every other
# copy to 81. Driven off ledger_declared() like the rest, rather than a
# literal, so the next phase change moves it or reds here (#214).
#
# The DENOMINATOR is what drifted and the denominator is what is pinned. The
# numerator is a RESULT: drills/README.md's own worked example reads 80/81, so
# a guard demanding N-of-N would forbid the README from ever reporting a run
# that had a failure — asserting a thing this repo does not believe. It is
# still bounded: an integer, and never more than the ledger declares, because
# a run cannot pass more probes than exist (#214).
readme_quotes_the_total() {  # [<file>] — README.md unless a fixture says else
  ( set -u
    # shellcheck disable=SC2034  # skipped() appends to it; the block assumes it
    findings=()
    # shellcheck disable=SC1090  # the extracted ledger, written above
    . "$LEDGERFN"
    local f="${1:-$ROOT/README.md}" n pair d q c
    n="$(ledger_declared)"
    # Exactly one total, asserted before the one is read. The extraction below
    # takes 'head -1', so a SECOND '**N checks, N passing**' anywhere in the
    # file would go unchecked behind the first — a guard that silently reads
    # one of two copies is the same shape as an absence sweep over an empty
    # list, and the drift this exists for started with a copy nothing read.
    c="$(grep -cE '\*\*[0-9]+ checks, [0-9]+ passing\*\*' "$f")"
    # Both numbers out in one pass, split by parameter expansion rather than by
    # 'read': a bare 'read' under 'set -e' is what #111's repo-wide sweep
    # forbids, and it is right to — no match here must be a reported failure,
    # never a silent exit.
    pair="$(sed -n \
      "s/.*\*\*\([0-9]\{1,\}\) checks, \([0-9]\{1,\}\) passing\*\*.*/\1 \2/p" "$f" | head -1)"
    d="${pair%% *}"; q="${pair##* }"
    [ -n "$pair" ] \
      || { echo "$f quotes no '**N checks, N passing**' total at all"; exit 1; }
    [ "$c" = 1 ] \
      || { echo "$f quotes $c totals; only the first is checked"; exit 1; }
    [ "$d" = "$n" ] \
      || { echo "$f advertises $d checks; the ledger declares $n"; exit 1; }
    [ "$q" -le "$n" ] \
      || { echo "$f claims $q passing out of $n — more probes than exist"; exit 1; } )
}
check "probe ledger: ...and the total the README advertises (#214)" 0 "" \
  readme_quotes_the_total
# The guard's own test, on the axis the round moved it: the denominator is
# pinned and the numerator is free, so a run that HAD a failure is reportable.
RQPROBE="$(mktemp)"
printf 'currently **71 checks, 70 passing**\n' > "$RQPROBE"
check "probe ledger: ...and a run with a failure is still quotable, 70/71" 0 "" \
  readme_quotes_the_total "$RQPROBE"
printf 'currently **84 checks, 84 passing**\n' > "$RQPROBE"
check "probe ledger: ...while the drift that started this, 84/84, reds" 1 "advertises 84" \
  readme_quotes_the_total "$RQPROBE"
printf 'currently **71 checks, 99 passing**\n' > "$RQPROBE"
check "probe ledger: ...and so does passing more probes than exist" 1 "more probes than exist" \
  readme_quotes_the_total "$RQPROBE"
# The second copy, which 'head -1' would have read straight past: the first
# total is correct here and the guard must still red.
printf 'currently **71 checks, 70 passing**\nand elsewhere **84 checks, 84 passing**\n' > "$RQPROBE"
check "probe ledger: ...and a second total nothing would have read reds too" 1 "quotes 2 totals" \
  readme_quotes_the_total "$RQPROBE"
rm -f "$RQPROBE"

check "probe ledger: a complete run is short in nothing" 0 "[]" \
  led "$FULL; printf '[%s]' \"\$(ledger_short)\""
check "probe ledger: a complete run's floor is the declared total" 0 "[71]" \
  led "$FULL; printf '[%s]' \"\$(ledger_expected)\""

# THE regression. A phase that never executed used to be invisible: the pass
# count simply ended lower and exit 0 vouched for it.
check "probe ledger: a phase that never ran is named, not silently dropped" 0 "C(0/9)" \
  led "$FULL; PHASE_RAN[C]=0; printf '[%s]' \"\$(ledger_short)\""
check "probe ledger: ...and one missing probe inside a phase is named too" 0 "B(44/45)" \
  led "$FULL; PHASE_RAN[B]=44; printf '[%s]' \"\$(ledger_short)\""

# A floor, not an equality: adding a probe must not red the commit that adds it.
check "probe ledger: overshooting a phase is not a shortfall" 0 "[]" \
  led "$FULL; PHASE_RAN[B]=60; printf '[%s]' \"\$(ledger_short)\""

# A declared skip is honest — it lowers the expectation by exactly its probes
# and says so. The whole point is that the floor is never tuned down silently.
check "probe ledger: a declared skip lowers the floor by its probes" 0 "[62]" \
  led "$FULL; skipped C 9 'no isolation stack'; PHASE_RAN[C]=0; printf '[%s]' \"\$(ledger_expected)\""
check "probe ledger: ...so a declared skip is not a shortfall" 0 "[]" \
  led "$FULL; skipped C 9 'no isolation stack'; PHASE_RAN[C]=0; printf '[%s]' \"\$(ledger_short)\""
check "probe ledger: ...and it prints a SKIP line the record can carry" 0 "SKIP" \
  led "skipped C 9 'no isolation stack'"
check "probe ledger: ...which lands in findings, not only on the terminal" 0 "SKIP: no isolation stack" \
  led "skipped C 9 'no isolation stack' >/dev/null; printf '%s\n' \"\${findings[@]}\""
# An UNdeclared skip is still a shortfall. This is the line between the two.
check "probe ledger: an undeclared skip of the same phase still reds" 0 "C(0/9)" \
  led "$FULL; PHASE_RAN[C]=0; printf '[%s]' \"\$(ledger_short)\""

# DRILL_EXPECT raises the floor for an operator who knows the table is behind.
check "probe ledger: DRILL_EXPECT overrides the total floor" 0 "[90]" \
  led "DRILL_EXPECT=90; $FULL; printf '[%s]' \"\$(ledger_expected)\""

# ok/no must keep returning 0 — the file's SC2015 disable at the top rests on it.
check "probe ledger: tally returns 0 so ok/no still do" 0 "[0][0]" \
  led "PHASE=A; tally; printf '[%s]' \$?; PHASE=-; tally; printf '[%s]' \$?"
# A verdict emitted outside any ledgered phase means the table has drifted.
check "probe ledger: an unattributed verdict is surfaced, not swallowed" 0 "unattributed" \
  led "PHASE=-; tally; ledger_line"
check "probe ledger: the per-phase line is what a single total cannot say" 0 "B 45/45" \
  led "$FULL; ledger_line"

# The wiring, so the ledger cannot be left correct-but-unused.
ledger_keys_agree() {
  ( set -u
    # shellcheck disable=SC2034  # skipped() appends to it; the block assumes it
    findings=()
    # shellcheck disable=SC1090  # the extracted block, written just above
    . "$LEDGERFN"
    local k
    while read -r k; do
      [ "$k" = "-" ] && continue
      [ -n "${PHASE_EXPECT[$k]:-}" ] || { echo "phase header uses an undeclared key: $k"; exit 1; }
    done < <(grep -oE '^[[:space:]]*phase [A-Za-z-]+ ' "$ROOT/drill/drill.sh" | awk '{print $2}')
    for k in "${PHASE_ORDER[@]}"; do
      grep -qE "^[[:space:]]*phase $k " "$ROOT/drill/drill.sh" \
        || { echo "declared in the table but no phase opens it: $k"; exit 1; }
    done )
}
check "drill: the ledger's keys and the script's phase headers agree" 0 "" ledger_keys_agree
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "drill: the summary fails a short run instead of reporting a clean sweep" 0 "" \
  grep -qF 'no "the drill ran SHORT:' "$ROOT/drill/drill.sh"
# shellcheck disable=SC2016  # ditto
check "drill: the summary prints the denominator the record transcribes" 0 "" \
  grep -qF '%s/%s passed, %s failed' "$ROOT/drill/drill.sh"
# The two skips an operator meets most often. Either one silently short-counting
# is how a floor gets "tuned down to the weakest run" instead of held.
check "drill: a KVM-less host declares the VM probe it did not run" 0 "" \
  grep -qF 'skipped B 1 "no /dev/kvm' "$ROOT/drill/drill.sh"
check "drill: --keep-boxes declares the teardown probe it did not run" 0 "" \
  grep -qF 'skipped T 1 "--keep-boxes' "$ROOT/drill/drill.sh"

# A typo'd DRILL_EXPECT used to reach the arithmetic and leak a bash
# 'unbound variable' line into the summary. It failed safe; it did not explain.
check "probe ledger: a non-numeric DRILL_EXPECT is refused, and named" 2 \
  "DRILL_EXPECT must be a whole number, got: abc" \
  led "DRILL_EXPECT=abc; ledger_check_expect"
check "probe ledger: ...while a numeric one is accepted" 0 "" \
  led "DRILL_EXPECT=90; ledger_check_expect"
check "probe ledger: ...and an unset one is not an error" 0 "" led "ledger_check_expect"
# Refusing early is the whole point: an operator who typo'd it must find out
# before the drill starts formatting a host, not in the summary forty minutes on.
expect_guard_runs_first() {
  local guard first
  guard="$(grep -n '^ledger_check_expect || exit 2$' "$ROOT/drill/drill.sh" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] || { echo "the DRILL_EXPECT guard is defined but never called"; return 1; }
  first="$(grep -nE '^[[:space:]]*phase [A-Za-z-]+ ' "$ROOT/drill/drill.sh" | head -1 | cut -d: -f1)"
  [ "$guard" -lt "$first" ] || { echo "the guard runs at $guard, after the first phase at $first"; return 1; }
}
check "drill: the DRILL_EXPECT guard is called, and before the first phase" 0 "" \
  expect_guard_runs_first

# ---------------------------------------------------------------------------
# The exit path, EXECUTED (#153). Everything above proves the ledger's
# arithmetic and that the summary's lines are written. Neither proves the drill
# LEAVES non-zero when it ran short — and an exit status is the whole of #153's
# central criterion, so grep is not evidence for it: replacing the final
# `[ "$fail" -eq 0 ]` with unconditional success passed every check above.
#
# So compose the four extracted blocks — verdicts, ledger, record, summary —
# into the runnable skeleton of a drill that has finished, and run it. The exit
# status asserted below is the real one, produced by the real gate. The record
# block is composed in even where a scenario emits no record (#152): the point
# of the skeleton is that it is the script's actual tail, and a tail assembled
# from three of its four blocks is a different tail.
# ---------------------------------------------------------------------------
VERDFN="$(mktemp)"; SUMFN="$(mktemp)"; RECFN="$(mktemp)"
awk '/^# >>> drill verdicts/,/^# <<< drill verdicts/' "$ROOT/drill/drill.sh" > "$VERDFN"
awk '/^# >>> ledger summary/,/^# <<< ledger summary/' "$ROOT/drill/drill.sh" > "$SUMFN"
awk '/^# >>> drill record/,/^# <<< drill record/'     "$ROOT/drill/drill.sh" > "$RECFN"
check "drill summary: the verdict helpers extract (guards the awk)" 0 "pass=\$((pass + 1))" \
  cat "$VERDFN"
check "drill summary: the summary extracts (guards the awk)" 0 "the drill ran SHORT:" cat "$SUMFN"
# The gate must be INSIDE the extracted window, or the scenarios below run an
# exit path that is not the script's. This is what stops the hole reopening by
# the gate simply moving out from under the marker.
# shellcheck disable=SC2016  # a literal in the target file
check "drill summary: ...with the exit gate inside the window, not below it" 0 "" \
  grep -qF '[ "$fail" -eq 0 ]' "$SUMFN"

# Run the composed skeleton. $1 is the state a finished drill would be in.
# RECORD empty is a drill run without --emit-record, which is still the common
# case; the scenarios that DO emit one set it, further down.
run_summary() {
  # The settings the block documents itself as assuming, and no more: a skeleton
  # that supplied extras would prove the tail runs on a state the script never
  # produces. CHECKOUT and BOX_SHARE joined RECORD and KEEP when the tree
  # stopped being a repo/ref pair and the install root stopped being a
  # hard-coded $HOME path (#225); TREE_DIRTY joined them when the tree's
  # dirtiness stopped being re-read at summary time and became a fact the
  # preflight latched and the re-exec carried here (round 2, #225) — which is
  # exactly why the summary can no longer derive it and must be handed it.
  # CHECKOUT and BOX_SHARE are placeholders and neither is read: RECORD is
  # empty, so nothing in these scenarios collects a record. The scenarios that
  # DO emit one, further down, pass real fixtures.
  bash -c "set -u; . '$VERDFN'; . '$LEDGERFN'; . '$RECFN'
    RECORD=''; CHECKOUT=/nonexistent/checkout; BOX_SHARE=/nonexistent/install; KEEP=0
    TREE_DIRTY=0
    $1; . '$SUMFN'"
}
summary_lacks() {   # 0 when the composed run does NOT say $1
  local needle="$1"; shift
  ! run_summary "$1" 2>&1 | grep -qF -e "$needle"
}
COMPLETE="$FULL; pass=71; fail=0"

check "drill summary: a complete run reports 71/71 and EXITS 0" 0 "71/71 passed, 0 failed" \
  run_summary "$COMPLETE"

# THE regression, end to end. Phase C never executed: 62 verdicts, none of them
# failing, and the drill used to leave here 0 with "62 passed, 0 failed" on the
# line an operator transcribes into drills/<version>.md as proof.
check "drill summary: a phase that never ran EXITS NON-ZERO" 1 "the drill ran SHORT:" \
  run_summary "$COMPLETE; PHASE_RAN[C]=0; pass=62"
check "drill summary: ...naming the short phase, against the full denominator" 1 \
  "short in: C(0/9)" run_summary "$COMPLETE; PHASE_RAN[C]=0; pass=62"
check "drill summary: ...and the record carries 62/71, not a clean 62" 1 \
  "62/71 passed, 1 failed" run_summary "$COMPLETE; PHASE_RAN[C]=0; pass=62"
# The verdict names both roads to a short phase, not just the commoner one.
check "drill summary: ...and does not diagnose 'never ran' as the only cause" 1 \
  "or failed before emitting the rest" run_summary "$COMPLETE; PHASE_RAN[C]=0; pass=62"

# A DECLARED skip is the line between honest and tuned-down: same 62 verdicts,
# but the run said which nine it was not going to emit, and why.
check "drill summary: a declared skip lowers the floor and EXITS 0" 0 \
  "62/62 passed, 0 failed" \
  run_summary "$COMPLETE; skipped C 9 'no isolation stack'; PHASE_RAN[C]=0; pass=62"
check "drill summary: ...and the SKIP survives into the findings block" 0 \
  "SKIP: no isolation stack" \
  run_summary "$COMPLETE; skipped C 9 'no isolation stack'; PHASE_RAN[C]=0; pass=62"

# The other road to non-zero: nothing short, one thing genuinely failed. Both
# roads have to work, and the second must not be reported as the first.
check "drill summary: a complete run with one real FAIL EXITS NON-ZERO" 1 \
  "70/71 passed, 1 failed" run_summary "$COMPLETE; pass=70; fail=1"
check "drill summary: ...and is not mislabelled as a short run" 0 "" \
  summary_lacks "the drill ran SHORT:" "$COMPLETE; pass=86; fail=1"

# ---------------------------------------------------------------------------
# The record emitter (#152). drills/README.md asks a record for six things and
# drill.sh printed none of them in that shape, so every record was retyped by
# hand out of coloured terminal output at the end of a forty-minute run — and
# two fields (the shared run ID, the wall clock) did not exist to retype.
#
# Same doctrine as the ledger above it: the emitter is a self-contained block
# precisely so the SHAPE of a record can be driven on a host with no Incus, no
# drill and no network. record_collect() touches the world; record_write()
# touches nothing but the REC_* set, which is what makes it assertable here.
# ---------------------------------------------------------------------------
check "drill record: extracted from drill.sh (guards the awk)" 0 "record_write" cat "$RECFN"
check "drill record: the extracted block is valid bash" 0 "" bash -n "$RECFN"

RECWORK="$(mktemp -d)"; RECOUT="$RECWORK/emitted.md"
# The block assumes the verdict helpers and the ledger, and nothing else — so
# the harness supplies exactly those, exactly as the drill does.
rec() { bash -c "set -u; . '$VERDFN'; . '$LEDGERFN'; . '$RECFN'; $1"; }

# Two fixtures, because record_collect now takes both halves of what a record
# describes: the CHECKOUT it drilled and the INSTALL ROOT the tree landed in
# (#225). Neither is inferred from the environment any more — the checkout used
# to be a repo/ref pair off the command line and the install root a hard-coded
# $HOME path, and each was wrong for a case that actually happened.
RECGIT="$RECWORK/checkout"
git init -q "$RECGIT"
git -C "$RECGIT" symbolic-ref HEAD refs/heads/trunk
git -C "$RECGIT" config user.email drill@example.invalid
git -C "$RECGIT" config user.name drill
git -C "$RECGIT" config commit.gpgsign false
git -C "$RECGIT" remote add origin https://github.com/heavy-duty/box.git
: > "$RECGIT/tracked"
git -C "$RECGIT" add tracked
git -C "$RECGIT" commit -q -m 'the commit a record names'
# Read with git, asserted against the function: the criterion is that the two
# agree, so writing the SHA here by hand would assert the fixture and not the
# measurement.
RECGITSHA="$(git -C "$RECGIT" rev-parse --short=7 HEAD)"
RECGITREF="$(git -C "$RECGIT" rev-parse --abbrev-ref HEAD)"

RECNOTGIT="$RECWORK/not-a-checkout"; mkdir -p "$RECNOTGIT"
RECINST="$RECWORK/install-root"; mkdir -p "$RECINST/current"
printf '9.9.9\n' > "$RECINST/current/VERSION"

# The install root is an ARGUMENT because it is resolved by uid: a root install
# lands in /opt/box and a per-user one under $HOME, and a reader hard-coding
# either reports 'unknown' for half the hosts that run it — silently, which is
# how the uid defect stayed invisible until a root run was attempted.
check "drill record: the version is read from the install root it is given" 0 \
  "[9.9.9]" rec "printf '[%s]' \"\$(record_version '$RECINST')\""
check "drill record: ...and an install root with no tree is 'unknown', not blank" 0 \
  "[unknown]" rec "printf '[%s]' \"\$(record_version '$RECWORK/nothing-here')\""

# --- the run ID, which had no mechanism at all before this ------------------
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: the default run ID is drill-<version>-<date>-01" 0 \
  "[drill-9.9.9-20260721-01]" rec 'printf "[%s]" "$(record_run_id 9.9.9 20260721)"'
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...and record_collect derives it from the collected date" 0 \
  "[drill-9.9.9-20260721-01]" \
  rec "REC_VERSION=9.9.9; REC_DATE=2026-07-21; record_collect '$RECGIT' '$RECINST' 0 0; printf '[%s]' \"\$REC_RUN_ID\""
# An ID passed in is the release set's shared one and must survive collection
# untouched — three repos reconciling on it is the entire reason it exists.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...but a pinned run ID is never regenerated" 0 "[drill-shared-42]" \
  rec "REC_RUN_ID=drill-shared-42; REC_VERSION=9.9.9; REC_DATE=2026-07-21; record_collect '$RECGIT' '$RECINST' 0 0; printf '[%s]' \"\$REC_RUN_ID\""

# --- the wall clock, the other field that did not exist ---------------------
# drills/README.md's worked example writes "41 minutes wall clock"; 2460s is it.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: seconds become the phrase the worked example uses" 0 \
  "[41 minutes wall clock]" rec 'printf "[%s]" "$(record_wallclock 2460)"'
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...rounded to the nearest minute, not truncated" 0 "[42 minutes" \
  rec 'printf "[%s]" "$(record_wallclock 2490)"'
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...and a sub-minute run is not '0 minutes'" 0 "[under a minute" \
  rec 'printf "[%s]" "$(record_wallclock 30)"'
# An unmeasured clock says so. Guessing here would put a fabricated duration in
# the one artifact whose whole job is to be believed months later.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: an unmeasured clock is stated, never guessed" 0 \
  "[wall clock not measured]" rec 'printf "[%s]" "$(record_wallclock "")"'
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...and neither is a mangled one" 0 "[wall clock not measured]" \
  rec 'printf "[%s]" "$(record_wallclock abc)"'

# --- the three fields, MEASURED off the checkout (#225) ---------------------
# record_sha() and two shims lived here: a fake git answering `ls-remote` and a
# fake curl answering the commits API, with a peeled-ref fixture for annotated
# tags. All of it existed because the drill installed over the network and knew
# its subject only as a repo/ref pair somebody typed — so the pair had to be
# expanded by a REMOTE, and every branch of that expansion described what had
# been requested rather than what ran. The subject is the checkout now and the
# three fields are read off it, so the fixture is a REAL git repository: what is
# under test is git's own answer, and a shim inventing one would prove nothing
# about a tree.
check "drill tree: the SHA is what 'git rev-parse HEAD' says in that checkout" 0 \
  "[$RECGITSHA]" rec "printf '[%s]' \"\$(record_tree_sha '$RECGIT')\""
check "drill tree: the ref is what 'git rev-parse --abbrev-ref HEAD' says" 0 \
  "[$RECGITREF]" rec "printf '[%s]' \"\$(record_tree_ref '$RECGIT')\""
check "drill tree: ...which is the branch, not a default anybody guessed" 0 "[trunk]" \
  rec "printf '[%s]' \"\$(record_tree_ref '$RECGIT')\""
# A release candidate is most often drilled from a detached HEAD (`git checkout
# <tag>`), where --abbrev-ref answers the literal string HEAD. 'HEAD' names no
# tree to a reader six months later; the word for it does, and the SHA beside it
# is the fact that carries there anyway.
check "drill tree: a detached HEAD is named as one, never recorded as 'HEAD'" 0 \
  "[detached]" rec "git -C '$RECGIT' checkout -q --detach >/dev/null 2>&1
                    printf '[%s]' \"\$(record_tree_ref '$RECGIT')\""
check "drill tree: ...and the SHA is unchanged by the detach" 0 "[$RECGITSHA]" \
  rec "printf '[%s]' \"\$(record_tree_sha '$RECGIT')\""
# A candidate is detached ONTO something. drills/README.md's release procedure
# is `git checkout release/0.10.0` then drill, and that tag is the name the
# retired --ref flag used to be handed — so the record keeps saying it rather
# than falling back to the word for having no name at all (round 1, #225).
git -C "$RECGIT" tag v0.0.1-drilltest
check "drill tree: a detached HEAD exactly on a tag records the TAG" 0 \
  "[v0.0.1-drilltest]" \
  rec "printf '[%s]' \"\$(record_tree_ref '$RECGIT')\""
# Only an EXACT match. `describe` would happily answer "two commits past the
# tag" for a tree that is not the tag, and a record that blurs the two is worse
# than one that admits the tree has no name.
check "drill tree: ...but a commit PAST the tag is 'detached', not the tag" 0 \
  "[detached]" \
  rec "git -C '$RECGIT' commit -q --allow-empty -m past >/dev/null 2>&1
       printf '[%s]' \"\$(record_tree_ref '$RECGIT')\""
git -C "$RECGIT" tag -d v0.0.1-drilltest >/dev/null
git -C "$RECGIT" checkout -q trunk
# A BRANCH still wins outright: --abbrev-ref answers, and no tag is consulted.
git -C "$RECGIT" tag v0.0.2-drilltest
check "drill tree: a branch checkout still records the branch, tag or no tag" 0 \
  "[trunk]" rec "printf '[%s]' \"\$(record_tree_ref '$RECGIT')\""
git -C "$RECGIT" tag -d v0.0.2-drilltest >/dev/null

# The repository, off origin. The record has always carried owner/repo, so the
# four URL shapes git hands out reduce to it and old records stay comparable.
# A FORK is the case this was measured on: the 0.10.0 candidate lived on
# andriujoseba/box, and a record that could not say so is the defect.
check "drill tree: an https origin becomes owner/repo" 0 "[heavy-duty/box]" \
  rec "printf '[%s]' \"\$(record_tree_repo '$RECGIT')\""
recrepo() {   # recrepo <url> → what that origin is recorded as
  git -C "$RECGIT" remote set-url origin "$1"
  rec "printf '[%s]' \"\$(record_tree_repo '$RECGIT')\""
}
check "drill tree: ...and so does an https origin with no .git suffix" 0 \
  "[heavy-duty/box]" recrepo https://github.com/heavy-duty/box
check "drill tree: ...and an scp-style ssh remote, which is how a fork is cloned" 0 \
  "[andriujoseba/box]" recrepo git@github.com:andriujoseba/box.git
check "drill tree: ...and an ssh:// URL" 0 "[andriujoseba/box]" \
  recrepo ssh://git@github.com/andriujoseba/box.git
# USERINFO. A clone made by CI or a credential helper carries user[:token]@ in
# front of the host, and it is still GitHub. A version of this that prefix-
# matched whole URLs classified these as private hosts and wrote them VERBATIM
# into drills/<version>.md — a committed file — so a token in an origin URL
# became a token in git history. None of the four shapes above carries userinfo,
# which is exactly why none of them caught it (round 1, #225).
check "drill tree: an https origin with a user still reduces to owner/repo" 0 \
  "[heavy-duty/box]" recrepo https://someuser@github.com/heavy-duty/box.git
check "drill tree: ...and one carrying a TOKEN, which is the leak" 0 \
  "[heavy-duty/box]" \
  recrepo https://x-access-token:ghp_notarealtoken@github.com/heavy-duty/box.git
check "drill tree: ...and an scp-style remote whose user is not 'git'" 0 \
  "[andriujoseba/box]" recrepo someuser@github.com:andriujoseba/box.git
check "drill tree: ...and an ssh:// URL with no user at all" 0 \
  "[andriujoseba/box]" recrepo ssh://github.com/andriujoseba/box.git
# The property is not "no github.com credential reaches a record", it is that NO
# credential does: a private host's URL is carried verbatim, and verbatim used to
# include the token. So the verbatim arm is rebuilt from the URL's own parts —
# scheme, host, path, everything the record wants — minus the userinfo.
norecred() {   # norecred <url> <secret> — 0 when <secret> is NOT in the field
  local out; out="$(recrepo "$1")"
  case "$out" in
    *"$2"*) echo "the record field carries the credential: $out"; return 1 ;;
  esac
  printf '%s' "$out"
}
check "drill tree: a private host keeps its scheme, host and path" 0 \
  "[https://git.example.invalid/mirrors/box.git]" \
  norecred https://ci:s3cr3t@git.example.invalid/mirrors/box.git s3cr3t
check "drill tree: ...and a GitHub token cannot reach the field either" 0 "" \
  norecred https://x-access-token:ghp_notarealtoken@github.com/heavy-duty/box.git \
  ghp_notarealtoken
# Anything that is not GitHub is carried VERBATIM. Mangling a path or a private
# host into owner/repo would put a repository in the record that does not exist.
check "drill tree: a non-GitHub remote is recorded verbatim, not mangled" 0 \
  "[/srv/mirrors/box.git]" recrepo /srv/mirrors/box.git
check "drill tree: ...and so is an ssh:// one on a private host" 0 \
  "[ssh://git.example.invalid/mirrors/box.git]" \
  recrepo ssh://git@git.example.invalid/mirrors/box.git
# The host is matched case-INSENSITIVELY, hostnames being case-insensitive: a
# `GitHub.com` origin is the same host, and carrying it verbatim would put a
# record beside its siblings that no longer compares with them (round 2, #225).
check "drill tree: the host match ignores case, as hostnames do" 0 \
  "[heavy-duty/box]" recrepo https://GitHub.com/heavy-duty/box.git
check "drill tree: ...and that does not loosen the exact-host match" 0 \
  "[https://github.com.evil.invalid/heavy-duty/box.git]" \
  recrepo https://github.com.evil.invalid/heavy-duty/box.git
# A trailing slash after the suffix. '.git' was stripped first and found nothing
# at the end to strip, so the record carried 'heavy-duty/box.git' — the slash
# comes off first now (round 2, #225).
check "drill tree: a trailing slash after '.git' does not survive into the field" 0 \
  "[heavy-duty/box]" recrepo https://github.com/heavy-duty/box.git/
# A GitHub URL with NO PATH reduces to nothing, and nothing is not a reduction:
# an empty field in a record reads as a formatting slip rather than a fact, and
# this function's other absence ('no origin remote') is a stated one. So it
# falls to the verbatim arm like any other URL that does not reduce — and is
# credential-stripped there exactly the same way (round 2, #225).
check "drill tree: a pathless GitHub origin is never an empty field" 0 \
  "[https://github.com]" recrepo https://github.com
check "drill tree: ...and its credential does not survive the fallback" 0 "" \
  norecred https://someuser:pw123@github.com pw123
git -C "$RECGIT" remote set-url origin https://github.com/heavy-duty/box.git
# No origin at all is stated rather than left blank: a blank field in a record
# reads as a formatting slip, and this one is a fact about the checkout.
RECNOORIGIN="$RECWORK/no-origin"
git init -q "$RECNOORIGIN"
check "drill tree: a checkout with no origin says so" 0 "[no origin remote]" \
  rec "printf '[%s]' \"\$(record_tree_repo '$RECNOORIGIN')\""

# --- dirty, the one new failure mode co-location introduces (D5, #225) ------
# Exit 0 means DIRTY, so the caller reads the function as the question it asks.
check "drill tree: a clean checkout is not dirty" 1 "" \
  rec "record_tree_dirty '$RECGIT'"
check "drill tree: a modified tracked file is dirty, and is NAMED" 0 " tracked" \
  rec "printf x >> '$RECGIT/tracked'; record_tree_dirty '$RECGIT'"
git -C "$RECGIT" checkout -q -- tracked
# An untracked file counts. install.sh copies the whole tree, so it is in the
# box that ran, and it is not in the commit the record names either — which is
# the entire test, and the one a --porcelain reading limited to tracked files
# would fail.
check "drill tree: an untracked file is dirty too — install.sh ships it" 0 "stray" \
  rec "touch '$RECGIT/stray'; record_tree_dirty '$RECGIT'"
rm -f "$RECGIT/stray"
check "drill tree: ...and the checkout is clean again once it is gone" 1 "" \
  rec "record_tree_dirty '$RECGIT'"

# --- a tree git cannot read ------------------------------------------------
# Every function above has a soft answer for one, and each of those is a record
# that says less than it appears to. record_tree_is_git is what the preflight
# asks first so the soft answers are never reached in a real run.
check "drill tree: a directory that is not a checkout is not one" 1 "" \
  rec "record_tree_is_git '$RECNOTGIT'"
check "drill tree: ...and the real checkout is" 0 "" \
  rec "record_tree_is_git '$RECGIT'"
check "drill tree: an unreadable tree's SHA is 'unresolved', never blank" 0 \
  "[unresolved]" rec "printf '[%s]' \"\$(record_tree_sha '$RECNOTGIT')\""

# --- the path guard, which runs BEFORE the host is formatted ----------------
check "drill record: no --emit-record is not an error" 0 "" rec 'record_check_path ""'
check "drill record: a writable path is accepted" 0 "" rec "record_check_path '$RECWORK/new.md'"
check "drill record: a missing directory is refused, and named" 2 "no such directory" \
  rec "record_check_path '$RECWORK/nope/rec.md'"
# THE guard that matters. The emitted file is a skeleton the operator writes
# prose into, and that edited file is the release evidence the gate reads. A
# second run pointed at it would eat exactly the judgement calls that make it
# evidence — so it does not get to, and it finds out at startup rather than
# forty minutes in.
printf 'a hand-edited record\n' > "$RECWORK/taken.md"
check "drill record: an existing record is never overwritten" 2 "already exists" \
  rec "record_check_path '$RECWORK/taken.md'"
check "drill record: ...and the refusal says why that matters" 2 "destroys the judgement" \
  rec "record_check_path '$RECWORK/taken.md'"
: > "$RECWORK/empty.md"
check "drill record: ...while an empty file is not a record and may be used" 0 "" \
  rec "record_check_path '$RECWORK/empty.md'"

# --- one candidate ref, and no pin to read off a stamp ----------------------
# What lived here was the converger pin: read off the mint's own stamp (#150,
# #103) because the environment could no longer answer, driven against a shim
# incus, and carried into the reproduce-prefix. #214 removed the installation,
# the stamp and the variable, so the assertions invert — the record names box's
# ref alone, and reaches for nothing else.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: collects no converger repo (#214)" 0 "[]" \
  rec "record_collect '$RECGIT' '$RECINST' 0 0; printf '[%s]' \"\${REC_RIG_REPO:-}\""
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: collects no converger ref (#214)" 0 "[]" \
  rec "record_collect '$RECGIT' '$RECINST' 0 0; printf '[%s]' \"\${REC_RIG_REF:-}\""
# The pin environment cannot reach the record either. It used to be the first
# fallback record_collect consulted; a run that still honoured it would put a
# variable box never read into the reproduction of a run that never used it.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: a set pin in the environment is not collected (#214)" 0 "[]" \
  rec "export RIG_REPO=you/rig RIG_REF=topic; record_collect '$RECGIT' '$RECINST' 0 0; printf '[%s%s]' \"\${REC_RIG_REPO:-}\" \"\${REC_RIG_REF:-}\""
# drill_stamp() went with its only caller (#214): a reader with nothing to read
# is a place for the question to come back.
# On ACTING lines again: drill.sh's comments record what drill_stamp() was and
# why the per-role mints left, which is the history the next reader needs.
check "drill record: drill_stamp is gone from drill.sh's code (#214)" 1 "" \
  sf_names "$ROOT/drill/drill.sh" 'drill_stamp'
check "drill record: drill.sh reads no retired stamp at all (#214)" 1 "" \
  sf_names "$ROOT/drill/drill.sh" 'user\.box\.\(role\|rig\)'
check "drill record: drill.sh passes no --role (#214)" 1 "" \
  sf_names "$ROOT/drill/drill.sh" '--role'
# The invocation still has to reproduce the run, so the flags and DRILL_EXPECT
# stay; what leaves is the pin, because a prefix naming a variable box does not
# read would claim a dependency box does not have.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: the invocation carries no converger pin (#214)" 0 \
  "bash drill/drill.sh" \
  rec "export RIG_REF=topic; record_collect '$RECGIT' '$RECINST' 0 0; printf '%s' \"\$REC_INVOCATION\""
INVF="$(mktemp)"
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
rec "export RIG_REPO=you/rig RIG_REF=topic; record_collect '$RECGIT' '$RECINST' 0 0; printf '%s' \"\$REC_INVOCATION\"" > "$INVF" 2>/dev/null
check "drill record: ...not even one set in the environment (#214)" 1 "" \
  grep -qE 'RIG_RE(PO|F)=' "$INVF"
check "drill record: ...and 'unresolved' is never put in a command line (#150)" 1 "" \
  grep -q unresolved "$INVF"
# DRILL_EXPECT is the one env pin left, and it must have survived the removal
# of the two beside it.
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: DRILL_EXPECT still reaches the invocation (#153)" 0 \
  "DRILL_EXPECT=90 bash drill/drill.sh" \
  rec "export DRILL_EXPECT=90; record_collect '$RECGIT' '$RECINST' 0 0; printf '%s' \"\$REC_INVOCATION\""
rm -f "$INVF"
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: ...and --keep-boxes, which changes what was drilled" 0 "--keep-boxes" \
  rec "record_collect '$RECGIT' '$RECINST' 1 0; printf '%s' \"\$REC_INVOCATION\""

# --- what record_collect MEASURES (D4, #225) --------------------------------
# The three fields the issue exists for, end to end: not the readers in
# isolation, but what a collection off a real checkout actually puts in the
# REC_* set. These used to be $1 and $2 echoed back — the record described the
# arguments the run was given, which is the property drills/README.md says makes
# a record prove nothing later.
collected() {   # collected <field> [snippet] [tree-dirty] → that field, off the fixture
  rec "${2:-}
       record_collect '$RECGIT' '$RECINST' 0 ${3:-0}
       printf '[%s]' \"\$$1\""
}
check "drill record: the collected SHA is the checkout's HEAD" 0 "[$RECGITSHA]" \
  collected REC_TREE_SHA
check "drill record: the collected ref is the checkout's branch" 0 "[$RECGITREF]" \
  collected REC_TREE_REF
check "drill record: the collected repo is the checkout's origin" 0 "[heavy-duty/box]" \
  collected REC_TREE_REPO
# Every field stays pinnable, which is what lets this suite drive record_write
# on a host with no drill: collection fills only what is not already set.
check "drill record: a pinned field is still never overwritten by collection" 0 \
  "[pinned/repo]" collected REC_TREE_REPO 'REC_TREE_REPO=pinned/repo;'

# The dirty stamp, and the whole price of --allow-dirty. A record naming a
# commit that is not what ran is the same untruth this issue closes, so the
# field that names it stops naming a branch anybody can check out.
#
# The fact arrives as an ARGUMENT now and is not re-read here (round 2, #225):
# collection runs at the end of a forty-minute drill and the tree it can see by
# then is not the one that was installed. The fixture is still dirtied, because
# the SHA the stamp is built from is read off it — what moved is WHO measured
# the dirtiness, and that measurement is driven against the latch below.
dirty_collected() {   # dirty_collected <field> → that field, off a DIRTY fixture
  printf 'uncommitted\n' >> "$RECGIT/tracked"
  collected "$1" '' 1
  git -C "$RECGIT" checkout -q -- tracked
}
check "drill record: a dirty checkout stamps the ref field '-dirty'" 0 \
  "[$RECGITSHA-dirty]" dirty_collected REC_TREE_REF
check "drill record: ...and the SHA beside it is still the commit it diverged from" 0 \
  "[$RECGITSHA]" dirty_collected REC_TREE_SHA
# ...and the invocation says so too, for the reason --keep-boxes is in it: both
# change what was drilled. Read off the TREE and not off the flag, like every
# other field here.
check "drill record: ...and the reproducing command carries --allow-dirty" 0 \
  "--allow-dirty" dirty_collected REC_INVOCATION
clean_invocation_is_dirty() { collected REC_INVOCATION | grep -q -- --allow-dirty; }
check "drill record: a clean checkout's command carries no --allow-dirty" 1 "" \
  clean_invocation_is_dirty

# THE TRANSITION (round 2, #225). The fixture below is CLEAN at this moment and
# the latched fact says the tree was dirty when install.sh copied it — which is
# what a run looks like when the operator stashes or commits during the forty
# minutes. Collection used to re-ask git here and believe the answer, so the
# record named a clean branch, dropped --allow-dirty from the line that claims
# to reproduce the run, and described a checkout nobody had installed. The two
# checks below fail on that version and pass on this one; the suite covered
# dirty-at-collection and clean-at-collection but never the step between them.
check "drill record: a tree cleaned MID-DRILL still stamps what was installed" 0 \
  "[$RECGITSHA-dirty]" collected REC_TREE_REF '' 1
check "drill record: ...and its reproducing command still carries --allow-dirty" 0 \
  "--allow-dirty" collected REC_INVOCATION '' 1
# ...and the converse, so the fix is a carried FACT and not a stamp welded on:
# a tree dirtied after the install was measured clean records a clean ref.
dirtied_after_install() {   # <field> → that field for a tree dirtied mid-drill
  printf 'uncommitted\n' >> "$RECGIT/tracked"
  collected "$1" '' 0
  git -C "$RECGIT" checkout -q -- tracked
}
check "drill record: a tree dirtied AFTER the install records the clean ref" 0 \
  "[$RECGITREF]" dirtied_after_install REC_TREE_REF

# --- the record itself ------------------------------------------------------
# A finished drill, pinned so every field is assertable. record_collect fills
# only what is not already set, which is what lets a test pin the world away.
RECSTATE="PHASE_RAN=([I]=1 [A]=8 [B]=45 [C]=9 [E]=7 [D]=0 [M]=10 [T]=1)
REC_VERSION=9.9.9; REC_DATE=2026-07-21; REC_HOST='bare Debian 13, Incus 6.0.2'
REC_RUN_ID=drill-9.9.9-20260721-01; REC_TREE_SHA=abc1234
REC_TREE_REF=release/9.9.9; REC_TREE_REPO=heavy-duty/box
REC_ELAPSED=2460; record_collect '$RECGIT' '$RECINST' 0 0"
emit() {   # emit <state> → the record that state produces, on stdout
  rm -f "$RECOUT"
  rec "$RECSTATE; $1; record_write '$RECOUT'" >/dev/null 2>&1
  cat "$RECOUT" 2>/dev/null
}
CLEAN='pass=71; fail=0'

# drills/README.md:34-42 asks for six things. One check each, because a record
# missing one of them is the hand-transcription this replaces, reintroduced.
check "drill record: names the version, as the filename must match" 0 \
  "# Release drill — 9.9.9" emit "$CLEAN"
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: carries the run ID the sibling repos reconcile on" 0 \
  '**Run ID:** `drill-9.9.9-20260721-01`' emit "$CLEAN"
check "drill record: names the host — 'real hardware' is the claim" 0 \
  "**Host:** bare Debian 13, Incus 6.0.2" emit "$CLEAN"
check "drill record: dates the run" 0 "**Date:** 2026-07-21" emit "$CLEAN"
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill record: pins box's candidate ref TO A SHA" 0 \
  'box `release/9.9.9` @ `abc1234`' emit "$CLEAN"
# ...and box's is the ONLY candidate ref the record names now (#214). The
# second row said which converger the mint had installed; box installs none, so
# a row there would be a combination nobody drilled being claimed as one.
# Called from THIS shell: emit() is not exported, and a 127 from a child would
# satisfy an absence assertion by never having run. Counted rather than
# absence-grepped, because box's own row has the same shape as the one that
# left — an absence assertion here would have to exclude 'box' by name and
# would then go green on any THIRD row somebody adds.
record_ref_rows() { emit "$1" | grep -cE '^  - [a-z]+ `'; }
check "drill record: names exactly ONE candidate ref — box's (#214)" 0 "1" \
  record_ref_rows "$CLEAN"
check "drill record: says what ran, as a command that reproduces it" 0 \
  'bash drill/drill.sh' emit "$CLEAN"
# ...and the command names no tree, which is the point rather than an omission:
# the tree is the checkout, so the reproduction is the quickstart's own two
# lines run from the commit the field above names. A --repo/--ref pair here
# described what had been REQUESTED and could differ from what ran (#225).
record_invocation_names_a_tree() { emit "$1" | grep -qE '^`.*--(repo|ref) '; }
check "drill record: ...and names no repo or ref in it, there being none to get wrong" \
  1 "" record_invocation_names_a_tree "$CLEAN"
check "drill record: gives the numbers and the wall clock" 0 \
  "**71/71 passed, 0 failed.** 41 minutes wall clock." emit "$CLEAN"
check "drill record: carries the per-phase ledger a single total cannot say" 0 \
  "B 45/45" emit "$CLEAN"
check "drill record: states the floor and the table's total as two facts" 0 \
  "Probe floor: 71 expected this run; the table declares 71." emit "$CLEAN"
# DRILL_EXPECT can raise the floor above the table, and the record must not read
# that as an error — the operator is deliberately demanding more than the table.
check "drill record: ...which stays readable when DRILL_EXPECT raises the floor" 0 \
  "Probe floor: 90 expected this run; the table declares 71." \
  emit "DRILL_EXPECT=90; $CLEAN"
# The record is pasted into a file and read months later. Escape codes in it are
# the peculiar thing this issue found: every script emitted ANSI unconditionally.
# Emitted here rather than read from the check above, so the assertion owns the
# file it grades and a reordering cannot quietly grade a stale one.
emit "$CLEAN; no 'a coloured failure' >/dev/null" >/dev/null
check "drill record: contains no ANSI, whatever the terminal was" 1 "" \
  grep -q $'\033' "$RECOUT"

# THE thing the harness must not do. A generated file that reads like a finished
# one invites exactly the transcription-free confidence the last two waivers
# were written under, so it says what it is — in rendered text, not an HTML
# comment nobody sees.
check "drill record: says out loud that it is a draft, not a record" 0 \
  "Draft — a generated skeleton" emit "$CLEAN"
check "drill record: ...and says the judgement is the operator's to write" 0 \
  "a judgement it must not fabricate" emit "$CLEAN"

# THE #153 regression, in the artifact #153 exists to protect. A run that emitted
# 62 of 71 and failed none is not "62/62 passed" — and the record is precisely
# where that fraction used to get written down as proof a release was drilled.
check "drill record: a short run's denominator is the FLOOR, not what ran" 0 \
  "**62/71 passed" emit "pass=62; fail=0; PHASE_RAN[C]=0"
check "drill record: ...and the short phase is named in it" 0 "C 0/9" \
  emit "pass=62; fail=0; PHASE_RAN[C]=0"
# A DECLARED skip is the honest half: the floor moves, and the record says which
# probes were not expected and why — recorded as skipped, never as passing.
check "drill record: a declared skip lowers the record's denominator" 0 \
  "**62/62 passed" emit "pass=62; fail=0; PHASE_RAN[C]=0; skipped C 9 'no isolation stack' >/dev/null"
check "drill record: ...and the skip is recorded AS a skip, beside the failures" 0 \
  "- SKIP: no isolation stack" \
  emit "pass=62; fail=0; PHASE_RAN[C]=0; skipped C 9 'no isolation stack' >/dev/null"
check "drill record: ...and the waived probes are visible in the ledger line" 0 \
  "9 waived by declared skips" \
  emit "pass=62; fail=0; PHASE_RAN[C]=0; skipped C 9 'no isolation stack' >/dev/null"
check "drill record: failures land in it verbatim, uncoloured" 0 "- FAIL: the boundary held open" \
  emit "pass=86; fail=1; no 'the boundary held open' >/dev/null"
check "drill record: a clean run says so rather than leaving a bare heading" 0 \
  "Nothing to report" emit "$CLEAN"

# The audit answers, in the record rather than only on a terminal (#154). They
# were printed under a header telling a human to paste them into an issue that
# has since closed, in a repo that has been renamed — the last field still being
# retyped out of coloured output, which is the defect this emitter exists to end.
check "drill record: the audit answers land in it, not only on the terminal" 0 \
  "- A3 sibling: BLOCKED — tcp dropped" \
  emit "$CLEAN; aud 'A3 sibling: BLOCKED — tcp dropped'"
check "drill record: ...under their own heading, because they are measurements" 0 \
  "## Audit answers" emit "$CLEAN; aud 'A6 ipv6: none, as contract requires'"
# The reason they are not folded into `findings`: a real run always has audit
# answers, so folding them would retire the clean-run line entirely — a record
# could never again say plainly that nothing was wrong.
check "drill record: ...and a clean run with answers still reports nothing wrong" 0 \
  "Nothing to report" emit "$CLEAN; aud 'A6 ipv6: none, as contract requires'"
# A run with no answers grows no empty heading. Emitted here rather than read
# from a check above, so the assertion owns the file it grades.
emit "$CLEAN" >/dev/null
check "drill record: a run with no audit answers grows no empty section" 1 "" \
  grep -q '## Audit answers' "$RECOUT"

# --- the emitter on the real exit path --------------------------------------
# Everything above drives record_write directly. None of it proves the DRILL
# emits, or that emitting cannot disturb the exit status #153 made load-bearing.
# So run the composed skeleton — the script's actual tail — with a record path.
run_emit() {   # run_emit <state> — EXIT STATUS is the drill's own
  rm -f "$RECOUT"
  bash -c "set -u; . '$VERDFN'; . '$LEDGERFN'; . '$RECFN'
    RECORD='$RECOUT'; CHECKOUT='$RECGIT'; BOX_SHARE='$RECINST'; KEEP=0
    TREE_DIRTY=0
    RUN_ID=drill-9.9.9-20260721-01
    $RECSTATE; $1
    . '$SUMFN'"
}
check "drill emit: a clean run writes the record and still EXITS 0" 0 \
  "record written:" run_emit "$CLEAN"
check "drill emit: ...and the file on disk is the record" 0 "**71/71 passed, 0 failed.**" \
  cat "$RECOUT"
check "drill emit: ...pinned to the run ID the drill announced at install time" 0 \
  "drill-9.9.9-20260721-01" cat "$RECOUT"
check "drill emit: ...and the operator is told it is a skeleton to edit" 0 \
  "it is a SKELETON" run_emit "$CLEAN"
# The terminal block is retargeted at the same reader, so the two agree about
# where an audit answer goes. What it must never do again is send an operator to
# heavy-duty/claudebox#15: complete, and in a repo that has been renamed (#154).
check "drill emit: the terminal audit block is headed for the record" 0 \
  "Isolation audit answers" run_emit "$CLEAN; aud 'A6 ipv6: none, as contract requires'"
check "drill: ...and no phase header sends the operator to the closed audit" 1 "" \
  grep -qF 'phase - "#15 audit answers' "$ROOT/drill/drill.sh"

# The record is written AFTER the shortfall verdict, so it carries it. Emitting
# before that `no` fires would put a clean sweep in the record on a short run,
# which is the defect #153 closed.
check "drill emit: a short run EXITS NON-ZERO with a record written" 1 \
  "record written:" run_emit "pass=62; fail=0; PHASE_RAN[C]=0"
check "drill emit: ...and the record it wrote carries the shortfall, not a sweep" 0 \
  "FAIL: the drill ran SHORT:" cat "$RECOUT"
check "drill emit: ...against the full denominator, 62/71" 0 "**62/71 passed" cat "$RECOUT"
check "drill emit: a short run has no unattributed summary probe" 1 "" \
  grep -q 'unattributed' "$RECOUT"
short_ledgers_agree() {
  local out terminal emitted
  out="$(run_emit 'pass=62; fail=0; PHASE_RAN[C]=0')"
  terminal="$(printf '%s\n' "$out" | grep '^  probes')"
  # shellcheck disable=SC2016
  emitted="$(sed -n '/^```$/,/^```$/p' "$RECOUT" | grep '^  probes')"
  [ "$terminal" = "$emitted" ]
}
check "drill emit: terminal and emitted ledgers agree on a short run" 0 "" \
  short_ledgers_agree

# A record that cannot be written must not be able to turn a clean drill red:
# the exit status is the floor's verdict on the DRILL, and a full disk has no
# opinion about whether the trust boundary held. It must not be silent either.
check "drill emit: an unwritable path cannot change the drill's verdict" 0 "FAILED to write" \
  bash -c "set -u; . '$VERDFN'; . '$LEDGERFN'; . '$RECFN'
    RECORD='$RECWORK/gone/rec.md'; CHECKOUT='$RECGIT'; BOX_SHARE='$RECINST'
    KEEP=0; TREE_DIRTY=0; RUN_ID=x
    $RECSTATE; $CLEAN
    . '$SUMFN'"
# ...and no --emit-record writes nothing at all, which is still the common run.
check "drill emit: without --emit-record nothing is written" 0 "" \
  bash -c "rm -f '$RECOUT'; . '$VERDFN'; . '$LEDGERFN'; . '$RECFN'
    RECORD=''; CHECKOUT='$RECGIT'; BOX_SHARE='$RECINST'; KEEP=0; TREE_DIRTY=0
    $RECSTATE; $CLEAN; . '$SUMFN' >/dev/null; [ ! -e '$RECOUT' ]"

# --- the wiring, so the emitter cannot be left correct-but-unreachable ------
# The path guard must run before the first phase, for the same reason the
# DRILL_EXPECT guard does: an operator who typo'd it, or who pointed it at a
# record they already wrote, must find out before the host gets formatted.
record_guard_runs_first() {
  local guard first
  # shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
  guard="$(grep -n '^record_check_path "\$RECORD" || exit 2$' "$ROOT/drill/drill.sh" | head -1 | cut -d: -f1)"
  [ -n "$guard" ] || { echo "the record path guard is defined but never called"; return 1; }
  first="$(grep -nE '^[[:space:]]*phase [A-Za-z-]+ ' "$ROOT/drill/drill.sh" | head -1 | cut -d: -f1)"
  [ "$guard" -lt "$first" ] || { echo "the guard runs at $guard, after the first phase at $first"; return 1; }
}
check "drill: the record path guard is called, and before the first phase" 0 "" \
  record_guard_runs_first
# shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
check "drill: the run ID is announced during the run, not only at the end" 0 \
  'inf "run ID: $RUN_ID' grep -F 'run ID:' "$ROOT/drill/drill.sh"

# --- the preflight, EXECUTED (#225) -----------------------------------------
# Three refusals, and a refusal nothing has ever run is a guess about what the
# script does. All three are extracted and driven, the uid ones against canned
# uids rather than a real root — a suite that needed root to prove the root
# branch would prove it on no host anybody runs it on.
PREFN="$(mktemp)"
awk '/^# >>> drill preflight/,/^# <<< drill preflight/' "$ROOT/drill/drill.sh" > "$PREFN"
check "drill preflight: extracted from drill.sh (guards the awk)" 0 "preflight_uid" \
  cat "$PREFN"
check "drill preflight: the extracted block is valid bash" 0 "" bash -n "$PREFN"
# It leans on the record block's tree readers, so it is composed the way the
# script composes it and never in isolation.
pre() { bash -c "set -u; . '$RECFN'; . '$PREFN'; $1"; }

# The install destination, resolved by uid the way install.sh resolves it. This
# is the defect the issue reproduced: install.sh picks by uid (install.sh:39-45)
# and drill.sh wiped and then verified the per-user path unconditionally, so a
# root run installed to /opt/box, read a verification file that never existed,
# and fired a FATAL diagnosing a STALE LOCAL SCRIPT — confidently, and wrongly.
paths() {   # paths <uid> [env...] — what the drill resolves for that uid
  local uid="$1"; shift
  HOME=/home/tester env "$@" bash -c ". '$PREFN'
    resolve_install_paths \"\$1\"
    printf 'DEST=%s BINDIR=%s\n' \"\$BOX_SHARE\" \"\$BOX_BINDIR\"" _ "$uid"
}
check "drill preflight: root resolves the global tree, as install.sh does" 0 \
  "DEST=/opt/box BINDIR=/usr/local/bin" paths 0
check "drill preflight: non-root resolves the per-user tree" 0 \
  "DEST=/home/tester/.local/share/box BINDIR=/home/tester/.local/bin" paths 1000
check "drill preflight: BOX_HOME wins here too, or the drill verifies a path" \
  0 "DEST=/srv/box" paths 1000 BOX_HOME=/srv/box
check "drill preflight: ...and BOX_BIN, the same way" 0 "BINDIR=/srv/bin" \
  paths 0 BOX_BIN=/srv/bin
# ...and the two resolvers AGREE, which is the actual contract: "the same way
# install.sh resolves it" is a claim about two files, so both are run and their
# answers compared. A copy that drifts is what put the drill one directory away
# from the installer in the first place.
# The same extraction the install.sh section ran, through the same function —
# its $DBLOCK was removed up there, so this needs its own copy, not its own
# spelling of how to make one.
DBLOCK2="$(extract_dest_block)"
resolvers_agree() {   # resolvers_agree <uid> [env...]
  local uid="$1"; shift
  local a b
  a="$(run_dest_block "$DBLOCK2" "$uid" "$@")"
  b="$(paths "$uid" "$@")"
  [ "$a" = "$b" ] || { echo "install.sh says [$a], drill.sh says [$b]"; return 1; }
}
check "drill preflight: the drill and install.sh resolve root identically" 0 "" \
  resolvers_agree 0
check "drill preflight: ...and non-root identically" 0 "" resolvers_agree 1000
check "drill preflight: ...and agree about BOX_HOME on both branches" 0 "" \
  resolvers_agree 0 BOX_HOME=/srv/box
rm -f "$DBLOCK2"

# The root refusal. "Either completes or refuses with a message about the uid" —
# and it refuses, because no phase below has ever been run as root: the sg
# re-exec, the sudo calls and the tier box reports for uid 0 all assume the
# ordinary operator account. What must never happen again is the third option,
# a FATAL about a stale script.
check "drill preflight: a non-root uid proceeds" 0 "" pre "preflight_uid 1000"
check "drill preflight: root is refused" 2 "REFUSING to run as root" \
  pre "preflight_uid 0"
check "drill preflight: ...and the refusal is about the uid, by name" 2 "uid 0" \
  pre "preflight_uid 0"
check "drill preflight: ...and says what to run instead" 2 "NOT under sudo" \
  pre "preflight_uid 0"
# THE text that must be unreachable from a root invocation. It is gone from the
# script outright, so it cannot be reached from any invocation.
check "drill preflight: the stale-script diagnosis is gone from drill.sh" 1 "" \
  grep -qF 'probably STALE' "$ROOT/drill/drill.sh"

# The dirty refusal, against the same real fixture the record fields use.
check "drill preflight: a clean checkout proceeds" 0 "" \
  pre "preflight_tree '$RECGIT' 0"
check "drill preflight: a dirty one is refused" 2 "REFUSING to drill a dirty worktree" \
  pre "printf x >> '$RECGIT/tracked'; preflight_tree '$RECGIT' 0"
# Naming the paths is the whole of the message's usefulness: "something is
# dirty" sends the operator to git status, and the refusal already ran it.
check "drill preflight: ...naming the dirty paths" 2 "tracked" \
  pre "preflight_tree '$RECGIT' 0"
check "drill preflight: ...and pointing at the escape hatch" 2 "allow-dirty" \
  pre "preflight_tree '$RECGIT' 0"
# --allow-dirty proceeds, and says what it costs. It is not a silent override:
# the record it produces cannot be reproduced, and the operator is told so
# before the forty minutes rather than after.
check "drill preflight: --allow-dirty proceeds" 0 "" \
  pre "preflight_tree '$RECGIT' 1"
check "drill preflight: ...and warns that the record will be stamped" 0 "'-dirty'" \
  pre "preflight_tree '$RECGIT' 1"
git -C "$RECGIT" checkout -q -- tracked
# A tree git cannot read is refused too. Everything downstream has a soft answer
# for one — 'unresolved', 'no origin remote', not-dirty — and a run that reached
# them would emit a record quietly saying less than it appears to.
check "drill preflight: a tree that is not a checkout is refused" 2 "not a git checkout" \
  pre "preflight_tree '$RECNOTGIT' 0"
check "drill preflight: ...and --allow-dirty does not override that" 2 \
  "not a git checkout" pre "preflight_tree '$RECNOTGIT' 1"
check "drill preflight: ...and the refusal prints the two lines that DO work" 2 \
  "git clone https://github.com/heavy-duty/box" pre "preflight_tree '$RECNOTGIT' 0"

# --- the latch: the tree is measured ONCE, before anything is installed -------
# install.sh copies the checkout in stage 1 and the record is written forty
# minutes later, so every field describing the tree has exactly one moment at
# which it is true. It used to be re-read at summary time, which is a reading of
# a tree that is no longer the one in the box (round 2, #225).
#
# Composed the way the script composes it: the latch is in the preflight block
# and the readers it uses are in the record block, and the five settings it
# fills are declared by the settings block, so the harness seeds them empty the
# way a stage-1 start does.
latch() {   # latch <snippet> → the latched state after that snippet
  bash -c "set -u; . '$RECFN'; . '$PREFN'
    TREE_DIRTY=''; TREE_DIRTY_PATHS=''
    REC_TREE_REPO=''; REC_TREE_REF=''; REC_TREE_SHA=''; TREE_IDENT=''
    $1"
}
latched() {   # latched <field> [snippet] → that field after latching the fixture
  latch "${2:-}
    tree_ident_latch '$RECGIT'
    printf '[%s]' \"\$$1\""
}
check "drill latch: a clean tree latches dirty=0" 0 "[0]" latched TREE_DIRTY
check "drill latch: ...and the record's ref field is the branch" 0 "[$RECGITREF]" \
  latched REC_TREE_REF
check "drill latch: ...and the SHA and repo are the checkout's" 0 \
  "[$RECGITSHA][heavy-duty/box]" \
  latch "tree_ident_latch '$RECGIT'
         printf '[%s][%s]' \"\$REC_TREE_SHA\" \"\$REC_TREE_REPO\""
check "drill latch: a dirty tree latches dirty=1" 0 "[1]" \
  latched TREE_DIRTY "printf 'uncommitted\n' >> '$RECGIT/tracked'"
check "drill latch: ...and stamps the ref field, off the tree and not off a flag" 0 \
  "[$RECGITSHA-dirty]" \
  latched REC_TREE_REF "printf 'uncommitted\n' >> '$RECGIT/tracked'"
# The PATHS are latched with the flag because the NOTE that names them is raised
# on the far side of the sg re-exec, where git can no longer be asked for them.
check "drill latch: ...and the dirty paths are carried, not re-derived later" 0 \
  "tracked" latched TREE_DIRTY_PATHS "printf 'uncommitted\n' >> '$RECGIT/tracked'"
git -C "$RECGIT" checkout -q -- tracked
check "drill latch: a clean tree carries no paths" 0 "[]" latched TREE_DIRTY_PATHS

# THE latch, which is the whole point: an answer already in hand is stage 1's
# measurement arriving over the re-exec, and re-answering it in stage 2 is the
# defect. A second call must change nothing, even against a tree that has since
# been cleaned — that is the run codex reproduced, one function call wide.
check "drill latch: a second call does not re-answer a tree that has changed" 0 \
  "[1]" \
  latch "printf 'uncommitted\n' >> '$RECGIT/tracked'
         tree_ident_latch '$RECGIT'
         git -C '$RECGIT' checkout -q -- tracked
         tree_ident_latch '$RECGIT'
         printf '[%s]' \"\$TREE_DIRTY\""
check "drill latch: ...and the stamped ref it latched survives the second call" 0 \
  "[$RECGITSHA-dirty]" \
  latch "printf 'uncommitted\n' >> '$RECGIT/tracked'
         tree_ident_latch '$RECGIT'
         git -C '$RECGIT' checkout -q -- tracked
         tree_ident_latch '$RECGIT'
         printf '[%s]' \"\$REC_TREE_REF\""
# ...end to end, through record_collect, which is where the defect was VISIBLE:
# dirty at install, clean at collection, and the record still describes the tree
# that ran. This is codex's reproduction as a check.
check "drill latch: a run cleaned mid-drill records what was installed" 0 \
  "[$RECGITSHA-dirty][bash drill/drill.sh --allow-dirty]" \
  latch "printf 'uncommitted\n' >> '$RECGIT/tracked'
         tree_ident_latch '$RECGIT'
         git -C '$RECGIT' checkout -q -- tracked
         record_collect '$RECGIT' '$RECINST' 0 \"\$TREE_DIRTY\"
         printf '[%s][%s]' \"\$REC_TREE_REF\" \"\$REC_INVOCATION\""
git -C "$RECGIT" checkout -q -- tracked
# A COMMIT mid-drill moves the SHA the same way a stash moves the dirty flag,
# and the record must not follow it either: the tree that was installed is the
# one that ran, whatever HEAD says forty minutes on.
check "drill latch: a commit mid-drill does not move the recorded SHA" 0 \
  "[$RECGITSHA]" \
  latch "tree_ident_latch '$RECGIT'
         git -C '$RECGIT' commit -q --allow-empty -m 'mid-drill' >/dev/null 2>&1
         record_collect '$RECGIT' '$RECINST' 0 \"\$TREE_DIRTY\"
         printf '[%s]' \"\$REC_TREE_SHA\""
# That check commits into the shared fixture, so the fixture goes back to the
# commit every assertion above and below it names.
git -C "$RECGIT" reset -q --hard "$RECGITSHA"

# --- the window between the measurement and the copy (round 3, #225) ---------
# The latch above fixes WHEN the tree is read. It does not fix the tree: the
# latch runs before the consent prompt and install.sh copies minutes later, and
# in between the checkout is an ordinary directory. Everything the latch protects
# the record from at summary time can happen inside that window instead, and
# stage 2's re-run of the preflight does not see it — --allow-dirty waves a newly
# dirty tree through, a commit or a switch leaves a CLEAN tree it passes with
# nothing to say, and a rewrite inside an already-dirty path moves no path list.
#
# So the window is guarded by a witness rather than by a path list, and these
# drive it through the same extracted blocks the script runs.
window() {   # window <snippet> → the guard's verdict after that snippet
  latch "tree_ident_latch '$RECGIT'
         $1
         tree_ident_verify '$RECGIT' 'in the window'"
}
check "drill window: a tree that did not move passes" 0 "" window ':'
# The negative that keeps the guard from being a tripwire on ordinary work: the
# window CLOSES at the copy. What the operator does after it is their business,
# and the record already describes what was taken.
check "drill window: ...and the digest of an unmoved tree is stable" 0 "[same]" \
  latch "a=\"\$(record_tree_ident '$RECGIT')\"
         b=\"\$(record_tree_ident '$RECGIT')\"
         [ \"\$a\" = \"\$b\" ] && printf '[same]'"

# codex's case, driven: clean at the latch, a non-bin/box path appears before the
# copy. Under --allow-dirty stage 2's preflight has nothing to say about it, so
# this guard is the only thing between that tree and a record calling it clean.
check "drill window: a file appearing after the latch is refused" 1 \
  "changed in the window" window "touch '$RECGIT/after-latch'"
# The fixture is shared, and a file left behind would be latched by the next
# check rather than appearing after it — which is a pass for the wrong reason.
rm -f "$RECGIT/after-latch"
check "drill window: ...and the refusal names the tree the record would have named" 1 \
  "$RECGITSHA" window "touch '$RECGIT/after-latch'"
rm -f "$RECGIT/after-latch"
# A commit and a switch both leave a tree the preflight is happy with, which is
# why neither is caught anywhere else. The record would name the tree from
# before the move while the box holds the tree from after it.
check "drill window: a commit after the latch is refused" 1 "changed in the window" \
  window "git -C '$RECGIT' commit -q --allow-empty -m 'in-window' >/dev/null 2>&1"
git -C "$RECGIT" reset -q --hard "$RECGITSHA"
check "drill window: a branch switch after the latch is refused" 1 "changed in the window" \
  window "git -C '$RECGIT' switch -q -c in-window-branch >/dev/null 2>&1"
git -C "$RECGIT" switch -q "$RECGITREF" >/dev/null 2>&1
git -C "$RECGIT" branch -q -D in-window-branch >/dev/null 2>&1
# THE case a path list cannot see, and the reason the witness is a digest of the
# content rather than of `git status`: the tree is dirty before the latch and
# dirty after it, in the same path, and the bytes install.sh copies are not the
# bytes that were measured.
printf 'first\n' >> "$RECGIT/tracked"
check "drill window: a rewrite inside an already-dirty path is refused" 1 \
  "changed in the window" window "printf 'second\n' >> '$RECGIT/tracked'"
# ...and that case is invisible to the path list, which is the whole point: the
# check above would not exist if record_tree_dirty could answer it.
check "drill window: ...which the dirty PATH LIST cannot see" 0 "[same]" \
  latch "a=\"\$(record_tree_dirty '$RECGIT')\"
         printf 'second\n' >> '$RECGIT/tracked'
         b=\"\$(record_tree_dirty '$RECGIT')\"
         [ \"\$a\" = \"\$b\" ] && printf '[same]'"
git -C "$RECGIT" checkout -q -- tracked
# The same blindness, one path-class over: an untracked file's CONTENT can be
# rewritten between the latch and the copy without --porcelain moving either,
# and install.sh copies untracked files like every other byte in the tree.
touch "$RECGIT/stray-in-window"
check "drill window: a rewrite inside an already-untracked file is refused" 1 \
  "changed in the window" window "printf 'now with content\n' > '$RECGIT/stray-in-window'"
rm -f "$RECGIT/stray-in-window"
# A path CLEANED in the window moves the record the other way — the run would
# install a clean tree under a '-dirty' stamp naming paths that are no longer
# there — and is refused for the same reason.
check "drill window: a path cleaned after the latch is refused" 1 \
  "changed in the window" \
  latch "printf 'uncommitted\n' >> '$RECGIT/tracked'
         tree_ident_latch '$RECGIT'
         git -C '$RECGIT' checkout -q -- tracked
         tree_ident_verify '$RECGIT' 'in the window'"
git -C "$RECGIT" checkout -q -- tracked
# An unlatched witness is the guard disabled by silence, which is the one way a
# check like this fails without ever printing anything. It fails like a mismatch.
check "drill window: an empty witness is a FATAL, not a pass" 1 \
  "never latched" latch "tree_ident_verify '$RECGIT' 'in the window'"

# --- and the wiring, because the latch can be correct and still bypassed -----
# Everything above drives functions. The consumers that matter are on the
# script's own path — the summary's record_collect call and the dirty-tree NOTE
# raised at the top of stage 2 — and neither is inside an extracted block, so
# what is asserted about them is WHERE THEY READ FROM. The rule is one line
# long: after the drill has re-exec'd into the group, install.sh has already
# copied the checkout, so no acting line past that point may ask git about the
# tree again. That is the defect as a property rather than as a scenario, and
# it is what stops the NOTE quietly going back to a live `git status` (round 2,
# #225).
#
# It names EVERY reader, not just the one round 2 was about. The property is
# "nothing past the re-exec asks git about the tree", and spelling it as one
# function's name made it "nothing past the re-exec asks git about the tree's
# DIRTINESS" — a re-added record_tree_sha there would have gone straight past it
# (round 3, #225). Each of the five asks git the same question about the same
# subject and each is wrong in the same place.
no_tree_read_after_reexec() {
  ( set -u
    local rex line
    rex="$(grep -nE '^[[:space:]]*reexec_in_group[[:space:]]*$' "$ROOT/drill/drill.sh" \
           | head -1 | cut -d: -f1)"
    [ -n "$rex" ] || { echo "the re-exec is never called"; exit 1; }
    while IFS=: read -r line _; do
      [ -z "$line" ] && continue
      [ "$line" -gt "$rex" ] \
        && { echo "line $line re-reads the tree after the re-exec at $rex"; exit 1; }
    done < <(grep -nE '^[^#]*record_tree_(dirty|sha|ref|repo|ident)' "$ROOT/drill/drill.sh")
    exit 0 )
}
check "drill latch: nothing past the re-exec asks git about the tree again" 0 "" \
  no_tree_read_after_reexec
# ...and the guard is not vacuous: the reads that DO exist are the preflight's
# refusal and the latch, both of which run before anything is installed.
check "drill latch: ...and the reads that remain are the two before the install" 0 "2" \
  bash -c "grep -cE '^[^#]*record_tree_dirty \"\\\$1\"' '$ROOT/drill/drill.sh'"

# The window guard has the same shape of hole: it can be perfectly correct and
# never called, or called on one side of the install only. Both of its calls are
# on the script's own path, so what is asserted is that they BRACKET the install
# — one before it, where a refusal costs nothing, one after the copy, which is
# the half no earlier check can reach (round 3, #225).
guard_brackets_install() {
  # shellcheck disable=SC2016  # the install line is literal text in drill.sh
  ( set -u
    local ins pre post
    ins="$(grep -nF 'BOX_INSTALL_SOURCE="$CHECKOUT" bash "$CHECKOUT/install.sh"' \
           "$ROOT/drill/drill.sh" | head -1 | cut -d: -f1)"
    [ -n "$ins" ] || { echo "the install is never run"; exit 1; }
    pre="$(grep -nE '^[^#]*tree_ident_verify .* \|\| exit 1' "$ROOT/drill/drill.sh" \
           | awk -F: -v i="$ins" '$1 < i' | wc -l)"
    post="$(grep -nE '^[^#]*tree_ident_verify .* \|\| exit 1' "$ROOT/drill/drill.sh" \
            | awk -F: -v i="$ins" '$1 > i' | wc -l)"
    [ "$pre" -ge 1 ] || { echo "nothing verifies the tree before the install"; exit 1; }
    [ "$post" -ge 1 ] || { echo "nothing verifies the tree after the copy"; exit 1; }
    exit 0 )
}
check "drill window: the guard brackets the install, before it and after it" 0 "" \
  guard_brackets_install
# ...and it refuses rather than reports. A guard whose exit is dropped prints a
# FATAL into a log nobody reads and drills on, which is the failure it exists to
# prevent, wearing the message it would have printed.
check "drill window: ...and both calls exit rather than warn" 0 "2" \
  bash -c "grep -cE '^[^#]*tree_ident_verify \"\\\$CHECKOUT\" .* \\|\\| exit 1' '$ROOT/drill/drill.sh'"
# The install phase's own header is the first thing in the log that says which
# tree this run drilled, and it used to read the SHA live — so it could name a
# different commit than the record does, from a line printed seconds before the
# copy (round 3, #225). It prints the latched field, like every other consumer.
# shellcheck disable=SC2016  # the header is literal text in drill.sh
check "drill window: the install header names the latched SHA, not a live read" 0 \
  'phase - "Installing box from this checkout ($CHECKOUT @ $REC_TREE_SHA)"' \
  grep -F 'Installing box from this checkout' "$ROOT/drill/drill.sh"
# The witness deliberately does NOT cross the re-exec: past the copy the tree is
# free to move, so a second stage holding it could only refuse something legal.
check "drill window: the witness does not cross the re-exec" 1 "" \
  grep -qE 'DRILL_TREE_IDENT' "$ROOT/drill/drill.sh"
# The first guard runs ABOVE the rm -rf that wipes the previous install, because
# its whole claim is that it refuses with the host still untouched (round 4,
# #225). Below it, a refusal had already destroyed the operator's install.
guard_precedes_wipe() {
  # shellcheck disable=SC2016  # both patterns are literal text in drill.sh
  ( set -u
    local v w
    v="$(grep -nF 'tree_ident_verify "$CHECKOUT" "between its measurement' \
         "$ROOT/drill/drill.sh" | head -1 | cut -d: -f1)"
    w="$(grep -nF 'rm -rf "$BOX_SHARE" "$BOX_BINDIR/box"' \
         "$ROOT/drill/drill.sh" | head -1 | cut -d: -f1)"
    [ -n "$v" ] || { echo "the pre-install guard is gone"; exit 1; }
    [ -n "$w" ] || { echo "the wipe is gone"; exit 1; }
    [ "$v" -lt "$w" ] || { echo "the guard at $v refuses after the wipe at $w"; exit 1; } )
}
check "drill window: the pre-install guard refuses before the install is wiped" 0 "" \
  guard_precedes_wipe

# --- the bytes that landed (round 4, #225) -----------------------------------
# Everything above watches the SOURCE, and two equal endpoints do not make a
# constant interval: install.sh reads the checkout BETWEEN the two verifies, so a
# change made after the first and undone before the second is copied into the box
# and then made invisible to the only thing looking. codex reproduced exactly
# that with a `tar` shim — both witnesses matched, INSTALLED_FROM was right, the
# checkout ended clean, and the installed README.md carried a marker.
#
# The subject of the record is the COPY, so the copy is what is attested. These
# drive the attestation against fixtures, and then run codex's reproduction for
# real through install.sh, which is the only way to prove the guard catches a
# mutation nobody arranged inside the extracted block.
PAYWORK="$RECWORK/payload"; mkdir -p "$PAYWORK"
PAYTAR="$(command -v tar)"
pay() { bash -c "set -u; . '$RECFN'; . '$PREFN'; $1"; }
mk_tree() {   # mk_tree <dir> — the smallest tree install.sh will install
  mkdir -p "$1/bin" "$1/sub"
  printf '9.9.9\n'                         > "$1/VERSION"
  printf '#!/usr/bin/env bash\necho stub\n' > "$1/bin/box"; chmod +x "$1/bin/box"
  printf 'readme\n'                        > "$1/README.md"
  printf 'nested\n'                        > "$1/sub/nested.txt"
}
mk_git_tree() {   # mk_git_tree <dir> [gitignore-line] — the same, as a checkout
  mk_tree "$1"
  git init -q "$1"
  git -C "$1" symbolic-ref HEAD refs/heads/trunk
  git -C "$1" config user.email drill@example.invalid
  git -C "$1" config user.name drill
  git -C "$1" config commit.gpgsign false
  git -C "$1" remote add origin https://github.com/heavy-duty/box.git
  [ -n "${2:-}" ] && printf '%s\n' "$2" > "$1/.gitignore"
  git -C "$1" add -A
  git -C "$1" commit -q -m 'the commit a record names'
}
pay_install() {   # pay_install <src> <root> [shim-dir] — a real isolated install
  local src="$1" root="$2" shim="${3:-}"
  PATH="${shim:+$shim:}$PATH" BOX_YES=1 BOX_SKIP_SETUP_HOST=1 \
    BOX_HOME="$root/share" BOX_BIN="$root/bin" BOX_INSTALL_SOURCE="$src" \
    bash "$ROOT/install.sh" >/dev/null 2>&1
}

PAYSRC="$PAYWORK/src"; mk_tree "$PAYSRC"
PAYDST="$PAYWORK/dst"; mkdir -p "$PAYDST"; cp -a "$PAYSRC/." "$PAYDST/"
check "drill payload: a faithful copy attests" 0 "" \
  pay "payload_attest '$PAYSRC' '$PAYDST'"
# The two exclusions, each because it is not payload. install.sh excludes .git
# (install.sh:213) and WRITES INSTALLED_FROM into the version dir, so a check
# that compared either would fail on every honest install there has ever been.
mkdir -p "$PAYSRC/.git"; printf 'vcs state\n' > "$PAYSRC/.git/config"
printf 'local:%s\n' "$PAYSRC" > "$PAYDST/INSTALLED_FROM"
check "drill payload: ...with .git on one side and INSTALLED_FROM on the other" 0 "" \
  pay "payload_attest '$PAYSRC' '$PAYDST'"
# THE case: same paths, one file's content differs. This is the ABA reduced to
# its consequence — the source is irrelevant by now, the installed bytes are not
# the checkout's, and no reading of the source can say so.
printf 'readme-with-marker\n' > "$PAYDST/README.md"
check "drill payload: a file whose CONTENT differs is refused" 1 \
  "the installed tree is not the tree this checkout holds" \
  pay "payload_attest '$PAYSRC' '$PAYDST'"
check "drill payload: ...and the refusal names the file, both sides" 1 "README.md" \
  pay "payload_attest '$PAYSRC' '$PAYDST'"
printf 'readme\n' > "$PAYDST/README.md"
# A file the install has and the checkout does not, and its converse. Neither is
# a content change, and both mean the box holds a tree the record cannot name.
printf 'stray\n' > "$PAYDST/extra.txt"
check "drill payload: a file only the install has is refused" 1 "extra.txt" \
  pay "payload_attest '$PAYSRC' '$PAYDST'"
rm -f "$PAYDST/extra.txt"
rm -f "$PAYDST/sub/nested.txt"
check "drill payload: a file missing from the install is refused" 1 "nested.txt" \
  pay "payload_attest '$PAYSRC' '$PAYDST'"
printf 'nested\n' > "$PAYDST/sub/nested.txt"
check "drill payload: ...and the pair attests again once restored" 0 "" \
  pay "payload_attest '$PAYSRC' '$PAYDST'"
# A mode is not a byte the drill runs, and install.sh chmods bin/box +x on
# purpose — so the attestation must not red on one, or it reds on every install.
chmod -x "$PAYSRC/bin/box"
check "drill payload: a mode difference is not a payload difference" 0 "" \
  pay "payload_attest '$PAYSRC' '$PAYDST'"
chmod +x "$PAYSRC/bin/box"
# An empty listing is the reader failing, not two trees agreeing — the shape
# that would make this guard pass on a checkout it could not read at all.
check "drill payload: an unreadable checkout is a FATAL, not a pass" 1 \
  "holds no files to attest" pay "payload_attest '$PAYWORK/nonexistent' '$PAYDST'"
# Symlinks are compared as their TARGETS: 'current' is one, and a link that
# moved is a different tree even when every file behind it is identical.
ln -sfn sub "$PAYSRC/link"; ln -sfn bin "$PAYDST/link"
check "drill payload: a symlink pointing elsewhere is refused" 1 "link ->" \
  pay "payload_attest '$PAYSRC' '$PAYDST'"
rm -f "$PAYSRC/link" "$PAYDST/link"

# --- the manifest cannot be forged by a path (round 5, #225) -----------------
# codex's construction, built here. A newline is legal in a path, so a
# '<path> <hash>' LINE cannot say where a record ends: a source whose only file
# sits under a directory named `a <hash-of-alpha>` + newline + `.` prints the
# same two lines as a destination holding top-level `a` and `b`. Different
# payloads, one verdict, on the check whose whole claim is byte identity.
PAYNL="$PAYWORK/newline"; mkdir -p "$PAYNL/src" "$PAYNL/dst"
PAYNLA="$(printf alpha | git hash-object --stdin)"
PAYNLDIR="$(printf './a %s\n.' "$PAYNLA")"     # the forged record boundary
mkdir -p "$PAYNL/src/$PAYNLDIR"
printf beta  > "$PAYNL/src/$PAYNLDIR/b"
printf alpha > "$PAYNL/dst/a"
printf beta  > "$PAYNL/dst/b"
check "drill payload: codex's forged-boundary pair is REFUSED" 1 \
  "the installed tree is not the tree this checkout holds" \
  pay "payload_attest '$PAYNL/src' '$PAYNL/dst'"
# ...and the delta says so readably: the path is escaped for display, so the
# operator reads one line per record even when a file name holds a newline.
check "drill payload: ...and the delta escapes the forged path, not the verdict" 1 \
  "\$'./a $PAYNLA\\n./b'" pay "payload_attest '$PAYNL/src' '$PAYNL/dst'"
# The converse, which is what stops the fix being 'reds on anything with a
# newline in it': the same awkward path on both sides is still a faithful copy.
PAYNL2="$PAYWORK/newline-ok"; mkdir -p "$PAYNL2/src" "$PAYNL2/dst"
mkdir -p "$PAYNL2/src/$PAYNLDIR" "$PAYNL2/dst/$PAYNLDIR"
printf beta > "$PAYNL2/src/$PAYNLDIR/b"
printf beta > "$PAYNL2/dst/$PAYNLDIR/b"
check "drill payload: a newline path copied faithfully still attests" 0 "" \
  pay "payload_attest '$PAYNL2/src' '$PAYNL2/dst'"
# The encoding itself, so a regression to lines reds on its own rather than
# waiting for someone to rebuild the collision: three NUL-terminated fields per
# file, and a manifest that is a FILE because bash drops NUL from a $( ).
check "drill payload: the manifest is NUL-delimited, three fields per file" 0 "[3n]" \
  bash -c "set -u; . '$RECFN'; . '$PREFN'
    m=\"\$(mktemp)\"; payload_list '$PAYSRC' \"\$m\"
    nul=\$(tr -dc '\\0' < \"\$m\" | wc -c)
    f=\$(cd '$PAYSRC' && find . -name .git -prune -o -path ./INSTALLED_FROM -prune -o \\
          \\( -type f -o -type l \\) -print | wc -l)
    [ \"\$f\" -gt 0 ] && [ \"\$nul\" -eq \$((f * 3)) ] && printf '[3n]'"
check "drill payload: ...and nothing in it is separated by a newline" 0 "[0nl]" \
  bash -c "set -u; . '$RECFN'; . '$PREFN'
    m=\"\$(mktemp)\"; payload_list '$PAYSRC' \"\$m\"
    [ \"\$(tr -dc '\\n' < \"\$m\" | wc -c)\" -eq 0 ] && printf '[0nl]'"
# The verdict is taken from the MANIFESTS, not from a rendering of them. Both
# happen to be unambiguous today, so no fixture can tell the two apart — this is
# the wiring check that keeps the rendering a view: it may be made prettier, or
# lossy, without anyone discovering that the verdict was riding on it.
check "drill payload: the verdict is cmp on the manifests, not on the view" 0 "" \
  bash -c "grep -qF 'cmp -s \"\$a\" \"\$b\"' '$PREFN' \
        && ! grep -qE 'payload_render.*=.*payload_render' '$PREFN'"
# A symlink target may end in a newline, which \$( ) would eat — so the two
# targets below differ by exactly the byte a careless reader drops.
ln -sfn $'sub\n' "$PAYSRC/nlink"
ln -sfn 'sub'    "$PAYDST/nlink"
check "drill payload: a symlink target's trailing bytes are compared, not trimmed" 1 \
  "nlink ->" pay "payload_attest '$PAYSRC' '$PAYDST'"
rm -f "$PAYSRC/nlink" "$PAYDST/nlink"
check "drill payload: ...and the pair attests again once both links are gone" 0 "" \
  pay "payload_attest '$PAYSRC' '$PAYDST'"

# codex's reproduction, RUN. A tar shim appends a marker to the source's
# README.md immediately before the real tar reads it and restores the file the
# moment tar returns, which is the mutation-during-copy the two-instant guards
# cannot see. Everything else about the install is honest, and that is the point.
PAYABA="$PAYWORK/aba"; mk_git_tree "$PAYABA"
PAYSHIM="$PAYWORK/shim"; mkdir -p "$PAYSHIM"
cat > "$PAYSHIM/tar" <<EOF
#!/usr/bin/env bash
# Only the create side (-C <src>) mutates; the extract side passes straight
# through, so the install is otherwise exactly the one install.sh performs.
if [ "\$1" = "-C" ] && [ "\$2" = "$PAYABA" ]; then
  printf 'readme-during-copy\n' > "$PAYABA/README.md"
  "$PAYTAR" "\$@"; rc=\$?
  printf 'readme\n' > "$PAYABA/README.md"
  exit \$rc
fi
exec "$PAYTAR" "\$@"
EOF
chmod +x "$PAYSHIM/tar"
PAYABAROOT="$PAYWORK/aba-root"
# The witness is latched before the install and verified after it, the way the
# drill does it, so the two guards get their real chance at this run.
PAYABAIDENT="$(bash -c "set -u; . '$RECFN'; record_tree_ident '$PAYABA'")"
pay_install "$PAYABA" "$PAYABAROOT" "$PAYSHIM"
PAYABACUR="$PAYABAROOT/share/current"
check "drill payload: the ABA install SUCCEEDED, as codex reported" 0 "9.9.9" \
  cat "$PAYABACUR/VERSION"
check "drill payload: ...and INSTALLED_FROM names the checkout, correctly" 0 \
  "local:$PAYABA" cat "$PAYABACUR/INSTALLED_FROM"
check "drill payload: ...and the marker really did land in the installed tree" 0 \
  "readme-during-copy" cat "$PAYABACUR/README.md"
check "drill payload: ...while the checkout it came from ends with no marker" 1 "" \
  grep -qF 'readme-during-copy' "$PAYABA/README.md"
# THE discriminator. The window guard is not weakened by this scenario — it is
# blind to it, because its subject is the source and the source is restored.
check "drill payload: ...so the window guard passes the run it cannot see" 0 "[same]" \
  bash -c "set -u; . '$RECFN'
    now=\"\$(record_tree_ident '$PAYABA')\"
    [ \"\$now\" = '$PAYABAIDENT' ] && printf '[same]'"
# ...and the attestation refuses it, which is the whole of round 4's blocking
# point: the bytes that landed are not the bytes the record names.
check "drill payload: ...and the attestation refuses the tree that landed" 1 \
  "the installed tree is not the tree this checkout holds" \
  pay "payload_attest '$PAYABA' '$PAYABACUR'"
check "drill payload: ...naming the file that was copied mid-edit" 1 "README.md" \
  pay "payload_attest '$PAYABA' '$PAYABACUR'"
# The control: the same tree, the same installer, no shim. A guard that refused
# here would refuse every drill, which is a worse failure than the one above.
PAYOKROOT="$PAYWORK/ok-root"
pay_install "$PAYABA" "$PAYOKROOT"
check "drill payload: an honest real install attests, end to end" 0 "" \
  pay "payload_attest '$PAYABA' '$PAYOKROOT/share/current'"

# --- the two sides agree about .git and about filters (round 5, #225) --------
# `tar --exclude=.git` is UNANCHORED: it matches any path component, so a
# vendored repository is not copied either. A prune of the top-level .git alone
# would red this install — which is faithful — after the wipe, the install and
# the host setup had already been spent (claude, round 5).
PAYNEST="$PAYWORK/nested"; mk_git_tree "$PAYNEST"
mkdir -p "$PAYNEST/vendor"; git init -q "$PAYNEST/vendor"
printf 'lib\n' > "$PAYNEST/vendor/lib.txt"
PAYNESTROOT="$PAYWORK/nested-root"
pay_install "$PAYNEST" "$PAYNESTROOT"
check "drill payload: install.sh copied the vendored tree's FILES" 0 "lib" \
  cat "$PAYNESTROOT/share/current/vendor/lib.txt"
check "drill payload: ...and not the vendored .git, which it excludes by name" 1 "" \
  test -e "$PAYNESTROOT/share/current/vendor/.git"
check "drill payload: ...so a nested repository attests, it does not FATAL" 0 "" \
  pay "payload_attest '$PAYNEST' '$PAYNESTROOT/share/current'"
# hash-object reads .gitattributes on the checkout side and CANNOT on the
# install side, which is under no repository. A `text` attribute would hash the
# same bytes two ways and red every honest install, in the voice of the defect
# this guard exists to catch — so both sides read --no-filters (claude, round 5).
PAYATTR="$PAYWORK/attrs"; mk_git_tree "$PAYATTR"
printf '* text=auto\n' > "$PAYATTR/.gitattributes"
printf 'crlf\r\nlines\r\n' > "$PAYATTR/crlf.txt"
git -C "$PAYATTR" add -A 2>/dev/null   # `text=auto` warns about the CRLF; that
git -C "$PAYATTR" commit -q -m 'attributes and a CRLF file'   # warning IS the point
PAYATTRROOT="$PAYWORK/attrs-root"
pay_install "$PAYATTR" "$PAYATTRROOT"
check "drill payload: the CRLF bytes really did land unconverted" 0 "" \
  cmp -s "$PAYATTR/crlf.txt" "$PAYATTRROOT/share/current/crlf.txt"
check "drill payload: ...and a .gitattributes text filter does not red the install" 0 "" \
  pay "payload_attest '$PAYATTR' '$PAYATTRROOT/share/current'"

# --- the files git hides and install.sh copies (round 4, #225) ---------------
# `tar -C "$SRC" --exclude=.git` excludes the VCS state and NOTHING else, so an
# ignored file is installed like a tracked one while `git status` reports a clean
# tree — and this repository's ignore list is secrets.env and *.agekey. The gap
# is proved by a real install before anything is asserted about the refusal.
PAYIGN="$PAYWORK/ignored"; mk_git_tree "$PAYIGN" 'secrets.env'
printf 'TOKEN=hunter2\n' > "$PAYIGN/secrets.env"
PAYIGNROOT="$PAYWORK/ignored-root"
pay_install "$PAYIGN" "$PAYIGNROOT"
check "drill ignored: install.sh really does copy an ignored file into the box" 0 \
  "TOKEN=hunter2" cat "$PAYIGNROOT/share/current/secrets.env"
# ...and git says the tree is clean, which is why every reader in the record
# block was blind to it: the two subjects disagreed, and the copy is the one
# that gets drilled.
check "drill ignored: ...while the dirty path list calls that tree clean" 1 "" \
  pay "record_tree_dirty '$PAYIGN'"
check "drill ignored: the reader lists it, in git's own '!!' notation" 0 \
  "!! secrets.env" pay "record_tree_ignored '$PAYIGN'"
# So the drill refuses it, and the refusal is about what is actually there: a
# 'dirty worktree' headline would send the operator to the one reader that
# cannot see the file.
check "drill ignored: a tree carrying one is refused" 2 \
  "REFUSING to drill a tree git is not showing you" \
  pay "preflight_tree '$PAYIGN' 0"
check "drill ignored: ...naming the path" 2 "!! secrets.env" \
  pay "preflight_tree '$PAYIGN' 0"
check "drill ignored: ...and saying it would be installed" 2 \
  "copied into the box" pay "preflight_tree '$PAYIGN' 0"
check "drill ignored: ...and pointing at the escape hatch" 2 "allow-dirty" \
  pay "preflight_tree '$PAYIGN' 0"
check "drill ignored: --allow-dirty drills it, and says what it will install" 0 \
  "!! secrets.env" pay "preflight_tree '$PAYIGN' 1"
# A tree that is BOTH dirty and carrying one names both lists. The first version
# of this returned on the dirty list and never mentioned the second, which is
# the half that can be a secrets file.
check "drill ignored: a tree that is both dirty and ignoring names both" 2 \
  "!! secrets.env" \
  pay "printf 'edit\n' >> '$PAYIGN/README.md'; preflight_tree '$PAYIGN' 0"
check "drill ignored: ...and the dirty path with it" 2 "README.md" \
  pay "preflight_tree '$PAYIGN' 0"
git -C "$PAYIGN" checkout -q -- README.md
# The latch treats it as dirtiness, because that is what it is: the tree in the
# box is not the commit, so the record's ref field cannot claim to be either.
payign_latch() {   # payign_latch <field> [snippet]
  bash -c "set -u; . '$RECFN'; . '$PREFN'
    TREE_DIRTY=''; TREE_DIRTY_PATHS=''
    REC_TREE_REPO=''; REC_TREE_REF=''; REC_TREE_SHA=''; TREE_IDENT=''
    ${2:-}
    tree_ident_latch '$PAYIGN'
    printf '[%s]' \"\$$1\""
}
PAYIGNSHA="$(git -C "$PAYIGN" rev-parse --short=7 HEAD)"
check "drill ignored: the latch calls that tree dirty" 0 "[1]" payign_latch TREE_DIRTY
check "drill ignored: ...so the record's ref field is stamped" 0 "[$PAYIGNSHA-dirty]" \
  payign_latch REC_TREE_REF
check "drill ignored: ...and the NOTE's paths carry it, marked" 0 "!! secrets.env" \
  payign_latch TREE_DIRTY_PATHS
# ...and the witness digests its CONTENT, so a secrets file rewritten between the
# measurement and the copy moves the guard exactly like a tracked file does.
check "drill ignored: a rewrite inside an ignored file moves the witness" 1 \
  "changed in the window" \
  bash -c "set -u; . '$RECFN'; . '$PREFN'
    TREE_DIRTY=''; TREE_DIRTY_PATHS=''
    REC_TREE_REPO=''; REC_TREE_REF=''; REC_TREE_SHA=''; TREE_IDENT=''
    tree_ident_latch '$PAYIGN'
    printf 'TOKEN=rotated\n' > '$PAYIGN/secrets.env'
    tree_ident_verify '$PAYIGN' 'in the window'"
check "drill ignored: ...which the dirty path list still cannot see" 1 "" \
  pay "record_tree_dirty '$PAYIGN'"
# The cap. Ignored trees can be thousands of files where dirty ones rarely are,
# and TREE_DIRTY_PATHS crosses the sg re-exec as an environment variable — an
# exposure this round introduces, so it bounds it. What is capped is the LIST;
# what is not capped is anything the record's meaning depends on.
printf 'TOKEN=hunter2\n' > "$PAYIGN/secrets.env"
printf 'secrets.env\nignored/\n' > "$PAYIGN/.gitignore"
git -C "$PAYIGN" add .gitignore
git -C "$PAYIGN" commit -q -m 'ignore a directory too'
mkdir -p "$PAYIGN/ignored"
for i in $(seq 1 25); do printf 'x\n' > "$PAYIGN/ignored/f$i"; done
check "drill ignored: a refusal says how many it is not printing" 2 "…and 6 more" \
  pay "preflight_tree '$PAYIGN' 0"
# ...and PRINTS twenty. The trailer alone is not the assertion: a printer that
# lists all 26 and then says '…and 6 more' satisfies the check above and caps
# nothing, which is exactly what the mutation that survived this check did.
ignored_lines() {   # <how> → '[n]', the '!!' lines a refusal or the latch shows
  local n
  case "$1" in
    refusal) n="$(pay "preflight_tree '$PAYIGN' 0" 2>&1 | grep -c '^    !!')" ;;
    carried) n="$(payign_latch TREE_DIRTY_PATHS 2>&1 | grep -c '!! ')" ;;
  esac
  printf '[%s]' "$n"
}
check "drill ignored: ...and prints exactly TREE_PATHS_MAX of them" 0 "[20]" \
  ignored_lines refusal
check "drill ignored: ...and the carried list is capped the same way" 0 "…and 6 more" \
  payign_latch TREE_DIRTY_PATHS
check "drill ignored: ...to exactly TREE_PATHS_MAX paths, not 26" 0 "[20]" \
  ignored_lines carried
# The measurement is over all of them: capping the list must not cap the fact.
check "drill ignored: ...while the tree is still dirty on the 26th" 0 "[1]" \
  payign_latch TREE_DIRTY
check "drill ignored: ...and the witness still moves on a file past the cap" 1 \
  "changed in the window" \
  bash -c "set -u; . '$RECFN'; . '$PREFN'
    TREE_DIRTY=''; TREE_DIRTY_PATHS=''
    REC_TREE_REPO=''; REC_TREE_REF=''; REC_TREE_SHA=''; TREE_IDENT=''
    tree_ident_latch '$PAYIGN'
    printf 'moved\n' > '$PAYIGN/ignored/f25'
    tree_ident_verify '$PAYIGN' 'in the window'"
rm -rf "$PAYIGN/ignored"

# The wiring, the same shape the window guards get: the attestation can be
# perfect and never called, or called and its verdict dropped.
attest_follows_install() {
  # shellcheck disable=SC2016  # both patterns are literal text in drill.sh
  ( set -u
    local ins att
    ins="$(grep -nF 'BOX_INSTALL_SOURCE="$CHECKOUT" bash "$CHECKOUT/install.sh"' \
           "$ROOT/drill/drill.sh" | head -1 | cut -d: -f1)"
    att="$(grep -nF 'payload_attest "$CHECKOUT" "$BOX_SHARE/current" || exit 1' \
           "$ROOT/drill/drill.sh" | head -1 | cut -d: -f1)"
    [ -n "$att" ] || { echo "the payload is never attested, or the verdict is dropped"; exit 1; }
    [ "$att" -gt "$ins" ] || { echo "the attestation at $att runs before the install at $ins"; exit 1; } )
}
check "drill payload: the attestation runs after the install, and exits" 0 "" \
  attest_follows_install
# It attests the INSTALL ROOT, not the staging tree or the checkout twice — a
# comparison of the checkout with itself passes forever and proves nothing.
# shellcheck disable=SC2016  # the call is literal text in drill.sh
check "drill payload: ...against what landed, not against the source twice" 0 \
  'payload_attest "$CHECKOUT" "$BOX_SHARE/current"' \
  grep -F 'payload_attest "$CHECKOUT"' "$ROOT/drill/drill.sh"

# All three run before the consent prompt and before the first phase, for the
# reason the record-path guard does: an operator who cannot run this must find
# out in the first second, not in the summary forty minutes on.
# The guard names are matched with grep -F on the whole call, so the assertion
# is that the LINE exists rather than that a fragment of it does — a call whose
# `|| exit 2` was dropped would satisfy a looser pattern while refusing nothing.
# shellcheck disable=SC2016  # every one of these is literal text in drill.sh
PREFLIGHT_CALLS=(
  'preflight_uid "$(id -u)" || exit 2'
  'preflight_tree "$CHECKOUT" "$ALLOW_DIRTY" || exit 2'
)
preflight_runs_first() {
  ( set -u
    local first g line
    first="$(grep -nE '^[[:space:]]*phase [A-Za-z-]+ ' "$ROOT/drill/drill.sh" | head -1 | cut -d: -f1)"
    for g in "${PREFLIGHT_CALLS[@]}"; do
      line="$(grep -nF -- "$g" "$ROOT/drill/drill.sh" | head -1 | cut -d: -f1)"
      [ -n "$line" ] || { echo "preflight guard is defined but never called: $g"; exit 1; }
      [ "$line" -lt "$first" ] \
        || { echo "$g runs at $line, after the first phase at $first"; exit 1; }
    done )
}
check "drill preflight: both guards are called, and before the first phase" 0 "" \
  preflight_runs_first

# --- the sg re-exec, EXECUTED ------------------------------------------------
# The drill re-execs itself into the incus-admin group, and --in-group carries no
# arguments through, so every setting the second stage needs crosses as
# environment — the clock especially: $SECONDS in the shell that finishes
# measures the time since the exec, not the drill's.
#
# This was two greps for `DRILL_RECORD=` and `DRILL_T0=` in the exec line. A grep
# proves a string is present; it cannot see that `sg -c` hands its argument to a
# SHELL, so the values on that line were shell SOURCE. An apostrophe in a record
# path — legal, and constrained by no option here — closed the quotes and the
# remainder reparsed as a command, 127, forty minutes into a run whose startup
# guard had already blessed the path. So the block is extracted and RUN, against
# shadow's real `sg` argument shape and a second stage that reports what arrived.
REEXECFN="$(mktemp)"
awk '/^# >>> group re-exec/,/^# <<< group re-exec/' "$ROOT/drill/drill.sh" > "$REEXECFN"
check "drill re-exec: extracted from drill.sh (guards the awk)" 0 "sg incus-admin" \
  cat "$REEXECFN"
check "drill re-exec: the extracted block is valid bash" 0 "" bash -n "$REEXECFN"

REXWORK="$(mktemp -d)"
cat > "$REXWORK/sg" <<'SHIM'
#!/bin/sh
# Fake sg, in shadow's shape: `sg <group> -c <string>`, string handed to a shell
# (newgrp.c: execl(shell, prog, "-c", command)). Deliberately /bin/sh, not bash:
# the drill does not get to choose which shell /etc/passwd names.
[ "$1" = incus-admin ] || { echo "sg: wrong group: $1" >&2; exit 2; }
[ "$2" = -c ] || { echo "sg: expected -c, got: $2" >&2; exit 2; }
exec /bin/sh -c "$3"
SHIM
cat > "$REXWORK/stage2.sh" <<'SHIM'
#!/usr/bin/env bash
# The second stage, reduced to "say what you were handed". Delimited, so a value
# that lost or gained a character is visible rather than merely different.
printf 'argv=[%s] record=[%s] runid=[%s] dirty=[%s] keep=[%s] t0=[%s] ingroup=[%s] project=[%s]\n' \
  "${1:-}" "$DRILL_RECORD" "$DRILL_RUN_ID" "$DRILL_ALLOW_DIRTY" \
  "$DRILL_KEEP" "$DRILL_T0" "$IN_GROUP" "$INCUS_PROJECT"
# The latched tree, which stage 2 cannot re-measure: by the time it runs, the
# checkout has been installed and may have moved underneath the drill.
printf 'tree=[%s] paths=[%s] repo=[%s] ref=[%s] sha=[%s]\n' \
  "$DRILL_TREE_DIRTY" "$(printf '%s' "$DRILL_TREE_DIRTY_PATHS" | tr '\n' ';')" \
  "$DRILL_TREE_REPO" "$DRILL_TREE_REF" "$DRILL_TREE_SHA"
SHIM
chmod +x "$REXWORK/sg" "$REXWORK/stage2.sh"

reexec() {   # reexec <record> <run-id> <allow-dirty> → what stage 2 received
  # The hostile values arrive as POSITIONAL ARGUMENTS, never interpolated into
  # this snippet: a test that spliced them into its own bash -c would be making
  # the mistake it is here to catch.
  PATH="$REXWORK:$PATH" bash -c "set -u
    . '$REEXECFN'
    OWNS=0; KEEP=0; DRILL_T0=1750000000; export INCUS_PROJECT=default
    SELF='$REXWORK/stage2.sh'
    TREE_DIRTY=1; TREE_DIRTY_PATHS=' M tracked'
    REC_TREE_REPO=heavy-duty/box; REC_TREE_REF=abc1234-dirty; REC_TREE_SHA=abc1234
    RECORD=\$1; RUN_ID=\$2; ALLOW_DIRTY=\$3
    reexec_in_group" _ "$1" "$2" "$3"
}

check "drill re-exec: the settings arrive on the far side at all" 0 \
  "record=[drills/0.10.0.md] runid=[drill-0.10.0-20260819-01] dirty=[0]" \
  reexec drills/0.10.0.md drill-0.10.0-20260819-01 0
check "drill re-exec: ...and --in-group is what the second stage is told it is" 0 \
  "argv=[--in-group] " reexec drills/0.10.0.md drill-0.10.0-20260819-01 0
# --allow-dirty has to cross, because stage 2 re-runs the same refusal: a pin
# that did not arrive would refuse the tree stage 1 was told to drill anyway,
# which is how --keep-boxes was inert for a whole stage before #152.
check "drill re-exec: --allow-dirty crosses, or stage 2 refuses what stage 1 allowed" 0 \
  "dirty=[1]" reexec '' '' 1
# The clock is the field that cannot be recovered on the far side if it is lost:
# the record's wall clock is measured from it.
check "drill re-exec: the clock crosses, because \$SECONDS restarts here" 0 \
  "t0=[1750000000]" reexec '' '' 0
# The LATCHED TREE crosses for the same reason the clock does, and one more: it
# cannot be re-measured on the far side at all. install.sh has already copied
# the checkout by then, so a stage 2 that asked git again would answer about a
# tree the drill is no longer running — the record then names a commit anyone
# can check out and that is not what ran (round 2, #225).
check "drill re-exec: the latched dirty flag crosses, or stage 2 re-measures it" 0 \
  "tree=[1]" reexec '' '' 1
check "drill re-exec: ...and the dirty PATHS, which the far side cannot re-derive" 0 \
  "paths=[ M tracked]" reexec '' '' 1
check "drill re-exec: ...and the three tree fields the record carries" 0 \
  "repo=[heavy-duty/box] ref=[abc1234-dirty] sha=[abc1234]" reexec '' '' 1
check "drill re-exec: ...and so does IN_GROUP, or the second stage re-execs forever" 0 \
  "ingroup=[1]" reexec '' '' 0
check "drill re-exec: the pinned default project reaches the second stage" 0 \
  "project=[default]" reexec '' '' 0

# THE boundary. An apostrophe is legal in a Unix pathname and in a run ID, and
# this is the reproduction that was reported: the old line exited 127 here.
check "drill re-exec: an apostrophe in the record path survives verbatim" 0 \
  "record=[/tmp/release's record.md]" \
  reexec "/tmp/release's record.md" "run's-id" 0
check "drill re-exec: ...and one in the run ID, which constrains nothing either" 0 \
  "runid=[run's-id]" reexec "/tmp/release's record.md" "run's-id" 0
# Not just a crash: the same hole executes whatever it is handed. A value that
# reaches the far side INTACT is a value that was never parsed on the way. The
# vector used to be --ref, which is gone (#225); the record path is the free
# text that remains, and it is the value the reported incident carried anyway.
# shellcheck disable=SC2016  # the $( ) is the LITERAL text being asserted on
check "drill re-exec: a command substitution crosses as text, not as a command" 0 \
  'record=[$(touch '"$REXWORK"'/pwned)]' \
  reexec "\$(touch $REXWORK/pwned)" '' 0
check "drill re-exec: ...and nothing it named was executed" 1 "" test -e "$REXWORK/pwned"
check "drill re-exec: a semicolon is a character in a path, not a statement" 0 \
  "record=[/tmp/r.md; echo owned]" reexec '/tmp/r.md; echo owned' '' 0
# The path to the script itself is interpolated by nobody either — SELF is
# readlink's answer, and a drill checked out under a directory with a space in it
# is not an exotic host.
SPACED="$REXWORK/a dir/it's here"; mkdir -p "$SPACED"
cp "$REXWORK/stage2.sh" "$SPACED/stage2.sh"
check "drill re-exec: the drill's own path may contain a space and an apostrophe" 0 \
  "argv=[--in-group]" \
  bash -c "PATH='$REXWORK':\$PATH; set -u
    . '$REEXECFN'
    OWNS=0; KEEP=0; ALLOW_DIRTY=0; DRILL_T0=1; RECORD=; RUN_ID=; export INCUS_PROJECT=default
    TREE_DIRTY=0; TREE_DIRTY_PATHS=
    REC_TREE_REPO=; REC_TREE_REF=; REC_TREE_SHA=
    SELF=\$1
    reexec_in_group" _ "$SPACED/stage2.sh"

# --- the settings the re-exec carries, resolved ------------------------------
# The far side of the exec re-runs this block, so what the second stage BELIEVES
# is whatever these lines make of the environment it was handed. Extracted and
# driven with the environment emptied, so a default that only looks right
# because the outer shell happened to export something is visible.
SETFN="$(mktemp)"
awk '/^# >>> drill settings/,/^# <<< drill settings/' "$ROOT/drill/drill.sh" > "$SETFN"
check "drill settings: extracted from drill.sh (guards the awk)" 0 "--emit-record" \
  cat "$SETFN"
check "drill settings: the extracted block is valid bash" 0 "" bash -n "$SETFN"
check "drill settings: pins Incus to default without switching saved config" 0 \
  "export INCUS_PROJECT=default" grep -F 'export INCUS_PROJECT=default' "$SETFN"
settings() {   # settings <env-assignment...> -- <argv...> → the resolved settings
  # Seeded rather than empty: "${env[@]}" on an empty array is an unbound
  # variable under this file's set -u on bash before 4.4.
  local env=(_DRILL_SETTINGS_TEST=1)
  while [ "$1" != -- ]; do env+=("$1"); shift; done; shift
  # shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
  env -i PATH="$PATH" "${env[@]}" bash -c '. "$0"
    printf "keep=[%s] record=[%s] runid=[%s] dirty=[%s] checkout=[%s]\n" \
      "$KEEP" "$RECORD" "$RUN_ID" "$ALLOW_DIRTY" "$CHECKOUT"
    printf "tree=[%s] paths=[%s] repo=[%s] ref=[%s] sha=[%s]\n" \
      "$TREE_DIRTY" "$TREE_DIRTY_PATHS" \
      "$REC_TREE_REPO" "$REC_TREE_REF" "$REC_TREE_SHA"' "$SETFN" "$@"
}
check "drill settings: DRILL_RECORD and DRILL_RUN_ID cross the exec" 0 \
  "record=[/tmp/r.md] runid=[rid-01]" \
  settings DRILL_RECORD=/tmp/r.md DRILL_RUN_ID=rid-01 --
check "drill settings: ...and the flags win where both are given" 0 \
  "record=[/tmp/flag.md] runid=[flag-01]" \
  settings DRILL_RECORD=/tmp/env.md DRILL_RUN_ID=env-01 -- \
    --emit-record /tmp/flag.md --run-id flag-01
# The two settings that replaced them (#225). --allow-dirty is off unless it is
# asked for, and it crosses the sg re-exec as DRILL_ALLOW_DIRTY because stage 2
# re-runs the refusal it waives.
check "drill settings: --allow-dirty is off when nothing asks for it" 0 "dirty=[0]" \
  settings --
check "drill settings: ...and on when the flag is given" 0 "dirty=[1]" \
  settings -- --allow-dirty
check "drill settings: ...and DRILL_ALLOW_DIRTY is how it crosses the re-exec" 0 \
  "dirty=[1]" settings DRILL_ALLOW_DIRTY=1 --
# The latched tree is a MEASUREMENT and not a flag, so there is no way to ask
# for it on a command line: it arrives from the environment or it has not been
# taken yet. Empty is exactly that — 'not yet latched', which is how stage 1
# starts — and it is what makes the latch's own guard work (round 2, #225).
check "drill settings: an unlatched tree is empty, never a default of 'clean'" 0 \
  "tree=[] paths=[] repo=[] ref=[] sha=[]" settings --
check "drill settings: ...and --allow-dirty does not latch anything by itself" 0 \
  "tree=[]" settings -- --allow-dirty
check "drill settings: the latched tree crosses the re-exec, all five of it" 0 \
  "tree=[1] paths=[ M tracked] repo=[you/box] ref=[abc1234-dirty] sha=[abc1234]" \
  settings DRILL_TREE_DIRTY=1 'DRILL_TREE_DIRTY_PATHS= M tracked' \
    DRILL_TREE_REPO=you/box DRILL_TREE_REF=abc1234-dirty DRILL_TREE_SHA=abc1234 --
# The checkout is derived from the SCRIPT'S OWN PATH and never from $PWD, so
# the block is planted where drill.sh actually lives — <root>/drill/drill.sh —
# and sourced from somewhere else entirely. A resolver reading $PWD would answer
# with the directory the check happens to run in, which is the whole failure.
SETREPO="$(mktemp -d)/a repo"; mkdir -p "$SETREPO/drill"
cp "$SETFN" "$SETREPO/drill/drill.sh"
checkout_of() {   # what the settings block resolves as the checkout, from /
  # shellcheck disable=SC2016  # the snippet is evaluated by the child shell, not here
  ( cd / && env -i PATH="$PATH" HOME=/home/tester bash -c '. "$0"
      printf "checkout=[%s]\n" "$CHECKOUT"' "$1" )
}
check "drill settings: the checkout is the script's own parent, not \$PWD" 0 \
  "checkout=[$SETREPO]" checkout_of "$SETREPO/drill/drill.sh"
# ...and a path with a space in it is not exotic — the drill's own re-exec test
# has carried that case since #152.
check "drill settings: ...and survives a space in the checkout's path" 0 "a repo]" \
  checkout_of "$SETREPO/drill/drill.sh"
# There is no flag and no environment variable that can point the run at another
# tree. Asserted on the parsing block itself, because "there is no such flag" is
# a claim about what the case statement does NOT contain.
check "drill settings: --repo is not an option any more" 1 "" \
  grep -qE -- '--repo\)' "$SETFN"
check "drill settings: ...and neither is --ref" 1 "" \
  grep -qE -- '--ref\)' "$SETFN"
check "drill settings: ...and --repo is rejected like any other unknown option" 2 \
  "unknown option" bash "$ROOT/drill/drill.sh" --repo heavy-duty/box
check "drill settings: ...and so is --ref, which is the flag the docs used to use" 2 \
  "unknown option" bash "$ROOT/drill/drill.sh" --ref main
check "drill settings: --keep-boxes is read from the command line" 0 "keep=[1]" \
  settings -- --keep-boxes
check "drill settings: ...and is off when nothing asks for it" 0 "keep=[0]" settings --

# THE half that was broken. KEEP crossed the exec as a bare `KEEP=` and the
# settings line then reset it to 0 before anything could read it, so
# --keep-boxes was inert for the whole of the stage that runs the teardown phase
# and writes the record. The record's invocation field is the first thing to
# depend on it (#152), and a field that cannot be true is the hand-transcription
# problem in a new place.
check "drill settings: ...and DRILL_KEEP is how it crosses the re-exec" 0 "keep=[1]" \
  settings DRILL_KEEP=1 --
# A bare KEEP in an operator's environment is not a request to change what the
# drill asserts — the pin is DRILL_KEEP, like every other one.
check "drill settings: a stray KEEP in the environment is not the flag" 0 "keep=[0]" \
  settings KEEP=1 --

# The colour guard. Capturing this output is itself the regression: before #152
# every verdict carried escape codes into whatever file it was piped to, and the
# record was then transcribed past them. `grep -q ESC` exits 1 on a clean line.
verdicts_have_ansi() {   # 0 when the emitted verdicts still carry escape codes
  env "$@" bash -c "set -u; . '$VERDFN'; ok x; no y; note z; phase A B; skipped() { :; }" \
    | grep -q "$(printf '\033')"
}
check "drill colour: a captured verdict carries no ANSI" 1 "" verdicts_have_ansi
check "drill colour: ...nor does one under NO_COLOR" 1 "" verdicts_have_ansi NO_COLOR=1
# NO_COLOR's convention is that being SET is the signal, empty included — the
# reading that trips implementations testing for a non-empty value.
check "drill colour: ...including an empty NO_COLOR, per the convention" 1 "" \
  verdicts_have_ansi NO_COLOR=
check "drill colour: doctor.sh honours it too" 0 "" \
  grep -qF 'NO_COLOR+x' "$ROOT/drill/doctor.sh"
check "drill colour: multiuser.sh honours it too" 0 "" \
  grep -qF 'NO_COLOR+x' "$ROOT/drill/multiuser.sh"

# ...and the three checks above cannot tell the two halves of the guard apart.
# They pipe into grep, so stdout is never a terminal and `[ ! -t 1 ]` satisfies
# all three on its own: deleting the NO_COLOR clause left the suite fully green.
# A pty is what makes the distinction real — ANSI PRESENT on a terminal is the
# other half, and nothing asserted it either.
pty_verdicts() {   # pty_verdicts <env...> — the verdicts, on a real terminal
  env "$@" script -qec \
    "bash -c 'set -u; . \"$VERDFN\"; ok x; no y; note z; phase A B'" /dev/null
}
pty_has_ansi() { pty_verdicts "$@" | grep -q "$(printf '\033')"; }
# Every case PINS the variable — the baseline unsets it, the other two set it.
# Inheriting it is what a suite must not do here: NO_COLOR=1 is a valid thing
# for a developer or a review host to have set, and a baseline that inherits it
# asserts "ANSI is present" while being told to suppress ANSI. It then fails in
# precisely the environment whose behaviour it exists to test, and the green it
# gives anywhere else is a fact about the caller's shell, not about the guard.
if command -v script >/dev/null 2>&1 && pty_verdicts -u NO_COLOR >/dev/null 2>&1; then
  check "drill colour: on a real terminal the verdicts ARE coloured" 0 "" \
    pty_has_ansi -u NO_COLOR
  check "drill colour: ...and NO_COLOR alone turns them off, terminal or not" 1 "" \
    pty_has_ansi NO_COLOR=1
  # The empty case is the one implementations get wrong, and the only one the
  # tty test cannot stand in for.
  check "drill colour: ...including an empty NO_COLOR, on a terminal" 1 "" \
    pty_has_ansi NO_COLOR=
else
  # Recorded as a skip rather than passed silently — the #153 discipline, applied
  # to this file. script(1) is util-linux and present on the CI runner.
  echo "SKIP: drill colour: the pty checks need script(1); not usable here"
fi

# The help window is a line range into this file's own header, so a line added
# above it silently truncates the help. #153 moved it once already.
check "drill help: names --emit-record" 0 "--emit-record" bash "$ROOT/drill/drill.sh" --help
check "drill help: names the run ID" 0 "--run-id" bash "$ROOT/drill/drill.sh" --help
check "drill help: names NO_COLOR" 0 "NO_COLOR" bash "$ROOT/drill/drill.sh" --help
# ...and still covers the phase list rather than ending mid-sentence — the WHOLE
# list now. It used to stop on "C. Isolation baseline" while the block ran to M,
# so a tool asked directly for its phases answered with a truncated list of a
# list that was itself wrong (#154). Driven against the LEDGER's keys and not a
# fixed string: the two drifted apart for two releases because nothing compared
# them, and a phase added without a header line reds here now.
help_names_every_phase() {
  ( set -u
    # shellcheck disable=SC2034  # skipped() appends to it; the block assumes it
    findings=()
    # shellcheck disable=SC1090  # the extracted ledger, written above
    . "$LEDGERFN"
    local out k
    out="$(bash "$ROOT/drill/drill.sh" --help)" || { echo "--help failed"; exit 1; }
    for k in "${PHASE_ORDER[@]}"; do
      printf '%s\n' "$out" | grep -qE "^ *$k\. " \
        || { echo "--help does not name ledgered phase $k"; exit 1; }
    done )
}
check "drill help: it names every phase the ledger declares" 0 "" help_names_every_phase
# ...and by its NUMBER, not only by its key. The check above compared the two
# lists of phase LETTERS, so --help could state a per-phase count that the
# ledger contradicted and stay green — which is what happened: #214 moved B
# from 51 to 45 and the header kept printing [51], so the drill answered one
# number when asked directly and asserted another when it ran. Every phase's
# bracketed integer is compared, not just the one that drifted, because the
# next drift will be somewhere else. The count trails its phase's block, which
# is one line for B and four for D, so it is read as "the last [N] before the
# next phase opens".
help_counts_match_ledger() {
  ( set -u
    # shellcheck disable=SC2034  # skipped() appends to it; the block assumes it
    findings=()
    # shellcheck disable=SC1090  # the extracted ledger, written above
    . "$LEDGERFN"
    local out k n
    out="$(bash "$ROOT/drill/drill.sh" --help)" || { echo "--help failed"; exit 1; }
    for k in "${PHASE_ORDER[@]}"; do
      n="$(printf '%s\n' "$out" | awk -v k="$k" '
        $0 ~ "^ *"k"\\. "                                   { inb = 1 }
        inb && $0 ~ "^ *[A-Z]\\. " && $0 !~ "^ *"k"\\. "     { inb = 0 }
        inb && match($0, /\[[0-9]+\]/) { v = substr($0, RSTART + 1, RLENGTH - 2) }
        END { print v }')"
      [ -n "$n" ] || { echo "--help states no probe count for phase $k"; exit 1; }
      [ "$n" = "${PHASE_EXPECT[$k]}" ] \
        || { echo "phase $k: --help says [$n], the ledger declares [${PHASE_EXPECT[$k]}]"; exit 1; }
    done )
}
check "drill help: ...and every phase's COUNT matches the ledger's (#214)" 0 "" \
  help_counts_match_ledger
check "drill help: ...including the last one, so the window is not short again" 0 \
  "T. Teardown" bash "$ROOT/drill/drill.sh" --help
check "drill help: ...and the window reaches the line after the list" 0 \
  "Exit 0 = every check passed" bash "$ROOT/drill/drill.sh" --help
check "drill: an unknown option is still a usage error" 2 "unknown option" \
  bash "$ROOT/drill/drill.sh" --frobnicate
# The help must not NAME the two retired flags, not even in the sentence saying
# they are retired: the header block is what the tool answers with when asked
# directly, so a flag named there is a flag an operator will try (#225). The
# incident that bought the removal is kept in the settings block's comment,
# which is code and not the help window.
help_names_a_tree_flag() { bash "$ROOT/drill/drill.sh" --help | grep -qE -- '--repo|--ref'; }
check "drill help: names neither --repo nor --ref (#225)" 1 "" help_names_a_tree_flag
# The window is quoted in two docs as a literal range, beside an instruction to
# keep it in step with the script — so a stale copy is not a stale fact, it is a
# stale instruction, and the editor who obeys it truncates the help again. The
# checks above prove the window COVERS the list; this one proves the docs quote
# the range that produced it. Read out of the '-h|--help' line rather than
# written here twice, or this check is the third copy that can drift.
docs_quote_the_help_window() {
  ( set -u
    local range doc
    range="$(sed -n "s/.*-h|--help) *sed -n '\([0-9]*,[0-9]*p\)'.*/\1/p" \
      "$ROOT/drill/drill.sh")"
    [ -n "$range" ] \
      || { echo "could not read the help window range out of drill/drill.sh"; exit 1; }
    for doc in drill/README.md CONTRIBUTING.md; do
      grep -qF "sed -n '$range'" "$ROOT/$doc" \
        || { echo "$doc does not quote the help window the script runs, $range"; exit 1; }
    done )
}
check "drill help: the docs quote the window range the script actually runs" 0 "" \
  docs_quote_the_help_window

# The drill's own README is documentation of a MEASURED thing, so it is checked
# against the measurement rather than read. It described four phases while the
# script printed eight for two releases, and E and M — some 200 lines of expose
# and migration probes — went undocumented the whole time, because nothing here
# compared the file to the ledger (#154).
readme_names_every_phase() {
  ( set -u
    # shellcheck disable=SC2034  # skipped() appends to it; the block assumes it
    findings=()
    # shellcheck disable=SC1090  # the extracted ledger, written above
    . "$LEDGERFN"
    local k
    for k in "${PHASE_ORDER[@]}"; do
      grep -qE "^\| \*\*$k\*\* \|" "$ROOT/drill/README.md" \
        || { echo "drill/README.md does not document ledgered phase $k"; exit 1; }
      # ...and with the phase's own probe count, which is the number an operator
      # reads a shortfall against. Two places to update is the point: a phase
      # that gains a probe moves the table, the README and CONTRIBUTING's total.
      grep -qE "^\| \*\*$k\*\* \|.*\| ${PHASE_EXPECT[$k]} \|" "$ROOT/drill/README.md" \
        || { echo "drill/README.md gives phase $k a count other than ${PHASE_EXPECT[$k]}"; exit 1; }
    done
    grep -qF "$(ledger_declared) probes" "$ROOT/drill/README.md" \
      || { echo "drill/README.md does not quote the table's own total, $(ledger_declared)"; exit 1; } )
}
check "drill/README: documents every ledgered phase, with its probe count" 0 "" \
  readme_names_every_phase
# The repo was renamed; the clone line and the issue links were not.
check "drill/README: no longer points at the pre-rename repo" 1 "" \
  grep -q 'heavy-duty/claudebox' "$ROOT/drill/README.md"
# The warning that cost the most to leave standing: on a script whose header
# says run it on a machine you can format, it spent an operator's caution on
# mutations phase D stopped making when the hardening shipped. Both halves are
# checked — the README says so plainly, and no line the drill PRINTS says
# otherwise. Grepped past the comments on purpose: the ones preserving this
# incident quote the old warning, and a comment is not an answer to anybody.
check "drill/README: says plainly that a run leaves no D-phase mutations" 0 "" \
  grep -qF 'no D-phase mutations' "$ROOT/drill/README.md"
check "drill: no line it PRINTS still promises D-phase residue on the host" 1 "" \
  bash -c "grep -vE '^[[:space:]]*#' '$ROOT/drill/drill.sh' | grep -q 'still applied'"
# Two lines were retired, and 'still applied' only pins one of them. The other
# was "(plus, unless re-run: dns.mode=none and NIC filtering from the D phase)"
# on the closing summary, which carries none of that string — so re-introducing
# THAT half stayed green while the check above read as though it covered both.
# So: no line the drill PRINTS calls the phase by that name at all. Matched
# case-sensitively on the "D phase"/"D-phase" shape rather than on "phase D",
# because the ledger call `phase D "D. The isolation contract, stated"` is a
# printed line and a correct one; it is the phase's own heading, not a claim
# about residue. The header states the positive version and is a comment, past
# this grep for the reason the check above gives.
check "drill: ...nor the closing line's version of the same promise" 1 "" \
  bash -c "grep -vE '^[[:space:]]*#' '$ROOT/drill/drill.sh' | grep -qE 'D[- ]phase'"

# The gate reads drills/<version>.md, so the emitter's own documentation lives
# beside the record format it produces.
check "drills/README documents the emitter" 0 "" grep -qF -- '--emit-record' "$ROOT/drills/README.md"
check "drills/README documents the audit-answers section the emitter writes" 0 "" \
  grep -qF '## Audit answers' "$ROOT/drills/README.md"
check "drills/README says the emitted record is a starting point" 0 "" \
  grep -qiF 'skeleton' "$ROOT/drills/README.md"
check "drills/README says where the shared run ID comes from" 0 "" \
  grep -qF -- '--run-id' "$ROOT/drills/README.md"

# Every extracted block and every scratch directory, including the two blocks
# and the fake-`sg` tree added in round 2 — a stray directory on /tmp holding an
# executable called `sg` is a worse leftover than a stray file.
rm -rf "$RECWORK" "$REXWORK"
rm -f "$LEDGERFN" "$VERDFN" "$SUMFN" "$RECFN" "$REEXECFN" "$SETFN"

# The docs keep the new promises.
check "help setup-host names BOX_SUBNET" 0 "BOX_SUBNET" "$BOX" help setup-host
check "help setup-host names the refusal" 0 "REFUSES" "$BOX" help setup-host
check "help doctor names the #80 signature" 0 "#80" "$BOX" help doctor
check "README documents BOX_SUBNET" 0 "" grep -qF 'BOX_SUBNET' "$ROOT/README.md"

# ---------------------------------------------------------------------------
# The versioned install (#66 → 0.7.0). BOX_INSTALL_SOURCE bypasses the network,
# so these are REAL runs of install.sh against throwaway BOX_HOME/BOX_BIN
# roots — layout, symlink chain, flat-tree migration, symlink healing, use and
# uninstall are all DRIVEN, not grepped. A fake `incus` on PATH answers the
# existing-boxes gate ($FAKE_BOXES names them), so the #66 refusals — refuse
# to flip, refuse to switch, refuse to uninstall under boxes — run for real
# too, with no daemon anywhere near this suite.
# ---------------------------------------------------------------------------
VER="$(cat "$ROOT/VERSION")"
WORK="$(mktemp -d)"
FAKEHOME="$WORK/home"; mkdir -p "$FAKEHOME"

ISHIM="$WORK/ishim"; mkdir -p "$ISHIM"
cat > "$ISHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus: 'list' prints $FAKE_BOXES (whitespace-separated names, one per
# line); everything else succeeds silently. Just enough for the existing-boxes
# gate that guards version flips.
case " $* " in
  *" list "*) for b in ${FAKE_BOXES:-}; do printf '%s\n' "$b"; done ;;
esac
exit 0
SHIM
chmod +x "$ISHIM/incus"

# A fabricated "newer release": the same CLI, a different VERSION — what an
# upgrade actually is, from the installer's point of view.
SRC9="$WORK/src-9.9.9"; mkdir -p "$SRC9/bin" "$SRC9/host"
cp "$ROOT/bin/box" "$SRC9/bin/box"; chmod +x "$SRC9/bin/box"
echo "9.9.9-drill" > "$SRC9/VERSION"
# A stub host/setup-host.sh that only announces itself: enough to prove WHETHER
# the installer ran host setup, and from WHICH version's tree, with no Incus and
# no root. The real script builds the isolation stack; this one echoes (#115).
cat > "$SRC9/host/setup-host.sh" <<'STUB'
#!/usr/bin/env bash
echo "SETUP-HOST-RAN-FROM 9.9.9-drill"
STUB
chmod +x "$SRC9/host/setup-host.sh"
SRC8="$WORK/src-8.8.8"; mkdir -p "$SRC8/bin"
cp "$ROOT/bin/box" "$SRC8/bin/box"; chmod +x "$SRC8/bin/box"
echo "8.8.8-drill" > "$SRC8/VERSION"

inst() {  # inst <box_home> <box_bin> [VAR=val ...] — run install.sh for real
  local h="$1" b="$2"; shift 2
  env HOME="$FAKEHOME" PATH="$ISHIM:$PATH" FAKE_BOXES= \
      BOX_HOME="$h" BOX_BIN="$b" BOX_YES=1 BOX_SKIP_SETUP_HOST=1 \
      BOX_INSTALL_SOURCE="$ROOT" "$@" bash "$ROOT/install.sh"
}
inst_setup() {  # like inst, but WITHOUT BOX_SKIP_SETUP_HOST — host setup is the
  # thing under test, so the switch that suppresses it has to come off. Safe
  # offline: the only setup-host on these fabricated sources is the echo stub
  # above, and BOX_YES=1 answers its prompt.
  local h="$1" b="$2"; shift 2
  env HOME="$FAKEHOME" PATH="$ISHIM:$PATH" FAKE_BOXES= \
      BOX_HOME="$h" BOX_BIN="$b" BOX_YES=1 \
      BOX_INSTALL_SOURCE="$ROOT" "$@" bash "$ROOT/install.sh"
}
ibox() {  # ibox [VAR=val ...] <cmd...> — run an installed box under the shim
  env HOME="$FAKEHOME" PATH="$ISHIM:$PATH" FAKE_BOXES= "$@"
}

# --- fresh install: the layout and the chain --------------------------------
H1="$WORK/h1"; B1="$WORK/b1"
check "install: a fresh install runs clean" 0 "done" inst "$H1" "$B1"
check "install: the tree lands in versions/<v>" 0 "" test -x "$H1/versions/$VER/bin/box"
check "install: the guest checkup probe lands executable beside the CLI" 0 "" \
  test -x "$H1/versions/$VER/guest/checkup.sh"
check "install: 'current' points at versions/<v>" 0 "versions/$VER" readlink "$H1/current"
check "install: the PATH symlink rides the chain" 0 "$H1/current/bin/box" readlink "$B1/box"
check "install: box --version answers through the whole chain" 0 "box $VER" ibox "$B1/box" --version
check "install: INSTALLED_FROM records the local source" 0 "local:" cat "$H1/versions/$VER/INSTALLED_FROM"

# --- BOX_INSTALLED_FROM: the provenance override (#250) ---------------------
# The scp-able artifact stub unpacks its payload to a temp directory, hands
# THAT to BOX_INSTALL_SOURCE, and deletes it on its own trap — so without the
# override every artifact install writes 'local:/tmp/tmp.XXXX/tree' into the
# one file whose job is to name the source. These are REAL installs on their
# own roots, so nothing here perturbs the H1 chain the rest of this section
# walks. Equality, not a substring: the contract is that the file holds EXACTLY
# the value, and a substring check passes on a file that also holds the path.
installed_from_is() {  # <version-dir> <string> — the file holds EXACTLY <string>
  [ "$(cat "$1/INSTALLED_FROM")" = "$2" ]
}

HP1="$WORK/hp1"; BP1="$WORK/bp1"
check "provenance: an install with BOX_INSTALLED_FROM set runs clean" 0 "done" \
  inst "$HP1" "$BP1" BOX_INSTALLED_FROM='artifact:box-installer.sh sha256:deadbeef'
check "provenance: ...and INSTALLED_FROM holds exactly that value" 0 "" \
  installed_from_is "$HP1/versions/$VER" 'artifact:box-installer.sh sha256:deadbeef'
check "provenance: ...so the source path appears nowhere in it" 1 "" \
  grep -qF "$ROOT" "$HP1/versions/$VER/INSTALLED_FROM"

# Unset is the regression that matters most: this file is what the drill reads,
# so every existing install path must keep the exact string it wrote before.
HP2="$WORK/hp2"; BP2="$WORK/bp2"
check "provenance: unset, the install still runs clean" 0 "done" inst "$HP2" "$BP2"
check "provenance: ...and the recorded source is 'local:\$SRC', byte for byte" 0 "" \
  installed_from_is "$HP2/versions/$VER" "local:$ROOT"

# A newline would make the one-line contract false and leave `cat` readers
# seeing only the first line, so it dies before the run touches anything.
check "provenance: a newline-bearing value is REFUSED (#250 D4)" 1 "must not contain a newline" \
  inst "$WORK/hp3" "$WORK/bp3" BOX_INSTALLED_FROM=$'artifact:one\nsha256:two'
check "provenance: ...and the refusal installed nothing" 1 "" test -e "$WORK/hp3/versions"

# --- converge, don't clobber ------------------------------------------------
touch "$H1/versions/$VER/CANARY"
check "install: a same-version re-run is a no-op that says so (#66)" 0 "already installed" inst "$H1" "$B1"
check "install: the no-op left the tree untouched" 0 "" test -e "$H1/versions/$VER/CANARY"
check "install: BOX_REINSTALL=1 replaces that version's tree" 0 "reinstalled" inst "$H1" "$B1" BOX_REINSTALL=1
check "install: the reinstall really replaced it (canary gone)" 1 "" test -e "$H1/versions/$VER/CANARY"

# --- a second version: side-by-side, and the no-boxes flip ------------------
check "install: a second version installs side-by-side" 0 "" inst "$H1" "$B1" BOX_INSTALL_SOURCE="$SRC9"
check "install: ...into its own versions dir" 0 "" test -x "$H1/versions/9.9.9-drill/bin/box"
check "install: ...and the old version stays" 0 "" test -d "$H1/versions/$VER"
check "install: with no boxes, the default flips to the new version" 0 "box 9.9.9-drill" ibox "$B1/box" --version

# --- box versions -----------------------------------------------------------
check "versions: lists the installed versions" 0 "$VER" ibox "$B1/box" versions
check "versions: marks the current default" 0 "(current)" ibox "$B1/box" versions
check "versions: marks the running one" 0 "(running)" ibox "$B1/box" versions

# --- box use ----------------------------------------------------------------
check "use: no argument is a usage error" 2 "usage: box use" ibox "$B1/box" use
check "use: an unknown version is refused by name" 1 "no such version" ibox "$B1/box" use 1.2.3
# A version is a directory NAME — a crafted one must die at the gate, never
# reach the ln (current pointing outside the root) or an rm -rf.
check "use: a path-traversal version dies at the gate" 1 "not a sane version name" \
  ibox "$B1/box" use '../../tmp/evil'
check "use: refuses under existing boxes, naming them (#66)" 1 "wedged" \
  ibox FAKE_BOXES="wedged stuck" "$B1/box" use "$VER"
check "use: the refusal points at the remedy (box rm, then re-run)" 1 "box rm" \
  ibox FAKE_BOXES=wedged "$B1/box" use "$VER"
check "use: with no boxes, flips the default" 0 "switched to $VER" ibox "$B1/box" use "$VER"
check "use: the flip is effective through the PATH chain" 0 "box $VER" ibox "$B1/box" --version
check "install: an installed-but-not-current version is a no-op too" 0 "already installed" \
  inst "$H1" "$B1" BOX_INSTALL_SOURCE="$SRC9"
check "install: ...and does not move the default" 0 "box $VER" ibox "$B1/box" --version

# --- the upgrade-under-boxes refusal, driven end to end ---------------------
H2="$WORK/h2"; B2="$WORK/b2"
check "refusal drill: baseline install" 0 "done" inst "$H2" "$B2"
check "upgrade under boxes: REFUSES the default flip (#66)" 0 "refusing to change the default box version" \
  inst "$H2" "$B2" BOX_INSTALL_SOURCE="$SRC9" FAKE_BOXES=work
check "upgrade under boxes: the new version IS installed side-by-side" 0 "" \
  test -d "$H2/versions/9.9.9-drill"
check "upgrade under boxes: the default stayed put" 0 "box $VER" ibox "$B2/box" --version
check "upgrade under boxes: the blocking boxes are NAMED" 0 "· work" \
  inst "$H2" "$B2" BOX_INSTALL_SOURCE="$SRC8" FAKE_BOXES=work
check "upgrade under boxes: the refusal names the deliberate flip" 0 "" \
  bash -c 'grep -q "then flip the default:  box use" "'"$ROOT"'/install.sh"'

# --- migration: a 0.6.0 flat tree becomes a versioned one -------------------
H3="$WORK/h3"; B3="$WORK/b3"; mkdir -p "$H3/bin" "$B3"
cp "$ROOT/bin/box" "$H3/bin/box"; chmod +x "$H3/bin/box"
cp "$ROOT/VERSION" "$H3/VERSION"
echo "test@flat" > "$H3/INSTALLED_FROM"
ln -s "$H3/bin/box" "$B3/box"
check "migrate: a pre-0.7.0 flat tree is moved into versions/" 0 "migrating" inst "$H3" "$B3"
check "migrate: the OPERATOR'S tree moved (not a fresh copy)" 0 "test@flat" \
  cat "$H3/versions/$VER/INSTALLED_FROM"
check "migrate: nothing flat remains at the root" 1 "" test -e "$H3/bin"
check "migrate: current points at the migrated version" 0 "versions/$VER" readlink "$H3/current"
check "migrate: the PATH symlink was re-pointed through current" 0 "$H3/current/bin/box" readlink "$B3/box"
check "migrate: the migrated install answers --version" 0 "box $VER" ibox "$B3/box" --version

# #117: the migration is not silent about the entry it manufactured. The old
# tree is now a first-class 'box versions' row the operator never installed —
# so the output has to name the way back out (uninstall) and the reason to
# keep it (rollback), at the migration AND again in the closing summary, which
# is the half an operator scrolling ~250 lines of install output actually sees.
H3B="$WORK/h3b"; B3B="$WORK/b3b"; mkdir -p "$H3B/bin" "$B3B"
cp "$ROOT/bin/box" "$H3B/bin/box"; chmod +x "$H3B/bin/box"
cp "$ROOT/VERSION" "$H3B/VERSION"
ln -s "$H3B/bin/box" "$B3B/box"
mig_out="$WORK/mig-out.txt"
inst "$H3B" "$B3B" BOX_INSTALL_SOURCE="$SRC9" >"$mig_out" 2>&1 || true
check "migrate: the output points at the reap command (#117)" 0 "box uninstall $VER" \
  cat "$mig_out"
check "migrate: ...and names keeping it as a rollback target (#117)" 0 "keep it to roll back" \
  cat "$mig_out"
check "migrate: ...and the closing summary re-states it (#117)" 0 "was migrated to versions/$VER" \
  cat "$mig_out"
# ...and the note is conditional: an install with nothing to migrate must not
# mention a migration at all. grep exits 1 when the string is absent, which is
# the pass here.
nomig_out="$WORK/nomig-out.txt"
H3C="$WORK/h3c"; B3C="$WORK/b3c"
inst "$H3C" "$B3C" >"$nomig_out" 2>&1 || true
check "migrate: a NON-migrating install stays silent about migration (#117)" 1 "" \
  grep -qF "was migrated to versions/" "$nomig_out"

# ...and the seamless 0.6.0 → 0.7.0 upgrade: flat tree in, new version beside it.
H4="$WORK/h4"; B4="$WORK/b4"; mkdir -p "$H4/bin" "$B4"
cp "$ROOT/bin/box" "$H4/bin/box"; chmod +x "$H4/bin/box"
cp "$ROOT/VERSION" "$H4/VERSION"
ln -s "$H4/bin/box" "$B4/box"
check "migrate+upgrade: flat 0.6.0 in, new version installed beside it" 0 "" \
  inst "$H4" "$B4" BOX_INSTALL_SOURCE="$SRC9"
check "migrate+upgrade: both versions present" 0 "" \
  bash -c "[ -d '$H4/versions/$VER' ] && [ -d '$H4/versions/9.9.9-drill' ]"
check "migrate+upgrade: no boxes → the new version is the default" 0 "box 9.9.9-drill" \
  ibox "$B4/box" --version

# #115, end to end and fully offline: a flat pre-0.7.0 tree must still count as
# "no install yet" and RUN host setup. The migration converts the flat tree into
# versions/<v>, which is precisely what used to make had_install read 1 — the
# host then skipped setup-host while 'box --version' reported the new release,
# leaving every host-side artifact (box-firewall, #102) at the old one. The stub
# setup-host echoes a marker, so the marker IS the proof it ran.
H4B="$WORK/h4b"; B4B="$WORK/b4b"; mkdir -p "$H4B/bin" "$B4B"
cp "$ROOT/bin/box" "$H4B/bin/box"; chmod +x "$H4B/bin/box"
cp "$ROOT/VERSION" "$H4B/VERSION"
ln -s "$H4B/bin/box" "$B4B/box"
check "flat upgrade: host setup RUNS over a migrated flat tree (#115)" 0 "SETUP-HOST-RAN-FROM 9.9.9-drill" \
  inst_setup "$H4B" "$B4B" BOX_INSTALL_SOURCE="$SRC9"

# The converse, so the gate is proven to still GATE: H4B is now a genuinely
# versioned tree, which HAS already made the host-setup decision — a re-run must
# not redo it. Without this, "fix" and "run setup-host unconditionally" would be
# indistinguishable.
vers_out="$WORK/versioned-upgrade-out.txt"
inst_setup "$H4B" "$B4B" BOX_INSTALL_SOURCE="$SRC8" >"$vers_out" 2>&1 || true
check "versioned upgrade: an existing versioned install still SKIPS host setup" 0 "already had a box install" \
  cat "$vers_out"
check "versioned upgrade: ...and the stub did NOT run" 1 "" \
  grep -qF "SETUP-HOST-RAN-FROM" "$vers_out"

# 'current' does not always flip: the #66 guard holds the default under existing
# boxes. Host setup must still come from the version just installed, or the
# upgrade converges the host with the OLD release's host scripts — reinstating
# the very staleness #115 is about. The flat fixture carries no host/ dir at all,
# so going through 'current' could not even find a script to run.
H10="$WORK/h10"; B10="$WORK/b10"; mkdir -p "$H10/bin" "$B10"
cp "$ROOT/bin/box" "$H10/bin/box"; chmod +x "$H10/bin/box"
cp "$ROOT/VERSION" "$H10/VERSION"
ln -s "$H10/bin/box" "$B10/box"
check "flat upgrade under boxes: setup-host runs the NEW version's script" 0 "SETUP-HOST-RAN-FROM 9.9.9-drill" \
  inst_setup "$H10" "$B10" BOX_INSTALL_SOURCE="$SRC9" FAKE_BOXES=work
check "flat upgrade under boxes: ...while the default correctly stayed put (#66)" 0 "box $VER" \
  ibox "$B10/box" --version

# A broken current must halt the single-version path BEFORE any decision: the
# CURRENT guard keys off what current resolves to, and a dangling link makes
# that answer a lie. Drive the version tree's own binary — the current chain
# is exactly what is broken. H4 has two versions; heal current afterwards.
ln -sfn "versions/gone" "$H4/current"
check "uninstall: refuses while current is dangling (heal before delete)" 1 "dangling" \
  ibox "$H4/versions/$VER/bin/box" uninstall 9.9.9-drill --force
check "uninstall: ...and both version trees survived the refusal" 0 "" \
  bash -c "[ -d '$H4/versions/$VER' ] && [ -d '$H4/versions/9.9.9-drill' ]"
ln -sfn "versions/9.9.9-drill" "$H4/current"

# The migration reads VERSION off the old tree — disk data, not installer
# data. A hostile value must refuse BEFORE the tree moves anywhere.
H9="$WORK/h9"; B9="$WORK/b9"; mkdir -p "$H9/bin" "$B9"
cp "$ROOT/bin/box" "$H9/bin/box"; chmod +x "$H9/bin/box"
printf '%s\n' '../pwn' > "$H9/VERSION"
check "migrate: a hostile flat VERSION refuses to migrate" 1 "not a sane directory name" \
  inst "$H9" "$B9"
check "migrate: ...with the flat tree untouched where it was" 0 "" test -x "$H9/bin/box"

# --- healing: a wedged \$BINDIR/box must never block an install -------------
H5="$WORK/h5"; B5="$WORK/b5"; mkdir -p "$B5"
ln -s "$WORK/nowhere/box" "$B5/box"                    # dangling
check "heal: a DANGLING \$BINDIR/box does not wedge the install" 0 "done" inst "$H5" "$B5"
check "heal: ...and got repointed" 0 "box $VER" ibox "$B5/box" --version
H6="$WORK/h6"; B6="$WORK/b6"; mkdir -p "$B6"
ln -s /bin/true "$B6/box"                              # stale, but resolvable
check "heal: a STALE \$BINDIR/box with no tree does not fake 'installed'" 0 "installing $VER" \
  inst "$H6" "$B6"
check "heal: ...the install is real and answers" 0 "box $VER" ibox "$B6/box" --version

# --- box uninstall: one version ---------------------------------------------
check "uninstall: refuses to remove the CURRENT version" 1 "CURRENT" \
  ibox "$B1/box" uninstall "$VER" --force
check "uninstall: an unknown version is refused by name" 1 "no such version" \
  ibox "$B1/box" uninstall 5.5.5 --force
check "uninstall: a path-traversal version dies at the gate (never an rm -rf)" 1 "not a sane version name" \
  ibox "$B1/box" uninstall '../../../../etc' --force
check "uninstall: a version plus --all is ambiguous (usage error)" 2 "" \
  ibox "$B1/box" uninstall 9.9.9-drill --all --force
check "uninstall: removes a non-current version" 0 "removed version" \
  ibox "$B1/box" uninstall 9.9.9-drill --force
check "uninstall: that version dir is gone" 1 "" test -e "$H1/versions/9.9.9-drill"
check "uninstall: the current version still answers" 0 "box $VER" ibox "$B1/box" --version

# --- box uninstall: everything, in the safe order ---------------------------
check "uninstall: refuses while boxes exist, naming them" 1 "wedged" \
  ibox FAKE_BOXES=wedged "$B1/box" uninstall --all --force
check "uninstall: the refusal offers --purge-host" 1 "purge-host" \
  ibox FAKE_BOXES=wedged "$B1/box" uninstall --all --force
check "uninstall: refuses without --force when no terminal" 2 "refusing" \
  ibox bash -c "'$B1/box' uninstall --all </dev/null"
# Plant legacy crumbs: a real uninstall leaves neither name generation behind.
mkdir -p "$FAKEHOME/.local/share/claudebox"
ln -s "$WORK/gone" "$B1/claudebox"
check "uninstall --all: removes the whole install" 0 "uninstalled" \
  ibox "$B1/box" uninstall --all --force
check "uninstall --all: ZERO residue — root, symlinks, legacy names" 0 "" bash -c "
  [ ! -e '$H1' ] && [ ! -L '$H1' ] &&
  [ ! -e '$B1/box' ] && [ ! -L '$B1/box' ] &&
  [ ! -e '$B1/claudebox' ] && [ ! -L '$B1/claudebox' ] &&
  [ ! -e '$FAKEHOME/.local/share/claudebox' ]"
# The last word is a re-check: a survivor must turn into a loud INCOMPLETE,
# never a cheerful "uninstalled". (Root ignores file modes, so this drill is
# meaningful — and runnable — for a non-root runner only.)
if [ "$(id -u)" -ne 0 ]; then
  H7="$WORK/h7"; B7="$WORK/b7"
  inst "$H7" "$B7" >/dev/null 2>&1
  mkdir -p "$H7/versions/$VER/stuck"; touch "$H7/versions/$VER/stuck/pin"
  chmod 555 "$H7/versions/$VER/stuck"
  check "uninstall: a survivor makes it scream INCOMPLETE (exit 1)" 1 "INCOMPLETE" \
    ibox "$B7/box" uninstall --all --force
  chmod -R u+w "$H7" 2>/dev/null
fi

# --- the versioned verbs from a working tree: refuse, don't guess -----------
check "uninstall: refuses from a working tree" 1 "not a versioned install" "$BOX" uninstall --all --force
check "versions: refuses from a working tree" 1 "not a versioned install" "$BOX" versions
check "use: refuses from a working tree" 1 "not a versioned install" "$BOX" use 1.0.0

# The existing-boxes gate must be ONE decision: install.sh and bin/box carry
# byte-identical copies (the installer runs before any tree exists), and a
# drifted copy is two #66 stances pretending to be one.
EBBIN="$(mktemp)"; EBINST="$(mktemp)"
awk '/^existing_boxes\(\) \{/,/^\}/' "$ROOT/bin/box"     > "$EBBIN"
awk '/^existing_boxes\(\) \{/,/^\}/' "$ROOT/install.sh"  > "$EBINST"
check "existing_boxes: extracted from bin/box (guards the awk)" 0 "user.box=1" cat "$EBBIN"
check "existing_boxes: bin/box and install.sh copies are byte-identical" 0 "" diff "$EBBIN" "$EBINST"
rm -f "$EBBIN" "$EBINST"

# Same discipline for the version-name gate: one policy, two copies, no drift
# — a version that install.sh would refuse must not be one 'box use' accepts.
VVBIN="$(mktemp)"; VVINST="$(mktemp)"
awk '/^valid_version\(\) \{/,/^\}/' "$ROOT/bin/box"     > "$VVBIN"
awk '/^valid_version\(\) \{/,/^\}/' "$ROOT/install.sh"  > "$VVINST"
check "valid_version: extracted from bin/box (guards the awk)" 0 "A-Za-z0-9" cat "$VVBIN"
check "valid_version: bin/box and install.sh copies are byte-identical" 0 "" diff "$VVBIN" "$VVINST"
rm -f "$VVBIN" "$VVINST"

# --purge-host must FORWARD installer-family consent: under --force/BOX_YES
# the teardown call carries --yes, or a non-interactive combined uninstall
# dies at teardown's own prompt with the flag's promise broken.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "uninstall: --purge-host forwards consent to teardown-host (--yes)" 0 "" \
  grep -qF -- 'bash "$root/host/teardown-host.sh" --yes' "$ROOT/bin/box"

# --- the help keeps its promises --------------------------------------------
check "help: the table lists 'versions'"                0 "versions"   "$BOX" help
check "help use: names the #66 stance"                  0 "boxes"      "$BOX" help use
check "help uninstall: names --purge-host"              0 "purge-host" "$BOX" help uninstall
check "help uninstall: promises the absence re-check"   0 "absence"    "$BOX" help uninstall

# --- automation hooks the CI uninstall drill rides ---------------------------
check "teardown-host: honors --yes/BOX_YES (CI runs it unattended)" 0 "" \
  grep -qF 'BOX_YES' "$ROOT/host/teardown-host.sh"
check "teardown-host: points at box uninstall when done" 0 "" \
  grep -qF "box uninstall" "$ROOT/host/teardown-host.sh"
# ...and the other side of that contract (#113): consent NOT given and no
# terminal to ask on is a usage error, not a mute 'aborted'. Driven for real —
# the gate sits above the first 'incus' call, so a daemon-free run reaches it.
check "teardown-host: refuses without a TTY and names the override (#113)" 2 \
  "--yes (or BOX_YES=1) means yes" env -u BOX_YES bash "$ROOT/host/teardown-host.sh" </dev/null

# #102's race, pinned as a CLASS rather than at the one site that had it
# (#107). A daemon-free run cannot exercise a UFW teardown, so the shape is
# pinned instead: nowhere under host/, drill/, or bin/box may a known
# multi-line writer be piped into a line reader. `Status: active` is ufw's
# FIRST line, so the
# reader matches, closes the pipe, ufw takes SIGPIPE, and the pipeline
# yields 141 — under pipefail the branch silently reads false and the whole
# firewall block is skipped on a host the operator was told is clean.
#
# Swept, not per-file, because absence of pipefail is what made drill/wipe.sh
# survive the same shape: a file is only ever one `set -o pipefail` — the kind
# of robustness tweak that sails through review — from being #102 again. The
# sweep closes the class, so a new host/ or drill/ script — or a new bin/box
# site — inherits the pin for free instead of being one more site someone has
# to remember. bin/box joined the sweep after #134 removed its existing class.
# Comment lines are stripped before matching: each fix's own commentary quotes
# the racing shape to explain it, and a pin that cannot tell prose from code
# would fail on the very comment documenting why it exists.
#
# BOTH halves of the matcher are alternations, and both were widened in #124:
#
#   · READERS. Pinning `| grep` guarded the instance spelling, not the class.
#     `head -n1`, `sed -n '1p;q'` and `awk '/x/ {print; exit}'` all close the
#     pipe early and produce the identical wrong answer under pipefail. The
#     alternation is deliberately NOT restricted to the early-exit spellings
#     (`grep -q` but not `grep -c`, `sed …q` but not `sed s///`): telling
#     those apart by regex is exactly the kind of precision that rots, and
#     the house idiom is to capture first anyway — all six `ufw status` sites
#     in the tree already do. Banning the pipe outright costs nothing real
#     and cannot be defeated by a spelling nobody enumerated.
#
#   · WRITERS. Enumerated, not generalised. `incus config trust list` joins
#     `ufw status` because host/revoke-user.sh used it as a leftover-detection
#     condition under `set -euo pipefail` (#124). bin/box adds its multi-line
#     `incus` writers, `boxes_csv`, and the export metadata reader (#134). A
#     generic "no multi-line writer feeds a reader" matcher is unwritable here:
#     ~150 legitimate `| grep` sites exist across host/ and drill/, nearly all
#     reading an already-captured string back out of `printf '%s\n' "$var"`.
#     So the sweep claims exactly what it can check — THESE writers are never
#     piped — and grows one named writer at a time.
# shellcheck disable=SC2016  # "$1" is the subshell's positional, passed below
check "no multi-line writer is piped into a line reader under host/, drill/, or bin/box" 0 "" \
  bash -c 'bad=""
    for f in "$1"/host/*.sh "$1"/drill/*.sh "$1"/bin/box; do
      if [ "$f" = "$1/bin/box" ]; then
        writers="ufw status|incus [^|]*|boxes_csv|tar -xOf"
      else
        writers="ufw status|incus config trust list"
      fi
      awk '\''
        /^[[:space:]]*#/ { next }
        {
          line = $0
          if (logical != "") logical = logical line
          else logical = line
          if (line ~ /\\[[:space:]]*$/) {
            sub(/\\[[:space:]]*$/, "", logical)
            next
          }
          print logical
          logical = ""
        }
        END { if (logical != "") print logical }
      '\'' "$f" \
        | grep -qE "($writers)[^|]*\| *(grep|head|sed|awk|read)" \
        && bad="$bad ${f#"$1"/}"
    done
    [ -z "$bad" ] || { printf "racing reads in:%s\n" "$bad"; exit 1; }' \
    _ "$ROOT"

# The other direction, per file that removes UFW rules: the capture present and
# the delete loop breaking on absence, so the sweep above cannot be satisfied by
# deleting the block instead of fixing it.
for f in host/teardown-host.sh drill/wipe.sh; do
  # shellcheck disable=SC2016  # the $-strings are literals in the target files
  check "$f: the UFW branch reads a captured snapshot" 0 "" \
    grep -qF 'if [[ "$ufw_status" == *"Status: active"* ]]; then' "$ROOT/$f"
  # shellcheck disable=SC2016  # ditto
  check "$f: the numbered-delete loop breaks on absence, not on a pipe" 0 "" \
    grep -qF '[ -n "$line" ] || break' "$ROOT/$f"
done

# wipe's shared network can be held by a profile in ANY project. The 0.10.0
# release run found user-1001/box-net after the old current-project-only loop
# claimed to have wiped the host (#263). Drive the real script against a fake
# three-project daemon; sudo is blocked so this fixture cannot touch its host.
WIPEWORK="$(mktemp -d)"
cat > "$WIPEWORK/incus" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$WIPE_LOG"
if [ "$*" = "project list --format csv --columns n" ]; then
  project_list_reads="$(grep -cF 'project list --format csv --columns n' "$WIPE_LOG")"
  if [ "${WIPE_PROJECT_LIST_PARTIAL_AT:-0}" = "$project_list_reads" ]; then
    printf 'default\n'
    exit 1
  fi
  printf 'default\nuser-1000\nuser-1001\n'
  exit 0
fi
case "$*" in
  *" profile delete box-profile"|*" profile delete box-net"|*" profile delete claude-dev") exit 0 ;;
  "--project default network delete "*|"--project default network acl delete "*) exit 0 ;;
  *) exit 1 ;;
esac
SHIM
cat > "$WIPEWORK/sudo" <<'SHIM'
#!/bin/sh
# Never execute a privileged command from this host-independent fixture.
exit 1
SHIM
chmod +x "$WIPEWORK/incus" "$WIPEWORK/sudo"
WIPELOG="$WIPEWORK/incus.log"
WIPE_LOG="$WIPELOG" PATH="$WIPEWORK:/usr/bin:/bin" \
  bash "$ROOT/drill/wipe.sh" --yes >"$WIPEWORK/out" 2>&1
check "wipe: a three-project daemon finishes clean" 0 "clean — no trace" cat "$WIPEWORK/out"
for project in default user-1000 user-1001; do
  for profile in box-profile box-net claude-dev; do
    check "wipe: deletes $profile from $project" 0 "" \
      grep -qF -- "--project $project profile delete $profile" "$WIPELOG"
  done
done
# shellcheck disable=SC2016
check "wipe: deletes profiles before the shared network" 0 "" \
  bash -c 'p="$(grep -n -- "--project user-1001 profile delete box-net" "$1" | cut -d: -f1)"
    n="$(grep -n -- "--project default network delete boxnet" "$1" | cut -d: -f1)"
    [ -n "$p" ] && [ -n "$n" ] && [ "$p" -lt "$n" ]' _ "$WIPELOG"
check "wipe: never deletes an unrelated profile" 1 "" grep -q 'profile delete default' "$WIPELOG"

WIPE_PROJECT_LIST_PARTIAL_AT=1 WIPE_LOG="$WIPEWORK/partial-removal.log" \
  PATH="$WIPEWORK:/usr/bin:/bin" \
  bash "$ROOT/drill/wipe.sh" --yes >"$WIPEWORK/partial.out" 2>&1 || partial_status=$?
check "wipe: a partial removal inventory makes the run fail closed" 1 "" \
  test "${partial_status:-0}" -eq 0
check "wipe: a failed inventory explains why it cannot verify the host" 0 \
  "project inventory FAILED" cat "$WIPEWORK/partial.out"
check "wipe: a failed inventory cannot produce the clean verdict" 1 "" \
  grep -q "clean — no trace" "$WIPEWORK/partial.out"

WIPE_PROJECT_LIST_PARTIAL_AT=2 WIPE_LOG="$WIPEWORK/partial-verdict.log" \
  PATH="$WIPEWORK:/usr/bin:/bin" \
  bash "$ROOT/drill/wipe.sh" --yes >"$WIPEWORK/verdict.out" 2>&1 || verdict_status=$?
check "wipe: a partial verification inventory makes the run fail closed" 1 "" \
  test "${verdict_status:-0}" -eq 0
check "wipe: a failed verification cannot produce the clean verdict" 1 "" \
  grep -q "clean — no trace" "$WIPEWORK/verdict.out"

# Same other-direction pin for the non-ufw writer the sweep now names: the
# --purge leftover assert must match a captured trust store, so the sweep
# cannot be satisfied by deleting the assert instead of fixing it. That assert
# is the last thing standing between "purge INCOMPLETE" and a silent claim of
# success on a host that still trusts the revoked user's certificate.
# shellcheck disable=SC2016  # the $-strings are literals in the target file
check "revoke-user: the purge leftover assert reads a captured trust store" 0 "" \
  grep -qF 'trust_csv="$(incus config trust list' "$ROOT/host/revoke-user.sh"
# shellcheck disable=SC2016  # ditto
check "revoke-user: the cert leftover check matches the capture, not a pipe" 0 "" \
  grep -qF '"$trust_csv" == *$' "$ROOT/host/revoke-user.sh"
# The read still goes through current/ — the versioned layout's default
# symlink — but the root of it is resolved by uid rather than hard-coded to
# $HOME, which is what made a root run read a file that never existed (#225).
# shellcheck disable=SC2016  # a literal in the target file
check "drill: reads the installed tree through current/" 0 "" \
  grep -qF '"$BOX_SHARE/current/VERSION"' "$ROOT/drill/drill.sh"
# shellcheck disable=SC2016  # ditto
check "drill: ...and never through a hard-coded per-user path (#225)" 1 "" \
  grep -qF '.local/share/box/current' "$ROOT/drill/drill.sh"

# ---------------------------------------------------------------------------
# 'restart', and 'all' — the fleet word on the lifecycle verbs (#179)
# ---------------------------------------------------------------------------
# Driven end to end under a shim incus, because the whole of this feature is
# what box CALLS: which boxes it enumerates, in what order it keeps going, and
# what status it leaves behind. A grep would pin none of that.
FSHIM="$(mktemp -d)"; FWORK="$(mktemp -d)"
cat > "$FSHIM/incus" <<'SHIM'
#!/usr/bin/env bash
# Fake incus for the fleet drive (#179).
#   FAKE_BOXES   space-separated names 'incus list' reports as box-tagged
#   FAKE_FAIL    space-separated names whose lifecycle call fails, as incus
#                fails: non-zero, with a reason on stderr
#   FAKE_STATES  space-separated name=STATE pairs; anything unlisted is RUNNING
#   FAKE_DEAD    non-empty: 'incus list' fails the way a daemon that is not
#                answering fails — non-zero, a reason on stderr, nothing on
#                stdout. Not the same thing as reporting no boxes.
printf 'incus %s\n' "$*" >> "$FAKE_INCUS_LOG"
state_of() {   # $1 = box name
  for kv in ${FAKE_STATES:-}; do
    if [ "${kv%%=*}" = "$1" ]; then printf '%s' "${kv#*=}"; return; fi
  done
  printf 'RUNNING'
}
inst_of() {   # the first non-flag argument after the subcommand.
  # A positional read of "$2" was enough while every lifecycle call was
  # 'incus <sub> <box>'. 'box down --force' makes it 'incus stop --force
  # <box>' (#236), and a shim that took the flag for the instance would
  # answer RUNNING for a box named '--force' and never fail an injected
  # failure again — every mixed-state assertion below would pass for a build
  # that had stopped reading the state at all.
  local a; shift
  for a in "$@"; do
    case "$a" in -*) ;; *) printf '%s' "$a"; return ;; esac
  done
}
case "${1:-}" in
  list)
    if [ -n "${FAKE_DEAD:-}" ]; then
      echo "Error: The incus daemon doesn't appear to be started" >&2
      exit 1
    fi
    # boxes_csv() asks twice — user.box=1 then the legacy user.claudebox=1 —
    # and dedupes. Only the modern tag answers here, so a fleet that acted
    # twice per box would show up as duplicate lifecycle calls in the log.
    case "$*" in
      *--columns\ s*)
        # box_state()'s read, which the 'stopped' precondition goes through.
        # A different --columns spelling from boxes_csv()'s 'nstS', so the two
        # reads cannot be confused for one another here either.
        state_of "${2:-}"; echo ;;
      *user.box=1*)
        for b in ${FAKE_BOXES:-}; do
          printf '%s,%s,CONTAINER,0\n' "$b" "$(state_of "$b")"
        done ;;
    esac
    exit 0 ;;
  config)
    # resolve_box()'s boundary read, for the single-box path.
    if [ "${2:-}" = get ]; then
      for b in ${FAKE_BOXES:-}; do
        if [ "$b" = "${3:-}" ] && [ "${4:-}" = user.box ]; then echo 1; exit 0; fi
      done
    fi
    exit 0 ;;
  restart|stop|start)
    inst="$(inst_of "$@")"
    for f in ${FAKE_FAIL:-}; do
      if [ "$f" = "$inst" ]; then
        echo "Error: The instance \"$inst\" is busy" >&2
        exit 1
      fi
    done
    # Incus's own already-in-state refusals, reproduced verbatim, because a
    # shim that cheerfully succeeds on them would let the mixed-state
    # assertions below pass for a build that never looked at the state. These
    # are what lxc/incus returns: restartCommon() and the !IsRunning() /
    # isRunningStatusCode() guards in the lxc driver. Note the third: 'restart'
    # on a stopped instance does NOT start it, it errors.
    case "$1:$(state_of "$inst")" in
      stop:STOPPED)    echo "Error: The instance is already stopped" >&2; exit 1 ;;
      start:RUNNING)   echo "Error: The container is already running" >&2; exit 1 ;;
      restart:STOPPED) echo "Error: The instance is already stopped" >&2; exit 1 ;;
    esac
    exit 0 ;;
esac
exit 0
SHIM
chmod +x "$FSHIM/incus"

FLOG="$FWORK/fleet.log"
FLEET_STATES=""
fleetbox() {   # fleetbox <boxes> <failing> <box args...> — the real box, shimmed
  local boxes="$1" failing="$2"; shift 2
  : > "$FLOG"
  env FAKE_INCUS_LOG="$FLOG" FAKE_BOXES="$boxes" FAKE_FAIL="$failing" \
    FAKE_STATES="$FLEET_STATES" PATH="$FSHIM:$PATH" "$BOX" "$@" </dev/null 2>&1
}
# The same box, against a daemon that does not answer at all. Deliberately a
# separate helper rather than a FAKE_BOXES value: "the daemon said no boxes"
# and "the daemon said nothing" are the two states this round is about telling
# apart, and they should not share a spelling in the drive either.
deadbox() {   # deadbox <box args...>
  : > "$FLOG"
  env FAKE_INCUS_LOG="$FLOG" FAKE_BOXES="one two" FAKE_FAIL="" FAKE_DEAD=1 \
    PATH="$FSHIM:$PATH" "$BOX" "$@" </dev/null 2>&1
}
# An absence assertion, as a non-zero exit: 'check' matches a substring's
# presence, so "it does NOT say the D6 line" needs the grep to be the command.
dead_says_empty() { deadbox "$@" | grep -q 'nothing to'; }
# The same, with a mixed-state daemon: <name=STATE ...> first, anything
# unlisted is RUNNING. Set-then-clear rather than a `VAR=x fn` prefix, whose
# persistence past the call is a bash-version question I would rather not ask.
mixedbox() {   # mixedbox <states> <boxes> <failing> <box args...>
  local states="$1" rc; shift
  FLEET_STATES="$states"; fleetbox "$@"; rc=$?; FLEET_STATES=""; return "$rc"
}
# What box actually asked the daemon to do, one line per lifecycle call.
acted_on() { grep -cE "^incus (restart|stop|start) $1( |\$)" "$FLOG"; }
fleet_calls() { grep -cE "^incus $1 " "$FLOG"; }
# Helpers rather than 'sh -c': the quoting a sh -c needs to carry $ILOG into a
# subshell is exactly the SC2016 the sweep reds, and a function reads better.
run_fleet_src() { sed -n '/^run_fleet()/,/^}/p' "$ROOT/bin/box"; }
run_fleet_has() { run_fleet_src | grep -qF "$1"; }
run_fleet_matches() { run_fleet_src | grep -qE "$1"; }
# Absence assertions, as a non-zero exit: 'check' matches a substring's
# presence, so "is NOT refused" needs the grep to be the command under test.
new_says_reserved() { "$BOX" new --name "$1" 2>&1 | grep -q reserved; }
# The first of the two calls inside cmd_new must be the reserved-word guard.
guard_precedes_stack() {
  sed -n '/^cmd_new()/,/^}/p' "$ROOT/bin/box" \
    | grep -o 'refuse_fleet_word\|require_stack' \
    | head -1 | grep -q refuse_fleet_word
}
# The same contract for the table door: the 'newname' precondition has to run
# ahead of the 'box' one, because resolving the first positional is a daemon
# round trip and whether 'all' is a legal new name does not depend on it. Line
# numbers rather than a first-match grep: the two markers are on different
# lines, and asking which comes first is the whole assertion.
newname_precedes_resolve() {
  local g r
  g="$(grep -n '\*,newname,\*)' "$ROOT/bin/box" | head -1 | cut -d: -f1)"
  r="$(grep -n 'inst=.*resolve_box' "$ROOT/bin/box" | head -1 | cut -d: -f1)"
  [ -n "$g" ] && [ -n "$r" ] && [ "$g" -lt "$r" ]
}

# --- D1: restart is one incus call, not down-then-start ---------------------
check "restart: one box restarts" 0 "restarted work" \
  fleetbox "work" "" restart work
check "restart: it is a single 'incus restart'" 0 "1" \
  acted_on work
check "restart: no 'stop' rides along — this is not down-then-start" 1 "" \
  grep -qE '^incus stop ' "$FLOG"
check "restart: the verb is in the table, so help renders it" 0 "usage: box restart" \
  "$BOX" help restart

# --- D3: 'all' is exactly what 'box list' prints for this caller ------------
# The tier boundary itself is Incus's — a restricted user's client is scoped to
# user-<uid> and an admin's to default, and no shim can model that refusal.
# What IS box's to get right, and what this drives, is that 'all' enumerates
# through boxes_csv() and builds no second path around the boundary: box acts
# on exactly the set the daemon showed it, no more.
check "all: acts on every box the daemon reports" 0 "restarted one" \
  fleetbox "one two three" "" restart all
check "all: ...and that is all three of them" 0 "3" \
  fleet_calls restart
check "all: the third box is named too" 0 "restarted three" \
  fleetbox "one two three" "" restart all
check "all: a box the daemon did NOT report is never touched" 1 "" \
  grep -qE '^incus restart other' "$FLOG"
# Structural, and load-bearing: the fleet set MUST come from boxes_csv(), the
# same reader 'box list' prints from. A second enumeration would be a second
# implementation of the tier boundary, which is how one of them gets a hole.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "all: the fleet is read through the 'box list' source, not a second list" 0 "" \
  run_fleet_has 'rows="$(boxes_csv)"'
check "all: run_fleet enumerates nothing else" 1 "" \
  run_fleet_matches 'incus list|--columns'

# The restricted-tier read and the admin read, each seeing only its own side —
# the assertion the test plan calls the one that must fail before the guard is
# right. Same box, same verb; the only difference is what the daemon answers.
check "all (restricted): acts on the caller's own box" 0 "stopped dev1-work" \
  fleetbox "dev1-work" "" down all
check "all (restricted): touches no admin box" 1 "" \
  grep -qE '^incus stop admin-' "$FLOG"
check "all (admin): acts on the admin's box" 0 "stopped admin-ci" \
  fleetbox "admin-ci" "" down all
check "all (admin): touches nothing in a restricted project" 1 "" \
  grep -qE '^incus stop dev1-' "$FLOG"

# --- D4: one failure does not abort the rest, and the status aggregates -----
# All three are STOPPED here, so 'start' genuinely has work to do on each and
# the only non-zero in the block is the injected failure — not a box that was
# already where it was asked to be.
check "all: a failing box does not stop the others (exit is aggregate)" 1 "started one" \
  mixedbox "one=STOPPED two=STOPPED three=STOPPED" "one two three" "two" start all
# Exit 1 throughout this block: the aggregate status is the point, so every
# case here asserts the failing status AND the work that happened anyway.
check "all: ...the box after the failure still acted" 1 "started three" \
  mixedbox "one=STOPPED two=STOPPED three=STOPPED" "one two three" "two" start all
check "all: ...the failure is named" 1 "two FAILED" \
  mixedbox "one=STOPPED two=STOPPED three=STOPPED" "one two three" "two" start all
check "all: ...with incus's own reason, never swallowed" 1 "is busy" \
  mixedbox "one=STOPPED two=STOPPED three=STOPPED" "one two three" "two" start all
check "all: ...and the run says how many of each" 1 "2 of 3 succeeded, 1 failed" \
  mixedbox "one=STOPPED two=STOPPED three=STOPPED" "one two three" "two" start all
check "all: every box was attempted despite the failure" 0 "3" \
  fleet_calls start
check "all: all three succeeding exits 0" 0 "started three" \
  mixedbox "one=STOPPED two=STOPPED three=STOPPED" "one two three" "" start all

# --- the mixed-state fleet: already-there is not a failure ------------------
# A fleet is mixed-state in the ordinary case, and Incus errors when an
# instance is already in the state you asked for. Without this, 'down all' reds
# whenever one box was already down — which unmeasures D4's exit status and
# leaves the issue's first test-plan line unmet. The shim above answers exactly
# as Incus does, so every assertion here reds if run_fleet() stops reading the
# state column.
check "mixed: 'down all' stops the running box" 0 "stopped one" \
  mixedbox "two=STOPPED" "one two" "" down all
check "mixed: ...names the already-stopped one as the success it is" 0 "two is already stopped" \
  mixedbox "two=STOPPED" "one two" "" down all
check "mixed: ...and calls incus for the one box that needed it" 0 "1" \
  fleet_calls stop
check "mixed: ...never for the box that was already there" 1 "" \
  grep -qE '^incus stop two( |$)' "$FLOG"
check "mixed: 'start all' names the already-running box" 0 "one is already running" \
  mixedbox "two=STOPPED" "one two" "" start all
check "mixed: ...and starts only the stopped one" 0 "started two" \
  mixedbox "two=STOPPED" "one two" "" start all
check "mixed: ...one call, not two" 0 "1" fleet_calls start

# The issue's test plan, line one: two boxes up, one down — 'restart all'
# reports three outcomes and leaves all three running.
check "mixed: 'restart all' restarts the running boxes" 0 "restarted one" \
  mixedbox "three=STOPPED" "one two three" "" restart all
check "mixed: ...and the second of them" 0 "restarted two" \
  mixedbox "three=STOPPED" "one two three" "" restart all
check "mixed: ...and STARTS the stopped one rather than erroring on it" 0 "started three — it was stopped" \
  mixedbox "three=STOPPED" "one two three" "" restart all
check "mixed: ...through a single 'incus start', which is not down-then-start (D1)" 0 "1" \
  fleet_calls start
check "mixed: ...with no 'stop' anywhere in the run" 1 "" \
  grep -qE '^incus stop ' "$FLOG"
check "mixed: ...two restarts and one start, three boxes, three outcomes" 0 "2" \
  fleet_calls restart

# The aggregate status still means what D4 says it means: a real failure beside
# a no-op box is still non-zero, and the no-op is still reported.
check "mixed: a real failure beside an already-stopped box still exits non-zero" 1 "two FAILED" \
  mixedbox "three=STOPPED" "one two three" "two" down all
check "mixed: ...and the already-stopped box is still reported" 1 "three is already stopped" \
  mixedbox "three=STOPPED" "one two three" "two" down all
check "mixed: ...counted as one of the successes, not skipped from the tally" 1 "2 of 3 succeeded, 1 failed" \
  mixedbox "three=STOPPED" "one two three" "two" down all

# Only the three pairs that are guaranteed to error are handled. Anything else
# goes to Incus and Incus decides — this is a refusal to make two doomed calls,
# not a state machine that has to know every state Incus will ever have.
check "mixed: an unmodelled state passes straight through to incus" 0 "stopped one" \
  mixedbox "one=FROZEN" "one" "" down all
check "mixed: ...as a real call, not a skip" 0 "1" fleet_calls stop

# require_stopped() has accepted three spellings of STOPPED in this file since
# long before the fleet word existed, so the state match does not trust Incus's
# current casing habit either.
check "mixed: the state match is case-insensitive, as require_stopped's is" 0 "two is already stopped" \
  mixedbox "two=stopped" "one two" "" down all
check "mixed: ...and it still calls incus for the box that needed it" 0 "stopped one" \
  mixedbox "two=stopped" "one two" "" down all

# --- D5: no prompt on the fleet forms, and 'rm' has no 'all' ----------------
# No TTY here, so a confirm() would exit 2 with "refusing to ... without
# --force" — which is exactly how this asserts the absence of a prompt.
check "all: 'down all' does not prompt" 0 "stopped one" \
  fleetbox "one two" "" down all
check "all: 'restart all' does not prompt" 0 "restarted one" \
  fleetbox "one two" "" restart all
check "rm has no fleet form: 'all' is resolved as an ordinary name" 1 "no such box: all" \
  fleetbox "one two" "" rm all --force
check "rm has no fleet form: it deleted nothing" 1 "" \
  grep -qE '^incus delete' "$FLOG"
check "rm's row carries no 'fleet' token" 1 "" \
  grep -qE '^  "rm\^[^^]*\^[^^]*fleet' "$ROOT/bin/box"

# --- the fleet form takes nothing after the word ----------------------------
# The single-box path forwards everything after the name to incus. The fleet
# path cannot — "this flag once" and "this flag to each of six boxes" are
# different acts — so it refuses instead of dropping the word in silence, which
# is the one outcome the operator has no way to notice.
check "all: a trailing word is a usage error, not a silent drop" 2 "takes nothing else" \
  fleetbox "one two" "" down all extra
check "all: ...and it names the word it refused" 2 "'extra'" \
  fleetbox "one two" "" down all extra
check "all: ...having touched no box" 1 "" grep -qE '^incus stop ' "$FLOG"
# The reachable spelling of a flag: box rejects an unknown --flag at parse
# time, so anything flag-shaped arrives after '--'. It is refused on the fleet
# form too, rather than being forwarded to every box or dropped.
check "all: a flag passed through '--' is refused as well" 2 "takes nothing else" \
  fleetbox "one two" "" down all -- --force
check "all: the single-box path still forwards its extras" 0 "stopped one" \
  fleetbox "one" "" down one extra
check "all: ...to incus, exactly as before" 0 "" \
  grep -qE '^incus stop one extra$' "$FLOG"

# --- D6: 'all' over zero boxes is success with a message --------------------
check "all: no boxes at all exits 0" 0 "nothing to restart" \
  fleetbox "" "" restart all
check "all: no boxes — and it called no lifecycle verb" 1 "" \
  grep -qE '^incus restart ' "$FLOG"
check "all: 'down all' on an empty host says so too" 0 "nothing to down" \
  fleetbox "" "" down all

# --- ...and a daemon that never answered is NOT an empty host ---------------
# The other side of D6, and the one that has to be told apart from it: an empty
# 'rows' means "no boxes" only if the question was asked and answered. A daemon
# that refused leaves it empty too, and reporting THAT as D6 makes 'box start
# all || alert' pass a run in which nothing happened at all — #179's own
# motivating scenario, a fleet start fired before incusd is up. run_fleet reads
# boxes_csv's status explicitly, because the '|| exit $?' call site suppresses
# errexit through the whole function body.
check "dead daemon: 'down all' does not claim the host is empty, and exits non-zero" 1 "not answering" \
  deadbox down all
check "dead daemon: ...having called no lifecycle verb" 1 "" \
  grep -qE '^incus (stop|start|restart) ' "$FLOG"
check "dead daemon: ...never reporting it as D6's empty fleet" 1 "" \
  dead_says_empty down all
check "dead daemon: 'start all' says the same thing" 1 "not answering" \
  deadbox start all
check "dead daemon: 'restart all' too" 1 "not answering" \
  deadbox restart all
# The message is require_stack()'s, so the two doors say one thing about a
# daemon that is not there — and it names the diagnosis rather than the fault.
check "dead daemon: it points at the same diagnosis require_stack does" 1 "box doctor" \
  deadbox down all
# require_stack() no-ops under --remote, so it could not have caught this one
# even if the fleet path reached it. The status read is what does.
check "dead daemon: an unreachable --remote is caught as well" 1 "not answering" \
  deadbox down all --remote lab
# The contrast, on the same shim: with the daemon answering, the empty fleet is
# still D6's success. Without this the fix could be "always die", which would
# red D6 rather than distinguish it.
check "dead daemon: an ANSWERING daemon with no boxes is still D6" 0 "nothing to down" \
  fleetbox "" "" down all

# --- D2: 'all' is reserved, refused at every door that SETS a name ----------
# No shim needed: the refusal lands before any daemon call, which is itself
# the point — a name box will never mint cannot depend on a reachable daemon.
check "new --name all is refused" 1 "reserved" \
  "$BOX" new --name all
check "new --name all names the fleet word" 1 "fleet word" \
  "$BOX" new --name all
# This whole suite runs with no incus on PATH, so the refusal above already
# happened without a daemon. Pinned structurally as well, because the ORDER is
# the contract: a name box will never mint must not depend on a reachable host.
check "new: the reserved word is refused before require_stack" 0 "" \
  guard_precedes_stack
# The other direction: the guard catches its one word and nothing else, so it
# cannot be satisfied by refusing every mint.
check "the reserved word itself is caught" 0 "" new_says_reserved all
check "an ordinary name is not refused by the reserved-word guard" 1 "" \
  new_says_reserved allocated
check "a name merely CONTAINING the word is not refused" 1 "" \
  new_says_reserved install-all
# A real tarball, because cmd_import reads the embedded instance name with tar
# before any of this is reached — and the refusal must land after that read,
# since the artifact's OWN name is a door too when no --name overrides it.
FART="$FWORK/work-20260820T120000Z.tar.gz"
mkdir -p "$FWORK/backup" && printf 'name: work\n' > "$FWORK/backup/index.yaml"
tar -czf "$FART" -C "$FWORK" backup/index.yaml
import_says_reserved() {   # extra args, e.g. --name all
  env FAKE_INCUS_LOG="$FLOG" FAKE_BOXES="" FAKE_FAIL="" PATH="$FSHIM:$PATH" \
    "$BOX" import "$FART" "$@" </dev/null 2>&1 | grep -q reserved
}
check "import --name all is refused too — import mints a name as well" 1 "reserved" \
  fleetbox "" "" import "$FART" --name all
check "import --name all refuses before the daemon is asked to import" 1 "" \
  grep -qE '^incus import' "$FLOG"
# The other direction, so the guard cannot be satisfied by refusing every
# import: the same artifact under its own embedded name gets past the word.
check "import --name all: the guard is what refused it" 0 "" \
  import_says_reserved --name all
check "import under an ordinary name is not caught by the guard" 1 "" \
  import_says_reserved

# --- ...including 'rename', which sets a name through a ROW -----------------
# The third door, and the one that shipped unguarded: 'new' and 'import' are
# function actions with a call site to put the guard in, while 'rename' is a
# table row whose second positional went straight to 'incus rename'. A box
# renamed to 'all' is unreachable by all three lifecycle verbs, which is the
# collision D2 exists to prevent — so the reserved word has to be refused where
# the name is SET, not only where a box is first minted.
renamebox() {   # renamebox <new-name> — a stopped 'work', shimmed
  mixedbox "work=STOPPED" "work" "" rename work "$@"
}
check "rename to 'all' is refused — a rename sets a name too" 1 "reserved" \
  renamebox all
check "rename to 'all' names the fleet word" 1 "fleet word" \
  renamebox all
# The assertion that fails at the head this was found on: the message alone
# would pass for a build that refused after the daemon had already renamed it.
check "rename to 'all': the daemon is never asked to rename" 1 "" \
  grep -qE '^incus rename ' "$FLOG"
# The other direction, so the guard cannot be satisfied by refusing every
# rename: an ordinary target still reaches Incus and still reports.
check "an ordinary rename target still reaches incus" 0 "renamed work to archive" \
  renamebox archive
check "...as a real 'incus rename' call" 0 "1" \
  fleet_calls rename
# ...and the identity rides straight through it, which is the whole of #181:
# 'rename' moves the NAME and touches no config, so a box that was renamed is
# still provably the same box. Asserted on the drive rather than on the source,
# because what matters is that no call was made.
check "rename: the id is never written, so it survives the rename (#181)" 1 "" \
  grep -qE 'config (set|unset) .*user\.box\.id' "$FLOG"
# Same contract as the mint doors, and the reason the token runs ahead of the
# 'box' precondition: refusing a name box will never carry must not depend on a
# reachable daemon. This suite runs with no incus on PATH, so the bare call is
# the probe, and the order is pinned structurally beside it.
check "rename to 'all' is refused with no daemon at all" 1 "reserved" \
  "$BOX" rename work all
check "rename: the reserved word is refused before the box is resolved" 0 "" \
  newname_precedes_resolve
# '--' ends box's own option parsing and the rest becomes positionals, so the
# word arrives as args[1] either way and there is no escape spelling. Driven
# because "the guard reads the parsed positional, not the command line" is the
# reason, and a reader should not have to take it on trust.
check "rename to 'all' after '--' is refused as well" 1 "reserved" \
  "$BOX" rename work -- all
# The token is on 'rename' alone: 'restore' also takes a second positional, but
# it is a snapshot label and no box ends up carrying it.
check "restore's snapshot label is not caught — a different namespace" 0 "restored work to all" \
  mixedbox "work=STOPPED" "work" "" restore work all --force

# ---------------------------------------------------------------------------
# 'box down --force' — the power button, with the boundary still on (#236)
# ---------------------------------------------------------------------------
# Driven on the same shim, because the whole of this feature is what box CALLS.
# Every assertion here that matters is on the call log: "the flag reached
# incus" and "the flag did NOT reach incus" are the two facts, and only the log
# holds either. The log line is the shim's "$*", so the exact argv is visible.

# Absence assertions, as non-zero exits: 'check' matches a substring's
# presence, so "the call carried no --force" needs the grep to be the command.
log_has_force() { grep -qE -- '--force' "$FLOG"; }
# D4's order, pinned the way newname_precedes_resolve pins the mint door's: the
# tag check lives in the 'box' precondition and must run BEFORE dispatch reads
# 'forceable', or a forced call could reach incus for an instance box never
# resolved. Line numbers rather than a first-match grep — which comes first is
# the whole assertion, and a run in which the check refused cannot show it.
boundary_precedes_forceable() {
  local r f
  r="$(grep -n 'inst=.*resolve_box' "$ROOT/bin/box" | head -1 | cut -d: -f1)"
  f="$(grep -n '\*,forceable,\*)' "$ROOT/bin/box" | head -1 | cut -d: -f1)"
  [ -n "$r" ] && [ -n "$f" ] && [ "$r" -lt "$f" ]
}
start_help_has_force() { "$BOX" help start | grep -qF -- '--force'; }
# One 'down' entry in the general help, and one 'down' row in the table. D3 is
# about the SURFACE: a force variant that arrived as a second verb would show
# up in exactly these two places.
down_help_entries() { "$BOX" help | grep -cE '^ +down +'; }
down_table_rows()   { grep -cE '^  "down\^' "$ROOT/bin/box"; }
# Every verb the table declares — verbs() reads the same first field, so the
# table is the honest source and needs no daemon to read.
table_verbs()       { grep -oE '^  "[a-z-]+\^' "$ROOT/bin/box" | tr -d ' "^'; }
verb_named_force()  { table_verbs | grep -q force; }
# The two readings of --force cannot share a row: 'confirm' reads it as
# skip-the-prompt, 'forceable' as a flag to incus. Dispatch dies rather than
# pick a winner, and no row asks it to.
row_is_both() {
  grep -oE '^  "[a-z-]+\^[^^]*\^[^^]*\^' "$ROOT/bin/box" \
    | grep -E 'forceable' | grep -q 'confirm'
}
# The graceful refusal and the forceful one are ONE message, not two that
# happen to share a stem — D4 is that forcing changes nothing about the check.
same_refusal() {
  local g f
  g="$(fleetbox "one" "" down other 2>&1)"
  f="$(fleetbox "one" "" down other --force 2>&1)"
  [ "$g" = "$f" ]
}

# --- D1: the default does not move ------------------------------------------
# The first line of the test plan, and the one worth the most: a build that
# force-stopped by default would pass every other assertion in this block.
check "down: plain 'down' is still graceful" 0 "stopped one" \
  fleetbox "one" "" down one
check "down: ...and the call carries no --force at all" 1 "" log_has_force
check "down: ...it is exactly 'incus stop <box>', byte for byte" 0 "" \
  grep -qxF 'incus stop one' "$FLOG"

# --- D1: --force reaches incus as incus's own flag --------------------------
check "down --force: the box stops" 0 "stopped one" \
  fleetbox "one" "" down one --force
check "down --force: ...as 'incus stop --force <box>'" 0 "" \
  grep -qxF 'incus stop --force one' "$FLOG"
check "down -f: the short spelling forces too" 0 "stopped one" \
  fleetbox "one" "" down one -f
check "down -f: ...as the same call" 0 "" \
  grep -qxF 'incus stop --force one' "$FLOG"

# --- D4: the boundary holds under force -------------------------------------
# The half 'box incus <box> -- stop --force' loses, and the main reason this
# belongs in box. --force skips the politeness, never the tag check.
check "down --force: an instance box did not tag is refused" 1 "no such box: other" \
  fleetbox "one" "" down other --force
check "down --force: ...and the daemon is never asked to stop it" 1 "" \
  grep -qE '^incus stop ' "$FLOG"
check "down: the graceful path refuses the same instance" 1 "no such box: other" \
  fleetbox "one" "" down other
check "down --force: the refusal is the SAME message, not a second one" 0 "" \
  same_refusal
# The order is the contract: resolve_box() runs in the 'box' precondition,
# which is ahead of where 'forceable' is read. Structural, because "the check
# ran first" is not visible in a run where the check refused.
check "down --force: the boundary is resolved before --force is read" 0 "" \
  boundary_precedes_forceable

# --- D3: one verb, one row, one flag ----------------------------------------
check "down --force: 'box help' shows exactly one 'down' entry" 0 "1" \
  down_help_entries
check "down --force: the table carries exactly one 'down' row" 0 "1" \
  down_table_rows
check "down --force: no verb is named for the flag" 1 "" verb_named_force
check "down --force: 'down-force' is not a command" 2 "unknown command" \
  "$BOX" down-force
check "down --force: the synopsis names the flag" 0 "usage: box down <box>|all [--force]" \
  "$BOX" help down

# --- D-out: no timeout, no silent escalation --------------------------------
# A graceful stop that FAILS is not retried with the power button. This is the
# property crew#486's D1 exists to protect, and it is driven rather than
# grepped: an injected failure is exactly the moment an escalation would fire.
check "down: a failing graceful stop exits non-zero" 1 "" \
  fleetbox "one" "one" down one
check "down: ...it is NOT retried with --force" 1 "" log_has_force
check "down: ...and exactly one call was made" 0 "1" fleet_calls stop

# --- D-out: 'start' and 'restart' are untouched -----------------------------
# They share the lifecycle shape and neither carries the token, so --force is
# the inert positional-less flag it has always been on them — not a second
# meaning quietly acquired.
check "start --force: passes no flag to incus" 0 "started one" \
  mixedbox "one=STOPPED" "one" "" start one --force
check "start --force: ...the call is a plain 'incus start'" 0 "" \
  grep -qxF 'incus start one' "$FLOG"
check "restart --force: likewise" 0 "restarted one" \
  fleetbox "one" "" restart one --force
check "restart --force: ...a plain 'incus restart'" 0 "" \
  grep -qxF 'incus restart one' "$FLOG"
check "start: its help does not advertise a flag it does not take" 1 "" \
  start_help_has_force

# --- the 'confirm' rows keep the OTHER reading of --force -------------------
# One flag, two readings, and they must not leak into each other: 'rm --force'
# is still skip-the-prompt and its incus call is unchanged.
check "rm --force: still means skip-the-prompt" 0 "removed one" \
  mixedbox "one=STOPPED" "one" "" rm one --force
check "rm --force: ...and its call is unchanged" 0 "" \
  grep -qxF 'incus delete -f one' "$FLOG"
check "restore --force: passes no --force to incus either" 0 "restored work to snap" \
  mixedbox "work=STOPPED" "work" "" restore work snap --force
check "restore --force: ...its call is unchanged" 0 "" \
  grep -qxF 'incus snapshot restore work snap' "$FLOG"
check "the table has no row that is both forceable and confirm" 1 "" row_is_both
check "...and dispatch refuses one that is, rather than picking a winner" 0 "" \
  grep -qF 'marked both forceable and confirm' "$ROOT/bin/box"

# --- the fleet form forces too ----------------------------------------------
check "down all --force: the fleet stops" 0 "stopped one" \
  fleetbox "one two" "" down all --force
check "down all --force: ...the first box forcefully" 0 "" \
  grep -qxF 'incus stop --force one' "$FLOG"
check "down all --force: ...and the second too" 0 "" \
  grep -qxF 'incus stop --force two' "$FLOG"
check "down all: without the flag the fleet is graceful" 0 "stopped one" \
  fleetbox "one two" "" down all
check "down all: ...with no --force anywhere in the run" 1 "" log_has_force
# The flag is kept OFF $sub for this: fleet_op() matches on the bare
# subcommand, so 'stop --force' would miss the stop:STOPPED pair and hand an
# already-stopped box to incus, which errors. A box already down needs no
# power button, and #179's mixed-state contract survives the flag intact.
check "down all --force: an already-stopped box is still the skip it was" 0 "two is already stopped" \
  mixedbox "two=STOPPED" "one two" "" down all --force
check "down all --force: ...incus is never called for it, forced or not" 1 "" \
  grep -qE '^incus stop( --force)? two( |$)' "$FLOG"
check "down all --force: ...while the running one IS forced" 0 "" \
  grep -qxF 'incus stop --force one' "$FLOG"
check "down all --force: the run still exits 0" 0 "stopped one" \
  mixedbox "two=STOPPED" "one two" "" down all --force
# The tier boundary is the fleet's, drawn by boxes_csv(), and the flag does not
# widen it: a forced 'all' reaches exactly the boxes a graceful one does.
check "down all --force (restricted): acts on the caller's own box" 0 "stopped dev1-work" \
  fleetbox "dev1-work" "" down all --force
check "down all --force: ...and touches no admin box" 1 "" \
  grep -qE '^incus stop --force admin-' "$FLOG"

# --- the documentation names it where the operator will look ----------------
check "down --force: the global --force line names 'down' (bin/box:195)" 0 \
  "a box that will not stop gracefully (down)" "$BOX" help
check "down --force: 'box help down' says the unflushed state is lost" 0 \
  "NOT FLUSHED TO DISK IS LOST" "$BOX" help down
check "down --force: ...that box never escalates on its own" 0 \
  "never escalates on its own" "$BOX" help down
check "down --force: ...and that the boundary still holds under it" 0 \
  "politeness, never the check" "$BOX" help down
check "down --force: the README command reference names the flag" 0 "" \
  grep -qF 'box down <box>|all [--force]' "$ROOT/README.md"
check "down --force: ...and the README says the guest's unflushed state is lost" 0 "" \
  grep -qF 'Anything the' "$ROOT/README.md"
rm -rf "$FSHIM" "$FWORK"

# --- the real-daemon half, pinned so it cannot be deleted quietly -----------
# The shim above proves box acts on exactly the set the daemon showed it. What
# that set IS for a restricted caller is Incus's answer, and only the two-user
# rehearsal on a real daemon asks it. These greps are the same guard the other
# multiuser criteria carry here: a probe removed from the rehearsal reds this
# suite instead of silently reducing what CI measures.
check "multiuser: criterion (p) drives the fleet word" 0 "" \
  grep -qF 'box down all' "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "multiuser: (p) reads the other user's boxes back from the admin socket" 0 "" \
  grep -qF 'untouched by $U2' "$ROOT/drill/multiuser.sh"
check "multiuser: (p) restores its own box so later phases keep their premise" 0 "" \
  grep -qF 'box start all' "$ROOT/drill/multiuser.sh"
check "multiuser: (p) proves the reserved name on a real daemon" 0 "" \
  grep -qF 'box new --name all' "$ROOT/drill/multiuser.sh"
check "multiuser: (p) waits for the lease it disturbed, so (g) measures rather than skips" 0 "" \
  grep -qF 'took its boxnet lease back' "$ROOT/drill/multiuser.sh"
check "multiuser: (p) measures the admin direction too" 0 "" \
  grep -qF "reached no restricted project" "$ROOT/drill/multiuser.sh"
# ...and measures it on something. Every other mint in that file belongs to a
# rehearsal user, so without a box of the admin's own root's 'all' enumerates
# zero and the "reached no restricted project" assertion above passes for a
# build with no run_fleet() at all — the absence of an action wearing a green
# tick. These two pin the mint and the positive half that needs it.
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "multiuser: (p) mints a box of the ADMIN's own, so that direction acts on something" 0 "" \
  grep -qF 'box new --name "$ADMINBOX"' "$ROOT/drill/multiuser.sh"
check "multiuser: (p) asserts the admin's 'all' stopped the admin's own box" 0 "" \
  grep -qF "stopped the admin's own box" "$ROOT/drill/multiuser.sh"
# #209 reached this exact call and then left Actions with no verdict for 30
# minutes, until the job ceiling cancelled every later criterion. The real
# daemon still decides pass/fail; this bound makes a wedged client a named
# failure and keeps the cleanup/reporting path reachable.
check "multiuser: (p) time-boxes the admin fleet stop below the job ceiling" 0 "" \
  grep -qF 'timeout -k 5 60 box down all' "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "multiuser: (p) captures the bounded stop without a descendant-held pipe" 0 "" \
  grep -qF 'box down all >"$capture" 2>&1' "$ROOT/drill/multiuser.sh"
check "multiuser: (p) records daemon operations when that stop wedges" 0 "" \
  grep -qF 'incus operation list --format csv' "$ROOT/drill/multiuser.sh"
check "multiuser: (p) records the daemon journal after a prompt stop failure" 0 "" \
  grep -qF "journalctl -u incus.service --since '-2 minutes'" "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # the $-string is a literal in the target file
check "multiuser: (p) force-stops only as post-failure recovery" 0 "" \
  grep -qF 'incus stop "$b" --force' "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # the backtick strings are literal target-file prose
check "multiuser: (p) explains why recovery deliberately stays on raw incus" 0 "" \
  grep -qF 'Recovery stays on raw incus, not `box down --force`, because it runs only after `box down all` exceeded its bound and must not depend on the verb whose failure it survives.' "$ROOT/drill/multiuser.sh"
check "multiuser: (p) prints the captured wedge evidence before exiting" 0 "" \
  grep -qF "printf '%s\\n' \"\$admin_down\"" "$ROOT/drill/multiuser.sh"
check "multiuser: (p) does not re-wedge in cleanup after that evidence" 0 "" \
  grep -qF 'KEEP=1' "$ROOT/drill/multiuser.sh"
# shellcheck disable=SC2016  # ditto
check "multiuser: (p) cleans that box up rather than leaving it for later phases" 0 "" \
  grep -qF 'box rm "$ADMINBOX" --force' "$ROOT/drill/multiuser.sh"
check "multiuser: (p) is documented in the criteria list" 0 "" \
  grep -qF 'p. the fleet word' "$ROOT/drill/multiuser.sh"

# --- the three help texts mention the fleet form ----------------------------
for v in start down restart; do
  check "box help $v mentions the 'all' form" 0 "all" "$BOX" help "$v"
  check "box help $v shows it in the synopsis" 0 "<box>|all" "$BOX" help "$v"
  # The mixed-state leniency belongs to the fleet form only — D1 asked for a
  # passthrough row and that is what 'box restart <box>' is. The paragraph
  # saying "'restart all' starts a stopped box" sits three lines above, so the
  # difference is named where it is read rather than left to be discovered.
  check "box help $v says the single-box restart is not that lenient" 0 "still errors on a box that" \
    "$BOX" help "$v"
done

# ---------------------------------------------------------------------------
# The two files that name the review panel name one panel (#198). The roster
# dropped a fourth account on 2026-08-19 in .github/labels.conf — the file the
# state machine reads — and CONTRIBUTING.md, the file a contributor reads to
# learn what a handoff owes, kept it. Nothing broke at runtime and nothing here
# noticed, because nothing here compared the two. That is what this block is:
# the correction alone buys one correct day.
#
# Driven through file arguments and not against the repo's own copies alone,
# because "they agree today" is exactly what the stale pair also looked like
# from one side. The fixtures below break the agreement in each direction and
# require a red, and two more require a red for an extraction that reads
# nothing — a comparison of two empty sets passes, and would pass for a
# renamed heading or a deleted panel= line.
# ---------------------------------------------------------------------------
PANELWORK="$(mktemp -d)"

# Both extractors emit one account per line, in file order. Order is preserved
# rather than sorted here so the same two functions serve the set comparison
# and the order check below.
conf_panel() {   # conf_panel <labels.conf>
  sed -n 's/^panel=//p' "$1" | tr ' ' '\n' | sed '/^$/d'
}
# The doc's roster is the bulleted list under '## Review panel', bounded at the
# next heading. Both bounds carry weight. The bullet form is what keeps prose
# out: 'dan-claude-bot' is backticked INSIDE this section and is explicitly not
# a member, so an extractor reading every backtick reads triage onto the panel.
# The heading bound is what keeps the rest of the file out.
doc_panel() {   # doc_panel <CONTRIBUTING.md>
  # shellcheck disable=SC2016  # the backticks are markdown in the file being read
  sed -n '/^## Review panel$/,/^## /p' "$1" \
    | sed -n 's/^- `\([A-Za-z0-9._-]*\)`$/\1/p'
}
# panel_rosters_agree [<labels.conf> [<CONTRIBUTING.md>]] — the repo's own by
# default. Names the symmetric difference in both directions, so the message
# says which file is missing whom rather than that a comparison failed.
panel_rosters_agree() {
  ( set -u
    conf="${1:-$ROOT/.github/labels.conf}"; doc="${2:-$ROOT/CONTRIBUTING.md}"
    in_conf="$(conf_panel "$conf" | sort -u)"
    in_doc="$(doc_panel "$doc" | sort -u)"
    [ -n "$in_conf" ] || { echo "no panel= names read out of $conf"; exit 1; }
    [ -n "$in_doc" ] || { echo "no panel bullets read out of $doc's ## Review panel"; exit 1; }
    only_doc="$(comm -13 <(printf '%s\n' "$in_conf") <(printf '%s\n' "$in_doc") | tr '\n' ' ')"
    only_conf="$(comm -23 <(printf '%s\n' "$in_conf") <(printf '%s\n' "$in_doc") | tr '\n' ' ')"
    if [ -n "${only_doc% }" ] || [ -n "${only_conf% }" ]; then
      echo "the two rosters disagree:"
      [ -n "${only_doc% }" ] && echo "  listed in $doc, absent from $conf: ${only_doc% }"
      [ -n "${only_conf% }" ] && echo "  listed in $conf, absent from $doc: ${only_conf% }"
      exit 1
    fi
    exit 0 )
}
check "panel: the two rosters name the same set of accounts" 0 "" panel_rosters_agree
# ...and in one order, which is the other half of what the doc promises a
# reader: a list matching as a set but shuffled still reads as a different
# panel to the person comparing it against a review request.
panel_rosters_share_an_order() {
  ( set -u
    conf="$(conf_panel "$ROOT/.github/labels.conf" | tr '\n' ' ')"
    doc="$(doc_panel "$ROOT/CONTRIBUTING.md" | tr '\n' ' ')"
    [ "$conf" = "$doc" ] \
      || { echo "labels.conf lists [${conf% }]; CONTRIBUTING.md lists [${doc% }]"; exit 1; } )
}
check "panel: ...in the same order labels.conf uses" 0 "" panel_rosters_share_an_order

# --- the extraction is bounded ---------------------------------------------
# The case most likely to be got wrong, asserted directly rather than left to
# be implied by the sets happening to match: dan-claude-bot is triage, is named
# in this very section, and is never a reviewer.
doc_panel_omits_triage() {
  ( set -u
    doc_panel "$ROOT/CONTRIBUTING.md" | grep -qx 'dan-claude-bot' \
      && { echo "dan-claude-bot was read as a panel member; it is prose in the section, not a bullet"; exit 1; }
    exit 0 )
}
check "panel: dan-claude-bot is in the section and is NOT read as a member" 0 "" \
  doc_panel_omits_triage
# The heading bound, proven the same way: a bullet of the same shape in a later
# section is not the panel, so adding one must not move the roster.
awk '{ print } END { print ""; print "## Later"; print ""; print "- `grok-bot-andresmgsl`" }' \
  "$ROOT/CONTRIBUTING.md" > "$PANELWORK/later.md"
check "panel: a same-shaped bullet in a LATER section is not read as a member" 0 "" \
  panel_rosters_agree "$ROOT/.github/labels.conf" "$PANELWORK/later.md"

# --- and it fails, in both directions --------------------------------------
# The fix reverted: CONTRIBUTING.md as it stood at 362ec8d, four names against
# labels.conf's three.
awk '{ print } /^- `codex-bot-andresmgsl`$/ { print "- `grok-bot-andresmgsl`" }' \
  "$ROOT/CONTRIBUTING.md" > "$PANELWORK/reverted.md"
check "panel: the fix reverted in CONTRIBUTING.md reds" 1 "grok-bot-andresmgsl" \
  panel_rosters_agree "$ROOT/.github/labels.conf" "$PANELWORK/reverted.md"
check "panel: ...saying which file the extra name is absent from" 1 "absent from $ROOT/.github/labels.conf" \
  panel_rosters_agree "$ROOT/.github/labels.conf" "$PANELWORK/reverted.md"
# The same break made on the other file. Worth naming what this does and does
# not prove: a name removed from labels.conf lands in the SAME direction as the
# revert above — the doc holds a name the conf does not — and only shows the
# comparison is not pinned to one hard-coded file. The genuine other direction
# is the case below it.
sed 's/ kimi-bot-andresmgsl//' "$ROOT/.github/labels.conf" > "$PANELWORK/short.conf"
check "panel: a name dropped from labels.conf reds too" 1 "kimi-bot-andresmgsl" \
  panel_rosters_agree "$PANELWORK/short.conf" "$ROOT/CONTRIBUTING.md"
# The other direction: labels.conf names somebody CONTRIBUTING.md does not, so
# a contributor reads a shorter panel than the one their PR will be handed to.
# Without this the guard could be one-way and still pass everything above.
# shellcheck disable=SC2016  # ditto — a markdown bullet, not a command substitution
grep -v '^- `kimi-bot-andresmgsl`$' "$ROOT/CONTRIBUTING.md" > "$PANELWORK/thin.md"
check "panel: a name missing from CONTRIBUTING.md reds — the other direction" 1 "kimi-bot-andresmgsl" \
  panel_rosters_agree "$ROOT/.github/labels.conf" "$PANELWORK/thin.md"
check "panel: ...saying which file that one is absent from" 1 "absent from $PANELWORK/thin.md" \
  panel_rosters_agree "$ROOT/.github/labels.conf" "$PANELWORK/thin.md"

# --- an extraction that reads nothing is a failure, not an agreement --------
# Two empty sets are equal. So the heading a reader could rename in good faith,
# and the line a labels edit could drop, each have to be a red of their own.
sed 's/^## Review panel$/## Who reviews/' "$ROOT/CONTRIBUTING.md" > "$PANELWORK/noheading.md"
check "panel: a renamed section is a red, not two empty sets agreeing" 1 "no panel bullets" \
  panel_rosters_agree "$ROOT/.github/labels.conf" "$PANELWORK/noheading.md"
grep -v '^panel=' "$ROOT/.github/labels.conf" > "$PANELWORK/nopanel.conf"
check "panel: a labels.conf with no panel= line is a red as well" 1 "no panel= names" \
  panel_rosters_agree "$PANELWORK/nopanel.conf" "$ROOT/CONTRIBUTING.md"
rm -rf "$PANELWORK"

# ---------------------------------------------------------------------------
# The scope labels are described in THREE files, and they describe one set of
# scopes (#275). .ceremony/LABELS.md names two of them — .github/labels.conf,
# the definitions the state machine writes to GitHub, and CONTRIBUTING.md, the
# list a contributor reads — and the path map the labeler job actually reads,
# .github/labeler.yml, is a third it does not name because it is machinery
# rather than definition. At 1fcd1b0 the three described three different sets.
#
# This is the block above's failure mode with one more file in it: two
# documents drifted apart because nothing compared them. So the guard is the
# same guard — extract, compare, name the symmetric difference in every
# direction, and make an extraction that reads nothing a red of its own rather
# than two empty sets agreeing.
#
# WHAT IT CATCHES, stated exactly, because the honest bound is part of the
# spec (#275 D2): the scope NAMES. A scope minted into one of the three files
# and forgotten in the other two reds here, which is the class a future scope
# mint hits. It does NOT compare a glob to a prose description — nothing can —
# so it would not have caught any of the three drifts that motivated it. Those
# were fixed by hand in this diff, and the pins further down are pins on three
# named strings, not a comparator.
# ---------------------------------------------------------------------------
SCOPEWORK="$(mktemp -d)"

# Three extractors, one per file, each emitting one scope name per line in
# file order. Each is anchored to the shape its own file uses, so that a
# reader of the OTHER shape — a `scope:` mentioned in labeler.yml's header
# comment, a backticked scope name in CONTRIBUTING's prose — is not read as a
# member. That is the same bound doc_panel above carries for dan-claude-bot.
yml_scopes() {   # yml_scopes <labeler.yml>
  sed -n 's/^"\(scope:[A-Za-z0-9-]*\)":$/\1/p' "$1"
}
conf_scopes() {  # conf_scopes <labels.conf>
  sed -n 's/^\(scope:[A-Za-z0-9-]*\)|.*$/\1/p' "$1"
}
# Bounded at the next heading like doc_panel, and for the same reason: a
# same-shaped bullet in a later section is not the scope list.
doc_scopes() {   # doc_scopes <CONTRIBUTING.md>
  # shellcheck disable=SC2016  # the backticks are markdown in the file being read
  sed -n '/^## Scope labels$/,/^## /p' "$1" \
    | sed -n 's/^- `\(scope:[A-Za-z0-9-]*\)` —.*$/\1/p'
}

# scope_name_sets_agree [<labeler.yml> [<labels.conf> [<CONTRIBUTING.md>]]] —
# the repo's own by default. Three sets means six ordered directions, and all
# six are reported: with two files "they disagree" leaves only one question,
# with three it leaves three, so the message has to say which file is missing
# which name from which.
scope_name_sets_agree() {
  ( set -u
    yml="${1:-$ROOT/.github/labeler.yml}"
    conf="${2:-$ROOT/.github/labels.conf}"
    doc="${3:-$ROOT/CONTRIBUTING.md}"
    in_yml="$(yml_scopes "$yml" | sort -u)"
    in_conf="$(conf_scopes "$conf" | sort -u)"
    in_doc="$(doc_scopes "$doc" | sort -u)"
    [ -n "$in_yml" ]  || { echo "no scope keys read out of $yml"; exit 1; }
    [ -n "$in_conf" ] || { echo "no scope rows read out of $conf"; exit 1; }
    [ -n "$in_doc" ]  || { echo "no scope bullets read out of $doc's ## Scope labels"; exit 1; }
    bad=0
    # Every ordered pair of the three, which is the six directions. `$yml`,
    # `$conf` and `$doc` hold the file names and `$in_*` the sets, so one
    # indirection over the same three keys reaches both.
    for a in yml conf doc; do
      for b in yml conf doc; do
        [ "$a" = "$b" ] && continue
        a_set="in_$a"; b_set="in_$b"
        only_a="$(comm -23 <(printf '%s\n' "${!a_set}") <(printf '%s\n' "${!b_set}") | tr '\n' ' ')"
        if [ -n "${only_a% }" ]; then
          [ "$bad" -eq 0 ] && echo "the three scope maps disagree:"
          echo "  listed in ${!a}, absent from ${!b}: ${only_a% }"
          bad=1
        fi
      done
    done
    exit "$bad" )
}
check "scope: the three files name the same set of scopes" 0 "" scope_name_sets_agree
# Six in, six out (#275 D3). Asserted as a count rather than left implied by
# the agreement above, which a diff retiring one scope from all three files
# would pass.
scope_counts() {   # scope_counts — "<yml> <conf> <doc>" scope counts
  ( set -u
    n() { sort -u | grep -c . ; }
    printf '%s %s %s\n' \
      "$(yml_scopes  "$ROOT/.github/labeler.yml" | n)" \
      "$(conf_scopes "$ROOT/.github/labels.conf" | n)" \
      "$(doc_scopes  "$ROOT/CONTRIBUTING.md"     | n)" )
}
check "scope: there are six of them, in every file" 0 "6 6 6" scope_counts

# --- the extraction is bounded ---------------------------------------------
# CONTRIBUTING's heading bound, proven as the panel block proves its own: a
# bullet of the scope shape in a later section is not a scope.
awk '{ print } END { print ""; print "## Later"; print ""; print "- `scope:zzz` — not a scope" }' \
  "$ROOT/CONTRIBUTING.md" > "$SCOPEWORK/later.md"
check "scope: a same-shaped bullet in a LATER section is not read as a scope" 0 "" \
  scope_name_sets_agree "$ROOT/.github/labeler.yml" "$ROOT/.github/labels.conf" "$SCOPEWORK/later.md"
# labeler.yml's own header comment says the word `scope:*`; the key anchor is
# what keeps it out. Asserted directly rather than left to the sets happening
# to match, exactly as doc_panel_omits_triage is.
yml_scopes_omit_the_header() {
  ( set -u
    yml_scopes "$ROOT/.github/labeler.yml" | grep '[*]' \
      && { echo "labeler.yml's header prose was read as a scope name"; exit 1; }
    exit 0 )
}
check "scope: labeler.yml's header comment is not read as a scope" 0 "" \
  yml_scopes_omit_the_header

# --- and it fails, in all six directions ------------------------------------
# One extra scope in one file is absent from the other two, so each fixture
# below carries two of the six directions and the three carry all six. Each is
# asserted by its exact message, so a guard that reported only "they disagree"
# would pass none of them.
awk '{ print } END { print "\"scope:zzz\":"; print "  - changed-files:"; print "      - any-glob-to-any-file: [\"zzz/**\"]" }' \
  "$ROOT/.github/labeler.yml" > "$SCOPEWORK/extra.yml"
check "scope: a scope in labeler.yml alone reds — absent from labels.conf" 1 \
  "listed in $SCOPEWORK/extra.yml, absent from $ROOT/.github/labels.conf: scope:zzz" \
  scope_name_sets_agree "$SCOPEWORK/extra.yml" "$ROOT/.github/labels.conf" "$ROOT/CONTRIBUTING.md"
check "scope: ...and absent from CONTRIBUTING.md — the second direction" 1 \
  "listed in $SCOPEWORK/extra.yml, absent from $ROOT/CONTRIBUTING.md: scope:zzz" \
  scope_name_sets_agree "$SCOPEWORK/extra.yml" "$ROOT/.github/labels.conf" "$ROOT/CONTRIBUTING.md"
awk '{ print } END { print "scope:zzz|C5DEF5|not a scope" }' \
  "$ROOT/.github/labels.conf" > "$SCOPEWORK/extra.conf"
check "scope: a scope in labels.conf alone reds — absent from labeler.yml" 1 \
  "listed in $SCOPEWORK/extra.conf, absent from $ROOT/.github/labeler.yml: scope:zzz" \
  scope_name_sets_agree "$ROOT/.github/labeler.yml" "$SCOPEWORK/extra.conf" "$ROOT/CONTRIBUTING.md"
check "scope: ...and absent from CONTRIBUTING.md — the fourth direction" 1 \
  "listed in $SCOPEWORK/extra.conf, absent from $ROOT/CONTRIBUTING.md: scope:zzz" \
  scope_name_sets_agree "$ROOT/.github/labeler.yml" "$SCOPEWORK/extra.conf" "$ROOT/CONTRIBUTING.md"
# The bullet goes INSIDE the section this time, which is what makes it a
# disagreement rather than the bounded-extraction case above.
awk '{ print } /^- `scope:drill`/ { print "- `scope:zzz` — not a scope" }' \
  "$ROOT/CONTRIBUTING.md" > "$SCOPEWORK/extra.md"
check "scope: a scope in CONTRIBUTING.md alone reds — absent from labeler.yml" 1 \
  "listed in $SCOPEWORK/extra.md, absent from $ROOT/.github/labeler.yml: scope:zzz" \
  scope_name_sets_agree "$ROOT/.github/labeler.yml" "$ROOT/.github/labels.conf" "$SCOPEWORK/extra.md"
check "scope: ...and absent from labels.conf — the sixth direction" 1 \
  "listed in $SCOPEWORK/extra.md, absent from $ROOT/.github/labels.conf: scope:zzz" \
  scope_name_sets_agree "$ROOT/.github/labeler.yml" "$ROOT/.github/labels.conf" "$SCOPEWORK/extra.md"
# A scope DELETED from one file lands in directions the three fixtures above
# already cover — the other two files hold a name this one does not. It is
# here because it is the shape a real edit takes (a scope retired from
# labels.conf and left in the map), and because it proves the comparison is
# not pinned to the repo's own copies in any of the three positions.
grep -v '^scope:host|' "$ROOT/.github/labels.conf" > "$SCOPEWORK/short.conf"
check "scope: a scope dropped from labels.conf reds too" 1 "scope:host" \
  scope_name_sets_agree "$ROOT/.github/labeler.yml" "$SCOPEWORK/short.conf" "$ROOT/CONTRIBUTING.md"

# --- an extraction that reads nothing is a failure, not an agreement --------
# Three empty sets are equal, so each file's "read nothing" is its own red:
# a renamed heading, a labels edit that drops the rows, a map rewritten in a
# shape the anchor does not match.
sed 's/^## Scope labels$/## Areas/' "$ROOT/CONTRIBUTING.md" > "$SCOPEWORK/noheading.md"
check "scope: a renamed section is a red, not three empty sets agreeing" 1 "no scope bullets" \
  scope_name_sets_agree "$ROOT/.github/labeler.yml" "$ROOT/.github/labels.conf" "$SCOPEWORK/noheading.md"
grep -v '^scope:' "$ROOT/.github/labels.conf" > "$SCOPEWORK/noscopes.conf"
check "scope: a labels.conf with no scope rows is a red as well" 1 "no scope rows" \
  scope_name_sets_agree "$ROOT/.github/labeler.yml" "$SCOPEWORK/noscopes.conf" "$ROOT/CONTRIBUTING.md"
sed 's/^"scope:/"area:/' "$ROOT/.github/labeler.yml" > "$SCOPEWORK/renamed.yml"
check "scope: a labeler.yml naming no scope keys is a red as well" 1 "no scope keys" \
  scope_name_sets_agree "$SCOPEWORK/renamed.yml" "$ROOT/.github/labels.conf" "$ROOT/CONTRIBUTING.md"

# ---------------------------------------------------------------------------
# What the name-set guard above cannot see: which PATHS a scope attaches to.
# That is where all three of #275's drifts lived, and it is not a comparison
# any check can make — a glob and an English sentence are not comparable. What
# IS checkable is the glob half on its own: given labeler.yml, which scopes
# does a one-path diff land? So the three cases the issue names are asserted
# as derivations rather than asserted in prose.
#
# scope_of reimplements one narrow slice of actions/labeler, which is only
# honest if the slice is pinned. Two pins do that: every matcher key in the
# file is `any-glob-to-any-file` (the ANY semantics this assumes), and every
# glob is either an exact path or a `<dir>/**` prefix (the only two forms this
# matches). A file that grows a third shape reds on those pins instead of
# being silently mismatched here.
# ---------------------------------------------------------------------------
labeler_matchers_are_any_to_any() {   # [<labeler.yml>]
  ( set -u
    other="$(grep -E '^[[:space:]]*-[[:space:]]*[a-z-]+-glob-to-[a-z-]+:' \
               "${1:-$ROOT/.github/labeler.yml}" | grep -v 'any-glob-to-any-file:')"
    [ -z "$other" ] \
      || { echo "a matcher other than any-glob-to-any-file:"; printf '%s\n' "$other"; exit 1; }
    exit 0 )
}
check "scope: every matcher in labeler.yml is any-glob-to-any-file" 0 "" \
  labeler_matchers_are_any_to_any

# labeler_globs <labeler.yml> — "<scope> <glob>" per line. The scope key is the
# only quoted string on its own line; every glob lives on a line carrying the
# list's `[`, in either of the two layouts the file uses (inline, or wrapped
# onto the next line).
labeler_globs() {
  awk '
    /^"scope:[A-Za-z0-9-]*":$/ { scope = $0; gsub(/^"|":$/, "", scope); next }
    /\[/ {
      line = $0
      while (match(line, /"[^"]+"/)) {
        printf "%s %s\n", scope, substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$1"
}
glob_matches() {   # glob_matches <glob> <path>
  case "$1" in
    */'**')  case "$2" in "${1%/**}"/*) return 0 ;; esac; return 1 ;;
    *)       [ "$1" = "$2" ] ;;
  esac
}
labeler_globs_are_a_shape_this_matches() {   # [<labeler.yml>]
  ( set -u
    bad=0
    while read -r _scope glob; do
      case "$glob" in
        */'**')                     ;;   # a directory prefix
        *'*'*|*'?'*|*'['*|*'{'*)
          echo "glob '$glob' is neither an exact path nor a <dir>/** prefix"; bad=1 ;;
        *)                          ;;   # an exact path
      esac
    done <<EOF
$(labeler_globs "${1:-$ROOT/.github/labeler.yml}")
EOF
    exit "$bad" )
}
check "scope: every glob is an exact path or a <dir>/** prefix" 0 "" \
  labeler_globs_are_a_shape_this_matches
sed 's#"drill/\*\*"#"drill/*.sh"#' "$ROOT/.github/labeler.yml" > "$SCOPEWORK/oddglob.yml"
check "scope: ...and a glob outside that subset reds rather than being mismatched" 1 \
  "neither an exact path nor a <dir>/** prefix" \
  labeler_globs_are_a_shape_this_matches "$SCOPEWORK/oddglob.yml"

scope_of() {   # scope_of <path> [<labeler.yml>]
  ( set -u
    path="$1"
    while read -r scope glob; do
      glob_matches "$glob" "$path" && echo "$scope"
    done <<EOF
$(labeler_globs "${2:-$ROOT/.github/labeler.yml}")
EOF
  ) | sort -u
}
scope_of_is() {   # scope_of_is <labeler.yml> <path> [<expected scope>...]
  ( set -u
    yml="$1"; path="$2"; shift 2
    want=""
    if [ "$#" -gt 0 ]; then want="$(printf '%s\n' "$@" | sort -u | tr '\n' ' ')"; fi
    got="$(scope_of "$path" "$yml" | tr '\n' ' ')"
    [ "${got% }" = "${want% }" ] \
      || { echo "a $path-only diff lands [${got% }]; expected [${want% }]"; exit 1; }
    exit 0 )
}
LABELER="$ROOT/.github/labeler.yml"
# The three cases #275 names, each a one-path diff landing the scope its
# definitions name. drills/0.11.0.md is the one worth showing rather than
# asserting: it is the shape every release window produces (#253) and it
# landed NO scope at all before this change.
check "scope: a drills/*.md-only diff lands scope:drill" 0 "" \
  scope_of_is "$LABELER" drills/0.11.0.md scope:drill
check "scope: a test/cli.sh-only diff lands scope:cli" 0 "" \
  scope_of_is "$LABELER" test/cli.sh scope:cli
check "scope: a profiles/*-only diff lands scope:templates" 0 "" \
  scope_of_is "$LABELER" profiles/box-profile.yaml scope:templates
# ...and the change narrows nothing (#275 D1's rule and its test plan's
# must-pass): every attachment that stood before this diff still stands.
check "scope: bin/box still lands scope:cli" 0 "" \
  scope_of_is "$LABELER" bin/box scope:cli
check "scope: drill/ — the rehearsal machinery — still lands scope:drill" 0 "" \
  scope_of_is "$LABELER" drill/doctor.sh scope:drill
check "scope: templates/ still lands scope:templates" 0 "" \
  scope_of_is "$LABELER" templates/box-init.sh scope:templates
check "scope: install.sh still lands scope:installer" 0 "" \
  scope_of_is "$LABELER" install.sh scope:installer
check "scope: host/ still lands scope:host" 0 "" \
  scope_of_is "$LABELER" host/setup-host.sh scope:host
# Two scopes on one path is not a collision to fix: drill/multiuser.sh is
# globbed by both and always has been. Pinned so that a later narrowing of
# either glob has to argue with a check.
check "scope: host/grant-user.sh lands scope:tiers and scope:host" 0 "" \
  scope_of_is "$LABELER" host/grant-user.sh scope:host scope:tiers
check "scope: drill/multiuser.sh lands scope:tiers and scope:drill" 0 "" \
  scope_of_is "$LABELER" drill/multiuser.sh scope:drill scope:tiers
# A path no scope claims lands nothing, which is what makes the two reds below
# mean what they say rather than being satisfied by a matcher that matches
# everything.
check "scope: an unclaimed path lands no scope" 0 "" \
  scope_of_is "$LABELER" README.md

# --- and the two globs this diff moved are reds if they are reverted --------
sed 's#\["drill/\*\*", "drills/\*\*"\]#["drill/**"]#' "$LABELER" > "$SCOPEWORK/nodrills.yml"
check "scope: labeler.yml without drills/** leaves a drill record unlabelled" 1 \
  "lands []" scope_of_is "$SCOPEWORK/nodrills.yml" drills/0.11.0.md scope:drill
sed 's#\["bin/\*\*", "test/cli.sh"\]#["bin/**"]#' "$LABELER" > "$SCOPEWORK/nocli.yml"
check "scope: labeler.yml without test/cli.sh leaves a harness diff unlabelled" 1 \
  "lands []" scope_of_is "$SCOPEWORK/nocli.yml" test/cli.sh scope:cli

# ---------------------------------------------------------------------------
# The definitions' half of the same three cases. These are PINS ON THREE NAMED
# STRINGS and nothing more: they red if this diff's descriptions are reverted
# to the ones that disagreed with the map, and they say nothing at all about
# any scope row that moves next. The general comparison is the one D2 rules
# out — a glob against an English sentence — so what is written here is the
# repo's grep-the-load-bearing-line idiom, at the three lines this issue moved.
# ---------------------------------------------------------------------------
conf_desc() {   # conf_desc <labels.conf> <scope>
  awk -F'|' -v s="$2" '$1 == s { print $3 }' "$1"
}
doc_desc() {    # doc_desc <CONTRIBUTING.md> <scope>
  sed -n '/^## Scope labels$/,/^## /p' "$1" \
    | sed -n "s/^- \`$2\` — //p"
}
scope_definitions_name_their_surfaces() {   # [<labels.conf> [<CONTRIBUTING.md>]]
  ( set -u
    conf="${1:-$ROOT/.github/labels.conf}"; doc="${2:-$ROOT/CONTRIBUTING.md}"
    bad=0
    while IFS='|' read -r scope where needle; do
      [ -n "$scope" ] || continue
      case "$where" in
        conf) file="$conf"; have="$(conf_desc "$conf" "$scope")" ;;
        *)    file="$doc";  have="$(doc_desc "$doc" "$scope")"   ;;
      esac
      case "$have" in
        *"$needle"*) ;;
        *) echo "$file's $scope description does not name '$needle': [$have]"; bad=1 ;;
      esac
    done <<'ROWS'
scope:cli|conf|test/cli.sh
scope:cli|doc|test/cli.sh
scope:drill|conf|drills/
scope:drill|doc|drills/
scope:templates|conf|profiles/
scope:templates|doc|profile
ROWS
    exit "$bad" )
}
check "scope: both definitions of the three moved scopes name their surfaces" 0 "" \
  scope_definitions_name_their_surfaces
# Reverted in each file, one case per direction the issue's table named.
sed 's#^scope:cli|C5DEF5|.*$#scope:cli|C5DEF5|bin/box — the command surface#' \
  "$ROOT/.github/labels.conf" > "$SCOPEWORK/oldcli.conf"
check "scope: labels.conf saying scope:cli is bin/box alone reds" 1 "does not name 'test/cli.sh'" \
  scope_definitions_name_their_surfaces "$SCOPEWORK/oldcli.conf" "$ROOT/CONTRIBUTING.md"
# shellcheck disable=SC2016  # ditto — a markdown bullet, not a command substitution
sed 's#^- `scope:cli` — .*$#- `scope:cli` — `bin/box`, the command surface#' \
  "$ROOT/CONTRIBUTING.md" > "$SCOPEWORK/oldcli.md"
check "scope: ...and CONTRIBUTING.md saying it reds too — the other file" 1 "does not name 'test/cli.sh'" \
  scope_definitions_name_their_surfaces "$ROOT/.github/labels.conf" "$SCOPEWORK/oldcli.md"
sed 's#^scope:drill|C5DEF5|.*$#scope:drill|C5DEF5|drill/ — rehearsals, doctor, RUNS.md#' \
  "$ROOT/.github/labels.conf" > "$SCOPEWORK/olddrill.conf"
check "scope: labels.conf saying scope:drill is drill/ alone reds" 1 "does not name 'drills/'" \
  scope_definitions_name_their_surfaces "$SCOPEWORK/olddrill.conf" "$ROOT/CONTRIBUTING.md"
# shellcheck disable=SC2016  # ditto
sed 's#^- `scope:drill` — .*$#- `scope:drill` — rehearsals, doctor, and run evidence#' \
  "$ROOT/CONTRIBUTING.md" > "$SCOPEWORK/olddrill.md"
check "scope: ...and CONTRIBUTING.md leaving the two directories unnamed reds" 1 "does not name 'drills/'" \
  scope_definitions_name_their_surfaces "$ROOT/.github/labels.conf" "$SCOPEWORK/olddrill.md"
sed 's#^scope:templates|C5DEF5|.*$#scope:templates|C5DEF5|templates/ — the box seeds#' \
  "$ROOT/.github/labels.conf" > "$SCOPEWORK/oldtpl.conf"
check "scope: labels.conf omitting profiles/ from scope:templates reds" 1 "does not name 'profiles/'" \
  scope_definitions_name_their_surfaces "$SCOPEWORK/oldtpl.conf" "$ROOT/CONTRIBUTING.md"
# Every scope description still fits GitHub's 100-character cap, which is not
# decoration: the labels bootstrap aborted on the `operator` row at 106 on
# 2026-08-29, and this diff lengthens three of these six.
scope_descriptions_fit_githubs_cap() {   # [<labels.conf>]
  awk -F'|' '
    /^scope:/ && length($3) > 100 { printf "%s: %d chars\n", $1, length($3); bad = 1 }
    END { exit bad ? 1 : 0 }' "${1:-$ROOT/.github/labels.conf}"
}
check "scope: every description fits GitHub's 100-char cap" 0 "" \
  scope_descriptions_fit_githubs_cap
rm -rf "$SCOPEWORK"

# ---------------------------------------------------------------------------
# One pin, everywhere this repository writes it (#219). ceremony's docs-sync
# reads the ref from the single `uses:` line in release.yml and verifies
# `.ceremony/` against that one line. Nothing reads the other eleven callers,
# the prose comment beside sha-pinned, or the two documents that state the pin
# in words — and sha-pinned is not the backstop it looks like, because
# references owned by this repository's own owner are exempt from it by design
# (that exemption is written out at ci.yml's comment). So a bump that moves
# eleven callers of twelve is green on every check this repo runs, and the
# twelfth goes on invoking an older guard until somebody reads the file.
#
# Driven through a root argument rather than against this tree alone, because
# "they all agree today" is exactly what a mixed pin also looks like from the
# side that moved. The fixtures below break the agreement at each KIND of site
# and require a red, and three more require a red for an extraction that reads
# nothing — a comparison over an empty set of sites passes trivially, and would
# pass just as well for a renamed workflow directory or a deleted sentence.
#
# `changelog.d/` is deliberately not a site. A fragment is the published prose
# for what its own issue did: changelog.d/168.md says governance moved to a
# ceremony pinned at 0.7.4, and under #168 it did. Rewriting it to match the
# current pin would make it misreport the issue it is named for.
# ---------------------------------------------------------------------------
PINWORK="$(mktemp -d)"

# The pin itself, read exactly as docs-sync reads it: a real `uses:` key on the
# release caller. A commented-out one does not count, which is why the shape is
# anchored rather than grepped loose.
ceremony_pin() {   # ceremony_pin <release.yml>
  grep -E '^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*heavy-duty/ceremony/\.github/workflows/release\.yml@' "$1" \
    | sed -E 's/^.*@//; s/[[:space:]#].*$//'
}

# The pin is written three ways, so there are three extractors, each emitting
# "file:line ref". Splitting them is what lets each one's empty result be its
# own red below: one combined extractor that reads two shapes and misses the
# third still returns a non-empty set.
#
#   1. `@<ref>` — every `uses:` line, and the comment beside sha-pinned that
#      names the pin in prose to explain the owner exemption.
sites_at_ref() {   # sites_at_ref <file>...
  grep -nHoE 'heavy-duty/ceremony[A-Za-z0-9./_-]*@[A-Za-z0-9._-]+' "$@" \
    | sed -E 's/^(.*):([0-9]+):.*@([A-Za-z0-9._-]+)$/\1:\2 \3/'
}
#   2. a /blob/ or /tree/ URL into the pinned tree — CONTRIBUTING.md's link to
#      ceremony's README, drills/README.md's link to the drill-recorded action.
#      These are the sites that keep resolving after a bump and quietly show a
#      reader the old file, which is worse than a broken link.
sites_url_ref() {   # sites_url_ref <file>...
  grep -nHoE 'heavy-duty/ceremony/(blob|tree)/[A-Za-z0-9._-]+/' "$@" \
    | sed -E 's#^(.*):([0-9]+):.*/(blob|tree)/([A-Za-z0-9._-]+)/$#\1:\2 \4#'
}
#   3. the sentence in CONTRIBUTING.md that states the pin in words. Matched on
#      its own wording, so rephrasing the sentence reds as a site that reads
#      nothing rather than silently leaving the number unchecked.
sites_prose_ref() {   # sites_prose_ref <file>...
  # shellcheck disable=SC2016  # the backticks are markdown in the file being read
  grep -nHoE 'pins the shared machinery and doctrine at `[A-Za-z0-9._-]+`' "$@" \
    | sed -E 's/^(.*):([0-9]+):.*`([A-Za-z0-9._-]+)`$/\1:\2 \3/'
}

# ceremony_pin_is_one_pin [<root>] [<expected uses: count>] — this tree by
# default. Names every site that disagrees with its file and line, so the
# message says where the stale pin is rather than that a comparison failed.
#
# The count is asserted and not inferred. Twelve is this repository's callers
# as of #219; a thirteenth is a deliberate edit to this number, and that is the
# point — without it, an added caller could ship at any ref at all as long as
# the twelve already here agreed with each other.
ceremony_pin_is_one_pin() {
  ( set -u
    root="${1:-$ROOT}"; want_uses="${2:-12}"
    rel="$root/.github/workflows/release.yml"
    [ -f "$rel" ] || { echo "no $rel — the one pin lives there"; exit 1; }
    pins="$(ceremony_pin "$rel")"
    n_pins="$(printf '%s\n' "$pins" | awk 'NF { n++ } END { print n + 0 }')"
    [ "$n_pins" -eq 1 ] || {
      echo "expected exactly one ceremony pin line in $rel, read $n_pins —"
      echo "  docs-sync never guesses a ref and neither does this check"
      exit 1
    }
    pin="$pins"

    files=()
    for f in "$root"/.github/workflows/*.yml "$root/CONTRIBUTING.md" "$root/drills/README.md"; do
      [ -f "$f" ] && files+=("$f")
    done
    [ "${#files[@]}" -gt 0 ] || { echo "no pin-carrying files found under $root"; exit 1; }

    at="$(sites_at_ref "${files[@]}")"
    url="$(sites_url_ref "${files[@]}")"
    prose="$(sites_prose_ref "${files[@]}")"
    [ -n "$at" ]    || { echo "no 'heavy-duty/ceremony...@<ref>' sites read under $root"; exit 1; }
    [ -n "$url" ]   || { echo "no ceremony /blob/ or /tree/ URL sites read under $root"; exit 1; }
    [ -n "$prose" ] || { echo "no prose pin sentence read under $root's CONTRIBUTING.md"; exit 1; }

    uses="$(grep -hE '^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*heavy-duty/ceremony' \
      "${files[@]}" | awk 'END { print NR + 0 }')"
    [ "$uses" -eq "$want_uses" ] || {
      echo "expected $want_uses ceremony 'uses:' references under $root, found $uses —"
      echo "  a caller added or removed is a deliberate edit to that number"
      exit 1
    }

    stale="$(printf '%s\n%s\n%s\n' "$at" "$url" "$prose" \
      | awk -v p="$pin" 'NF && $2 != p { print "  " $1 " reads " $2 }')"
    [ -z "$stale" ] || {
      echo "the ceremony pin is mixed: $rel pins $pin, and"
      printf '%s\n' "$stale"
      exit 1
    }
    exit 0 )
}
check "pin: every ceremony reference in the tree reads the one pin" 0 "" ceremony_pin_is_one_pin
# The count, asserted from the other side too: the check is not passing because
# it read nothing and compared nothing.
check "pin: ...and there are twelve of them, counted not assumed" 1 "found 12" \
  ceremony_pin_is_one_pin "$ROOT" 11

# --- and it fails, at every kind of site ------------------------------------
# A tree of copies, broken one way at a time. Each fixture is one reference
# left behind at the previous pin — the exact shape of the bump that moves
# eleven of twelve.
mkpintree() {   # mkpintree <name> — a copy of every pin-carrying file
  local d="$PINWORK/$1"
  mkdir -p "$d/.github/workflows" "$d/drills"
  cp "$ROOT"/.github/workflows/*.yml "$d/.github/workflows/"
  cp "$ROOT/CONTRIBUTING.md" "$d/"
  cp "$ROOT/drills/README.md" "$d/drills/"
  printf '%s\n' "$d"
}

previous_pin=0.7.6

# only_line <file> <fixed-string> — the single line number it sits on, for the
# two checks below that assert the message names a file AND a line. The number
# is READ off the fixture and never written here: which line ci.yml puts a
# reference on is a coordinate, and a coordinate written into a check is a
# measurement that the next correct edit above it invalidates. These two read
# `157` and `150` until #224 added the guard block's comment and moved both,
# breaking a check whose subject that edit did not touch. A non-unique match
# reds rather than silently weakening the assertion to a bare `ci.yml:`.
only_line() {
  local hits n
  hits="$(grep -nF -e "$2" "$1" | cut -d: -f1)"
  n="$(printf '%s\n' "$hits" | grep -c .)"
  if [ "$n" -ne 1 ]; then
    echo "fixture: '$2' is on $n lines of $1, wanted exactly 1" >&2
    printf 'NO-UNIQUE-LINE'
    return 1
  fi
  printf '%s' "$hits"
}

MIXED="$(mkpintree mixed)"
sed -i "s|actions/sha-pinned@0\\.7\\.7|actions/sha-pinned@$previous_pin|" "$MIXED/.github/workflows/ci.yml"
check "pin: one caller left at the old ref reds" 1 "reads $previous_pin" ceremony_pin_is_one_pin "$MIXED"
check "pin: ...naming the file and line it is on" 1 \
  "ci.yml:$(only_line "$MIXED/.github/workflows/ci.yml" "actions/sha-pinned@$previous_pin")" \
  ceremony_pin_is_one_pin "$MIXED"

# The comment beside sha-pinned. It is the one site that names the pin in prose
# inside a workflow, and no guard reads a comment — so if this fixture passed,
# the file explaining the owner exemption would go on citing the ref the
# exemption no longer applies to.
STALECOMMENT="$(mkpintree stalecomment)"
sed -i "s|# heavy-duty/ceremony@0\\.7\\.7|# heavy-duty/ceremony@$previous_pin|" "$STALECOMMENT/.github/workflows/ci.yml"
check "pin: the prose comment left behind reds" 1 \
  "ci.yml:$(only_line "$STALECOMMENT/.github/workflows/ci.yml" "# heavy-duty/ceremony@$previous_pin")" \
  ceremony_pin_is_one_pin "$STALECOMMENT"

# The sentence a contributor reads to learn what this repo is governed by.
STALEDOC="$(mkpintree staledoc)"
# shellcheck disable=SC2016  # the backticks are markdown in the file being edited
sed -i 's|doctrine at `0\.7\.7`|doctrine at `0.7.6`|' "$STALEDOC/CONTRIBUTING.md"
check "pin: CONTRIBUTING.md's stated pin left behind reds" 1 "CONTRIBUTING.md" \
  ceremony_pin_is_one_pin "$STALEDOC"

# A URL into the old tree still resolves, so this is the failure with no
# symptom at all: the link works and shows the reader the wrong file.
STALELINK="$(mkpintree stalelink)"
sed -i 's|ceremony/tree/0\.7\.7/actions|ceremony/tree/0.7.6/actions|' "$STALELINK/drills/README.md"
check "pin: a /tree/ link into the old ref reds" 1 "drills/README.md" \
  ceremony_pin_is_one_pin "$STALELINK"
STALEBLOB="$(mkpintree staleblob)"
sed -i 's|ceremony/blob/0\.7\.7/README|ceremony/blob/0.7.6/README|' "$STALEBLOB/CONTRIBUTING.md"
check "pin: a /blob/ link into the old ref reds — the other URL shape" 1 "reads 0.7.6" \
  ceremony_pin_is_one_pin "$STALEBLOB"

# A thirteenth caller, at the right ref. Every site agrees, so only the count
# catches it — which is what the count is for.
THIRTEEN="$(mkpintree thirteen)"
sed -i 's|\(^ *\)uses: heavy-duty/ceremony/actions/sha-pinned@0\.7\.7|&\n\1uses: heavy-duty/ceremony/actions/nonesuch@0.7.7|' \
  "$THIRTEEN/.github/workflows/ci.yml"
check "pin: a thirteenth caller at the right ref still reds" 1 "found 13" \
  ceremony_pin_is_one_pin "$THIRTEEN"

# --- an extraction that reads nothing is a failure, not an agreement --------
# Three shapes, three ways to read nothing. Each has to be its own red, or the
# guard quietly narrows to the sites that happen to survive an edit.
NOPIN="$(mkpintree nopin)"
sed -i 's|^\( *\)uses: heavy-duty/ceremony/\.github/workflows/release\.yml@|\1# uses: heavy-duty/ceremony/.github/workflows/release.yml@|' \
  "$NOPIN/.github/workflows/release.yml"
check "pin: a commented-out release pin is a red, not a ref" 1 "exactly one ceremony pin line" \
  ceremony_pin_is_one_pin "$NOPIN"

NOPROSE="$(mkpintree noprose)"
sed -i 's|^Box pins the shared machinery and doctrine at .*|Box follows the shared machinery and doctrine.|' \
  "$NOPROSE/CONTRIBUTING.md"
check "pin: a rephrased CONTRIBUTING.md sentence is a red, not a pass" 1 "no prose pin sentence" \
  ceremony_pin_is_one_pin "$NOPROSE"

NOURL="$(mkpintree nourl)"
sed -i 's|https://github.com/heavy-duty/ceremony/blob/[A-Za-z0-9._-]*/README.md|https://github.com/heavy-duty/ceremony|' \
  "$NOURL/CONTRIBUTING.md"
sed -i 's|https://github.com/heavy-duty/ceremony/tree/[A-Za-z0-9._-]*/actions/drill-recorded|https://github.com/heavy-duty/ceremony|' \
  "$NOURL/drills/README.md"
check "pin: no versioned URL left anywhere is a red as well" 1 "no ceremony /blob/ or /tree/ URL sites" \
  ceremony_pin_is_one_pin "$NOURL"
rm -rf "$PINWORK"

echo "---"
echo "$PASS passed, $FAIL failed"
rm -rf "$SHIMDIR" "$WORK"
[ "$FAIL" -eq 0 ]
