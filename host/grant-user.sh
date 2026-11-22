#!/usr/bin/env bash
# box grant <user> — give a host user the restricted tier (#74).
#
# The tier rides incus-user: the user lands in an auto-created project
# user-<uid> and can only ever see their own instances. What incus-user does
# NOT do is put them on box's hardened network — it auto-creates a private
# bridge incusbr-<uid> (a plain NAT bridge: no ACL, no DNS isolation, IPv6 on,
# none of box's contract) and pins the project to it. Measured on Debian 13 /
# Incus 6.0.4; the full write-up is in docs/plans/2026-07-18-restricted-tier.md.
#
# So granting is a per-user CONVERGENCE, and it must be run by an admin:
#   1. put the user in the 'incus' group (not incus-admin — that is the tier).
#      An incus-admin member goes in too, and NOT for privilege: incus-user's
#      socket is a FILE, group 'incus', mode 0660, so the membership is the
#      only thing that lets step 2 connect() at all (#99, #101 review)
#   2. touch incus-user AS the user, so the lazy project exists to converge
#   3. unpin the private bridge (drop eth0 from the project's default profile)
#   4. restrict the project's network access to boxnet and ONLY boxnet —
#      "boxnet,incusbr-<uid>" would leave an unhardened NAT bridge one
#      '--network' flag away from any box they mint
#   5. allow snapshots (incus-user blocks them; box's clone workflow is built
#      on them)
#   6. allow backups (blocked too; 'box export' rides the backup API — #70)
#   7. install the shipped box-profile profile into their project
#
# Idempotent: every step converges, so re-running (including after a box
# upgrade, to refresh the profile) is safe. incus-user never rewrites a
# project it already created (verified against its source: setup is skipped
# once the project exists and the user's certificate is trusted), so nothing
# here is fighting a re-sync.
set -euo pipefail

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
here="$(dirname "$(dirname "$self")")"

usage() {
  echo "usage: box grant [--service [--share GROUP | --unshare]] [--pool NAME --pool-size SIZE] [--memory SIZE|none] [--cpu N|none] [--instances N|none] <user>" >&2
  exit 2
}

# --service (#281): the user is a SERVICE, not a person — a no-login system
# account a daemon runs as (gig or crew, heavy-duty/handbook proposal 0011).
# Three things differ, each bought by how a person's grant would break it:
#   · no usable home: the user-side incus calls get a throwaway HOME and
#     INCUS_CONF, because the CLI wants ~/.config/incus before it connects and
#     a --system account has none (the old '|| true' then blamed incus-user);
#   · no host paths: incus-user's default lets a user attach disks under its
#     home, which for a service means its own secrets mounted into an untrusted
#     instance — the project is pinned to restricted.devices.disk=managed;
#   · grant-then-start: a systemd service reads its groups once, at start, and
#     a service that touches incus-user before the grant creates an unhardened
#     project — the grant says so, and warns if the user already runs.
service=0
user=""
# --pool/--pool-size (#282) and the caps (#283) converge only when given: a
# re-run without them leaves what an earlier grant set (the pool is read back
# from the project's user.box.pool marker for the profile's root, below).
pool=""; pool_size=""; cap_memory=""; cap_cpu=""; cap_instances=""
# --share GROUP / --unshare (#287): a shared tenant is a service grant a group
# operates through 'box --as'. Converged only when given, like the pool.
share_group=""; unshare=0
need_val() {
  if [ "$#" -lt 2 ] || [ -z "$2" ] || [ "${2#-}" != "$2" ]; then echo "box grant: $1 needs a value" >&2; usage; fi
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --service) service=1 ;;
    --pool)        need_val "$@"; pool="$2"; shift ;;
    --pool-size)   need_val "$@"; pool_size="$2"; shift ;;
    --memory)      need_val "$@"; cap_memory="$2"; shift ;;
    --cpu)         need_val "$@"; cap_cpu="$2"; shift ;;
    --instances)   need_val "$@"; cap_instances="$2"; shift ;;
    --share)       need_val "$@"; share_group="$2"; shift ;;
    --unshare)     unshare=1 ;;
    -*) usage ;;
    *) [ -z "$user" ] || usage; user="$1" ;;
  esac
  shift
done
[ -n "$user" ] || usage

