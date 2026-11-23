#!/usr/bin/env bash
# doctor.sh — is this host fit to mint boxes (and to drill), and if not, what
# is wrong? Users reach it as 'box doctor'; the drill runs it directly.
#
#   bash drill/doctor.sh          # report
#   bash drill/doctor.sh --fix    # report, then restore what is missing, delete leftovers
#
# --fix has two halves because a host goes wrong in two ways.
#
#   · A RUN LEFT THINGS BEHIND. An aborted drill leaves its boxes (drill,
#     clone, archive, peer, payroll, cbprobe, cbcopy, cbnotours), and an
#     interrupted multiuser.sh leaves its rehearsal users and their projects.
#     --fix deletes the boxes and names the users' own cleanup.
#   · THE HOST IS MISSING SHIPPED STACK PIECES. dns.mode=none, the box-isolate
#     ACL and a gateway carve-out that tracks the live bridge,
#     security.port_isolation on the NIC, a dnsmasq actually serving boxnet.
#     Their ABSENCE is the fault, never their presence, and --fix puts them
#     back.
#
# Either way the host mints boxes on a broken network, and that is not a
# hypothetical. It is how a box came up with no DNS at all
# ("Temporary failure resolving deb.debian.org" in cloud-init), and how a false
# design veto against #16 got posted from a poisoned baseline. A verdict
# measured on a broken baseline is not a verdict, which is why this file exists.
#
# This script is the answer to "what state is the host actually in?" — the
# question that kept getting answered by hand.
#
# ok/no/inf/head_ all return 0, so the 'A && ok "…" || no "…"' idiom this file
# is built on cannot hit the C-may-run-when-A-is-true trap SC2015 warns about
# (same reasoning as drill.sh's ok/no).
# shellcheck disable=SC2015
set -u

FIX=0; PIN=0
case "${1:-}" in
  --fix)     FIX=1 ;;
  --pin-dns) PIN=1 ;;
  "")        ;;
  *) echo "usage: doctor.sh [--fix | --pin-dns]"; exit 2 ;;
esac

bad=0
# Colour resolved once, and dropped for NO_COLOR (set, any value, per the
# convention) or a stdout that is not a terminal (#152). A doctor report is
# pasted into an issue at least as often as it is read on a terminal, and
# escape codes in that paste are noise nobody asked for.
if [ -n "${NO_COLOR+x}" ] || [ ! -t 1 ]; then
  C_G=''; C_R=''; C_B=''; C_0=''
else
  C_G=$'\033[32m'; C_R=$'\033[31m'; C_B=$'\033[1m'; C_0=$'\033[0m'
fi
ok()   { printf '  %sOK%s    %s\n' "$C_G" "$C_0" "$*"; }
no()   { printf '  %sDIRTY%s %s\n' "$C_R" "$C_0" "$*"; bad=$((bad + 1)); }
inf()  { printf '        %s\n' "$*"; }
head_() { printf '\n%s%s%s\n' "$C_B" "$*" "$C_0"; }

# What --fix will NOT touch, and why. A key the tool refuses to change is a
# STATED refusal, never a silent pass — the same rule the drill's probe floor
# and 'drill-recorded' hold: a check that cannot act says so. The verdict has
# to be reachable, and it was not: a report saying "3 problem(s) — run
# doctor.sh --fix" where --fix could only reach one sent the operator round a
# loop this tool already knew the end of (#227). Every refusal registers here
# in BOTH modes — whether --fix can reach a key is a property of the host's
# state, not of the flag — and the verdict names each one.
HELD=""
hold() { HELD="$HELD${HELD:+$'\n'}$*"; inf "--fix cannot reach this: $*"; }

# --- The #80 signature: a nested box stack squatting on the gateway ---------
# setup-host run INSIDE a box builds a nested boxnet on the guest's own uplink
# subnet. The measured mechanism, and the two lines this function reads for:
# hold your own gateway's address and the kernel's local table eats packets
# meant for the real gateway (DNS, unicast DHCP renewals); carry two connected
# routes for the uplink subnet and whichever link last has carrier wins — a
# nested bridge gaining carrier blackholes egress instantly. Pure text in,
# findings out (one per line, silence is clean), so test/cli.sh drives it
# against synthetic route tables and the guest probe can feed it routes read
# INSIDE a box. Inputs: `ip -4 route show` and `ip -4 -o addr show` output.
gw_squat_signature() {
  local routes="$1" addrs="$2" gw updev
  gw="$(printf '%s\n' "$routes" | awk '$1 == "default" { for (i = 1; i < NF; i++) if ($i == "via") { print $(i+1); exit } }')"
  updev="$(printf '%s\n' "$routes" | awk '$1 == "default" { for (i = 1; i < NF; i++) if ($i == "dev") { print $(i+1); exit } }')"
  [ -n "$gw" ] || return 0    # no default route: nothing to squat on
  printf '%s\n' "$addrs" | awk -v gw="$gw" '
    { split($4, a, "/")
      if (a[1] == gw) { print "the default gateway " gw " is held as a LOCAL address (on " $2 ") — the kernel delivers packets meant for the gateway to this machine itself"; exit } }'
  printf '%s\n' "$routes" | awk -v updev="$updev" '
    / proto kernel / && $2 == "dev" {
      cnt[$1]++; devs[$1] = devs[$1] (devs[$1] ? ", " : "") $3
      if ($3 == updev) up = $1
    }
    END { if (up != "" && cnt[up] > 1)
      print "duplicate connected routes for the uplink subnet " up " (" devs[up] ") — whichever link last gains carrier wins, and a nested bridge with carrier blackholes egress" }'
}

# --- The UFW half of the gateway carve-out (#86 review) ---------------------
# setup-host converges the ACL's gateway allow and box-firewall converges
# UFW's — but a doctor that reads only the ACL hands a remapped UFW host a
# clean bill while a stale 'allow … to <old-gw> port 53' quietly drops
# box→gateway DNS. This reads UFW's own table. Pure text in (`ufw status`
# output, the network, the live gateway), findings out (one per line,
# silence is agreement) — the gw_squat_signature seam, so test/cli.sh drives
# it against canned tables. Judged only where UFW is active: the no-UFW nft
# carve-out is interface-scoped (no gateway address to go stale).
ufw_dns_findings() {
  local status="$1" net="$2" gw="$3" allows stale
  allows="$(printf '%s\n' "$status" | awk -v net="$net" '
    $2 ~ /^53\// && $3 == "on" && $4 == net { print $1 }' | sort -u)"
  if [ -z "$allows" ]; then
    # No DNS allow at all is a drop only if OUR deny is there to do the
    # dropping — a UFW host box-firewall never touched has nothing to judge.
    printf '%s\n' "$status" | grep " on $net" | grep -q "DENY" \
      && printf 'UFW denies in on %s with NO DNS allow at all — box DNS to the gateway is dropped\n' "$net"
    return 0
  fi
  if ! printf '%s\n' "$allows" | grep -qxF "$gw"; then
    printf "UFW's DNS allow points at %s — NOT %s's live gateway (%s): box DNS dies at UFW's deny\n" \
      "$(printf '%s' "$allows" | tr '\n' ' ')" "$net" "$gw"
    return 0
  fi
  stale="$(printf '%s\n' "$allows" | grep -vxF "$gw")" || true
  [ -n "$stale" ] \
    && printf "stale UFW DNS allow(s) for %s left beside the live gateway's — box-firewall converges these away now\n" \
         "$(printf '%s' "$stale" | tr '\n' ' ')"
  return 0
}

