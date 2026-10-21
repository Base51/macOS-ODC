#!/bin/bash
#
# IntuneMacODC - Intune macOS One Data Collector
#
# Gathers system information and logs from macOS devices managed by Microsoft Intune
# and packages them into a single zip for troubleshooting.
#
# Usage:
#   sudo ./IntuneMacODC.sh [options]
#
# Options:
#   -d, --days N          Number of days of unified logs / crash reports to collect (default: 7, max: 30)
#   -o, --output DIR      Folder where the zip is created (default: current folder)
#   -l, --logarchive      Also create a full unified log archive (.logarchive) - large, slow
#   -a, --all-varlog      Collect everything under /var/log (default: only install/system/wifi/jamf logs)
#   -c, --include-cmdline Include full process command lines (may contain sensitive data)
#   -k, --keep            Keep the uncompressed staging folder after zipping
#   -n, --no-open         Do not open Finder when finished
#   -q, --quiet           Skip the data collection notice prompt
#   -D, --debug           Enable shell tracing (set -x)
#   -h, --help            Show this help
#
# Compatible with the bash 3.2 that ships with macOS.
#
# MIT License

VERSION="2.0.0"

#######################################################################################
# Defaults and argument parsing
#######################################################################################
DAYS=7
OUTPUT_DIR="$(pwd)"
LOGARCHIVE=0
ALL_VARLOG=0
INCLUDE_CMDLINE=0
KEEP_STAGE=0
OPEN_FINDER=1
QUIET=0

usage() {
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -d|--days)            DAYS="$2"; shift ;;
        -o|--output)          OUTPUT_DIR="$2"; shift ;;
        -l|--logarchive)      LOGARCHIVE=1 ;;
        -a|--all-varlog)      ALL_VARLOG=1 ;;
        -c|--include-cmdline) INCLUDE_CMDLINE=1 ;;
        -k|--keep)            KEEP_STAGE=1 ;;
        -n|--no-open)         OPEN_FINDER=0 ;;
        -q|--quiet)           QUIET=1 ;;
        -D|--debug|-Debug|-debug) set -x; echo "Debug mode enabled" ;;
        -h|--help)            usage ;;
        *) echo "Unknown option: $1 (use --help)"; exit 1 ;;
    esac
    shift
done

case "$DAYS" in
    ''|*[!0-9]*) echo "--days must be a whole number"; exit 1 ;;
esac
if [ "$DAYS" -lt 1 ]; then DAYS=1; fi
if [ "$DAYS" -gt 30 ]; then DAYS=30; fi

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This tool only runs on macOS."
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "Please run using: sudo $0 $*"
    exit 1
fi

#######################################################################################
# Signed-in (console) user - so user-scoped logs are collected from the right home folder
# even when running under sudo.
#######################################################################################
CONSOLE_USER="$(stat -f%Su /dev/console 2>/dev/null)"
if [ -z "$CONSOLE_USER" ] || [ "$CONSOLE_USER" = "root" ] || [ "$CONSOLE_USER" = "loginwindow" ]; then
    CONSOLE_USER="${SUDO_USER:-}"
fi
CONSOLE_UID=""
USER_HOME=""
if [ -n "$CONSOLE_USER" ] && [ "$CONSOLE_USER" != "root" ]; then
    CONSOLE_UID="$(id -u "$CONSOLE_USER" 2>/dev/null)"
    USER_HOME="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
    [ -z "$USER_HOME" ] && USER_HOME="/Users/$CONSOLE_USER"
fi

#######################################################################################
# Notice
#######################################################################################
if [ "$QUIET" -eq 0 ]; then
    cat <<NOTICE

IntuneMacODC v$VERSION
----------------------
This tool collects device configuration, management profiles, installed apps,
Microsoft and system logs (last $DAYS days) from this Mac. The resulting zip may
contain device names, user names, network details and file paths.
Review it before sharing, and only share it through your support case.

NOTICE
    printf "Press Enter to continue or Ctrl+C to cancel... "
    read -r _
fi

