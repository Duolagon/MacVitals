#!/bin/sh
# Installed root-owned; collects only fixed system metrics, never executes app code.
set -eu
# Validate leases against live app PIDs and ownership. Only filesystem metadata is consumed.
has_demand() {
    target_pid_filter=${1:-}
    for app_pid in $(/usr/bin/pgrep -x MacVitals); do
        [ -z "$target_pid_filter" ] || [ "$app_pid" = "$target_pid_filter" ] || continue
        request="/tmp/local.macvitals.power-demand.$app_pid"
        [ -f "$request" ] && [ ! -L "$request" ] || continue
        metadata=$(/usr/bin/stat -f '%u %m %Lp' "$request") || continue
        set -- $metadata
        [ "$#" -eq 3 ] || continue
        owner=$1; modified=$2; mode=$3
        case "$owner:$modified:$mode" in *[!0-9:]*) continue ;; esac
        [ "$mode" = 600 ] || continue
        set -- $(/bin/ps -p "$app_pid" -o uid= -o stat=)
        [ "${1:-}" = "$owner" ] || continue
        case "${2:-}" in ''|*Z*) continue ;; esac
        now=$(/bin/date +%s)
        age=$((now - modified))
        [ "$age" -ge 0 ] && [ "$age" -lt 75 ] && return 0
    done
    return 1
}
if [ "${1:-}" = --check-demand ]; then has_demand "${2:-}"; exit $?; fi
has_demand || exit 0
umask 022
/bin/mkdir -p /var/run/local.macvitals.power
/usr/sbin/chown root:wheel /var/run/local.macvitals.power
/bin/chmod 755 /var/run/local.macvitals.power
/usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power -n 1 -i 1000 -f plist -o /var/run/local.macvitals.power/sample.next
/bin/mv -f /var/run/local.macvitals.power/sample.next /var/run/local.macvitals.power/sample.plist