if [ -n "$share_group" ] || [ "$unshare" -eq 1 ]; then
  [ "$service" -eq 1 ] || { echo "box grant: --share and --unshare are for service grants (--service): a person's project is theirs alone" >&2; exit 2; }
  if [ -n "$share_group" ] && [ "$unshare" -eq 1 ]; then echo "box grant: --share and --unshare together make no sense" >&2; exit 2; fi
fi
if [ -n "$share_group" ]; then
  [[ "$share_group" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "box grant: --share needs a group name, got '$share_group'" >&2; exit 2; }
fi
share_bin="${BOX_SHARE_BIN:-/usr/local/bin/box}"
share_dir="${BOX_SHARE_DIR:-/etc/box/shares}"
sudoers_d="${BOX_SUDOERS_D:-/etc/sudoers.d}"

# Sizes are Incus's own spelling (bytes, or N with kB/MB/GB/TB or KiB/MiB/GiB/
# TiB); to_bytes is the one reader, so a check and a comparison never disagree.
size_re='^[0-9]+(B|kB|KB|MB|GB|TB|KiB|MiB|GiB|TiB)?$'
to_bytes() {
  local v="$1" n u
  n="${v%%[!0-9]*}"; u="${v#"$n"}"
  case "$u" in
    ""|B) echo "$n" ;;
    kB|KB) echo $((n*1000)) ;;      MB) echo $((n*1000**2)) ;;
    GB) echo $((n*1000**3)) ;;      TB) echo $((n*1000**4)) ;;
    KiB) echo $((n*1024)) ;;        MiB) echo $((n*1024**2)) ;;
    GiB) echo $((n*1024**3)) ;;     TiB) echo $((n*1024**4)) ;;
    *) return 1 ;;
  esac
}
if [ -n "$pool" ] || [ -n "$pool_size" ]; then
  if [ -z "$pool" ] || [ -z "$pool_size" ]; then echo "box grant: --pool and --pool-size go together" >&2; exit 2; fi
  [[ "$pool" =~ ^[a-z][a-z0-9-]{0,62}$ ]] || { echo "box grant: --pool must be a lower-case name (letters, digits, '-'), got '$pool'" >&2; exit 2; }
  [ "$pool" != default ] || { echo "box grant: --pool default is the host's shared pool — a grant pool is its own" >&2; exit 2; }
  if ! [[ "$pool_size" =~ $size_re ]] || [ "${#pool_size}" -gt 12 ]; then
    echo "box grant: --pool-size must be a size like 200GiB, got '$pool_size'" >&2; exit 2
  fi
fi
[ -z "$cap_memory" ] || [ "$cap_memory" = none ] || { [[ "$cap_memory" =~ $size_re ]] && [ "${#cap_memory}" -le 12 ]; } \
  || { echo "box grant: --memory must be a size like 16GiB, or none — got '$cap_memory'" >&2; exit 2; }
for c in "cpu:$cap_cpu" "instances:$cap_instances"; do
  v="${c#*:}"; [ -z "$v" ] || [ "$v" = none ] || [[ "$v" =~ ^[1-9][0-9]{0,4}$ ]] \
    || { echo "box grant: --${c%%:*} must be a whole number, or none — got '$v'" >&2; exit 2; }
done

# Root, or sudo — same decision, same reasons as setup-host.sh: granting
# needs usermod and a run-as-the-user touch, both root's to give.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  echo "ERROR: box grant needs root and 'sudo' was not found." >&2
  echo "       re-run as root: $self $user" >&2
  exit 1
fi

# Run a command as the granted user. 'runuser' when we are root (sudo may not
# exist there), sudo -u otherwise. -H so incus's client state lands in THEIR
# home, not the admin's. stdin pinned: an incus client with a terminal on
# stdin can go interactive and wedge a script that will never answer it.
# The throwaway home a service's user-side incus calls run with (#281): made
# below, once the user is known, and removed on every exit path.
svc_home=""
run_as() {
  local u="$1"; shift
  if [ -n "$svc_home" ]; then set -- env HOME="$svc_home" INCUS_CONF="$svc_home/incus" "$@"; fi
  if [ -n "$SUDO" ]; then $SUDO -u "$u" -H -- "$@" </dev/null
  else runuser -u "$u" -- "$@" </dev/null
  fi
}

getent passwd "$user" >/dev/null || { echo "box grant: no such user: $user" >&2; exit 1; }
uid="$(id -u "$user")"
[ "$uid" -eq 0 ] && { echo "box grant: root does not need a tier — UID 0 owns the daemon socket outright." >&2; exit 1; }

