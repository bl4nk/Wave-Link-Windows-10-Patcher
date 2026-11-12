<#
.SYNOPSIS
    Patches and installs the Elgato Wave Link v3 installer on Windows 10 systems.
.DESCRIPTION
    This script extracts the Wave Link installer, patches out the Windows 11 requirement, 
    repacks the installer, checks for required dependencies and drivers, installs everything
    for you, and deletes the created temporary files. It can also handle updating between
    versions and will restore settings upon doing so.
.PARAMETER FilePath
    The path to the target Wave Link .msix installer file.
.EXAMPLE
    .\wavelink_win10_patcher.ps1 "C:\Users\bl4nk\Desktop\Elgato.WaveLink_3.3.0.4529_x64.msix"
#>

# Define script usage params
param (
    [string]$FilePath
)

function Main {
    # Define the first param as a string
    param([string]$Path)
    
    # Save user's error preference and set the script to stop on error (preference restored at end/fail)
    $OldErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    
    # Save the user's progress display preference (preference restored at end/fail)
    $OldProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    
    
    # Init variables for later
    $oldPackage = $null
    $backupSettingsDir = $null
    $tempDir = $null
    $copiedFolders = @()
    

    try {
        # Verify a param is given
        if ([string]::IsNullOrWhiteSpace($Path)) {
            Show-Usage
            return
        }

        # Make sure the file exists
        if (-not (Test-Path $Path -PathType Leaf)) {
            Write-Host "`n[ERROR] The file '$Path' does not exist or is invalid." -ForegroundColor Red
            Show-Usage
            return
        }
        
        # Make sure this is ran as an administrator
        if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            # Print the error message and await user input
            Write-Host "[ERROR] PowerShell needs to be run as an Administrator. Please accept the UAC prompt." -ForegroundColor Red
            Write-Host "Press any key to continue and open the administrator prompt..." -ForegroundColor Cyan
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            
            # Resolve the path so it's properly passed to the elevated powershell
            $Path = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
            
            # Pop up the UAC prompt and make sure they accepted
            try {
                $escScriptPath = $PSCommandPath.Replace("'", "''")
                $escInstallPath = $Path.Replace("'", "''")
                
                Start-Process -FilePath "powershell.exe" -ArgumentList "-NoExit -NoProfile -ExecutionPolicy Bypass -Command ""& '$escScriptPath' '$escInstallPath'""" -Verb RunAs
            } catch {
                Write-Host "`n[ERROR] You chose NO on the prompt. The script cannot run without Administrator privileges." -ForegroundColor Red
            }
            
            # A new admin powershell is either ran or not -- exit out
            return
        }
        
        # Create a temporary folder
        $tempDir = Join-Path $env:TEMP ("wavelink_patcher_" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
        
        Write-Host "Using temporary folder: $tempDir" -ForegroundColor Yellow
        
        # Detect the Windows SDK
        Write-Host "Detecting newest Windows SDK folder..."
        $winsdk = Find-WinSDKFolder
        
        # Windows SDK not found, attempt installation
        if ($winsdk) {
            Write-Host "Found Windows SDK folder: $winsdk" -ForegroundColor Yellow
        } else {
            # URL and paths used
            $sdkUrl = 'https://go.microsoft.com/fwlink/?linkid=2382519'
            $sdkInstaller = Join-Path $tempDir 'winsdksetup.exe'
            $sdkLog = Join-Path $tempDir 'winsdk-install.log'
            
            Write-Host "Windows SDK is required and not found" -ForegroundColor Red
            Write-Host "Downloading and installing it now. This may take a few minutes..." -ForegroundColor Yellow
            
            # Download the installer
            Invoke-WebRequest `
                -Uri $sdkUrl `
                -Outfile $sdkInstaller `
                -UseBasicParsing `
                -ErrorAction stop
            
            # Run the installer
            $success = Start-Process `
                -FilePath $sdkInstaller `
                -ArgumentList "/quiet /norestart /log `"$sdkLog`"" `
                -Wait `
                -PassThru `
                -ErrorAction stop
                
            # Install failed
            if ($success.ExitCode -ne 0) {
                throw "Windows SDK installation failed with exit code $($success.ExitCode). Check the log at: $sdkLog"
            }
            
            # Double check the install was successful
            $winsdk = Find-WinSDKFolder
            if (-not $winsdk) {
                throw "Windows SDK setup finished but MakeAppx and/or SignTool were not found. Check the log at: $sdkLog"
            }
            
            Write-Host "Windows SDK was installed successfully" -ForegroundColor Green
        }
        
        # Set up MakeAppx and SignTool
        $makeappx = Join-Path $winsdk 'makeappx.exe'
        $signtool = Join-Path $winsdk 'signtool.exe'
        
        # Extract the installer files
        Write-Host "Unpacking the installer..."
        
        $msixDir = Join-Path $tempDir "msix"
        New-Item -ItemType Directory -Force -Path $msixDir | Out-Null
        
        & $makeappx unpack /p "$Path" /d $msixDir /o | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to unpack MSIX installer"
        }
        
        # Locate the AppxManifest.xml
        $appmanifest = Join-Path $msixDir "AppxManifest.xml"
        if (-not (Test-Path $appmanifest)) {
            throw "AppxManifest.xml not found after unpack"
        }
        
        # Parse the xml
        $xml = [System.IO.File]::ReadAllText($appmanifest, [System.Text.Encoding]::UTF8)
        
        # Check that the installer is for Wave Link
        [xml]$manifest = $xml
        $identity = $manifest.DocumentElement.SelectSingleNode("*[local-name()='Identity']")
        
        if ($identity -eq $null) {
            throw "The installer manifest does not have an Identity element"
        }
        
        if ($identity.GetAttribute("Name") -ne 'Elgato.WaveLink') {
            throw "The MSIX installer you provided is not for Wave Link"
        }
        
        # Get the version number we are trying to install
        $newVersion = [version]$identity.GetAttribute('Version')
        
        Write-Host "Detected installer version: $newVersion" -ForegroundColor Yellow
        
        Write-Host "Checking for previously installed Wave Link installations..."

        # If more than one Wave Link Package is installed
        $installed = @(Get-AppxPackage -Name 'Elgato.WaveLink' -ErrorAction Stop)
        if ($installed.Count -gt 1) {
            throw "More than one Wave Link package is installed. You need to remove the old versions. This patcher only handles single installs."
        }

        # If only one Wave Link install is found
        if ($installed.Count -eq 1) {
            $oldPackage = $installed[0]

            Write-Host "Detected Wave Link Version: $($oldPackage.Version) ($($oldPackage.PackageFamilyName))" -ForegroundColor Yellow
            
            # Version checking
            if ([version]$oldPackage.Version -ge $newVersion) {
                throw "The version you have installed is the same or newer than the one you are trying to install"
            }
        }
            
        # Close down problem programs
        Write-Host "Checking for problem programs to close..."
        CloseProblemPrograms
        
        # Check for Microsoft VCLibs installation
        $vclibPackage = Get-AppxPackage -Name "Microsoft.VCLibs.140.00.UWPDesktop" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Version -ge [version]"14.0.33728.0" -and
                $_.Architecture.ToString() -eq "X64"
            } | Select-Object -First 1
        
        # Install Microsoft VCLibs if not found
        if ($vclibPackage) {
            Write-Host "Detected Microsoft VCLibs $($vclibPackage.Version) ($($vclibPackage.Architecture))" -ForegroundColor Yellow
        } else {
            Write-Host "Microsoft VCLibs 14.0.33728.0 (X64) or newer is required." -ForegroundColor Red
            Write-Host "Downloading and installing it now. This may take a few minutes..." -ForegroundColor Yellow
            
            # Set up URL and temp path
            $vcLibZip = Join-Path $tempDir "VCLibs.zip"
            $downloadUrl = "https://github.com/microsoft/winget-cli/releases/download/v1.9.25180/DesktopAppInstaller_Dependencies.zip"
            
            # Download VCLib installer
            Invoke-WebRequest -Uri $downloadUrl -OutFile $vcLibZip -UseBasicParsing -ErrorAction Stop
            
            # Extract VCLib files into a new folder
            $vcLibFolder = Join-Path $tempDir "vcLib"
            New-Item -ItemType Directory -Path $vcLibFolder -Force | Out-Null
            
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory(
                $vcLibZip,
                $vcLibFolder
            )
            
            # Get VCLibs package path
            $vcLibsPath = Join-Path $vcLibFolder "x64\Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64.appx"
            if (-not (Test-Path $vcLibsPath)) {
                throw "Required VCLibs package not found in download"
            }
            
            # Install VCLib
            Add-AppxPackage -Path $vcLibsPath -ForceApplicationShutdown -ErrorAction stop
            
            # Verify installation
            $vclibPackage = Get-AppxPackage -Name "Microsoft.VCLibs.140.00.UWPDesktop" -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Version -ge [version]"14.0.33728.0" -and
                    $_.Architecture.ToString() -eq "X64"
                } | Select-Object -First 1
                
            if (-not $vclibPackage) {
                throw "Microsoft VCLibs installation verification failed"
            }
            
            Write-Host "Microsoft VCLibs $($vclibPackage.Version) (X64) installed successfully" -ForegroundColor Green
        }
        
        # Check for Windows App Runtime installation
        $appRuntime = Get-AppxPackage -Name 'Microsoft.WindowsAppRuntime.2' -ErrorAction Stop |
            Where-Object {
                $_.Version -ge [version]'2.4.0.0' -and
                $_.Architecture.ToString() -in @('X64', 'Neutral')
            } | Select-Object -First 1
            
        # Install Windows App Runtime if not found
        if ($appRuntime) {
            Write-Host "Detected Windows App Runtime $($appRuntime.Version) ($($appRuntime.Architecture))" -ForegroundColor Yellow
        } else {
            Write-Host "Windows App Runtime 2.4.0.0 or newer is required." -ForegroundColor Red
            Write-Host "Downloading and installing it now. This may take a few minutes..." -ForegroundColor Yellow
            
            # URL and paths used
            $runtimeUrl = 'https://aka.ms/windowsappsdk/2.4/2.4.0/windowsappruntimeinstall-x64.exe'
            $runtimeInstaller = Join-Path $tempDir 'WindowsAppRuntimeInstall-x64.exe'
            
            # Download Windows App Runtime installer
            Invoke-WebRequest `
                -Uri $runtimeUrl `
                -Outfile $runtimeInstaller `
                -UseBasicParsing `
                -ErrorAction Stop
                
            # Run the installer
            $success = Start-Process `
                -FilePath $runtimeInstaller `
                -WindowStyle Hidden `
                -Wait `
                -PassThru `
                -ErrorAction Stop
                
            # Check for successful installation
            if ($success.ExitCode -ne 0) {
                throw "Windows App Runtime installation failed with Exit Code $($success.ExitCode)"
            }
            
            # Verify the installation
            $runtimePackage = Get-AppxPackage -Name "Microsoft.WindowsAppRuntime.2" -ErrorAction Stop |
                Where-Object {
                    $_.Version -ge [version]'2.4.0.0' -and
                    $_.Architecture.ToString() -in @('X64', 'Neutral')
                } | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
                
            if (-not $runtimePackage) {
                throw "Windows App Runtime installation verification failed"
            }
            
            Write-Host "Windows App Runtime $($runtimePackage.Version) ($($runtimePackage.Architecture)) installed successfully" -ForegroundColor Green
        }
        
        Write-Host "Patching the AppxManifest.xml..."
        
        # Replace the minimum required version
        $xml = $xml.Replace('MinVersion="10.0.22000.0"', 'MinVersion="10.0.19041.0"')
        
        # Verify it was patched
        if ($xml -notmatch 'MinVersion="10\.0\.19041\.0"') {
            throw "Failed to patch the minimum Windows version"
        }

        # Replace the publisher
        $xml = [regex]::Replace($xml, '(<Identity\b[^>]*?\bPublisher=")[^"]*(")', '${1}CN=WaveLinkPatched${2}')
        
        # Verify it was patched
        if ($xml -notmatch '<Identity\b[^>]*\bPublisher="CN=WaveLinkPatched"') {
            throw "Failed to patch the publisher"
        }
        
        # Save the modified AppxManifest.xml
        [System.IO.File]::WriteAllText($appmanifest, $xml, [System.Text.Encoding]::UTF8)
        
        # Repack the installer
        $patchedInstaller = Join-Path $tempDir "WaveLink_Installer_Patched.msix"
        Write-Host "Repacking the installer..."
        & $makeappx pack /d $msixDir /p "$patchedInstaller" /o | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to repack MSIX installer"
        }

        # Create a dummy password string (required but doesn't matter what it is)
        $passwordStr = "password"
        $passwordSec = ConvertTo-SecureString $passwordStr -AsPlainText -Force

        # Create a self-signed certificate
        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=WaveLinkPatched" -KeyUsage DigitalSignature -FriendlyName "WaveLinkPatched" -CertStoreLocation "Cert:\CurrentUser\My"

        $certPfx = Join-Path $tempDir "WaveLinkPatchedCert.pfx"
        $certCer = Join-Path $tempDir "WaveLinkPatchedCert.cer"

        # Export the certs
        Write-Host "Creating signing certificate..."
        Export-PfxCertificate -Cert $cert -FilePath $certPfx -Password $passwordSec | Out-Null
        
        Write-Host "Creating public certificate..."
        Export-Certificate -Cert $cert -FilePath $certCer | Out-Null

        # Sign the installer with the new cert
        Write-Host "Signing the patched installer with our new cert.."
        & $signtool sign /fd SHA256 /f "$certPfx" /p $passwordStr "$patchedInstaller" | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to sign the patched installer"
        }

        # Import the cert into the trusted store
        Write-Host "Importing the cert into TrustedPeople..."
        Import-Certificate -FilePath "$certCer" -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" | Out-Null
        
        if ($oldPackage) {
            Write-Host "Closing any active Wave Link processes..."
            
            # Get list of running Wave Link processes
            $curSession = (Get-Process -Id $PID).SessionId
            $packagePath = ($oldPackage.InstallLocation.TrimEnd('\') + '\')
            
            $processes = @(Get-Process -ErrorAction Stop | Where-Object {
                $_.SessionId -eq $curSession -and
                $_.Path -and
                $_.Path.StartsWith($packagePath, [StringComparison]::OrdinalIgnoreCase)
            })
            
            # Close all running Wave Link processes
            foreach ($process in $processes) {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                Wait-Process -Id $process.Id -Timeout 10 -ErrorAction SilentlyContinue
            }
            
            # Get old settings folder
            $oldFolder = Join-Path $env:LOCALAPPDATA ('Packages\' + $oldPackage.PackageFamilyName)
            
            if (Test-Path $oldFolder) {
                # Create settings backup folder
                $backupSettingsDir = Join-Path $tempDir "settings_backup"
                New-Item -ItemType Directory -Path $backupSettingsDir -Force | Out-Null
                
                Write-Host "Backing up old settings: '$oldFolder' -> '$backupSettingsDir'" -ForegroundColor Yellow
                
                # Back up old settings folders
                $copiedFolders = @()
                foreach ($folder in @('LocalCache', 'LocalState', 'RoamingState')) {
                    $source = Join-Path $oldFolder $folder
                    if (Test-Path -LiteralPath $source) {
                        Copy-Folder -Source $source -Destination (Join-Path $backupSettingsDir $folder)
                        $copiedFolders += $folder
                    }
                }
            }
            
            Write-Host "Removing old Wave Link installation..."
            
            # Remove old installation
            Remove-AppxPackage -Package $oldPackage.PackageFullName -ErrorAction Stop
            
            # Check to make sure it was properly removed
            if (Get-AppxPackage -Name 'Elgato.WaveLink' -ErrorAction Stop) {
                throw "The old Wave Link package was not successfully removed."
            }
        }
        
        # Install the patched msix file
        Write-Host "Installing the patched files..."
        Add-AppxPackage -Path "$patchedInstaller" -ForceApplicationShutdown -ErrorAction Stop
        
        # Check for successful installation
        $newPackage = Get-AppxPackage -Name 'Elgato.WaveLink' -ErrorAction stop
        if (-not $newPackage -or [version]$newPackage.Version -ne $newVersion) {
            throw "New version installation failed."
        }
        
        # Check for backed up settings folder to Restore
        if ($backupSettingsDir) {
            Write-Host "Restoring backed up settings files..."
            
            $newSettingsDir = Join-Path $env:LOCALAPPDATA ('Packages\' + $newPackage.PackageFamilyName)
            
            foreach ($folder in $copiedFolders) {
                Copy-Folder -Source (Join-Path $backupSettingsDir $folder) -Destination (Join-Path $newSettingsDir $folder)
            }
        }
        
        Write-Host "Creating directory link to default Elgato Wave Link program data folder..."
        
        # Build paths for the directory junction
        $packagesDir = Join-Path $env:LOCALAPPDATA 'Packages'
        $linkPath = Join-Path $packagesDir 'Elgato.WaveLink_g54w8ztgkx496'
        $targetPath = Join-Path $packagesDir $newPackage.PackageFamilyName
        
        # Check to make sure the patched install has a data folder
        if (-not (Test-Path -LiteralPath $targetPath -PathType Container)) {
            throw "Patched Wave Link data folder not found: $targetPath"
        }
        
        # Does the junction already exist?
        $exists = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
        
        # If it exists already check if it's legit or fail out.. If it doesn't, create the junction
        if ($linkPath -eq $targetPath) {
            Write-Host "Wave Link already using the default program data folder"
        } elseif ($exists) {
            if ($exists.LinkType -eq 'Junction' -and $exists.Target -contains $targetPath) {
                Write-Host "The directory junction already exists"
            } else {
                throw "Could not create the junction due to another folder or junction existing at: $linkPath"
            }
        } else {
            New-Item -ItemType Junction -Path $linkPath -Target $targetPath -ErrorAction Stop | Out-Null
        }
        
        Write-Host "Removing the imported certs..."
        
        # Remove the public certificate from trusted store
        $certPath = "Cert:\CurrentUser\My\$($cert.Thumbprint)"
        if (Test-Path $certPath) {
            Remove-Item -Path $certPath -Force
        }

        # Remove the trusted public certificate
        $trustedCert = "Cert:\LocalMachine\TrustedPeople\$($cert.Thumbprint)"
        if (Test-Path $trustedCert) {
            Remove-Item -Path $trustedCert -Force
        }
        
        # Check for Elgato Audio Driver
        Write-Host "Checking for an installed Elgato Audio Driver..."
        $audioDriver = Get-CimInstance Win32_PnPSignedDriver |
            Where-Object { $_.DeviceName -eq 'Elgato Virtual Audio' } |
            Sort-Object { [version]$_.DriverVersion } -Descending |
            Select-Object -First 1
            
        # If the driver is not found, download and install it
        if ($audioDriver) {
            Write-Host "Detected Elgato Audio Driver: $($audioDriver.DriverVersion)"
        } else {
            Write-Host "Elgato Audio Driver not found." -ForegroundColor Red
            Write-Host "Downloading and installing it now. This may take a few minutes..." -ForegroundColor Yellow
            
            # Get the URL to the latest driver from Elgato
            $driverUrl = (
                'https://gc-updates.elgato.com/windows/ewlw-update/final/device-update-check.php' +
                '?osName=Windows' +
                '&osVersion=10.0.22000.0' +
                '&osPlatform=x86_64' +
                "&appVersion=$newVersion" +
                '&appPlatform=x86_64' +
                '&appLanguage=en-US'
            )
            
            # Get the list of driver updates
            $driverUpdates = Invoke-RestMethod -Uri $driverUrl -ErrorAction Stop
            
            # Choose the newest driver
            $latestDriver = $driverUpdates.appDevices |
                Where-Object { $_.name -eq 'Elgato Wave Link Driver' } |
                ForEach-Object { $_.drivers } |
                Sort-Object { [version]$_.version } -Descending |
                Select-Object -First 1
                
            # Check if driver url was found
            if (-not $latestDriver -or -not $latestDriver.downloadUrl) {
                throw "Elgato did not return a Wave Link Audio Driver download"
            }
            
            # Set up URL and paths
            $driverVersion = [version]$latestDriver.version
            $driverUrl = [string]$latestDriver.downloadUrl
            
            $driverInstaller = Join-Path $tempDir "WaveLinkDriver_$($driverVersion)_x64.msi"
            $driverLog = Join-Path $tempDir "wavelink-driver-install.log"
            
            # Download the driver
            Invoke-WebRequest `
                -Uri $driverUrl `
                -OutFile $driverInstaller `
                -UseBasicParsing `
                -ErrorAction stop
                
            # Install the driver
            $driverInstall = Start-Process `
                -FilePath "$env:SystemRoot\System32\msiexec.exe" `
                -ArgumentList "/i `"$driverInstaller`" /qn /norestart /L*v `"$driverLog`"" `
                -Wait `
                -PassThru `
                -ErrorAction Stop
                
            # Verify the installation was a success
            if ($driverInstall.ExitCode -notin @(0, 3010)) {
                throw "Elgato Wave Link Driver installation failed with Exit Code $($driverInstall.ExitCode). Check the log at: $driverLog"
            }
            
            # Verify the driver was installed successfully
            $uninstallPaths = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            )

            $installedDriver = Get-ItemProperty -Path $uninstallPaths -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq 'Elgato Wave Link Driver' } |
                Sort-Object { [version]$_.DisplayVersion } -Descending |
                Select-Object -First 1

            if (-not $installedDriver -or [version]$installedDriver.DisplayVersion -lt $driverVersion) {
                throw "Elgato Wave Link Driver installation verification failed. Check the log at: $driverLog"
            }
            
            Write-Host "Elgato Wave Link Driver $($installedDriver.DisplayVersion) successfully installed" -ForegroundColor Green
        }
        
        # Remove the temporary files
        Write-Host "Removing the temporary files..."
        Remove-Item -Path $tempDir -Recurse -Force
        
        Write-Host "`nInstallation complete! Launching Wave Link..." -ForegroundColor Green
        
        # Attempt launching Wave Link
        try {
            $launchManifest = Get-AppxPackageManifest -Package $newPackage.PackageFullName -ErrorAction stop
            $application = $launchManifest.Package.Applications.Application |
                Where-Object { $_.Executable -like '*Elgato.WaveLink.exe' } |
                Select-Object -First 1
                
            if (-not $application) {
                throw "Could not find the Wave Link application ID"
            }
            
            $appId = "$($newPackage.PackageFamilyName)!$($application.Id)"
            
            Start-Process -FilePath 'explorer.exe' `
                -ArgumentList "shell:AppsFolder\$appId" `
                -ErrorAction Stop
        } catch {
            Write-Host "Wave Link was installed, but could not be launched automatically: $_" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "`n[FATAL ERROR] Script execution halted: `n$_" -ForegroundColor Red
        
        # If temp files exist, prompt use for deletion
        if ($tempDir -and (Test-Path -LiteralPath $tempDir)) {
            Write-Host "`nTemporary files folder: $tempDir" -ForegroundColor Yellow
            
            $settingsBackupFolder = Join-Path $tempDir 'settings_backup'
            if (Test-Path -LiteralPath $settingsBackupFolder) {
                Write-Host "This folder contains your settings backup. Keep it if you need to recover them later."
            }
            
            $answer = Read-Host "Delete the temporary folder and all files inside it?`nType YES to delete or press enter to keep them"
            if ($answer.Trim() -ieq 'YES') {
                try {
                    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction stop
                    Write-Host "Temporary files deleted"
                } catch {
                    Write-Host "Could not delete the temporary files: $_" -ForegroundColor Yellow
                }
            } else {
                Write-Host "Temporary files were not deleted"
            }
        }
    } finally {
        # Restore the user's old error and progress display preferences
        $ErrorActionPreference = $OldErrorAction
        $ProgressPreference = $OldProgressPreference
    }
}

