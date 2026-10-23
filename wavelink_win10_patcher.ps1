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
			Exit
		}

		# Make sure the file exists
		if (-not (Test-Path $Path -PathType Leaf)) {
			Write-Host "`n[ERROR] The file '$Path' does not exist or is invalid." -ForegroundColor Red
			Show-Usage
			Exit
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
				Write-Host "`n[ERROR] You chose NO on the prompt. The script cannot run without Administrator priveleges." -ForegroundColor Red
			}
			
			# A new admin powershell is either ran or not -- exit out
			Exit
		}
		
		# Get the newest available Windows SDK folder
		Write-Host "Detecting newest Windows SDK folder..."
		$winsdk = Find-WinSDKFolder
		if (-not $winsdk) {
			Write-Host "`n[ERROR] Windows SDK not found!" -ForegroundColor Red
			DownloadSDK-Message
			Exit
		}

		Write-Host "Found Windows SDK folder: $winsdk" -ForegroundColor Yellow

		# Check for makeappx.exe
		$makeappx = Join-Path $winsdk "makeappx.exe"
		if (-not (Test-Path $makeappx)) {
			Write-Host "`n[ERROR] makeappx.exe not found, reinstall your Windows SDK" -ForegroundColor Red
			DownloadSDK-Message
			Exit
		}
		
		# Check for signtool.exe
		$signtool = Join-Path $winsdk "signtool.exe"
		if (-not (Test-Path $signtool)) {
			Write-Host "`n[ERROR] signtool.exe not found, reinstall your Windows SDK" -ForegroundColor Red
			DownloadSDK-Message
			Exit
		}
		
		# Create a temporary folder
		$tempDir = Join-Path $env:TEMP ("wavelink_patcher_" + [guid]::NewGuid().ToString("N"))
		New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
		
		Write-Host "Using temporary folder: $tempDir" -ForegroundColor Yellow
		
		# Extract the installer files
		Write-Host "Unpacking the installer..."
		& $makeappx unpack /p "$Path" /d "$tempDir" /o | Out-Null
		
		# Locate the AppxManifest.xml
		$appmanifest = Join-Path $tempDir "AppxManifest.xml"
		if (-not (Test-Path $appmanifest)) {
			Write-Host "`n[ERROR] AppxManifest.xml not found after unpack" -ForegroundColor Red
			Exit
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
		$patchedInstaller = "$PSScriptRoot\WaveLink_Installer_Patched.msix"
		Write-Host "Repacking the installer as: $patchedInstaller" -ForegroundColor Yellow
		& $makeappx pack /d "$tempDir" /p "$patchedInstaller" /o | Out-Null

		# Create a dummy password string (required but doesn't matter what it is)
		$passwordStr = "password"
		$passwordSec = ConvertTo-SecureString $passwordStr -AsPlainText -Force

		# Create a self-signed certificate
		$cert = New-SelfSignedCertificate -Type Custom -Subject "CN=WaveLinkPatched" -KeyUsage DigitalSignature -FriendlyName "WaveLinkPatched" -CertStoreLocation "Cert:\CurrentUser\My"

		# Export the cert
		$certFile = "$PSScriptRoot\WaveLinkPatchCert.pfx"
		Write-Host "Creating self-signed certificate: $certFile" -ForegroundColor Yellow
		Export-PfxCertificate -Cert $cert -FilePath $certFile -Password $passwordSec | Out-Null

		# Sign the installer with the new cert
		Write-Host "Signing the patched installer with our new cert.."
		& $signtool sign /fd SHA256 /a /f "$certFile" /p $passwordStr "$patchedInstaller" | Out-Null

		# Import the cert into the Local Machine store
		Write-Host "Importing the cert into your Local Machine store..."
		Import-PfxCertificate -FilePath "$certFile" -CertStoreLocation "Cert:\LocalMachine\Root" -Password $passwordSec | Out-Null

		# Install the patched msix file
		Write-Host "Installing the patched files..."
		Add-AppxPackage -Path "$patchedInstaller" -ErrorAction Stop
        
        Write-Host "Removing the generated/imported certs..."
        
        # Remove the certificate from the personal CurrentUser store where it was generated
        if (Test-Path "Cert:\CurrentUser\My\$($cert.Thumbprint)") {
            Remove-Item -Path "Cert:\CurrentUser\My\$($cert.Thumbprint)" -Force
        }
        
        # Remove the certificate from the trusted LocalMachine store where it was imported
        if ($cert.Thumbprint) {
            & certutil.exe -delstore Root $($cert.Thumbprint) | Out-Null
        }
		
		# Remove the temporary files
		Write-Host "Removing the temporary files..."
		Remove-Item -Path $tempDir -Recurse -Force
		Remove-Item -Path $patchedInstaller -Force
		Remove-Item -Path $certFile -Force
		
		Write-Host "`nInstallation complete!" -ForegroundColor Green
	} catch {
		Write-Host "`n[FATAL ERROR] Script execution halted: `n$_" -ForegroundColor Red
		Exit
	} finally {
		# Restore the user's old error preference
		$ErrorActionPreference = $OldErrorAction
	}
}

function Show-Usage {
	$ScriptName = $MyInvocation.MyCommand.Name
	
	Write-Host "Usage:"
	Write-Host '  .\$ScriptName "<path_to_file>"' -ForegroundColor Yellow
	Write-Host "Example:"
	Write-Host '  .\$ScriptName "C:\Elgato.WaveLink_3.3.0.4529_x64.msix"' -ForegroundColor Cyan
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
		Exit
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

Main -Path $FilePath