# An incus-admin member gets the full convergence anyway (#99). This used to
# be a hard refusal, on the reasoning that admin membership wins at the socket
# so nothing here could restrict them. True — and beside the point, because it
# conflates the two separate things a grant hands over:
#   · PERMISSION — the 'incus' group. At the DAEMON API they already hold
#     strictly more through incus-admin, so this group adds no privilege. It
#     is still required, because the two sockets are two FILES with two
#     different owning groups (Debian 13 / Incus 6.0.4, measured):
#         /var/lib/incus/unix.socket       group incus-admin  0660
#         /var/lib/incus/unix.socket.user  group incus        0660
#     incus-admin opens the first and not the second, and the second is the
#     only one that provisions a user-<uid> project. An earlier revision of
#     this script skipped the usermod for an admin member, reasoning that
#     'incus' is a subset of incus-admin — true of the API, false of the
#     filesystem: the pinned touch below took EACCES, the '|| true' swallowed
#     it, no project appeared, and the grant died blaming a healthy
#     incus-user. So the group step is a real convergence for everyone.
#   · PROVISIONING — the user-<uid> project, the boxnet narrowing, the
#     snapshot and backup allowances, the box-profile profile installed INTO that
#     project. An incus-admin member has none of it: box_tier() resolves them
#     to 'admin' (bin/box), so they work in the SHARED default project next to
#     root and every other admin, with no world of their own. This script is
#     the only thing that provisions one, and refusing left them unable to get
#     it without first being taken out of incus-admin.
# So provision, and say plainly at the end what the provisioning does not do.
admin_member=0
if id -nG "$user" | tr ' ' '\n' | grep -qx incus-admin; then
  admin_member=1
fi
# A service in incus-admin is not fenced by anything this grant converges: the
# admin socket wins (see the caveat at the end). The whole point of a service
# grant is the fence, so refuse rather than hand out a project that binds
# nothing (#281).
if [ "$service" -eq 1 ] && [ "$admin_member" -eq 1 ]; then
  echo "box grant --service: $user is in 'incus-admin', which no grant can fence; remove it first:  gpasswd -d $user incus-admin" >&2
  exit 1
fi
if [ "$service" -eq 1 ] && pgrep -u "$user" >/dev/null 2>&1; then
  echo "box grant --service: WARNING — processes owned by $user are running; they hold the groups they" >&2
  echo "           started with. Restart the service after this grant (a service reads its groups at start)." >&2
fi

# The stack the tier converges ONTO must exist first. Checked via the daemon,
# not config files: setup-host is the only thing that builds boxnet.
incus network show boxnet >/dev/null 2>&1 </dev/null \
  || { echo "box grant: no boxnet on this host — build the stack first: box setup-host" >&2; exit 1; }

# incus-user is the mechanism under the whole tier. Debian 13 and Ubuntu 24.04
# ship it in the incus package; a host without it cannot hold this tier at all.
if ! systemctl is-active --quiet incus-user.socket; then
  $SUDO systemctl enable --now incus-user.socket 2>/dev/null \
    || { echo "box grant: incus-user.socket is not available — this Incus cannot serve the restricted tier (see #74)." >&2; exit 1; }
fi

