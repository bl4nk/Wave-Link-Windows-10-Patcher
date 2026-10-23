<#
.SYNOPSIS
	Patches and installs the Elgato Wave Link v3 installer on Windows 10 systems.
.DESCRIPTION
	This script extracts the Wave Link installer, modifies the AppxManifest.xml, 
	repacks the installer, generates a custom self-signed certificate, installs 
	the patched file, and deletes temporary files.
.PARAMETER FilePath
	The path to the target Wave Link .msix installer file.
.EXAMPLE
	.\patcher_new.ps1 "C:\Users\bl4nk\Desktop\Elgato.WaveLink_3.3.0.4529_x64.msix"
.NOTES
	This script must be ran as an Administrator in order to work properly.
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
			
			# Pop up the UAC prompt and make sure they accepted
			try {
				Start-Process -FilePath "powershell.exe" -ArgumentList "-NoExit -NoProfile -ExecutionPolicy Bypass -Command ""& '$PSCommandPath' '$Path'""" -Verb RunAs
			} catch {
				Write-Host "`n[ERROR] You chose NO on the prompt. The script cannot run without Administrator privileges." -ForegroundColor Red
			}
			
			# A new admin powershell is either ran or not -- exit out
			return
		}
		
		# Get the newest available Windows SDK folder
		Write-Host "Detecting newest Windows SDK folder..."
		$winsdk = Find-WinSDKFolder
		if (-not $winsdk) {
			Write-Host "`n[ERROR] Windows SDK not found!" -ForegroundColor Red
			DownloadSDK-Message
            return
		}

		Write-Host "Found Windows SDK folder: $winsdk" -ForegroundColor Yellow

		# Check for makeappx.exe
		$makeappx = Join-Path $winsdk "makeappx.exe"
		if (-not (Test-Path $makeappx)) {
			Write-Host "`n[ERROR] makeappx.exe not found, reinstall your Windows SDK" -ForegroundColor Red
			DownloadSDK-Message
            return
		}
		
		# Check for signtool.exe
		$signtool = Join-Path $winsdk "signtool.exe"
		if (-not (Test-Path $signtool)) {
			Write-Host "`n[ERROR] signtool.exe not found, reinstall your Windows SDK" -ForegroundColor Red
			DownloadSDK-Message
            return
		}
		
		# Create a temporary folder
		$tempDir = Join-Path $env:TEMP ("wavelink_patcher_" + [guid]::NewGuid().ToString("N"))
		New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
		
		Write-Host "Using temporary folder: $tempDir" -ForegroundColor Yellow
		
		# Extract the installer files
		Write-Host "Unpacking the installer..."
        
        $msixDir = Join-Path $tempDir "msix"
        New-Item -ItemType Directory -Force -Path $msixDir | Out-Null
        
		& $makeappx unpack /p "$Path" /d $msixDir /o | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to unpack MSIX installer" -ForegroundColor Red
            return
        }
		
		# Locate the AppxManifest.xml
		$appmanifest = Join-Path $msixDir "AppxManifest.xml"
		if (-not (Test-Path $appmanifest)) {
			Write-Host "`n[ERROR] AppxManifest.xml not found after unpack" -ForegroundColor Red
            return
		}
		
		Write-Host "Patching the AppxManifest.xml..."
		
		# Replace the minimum required version
		$xml = [System.IO.File]::ReadAllText($appmanifest, [System.Text.Encoding]::UTF8)
		$xml = $xml.Replace('MinVersion="10.0.22000.0"', 'MinVersion="10.0.19041.0"')

		# Replace the publisher (used later on with the self-signed cert)
		$xml = [regex]::Replace($xml, '(<Identity\b[^>]*?\bPublisher=")[^"]*(")', '${1}CN=WaveLinkPatched${2}')
		
		# Save the modified AppxManifest.xml
		[System.IO.File]::WriteAllText($appmanifest, $xml, [System.Text.Encoding]::UTF8)
		
		# Repack the installer
		$patchedInstaller = Join-Path $tempDir "WaveLink_Installer_Patched.msix"
		Write-Host "Repacking the installer as: $patchedInstaller" -ForegroundColor Yellow
		& $makeappx pack /d $msixDir /p "$patchedInstaller" /o | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to repack MSIX installer" -ForegroundColor Red
            return
        }

		# Create a dummy password string (required but doesn't matter what it is)
		$passwordStr = "password"
		$passwordSec = ConvertTo-SecureString $passwordStr -AsPlainText -Force

		# Create a self-signed certificate
		$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=WaveLinkPatched" -KeyUsage DigitalSignature -FriendlyName "WaveLinkPatched" -CertStoreLocation "Cert:\CurrentUser\My"

        $certPfx = Join-Path $tempDir "WaveLinkPatchedCert.pfx"
        $certCer = Join-Path $tempDir "WaveLinkPatchedCert.cer"

		# Export the certs
        Write-Host "Creating signing certificate: $certPfx" -ForegroundColor Yellow
        Export-PfxCertificate -Cert $cert -FilePath $certPfx -Password $passwordSec | Out-Null
        
		Write-Host "Creating public certificate: $certCer" -ForegroundColor Yellow
		Export-Certificate -Cert $cert -FilePath $certCer | Out-Null

		# Sign the installer with the new cert
		Write-Host "Signing the patched installer with our new cert.."
		& $signtool sign /fd SHA256 /a /f "$certPfx" /p $passwordStr "$patchedInstaller" | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Failed to sign the patched installer" -ForegroundColor Red
            return
        }

		# Import the cert into the trusted store
		Write-Host "Importing the cert into TrustedPeople..."
		Import-Certificate -FilePath "$certCer" -CertStoreLocation "Cert:\LocalMachine\TrustedPeople" | Out-Null
        
        # Check for dependencies
        $vclibPackage = Get-AppxPackage -Name "Microsoft.VCLibs.140.00.UWPDesktop" -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Version -ge [version]"14.0.33728.0" -and
                $_.Architecture.ToString() -eq "X64"
            } | Select-Object -First 1
        
        if ($vclibPackage) {
            Write-Host "Detected Microsoft VCLibs $($vclibPackage.Version) ($($vclibPackage.Architecture))..." -ForegroundColor Yellow
        } else {
            Write-Host "Microsoft VCLibs 14.0.33728.0 (X64) or newer is required." -ForegroundColor Red
            Write-Host "Downloading and installing Microsoft VCLibs..."
            
            # Download VCLib files
            $vcLibZip = "$tempDir\VCLibs.zip"
            $downloadUrl = "https://github.com/microsoft/winget-cli/releases/download/v1.9.25180/DesktopAppInstaller_Dependencies.zip"
            
            Invoke-WebRequest -Uri $downloadUrl -OutFile $vcLibZip -ErrorAction Stop
            
            # Extract VCLib files into a new folder
            $vcLibFolder = Join-Path $tempDir "vcLib"
            New-Item -ItemType Directory -Path $vcLibFolder -Force | Out-Null
            Expand-Archive -Path $vcLibZip -DestinationPath $vcLibFolder -Force
            
            # Get VCLibs package path
            $vcLibsPath = Join-Path $vcLibFolder "x64\Microsoft.VCLibs.140.00.UWPDesktop_14.0.33728.0_x64.appx"
            if (-not (Test-Path $vcLibsPath)) {
                Write-Host "Required VCLibs package not found in download" -ForegroundColor Red
                return
            }
            
            # Close down problem programs
            CloseProblemPrograms
            
            # Install VCLib
            Add-AppxPackage -Path $vcLibsPath -ForceApplicationShutdown -ErrorAction stop
            
            # Verify installation
            $vclibPackage = Get-AppxPackage -Name "Microsoft.VCLibs.140.00.UWPDesktop" -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Version -ge [version]"14.0.33728.0" -and
                    $_.Architecture.ToString() -eq "X64"
                } | Select-Object -First 1
                
            if (-not $vclibPackage) {
                Write-Host "Microsoft VCLibs installation verification failed" -ForegroundColor Red
                return
            }
            
            Write-Host "Microsoft VCLibs $($vclibPackage.Version) (X64) installed successfully" -ForegroundColor Green
        }
            
        # Close down problem programs
        CloseProblemPrograms
        
		# Install the patched msix file
		Write-Host "Installing the patched files..."
		Add-AppxPackage -Path "$patchedInstaller" -ForceApplicationShutdown -ErrorAction Stop
        
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
		
		# Remove the temporary files
		Write-Host "Removing the temporary files..."
		Remove-Item -Path $tempDir -Recurse -Force
		
		Write-Host "`nInstallation complete!" -ForegroundColor Green
	} catch {
		Write-Host "`n[FATAL ERROR] Script execution halted: `n$_" -ForegroundColor Red
	} finally {
		# Restore the user's old error preference
		$ErrorActionPreference = $OldErrorAction
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
		"amd64"	  { "x64" }
		"arm64"	  { "arm64" }
		"x86"	  { "x86" }
		default	  { $null }
	}
	
	if (-not $arch) {
		Write-Host "ERROR: Could not detect hardware architecture" -ForegroundColor Red
		return $null
	}

	$roots = @("C:\Program Files (x86)\Windows Kits\10\bin", "C:\Program Files\Windows Kits\10\bin")
	$foundFiles = foreach ($r in $roots) {
		if (Test-Path $r) {
			Get-ChildItem $r -Recurse -Filter makeappx.exe -ErrorAction SilentlyContinue | 
				Where-Object { $_.DirectoryName -like "*\$arch" }
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

function DownloadSDK-Message {	
	Write-Host "Download one from https://learn.microsoft.com/en-us/windows/apps/windows-sdk/downloads"
	Write-Host "Just download the newest version, even if it's for Windows 11"
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

Main -Path $FilePath