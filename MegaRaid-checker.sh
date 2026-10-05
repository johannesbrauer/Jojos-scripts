#!/bin/bash
#
# MegaRaid-checker.sh - MegaRAID health check for use with systemd
#
# Checks the state of all virtual drives and physical drives on a
# Broadcom/LSI MegaRAID controller via StorCLI.
#
# Exit codes:
#   0  all virtual and physical drives are healthy
#   1  at least one virtual or physical drive is not in a healthy state
#   2  no virtual drives found or StorCLI failed
#
# Environment variables (optional):
#   STORCLI          path to the storcli64 binary
#                    (default: /opt/MegaRAID/storcli/storcli64)
#   CTRL             controller to check (default: /c0)
#   RAID_FORCE_FAIL  if set to any value, the script reports a critical
#                    state without querying the controller (for testing)
#
# Requires: bash, awk, StorCLI. Must be run as root.

STORCLI="${STORCLI:-/opt/MegaRAID/storcli/storcli64}"
CTRL="${CTRL:-/c0}"
problems=0

# Test mode, e.g.: systemctl set-environment RAID_FORCE_FAIL=1
if [ -n "${RAID_FORCE_FAIL:-}" ]; then
  echo "CRITICAL: test alarm (RAID_FORCE_FAIL is set)"
  exit 1
fi

if [ ! -x "$STORCLI" ]; then
  echo "CRITICAL: StorCLI not found or not executable: $STORCLI"
  exit 2
fi

# --- Virtual drives -----------------------------------------------------
# Rows look like: "0/0  RAID1  Optl  RW  Yes  RWBD  -  ON  1.818 TB"
# Common states: Optl = optimal, Dgrd = degraded, Pdgd = partially degraded,
#                OfLn = offline
vd_out=$("$STORCLI" "$CTRL"/vall show 2>&1)
vds=$(echo "$vd_out" | awk '$1 ~ /^[0-9]+\/[0-9]+$/ {print $1" "$2" "$3}')

if [ -z "$vds" ]; then
  echo "CRITICAL: no virtual drives found or StorCLI error"
  echo "$vd_out" | head -20
  exit 2
fi

while read -r id type state; do
  [ -n "$id" ] || continue
  if [ "$state" = "Optl" ]; then
    echo "OK: VD $id ($type) is optimal"
  else
    echo "CRITICAL: VD $id ($type) state=$state"
    problems=1
  fi
done <<< "$vds"

# --- Physical drives ----------------------------------------------------
# Rows look like: "252:0  8  Onln  0  1.819 TB SATA HDD N N 512B ..."
# Accepted states: Onln = online, GHS = global hot spare,
#                  DHS = dedicated hot spare, UGood = unconfigured good,
#                  JBOD = JBOD mode.
# Anything else (Offln, UBad, Failed, Rbld, ...) is reported as a problem.
pd_out=$("$STORCLI" "$CTRL"/eall/sall show 2>&1)
pds=$(echo "$pd_out" | awk '$1 ~ /^[0-9]+:[0-9]+$/ {print $1" "$3}')

while read -r slot state; do
  [ -n "$slot" ] || continue
  case "$state" in
    Onln|GHS|DHS|UGood|JBOD) ;;
    *)
      echo "CRITICAL: drive $slot state=$state"
      problems=1
      ;;
  esac
done <<< "$pds"

if [ "$problems" -eq 0 ]; then
  echo "OK: all drives healthy"
fi

exit "$problems"