# 1. The group. 'incus' is the restricted socket; membership takes effect at
# the user's next login, but run_as below starts a fresh process with the
# database's groups, so the grant itself never waits on a re-login.
#
# If THIS run granted the group and a later step fails, take it back on the
# way out: a half-granted user would otherwise hold live socket access to an
# UN-NARROWED project — the stock unhardened bridge attachable — until an
# admin re-runs. Backing out the group closes that window completely for a
# fresh grant (their existing sessions predate the membership, so no process
# holds it yet). A user who was already in the group keeps it: not ours to
# take on a re-run's failure. An incus-admin member now takes those same two
# paths (#101): the membership IS added for them and so IS backed out, with
# one thing extra to say either way — the rollback closes incus-user's socket
# and never their daemon access, which outlives this failure by a route the
# script never granted and must not pretend to control.
added_group=0; was_member=0
backout() {
  if [ "$added_group" -eq 1 ]; then
    $SUDO gpasswd -d "$user" incus >/dev/null 2>&1 || true
    # VERIFY the removal — an unverified rollback printing a security
    # guarantee is a lie waiting for its day. Exact-token match, live DB.
    if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx incus; then
      echo "box grant: ROLLBACK INCOMPLETE — the grant failed AND $user is still in the 'incus' group." >&2
      echo "           remove it by hand NOW:  gpasswd -d $user incus   (then fix the cause and re-run)" >&2
      exit 1
    fi
    echo "box grant: FAILED — removed $user from 'incus' again (verified against the group database); fix the cause and re-run" >&2
    if [ "$admin_member" -eq 1 ]; then
      # The rollback is real and verified, but for an admin member it is not a
      # lockout and must not read as one: what came back was incus-user's
      # socket key, not the daemon. Say what survives, and what would end it.
      echo "box grant: NOTE — that rollback closed incus-user's socket, NOT $user's access." >&2
      echo "           They keep full admin socket access throughout via 'incus-admin', which this run" >&2
      echo "           neither granted nor removed, so every project on this host stays open to them." >&2
      echo "           Their project may be part-converged; a re-run converges the rest. To close their" >&2
      echo "           access you must take the admin group itself:  gpasswd -d $user incus-admin" >&2
    fi
    # The one window the database cannot close: a login STARTED between our
    # usermod and this backout keeps the group in its session credentials.
    # For a fresh grant that is a rare race, but rare is not never — name it
    # and the remedy instead of overclaiming.
    if pgrep -u "$user" >/dev/null 2>&1; then
      echo "box grant: NOTE — $user has live processes; a session begun during this grant would still hold" >&2
      echo "           the group until it ends:  sudo loginctl terminate-user $user" >&2
    fi
  elif [ "$was_member" -eq 1 ]; then
    # A user who was ALREADY in the group keeps it — stripping a membership
    # this run did not add could break a working user over a failed re-run.
    # But silence here would leave them holding a socket onto part-converged
    # policy without the admin being told. Loud, with both remediations.
    echo "box grant: FAILED with $user still holding socket access (their membership predates this run)." >&2
    echo "           their project may be part-converged — harmless in itself, and a re-run converges the rest." >&2
    echo "           if their access is not acceptable while you fix the cause:  box revoke $user" >&2
    if [ "$admin_member" -eq 1 ]; then
      # Same correction as above, for the member who was in BOTH groups before
      # this run: 'box revoke' takes the 'incus' key back, and still leaves
      # them the whole daemon.
      echo "box grant: NOTE — $user is also in 'incus-admin', which this run neither granted nor removed:" >&2
      echo "           'box revoke' takes back incus-user's socket key and nothing more. To close their" >&2
      echo "           access:  gpasswd -d $user incus-admin" >&2
    fi
  fi
}
# A service's throwaway home, owned by it (the CLI writes its config there).
# Under /tmp explicitly: root's own $TMPDIR may be a 0700 per-user dir
# (libpam-tmpdir's /tmp/user/0) the service could never enter. Every step is
# $SUDO's: a non-root admin runs this script too. The trap is set FIRST, and
# a failed cleanup can never skip the group backout.
cleanup_svc_home() { [ -z "$svc_home" ] || $SUDO rm -rf -- "$svc_home" || true; }
trap 'cleanup_svc_home || true; backout' EXIT
if [ "$service" -eq 1 ]; then
  svc_home="$($SUDO mktemp -d /tmp/box-grant.XXXXXX)"
  $SUDO chown "$user" "$svc_home"
fi

if id -nG "$user" | tr ' ' '\n' | grep -qx incus; then
  was_member=1
  echo "group: $user already in 'incus'"
else
  $SUDO usermod -aG incus "$user"
  added_group=1
  if [ "$admin_member" -eq 1 ]; then
    # Say why, because the group list alone would imply a restriction that is
    # not in force — the concern the old no-op was built around. It was a
    # cosmetic concern and this is where it gets carried: in output, not in a
    # skipped mutation that broke the mechanism.
    echo "group: added $user to 'incus' — NOT a new privilege ('incus-admin' already opens the daemon,"
    echo "       and box_tier still reads them as 'admin'), but the key to a FILE: incus-user's socket is"
    echo "       group 'incus' mode 0660, and nothing below can provision $user without it"
  else
    echo "group: added $user to 'incus' (their next login picks it up; the grant does not wait)"
  fi
fi

project="user-$uid"

