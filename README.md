# Install-DellISM

Unattended PowerShell installer for Dell iDRAC Service Module (iSM) on Windows Server PowerEdge hosts. Built to be pushed from ConnectWise RMM (Asio) as SYSTEM, but it runs from any RMM or an elevated prompt.

It needs no parameters. The script works out the server generation and OS, picks the matching Dell package, verifies it, installs it silently and never reboots.

## What it does

1. Relaunches itself in 64-bit PowerShell if the RMM started it in 32-bit.
2. Skips anything that is not a Dell PowerEdge running Windows Server (VMs, other vendors, client OSes).
3. Derives the PowerEdge generation from the model string and maps generation + OS to a Dell iSM package.
4. Skips if the same or a newer iSM is already installed.
5. Downloads the package from dl.dell.com and checks its SHA-256 against the value on Dell's driver page.
6. Extracts the web pack and runs `iDRACSvcMod.msi` with `/qn /norestart REBOOT=ReallySuppress`.
7. Confirms the installed version and that the iSM service is running.

Older iSM versions are upgraded in place. The script never downgrades.

## Requirements

- Windows Server 2016, 2019, 2022 or 2025 on a Dell PowerEdge with iDRAC (12G through 17G)
- Windows PowerShell 5.1
- Run as SYSTEM or a local administrator
- Outbound HTTPS to `dl.dell.com`

## Package selection

| iSM version | Dell driver ID | Generations | Windows Server |
|---|---|---|---|
| 6.1.0.0 | [V2H2D](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=v2h2d) | 15G, 16G, 17G | 2022, 2025 |
| 5.4.1.1 | [GC9TH](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=gc9th) | 14G, 15G, 16G | 2019, 2022, 2025 |
| 4.3.0.0 | [N6KY8](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=n6ky8) | 13G, 14G, 15G | 2019, 2022 |
| 4.2.0.0 | [56GJN](https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=56gjn) | 12G - 15G | 2016, 2019, 2022 |

The newest package that supports both the generation and the OS wins. Combinations Dell publishes no package for (for example 13G on Server 2025, or 17G on Server 2019) are skipped.

## Running it from ConnectWise RMM (Asio)

- Script type: PowerShell
- Run as: System
- Timeout: 900 seconds (15 minutes). The script itself is bounded to about 11.5 minutes worst case.
- Parameters: none required

It is safe to target a mixed group. Hosts the script does not apply to exit 0 with a `SKIPPED` line.

### Optional: force a reinstall

The script contains one Asio placeholder, `@ForceReinstall@`. Leave it undefined for normal use. Set it to `true` to reinstall iSM even when the target version is already present. A newer installed version is still left alone.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Installed, upgraded, already current, or not applicable to this host |
| 1 | Failure (download, hash, extraction, msiexec, or service check) |
| 2 | PowerEdge model string the script could not map to a generation |
| 3 | Not running elevated |

msiexec 3010 (reboot pending) is treated as success and reported in the log. No reboot is started.

## Logs

| File | Contents |
|---|---|
| `C:\ProgramData\DellISM\Install-DellISM.log` | Script log, appended on every run |
| `C:\ProgramData\DellISM\msi-<timestamp>.log` | Verbose msiexec log for that run |

The same lines go to stdout, so they show up in the RMM job output. If the RMM status and the log disagree, trust the log.

## Troubleshooting

- **`Download failed`** - the host could not reach `dl.dell.com`, or a web filter blocked it. The log line carries the HTTP or network error.
- **`SHA-256 mismatch`** - the downloaded file is not the package Dell published. Usually a filter or proxy returned a block page.
- **`msiexec did not finish within 300 s`** - the install was left running. Check the msiexec log, then rerun; a completed install reports `SKIPPED`.
- **`UNKNOWN MODEL`** (exit 2) - add the model to `$ModelExceptions` near the top of the script.
- **Service running but no `Remote NDIS` adapter** - enable OS to iDRAC Pass-through (USB NIC) in the iDRAC settings.

## Updating for a new iSM release

Edit the `$Packages` table at the top of the script. Each entry needs the version, the supported generations and OS versions, the download URL and the SHA-256 from Dell's driver page. Keep the table ordered newest first.

## Notes

- Versions are compared on the first three fields (Major.Minor.Build), the same way Windows Installer compares them.
- Package URLs and hashes were last checked against Dell's driver pages in November 2026.
- Test on one server before a wide rollout.
