#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo '请以管理员身份执行此安装脚本'; exit 1; }
POWER_SOURCE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
/bin/mkdir -p /Library/PrivilegedHelperTools
# /var/run resets at reboot; the collector creates its private root-owned directory.
/usr/bin/install -o root -g wheel -m 755 "$POWER_SOURCE_DIR/collect.sh" /Library/PrivilegedHelperTools/local.macvitals.collect-power.sh
/usr/bin/install -o root -g wheel -m 644 "$POWER_SOURCE_DIR/local.macvitals.power.plist" /Library/LaunchDaemons/local.macvitals.power.plist
/bin/launchctl bootout system/local.macvitals.power 2>/dev/null || true
/bin/launchctl bootstrap system /Library/LaunchDaemons/local.macvitals.power.plist