function Show-Usage {
    $ScriptName = Split-Path -Leaf $PSCommandPath
    
    Write-Host "Usage:"
    Write-Host "  .\$ScriptName `"<path_to_file>`"" -ForegroundColor Yellow
    Write-Host "Example:"
    Write-Host "  .\$ScriptName `"C:\Elgato.WaveLink_3.3.0.4529_x64.msix`"" -ForegroundColor Cyan
}

function Find-WinSDKFolder {
    $rawArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $arch = switch ($rawArch.ToLower()) {
        "amd64"   { "x64" }
        "arm64"   { "arm64" }
        "x86"     { "x86" }
        default   { $null }
    }
    
    if (-not $arch) {
        Write-Host "ERROR: Could not detect hardware architecture" -ForegroundColor Red
        return $null
    }

    $roots = @("C:\Program Files (x86)\Windows Kits\10\bin", "C:\Program Files\Windows Kits\10\bin")
    $foundFiles = foreach ($r in $roots) {
        if (Test-Path $r) {
            Get-ChildItem $r -Recurse -Filter 'makeappx.exe' -ErrorAction SilentlyContinue | 
                Where-Object {
                    $_.DirectoryName -like "*\$arch" -and
                    (Test-Path (Join-Path $_.DirectoryName "signtool.exe"))
                }
        }
    }

    if ($foundFiles) {
        $newest = $foundFiles | Sort-Object { 
            [version]($_.Directory.Parent.Name) 
        } -Descending | Select-Object -First 1

        return $newest.DirectoryName
    }

    return $null
}

function CloseProblemPrograms {
    $problemProgs = @("AppInstaller", "WinStore.App")
    foreach ($process in $problemProgs) {
        $running = Get-Process -Name $process -ErrorAction SilentlyContinue
        if ($running) {
                Write-Host "Closing $process..."
                $running | Stop-Process -Force -ErrorAction SilentlyContinue
                $running | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue

                if (Get-Process -Name $process -ErrorAction SilentlyContinue) {
                    Write-Host "[WARNING] $process is still running." -ForegroundColor Yellow
                }
        }
    }
}

function Copy-Folder {
    param([string]$Source, [string]$Destination)
    
    # Create the new folder
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    
    # Copy files/folders using robocopy (returns 0-7 for success and 8+ for failure)
    & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /NP /NFL /NDL /NJH /NJS | Out-Null
    
    # Check for errors
    if ($LASTEXITCODE -ge 8) {
        throw "Backup copy failed ($LASTEXITCODE): '$Source' -> '$Destination'"
    }   
}

Main -Path $FilePath