# --- Where the boxes' root disks actually live (#180) -----------------------
# "My boxes filled the root disk" is a placement question, and answering it
# needed an Incus lesson: the pool declares a driver and, unless setup-host was
# given BOX_STORAGE_SOURCE, no source — so Incus builds it as a loop-backed
# image under its own state directory, on '/'. Pure text in, report lines out
# (the gw_squat_signature seam, so test/cli.sh drives it against canned pool
# config): 'incus storage show <pool>' output in, one line per finding.
#

# The value is read through yaml_scalar and not awk's $2, and that is not
# tidiness: '$2' of "  source: /data/bulk/box pool" is "/data/bulk/box", so
# this section answered "where do my boxes live" with a directory they are not
# in — a wrong answer that looks exactly like a right one (#180, panel round
# 2). Everything after the first ':' is the value, and Incus quotes any value
# plain YAML would mangle, so the quotes come off here: single-quoted is
# literal with '' for a quote, double-quoted needs \" and \\ undone.
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

# The scalar for one key of the pool's config. $1 is the key test, so a key
# indented under 'config:' costs nothing; the value is everything past the
# first colon. A bare pair of quotes is YAML's recorded-but-empty, i.e. the key
# is absent — normalised once, in yaml_scalar, for every key rather than for
# the one that happened to need it. (setup-host.sh carries the same pair: these
# two scripts ship and run independently, as bin/box's storage_driver does.)
yaml_value() {
  local key="$1" show="$2" line
  line="$(printf '%s\n' "$show" | awk -v k="$key:" '$1 == k { sub(/^[[:space:]]*[^:]*:/, ""); print; exit }')"
  yaml_scalar "$line"
}

# The INSTANCES named by a 'used_by:' list — one per line, project-qualified
# where Incus qualifies them, nothing at all when none. Text in, names out, so
# test/cli.sh drives it against canned 'incus network show' output (#227).
#
# One read answers "is anything attached?" because Incus computes used_by from
# every instance's EXPANDED devices: a box that reaches boxnet through the
# box-profile profile — which is every box — is listed here by its own name, beside
# the profiles. Reading the profile entries instead would need the names of the
# restricted tier's per-user profile copies, which 'box grant' creates and this
# script has never known. (setup-host.sh carries the same pair as it does of
# yaml_scalar: these two scripts ship and run independently.)
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

