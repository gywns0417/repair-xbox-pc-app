# Xbox App / Microsoft Store 0x80096004 Repair Tool

[![Windows](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D4)](#requirements)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)](#quick-run)
[![Unofficial](https://img.shields.io/badge/Microsoft-Unofficial-lightgrey)](#trademark-notice)
[![License](https://img.shields.io/badge/License-Apache--2.0-green)](#license)
<img width="2172" height="724" alt="7155348a-a341-4ff1-9ba2-2d1f115b60d5" src="https://github.com/user-attachments/assets/87aaacc0-2037-49cd-a58c-7009e5b39ae4" />

**Korean:** [READMEko.md](README.md)

Fixes common Xbox app, PC Game Pass, and Microsoft Store installation failures caused by broken Windows Update state or stale trusted root certificates.

This tool was created for Windows PCs where the Xbox app or Microsoft Store fails with errors such as `0x80096004`, often after Windows Update has been disabled for a long time or its working folders have been damaged.

It does **not** bypass Xbox, Game Pass, Microsoft Store, account, payment, region, DRM, or license checks.

---

## What It Fixes

| Symptom | What this tool checks or repairs |
| --- | --- |
| Xbox app install fails from Microsoft Store | Starts Microsoft Store and Windows Update related services |
| PC Game Pass app install fails | Refreshes trusted root certificates used for signature validation |
| `0x80096004` during Store install | Repairs certificate trust state through Windows Update root sync |
| `wuauserv` will not start | Restores Windows Update service startup and required folders |
| `wuauserv` or `DoSvc` stays Disabled | Repairs WubLock, service registry ACLs, and svchost group membership |
| Store install fails with `0x8024500c` | Clears Windows Update policy cache (`UpdatePolicy\GPCache`) and Store cache |
| Xbox page says Store client update is required | Updates Microsoft Store with `WSReset.exe -i` |
| `The system cannot find the path specified` from Windows Update | Repairs `C:\Windows\SoftwareDistribution` when it is missing or blocked by a file |
| Store installs fail on PC bangs, public PCs, or long-frozen Windows images | Restores the minimum update/certificate state needed for Store package validation |

`0x80096004` is commonly associated with `TRUST_E_CERT_SIGNATURE`, which can happen when Windows cannot validate a Store package signature because its trusted root certificate store is stale or Windows Update cannot fetch the required trust data.

---

## Quick Run

Run from an elevated PowerShell prompt:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\XboxGamePass_PCBang_Fix.ps1
```

Or run the packaged executable as administrator:

```powershell
.\XboxGamePass_PCBang_Fix.exe
```

After the tool finishes, retry the Xbox app, PC Game Pass, or Microsoft Store installation.

---

## Required Final Steps

Run the repair tool first, then finish the fix from Microsoft Store:

1. Run this tool as administrator.
2. Open Microsoft Store.
3. Sign in with the Microsoft account you will use in the Xbox app.
4. In Microsoft Store, update the Xbox app.
5. Close and restart the Xbox app.

The repair is usually not complete until the Xbox app is updated through Microsoft Store after the certificate and Windows Update repair.

---

## Getting Started

1. Download the latest release or clone this repository.
2. Right-click PowerShell and choose **Run as administrator**.
3. Run the script or executable.
4. Confirm that Windows Update, BITS, Cryptographic Services, and Microsoft Store Install Service report `Running`.
5. Follow the required final steps above in Microsoft Store.

---

## What It Does


| Step | Action |
| --- | --- |
| 1 | Removes common Windows Update blocking policy values when present: `DisableWindowsUpdateAccess`, `NoAutoUpdate`, `UseWUServer` |
| 2 | Removes WSUS/internet Windows Update blockers: `DoNotConnectToWindowsUpdateInternetLocations`, `WUServer`, `WUStatusServer`, and `UpdateServiceUrlAlternate` |
| 3 | Repairs WubLock or PC bang management tool service registry ACL locks |
| 4 | Restores missing `wuauserv`/`DoSvc` entries in `svchost` groups |
| 5 | Removes leftover blocking values from the Windows Update internal policy cache (`UpdatePolicy\GPCache`) |
| 6 | Repairs Windows Update working folders: `SoftwareDistribution`, `DataStore`, `Download`, and `catroot2` |
| 7 | Enables and starts `wuauserv`, `BITS`, `CryptSvc`, `UsoSvc`, `DoSvc`, `InstallService`, and `WaaSMedicSvc` |
| 8 | Verifies that the Windows Update search API works without `0x8024500c` |
| 9 | Updates an old Microsoft Store client with `WSReset.exe -i` |
| 10 | Clears Microsoft Store cache |
| 11 | Generates a root certificate store file with `certutil -generateSSTFromWU` and imports it with `certutil -addstore -f Root` |
| 12 | Opens the Xbox app Store page after a successful repair |


---

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or later
- Administrator privileges
- Network access to Windows Update certificate endpoints
- Permission to modify the target PC

---

## Safety Notes

Use this tool only on a PC you own or administer, or on a PC where the owner or administrator has explicitly allowed this repair.

The tool can change:

- Windows Update policy values
- Windows service startup settings
- Windows Update working folders
- The local machine trusted root certificate store

On PC bang, school, company, or other managed PCs, run it only with permission from the system owner or administrator.

---

## Non-Goals

This project does **not**:

- Bypass Xbox, Game Pass, Microsoft Store, payment, account, region, DRM, or license checks
- Patch or modify Microsoft Store, Xbox app, or game binaries
- Modify game files
- Collect account information
- Contact a custom remote server
- Register a startup task
- Stay resident in the background
- Disable antivirus or endpoint protection

---

## Build

The executable is a small C# launcher that runs the PowerShell repair script. If the `.ps1` file is next to the executable, the launcher uses it. If the executable is copied alone, it extracts the embedded script to a temporary folder and runs that copy.

Build from Windows PowerShell:

```powershell
$src = ".\XboxGamePass_PCBang_Fix_Launcher.cs"
$script = ".\XboxGamePass_PCBang_Fix.ps1"
$out = ".\XboxStoreCertRepair.exe"

Add-Type -AssemblyName Microsoft.CSharp
$provider = New-Object Microsoft.CSharp.CSharpCodeProvider
$params = New-Object System.CodeDom.Compiler.CompilerParameters
$params.GenerateExecutable = $true
$params.GenerateInMemory = $false
$params.OutputAssembly = $out
$params.CompilerOptions = "/target:exe"
[void]$params.ReferencedAssemblies.Add("System.dll")
[void]$params.EmbeddedResources.Add($script)
$result = $provider.CompileAssemblyFromFile($params, $src)

if ($result.Errors.Count -gt 0) {
    $result.Errors | ForEach-Object { $_.ToString() }
    exit 1
}
```

---

## Trademark Notice

Microsoft, Windows, Microsoft Store, Xbox, and Game Pass are trademarks of the Microsoft group of companies.

**This project is independent and is not affiliated with, endorsed by, sponsored by, or approved by Microsoft. Product names are used only to describe compatibility and the installation errors this tool is intended to repair.**

---

## License

Apache License 2.0. See [LICENSE](LICENSE).