# The incus CLI picks its socket by WRITABILITY, not by intent: with no
# INCUS_SOCKET set it takes $INCUS_DIR/unix.socket when that is writable and
# only falls back to unix.socket.user when it is not (client/connection.go,
# stable-6.0 — the same branch that then defaults the project to user-<uid>).
# For a plain 'incus' member the fallback fires and every command below lands
# where we want it. For an incus-admin member the daemon socket IS writable,
# so an unpinned client sails straight past incus-user — the touch would not
# provision anything and the grant would die claiming incus-user was
# unhealthy. Pin the socket for them, by incus's own directory rule.
# INCUS_DIR first, then /run/incus if the daemon socket lives there, else
# /var/lib/incus: incus's resolution order, not an approximation of it — the
# pinned path has to name the same directory the client would have chosen.
user_socket=""
if [ "$admin_member" -eq 1 ]; then
  incus_dir="${INCUS_DIR:-}"
  if [ -z "$incus_dir" ]; then
    incus_dir="/var/lib/incus"; [ -e /run/incus/unix.socket ] && incus_dir="/run/incus"
  fi
  user_socket="$incus_dir/unix.socket.user"
  # $SUDO test, not a bare [ -e ]: revoke-user.sh documents from measurement
  # that /var/lib/incus is not traversable by a non-root admin, so an
  # unprivileged stat answers "absent" for a socket that is very much there —
  # and this check EXITS on absent. Same discipline, same reason (#101 review).
  $SUDO test -e "$user_socket" \
    || { echo "box grant: incus-user is active but $user_socket is not there — nothing can provision $project (journalctl -u incus-user)" >&2; exit 1; }
fi

# Run the incus CLI as the granted user, on the socket that will actually
# serve them: pinned to incus-user for an admin member, left to the CLI's own
# resolution for everyone else (whose fallback already gets it right).
run_as_incus() {
  if [ -n "$user_socket" ]; then run_as "$user" env INCUS_SOCKET="$user_socket" "$@"
  else run_as "$user" "$@"
  fi
}

# 2. The project is created LAZILY, on the user's first contact with
# incus-user — an admin cannot pre-create it (incus-user would fight over
# it), so make that first contact happen now, as the user.
preexisting=0
if ! incus project show "$project" >/dev/null 2>&1 </dev/null; then
  echo "project: touching incus-user as $user to create $project..."
  # The touch's own stderr is kept (#281): swallowed, a client that failed
  # before it ever connected (no home for its config) read as incus-user's fault.
  touch_rc=0
  touch_err="$(run_as_incus timeout 60 incus project list 2>&1 >/dev/null)" || touch_rc=$?
  if ! incus project show "$project" >/dev/null 2>&1 </dev/null; then
    echo "box grant: incus-user did not create $project — is incus-user.socket healthy? (journalctl -u incus-user)" >&2
    if [ "$touch_rc" -eq 124 ]; then
      echo "  the touch as $user timed out after 60s" >&2
    elif [ -n "$touch_err" ]; then
      echo "  the touch as $user said: $touch_err" >&2
    fi
    exit 1
  fi
  echo "project: $project created"
else
  preexisting=1
  echo "project: $project already exists"
fi

# 3. Unpin the private bridge. incus-user's default profile carries an eth0
# on incusbr-<uid>; while ANY profile references that bridge, the narrowing
# below is rejected by incus's own validation. Removing the device is also
# what it looks like: the default profile in this project places no network —
# box-profile is the only door, which is the placement contract working.
if incus --project "$project" profile device get default eth0 type >/dev/null 2>&1 </dev/null; then
  incus --project "$project" profile device remove default eth0 >/dev/null </dev/null
  echo "profile: removed the private-bridge eth0 from $project's default profile"
fi

# 4. boxnet, and ONLY boxnet. The auto-created incusbr-<uid> is a stock NAT
# bridge with none of box's hardening — listing it here would keep a
# one-flag escape from the isolation contract open forever. Narrowed, the
# hardened network is not the default placement but the only one possible.
# This can fail honestly: an instance the user already parked on the private
# bridge blocks the narrowing, and incus's error names it.
if ! err="$(incus project set "$project" restricted.networks.access boxnet 2>&1 </dev/null)"; then
  echo "box grant: could not restrict $project to boxnet:" >&2
  echo "  $err" >&2
  echo "  (an instance still on the private bridge blocks this — move or delete it, then re-run)" >&2
  exit 1
fi
# The private bridge's name follows incus-user's own rule (revoke-user.sh
# mirrors it too): incusbr-<uid>, or user-<uid> when that would not fit an
# interface name — naming the wrong one here would be a true claim with the
# wrong noun on big-uid (SSSD/AD) hosts.
bridge="incusbr-$uid"; [ "${#bridge}" -gt 15 ] && bridge="user-$uid"
echo "network: $project restricted to boxnet (the private $bridge is unreferenced and unreachable)"