# The report. It JUDGES NOTHING — every line here is informational and none of
# them touch the verdict. Where a pool lives is a choice, not a fault, and a
# doctor that called the shipped loop-backed default DIRTY would red every
# stock host on the day it shipped.
pool_findings() {
  local show="$1" drv src ini
  drv="$(yaml_value driver "$show")"
  src="$(yaml_value source "$show")"
  # The pool made from a block device does NOT report that device: btrfs
  # formats it and overwrites 'source' with the new filesystem's UUID, keeping
  # what it was handed in 'volatile.initial_source'. Reporting the UUID alone
  # answers "where do my boxes live" with a string naming no disk on the host.
  ini="$(yaml_value volatile.initial_source "$show")"
  printf 'driver = %s\n' "${drv:-<unreadable>}"
  # The driver decides whether a clone is near-free; it is the same fact
  # bin/box reads before deciding whether to take a mark (#104, #130).
  [ "$drv" = dir ] && printf "'dir' has no copy-on-write — every snapshot and clone is a FULL copy of a box's root\n"
  if [ -z "$src" ]; then
    printf 'source = <none reported> — the pool is placed under Incus own state directory, on the ROOT filesystem\n'
  else
    printf 'source = %s\n' "$src"
    # The recorded-but-empty initial source every loop-backed pool carries is
    # already absence by here: yaml_scalar reads YAML's bare pair of quotes as
    # the empty string, for this key and for 'source' alike.
    # Past tense, and deliberately: this is the path Incus was HANDED at
    # creation, not a claim about what that name points at today. A device name
    # is assigned in enumeration order and can move across a reboot, while the
    # UUID above cannot — setup-host refuses a re-run it cannot bind back to
    # this filesystem for exactly that reason (#180, panel round 3). This
    # function judges nothing and probes nothing, so it says which fact it has.
    if [ -n "$ini" ] && [ "$ini" != "$src" ]; then
      printf 'made from = %s — the path Incus was given when this pool was created; the source above is the filesystem UUID it wrote onto that device\n' "$ini"
      printf 'a device NAME can move between reboots and that UUID cannot, so check with "lsblk -o NAME,UUID" before trusting the name\n'
    fi
    case "$src" in
      /var/lib/incus/*|/var/lib/lxd/*)
        printf 'that is Incus own state directory: every box root device is charged against "/" — "df -h /" is the number that matters\n'
        printf 'a FRESH host places it elsewhere:  BOX_STORAGE_SOURCE=/dev/sdb box setup-host\n'
        printf 'moving a pool that already carries boxes is a migration, not a re-run (issue #180)\n' ;;
    esac
  fi
  return 0
}

# The signature, probed INSIDE a box: its routes, read where they live. A
# poisoned guest looks healthy from every host-side config check — the nested
# bridge and the captured gateway exist only in the guest's kernel.
probe_sig() {
  local b="$1" routes addrs sig line
  routes="$(timeout -k 5 20 incus exec "$b" -- ip -4 route show </dev/null 2>/dev/null)"
  addrs="$(timeout -k 5 20 incus exec "$b" -- ip -4 -o addr show </dev/null 2>/dev/null)"
  if [ -z "$routes" ]; then
    inf "could not read routes inside '$b' — the #80 signature was not probed"
    return 0
  fi
  sig="$(gw_squat_signature "$routes" "$addrs")"
  if [ -n "$sig" ]; then
    while IFS= read -r line; do no "inside '$b': $line"; done <<<"$sig"
    inf "a box stack was installed INSIDE this box — its nested bridge claims the"
    inf "box's own uplink subnet, and egress blacks out intermittently (issue #80)."
    inf "fix, inside the box:  sudo incus network set boxnet ipv4.address 10.89.0.1/24"
    inf "      (or remove the nested stack there:  box teardown-host)"
  else
    ok "no #80 signature inside '$b' — nothing is squatting on its gateway"
  fi
}

command -v incus >/dev/null || { echo "doctor: incus is not installed on this host."; exit 1; }

# THIS MACHINE first, both tiers, before anything that needs the daemon: the
# #80 signature is a fact about the kernel's routing tables, not about incus —
# and a poisoned guest is exactly where the daemon answering below may be the
# WRONG (nested) one, judging its own impostor stack clean.
head_ "This machine — is a nested box stack squatting on the gateway? (#80)"
sig="$(gw_squat_signature "$(ip -4 route show 2>/dev/null)" "$(ip -4 -o addr show 2>/dev/null)")"
if [ -n "$sig" ]; then
  while IFS= read -r line; do no "$line"; done <<<"$sig"
  inf "a box stack was built on a machine whose uplink already owns its subnet —"
  inf "run inside a box, that is issue #80: egress blacks out intermittently while"
  inf "everything looks healthy. setup-host now auto-picks a free subnet for the"
  inf "nested case, so this stack predates the fix (or was pinned onto the uplink)."
  inf "fix:  move the nested bridge off the uplink's subnet:"
  inf "        sudo incus network set boxnet ipv4.address 10.89.0.1/24"
  inf "      (or remove the nested stack:  box teardown-host)"
else
  ok "the default gateway is not held locally, and the uplink subnet has one connected route"
fi
timeout 10 incus list >/dev/null 2>&1 || {
  echo "doctor: the incus daemon is not answering (see issue #26 for recovery):"
  echo "  sudo pkill -9 -f 'incusd shutdown'"
  echo "  sudo systemctl stop incus.service incus.socket"
  echo "  sudo systemctl reset-failed incus.service incus.socket"
  echo "  sudo systemctl start incus.socket incus.service"
  exit 1
}

# The tier changes what this doctor can SEE, so it changes what it may JUDGE.
# bin/box exports BOX_TIER; unset means a hand-run, which was always admin.
# A restricted (incus-group) user cannot read the nft tables, the kernel's
# bridge ports, or boxnet's (redacted) config — reporting those as DIRTY
# would blame the host for the reader's own, correct, confinement. They get
# the checks that are theirs: is the tier granted, is the contract in their
# project, do their boxes actually resolve and route.
TIER="${BOX_TIER:-admin}"
if [ "$TIER" = restricted ]; then
  head_ "Access tier — restricted (the incus group: your own boxes, nothing else)"
  inf "the host stack (network, ACL, firewall, kernel state) is admin-owned;"
  inf "this doctor judges only what is yours to see"
  if [ "$FIX" = 1 ] || [ "$PIN" = 1 ]; then
    inf "--fix / --pin-dns are admin levers — ignored on this tier"
    FIX=0; PIN=0
  fi

  head_ "Your project — is the tier granted?"
  if incus profile show box-profile >/dev/null 2>&1 </dev/null; then
    ok "the box-profile profile is in your project — 'box new' lands on the hardened boxnet"
    iso="$(incus profile device get box-profile eth0 security.port_isolation </dev/null 2>/dev/null)"
    [ "$iso" = "true" ] \
      && ok "security.port_isolation = true (as shipped)" \
      || no "security.port_isolation is NOT set in your box-profile profile — re-grant refreshes it: ask an admin to re-run 'box grant $(id -un)'"
  elif incus profile show box-net >/dev/null 2>&1 </dev/null; then
    # The tier IS granted — it is wearing the pre-0.10.0 name (#229). Saying
    # "not granted" here would send the operator at the wrong fix: a re-grant
    # would install box-profile beside the stale box-net rather than converge
    # it, and the user would be told nothing about the copy left behind.
    no "your project carries box-net, the pre-0.10.0 name for the placement contract — the tier is granted, but this project did not converge"
    inf "fix:  an admin runs:  box setup-host   (it converges every project, this one included)"
    # 'inf' and not 'hold': HELD is rendered by the admin verdict, which this
    # tier exits before reaching, and the tier banner has already said the
    # --fix lever is ignored here — so hold's "--fix cannot reach this" would
    # be a second saying of it that nothing ever prints (#229, round 1).
    inf "converging it is admin-owned: this tier cannot write another project's profiles"
  else
    no "no box-profile profile in your project — the restricted tier is granted per user"
    inf "fix:  an admin runs:  box grant $(id -un)"
  fi
  if incus network show boxnet >/dev/null 2>&1 </dev/null; then
    ok "boxnet is reachable from your project"
  else
    no "boxnet is not visible from your project — ask an admin to re-run 'box grant $(id -un)'"
  fi

  head_ "Can one of your boxes actually resolve DNS?"
  probe="$(incus list "user.box=1" --format csv --columns ns 2>/dev/null \
           | awk -F, '$2 == "RUNNING" { print $1; exit }')"
  if [ -n "$probe" ]; then
    inf "probing inside '$probe':"
    if timeout -k 5 25 incus exec "$probe" -- curl -sS -m 10 -o /dev/null https://1.1.1.1 </dev/null 2>/dev/null; then
      routing=1; ok "reaches 1.1.1.1 by address — egress routing is fine"
    else
      routing=0; no "cannot reach 1.1.1.1 by address — egress routing is broken (an admin problem: box doctor as admin)"
    fi
    if timeout -k 5 25 incus exec "$probe" -- getent hosts deb.debian.org </dev/null >/dev/null 2>&1; then
      ok "resolves deb.debian.org — DNS works"
      # Egress broken while DNS resolves is #80's fingerprint: an impostor
      # dnsmasq on a captured gateway address answers names happily (it
      # forwards upstream via the default route) while direct IP egress dies.
      [ "$routing" = 0 ] && inf "…egress broken while DNS resolves is #80's fingerprint — the signature probe below answers whether something inside this box squats on its gateway"
    else
      no "CANNOT resolve deb.debian.org — an admin problem (the resolver pin lives on the host): box doctor as admin"
    fi
    probe_sig "$probe"
  else
    inf "no running box to probe with (mint one: box new --name work)"
  fi

  head_ "Verdict"
  if [ "$bad" -eq 0 ]; then
    printf '  %sclean%s — your tier is granted and your boxes are fit.\n\n' "$C_G" "$C_0"
    exit 0
  fi
  printf '  %s%s problem(s)%s — see the fixes above (most need an admin).\n\n' "$C_R" "$bad" "$C_0"
  exit 1
fi

# A FRESH host (no boxnet) is not a DIRTY one. Everything below that would
# scream about a missing piece must first ask: missing from a stack, or never
# set up? setup-host creates all of it, and the drill runs setup-host itself —
# a bare host went 84/84 green minutes after this doctor called it unfit.
FRESH=0

head_ "Network — boxnet"
if incus network show boxnet >/dev/null 2>&1; then
  # dns.mode=none is SHIPPED — it is what stops a box enumerating its siblings
  # through the gateway's dnsmasq. Its ABSENCE is the problem, not its presence.
  dns="$(incus network get boxnet dns.mode 2>/dev/null)"
  if [ "$dns" = none ]; then
    ok "dns.mode = none — a box cannot enumerate its siblings by name"
  else
    no "dns.mode = ${dns:-<unset>} — a box can RESOLVE its siblings' names and addresses"
    inf "fix:  re-run:  box setup-host"
    [ "$FIX" = 1 ] && { incus network set boxnet dns.mode=none && inf "set: dns.mode=none"; }
  fi
  # ipv4.address was PRINTED here and never judged, in a section whose whole
  # job is to judge — so a bridge that had lost the key read as a clean line.
  # It is not cosmetic: the ACL carve-out check below, the UFW check, drill.sh's
  # boxnet_gw and box-firewall all read this key, and an empty one makes each
  # of them skip silently rather than fail. The contract is that the key agrees
  # with the address the bridge actually holds — the same address choose_subnet
  # reads, and the one every rule downstream is derived from (#227).
  #
  # The doctor never DECIDES a subnet: converging means writing back the
  # address the bridge is already on. Deciding is choose_subnet's, in
  # setup-host, and it stays there.
  ipv4="$(incus network get boxnet ipv4.address 2>/dev/null)"
  live="$(ip -4 -o addr show dev boxnet 2>/dev/null | awk '{ print $4; exit }')"
  # A 'show' that answers nothing is not an empty used_by list — the bridge
  # described itself one line ago, so silence here is the daemon, not the
  # fleet, and the safe reply to "may I renumber?" under ignorance is no.
  boxnet_show="$(incus network show boxnet 2>/dev/null)"
  attached="$(used_by_instances "$boxnet_show")"
  if [ -n "$ipv4" ] && { [ -z "$live" ] || [ "$ipv4" = "$live" ]; }; then
    ok "ipv4.address = $ipv4 — the ACL carve-out, the firewall and the drill all read this key"
  else
    if [ -z "$ipv4" ]; then
      no "ipv4.address = <unset> — nothing records the bridge's address, so every check derived from it silently passes"
    else
      no "ipv4.address = $ipv4 but the bridge holds $live — the config and the kernel disagree about the gateway"
    fi
    inf "fix:  re-run:  box setup-host   (it converges this key now, #227)"
    # Writing it RENUMBERS the bridge, so it is the one key here that is not
    # unconditionally safe: every attached box holds a lease on the old subnet.
    # A tool that silently renumbers a running fleet is worse than one that
    # will not — so refuse, out loud, and let the operator choose the moment.
    if [ -z "$boxnet_show" ]; then
      hold "ipv4.address — 'incus network show boxnet' answered nothing, so what is attached is unknown; check the daemon, then re-run --fix"
    elif [ -n "$attached" ]; then
      hold "ipv4.address — $(printf '%s\n' "$attached" | wc -l | tr -d ' ') instance(s) attached to boxnet and writing this key renumbers the bridge; stop them, then re-run --fix"
      inf "attached: $(printf '%s\n' "$attached" | tr '\n' ' ')"
    elif [ -z "$live" ]; then
      hold "ipv4.address — the bridge holds no address here, so there is nothing to converge it TO; 'box setup-host' decides the subnet, this tool never does"
    elif [ "$FIX" = 1 ]; then
      incus network set boxnet ipv4.address="$live" \
        && inf "set: ipv4.address=$live (the address the bridge already holds)"
    fi
  fi
  # Incus reports the network as "Created" whether or not anything is actually
  # SERVING it. Kill the daemon uncleanly (a wedge, an OOM, a SIGKILL) and it
  # can come back without respawning this network's dnsmasq — the bridge is up,
  # the config is perfect, and every box minted afterwards gets NO DHCP lease,
  # so it dies deep inside cloud-init with "Temporary failure resolving
  # deb.debian.org". Two cold mints and an hour of hunting went into learning
  # that Incus's own status does not cover this. Ask the process table instead.
  if pgrep -af 'dnsmasq.*--interface=boxnet' >/dev/null 2>&1; then
    ok "a dnsmasq is serving boxnet (DHCP + DNS)"
  else
    no "NO dnsmasq is serving boxnet — the bridge is up and incus says 'Created', but nothing hands out leases"
    inf "every box minted now gets no address, no DNS, and dies in cloud-init"
    inf "fix:  timeout 60 incus delete -f <any boxes>; sudo systemctl restart incus"
    inf "      (if it does not come back: teardown-host.sh, then re-run the drill)"
    [ "$FIX" = 1 ] && {
      inf "restarting incus to respawn it…"
      sudo systemctl restart incus && sleep 5
      pgrep -af 'dnsmasq.*--interface=boxnet' >/dev/null 2>&1 \
        && inf "reverted: dnsmasq is serving boxnet again" \
        || inf "STILL missing — run teardown-host.sh and let the drill rebuild the network"
    }
  fi
  # Unlike ipv4.address this one is unconditionally safe to write — it does not
  # depend on the operator's subnet choice and setting it strands no lease — so
  # --fix has an arm here. It had none, and that was the gap that made the
  # verdict unreachable on the 2026-08-27 host: probe C6 reads exactly this key
  # and would have recorded "ipv6: ENABLED and uncovered" against the release.
  ipv6="$(incus network get boxnet ipv6.address 2>/dev/null)"
  if [ "$ipv6" = none ]; then
    ok "ipv6.address = none (the isolation contract — every ACL rule is IPv4-only)"
  else
    no "ipv6.address = ${ipv6:-<unset>} — IPv6 is on and NOT covered by any ACL rule"
    inf "fix:  re-run:  box setup-host   (it converges this key now, #227)"
    [ "$FIX" = 1 ] && { incus network set boxnet ipv6.address=none && inf "set: ipv6.address=none"; }
  fi
else
  FRESH=1
  inf "boxnet does not exist (a fresh host — setup-host.sh will create it)"
fi

head_ "Firewall — the box-to-box drop"
if sudo nft list table bridge box >/dev/null 2>&1; then
  ok "nft bridge table 'box' is present — boxes cannot reach each other"
elif [ "$FRESH" = 1 ]; then
  inf "not installed yet (a fresh host — setup-host.sh installs it)"
else
  no "the box-to-box drop is MISSING — boxes can reach each other"
  inf "an L3 ACL never sees frames switched between two ports of one bridge;"
  inf "the drop is an nft BRIDGE-family rule, and without it siblings are wide open."
  inf "fix:  sudo /usr/local/sbin/box-firewall"
  inf "      (or: sudo systemctl restart box-firewall.service)"
fi

# The UFW blind spot: the ACL check further down compares the ACL's carve-out
# to the live gateway, but on a UFW host the SAME stale-carve-out failure can
# live in UFW's own table — and did, invisibly (#86 review). Judge it here,
# from `ufw status`, wherever UFW is the active firewall and a bridge exists
# to compare against (a fresh host has neither).
if command -v ufw >/dev/null 2>&1; then
  ufw_out="$(sudo ufw status 2>/dev/null)"
  ufw_gw="$(incus network get boxnet ipv4.address 2>/dev/null | cut -d/ -f1)"
  if printf '%s\n' "$ufw_out" | grep -q "Status: active" && [ -n "$ufw_gw" ]; then
    findings="$(ufw_dns_findings "$ufw_out" boxnet "$ufw_gw")"
    if [ -n "$findings" ]; then
      while IFS= read -r line; do no "$line"; done <<<"$findings"
      inf "the bridge moved (#80's escape hatch) and UFW did not follow"
      inf "fix:  sudo /usr/local/sbin/box-firewall   (it converges the UFW allows off the live bridge now)"
    else
      ok "no stale UFW DNS carve-out — box DNS to the gateway ($ufw_gw) survives UFW"
    fi
  fi
fi

# Drop-ins (#279): what other tools opened on the gateway, read through the
# installed firewall's own parser so the doctor and the firewall can never
# disagree about what a file means. Informational: a tool's port is that
# tool's business; a malformed file is reported (it fails closed).
FW_BIN=/usr/local/sbin/box-firewall
[ -x "$FW_BIN" ] || FW_BIN="$(dirname "$0")/../host/box-firewall.sh"
if [ -d "${BOX_FIREWALL_D:-/etc/box/firewall.d}" ]; then
  head_ "Firewall — drop-in ports (${BOX_FIREWALL_D:-/etc/box/firewall.d})"
  # READ, never run, to decide: a pre-#279 box-firewall ignores its arguments
  # and applies the whole firewall — an upgraded host keeps the old binary
  # until setup-host — so executing it as a probe would re-apply old rules.
  if ! grep -q -- '--supports)' "$FW_BIN" 2>/dev/null; then
    no "the installed box-firewall does not read drop-ins — re-run setup-host to install this release's"
  else
    dropin_err="$(mktemp)"
    dropin_list="$(bash "$FW_BIN" --list-dropins 2>"$dropin_err" || true)"
    if [ -n "$dropin_list" ]; then
      ok "accepted from boxnet to the gateway only: $(tr '\n' ',' <<<"$dropin_list" | sed 's/,$//; s/,/, /g')"
    else
      inf "no drop-in ports"
    fi
    while IFS= read -r line; do [ -z "$line" ] || no "${line#box-firewall: }"; done <"$dropin_err"
    rm -f "$dropin_err"
  fi
fi

# box-profile is the placement contract. The pre-rename ancestor profile used to be
# reported beside it, because the migration tool could still re-home the boxes
# that referenced it; with that tool retired (#226), naming it here would tell
# the operator to perform a migration this tool can no longer perform.
#
# That reasoning is why claude-dev stays unreported and box-net does not: the
# test is whether a fix exists to name, not how old the name is. setup-host
# converges box-net in every project, so the drift check below names a lever
# the operator actually holds.
PROFILES=""
incus profile show box-profile >/dev/null 2>&1 && PROFILES="box-profile"
head_ "Profile — the NIC is the isolation contract"
if [ -n "$PROFILES" ]; then
  for p in $PROFILES; do
    iso="$(incus profile device get "$p" eth0 security.port_isolation 2>/dev/null)"
    if [ "$iso" = "true" ]; then
      ok "$p: security.port_isolation = true — boxes cannot reach each other at L2"
    else
      no "$p: security.port_isolation is NOT set — BOXES CAN REACH EACH OTHER"
      inf "an L3 ACL cannot do this: two boxes on one bridge are on the same L2"
      inf "segment, so their frames are switched, never routed past the ACL."
      inf "fix:  re-run:  box setup-host"
    fi
    # NEITHER filter is in the shipped stack, so any value here is a fault —
    # and the fault is that it is set, not how it got set. setup-host sets
    # neither, and security.ipv4_filtering was MEASURED to break the box's
    # networking outright (dockerd comes up but cannot pull or run a
    # container); drill.sh's isolation-contract record carries it as VETOED.
    for k in security.mac_filtering security.ipv4_filtering; do
      v="$(incus profile device get "$p" eth0 "$k" 2>/dev/null)"
      if [ -z "$v" ]; then
        ok "$p: $k unset (as shipped)"
      else
        no "$p: $k = $v  ← NOT SHIPPED — setup-host sets neither NIC filter, and ipv4_filtering is recorded VETOED. A box can fail to get on the network at all."
        [ "$FIX" = 1 ] && { incus profile device unset "$p" eth0 "$k" && inf "reverted: $k unset"; }
      fi
    done
  done
  inf "resources are per-box since 0.4.0 (stamped from the template at mint; BOX_CPU/BOX_MEMORY override)"
else
  inf "box-profile does not exist (a fresh host — setup-host.sh will create it)"
fi

# A surviving box-net is drift, and unlike claude-dev above it is drift this
# host can still fix: setup-host converges the rename in every project, so the
# report names a fix that exists. It is reported in both the have- and
# have-not-box-profile cases, because both are real — a host that never
# converged carries only box-net, and one whose convergence was interrupted
# carries the pair. Every project, since 'box grant' installs a copy into each
# user-<uid> one and a stale copy there is exactly the residue the rename set
# out to stop leaving behind (#229 D5).
#
# The literal 'default' and 'user-*' and no wider, which is exactly the set
# setup-host converges. box creates no other project, so a box-net in one is
# not a state this stack can reach — and reporting it here would name
# 'box setup-host' as the fix for something that run does not touch, which is a
# lever that cannot clear what it is offered for. Anchored at both ends on the
# 'default' arm: setup-host converges the project literally named 'default',
# and an operator's own 'default-archive' is no more in its reach than
# 'scratch' is (#229, rounds 1 and 2). The two loops are a pair and are written
# as one.
#
# And the listing is read before the loop, then checked: a 'project list' that
# fails hands the loop the same empty stream a host with no projects would, and
# an OK saying "the placement contract has one name on this host" off the back
# of zero projects checked is a clean bill of health for a question nobody
# asked. Same rule as the bridge's 'network show' above (#227) — an unreadable
# read is not an empty result — and unreadable includes an empty answer, since
# a daemon that can list projects at all lists 'default' (#229, round 2).
#
# BOTH halves of "could not be read" are checked, and the assignment sits in
# the 'if' for exactly that reason: the status has to survive to be one of
# them. A '|| true' out here would decide the branch on emptiness alone, and a
# daemon that writes a row and THEN fails — 'default (current)' is the likeliest
# such row — would be certified off a listing that stopped early. Two projects
# hold this stack's residue and only one of them got enumerated, so the sweep
# below would report on the wrong half of a host and call it clean. The same
# condition setup-host uses for the same listing, written the same way, because
# the two loops are a pair (#229, round 3).
STALE=""
if PROJECT_CSV="$(incus project list --format csv 2>/dev/null </dev/null)" \
   && [ -n "$PROJECT_CSV" ]; then
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    incus --project "$project" profile show box-net >/dev/null 2>&1 </dev/null \
      && STALE="$STALE${STALE:+ }$project"
  done <<<"$(printf '%s\n' "$PROJECT_CSV" | cut -d, -f1 | sed 's/ (current)$//' \
             | grep -E '^default$|^user-' || true)"
  if [ -n "$STALE" ]; then
    no "box-net still exists — the pre-0.10.0 name for this profile, in: $STALE"
    inf "boxes placed on it are still isolated; the fault is two names one hyphen"
    inf "apart, which is what the rename removed (#229)."
    inf "fix:  box setup-host   (renames it in every project; attached boxes keep their placement)"
    hold "the rename — converging it is setup-host's job, and doing it here would be a second mechanism for one convergence"
  else
    ok "no stale box-net — the placement contract has one name on this host"
  fi
else
  no "the project list could not be read, so whether box-net survives anywhere is unknown"
  inf "'incus project list' failed, or answered nothing — and nothing is a failure"
  inf "too: every working daemon lists the default project. Either way this is the"
  inf "daemon, not a clean host, and a partial listing is not the host's inventory."
  inf "fix:  check the daemon (incus project list), then run the doctor again"
  hold "the box-net check — it cannot report on projects it cannot name"
fi

# The pool is read off the profile that PLACES every box (profiles/box-profile.yaml
# hardcodes root's pool), not guessed from the name setup-host creates — the
# same read bin/box's storage_driver makes before taking a mark.
head_ "Storage pool — the disk every box's root device rides on"
POOL="$(incus profile device get box-profile root pool 2>/dev/null)"
[ -n "$POOL" ] || POOL=default
POOL_SHOW="$(incus storage show "$POOL" 2>/dev/null)"
if [ -n "$POOL_SHOW" ]; then
  inf "pool '$POOL'"
  while IFS= read -r line; do inf "$line"; done <<<"$(pool_findings "$POOL_SHOW")"
  # The config is a claim; the filesystem is the fact — and "how full is it"
  # is half of what anyone asking this question wants. Only for a directory
  # source: 'df' on a raw block device Incus owns outright answers nothing.
  #
  # Through yaml_value for the same reason the report is: read with awk's $2, a
  # pool on '/data/bulk/box pool' asks '[ -d /data/bulk/box ]' — and either
  # says nothing at all, or measures a DIFFERENT filesystem and labels it this
  # pool's.
  src="$(yaml_value source "$POOL_SHOW")"
  if [ -n "$src" ] && [ -d "$src" ]; then
    inf "$(df -h "$src" 2>/dev/null | awk 'NR == 2 { print "df " $6 ": " $2 " total, " $3 " used, " $4 " free (" $5 ") on " $1 }')"
  fi
elif [ "$FRESH" = 1 ]; then
  inf "no pool yet (a fresh host — setup-host.sh creates it; BOX_STORAGE_SOURCE decides where)"
else
  inf "cannot read the storage pool '$POOL' from here"
fi

head_ "ACL — box-isolate"
if incus network acl show box-isolate >/dev/null 2>&1; then
  n="$(incus network acl show box-isolate | grep -c 'action:' || true)"
  inf "$n rules"
  incus network acl show box-isolate | grep -E 'action:|destination:' | sed 's/^/        /'
  # @internal is REJECTED as an ACL destination on a bridge network
  # ("Unsupported nftables subject"), so a rule carrying it enforces nothing —
  # which is why the sibling drop is an nft bridge-family rule instead. Such a
  # rule is dead weight that reads like a boundary; --fix removes it.
  if incus network acl show box-isolate | grep -q '@internal'; then
    no "an @internal rule — unsupported on a bridge network's ACL ('Unsupported nftables subject'), so it enforces nothing"
    [ "$FIX" = 1 ] && { incus network acl rule remove box-isolate egress action=drop destination=@internal && inf "reverted: @internal rule removed"; }
  fi
  # The gateway carve-out must track the BRIDGE. #80's escape hatch moves
  # boxnet off a colliding subnet — and the stale /32 then strands box DNS
  # inside the 10.0.0.0/8 drop, which presents as a dead resolver, never as
  # a stale ACL. Compare the allow rule to boxnet's actual gateway.
  gwaddr="$(incus network get boxnet ipv4.address 2>/dev/null | cut -d/ -f1)"
  carve="$(incus network acl show box-isolate 2>/dev/null \
           | awk '/- action: allow/ { hit = 1; next } hit && /destination:/ { sub("/32", "", $2); print $2; exit } { hit = 0 }')"
  if [ -n "$gwaddr" ] && [ -n "$carve" ]; then
    if [ "$carve" = "$gwaddr" ]; then
      ok "the gateway carve-out matches boxnet's gateway ($gwaddr) — box DNS survives the 10/8 drop"
    else
      no "the gateway carve-out ($carve/32) does NOT match boxnet's gateway ($gwaddr) — box DNS to the gateway dies inside the 10.0.0.0/8 drop"
      inf "the bridge moved (#80's escape hatch) and the ACL did not follow"
      inf "fix:  BOX_SUBNET=${gwaddr%.*}.0/24 box setup-host   (it converges the ACL now)"
    fi
  fi
  # Incus renders every drop ahead of every allow (#298), so the carve-out above
  # only works if NO drop covers the gateway. A host set up before 0.11.0 still
  # has the whole 10/8 dropped, and every firewall drop-in is dead behind it.
  if [ -n "$gwaddr" ]; then
    d_ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }
    gi="$(d_ip2int "$gwaddr")"; covered=""
    for dst in $(incus network acl show box-isolate 2>/dev/null \
                 | awk '/- action: drop/ { hit = 1; next } hit && /destination:/ { print $2 } { hit = 0 }' | tr ',' ' '); do
      case "$dst" in
        */*) lo="$(d_ip2int "${dst%/*}")"; hi=$(( lo + (1 << (32 - ${dst#*/})) - 1 )) ;;
        *-*) lo="$(d_ip2int "${dst%-*}")"; hi="$(d_ip2int "${dst#*-}")" ;;
        *)   lo="$(d_ip2int "$dst")"; hi="$lo" ;;
      esac
      [ "$gi" -ge "$lo" ] && [ "$gi" -le "$hi" ] && covered="$dst"
    done
    if [ -n "$covered" ]; then
      no "the ACL drop $covered covers boxnet's gateway ($gwaddr) — Incus orders drops first, so the carve-out is dead and firewall drop-ins never reach the host (#298)"
      inf "fix:  box setup-host   (it writes the drop around the gateway now)"
    else
      ok "no ACL drop covers boxnet's gateway — drop-in ports can reach the host (#298)"
    fi
  fi
