#!/usr/bin/env bash
# One-time host setup: install Incus, create the isolated network + ACL and
# the box-profile profile. Idempotent. Ubuntu 24.04 / Debian 13.
set -euo pipefail

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
here="$(dirname "$(dirname "$self")")"

# Byte-identical copy of bin/box's box_tier() — this script must know the
# tier before any install tree exists, and test/cli.sh diffs the two copies
# so they cannot drift.
box_tier() {
  [ "$(id -u)" -eq 0 ] && { printf 'admin\n'; return; }
  local groups; groups="$(id -nG 2>/dev/null | tr ' ' '\n')"
  if   printf '%s\n' "$groups" | grep -qx incus-admin; then printf 'admin\n'
  elif printf '%s\n' "$groups" | grep -qx incus;       then printf 'restricted\n'
  else printf 'none\n'
  fi
}

# A restricted (incus-group) user cannot build daemon-global state, and
# telling them to escalate would be wrong twice: the stack is the admin's to
# own, and if 'box new' works for them it already exists. Say so and succeed —
# this must sit BEFORE the sudo resolution below, which would otherwise bury
# the honest answer under a privilege error. Gated on the tier, not on
# 'command -v sudo': having the sudo binary is not the same as holding a grant.
if [ "$(id -u)" -ne 0 ] && [ "$(box_tier)" = restricted ]; then
  echo "You are in the 'incus' group (restricted tier): you manage your own boxes," >&2
  echo "but the host's daemon-global stack is built by an admin. It is already set" >&2
  echo "up if 'box new' works. Nothing for you to do here." >&2
  exit 0
fi

# How we reach root, decided once. 'sudo' cannot be hardcoded: at UID 0 it is
# unnecessary, and on a minimal root image it is not installed at all — this
# script died on 'sudo: command not found' before doing anything, which made
# install.sh's deliberate root path unusable on exactly the hosts it was for.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  echo "ERROR: host setup needs root and 'sudo' was not found." >&2
  echo "       re-run this as root: $self" >&2
  exit 1
fi

# --- The subnet: never build on one something already owns ------------------
# (#80.) The stack's subnet was hardcoded, and running setup-host INSIDE a box
# gave the guest a nested boxnet claiming the exact subnet and gateway of its
# own uplink: the guest then held its gateway's address as a LOCAL address,
# carried two connected routes for the subnet, and suffered intermittent,
# self-recovering egress blackouts nobody could attribute — the host looked
# clean the whole time. The flagship use case funnels agents toward doing
# exactly this (working on box, in a box), so the decision must happen BEFORE
# any mutation. An explicit BOX_SUBNET is honored or refused, never overridden;
# with no pin, choose_subnet below converges on an existing bridge or picks a
# free /24 itself — a drill inside a box now just works, zero flags.

# BOX_SUBNET must be a /24 with a zero host octet — a.b.c.0/24. Everything
# the stack derives (the bridge address, the gateway carve-out, the firewall)
# assumes that shape, and a garbage value must die HERE, never inside an
# incus create or an nft rule.
valid_subnet() {
  local o a="" b="" c="" rest=""
  case "$1" in *.0/24) ;; *) return 1 ;; esac
  IFS=. read -r a b c rest <<<"${1%/24}"
  [ "$rest" = 0 ] || return 1
  for o in "$a" "$b" "$c"; do
    case "$o" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#o}" -le 3 ] && [ "$o" -le 255 ] || return 1
  done
}

# Who, other than box's own bridge, already owns an address inside $1?
# Prints the claimant and succeeds when the subnet is claimed by a FOREIGNER;
# stays silent and fails when it is free — or held only by boxnet, which is
# the legitimate re-run, converging a stack this script built before. The
# most telling claimant is the default route's gateway: if it sits inside the
# target subnet, this machine's own uplink lives there — i.e. this is almost
# certainly the inside of a box. Pure over `ip` output, so test/cli.sh can
# drive it against canned tables with a shim ip.
subnet_claimant() {
  local pfx hit
  pfx="${1%0/24}"
  hit="$(ip -4 route show default 2>/dev/null | awk -v p="$pfx" '
    { gw = ""; dev = ""
      for (i = 1; i < NF; i++) { if ($i == "via") gw = $(i+1); if ($i == "dev") dev = $(i+1) }
      if (index(gw, p) == 1 && dev != "boxnet") {
        print "this machine\047s own DEFAULT GATEWAY (" gw " via " dev ")"; exit } }')"
  if [ -z "$hit" ]; then
    hit="$(ip -4 -o addr show 2>/dev/null | awk -v p="$pfx" '
      $2 != "boxnet" && index($4, p) == 1 { print "interface " $2 " (" $4 ")"; exit }')"
  fi
  [ -n "$hit" ] && printf '%s\n' "$hit"
}