# 5. Snapshots. incus-user projects block them by default, and box's whole
# reuse story — log in once, snapshot, clone forever — is snapshots.
incus project set "$project" restricted.snapshots allow </dev/null
echo "snapshots: allowed"

# 6. Backups. 'box export' rides incus's backup API — an export IS "create a
# backup, download it, delete it" — and a restricted project blocks that by
# default: restricted.backups=block the moment restricted=true (incus 6.0,
# internal/server/project/permissions.go, enforced by AllowBackupCreation).
# 'box import' needs no key of its own — restoring a backup file is plain
# instance creation. Same convergence as snapshots, for the same reason: the
# tier is the same workflows on your own boxes, and export/import are
# workflows (#70).
incus project set "$project" restricted.backups allow </dev/null
echo "backups: allowed ('box export' rides them, #70)"

# 6b. A pool of the grant's own (#282). A full tenant pool then fails that
# tenant and never 'default', which carries every other guest. Created as a
# btrfs loop file of the given size, or adopted when an earlier grant of THIS
# user made it (the user.box.grant marker); anything else is refused and never
# resized or deleted here. Confinement is limits.disk.pool.<other>=0 for every
# other pool, which needs the projects_limits_disk_pool API extension.
if [ -n "$pool" ]; then
  # Captured, never piped into grep -q: under pipefail an early-exiting grep
  # SIGPIPEs the much longer 'incus info' and the check reads as a refusal.
  server_info="$(incus info </dev/null 2>/dev/null || true)"
  grep -Eq '^[[:space:]]*-[[:space:]]+projects_limits_disk_pool[[:space:]]*$' <<<"$server_info" \
    || { echo "box grant --pool: this Incus lacks the projects_limits_disk_pool extension (Incus 6.0 LTS has it) — cannot confine $project to one pool" >&2; exit 1; }
  if incus storage show "$pool" >/dev/null 2>&1 </dev/null; then
    driver="$(incus storage show "$pool" </dev/null | awk '/^driver:/{print $2}')"
    owner="$(incus storage get "$pool" user.box.grant </dev/null 2>/dev/null || true)"
    have="$(incus storage get "$pool" size </dev/null 2>/dev/null || true)"
    [ "$owner" = "$user" ] || { echo "box grant --pool: pool '$pool' exists and is not $user's grant pool (user.box.grant=${owner:-unset}) — choose another name" >&2; exit 1; }
    [ "$driver" = btrfs ] || { echo "box grant --pool: pool '$pool' is $driver, not btrfs" >&2; exit 1; }
    if [ -z "$have" ] || [ "$(to_bytes "$have" 2>/dev/null || echo 0)" -lt "$(to_bytes "$pool_size")" ]; then
      echo "box grant --pool: pool '$pool' is ${have:-of unknown size}, smaller than $pool_size — box never resizes a pool; grow it by hand or pick a smaller --pool-size" >&2; exit 1
    fi
    echo "pool: $pool already exists ($have, btrfs, $user's)"
  else
    if ! err="$(incus storage create "$pool" btrfs size="$pool_size" </dev/null 2>&1)"; then
      echo "box grant --pool: could not create pool '$pool': $err" >&2; exit 1
    fi
    incus storage set "$pool" user.box.grant "$user" </dev/null
    echo "pool: created $pool ($pool_size btrfs loop file) for $user"
  fi
  incus project unset "$project" "limits.disk.pool.$pool" </dev/null 2>/dev/null || true
  while read -r other; do
    if [ -z "$other" ] || [ "$other" = "$pool" ]; then continue; fi
    incus project set "$project" "limits.disk.pool.$other" 0 </dev/null
  done < <(incus storage list --format csv -c n </dev/null)
  # Incus enforces per-pool limits ONLY when the project also sets limits.disk
  # (AllowVolumeCreation returns early without it — measured in the
  # rehearsal, and read in internal/server/project/permissions.go). So the
  # pool's size is the project's total disk budget too; without it the zero
  # limits above would bind nothing.
  if ! err="$(incus project set "$project" limits.disk "$pool_size" </dev/null 2>&1)"; then
    echo "box grant --pool: could not set limits.disk=$pool_size on $project: $err" >&2; exit 1
  fi
  incus project set "$project" user.box.pool "$pool" </dev/null
  echo "pool: $project confined to $pool (limits.disk=$pool_size, every other pool's limit is 0; re-run the grant after adding a pool)"
