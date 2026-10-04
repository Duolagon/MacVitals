#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo '请以管理员身份执行此卸载脚本'; exit 1; }
/bin/launchctl bootout system/local.macvitals.power 2>/dev/null || true
/bin/rm -f /Library/LaunchDaemons/local.macvitals.power.plist /Library/PrivilegedHelperTools/local.macvitals.collect-power.sh
/bin/rm -f /var/run/local.macvitals.power/sample.next /var/run/local.macvitals.power/sample.plist
/bin/rmdir /var/run/local.macvitals.power 2>/dev/null || true