#######################################################################################
# Staging folder
#######################################################################################
HOSTNAME_SHORT="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
NOW="$(date +%Y-%m-%dT%H-%M-%S%z)"
BASENAME="${HOSTNAME_SHORT}-IntuneMacODC-${NOW}"

mkdir -p "$OUTPUT_DIR" || { echo "Cannot create output folder $OUTPUT_DIR"; exit 1; }
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
STAGE="$OUTPUT_DIR/$BASENAME"
ZIPFILE="$OUTPUT_DIR/$BASENAME.zip"

mkdir -p "$STAGE"/{system,mdm,security,network,apps,logs/unified,logs/files,crash,defender,jamf} || exit 1
MANIFEST="$STAGE/collection_manifest.txt"
START_TS=$(date +%s)
OK_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

{
    echo "IntuneMacODC version : $VERSION"
    echo "Collected            : $(date)"
    echo "Host                 : $HOSTNAME_SHORT"
    echo "Console user         : ${CONSOLE_USER:-<none>}"
    echo "User home            : ${USER_HOME:-<none>}"
    echo "Days of logs         : $DAYS"
    echo "Options              : logarchive=$LOGARCHIVE all-varlog=$ALL_VARLOG include-cmdline=$INCLUDE_CMDLINE"
    echo "========================================================================"
} > "$MANIFEST"

#######################################################################################
# Helpers
#######################################################################################
log_step() { echo "[$(date +%H:%M:%S)] $*"; }

record() {   # record <status> <description>
    printf "%-6s %s\n" "$1" "$2" >> "$MANIFEST"
    case "$1" in
        OK)   OK_COUNT=$((OK_COUNT + 1)) ;;
        FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
        SKIP) SKIP_COUNT=$((SKIP_COUNT + 1)) ;;
    esac
}

# run_with_timeout <seconds> <command...>   (macOS has no 'timeout' binary)
run_with_timeout() {
    local secs="$1"; shift
    "$@" &
    local cmd_pid=$!
    ( sleep "$secs" && kill -TERM "$cmd_pid" 2>/dev/null && echo "*** Timed out after ${secs}s ***" ) &
    local watch_pid=$!
    wait "$cmd_pid"
    local rc=$?
    pkill -P "$watch_pid" 2>/dev/null
    kill "$watch_pid" 2>/dev/null
    wait "$watch_pid" 2>/dev/null
    return $rc
}

# run_cmd <output file relative to stage> <timeout seconds> <command...>
# Appends a header plus the command output (stdout+stderr) to the file.
run_cmd() {
    local rel="$1"; local out="$STAGE/$1"; local secs="$2"; shift 2
    mkdir -p "$(dirname "$out")"
    {
        echo "************************************************************************"
        echo "# $*"
        echo "# $(date)"
        echo "************************************************************************"
    } >> "$out"
    run_with_timeout "$secs" "$@" >> "$out" 2>&1
    local rc=$?
    echo "" >> "$out"
    if [ $rc -eq 0 ]; then record OK "$* -> $rel"; else record FAIL "$* (exit $rc) -> $rel"; fi
    return $rc
}

# run_as_user <command...>  - run in the signed-in user's session
run_as_user() {
    if [ -n "$CONSOLE_UID" ]; then
        launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" "$@"
    else
        echo "No signed-in user - skipped"
        return 1
    fi
}

# copy_path <source> <destination folder relative to stage>
copy_path() {
    local src="$1"; local dest="$STAGE/$2"
    if [ -e "$src" ]; then
        mkdir -p "$dest"
        if cp -Rp "$src" "$dest/" 2>>"$STAGE/copy_errors.txt"; then
            record OK "copy $src"
        else
            record FAIL "copy $src (see copy_errors.txt)"
        fi
    else
        record SKIP "not found: $src"
    fi
}

# copy_glob <pattern> <destination folder>  - pattern is expanded here
copy_glob() {
    local dest="$2"; local found=0; local f
    for f in $1; do
        [ -e "$f" ] || continue
        found=1
        copy_path "$f" "$dest"
    done
    [ $found -eq 0 ] && record SKIP "no match: $1"
}