else
  inf "box-isolate does not exist (a fresh host)"
fi

# Config is a claim; the bridge port is the fact. Incus can accept
# security.port_isolation and the kernel can still have 'isolated off' on the
# tap — and then boxes reach each other while every config says they cannot.
# Ask the kernel.
head_ "Bridge ports — the KERNEL's view (config is a claim; this is the fact)"
BRIDGE=""
for c in bridge /usr/sbin/bridge /sbin/bridge; do
  sudo "$c" -V >/dev/null 2>&1 && { BRIDGE="$c"; break; }
done
if [ -n "$BRIDGE" ]; then
  ports="$(sudo "$BRIDGE" -d link show 2>/dev/null | grep -A1 'master boxnet')"
  if [ -z "$ports" ]; then
    inf "no instance is attached to boxnet right now (mint a box to check the taps)"
  else
    printf '%s\n' "$ports" | sed 's/^/        /'
    if printf '%s' "$ports" | grep -q 'isolated on'; then
      ok "the bridge ports are ISOLATED — boxes cannot exchange frames at L2"
    else
      no "the bridge ports are NOT isolated ('isolated off') — BOXES CAN REACH EACH OTHER"
      inf "security.port_isolation in the profile is a claim; this line is the fact."
      inf "if the profile says true and the kernel says off, the flag is not being"
      inf "applied to VM taps and the isolation needs a different mechanism."
    fi
  fi
