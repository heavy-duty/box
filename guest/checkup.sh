#!/usr/bin/env bash
set -euo pipefail

# Read-only guest fitness report, streamed into one box by `box checkup` (#258).
# Positional inputs are host facts the guest cannot discover honestly:
# instance type, the mint's seed marker, and a container's expanded swap policy.
kind="${1:-}"
seed="${2:-unknown}"
swap_policy="${3:-default}"
case "$kind" in vm|container) ;; *) echo "checkup: expected vm or container" >&2; exit 2 ;; esac

gib() {
  awk -v bytes="$1" 'BEGIN { printf "%.1f GiB", bytes / 1073741824 }'
}

problems=0
printf '%-9s%s\n' TYPE "$( [ "$kind" = vm ] && echo VM || echo CONTAINER )"
case "$seed" in
  unknown)
    printf '%-9s%s\n' SEED "unknown — this box carries no seed-generation marker"
    problems=$((problems + 1))
    ;;
  *)       printf '%-9s%s\n' SEED "$seed" ;;
esac

# Headroom is evidence, not a threshold. 81% used is worth seeing and is not a
# failure, so valid rows never change the exit status (#258 D4). A reader that
# fails is itself a finding, printed in place instead of truncating later rows.
disk_rc=0
disk_row="$(df -B1 --output=size,avail,pcent / 2>&1)" || disk_rc=$?
disk_values="$(awk 'NR == 2 { print $1, $2, $3 }' <<<"$disk_row")"
read -r disk_total disk_available disk_used <<<"$disk_values"
if [ "$disk_rc" -ne 0 ] \
  || ! [[ "${disk_total:-}" =~ ^[0-9]+$ && "${disk_available:-}" =~ ^[0-9]+$ && "${disk_used:-}" =~ ^[0-9]+%$ ]]; then
  printf '%-9s%s\n' DISK "could not determine disk headroom${disk_row:+ — $disk_row}"
  problems=$((problems + 1))
else
  printf '%-9s%s available of %s (%s used)\n' DISK \
    "$(gib "$disk_available")" "$(gib "$disk_total")" "$disk_used"
fi

free_rc=0
free_output="$(free -b 2>&1)" || free_rc=$?
memory_values="$(awk '/^Mem:/ { print $2, $7 }' <<<"$free_output")"
read -r mem_total mem_available <<<"$memory_values"
if [ "$free_rc" -ne 0 ] \
  || ! [[ "${mem_total:-}" =~ ^[0-9]+$ && "${mem_available:-}" =~ ^[0-9]+$ ]]; then
  printf '%-9s%s\n' MEMORY "could not determine memory headroom${free_output:+ — $free_output}"
  problems=$((problems + 1))
  mem_total=""
else
  printf '%-9s%s available of %s\n' MEMORY \
    "$(gib "$mem_available")" "$(gib "$mem_total")"
fi

tmp_rc=0
tmp_row="$(findmnt -bn -o FSTYPE,SIZE,OPTIONS /tmp 2>&1)" || tmp_rc=$?
read -r tmp_fstype tmp_size tmp_options <<<"$tmp_row"
if [ "$tmp_rc" -ne 0 ] \
  || ! [[ "${tmp_fstype:-}" =~ ^[^[:space:]]+$ && "${tmp_size:-}" =~ ^[0-9]+$ ]]; then
  printf '%-9s%s\n' TMP "could not determine /tmp's mount${tmp_row:+ — $tmp_row}"
  problems=$((problems + 1))
  tmp_fstype=""
else
  printf '%-9s%s at %s (%s)\n' TMP "$tmp_fstype" "$(gib "$tmp_size")" "$tmp_options"
fi
# The measured legacy shape was systemd's stock 50%-of-RAM tmpfs. The current
# #178 seed uses a fixed 1 GiB cap, which is itself 50% on a 2 GiB box. Require
# both the incident-backed ratio floor and a size above that cap; no upper
# ratio bound lets a larger legacy tmpfs hide by being worse than the incident.
if [ "$tmp_fstype" = tmpfs ] \
  && [ -n "$mem_total" ] \
  && [ "$tmp_size" -gt 1073741824 ] \
  && [ "$tmp_size" -gt $((mem_total * 45 / 100)) ]; then
  if [ "$kind" = container ]; then
    echo "FIX       /tmp is about 50% of the container's reported memory; remint with tenant seed #178 for the fixed 1.0 GiB cap."
  else
    echo "FIX       /tmp is about 50% of VM memory; remint with tenant seed #178 for the fixed 1.0 GiB cap."
  fi
  problems=$((problems + 1))
fi

if [ "$kind" = container ]; then
  printf '%-9s%s\n' SWAP "host-managed for this container (limits.memory.swap=$swap_policy)"
else
  swap_total="$(awk '/^Swap:/ { print $2 }' <<<"$free_output")"
  if [ "$free_rc" -ne 0 ] || ! [[ "${swap_total:-}" =~ ^[0-9]+$ ]]; then
    printf '%-9s%s\n' SWAP "could not determine VM swap${free_output:+ — $free_output}"
    problems=$((problems + 1))
  elif [ "$swap_total" -eq 0 ]; then
    echo "SWAP     none"
    case "$seed" in
      seed/*)
        # Since seed/3 (0.11.0, #290) box lays no swap: convergence does. An
        # unconverged box has none by design, so this is a note, not a fault.
        echo "NOTE      box lays no swap since 0.11.0 — a converged role provides it (SWAP_SIZE); an unconverged box has none." ;;
      *)
        # tenant/2 laid a 4 GiB swapfile (#178), and an unmarked box predates
        # even that: for either, none is a defect.
        echo "FIX       missing swap; the tenant seed of #178 laid a 4.0 GiB swapfile — remint, or converge a role that sets swap."
        problems=$((problems + 1)) ;;
    esac
  else
    printf '%-9s%s total\n' SWAP "$(gib "$swap_total")"
  fi
fi

# One capture preserves journalctl's status without writing an error file. The
# probe runs as root through Incus, but a missing journal or explicit denial is
# still unknown, never "no OOM" — the false negative that bought this check.
journal_rc=0
# _TRANSPORT=kernel instead of `-k`: journalctl -k implies the current boot,
# while "ever logged" means every retained boot in this guest (#258).
journal="$(journalctl --no-pager -o cat _TRANSPORT=kernel 2>&1)" || journal_rc=$?
if [ "$journal_rc" -ne 0 ]; then
  printf '%-9s%s\n' OOM "could not read kernel journal${journal:+ — $journal}"
  problems=$((problems + 1))
else
  oom_count="$(grep -ciE 'oom-kill|out of memory|killed process [0-9]+' <<<"$journal" || true)"
  if [ "$oom_count" -eq 0 ]; then
    printf '%-9s%s\n' OOM "no OOM kill logged"
  else
    printf '%-9s%s\n' OOM "$oom_count OOM kill record(s) logged"
    problems=$((problems + 1))
  fi
fi

[ "$problems" -eq 0 ] || exit 1
