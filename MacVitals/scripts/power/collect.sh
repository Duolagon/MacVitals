#!/bin/sh
# Installed root-owned; collects only fixed system metrics, never executes app code.
set -eu
/usr/bin/pgrep -x MacVitals >/dev/null || exit 0
umask 022
/bin/mkdir -p /var/run/local.macvitals.power
/usr/sbin/chown root:wheel /var/run/local.macvitals.power
/bin/chmod 755 /var/run/local.macvitals.power
/usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power -n 1 -i 1000 -f plist -o /var/run/local.macvitals.power/sample.next
/bin/mv -f /var/run/local.macvitals.power/sample.next /var/run/local.macvitals.power/sample.plist