else
  inf "'bridge' (iproute2) not found — cannot read the kernel's view"
fi

head_ "Instances"
left="$(incus list --format csv --columns ns 2>/dev/null)"
[ -z "$left" ] && inf "(none)" || printf '        %s\n' "$left"
for b in drill clone archive peer payroll cbprobe cbcopy cbnotours; do
  if incus config show "$b" >/dev/null 2>&1; then
    no "leftover drill box: $b"
    [ "$FIX" = 1 ] && { timeout 60 incus delete -f "$b" >/dev/null 2>&1 && inf "reverted: deleted $b"; }
  fi
done
# An interrupted multiuser.sh leaves its users (and their projects) behind —
# and nothing else on this host will ever mention them. Its own cleanup is
# 'box revoke --purge + userdel'; say so rather than absorbing them silently.
for u in boxdrill1 boxdrill2 boxdrill3 boxdrill4; do
  if getent passwd "$u" >/dev/null 2>&1; then
    no "leftover rehearsal user: $u (an interrupted drill/multiuser.sh run)"
    inf "fix:  sudo BOX_YES=1 box revoke $u --purge && sudo userdel -r $u"
  fi
done

# --- Grants: what each granted project holds (#282, #283, #287) -------------
# Informational: a grant's pool fill, its caps and current use, whether it is
# a service and whom it is shared with. An admin reads every project; nothing
# here is a finding unless a grant pool is missing.
grants="$(incus project list --format csv --columns n 2>/dev/null | sed 's/ (current)$//' | grep '^user-' || true)"
if [ -n "$grants" ]; then
  head_ "Grants"
  share_dir="${BOX_SHARE_DIR:-/etc/box/shares}"
  while IFS= read -r gp; do
    [ -n "$gp" ] || continue
    g_uid="${gp#user-}"; g_user="$(getent passwd "$g_uid" 2>/dev/null | cut -d: -f1)"
    g_svc="$(incus project get "$gp" user.box.service 2>/dev/null || true)"
    g_pool="$(incus project get "$gp" user.box.pool 2>/dev/null || true)"
    line="$gp (${g_user:-uid $g_uid}$([ "$g_svc" = true ] && echo ", service"))"
    caps=""
    for k in memory cpu instances; do
      v="$(incus project get "$gp" "limits.$k" 2>/dev/null || true)"
      [ -z "$v" ] || caps="$caps${caps:+, }$k $v"
    done
    inf "$line"
    if [ -n "$caps" ]; then
      inf "  caps: $caps"
      # Current use beside the caps (#283): incus's own resource table.
      while IFS= read -r urow; do inf "    $urow"; done < <(incus project info "$gp" 2>/dev/null \
        | awk -F'|' 'NF>3 && $2 ~ /[A-Z]/ { gsub(/^ +| +$/,"",$2); gsub(/^ +| +$/,"",$3); gsub(/^ +| +$/,"",$4); if ($2 != "RESOURCE") printf "%s: %s used of %s\n", tolower($2), $4, $3 }')
    fi
    if [ -n "$g_pool" ]; then
      if pinfo="$(incus storage info "$g_pool" 2>/dev/null)"; then
        used="$(awk -F': ' '/space used:/{print $2; exit}' <<<"$pinfo")"
        total="$(awk -F': ' '/total space:/{print $2; exit}' <<<"$pinfo")"
        inf "  pool: $g_pool — ${used:-?} of ${total:-?} used"
      else
        no "$gp's grant pool $g_pool is missing — re-run: box grant ${g_user:-<user>}$([ "$g_svc" = true ] && echo " --service") --pool $g_pool --pool-size <size>"
      fi
    fi
    if [ -n "$g_user" ] && [ -e "$share_dir/$g_user" ]; then
      inf "  shared with group: $(cat "$share_dir/$g_user") (box --as $g_user)"
    fi
  done <<<"$grants"