# The one place the stack's subnet is decided. Four deliberate cases (#80's
# fix #1, completed — the refusal shipped first, this adds the auto-pick):
#   1. explicit BOX_SUBNET       — use it; a foreign claimant or a disagreeing
#      bridge still REFUSES. An operator's pin is never silently overridden:
#      a script that says 10.90 gets 10.90 or a loud stop, never a surprise.
#   2. no pin, boxnet exists     — converge to the bridge's own subnet: the
#      bridge IS the pin (boxes hold leases on it; setup-host never
#      re-addresses it). What used to be an agree-gate refusal on a bare
#      re-run against a moved bridge is now plain convergence. A FOREIGN
#      claimant on the bridge's own subnet still refuses — that is #80's
#      poisoned state, and converging would rebuild on it.
#   3. no pin, no bridge, 10.88.0.0/24 free — the default, as always.
#   4. no pin, no bridge, default claimed   — the nested case (a drill or
#      rehearsal inside a box): scan 10.89.0.0/24 … 10.127.0.0/24 in order,
#      take the first free candidate, and say so loudly; refuse only when
#      EVERY candidate is claimed. The scan only ever runs bridge-less —
#      an existing bridge is case 2, which precedes it.
# Prints the chosen subnet on stdout, explains itself on stderr, fails when
# it refuses. Everything downstream (BOX_GW, the bridge, the ACL carve-out,
# the firewall, the doctor's expectations) derives from the choice, which is
# why it happens here, before any of them. Pure over `ip` (via
# subnet_claimant and the bridge read), so test/cli.sh drives every case
# against canned tables with a shim ip.
choose_subnet() {
  local pin="$1" have_gw have_sub hit cand b
  # ('|| true': under pipefail, `ip … dev boxnet` on a fresh host — no such
  # device — would kill the script here instead of answering "no bridge".)
  have_gw="$(ip -4 -o addr show dev boxnet 2>/dev/null | awk '{ split($4, a, "/"); print a[1]; exit }' || true)"
  have_sub="${have_gw:+${have_gw%.*}.0/24}"

  if [ -n "$pin" ]; then
    if ! valid_subnet "$pin"; then
      echo "ERROR: BOX_SUBNET='$pin' is not a sane subnet — the stack takes a" >&2
      echo "       /24 with a zero host octet, e.g. BOX_SUBNET=10.89.0.0/24" >&2
      return 1
    fi
    if hit="$(subnet_claimant "$pin")"; then
      echo "ERROR: refusing to build boxnet on $pin — that subnet is already" >&2
      echo "       claimed here by $hit." >&2
      echo "       If that is this machine's uplink, you are INSIDE a box: a nested" >&2
      echo "       stack on the guest's own subnet captures its gateway address and" >&2
      echo "       blackholes its egress, intermittently (issue #80)." >&2
      echo "       Nothing was changed. Drop the pin to let setup-host auto-pick a" >&2
      echo "       free subnet, or pick one yourself:  BOX_SUBNET=<a.b.c.0/24> box setup-host" >&2
      return 1
    fi
    if [ -n "$have_sub" ] && [ "$have_sub" != "$pin" ]; then
      echo "ERROR: boxnet already exists on $have_sub and the target is $pin —" >&2
      echo "       setup-host converges an existing bridge, it never re-addresses one." >&2
      echo "       Re-run with the bridge's own subnet (a bare 'box setup-host'" >&2
      echo "       converges on it automatically):" >&2
      echo "         BOX_SUBNET=$have_sub box setup-host" >&2
      echo "       (or move the bridge first:  incus network set boxnet ipv4.address ${pin%.0/24}.1/24)" >&2
      return 1
    fi
    printf '%s\n' "$pin"
    return 0
  fi

  if [ -n "$have_sub" ]; then
    if hit="$(subnet_claimant "$have_sub")"; then
      echo "ERROR: boxnet lives on $have_sub, but that subnet is ALSO claimed here" >&2
      echo "       by $hit — the #80 poisoned state. Converging would rebuild on it." >&2
      echo "       Move the bridge off the claimed subnet first:" >&2
      echo "         incus network set boxnet ipv4.address 10.89.0.1/24" >&2
      echo "       then re-run:  box setup-host" >&2
      return 1
    fi
    if [ "$have_sub" != 10.88.0.0/24 ]; then
      echo "boxnet already lives on $have_sub — converging to it." >&2
      echo "(pin it explicitly with BOX_SUBNET=$have_sub if you script this host)" >&2
    fi
    printf '%s\n' "$have_sub"
    return 0
  fi

  if ! hit="$(subnet_claimant 10.88.0.0/24)"; then
    printf '10.88.0.0/24\n'
    return 0
  fi
  for b in {89..127}; do
    cand="10.$b.0.0/24"
    subnet_claimant "$cand" >/dev/null && continue
    echo "10.88.0.0/24 is claimed here by $hit —" >&2
    echo "most likely this machine IS a box (a nested drill or rehearsal, issue #80)." >&2
    echo "auto-picked $cand for this stack instead." >&2
    echo "(pin it explicitly with BOX_SUBNET=$cand if you script this host)" >&2
    printf '%s\n' "$cand"
    return 0
  done
  echo "ERROR: refusing to build boxnet — 10.88.0.0/24 is already claimed here by" >&2
  echo "       $hit, and so is every candidate through 10.127.0.0/24." >&2
  echo "       If that first claimant is this machine's uplink, you are INSIDE a" >&2
  echo "       box: a nested stack on the guest's own subnet captures its gateway" >&2
  echo "       address and blackholes its egress, intermittently (issue #80)." >&2
  echo "       Nothing was changed. Pick a free subnet yourself:" >&2
  echo "         BOX_SUBNET=<a.b.c.0/24> box setup-host" >&2
  return 1
}

BOX_SUBNET="$(choose_subnet "${BOX_SUBNET:-}")" || exit 1
BOX_GW="${BOX_SUBNET%.0/24}.1"

