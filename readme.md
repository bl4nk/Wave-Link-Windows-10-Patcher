# Wave Link v3 Windows 10 Patcher

An automated PowerShell script to patch and install the Elgato Wave Link MSIX package on Windows 10 systems. The script unpacks the installer, patches out the Windows 11 requirement, handles certificate signing, and automatically cleans up temporary files after a successful installation.

## Prerequisites

Before running the patcher, ensure you have the following:

1. **Wave Link Installer**: Download the latest official package from the [Elgato Downloads Page](https://www.elgato.com/us/en/s/downloads).
2. **Windows SDK**: The script requires tools contained inside the Windows SDK. 

### Verifying Windows SDK Installation
Check if you already have the SDK by looking for version-labeled folders in either of these directories:
* `C:\Program Files\Windows Kits\10\bin`
* `C:\Program Files (x86)\Windows Kits\10\bin`

> **Missing the SDK?** You can grab the latest version from the [Official Microsoft Windows SDK Downloads](https://learn.microsoft.com/en-us/windows/apps/windows-sdk/downloads). Download and install the newest release. It will function properly even if labeled exclusively for Windows 11.

---

## Usage Instructions

1. Open **PowerShell** with **Administrator** privileges.
2. Navigate to the folder containing `wavelink_win10_patcher.ps1`.
3. Execute the script by passing the target path of your downloaded `.msix` file as a parameter:

```powershell
.\wavelink_win10_patcher.ps1 "C:\Users\bl4nk\Desktop\Elgato.WaveLink_3.3.0.4529_x64.msix"
```

The script will automatically patch the installer, install the program, and delete the temporary files upon completion.

> **NOTE:** If you wish to retain the patched installer or temporary files afterwards, delete/comment out the *Remove-Item* lines in the script.

---

## Troubleshooting

### Execution Policy Error
If PowerShell returns an error stating that the script *“cannot be loaded because running scripts is disabled on this system”*, your current execution policy context is blocking third-party scripts.

To temporarily bypass this restriction for your **active PowerShell session only**, run this command:

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process
```

Once executed, re-run the patcher script normally.

---

## Credits & Motivation

This script was inspired by [DRDRDRRDDRDR](https://github.com/DRDRDRRDDRDR). He made a whole program to handle everything, but I created this because I was having problems with his implementation, and I was looking for a simple script-based solution rather than a full application to handle the patch/installation process.