fi

# --- the box's DNS comes from the HOST's resolver. See issue #33. -----------
head_ "Host resolver — a box's DNS is forwarded through this"
hostns="$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
inf "/etc/resolv.conf: ${hostns:-<none>}"
raw="$(incus network get boxnet raw.dnsmasq 2>/dev/null | tr '\n' ';')"
if [ -n "$raw" ]; then
  ok "boxnet has a pinned resolver (raw.dnsmasq: $raw)"
  inf "boxes do NOT inherit the host's resolver — good (issue #33)"
elif [ "$FRESH" = 1 ]; then
  # No boxnet, so there is nothing to pin YET. A VPN resolver on the host is
  # worth naming, but it is a fact about the host, not a fault in a stack
  # that does not exist — setup-host pins around it at creation.
  if printf '%s' "$hostns" | grep -qE '(^| )100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'; then
    inf "the host resolves via a CGNAT/Tailscale resolver ($hostns) — noted, not a fault:"
    inf "setup-host pins the box resolver to public upstreams, so boxes will not inherit it (issue #33)"
  else
    inf "no boxnet yet — setup-host.sh pins its resolver at creation"
  fi
else
  # 100.64.0.0/10 is CGNAT — which is exactly Tailscale's range.
  if printf '%s' "$hostns" | grep -qE '(^| )100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.'; then
    no "the host resolves via a CGNAT/Tailscale resolver ($hostns), and boxes INHERIT it — see issue #33"
    inf "· box DNS breaks whenever the tailnet's resolver does (this is what kills cold mints)"
    inf "· and tailnet names RESOLVE from inside a box, though its ACL blocks connecting to them"
    inf "fix:  re-run:  box setup-host  (it pins the resolver)"
    inf "      or quick-test the pin alone:  bash drill/doctor.sh --pin-dns"
  else
    inf "boxes inherit the host's resolver (unpinned — setup-host.sh pins this now; re-run it)"
  fi
