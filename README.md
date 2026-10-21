# macOS-ODC

**macOS One Data Collector for Microsoft Intune**

`IntuneMacODC.sh` collects system information, management profiles, and Microsoft and Apple logs from a Mac managed by Microsoft Intune. It packages everything into a single zip that you can attach to a support case.

> This project is based on the original [IntuneMacODC](https://github.com/markstan/IntuneMacODC) by Mark Stanfill (MIT license). Version 2.0 fixes several bugs, makes the script faster, and collects data from newer macOS features such as Platform SSO and Declarative Device Management.

---

## Quick start

Open **Terminal** on the affected Mac and run:

```bash
curl -L https://raw.githubusercontent.com/Base51/macOS-ODC/main/IntuneMacODC.sh -o IntuneMacODC.sh
chmod u+x ./IntuneMacODC.sh
sudo ./IntuneMacODC.sh
```

1. Read the data collection notice and press **Enter** to continue (or **Ctrl+C** to cancel).
2. Wait for the collection to finish. It usually takes a few minutes, mostly spent reading the system logs.
3. A Finder window opens with the zip selected, named like this:

   ```
   <ComputerName>-IntuneMacODC-<yyyy-mm-ddTHH-MM-SS+zzzz>.zip
   ```

4. Attach the zip to your support case.

> **Tip:** Reproduce the issue first (for example, sync from Company Portal or retry the failing app install), then run the script right away, so the logs include the problem.

---

## Requirements

- macOS (any version still supported by Microsoft Intune)
- Administrator rights (`sudo`)
- No extra software. The script uses only tools that come with macOS, and runs on the built-in bash 3.2.

---

## Options

```
sudo ./IntuneMacODC.sh [options]
```

| Option | Description | Default |
|---|---|---|
| `-d`, `--days N` | Number of days of unified logs and crash reports to collect (1–30) | `7` |
| `-o`, `--output DIR` | Folder where the zip is created | Current folder |
| `-l`, `--logarchive` | Also create a full unified log archive (`.logarchive`). Large and slow; only use it when support asks for it | Off |
| `-a`, `--all-varlog` | Collect everything under `/var/log` instead of only the install, system, Wi-Fi and Jamf logs | Off |
| `-c`, `--include-cmdline` | Include full process command lines in the process list. **These can contain sensitive data** | Off |
| `-k`, `--keep` | Keep the uncompressed folder next to the zip | Off |
| `-n`, `--no-open` | Don't open Finder when finished | Off |
| `-q`, `--quiet` | Skip the data collection notice prompt (useful for remote or scripted runs) | Off |
| `-D`, `--debug` | Turn on shell tracing (`set -x`) to troubleshoot the script itself | Off |
| `-h`, `--help` | Show help | |

### Examples

```bash
# Default collection (last 7 days)
sudo ./IntuneMacODC.sh

# Issue started two weeks ago
sudo ./IntuneMacODC.sh --days 14

# Unattended run, save to /tmp, don't open Finder
sudo ./IntuneMacODC.sh -q -n -o /tmp

# Everything, including a full log archive
sudo ./IntuneMacODC.sh --days 3 --logarchive --all-varlog
```

---

## What's collected

Inside the zip, data is organized by folder:

| Folder | Contents |
|---|---|
| `system/` | macOS version, kernel, uptime, hardware and software overview, disk and APFS layout, reboot and login history, local accounts, process list, full System Report (`SystemReport.spx`, which you can double-click to open in System Information) |
| `mdm/` | Enrollment and bootstrap token status, device and user configuration profiles (text and XML), `mdmclient` queries (device information, installed profiles, certificates, security info, installed apps, SCEP variables), `MDMOverrides.plist` (PPPC/TCC), `/Library/Managed Preferences` |
| `security/` | FileVault status and recovery key presence, Gatekeeper, System Integrity Protection, application firewall, secure token status, Platform SSO state (`app-sso platform -s`), registered SSO extensions |
| `network/` | Proxy, DNS, network services, interfaces, routing table |
| `apps/` | Installed packages (`pkgutil`) with package details, `/Applications` listing, software update history and settings, Microsoft Edge updater logs |
| `logs/files/` | `/Library/Logs/Microsoft` (including the Intune agent logs), Intune SideCar data, the signed-in user's Company Portal and Microsoft logs, Company Portal SSO extension logs, selected `/var/log` files |
| `logs/unified/` | Filtered unified log extracts for the selected number of days (see below) |
| `crash/` | System and user diagnostic reports from the selected time window (Siri reports excluded) |
| `defender/` | Only if Microsoft Defender for Endpoint is installed: `mdatp health`, wdavstate, and security management policy and report files |
| `jamf/` | Only if Jamf is installed: `jamfAAD gatherAADInfo` output and jamfAAD unified log |
| `collection_manifest.txt` | Run summary: script version, options, signed-in user, and the result of every step (OK / FAIL / SKIP) |

### Unified log extracts

| File | Covers |
|---|---|
| `intune.log` | Intune management agent, Company Portal, Intune-related messages |
| `mdm.log` | `mdmclient`, ManagedClient (profile installation and MDM commands) |
| `ddm_remotemanagement.log` | Declarative Device Management (`remotemanagementd`) |
| `apns.log` | Apple Push Notification service (`apsd`), which affects device check-in |
| `appstore_downloads.log` | App Store, VPP and package downloads and installs |
| `softwareupdate.log` | macOS software updates, including managed update enforcement |
| `sso.log` | Platform SSO, Enterprise SSO extension, AppSSO |
| `jamf_jamfAAD.log` | Jamf / Entra ID registration (only if Jamf is present) |

---

## Privacy

The zip may contain:

- Device name, serial number, and hardware identifiers
- User account names and login history
- Network configuration (IP addresses, DNS servers, proxy settings)
- Installed apps, configuration profiles, and certificate details (no private keys)
- Log entries that can include file paths, URLs, and user or device identifiers

The script does **not** collect user documents, passwords, keychain contents, or private keys. Full process command lines are left out unless you use `--include-cmdline`.

Review the zip before sharing it, and share it only through your support case.

---

## Troubleshooting

| Symptom | What to do |
|---|---|
| `Please run using: sudo ...` | Run the script with `sudo`. |
| `Permission denied` when starting | Run `chmod u+x ./IntuneMacODC.sh` first. |
| Collection takes a long time | Most of the time goes to the unified logs. Use a smaller window, for example `--days 2`. |
| Some items show `FAIL` or `SKIP` in `collection_manifest.txt` | This is expected when a component isn't installed (Defender, Jamf) or a command isn't available on that macOS version. The rest of the collection is still valid. |
| User logs are missing | Make sure a user is signed in to the Mac's desktop (not only over SSH) when you run the script. |
| Terminal can't read some files | Give **Terminal** Full Disk Access in **System Settings > Privacy & Security > Full Disk Access**, then run the script again. |
| The script itself fails | Run it again with `--debug` and attach the Terminal output along with the zip. |

---

## What's new in 2.0

Compared with the original IntuneMacODC:

**Fixes**
- Profile output, reboot history and login history were overwritten. Each command now appends to its output file.
- The jamfAAD output is now added to the zip, and the Jamf log command typo is fixed.
- Fixed a filename typo in the package info output.
- User logs are now read from the signed-in user's home folder instead of root's when the script runs with `sudo`.
- `profiles` commands no longer run twice.

**Improvements**
- Configurable log window (`--days`, default 7 instead of a fixed 30 days)
- Smaller default collection from `/var/log`, and crash reports limited to the selected time window
- A timeout on each command, so a hung tool can't stall the run
- Data organized in folders and compressed once at the end
- `collection_manifest.txt` showing what was collected, failed or skipped
- The zip is owned by the signed-in user, so you can attach it without `sudo`
- Data collection notice, with command lines left out by default

**New data**
- Enrollment and bootstrap token status, Managed Preferences
- Platform SSO and SSO extension state
- FileVault, Gatekeeper, SIP, firewall and secure token status
- Network configuration
- Software update history and logs
- Declarative Device Management logs
- Optional full `.logarchive`

---

## Contributing

Issues and pull requests are welcome. When you add a collection step:

- Use the `run_cmd`, `copy_path`, `copy_glob` or `unified_log` helpers so every step appears in the manifest and has a timeout.
- Keep the script compatible with the bash 3.2 that ships with macOS.
- Don't collect secrets, private keys or user content.
- Test on at least the current and previous major macOS release.

---

## License

MIT. See [LICENSE](LICENSE). This project is based on [markstan/IntuneMacODC](https://github.com/markstan/IntuneMacODC), also under the MIT license.

## Disclaimer

This script is provided "as is", without warranty of any kind. It reads system state and logs, and does not change device configuration.