# unified_log <file name> <predicate>
unified_log() {
    run_cmd "logs/unified/$1" 1800 \
        log show --style syslog --info --debug --last "${DAYS}d" --predicate "$2"
}

#######################################################################################
# 1. System information
#######################################################################################
log_step "Collecting system information"
run_cmd system/sw_vers.txt          30  sw_vers
run_cmd system/uname.txt            30  uname -a
run_cmd system/uptime.txt           30  uptime
run_cmd system/hardware.txt         60  system_profiler SPHardwareDataType SPSoftwareDataType
run_cmd system/disk_usage.txt       60  df -h
run_cmd system/diskutil_apfs.txt    60  diskutil apfs list
run_cmd system/reboot_history.txt   30  last reboot
run_cmd system/login_history.txt    30  last -50
run_cmd system/local_users.txt      30  dscl . -list /Users UniqueID

log_step "Gathering full system report (may take a few minutes)"
run_with_timeout 900 /usr/sbin/system_profiler -detailLevel full -xml > "$STAGE/system/SystemReport.spx" 2>/dev/null \
    && record OK "system_profiler full -> system/SystemReport.spx (double-click to open)" \
    || record FAIL "system_profiler full"

if [ "$INCLUDE_CMDLINE" -eq 1 ]; then
    run_cmd system/processes.txt 30 ps -A -o pid,ppid,user,%cpu,%mem,lstart,comm,args
else
    run_cmd system/processes.txt 30 ps -A -o pid,ppid,user,%cpu,%mem,lstart,comm
fi

#######################################################################################
# 2. MDM enrollment and profiles
#######################################################################################
log_step "Collecting MDM enrollment and profile data"
run_cmd mdm/enrollment_status.txt       60  profiles status -type enrollment
run_cmd mdm/bootstraptoken_status.txt   60  profiles status -type bootstraptoken
run_cmd mdm/profiles.txt                60  profiles list -all
run_cmd mdm/profiles.txt                60  profiles show -all
run_cmd mdm/profiles.txt                60  profiles show -type enrollment
profiles show -output stdout-xml > "$STAGE/mdm/profiles_show.xml" 2>/dev/null \
    && record OK "profiles show -output stdout-xml" || record FAIL "profiles show -output stdout-xml"
profiles list -output stdout-xml > "$STAGE/mdm/profiles_list.xml" 2>/dev/null \
    && record OK "profiles list -output stdout-xml" || record FAIL "profiles list -output stdout-xml"
if [ -n "$CONSOLE_USER" ]; then
    run_cmd mdm/profiles_user.txt 60 profiles list -user "$CONSOLE_USER"
fi

MDMCLIENT=/usr/libexec/mdmclient
if [ -x "$MDMCLIENT" ]; then
    for q in QueryDeviceInformation QueryInstalledProfiles QueryCertificates QuerySecurityInfo QueryInstalledApps dumpSCEPVars; do
        run_cmd "mdm/mdmclient_${q}.txt" 120 "$MDMCLIENT" "$q"
    done
else
    record SKIP "mdmclient not found"
fi

copy_path "/Library/Application Support/com.apple.TCC/MDMOverrides.plist" mdm
copy_path "/Library/Managed Preferences" mdm

#######################################################################################
# 3. Security state (FileVault, Gatekeeper, SIP, firewall, Platform SSO)
#######################################################################################
log_step "Collecting security state"
run_cmd security/filevault.txt        30  fdesetup status
run_cmd security/filevault.txt        30  fdesetup haspersonalrecoverykey
run_cmd security/filevault.txt        30  fdesetup hasinstitutionalrecoverykey
run_cmd security/gatekeeper.txt       30  spctl --status
run_cmd security/sip.txt              30  csrutil status
run_cmd security/firewall.txt         30  /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
run_cmd security/firewall.txt         30  /usr/libexec/ApplicationFirewall/socketfilterfw --getstealthmode
run_cmd security/secure_token.txt     30  sysadminctl -secureTokenStatus "${CONSOLE_USER:-root}"
run_cmd security/platform_sso.txt     60  run_as_user app-sso platform -s
run_cmd security/sso_extensions.txt   60  run_as_user app-sso -l