fi

if [ "$PIN" = 1 ]; then
  head_ "Pinning boxnet's resolver (issue #33)"
  if incus network set boxnet raw.dnsmasq "$(printf 'no-resolv\nserver=1.1.1.1\nserver=8.8.8.8\n')" 2>/tmp/pin.err; then
    ok "set raw.dnsmasq: no-resolv + 1.1.1.1 + 8.8.8.8 — dnsmasq now ignores /etc/resolv.conf"
    inf "a box's DNS no longer depends on the host's VPN state, and MagicDNS is out of the path"
    inf "re-run the drill; if the cold mint now succeeds, issue #33 is confirmed and the fix belongs in setup-host.sh"
  else
    no "incus rejected raw.dnsmasq: $(head -1 /tmp/pin.err 2>/dev/null)"
    inf "then raw.dnsmasq is the wrong lever and #33 needs a different mechanism — say so on the issue"
  fi
fi

head_ "Can a box actually resolve DNS?"
# Any box will do — the drill's names are not the only boxes on a host.
probe="$(incus list "user.box=1" --format csv --columns ns 2>/dev/null \
         | awk -F, '$2 == "RUNNING" { print $1; exit }')"
if [ -n "$probe" ] && [ "$FIX" != 1 ]; then
  # Stdin MUST be pinned to /dev/null: with a TTY on stdin, 'incus exec' goes
  # interactive and puts the terminal in raw mode — the probe hangs forever,
  # timeout's TERM never takes (hence -k), and ^C is forwarded INTO the box
  # instead of killing the script. The drill learned this in #22; same rule here.
  inf "probing inside '$probe' — this separates DNS from routing, which is the whole question:"
  inf "its resolv.conf: $(timeout -k 5 20 incus exec "$probe" -- sh -c 'grep -m2 nameserver /etc/resolv.conf' </dev/null 2>/dev/null | tr '\n' ' ')"

  # Routing is probed by ADDRESS against the public internet, NOT by pinging
  # the gateway: box-firewall.sh drops everything from a box to the host
  # except DNS/DHCP, so ICMP to 10.88.0.1 fails BY DESIGN on a healthy host.
  # A gateway ping here is a check that can only ever lie.
  if timeout -k 5 25 incus exec "$probe" -- curl -sS -m 10 -o /dev/null https://1.1.1.1 </dev/null 2>/dev/null; then
    routing=1; ok "reaches 1.1.1.1 by address — egress routing is fine"
  else
    routing=0; no "cannot reach 1.1.1.1 by address — egress routing is broken (this is not DNS)"
  fi

  if timeout -k 5 25 incus exec "$probe" -- getent hosts deb.debian.org </dev/null >/dev/null 2>&1; then
    ok "resolves deb.debian.org — DNS works"
    # The OTHER split from the one below: egress broken while DNS resolves is
    # #80's fingerprint — an impostor dnsmasq on a captured gateway address
    # keeps answering names (it forwards upstream via the default route)
    # while direct IP egress dies. The signature probe underneath answers it.
    [ "$routing" = 0 ] && inf "…egress broken while DNS resolves is #80's fingerprint — see the signature probe below"
  else
    no "CANNOT resolve deb.debian.org — this is exactly what kills cloud-init on every cold mint"
    # Egress by address was probed above. If it worked, the fault is purely
    # name resolution — i.e. the forwarder, i.e. issue #33.
    if [ "$routing" = 1 ]; then
      inf "…but it CAN reach 1.1.1.1 by address. So egress works and only NAME RESOLUTION is broken:"
      inf "the fault is the forwarder the box inherits from the host — issue #33."
      inf "test the fix:  bash drill/doctor.sh --pin-dns   then re-run the drill"
    else
      inf "…and it cannot reach 1.1.1.1 by address either — so egress itself is broken, not just DNS."
    fi
  fi

  probe_sig "$probe"