fi

# 6c. Caps (#283): the project's own limits.* — 'none' unsets. Incus then
# refuses any instance that does not set limits.cpu/limits.memory itself or
# by profile; 'box new' always stamps both, and so must a tool's profiles.
for c in "memory:$cap_memory" "cpu:$cap_cpu" "instances:$cap_instances"; do
  k="limits.${c%%:*}"; v="${c#*:}"
  [ -n "$v" ] || continue
  if [ "$v" = none ]; then
    incus project unset "$project" "$k" </dev/null 2>/dev/null || true
    echo "caps: $k unset"
  elif ! err="$(incus project set "$project" "$k" "$v" </dev/null 2>&1)"; then
    echo "box grant: could not set $k=$v on $project: $err" >&2
    echo "  (Incus refuses a cap below what the project already uses — see: incus project info $project)" >&2
    exit 1
  else
    echo "caps: $k=$v"
  fi
done

if [ "$service" -eq 1 ]; then
  # No host paths for a service (#281): managed volumes only. An instance that
  # already carries a host-path disk blocks this — say which way out.
  if ! err="$(incus project set "$project" restricted.devices.disk managed 2>&1 </dev/null)"; then
    echo "box grant --service: could not limit $project to managed disks:" >&2
    echo "  $err" >&2
    echo "  (an instance with a host-path disk blocks this — remove the device or the instance, then re-run)" >&2
    exit 1
  fi
  echo "disks: managed volumes only (a service never mounts host paths)"
  # The marker that tells a service grant from a person's (revoke reads it
  # with #285; tools such as gig check it before they act).
  incus project set "$project" user.box.service true </dev/null
  echo "service: $project marked as a service grant"
  if [ "$preexisting" -eq 1 ]; then
    echo "service: $project existed before this grant — every step above re-hardened it"
  fi
fi

# 6d. Sharing (#287). The group may run box — only box, the global install's
# stable path — as this service, and nothing else: no shell, no other command.
# The sudoers drop-in is validated by visudo before it is moved into place, so
# a bad write can never break sudo for the host. The share record beside it is
# world-readable on purpose: 'box --as' reads it to tell a refused user which
# group to join, and sudoers itself is root's to read.
if [ -n "$share_group" ]; then
  getent group "$share_group" >/dev/null || { echo "box grant --share: no such group: $share_group (box never creates host groups; groupadd it first)" >&2; exit 1; }
  [ -x "$share_bin" ] || { echo "box grant --share: $share_bin is not there — sharing needs box installed globally (sudo install.sh), so every member runs the same path" >&2; exit 1; }
  tmp_rule="$sudoers_d/.box-share-$user.tmp"
  printf '# Written by box grant --share (#287); removed by --unshare and revoke.\n%%%s ALL=(%s) NOPASSWD: %s\n' "$share_group" "$user" "$share_bin" \
    | $SUDO tee "$tmp_rule" >/dev/null
  $SUDO chmod 0440 "$tmp_rule"
  if ! $SUDO visudo -cf "$tmp_rule" >/dev/null 2>&1; then
    $SUDO rm -f -- "$tmp_rule"
    echo "box grant --share: the sudoers rule did not validate (visudo -cf) — nothing written" >&2; exit 1
  fi
  $SUDO mv -f -- "$tmp_rule" "$sudoers_d/box-share-$user"
  $SUDO install -d -m 0755 "$share_dir"
  printf '%s\n' "$share_group" | $SUDO tee "$share_dir/$user" >/dev/null
  $SUDO chmod 0644 "$share_dir/$user"
  echo "share: '$share_group' may act as $user through 'box --as $user …' (box only, never a shell)"
  {
    echo "box: ============================== WARNING =============================="
    echo "box: everyone in '$share_group' holds EVERYTHING put inside $user's boxes:"
    echo "box: agent logins, git credentials, SSH keys, shell history — whatever"
    echo "box: anyone left there. A shared box is shared all the way down."
    echo "box: share only what that whole group may hold."
    echo "box: ====================================================================="
  } >&2
elif [ "$unshare" -eq 1 ]; then
  $SUDO rm -f -- "$sudoers_d/box-share-$user" "$share_dir/$user"
  echo "share: $user is no longer shared ('box --as $user' now refuses everyone)"
fi