#######################################################################################
# 4. Network (enrollment / check-in / APNs connectivity)
#######################################################################################
log_step "Collecting network configuration"
run_cmd network/proxy.txt        30  scutil --proxy
run_cmd network/dns.txt          30  scutil --dns
run_cmd network/services.txt     30  networksetup -listallnetworkservices
run_cmd network/interfaces.txt   30  ifconfig -a
run_cmd network/routes.txt       30  netstat -rn

#######################################################################################
# 5. Apps, packages and software updates
#######################################################################################
log_step "Collecting installed packages and update history"
run_cmd apps/pkgutil_pkgs.txt    60  pkgutil --pkgs

pkg_info_all() {
    pkgutil --pkgs | grep -v '^com\.apple\.pkg\.MAContent10' | sort | while read -r p; do
        pkgutil --pkg-info "$p"
        echo ""
    done
}
run_cmd apps/pkgutil_info.txt    300 pkg_info_all

run_cmd apps/applications.txt    60  ls -la /Applications
run_cmd apps/softwareupdate_history.txt 120 softwareupdate --history
run_cmd apps/softwareupdate_prefs.txt   30  defaults read /Library/Preferences/com.apple.SoftwareUpdate
copy_glob "/Library/Application Support/Microsoft/EdgeUpdater/updater.log*" apps/EdgeUpdater

#######################################################################################
# 6. Microsoft / Intune log files
#######################################################################################
log_step "Collecting Microsoft and Intune log files"
copy_path "/Library/Logs/Microsoft"                                  logs/files/Library_Logs
copy_path "/Library/Application Support/Microsoft/Intune/SideCar"    logs/files/IntuneSideCar
if [ -n "$USER_HOME" ]; then
    copy_path "$USER_HOME/Library/Logs/Company Portal"               logs/files/User_Logs
    copy_path "$USER_HOME/Library/Logs/Microsoft"                    logs/files/User_Logs
    copy_path "$USER_HOME/Library/Containers/com.microsoft.CompanyPortalMac.ssoextension/Data/Library/Caches/Logs/Microsoft/SSOExtension" logs/files/SSOExtension
else
    record SKIP "no signed-in user - user log folders not collected"
fi

if [ "$ALL_VARLOG" -eq 1 ]; then
    copy_path "/var/log" logs/files
else
    copy_glob "/var/log/install.log*" logs/files/var_log
    copy_glob "/var/log/system.log*"  logs/files/var_log
    copy_glob "/var/log/wifi.log*"    logs/files/var_log
    copy_glob "/var/log/jamf.log*"    logs/files/var_log
fi

#######################################################################################
# 7. Crash / diagnostic reports (last N days only, Siri excluded)
#######################################################################################
log_step "Collecting recent diagnostic reports"
collect_crash() {   # collect_crash <folder> <dest>
    local src="$1"; local dest="$STAGE/$2"
    if [ -d "$src" ]; then
        mkdir -p "$dest"
        find "$src" -maxdepth 1 -type f -mtime "-${DAYS}" ! -iname "*Siri*" -exec cp -p {} "$dest/" \; 2>/dev/null
        record OK "diagnostic reports from $src"
    else
        record SKIP "not found: $src"
    fi
}
collect_crash "/Library/Logs/DiagnosticReports" crash/system
[ -n "$USER_HOME" ] && collect_crash "$USER_HOME/Library/Logs/DiagnosticReports" crash/user

#######################################################################################
# 8. Microsoft Defender for Endpoint (if installed)
#######################################################################################
if command -v mdatp >/dev/null 2>&1; then
    log_step "Collecting Microsoft Defender data"
    copy_path "/Library/Logs/Microsoft/Defender/wdavstate"                         defender
    copy_path "/Library/Logs/Microsoft/Defender/security_management/policy"         defender
    copy_path "/Library/Logs/Microsoft/Defender/security_management/current_report" defender
    run_cmd defender/mdatp_health.txt 120 mdatp health