else
  inf "no box to probe with (mint one, or run without --fix after a run)"
fi

head_ "Verdict"
if [ "$bad" -eq 0 ]; then
  if [ "$FRESH" = 1 ]; then
    printf '  %sfresh%s — no box stack on this host yet, and nothing dirty either.\n' "$C_G" "$C_0"
    printf '  run:  box setup-host   (or the drill — it sets the host up itself)\n\n'
  else
    printf '  %sclean%s — this host is fit to mint boxes (and to drill).\n\n' "$C_G" "$C_0"
  fi
  exit 0
fi
printf '  %s%s problem(s)%s — this host is NOT fit to mint boxes (or to drill).\n' "$C_R" "$bad" "$C_0"
# The verdict's advice has to be reachable (#227). Where --fix cannot reach a
# finding, say which one and why here rather than offering a command that
# leaves the count where it was: the two classes need different next moves —
# one is a flag, the other is stopping the boxes (or an operator).
if [ -n "$HELD" ]; then
  printf '  %s of them need the boxes down first — --fix will not touch:\n' \
    "$(printf '%s\n' "$HELD" | wc -l | tr -d ' ')"
  while IFS= read -r held_line; do printf '    · %s\n' "$held_line"; done <<<"$HELD"
fi
if [ "$FIX" = 1 ]; then
  if [ -n "$HELD" ]; then
    printf '  fixed what could be fixed; the line(s) above are yours to time.\n\n'
  else
    printf '  reverted what could be reverted; re-run doctor to confirm.\n\n'
  fi
else
  if [ -n "$HELD" ]; then
    printf '  run:  bash drill/doctor.sh --fix   (it clears the rest)\n\n'
  else
    printf '  run:  bash drill/doctor.sh --fix\n\n'
  fi
fi
exit 1
