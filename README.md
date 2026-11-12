# Wave Link v3 Windows 10 Patcher

An automated PowerShell script to patch and install the Elgato Wave Link MSIX package on Windows 10 systems. The script unpacks the installer, patches out the Windows 11 requirement, checks for and installs required dependencies, and automatically cleans up temporary files after a successful installation. It can also handle updating between versions and will restore your settings upon doing so.

## Prerequisites

Before running the patcher, ensure you have the following:

1. **Wave Link Installer**: Download the latest official package from the [Elgato Downloads Page](https://www.elgato.com/us/en/s/downloads).
2. Previously the Windows SDK, Microsoft VCLibs, and Windows App Runtime were needed as well, but the script now handles installing them automatically.

---

## Usage Instructions

1. Open **PowerShell** with **Administrator** privileges.
2. Navigate to the folder containing `wavelink_win10_patcher.ps1`.
3. Execute the script by passing the target path of your downloaded `.msix` file as a parameter:

```powershell
.\wavelink_win10_patcher.ps1 "C:\Users\bl4nk\Desktop\Elgato.WaveLink_3.3.0.4529_x64.msix"
```

The script will automatically patch the installer, install the program, and delete the temporary files upon completion.

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

## Credits, Motivation, and Thanks

This script was inspired by [DRDRDRRDDRDR](https://github.com/DRDRDRRDDRDR). He made a whole program to handle everything, but I created this because I was having problems with his implementation, and I was looking for a simple script-based solution rather than a full application to handle the patch/installation process.

Thanks to BurdTird for pointing out problems with VCLib being required and helping test out how to get it fixed.

---

## Screenshots

![Elgato Wave Link Windows 10 Patcher example](https://github.com/user-attachments/assets/24f022d8-3fce-4b56-930f-60a10d5e5db6)

![Elgato Wave Link v3 running on Windows 10](https://github.com/user-attachments/assets/74926d82-8adf-4535-b6f1-9df11e71df4f)