# Where the pool goes, decided here beside the subnet and for the same reason:
# both gates say "Nothing was changed", and that is only true above the apt
# calls. This one used to sit down by the pool, where a FRESH host had already
# been sent through 'apt-get update' and 'apt-get install -y incus' before the
# gate ever ran — harmless (the install is what setup-host came to do) but the
# sentence overstated, and the check guarding it could not see the difference
# because the suite's shim pre-installs incus. It is pure shell with no
# dependencies, so it moves up unchanged and the claim becomes true on every
# host. test/cli.sh holds the order the way it holds the subnet gate's.
BOX_STORAGE_SOURCE="${BOX_STORAGE_SOURCE:-}"
# btrfs and dir — the only two drivers this script creates — read 'source:' as
# a filesystem path or a block device. A relative one would be resolved by the
# DAEMON, against its idea of where it is standing and not yours, so it dies
# here rather than placing a pool somewhere nobody named.
case "$BOX_STORAGE_SOURCE" in
  ''|/*) ;;
  *) echo "ERROR: BOX_STORAGE_SOURCE must be an absolute path — got '$BOX_STORAGE_SOURCE'." >&2
     echo "       a block device ('/dev/sdb', which Incus formats and owns outright)" >&2
     echo "       or a path on an already-mounted filesystem ('/data/bulk/incus')." >&2
     echo "       Nothing was changed." >&2
     exit 1 ;;
esac
# The one shape the pass-through cannot carry. Everything else survives being
# quoted (below), but YAML FOLDS a line break inside a quoted scalar to a
# space, so '/data/a<newline>b' would reach Incus as '/data/a b' — a different
# path, silently, which is the whole defect #180 exists to close. Refusing a
# value this preseed cannot transmit faithfully is the opposite of refusing one
# Incus would have accepted: the gate is not second-guessing the placement, it
# is declining to lie about it. A tab and the other control characters go with
# it — same class, same reason, and none of them is a path anyone typed on
# purpose (panel round 3).
case "$BOX_STORAGE_SOURCE" in
  *[[:cntrl:]]*)
     echo "ERROR: BOX_STORAGE_SOURCE contains a control character (a newline or a tab)." >&2
     echo "       The preseed carries the source as a YAML scalar, and YAML" >&2
     echo "       folds a line break inside one to a space — so Incus would be handed a" >&2
     echo "       DIFFERENT path than you named, and the pool would be built somewhere" >&2
     echo "       nobody asked for." >&2
     echo "       Refusing rather than mangling it. Rename the directory, or place the" >&2
     echo "       pool on a path without one." >&2
     echo "       Nothing was changed." >&2
     exit 1 ;;
esac

# apt, unattended-safe. install.sh now runs us without a human watching, and
# a fresh cloud image has apt-daily/unattended-upgrades holding the dpkg lock
# for the first minutes of its life — plain 'apt-get install' then waits on it
# in complete silence, indefinitely. Bound the wait and never prompt.
# 'env', not a bare VAR=val prefix: bash recognises assignments at PARSE time,
# so with $SUDO empty (we are root) 'DEBIAN_FRONTEND=x apt-get' would have
# already been parsed as a plain word and bash would try to EXECUTE it —
# 'DEBIAN_FRONTEND=noninteractive: command not found'. env is immune.
apt_get() {
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 "$@"
}

if ! command -v incus >/dev/null; then
  apt_get update
  apt_get install -y incus
fi

if [ "$(id -u)" -eq 0 ]; then
  # Root needs no group: UID 0 opens /var/lib/incus/unix.socket regardless of
  # who owns it, and there is nothing to re-exec into. The HUMAN needs it — and
  # under 'sudo install.sh' that is SUDO_USER, not the root we are running as.
  # Adding root to incus-admin would be a no-op that also left the actual user
  # locked out of their own boxes.
  # NOTE: 'id -nG "$name"' here is deliberate and NOT the bug fixed below. That
  # bug was asking the DATABASE about our own process; this asks the database
  # about someone else's account, which is the only thing it can be asked.
  login_user="${SUDO_USER:-}"
  if [ -n "$login_user" ] && [ "$login_user" != root ]; then
    if ! id -nG "$login_user" | grep -qw incus-admin; then
      usermod -aG incus-admin "$login_user"
      echo "added $login_user to incus-admin — log out and back in for your shell to pick it up"
    fi
  fi
# Group membership is a property of THIS PROCESS's credentials, not of the group
# database — and the two disagree for exactly as long as it matters here.
# 'id -nG "$USER"' names a user, so it reads /etc/group and reports incus-admin
# the instant usermod returns; the running shell's own credentials still lack
# it, because supplementary groups are fixed at login. So the old check passed
# on a same-session re-run, sailed into the incus calls below, and died on a
# permission error that named neither the group nor the re-login. Argless
# 'id -nG' asks the process what it actually holds, which is what incus checks
# when it opens /var/lib/incus/unix.socket.
elif ! id -nG | grep -qw incus-admin; then
  $SUDO usermod -aG incus-admin "$USER"
  # Then finish the job rather than adjourning it. Exiting 0 here was a
  # success-shaped no-op: no boxnet, no ACL, no box-profile profile, no firewall —
  # and the burden of knowing that on the reader of a NOTE (#63). 'sg' runs us
  # again with the new group in our credentials, no re-login, one invocation.
  # The guard makes that at most one hop: if sg somehow lands without the
  # group, we fail loudly instead of forking forever.
  if [ -z "${BOX_SETUP_HOST_REEXEC:-}" ]; then
    echo "added $USER to incus-admin — re-running under the new group (no re-login needed)"
    export BOX_SETUP_HOST_REEXEC=1
    exec sg incus-admin -c "$(printf '%q ' bash "$self" "$@")"
  fi
  echo "ERROR: still not in incus-admin after usermod + sg." >&2
  echo "       log out and back in, then re-run: box setup-host" >&2
  exit 1
fi

# Storage pool + base config (safe to re-run: skipped once the pool exists).
# NOT 'incus admin init --minimal': minimal picks the 'dir' backend, which has
# no copy-on-write — every snapshot and clone is a FULL copy of the box's root,
# several GB and minutes apiece once a box is provisioned, against a workflow
# whose whole point is "log in once, snapshot, clone forever" (#29). btrfs on
# a loop device gives CoW (near-instant, near-free clones) with no
# partitioning. The preseed mirrors exactly what --minimal creates (pool,
# incusbr0, default profile) with only the driver deliberate; dir remains the
# fallback so a host that cannot do btrfs still works — just slowly, and it
# says so.
#
# WHERE that pool lives is a second decision, independent of the driver (#180).
# With no 'source:' key Incus creates the pool inside its own state directory,
# /var/lib/incus/storage-pools/default — on the root filesystem. Every box's
# root device then sits in that loop-backed image, so the disk a template asks
# for (BOX_DISK, 60GiB by default) is charged against '/', and a whole fleet
# competes with the operating system for one partition. BOX_STORAGE_SOURCE is
# that placement and it is passed through to 'source:' VERBATIM: Incus reads a
# block device (/dev/sdb — formatted and owned outright, the recommended form)
# and a path on an already-mounted filesystem (/data/bulk/incus — shared with
# whatever else is there) through the same key, and this script telling the two
# apart would only be guessing at what Incus already knows. Unset emits no
# 'source:' line at all, so an upgraded host keeps byte-for-byte the pool it
# has. Placement is HOST state, decided once with the pool, which is why it is
# a setup-host variable and not a 'box new' flag — box new owns no resize verb
# for the same reason (docs/box-design.md).

# The preseed's storage_pools block, composed in one place so test/cli.sh can
# drive every driver/source combination against it — and so the unset case is
# provably the same bytes it has always been.
#
# The source is a SINGLE-QUOTED YAML scalar, never a plain one. A plain scalar
# ends at ' #', YAML's comment marker, so '/data/bulk/a #archive' — a legal
# directory name and a legal Incus source — would reach the daemon as
# '/data/bulk/a', and where that prefix exists the pool is built somewhere
# nobody named, silently. That is exactly the defect #180 came to close,
# arriving through the front door instead. Quoting is also what makes the
# pass-through VERBATIM rather than nearly: inside single quotes every
# character is literal and only a quote needs escaping, by doubling it. The
# alternative — refusing such a value at the gate — would make this script the
# thing standing between the operator and a placement Incus accepts, which is
# the guessing the pass-through exists to avoid.
#
# Unset still emits no 'source:' line at all, so an upgraded host's preseed is
# byte-for-byte the one it has always had.
pool_block() {
  local src="$2"
  printf 'storage_pools:\n- name: default\n  driver: %s\n' "$1"
  [ -z "$src" ] || printf "  source: '%s'\n" "${src//\'/\'\'}"
}

# One YAML scalar, off a 'key: value' line, with none of it lost. Reading such
# a line with awk's $2 stops at the first space — so a source with a space in
# it read back as a DIFFERENT path than the pool is on, and every report built
# from it named a directory that does not hold the boxes (#180, panel round 2).
# Everything after the first ':' is the value; whitespace around it is YAML's,
# not the value's.
#
# The quotes come off here because Incus puts them on: it emits any value plain
# YAML would mangle as a quoted scalar. Single-quoted is literal with '' for a
# quote; double-quoted needs \" and \\ undone. A bare pair of quotes is the
# recorded-but-EMPTY value every loop-backed pool carries in
# volatile.initial_source — the key being absent, not a source named '""', and
# handled here once rather than at each reader.
yaml_scalar() {
  local v="$1"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    "'"*"'") v="${v#\'}"; v="${v%\'}"; v="${v//\'\'/\'}" ;;
    '"'*'"') v="${v#\"}"; v="${v%\"}"; v="${v//\\\"/\"}"; v="${v//\\\\/\\}" ;;
  esac
  printf '%s' "$v"
}

# That scalar, for one key of 'incus storage show' output. $1 is the key test
# (so indentation under 'config:' costs nothing), and the value is everything
# past the first colon — never a field.
yaml_value() {
  local key="$1" show="$2" line
  line="$(awk -v k="$key:" '$1 == k { sub(/^[[:space:]]*[^:]*:/, ""); print; exit }' <<<"$show")"
  yaml_scalar "$line"
}

# The INSTANCES named by a 'used_by:' list — one per line, project-qualified
# where Incus qualifies them, nothing at all when none. Text in, names out, so
# test/cli.sh drives it against canned 'incus network show' output the way it
# drives valid_subnet and pool_block (#227).
#
# One read answers "is anything attached?" because Incus computes used_by from
# every instance's EXPANDED devices: a box that reaches boxnet through the
# box-profile profile — which is every box — is listed here by its own name, beside
# the profiles. Reading the profile entries instead would need the names of the
# restricted tier's per-user profile copies, which 'box grant' creates and this
# script has never known. The profile entries are why the bridge cannot simply
# be deleted and rebuilt: clearing them to free the network breaks those grants
# with no lever to restore them, so the bridge is converged in place.
# doctor.sh carries a copy, as it does of yaml_scalar; test/cli.sh drives both.
used_by_instances() {
  printf '%s\n' "$1" | awk '
    /^used_by:/ { in_list = 1; next }
    in_list && /^-[[:space:]]/ {
      url = $2
      if (url !~ /^\/1\.0\/instances\//) next
      sub(/^\/1\.0\/instances\//, "", url)
      proj = ""
      if (match(url, /\?project=/)) {
        proj = substr(url, RSTART + 9)
        url  = substr(url, 1, RSTART - 1)
      }
      print (proj == "" ? url : url " (project " proj ")")
      next
    }
    in_list && /^[^[:space:]-]/ { in_list = 0 }
  '
}

# One key of the live pool's config, or nothing. Two probes: 'get' answers with
# an empty line for a key that was never recorded, which is indistinguishable
# from a refusal, and 'show' is the read this script already prints its driver
# from. Never fatal — '|| true' on both, and the awk reads a variable rather
# than a pipeline, so this cannot turn fatal later under 'shopt -s
# inherit_errexit' (bin/box's storage_driver carries the same note, #107).
# 'incus storage get' reads the pool's config map straight, with no volatile
# filtering, so a volatile.* key is a legitimate read here.
pool_cfg() {
  local key="$1" out show
  out="$(incus storage get default "$key" 2>/dev/null || true)"
  # 'get' prints the value itself, unquoted and whole — it is the read that
  # needs no unpicking. The 'show' fallback is YAML, so it goes through
  # yaml_value, which is where the quoting and the recorded-but-empty '""'
  # of a loop-backed pool are dealt with.
  if [ -z "$out" ]; then
    show="$(incus storage show default 2>/dev/null || true)"
    out="$(yaml_value "$key" "$show")"
  fi
  printf '%s' "$out"
}

# What filesystem does this path hold RIGHT NOW, as a UUID? Empty for anything
# that is not a block device, for a path that does not exist, and for a host
# with neither tool — all of which are "cannot be established", which the
# matcher below treats as a refusal and never as a pass.
#
# 'lsblk' first, deliberately: it answers out of udev/sysfs and needs no
# privilege, so a non-root run is not silently identity-blind. 'blkid' reads
# the superblock itself and therefore needs the device open, i.e. root — but it
# is the read INCUS ITSELF does to fill 'source' after formatting (fsUUID(),
# driver_btrfs.go, lxc/incus@90429bf), so the two answers are the same string
# by construction and the fallback cannot disagree with the primary.
dev_fs_uuid() {
  local dev="$1" uuid=""
  if command -v lsblk >/dev/null 2>&1; then
    uuid="$(lsblk --nodeps -rno UUID -- "$dev" 2>/dev/null | head -1 || true)"
  fi
  if [ -z "$uuid" ] && command -v blkid >/dev/null 2>&1; then
    uuid="$($SUDO blkid -s UUID -o value -- "$dev" 2>/dev/null | head -1 || true)"
  fi
  printf '%s' "$uuid"
}

# Is the live pool already at the requested source? Pure — requested, live,
# initial and what the request resolves to NOW in, exit status out — so
# test/cli.sh drives it directly.
#
# Two sources, because Incus keeps two. Handed a BLOCK DEVICE, the btrfs driver
# records what you gave it in 'volatile.initial_source', formats the device,
# then OVERWRITES 'source' with the new filesystem's UUID — a bare UUID, not a
# path (lxc/incus@90429bf, driver_btrfs.go). So a host set up with
# BOX_STORAGE_SOURCE=/dev/sdb reports 'source: 4ff9…' ever after, and reading
# live 'source' alone would make every re-run of the documented block-device
# form fire the migration refusal below at the pool it had just correctly
# placed. The 'dir' driver sets no initial source and mangles nothing, so the
# fall back to live 'source' is not a courtesy for old pools — it is the only
# correct read for that driver, and for every path-shaped source.
#
# But an initial source is a STRING RECORDED ONCE, at creation, and it was
# being used as proof of what a path names TODAY. Those are different facts,
# and they come apart the first time the kernel enumerates disks in a different
# order — a reboot, an added controller, a hot-plug. Then '/dev/sdb' is disk B
# while the pool is still on disk A, and the documented identical invocation
# used to answer "already placed there" about a disk it is not on: D3's silence
# wearing a success message (panel round 3). So where live 'source' is NOT a
# path — i.e. it is the UUID btrfs wrote after formatting a device — the
# historical string is proof only if the path still resolves to that
# filesystem. Where live 'source' IS a path, or absent, Incus mangled nothing,
# the string is the answer, and the textual comparison stands unchanged: every
# 'dir' pool, every mounted-path source.
#
# Three outcomes, because there are three facts: 0 placed, 1 placed somewhere
# else entirely, 2 made from this path but the path is not that disk now (or
# cannot be shown to be). 1 and 2 both refuse, and they refuse differently.
#
# A trailing slash is not a mismatch, on any of them.
pool_placed_at() {
  local want="$1" live="$2" initial="${3:-}" now="${4:-}"
  [ -n "$want" ] || return 1
  if [ "${want%/}" = "${live%/}" ]; then return 0; fi
  if [ -n "$initial" ] && [ "${want%/}" = "${initial%/}" ]; then
    case "$live" in
      ''|/*) return 0 ;;
    esac
    if [ -n "$now" ] && [ "$now" = "$live" ]; then return 0; fi
    return 2
  fi
  return 1
}

if incus storage show default >/dev/null 2>&1; then
  # The pool exists, so the preseed below is skipped — and with it any chance
  # of honoring a placement. That skip used to be SILENT: setting
  # BOX_STORAGE_SOURCE on a host that already has a pool did nothing and said
  # nothing, and the operator learned it from 'df' weeks later. That silence is
  # the defect this refusal closes (#180). Moving a pool that already carries
  # boxes means moving every box's root device — a migration with its own risk,
  # its own confirmation and its own drill leg, deliberately not this script's.
  if [ -n "$BOX_STORAGE_SOURCE" ]; then
    live="$(pool_cfg source)"
    initial="$(pool_cfg volatile.initial_source)"
    if [ -z "$live" ] && [ -z "$initial" ]; then
      echo "ERROR: BOX_STORAGE_SOURCE=$BOX_STORAGE_SOURCE was requested, but the live pool" >&2
      echo "       'default' reports NO source at all — so this run cannot prove it is" >&2
      echo "       already placed there, and creating it again is not on the table." >&2
      echo "       read it by hand:  incus storage show default" >&2
      echo "       Nothing was changed." >&2
      exit 1
    fi
    # What the requested path names on this machine at this moment — read once,
    # here, so the matcher stays pure and the suite can contradict it.
    now="$(dev_fs_uuid "$BOX_STORAGE_SOURCE")"
    placed=0; pool_placed_at "$BOX_STORAGE_SOURCE" "$live" "$initial" "$now" || placed=$?
    if [ "$placed" -eq 2 ]; then
      # The pool WAS made from this path, and the path is not that disk now.
      # Refusing here is not pedantry: proceeding would tell an operator their
      # boxes are on the disk currently answering to that name, and they are
      # not — which is exactly the belief #180 exists to stop a script creating.
      echo "ERROR: the storage pool 'default' was made from $BOX_STORAGE_SOURCE, but that" >&2
      echo "       path does not name the disk the pool is on now." >&2
      echo "         live:      ${live:-<none reported>}  (the filesystem UUID Incus wrote when it formatted the device)" >&2
      echo "         made from: $initial" >&2
      echo "         requested: $BOX_STORAGE_SOURCE" >&2
      if [ -n "$now" ]; then
        echo "         and $BOX_STORAGE_SOURCE now holds: $now" >&2
      else
        echo "         and $BOX_STORAGE_SOURCE holds no filesystem this run could read" >&2
        echo "                    (no such device, not a block device, or no lsblk/blkid here)" >&2
      fi
      echo "       A device NAME is assigned in enumeration order and can move across a" >&2
      echo "       reboot; the filesystem UUID above cannot. So this run cannot prove the" >&2
      echo "       pool is where you asked, and saying it is would be the silence this" >&2
      echo "       check exists to remove." >&2
      echo "       Find the disk that holds it:  lsblk -o NAME,UUID   |   blkid -t UUID=${live:-<uuid>}" >&2
      echo "       ...then name THAT device, or unset BOX_STORAGE_SOURCE to re-run this" >&2
      echo "       script against the host as it stands." >&2
      echo "       Nothing was changed." >&2
      exit 1
    fi
    if [ "$placed" -ne 0 ]; then
      echo "ERROR: the storage pool 'default' already exists somewhere else." >&2
      echo "         live:      ${live:-<none reported>}" >&2
      # The device the operator actually named, whenever Incus still knows it:
      # a refusal whose 'live' is a bare UUID names no disk anybody can act on.
      if [ -n "$initial" ] && [ "${initial%/}" != "${live%/}" ]; then
        echo "         made from: $initial" >&2
      fi
      echo "         requested: $BOX_STORAGE_SOURCE" >&2
      case "$live" in
        ''|/*) ;;
        *) echo "       ('live' is not a path because Incus formats a block device and then" >&2
           echo "        records the new filesystem's UUID as the pool's source.)" >&2 ;;
      esac
      echo "       A pool is created once, so re-running with BOX_STORAGE_SOURCE set does" >&2
      echo "       NOT move it — and pretending otherwise is how a host ends up filling" >&2
      echo "       its root disk while its operator believes the boxes live elsewhere." >&2
      echo "       Moving a pool that carries boxes means moving every box's root device:" >&2
      echo "       that is a migration, not a re-run (issue #180). To re-run this script" >&2
      echo "       against the host as it stands, unset BOX_STORAGE_SOURCE." >&2
      echo "       Nothing was changed." >&2
      exit 1
    fi
    # Report the device the operator named, not the UUID it became: on the
    # block-device form those differ, and the UUID answers a question nobody
    # asked. Where they are the same (every 'dir' pool, every path source) this
    # is the line it always was.
    if [ -n "$initial" ] && [ "${initial%/}" != "${live%/}" ]; then
      echo "storage: pool 'default' source = $initial (already placed there; Incus records it as '$live'; nothing to do)"
    else
      echo "storage: pool 'default' source = $live (already placed there; nothing to do)"
    fi
  fi
else
  driver=btrfs
  command -v mkfs.btrfs >/dev/null 2>&1 || apt_get install -y btrfs-progs || driver=dir
  if ! incus admin init --preseed <<PRESEED
$(pool_block "$driver" "$BOX_STORAGE_SOURCE")
networks:
- name: incusbr0
  type: bridge
profiles:
- name: default
  devices:
    root:
      path: /
      pool: default
      type: disk
    eth0:
      name: eth0
      network: incusbr0
      type: nic
PRESEED
  then
    # --minimal cannot carry a source: it creates the pool under /var/lib/incus,
    # on the root filesystem — the exact placement the operator asked to avoid.
    # Falling back to it here would be the same silence as the skip above, one
    # step further along, so a requested placement makes the preseed failure
    # fatal instead. With nothing requested, the fallback is what it always was.
    if [ -n "$BOX_STORAGE_SOURCE" ]; then
      echo "ERROR: the storage preseed failed, and BOX_STORAGE_SOURCE=$BOX_STORAGE_SOURCE" >&2
      echo "       cannot be honored by the '--minimal' fallback: minimal places the pool" >&2
      echo "       under /var/lib/incus, on the root filesystem. Refusing rather than" >&2
      echo "       building a host whose boxes live somewhere you did not name." >&2
      echo "       incus said why above. Fix that, or re-run without BOX_STORAGE_SOURCE" >&2
      echo "       to accept the root-filesystem pool." >&2
      exit 1
    fi
    echo "storage: $driver preseed failed — falling back to --minimal (dir: every clone is a full disk copy)" >&2
    incus admin init --minimal
  fi
  # Report both halves: the driver decides whether a clone is near-free, the
  # source decides which disk fills up (#180). Read back rather than echoed
  # from the inputs — the fallback above can have changed both.
  #
  # The driver comes off 'show' because it is not a config key and 'incus
  # storage get' would not answer for it; the source goes through pool_cfg,
  # the same read the re-run above uses, so this line says what that one says.
  pool_show="$(incus storage show default 2>/dev/null || true)"
  echo "storage: pool 'default' driver = $(yaml_value driver "$pool_show")"
  pool_live="$(pool_cfg source)"
  pool_initial="$(pool_cfg volatile.initial_source)"
  if [ -n "$pool_live" ]; then
    # Name the device the operator just typed, not the UUID it became. This is
    # the ONE run where they are guaranteed to differ on the documented
    # block-device form — btrfs has just formatted the disk and written the new
    # filesystem's UUID over 'source' — and it was the one line still answering
    # with the UUID alone, while the re-run and 'box doctor' name the disk.
    if [ -n "$pool_initial" ] && [ "${pool_initial%/}" != "${pool_live%/}" ]; then
      echo "storage: pool 'default' source = $pool_initial (Incus records it as '$pool_live')"
    else
      echo "storage: pool 'default' source = $pool_live"
    fi
  else
    echo "storage: pool 'default' source = <none> — loop-backed under /var/lib/incus, i.e." \
         "on the root filesystem; BOX_STORAGE_SOURCE places a FRESH host's pool elsewhere (#180)"
  fi
fi

# Isolated NAT network. IPv6 off: one less egress path to reason about.
# The default is 10.88 — not 10.87: a pre-rename host may still carry
# claudenet on 10.87 with legacy boxes attached — two bridges must not claim
# one subnet. BOX_SUBNET holds whatever choose_subnet decided above (an
# explicit pin, the existing bridge, the default, or an auto-picked free
# /24); the gateway and every rule below derive from it.
#
# Create if missing, then CONVERGE — the same shape as the ACL below and the
# box-profile profile at the end of this file, and for the same reason. The create
# arguments used to be the ONLY place these keys were written, so they ran on a
# fresh host and never again: a bridge that drifted, or that predates a key,
# was detected by every tool in this repo and repaired by none. Measured on a
# real host 2026-08-27 while preparing the 0.10.0 drill — ipv4.address EMPTY,
# ipv6.address SET, a combination no current create produces — where probe C6
# reads ipv6.address and would have written "ipv6: ENABLED and uncovered" into
# the release record as a finding against the release (#227).
if ! incus network show boxnet >/dev/null 2>&1; then
  incus network create boxnet \
    ipv4.address="$BOX_GW/24" ipv4.nat=true ipv6.address=none
else
  # ipv4.address is the ONE key converged conditionally, and this is why: it
  # RENUMBERS the bridge. Every attached box holds a lease on the old subnet
  # and the gateway moves out from under it — the shape of #80's blackouts,
  # bought this time by the tool that repairs them. So converge it only where
  # nothing is attached; where something is, name the drift and leave it. A
  # tool that silently renumbers a running fleet is worse than one that will
  # not. choose_subnet stays the authority: $BOX_GW is the address it already
  # decided (the bridge's own, on a bare re-run), never a second decision.
  #
  # It goes FIRST so the unconditional keys below are never set against a
  # bridge that is about to be re-addressed in the same run.
  have_addr="$(incus network get boxnet ipv4.address 2>/dev/null || true)"
  if [ "$have_addr" != "$BOX_GW/24" ]; then
    BOXNET_IPV4_DRIFT="${have_addr:-<unset>}"
    # An 'incus network show' that answers nothing is not an empty used_by
    # list. The bridge described itself one line ago, so a silent answer here
    # is the daemon, not the fleet — and the safe reply to "may I renumber?"
    # under ignorance is no.
    boxnet_show="$(incus network show boxnet 2>/dev/null || true)"
    attached="$(used_by_instances "$boxnet_show")"
    if [ -z "$boxnet_show" ]; then
      echo "WARNING: boxnet's ipv4.address is $BOXNET_IPV4_DRIFT, and the contract for" >&2
      echo "         this subnet is $BOX_GW/24 — but 'incus network show boxnet' answered" >&2
      echo "         nothing, so what is attached to the bridge is unknown. Converging" >&2
      echo "         RENUMBERS it, so nothing was changed. Check the daemon and re-run." >&2
    elif [ -z "$attached" ]; then
      incus network set boxnet ipv4.address="$BOX_GW/24"
      echo "boxnet: ipv4.address converged $BOXNET_IPV4_DRIFT -> $BOX_GW/24 (nothing attached)"
      unset BOXNET_IPV4_DRIFT
    else
      echo "WARNING: boxnet's ipv4.address is $BOXNET_IPV4_DRIFT, and the contract for" >&2
      echo "         this subnet is $BOX_GW/24. Converging it RENUMBERS the bridge, and" >&2
      echo "         these instances are attached to it:" >&2
      printf '%s\n' "$attached" | sed 's/^/           /' >&2
      echo "         Nothing was changed. Stop them, then converge it — either by" >&2
      echo "         re-running 'box setup-host' with nothing attached, or by hand:" >&2
      echo "           incus network set boxnet ipv4.address $BOX_GW/24" >&2
    fi
  fi

  # The isolation contract's own keys, converged unconditionally. Neither
  # depends on the operator's subnet choice, and both are safe to set with
  # instances attached — which is the whole difference from the key above.
  incus network set boxnet ipv6.address=none ipv4.nat=true
fi

# ACL: default egress allow (internet), explicit drops for private space.
# Gateway carve-out first so instance DNS (dnsmasq on the gateway) survives.
# 'edit' the full shipped ruleset, not create-once: the carve-out derives
# from BOX_SUBNET now, and a bridge moved off a colliding subnet (#80's
# escape hatch) left the OLD /32 behind — box DNS to the new gateway then
# died inside the 10.0.0.0/8 drop, looking like a dead resolver, not a stale
# ACL. A conditional 'rule add' cannot converge that (the stale carve-out
# would survive beside the new one); replacing the ruleset does, idempotently.
incus network acl show box-isolate >/dev/null 2>&1 || incus network acl create box-isolate
incus network acl edit box-isolate <<ACL
description: ""
egress:
- action: allow
  destination: $BOX_GW/32
  state: enabled
- action: drop
  destination: 10.0.0.0/8
  state: enabled
- action: drop
  destination: 172.16.0.0/12
  state: enabled
- action: drop
  destination: 192.168.0.0/16
  state: enabled
- action: drop
  destination: 169.254.0.0/16
  state: enabled
- action: drop
  destination: 100.64.0.0/10
  state: enabled
ingress: []
ACL
incus network set boxnet security.acls=box-isolate \
  security.acls.default.egress.action=allow \
  security.acls.default.ingress.action=drop

# A box must not be able to ENUMERATE its siblings, either. dnsmasq on the
# gateway serves DNS (that carve-out is what makes egress resolution work) and
# it holds a record for every instance on the network — so 'getent hosts <box>'
# from inside one box resolved another's name and address. Connection blocked,
# reconnaissance wide open. dns.mode=none stops it registering instance records;
# forwarding for public names is unaffected (verified live).
incus network set boxnet dns.mode=none

# A box's resolver must not be a function of the host's VPN posture (#33).
# The bridge's dnsmasq forwards to whatever sits in the HOST's /etc/resolv.conf
# at that moment. On a Tailscale/VPN host that is MagicDNS: box DNS flaps with
# the tailnet (this is what killed cold mints), and tailnet peer names and
# split-DNS zones RESOLVE from inside a box — name-level reconnaissance of a
# private network, the same shape as the sibling enumeration closed above.
# no-resolv detaches dnsmasq from the host's resolver entirely; server= pins a
# stable public upstream (override: BOX_DNS="ip ip…"). raw.dnsmasq is the
# lever — the bridge has no first-class upstream key. Verified live on the
# drill host: pin applied, box resolves, cold mint survives.
BOX_DNS="${BOX_DNS:-1.1.1.1 8.8.8.8}"
incus network set boxnet raw.dnsmasq \
  "$(printf 'no-resolv\n'; for s in $BOX_DNS; do printf 'server=%s\n' "$s"; done)"

# Sibling isolation itself is NOT an ACL rule — an L3 ACL never sees frames
# switched between two ports of one bridge. It lives in box-firewall.sh
# as an nftables bridge-family rule. See the comment there; it is the reason
# boxes cannot reach each other.

# IPv6 stays off (ipv6.address=none, above). Every rule in the ACL and every
# rule in the firewall is IPv4-only, so IPv6 would be an uncovered path, not a
# feature. That is a contract, not a default.

# --- Firewall coexistence ---------------------------------------------------
# Hosts running UFW (INPUT drop) and/or Docker (FORWARD drop) silently eat
# boxnet traffic. Punch minimal, ordered holes; the Incus ACL still layers
# on top. The trailing deny also blocks instance -> host's own (public) IPs,
# which the RFC1918-only ACL cannot express. Rules live in
# box-firewall.sh; a boot-time systemd unit re-applies the runtime-only
# parts (nft table, DOCKER-USER) after every reboot.
# The no-UFW path drives nft directly, and a stock Debian 13 cloud image ships
# neither nftables nor UFW — install the dependency we are about to use.
if ! command -v ufw >/dev/null 2>&1 && ! command -v nft >/dev/null 2>&1; then
  apt_get install -y nftables
fi
$SUDO install -m 755 "$here/host/box-firewall.sh" /usr/local/sbin/box-firewall
# The drop-in directory tools write their ports into (#279). Made here so it
# is discoverable; never removed by teardown — the files are the tools'.
$SUDO install -d -m 0755 /etc/box/firewall.d
$SUDO install -m 644 "$here/host/box-firewall.service" /etc/systemd/system/
$SUDO systemctl daemon-reload
$SUDO systemctl enable box-firewall.service
# RESTART, not 'enable --now'. The unit is RemainAfterExit, so once it has run
# it stays "active" forever — and 'enable --now' does nothing to an active unit.
# Re-running setup-host after upgrading the tool therefore installed the new
# rules to /usr/local/sbin and never applied them: the host kept the old
# firewall, silently, and the box→box hole stayed open through a release that
# claimed to close it. Restart re-runs the script, which is idempotent by design.
$SUDO systemctl restart box-firewall.service

# incus-user is what serves the restricted tier (box grant). Debian 13 and
# Ubuntu 24.04 ship it inside the incus package; enabling it here makes the
# host tier-ready, and costs a host that never grants anyone nothing. Failure
# is a NOTE, not an error: the admin tier does not depend on it.
$SUDO systemctl enable --now incus-user.socket 2>/dev/null \
  || echo "NOTE: could not enable incus-user.socket — 'box grant' (the restricted tier) needs it; this Incus may not ship incus-user (#74)." >&2

# Profile — box-profile, the placement contract: the isolated NIC and the root
# disk, nothing a template controls (resources are stamped per-instance from
# the template at mint time). A legacy claude-dev profile is left alone:
# Incus refuses to delete an in-use profile, and pre-rename boxes reference
# it until their last one is gone — teardown-host removes it then.
#
# Converge the #229 rename first. Up to 0.9.x this profile was 'box-net', one
# hyphen from the 'boxnet' bridge its NIC attaches to, which read as a typo to
# anyone holding raw 'incus' output and no context. Converging a host's own
# stack is what this script already does for the bridge, the ACL, dns.mode and
# the resolver; the rename joins that list rather than becoming migration
# tooling, which box is leaving (#226).
#
# Projects this run could not converge, collected rather than thrown: one
# project that cannot converge must not stop the ones after it from trying,
# and it must not be forgotten by the time the run reports (#229, round 1).
PROFILE_UNCONVERGED=""
# Three ways this convergence can end short, and they are held apart because
# they leave the host in three different states and each is cleared by a
# different act. Collapsing them would put the run's most detailed report —
# "boxes are placed on each, move the stragglers" — on top of two states where
# it is simply untrue (#229, round 2).
PROFILE_HALFDONE=""
PROJECTS_UNREAD=""

converge_profile_name() {
  local project="$1" label="$2"

  incus --project "$project" profile show box-net >/dev/null 2>&1 || return 0

  # Both names present, which is where an interrupted upgrade lands. The new
  # name wins and the old is removed — and this case is decided BEFORE any
  # rename is attempted, never as a fallback from one failing. Incus refuses a
  # rename onto an existing name outright ("Profile %q already exists",
  # cmd/incusd/profiles.go), so ordering it the other way would turn the
  # resume-an-interrupted-upgrade path into a hard error under 'set -e'.
  if incus --project "$project" profile show box-profile >/dev/null 2>&1; then
    if incus --project "$project" profile delete box-net >/dev/null 2>&1; then
      echo "profile: removed the stale box-net in $label (box-profile is already there)"
      return 0
    fi

    # The delete was refused, which says one thing: something is still placed
    # on the old name. That is not a state to warn about and walk away from —
    # 'box grant' produces it on every upgraded host, installing a fresh
    # box-profile beside the in-use box-net it does not converge, and a run
    # that leaves both names behind has not converged the rename whatever it
    # printed afterwards.
    #
    # So converge it the other way round. The box-profile beside it is the
    # copy grant just wrote: same body, and by construction nothing is placed
    # on it yet, so it is the one that can go. Then the ordinary rename
    # carries the in-use profile onto the new name, and by D6 every attached
    # box keeps its placement across it — the association is by profiles.id
    # and the rename writes the name column alone. One name afterwards, no
    # instance reassignment, no restart, and nothing here that is migration
    # tooling: it is the same two calls in the other order.
    #
    # The two calls are written apart rather than as one '&&' compound because
    # they fail differently and a single report for both would be false in one
    # of the cases: once the delete has succeeded the target name is FREE, so
    # a rename failing after it does not mean "boxes are placed on each" — it
    # means this project now carries box-net alone, with no box-profile for
    # 'box new' to place on, and the operator needs to be told that and not
    # the other thing (#229, round 2).
    if incus --project "$project" profile delete box-profile >/dev/null 2>&1; then
      if incus --project "$project" profile rename box-net box-profile >/dev/null 2>&1; then
        echo "profile: box-net was in use in $label — renamed it onto box-profile (#229)"
        return 0
      fi

      # Not a state Incus's own refusals can produce — it has just accepted the
      # delete, and neither of the rename's two refusals (target exists, source
      # missing) applies. A transient daemon error, then, and the report says
      # what the run actually left rather than what it set out to do.
      echo "WARNING: $label had box-net in use, so the unused box-profile was removed to" >&2
      echo "         make room — and the rename onto it then failed. The old name is" >&2
      echo "         still there and this project is NOT converged. In a user-<uid>" >&2
      echo "         project box-net is now the ONLY profile, and 'box new' there will" >&2
      echo "         not find one until this is cleared ('default' gets its copy back" >&2
      echo "         from this run's own create-if-missing, a few lines below)." >&2
      echo "         Converge it by hand, or re-run this script:" >&2
      echo "           incus --project $project profile rename box-net box-profile" >&2
      PROFILE_HALFDONE="$PROFILE_HALFDONE${PROFILE_HALFDONE:+ }$project"
      return 0
    fi

    # Both names are in use: some boxes are placed on each, and no ordering of
    # delete and rename converges that. Moving instances between profiles is
    # the reassignment pass D4 rules out, so this run reports the residue
    # rather than claiming a convergence it did not perform. Not fatal HERE —
    # the rest of the stack still converges — but the run does not end green:
    # PROFILE_UNCONVERGED is what suppresses 'Host ready' at the bottom.
    echo "WARNING: $label carries BOTH box-profile and box-net, and neither can be" >&2
    echo "         removed — boxes are placed on each. Name them with:" >&2
    echo "           incus --project $project profile show box-net" >&2
    echo "           incus --project $project list --format csv --columns nP" >&2
    PROFILE_UNCONVERGED="$PROFILE_UNCONVERGED${PROFILE_UNCONVERGED:+ }$project"
    return 0
  fi

  # The ordinary upgrade: one rename, and every attached box keeps its
  # placement across it. That is measured, not assumed (#229 D6): Incus stores
  # the instance-profile association by profile id in instances_profiles, and
  # the rename is an UPDATE of the name column alone, identical on main and on
  # the stable-6.0 line this script's 'apt-get install -y incus' lands. So
  # unlike the bridge's ipv4.address above, this convergence cannot move
  # anything out from under a running fleet, and needs no reassignment pass.
  incus --project "$project" profile rename box-net box-profile
  echo "profile: renamed box-net -> box-profile in $label (#229)"
}

# Every project, not just 'default'. 'box grant' installs a COPY of this
# profile into each user-<uid> project and refreshes it on every re-run, so new
# and re-run grants land on the new name by themselves — but an existing grant
# nobody re-runs would keep a stale box-net forever, which is precisely the
# claude-dev residue #226 is deleting. Converging only 'default' would repeat
# it exactly.
#
# The trap in the listing: Incus marks the session's own project by appending
# " (current)" to the name in the CSV, so the column is stripped before it is
# used as a project name — unstripped, 'default (current)' names no project
# and every convergence below it silently does nothing.
#
# The listing is READ FIRST and checked, not piped straight into the loop. A
# 'project list' that fails and a host with no grants both hand the loop an
# empty stream, and the '|| true' that keeps grep's no-match clear of 'set -e'
# closes over the difference — so piped, a daemon that cannot answer converges
# zero user-<uid> projects and the run goes on to print 'Host ready' having
# checked none of them. That is the same rule the bridge's 'network show'
# above already holds (#227): an unreadable read is not an empty result. An
# empty answer counts as unreadable too — a daemon that can list projects at
# all lists 'default', so nothing is the shape of a broken read, not of a
# host without grants (#229, round 2).
converge_profile_name default "the default project"
if PROJECT_CSV="$(incus project list --format csv 2>/dev/null)" && [ -n "$PROJECT_CSV" ]; then
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    converge_profile_name "$project" "project $project"
  done < <(printf '%s\n' "$PROJECT_CSV" | cut -d, -f1 | sed 's/ (current)$//' | grep '^user-' || true)
else
  echo "WARNING: 'incus project list' answered nothing, so the granted user-<uid>" >&2
  echo "         projects could not be enumerated and NONE of them was converged." >&2
  echo "         The default project was. Check the daemon and run this again:" >&2
  echo "           incus project list" >&2
  PROJECTS_UNREAD=1
fi

if ! incus profile show box-profile >/dev/null 2>&1; then
  incus profile create box-profile
fi
incus profile edit box-profile < "$here/profiles/box-profile.yaml"

# The sibling drop is the one rule whose absence is invisible: everything keeps
# working, and boxes can simply reach each other. Assert it landed.
if $SUDO nft list table bridge box >/dev/null 2>&1; then
  echo "Isolation: box-to-box drop is live (nft bridge table 'box')."
else
  echo "WARNING: the box-to-box drop is NOT active — boxes can reach each other." >&2
  echo "         check: sudo /usr/local/sbin/box-firewall ; sudo nft list table bridge box" >&2
fi

# The one contract key this run deliberately left drifted, restated where it
# will still be on screen: the detection happens ~100 lines of install output
# ago, and a warning that scrolled away is a warning nobody read (#227).
if [ -n "${BOXNET_IPV4_DRIFT:-}" ]; then
  echo "WARNING: boxnet's ipv4.address is still $BOXNET_IPV4_DRIFT, not $BOX_GW/24 —" >&2
  echo "         this run refused to renumber the bridge. See the WARNING further up" >&2
  echo "         for why, and for the single command that converges it." >&2
fi

# The rename is the one convergence this run can fail to perform while every
# other piece of the stack lands, so it is the one that decides whether the run
# gets to say it converged. 'Host ready' is that claim; a host still carrying
# both names is not entitled to it, however well the rest went (#229 round 1).
# Each of the three ways it can end short reports separately and in full — a
# run that hit two of them owes the operator both remedies — and the exit is
# taken once, below them (#229 round 2).
if [ -n "$PROFILE_UNCONVERGED" ]; then
  echo "" >&2
  echo "NOT converged: the placement contract still has two names in: $PROFILE_UNCONVERGED" >&2
  echo "         Boxes are placed on box-profile AND on box-net there, so neither can be" >&2
  echo "         removed and no rename converges them. Move the stragglers onto" >&2
  echo "         box-profile — for each box the second command names:" >&2
  echo "           incus --project <project> list --format csv --columns nP" >&2
  echo "           incus --project <project> profile assign <box> box-profile" >&2
  echo "         then run this script again. Everything else on this host is set up;" >&2
  echo "         this run does not report ready because the rename did not converge." >&2
fi

# The half-done one: the old name's copy went, the rename after it did not, and
# the project is left carrying box-net alone. The next run converges it by the
# ordinary path — box-net present, box-profile gone, one rename — so the
# remedy is genuinely just to run this again once the daemon is well.
if [ -n "$PROFILE_HALFDONE" ]; then
  echo "" >&2
  echo "NOT converged: box-profile was removed to make room for the rename, and the" >&2
  echo "         rename then failed, in: $PROFILE_HALFDONE" >&2
  echo "         Those projects carry box-net alone and have no profile for 'box new'" >&2
  echo "         to place a box on. Running this script again converges them by the" >&2
  echo "         ordinary rename; the WARNING further up names the single command if" >&2
  echo "         you would rather do it by hand." >&2
fi

# ...and the quietest: the run never learned which projects it owed a
# convergence to. 'Host ready' would be a claim about every granted user, made
# by a run that looked at none of them, so it is not made here either.
if [ -n "$PROJECTS_UNREAD" ]; then
  echo "" >&2
  echo "NOT converged: the granted user-<uid> projects could not be listed, so this run" >&2
  echo "         does not know whether any of them still carries box-net. It converged" >&2
  echo "         the default project and nothing else. Everything else on this host is" >&2
  echo "         set up; this run does not report ready because it cannot say the" >&2
  echo "         placement contract has one name on it. Check the daemon:" >&2
  echo "           incus project list" >&2
  echo "         then run this script again." >&2
fi

if [ -n "$PROFILE_UNCONVERGED$PROFILE_HALFDONE$PROJECTS_UNREAD" ]; then
  exit 1
fi

echo "Host ready. Launch with: box new --name <box>"