# 7. The placement contract itself, installed into their project. Created if
# missing, refreshed unconditionally — same convergence discipline as
# setup-host's own profile handling, so a box upgrade propagates by re-run.
incus --project "$project" profile show box-profile >/dev/null 2>&1 </dev/null \
  || incus --project "$project" profile create box-profile >/dev/null </dev/null
incus --project "$project" profile edit box-profile < "$here/profiles/box-profile.yaml"
# The shipped profile roots on 'default'; a grant pool (#282) re-points it, read
# back from the project's marker so a re-run WITHOUT --pool keeps it.
grant_pool="$(incus project get "$project" user.box.pool </dev/null 2>/dev/null || true)"
if [ -n "$grant_pool" ]; then
  incus --project "$project" profile device set box-profile root pool "$grant_pool" </dev/null
  echo "profile: box-profile installed in $project, rooted on $grant_pool"
else
  echo "profile: box-profile installed in $project"
fi

# Prove the grant from the USER's side of the socket — the only side that
# matters. This catches the failure the steps above cannot see one at a time:
# a converged project the user still cannot reach. For an admin member the
# project is named explicitly: an unqualified profile show over the pinned
# incus-user socket asks about 'default', and over their own admin socket it
# would answer from the shared default project — a green that proves the
# convergence nothing at all.
if [ -n "$user_socket" ]; then
  run_as_incus timeout 30 incus --project "$project" profile show box-profile >/dev/null 2>&1 \
    || { echo "box grant: converged, but $user cannot reach $project's box-profile profile through incus-user — check journalctl -u incus-user" >&2; exit 1; }
else
  run_as "$user" timeout 30 incus profile show box-profile >/dev/null 2>&1 \
    || { echo "box grant: converged, but $user cannot see the box-profile profile through incus-user — check journalctl -u incus-user" >&2; exit 1; }
fi

trap - EXIT   # converged and verified: the grant stands
cleanup_svc_home || true
if [ "$service" -eq 1 ]; then
  echo "granted: service $user has its own project $project (boxnet-only, managed disks, box-profile)."
  echo "         It reaches it through incus-user's socket (unix.socket.user) with project=$project;"
  echo "         a Go client needs no config directory."
  echo "         NOW start (or restart) the service: a service reads its groups when it starts."
  exit 0
fi
if [ "$admin_member" -eq 1 ]; then
  # The honest version of what the old refusal was gesturing at. The project
  # is real, converged and theirs — that is what they were missing and what
  # this run supplied. What it is NOT is confinement, in two distinct ways
  # that both come from incus-admin winning at the socket, and both belong in
  # the output rather than in a hard exit:
  #   · nothing here binds them. Every restriction converged above describes
  #     project $project; the default project and every other user's instances
  #     stay one flag away, and no setting inside $project can say otherwise
  #     while they hold that group.
  #   · nothing here even routes them, yet. Their unpinned CLI resolves to the
  #     writable daemon socket and so to the DEFAULT project (the socket rule
  #     cited at step 2), so their 'box new' still lands beside the other
  #     admins' until they either drop incus-admin — at which point this
  #     project becomes their automatic home, no re-run needed — or pin
  #     INCUS_SOCKET at incus-user by hand.
  # That "no re-run needed" is a real promise only because the group step
  # above put them in 'incus' (#101): dropping incus-admin leaves them a
  # plain 'incus' member, which is exactly the tier whose client falls back
  # to unix.socket.user and lands in $project. Under the old no-op they would
  # have been left in NEITHER group — box_tier 'none', no socket at all, and
  # a converged project they could not open.
  echo "granted: $user has their own converged project $project (boxnet-only, snapshots, backups, box-profile)."
  echo "         CAVEAT — $user is in 'incus-admin', which wins at the socket: this is a"
  echo "         DEFAULT PLACEMENT, not a confinement. They can reach the default project and"
  echo "         every other user's instances whenever they choose to."
  echo "         And until incus-admin goes, their own 'box' commands keep landing in the DEFAULT"
  echo "         project — the admin socket is the one their client picks. To make $project theirs"
  echo "         for real:  gpasswd -d $user incus-admin   (no re-grant needed: they keep 'incus', so"
  echo "         their client falls straight back to incus-user and $project is already ready)."
  echo "         'box revoke $user' unwinds this provisioning and takes the 'incus' membership back;"
  echo "         it cannot touch their admin access."
else
  echo "granted: $user has the restricted tier — their 'box new' lands on the hardened boxnet."
  echo "         (their boxes are theirs alone; 'box revoke $user' takes the tier back)"
fi