else
    record SKIP "Microsoft Defender (mdatp) not installed"
fi

#######################################################################################
# 9. Jamf (if installed)
#######################################################################################
JAMFAAD=/usr/local/jamf/bin/jamfAAD
if [ -e "$JAMFAAD" ]; then
    log_step "Collecting Jamf data"
    if [ -d "$JAMFAAD" ]; then copy_path "$JAMFAAD" jamf; fi
    if [ -x "$JAMFAAD" ] && [ ! -d "$JAMFAAD" ]; then
        run_cmd jamf/jamfAAD_gatherAADInfo.txt 120 run_as_user "$JAMFAAD" gatherAADInfo
    fi
    unified_log jamf_jamfAAD.log 'subsystem CONTAINS "jamfAAD"'
else
    record SKIP "Jamf (jamfAAD) not installed"
fi

#######################################################################################
# 10. Unified logs (last N days)
#######################################################################################
log_step "Gathering unified logs for the last $DAYS day(s). This may take several minutes."

unified_log intune.log \
    'process BEGINSWITH "Intune" OR process CONTAINS[c] "IntuneMdmAgent" OR process CONTAINS[c] "CompanyPortal" OR eventMessage CONTAINS[c] "Intune"'

unified_log mdm.log \
    'process == "mdmclient" OR process == "ManagedClient" OR subsystem == "com.apple.ManagedClient" OR process CONTAINS "mdm"'

unified_log ddm_remotemanagement.log \
    'process == "remotemanagementd" OR subsystem CONTAINS[c] "remotemanagement"'

unified_log apns.log \
    'process CONTAINS[c] "apsd" OR eventMessage CONTAINS[c] "apsd"'

unified_log appstore_downloads.log \
    'process CONTAINS[c] "appstore" OR process CONTAINS[c] "downloadd" OR process CONTAINS[c] "storedownloadd" OR process == "installd"'

unified_log softwareupdate.log \
    'process == "softwareupdated" OR process CONTAINS[c] "SoftwareUpdate" OR subsystem CONTAINS[c] "SoftwareUpdate"'

unified_log sso.log \
    'subsystem CONTAINS[c] "AppSSO" OR process CONTAINS[c] "AppSSO" OR process CONTAINS[c] "ssoextension" OR subsystem == "com.apple.PlatformSSO"'

if [ "$LOGARCHIVE" -eq 1 ]; then
    log_step "Creating full unified log archive (large)"
    run_cmd logs/logarchive_result.txt 3600 \
        log collect --last "${DAYS}d" --output "$STAGE/logs/unified/system_logs.logarchive"
fi

#######################################################################################
# Package results
#######################################################################################
END_TS=$(date +%s)
{
    echo "========================================================================"
    echo "Completed : $(date)"
    echo "Duration  : $((END_TS - START_TS)) seconds"
    echo "Results   : $OK_COUNT OK, $FAIL_COUNT failed, $SKIP_COUNT skipped"
} >> "$MANIFEST"

log_step "Compressing results"
if ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$ZIPFILE"; then
    [ "$KEEP_STAGE" -eq 0 ] && rm -rf "$STAGE"
else
    echo "Compression failed. Uncompressed data kept in: $STAGE"
    exit 1
fi

# Give the signed-in user ownership so the zip can be attached to the case without sudo
if [ -n "$CONSOLE_USER" ]; then
    chown "$CONSOLE_USER" "$ZIPFILE" 2>/dev/null
    [ "$KEEP_STAGE" -eq 1 ] && chown -R "$CONSOLE_USER" "$STAGE" 2>/dev/null
fi

echo ""
echo "Done in $((END_TS - START_TS)) seconds: $OK_COUNT collected, $FAIL_COUNT failed, $SKIP_COUNT skipped."
echo "Results: $ZIPFILE"
echo "See collection_manifest.txt inside the zip for details."

if [ "$OPEN_FINDER" -eq 1 ] && [ -n "$CONSOLE_UID" ]; then
    launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" open -R "$ZIPFILE" >/dev/null 2>&1
fi

exit 0
