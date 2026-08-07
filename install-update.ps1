<#
.SYNOPSIS
    TPM Plugins Installer & Updater
.DESCRIPTION
    Downloads and installs TPM DriveWorks plugins from GitHub Releases.
    Detects already-installed plugins and shows available updates.
    Handles license file setup and DLL unblocking.
    Requires GitHub CLI (gh) authenticated with access to TPM-Repos.
#>

param(
    [string]$GithubRepo = "TPM-Repos/TPMPlugins",
    [string]$LicenseServerUrl = "https://license.tpmautomation.com",
    [string]$InstallDir = ""
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Version of this installer. Keep in sync with the release tag (V<version>)
# published at https://github.com/TPM-Repos/TPMPluginsPublicRelease/releases
$InstallerVersion = "1.1.0"
$InstallerRepo = "TPM-Repos/TPMPluginsPublicRelease"

# -- Plugin definitions --
$Plugins = @(
    @{
        Name        = "TPMLicensing"
        DisplayName = "TPM Licensing Plugin (required for licensed plugins)"
        TagPrefix   = "TPMLicensing"
        ProductId   = "TPMPlugins.TPMLicensing"
        PrimaryDll  = "TPMLicensingPlugin.dll"
        Licensed    = $false
    },
    @{
        Name        = "TPMSPP"
        DisplayName = "TPM SPP - Stored Procedure Parameters"
        TagPrefix   = "TPMSPP"
        ProductId   = "TPMPlugins.TPMSPP"
        PrimaryDll  = "TPMSPPPlugin.dll"
        Licensed    = $true
    },
    @{
        Name        = "TPMUISetting"
        DisplayName = "TPM UI Setting - CSS Properties"
        TagPrefix   = "TPMUISetting"
        ProductId   = "TPMPlugins.TPMUISetting"
        PrimaryDll  = "TPMUISettingPlugin.dll"
        Licensed    = $true
    },
    @{
        Name        = "TPMGroupSettings"
        DisplayName = "TPM Group Settings"
        TagPrefix   = "TPMGroupSettings"
        ProductId   = "TPMPlugins.TPMGroupSettings"
        PrimaryDll  = "TPMGroupSettingsPlugin.dll"
        Licensed    = $true
    },
    @{
        Name        = "TPMDynamicIcons"
        DisplayName = "TPM Dynamic Icons - 20K+ SVG icons"
        TagPrefix   = "TPMDynamicIcons"
        ProductId   = "TPMPlugins.DynamicIcons"
        PrimaryDll  = "TPMDynamicIconsPlugin.dll"
        Licensed    = $true
    },
    @{
        Name        = "TPMSafeSPExecutor"
        DisplayName = "TPM Safe SP Executor"
        TagPrefix   = "TPMSafeSPExecutor"
        ProductId   = "TPMPlugins.TPMSafeSPExecutor"
        PrimaryDll  = "TPMSafeSPExecutorPlugin.dll"
        Licensed    = $false
    },
    @{
        Name        = "TPMTempAM"
        DisplayName = "TPM Temp Account Management"
        TagPrefix   = "TPMTempAM"
        ProductId   = "TPMPlugins.TPMTempAM"
        PrimaryDll  = "TPMTemp_AMPlugin_V0.1.dll"
        Licensed    = $false
    }
)

# -- Helper functions --

function Get-InstalledVersion {
    param([string]$DllPath)
    if (-not (Test-Path $DllPath)) { return $null }
    try {
        $ver = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($DllPath).FileVersion
        if ($ver) { return $ver.Trim() }
    } catch {}
    return $null
}

function Get-LatestRelease {
    param([string]$TagPrefix)
    try {
        $releases = cmd /c ('gh release list --repo ' + $GithubRepo + ' --limit 50 2>nul')
        if ($LASTEXITCODE -ne 0) { return $null }

        foreach ($line in $releases -split "`n") {
            if ($line -match "$TagPrefix`_V(\d+\.\d+\.\d+)") {
                return @{
                    Version = $Matches[1]
                    Tag     = "$TagPrefix`_V$($Matches[1])"
                }
            }
        }
    } catch {}
    return $null
}

function Compare-Versions {
    param([string]$Installed, [string]$Latest)
    try {
        $inst = $Installed.Trim()
        if ($inst -match '^\d+\.\d+\.\d+\.\d+$') {
            $inst = $inst -replace '\.\d+$', ''
        }
        $instVer = [Version]$inst
        $latVer  = [Version]$Latest
        return $latVer -gt $instVer
    } catch {
        return $false
    }
}

function Test-IsElevated {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-DirWritable {
    param([string]$Dir)
    # If the directory does not exist yet, test the nearest existing parent
    # (creating the directory needs write access there too).
    $target = $Dir
    while ($target -and (-not (Test-Path $target))) {
        $target = Split-Path $target -Parent
    }
    if ([string]::IsNullOrWhiteSpace($target)) { return $false }
    $probe = Join-Path $target ("tpm-write-test-" + [Guid]::NewGuid().ToString("N") + ".tmp")
    try {
        [System.IO.File]::WriteAllText($probe, "test")
        Remove-Item $probe -Force -Confirm:$false -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Initialize-RestartManager {
    # Compiles a small wrapper around the Windows Restart Manager API, which
    # reports exactly which processes/services have a file open. Compiled once.
    if ('TpmRestartManager' -as [type]) { return $true }
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class TpmRestartManager
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }

    const int CCH_RM_MAX_APP_NAME = 255;
    const int CCH_RM_MAX_SVC_NAME = 63;
    const int ERROR_MORE_DATA = 234;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct RM_PROCESS_INFO
    {
        public RM_UNIQUE_PROCESS Process;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)]
        public string strAppName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)]
        public string strServiceShortName;
        public int ApplicationType;
        public uint AppStatus;
        public uint TSSessionId;
        [MarshalAs(UnmanagedType.Bool)]
        public bool bRestartable;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
    [DllImport("rstrtmgr.dll")]
    static extern int RmEndSession(uint pSessionHandle);
    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames, uint nApplications, RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
    [DllImport("rstrtmgr.dll")]
    static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo, [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

    // Returns "pid|appName|serviceShortName" for each process using the file
    public static List<string> GetLockers(string path)
    {
        var result = new List<string>();
        uint handle;
        if (RmStartSession(out handle, 0, Guid.NewGuid().ToString()) != 0) return result;
        try
        {
            if (RmRegisterResources(handle, 1, new[] { path }, 0, null, 0, null) != 0) return result;
            uint pnProcInfoNeeded = 0, pnProcInfo = 0, rebootReasons = 0;
            int res = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, null, ref rebootReasons);
            if (res == ERROR_MORE_DATA && pnProcInfoNeeded > 0)
            {
                var info = new RM_PROCESS_INFO[pnProcInfoNeeded];
                pnProcInfo = pnProcInfoNeeded;
                res = RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, info, ref rebootReasons);
                if (res == 0)
                {
                    for (int i = 0; i < pnProcInfo; i++)
                        result.Add(info[i].Process.dwProcessId + "|" + info[i].strAppName + "|" + info[i].strServiceShortName);
                }
            }
        }
        finally { RmEndSession(handle); }
        return result;
    }
}
"@
        return $true
    } catch {
        return $false
    }
}

function Get-FileLockInfo {
    # Finds which programs have the file open. Primary: Windows Restart Manager
    # (authoritative for "file in use" errors). Fallback: scan loaded modules.
    param([string]$Path)
    $fullPath = $Path
    try { $fullPath = [System.IO.Path]::GetFullPath($Path) } catch {}
    $holders = @()

    $rmWorked = $false
    if (Initialize-RestartManager) {
        try {
            foreach ($entry in [TpmRestartManager]::GetLockers($fullPath)) {
                $parts = $entry -split '\|', 3
                $name = $parts[1]
                if ($parts[2]) { $name = $name + " [Windows service: " + $parts[2] + "]" }
                $holders += @{ Name = $name; Id = [int]$parts[0] }
            }
            $rmWorked = $true
        } catch {}
    }

    if (-not $rmWorked) {
        # Fallback: module enumeration throws for protected/other-bitness
        # processes, so each process is checked inside its own try/catch.
        foreach ($proc in @(Get-Process -ErrorAction SilentlyContinue)) {
            try {
                foreach ($module in $proc.Modules) {
                    if ($module.FileName -and ($module.FileName -ieq $fullPath)) {
                        $holders += @{ Name = $proc.ProcessName; Id = $proc.Id }
                        break
                    }
                }
            } catch {}
        }
    }
    return @($holders)
}

function Test-LicenseKey {
    # Validates a license key against the TPM license server using the same
    # /activate call the TPMLicensing plugin makes on first run.
    # Returns @{ Result = 'valid' | 'invalid' | 'unreachable'; ... }
    param([string]$Key, [string]$ServerUrl, [string]$PluginVersion)

    $machineId = $env:COMPUTERNAME
    try {
        $guid = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Cryptography" -Name MachineGuid -ErrorAction Stop).MachineGuid
        if ($guid) { $machineId = $guid }
    } catch {}

    $ver = $PluginVersion
    if ([string]::IsNullOrWhiteSpace($ver)) { $ver = "0.0.0" }
    $body = @{
        key            = $Key
        machineId      = $machineId
        machineName    = $env:COMPUTERNAME
        version        = $ver
        product        = "TPMPlugins"
        pluginVersions = @{}
    } | ConvertTo-Json -Compress

    $responseText = $null
    try {
        $resp = Invoke-WebRequest -Uri ($ServerUrl.TrimEnd('/') + "/activate") -Method Post `
            -Body $body -ContentType "application/json" -TimeoutSec 15 -UseBasicParsing
        $responseText = $resp.Content
    } catch {
        $webResp = $null
        try { $webResp = $_.Exception.Response } catch {}
        if ($webResp) {
            $code = 0
            try { $code = [int]$webResp.StatusCode } catch {}
            if ($code -in 502, 503, 504) {
                return @{ Result = "unreachable"; Message = ("Server gateway error: " + $code) }
            }
            # PS 5.1: the error body is in ErrorDetails; the response stream is
            # already consumed and reads back empty.
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                $responseText = $_.ErrorDetails.Message
            } else {
                try {
                    $stream = $webResp.GetResponseStream()
                    if ($stream.CanSeek) { $stream.Position = 0 }
                    $reader = New-Object System.IO.StreamReader($stream)
                    $responseText = $reader.ReadToEnd()
                    $reader.Close()
                } catch {}
            }
        }
        if (-not $responseText) {
            return @{ Result = "unreachable"; Message = $_.Exception.Message }
        }
    }

    $json = $null
    try { $json = $responseText | ConvertFrom-Json } catch {}
    if (-not $json -or ($null -eq $json.PSObject.Properties['valid'])) {
        return @{ Result = "unreachable"; Message = "Server returned an unrecognized response" }
    }

    if (("" + $json.valid) -ne 'true' -and ("" + $json.valid) -ne 'True') {
        $msg = $null
        if ($json.PSObject.Properties['message']) { $msg = $json.message }
        if (-not $msg -and $json.PSObject.Properties['error']) { $msg = $json.error }
        if (-not $msg) { $msg = "unknown reason" }
        return @{ Result = "invalid"; Message = $msg }
    }

    if ($json.PSObject.Properties['product'] -and $json.product -and
        -not [string]::Equals(("" + $json.product), "TPMPlugins", [StringComparison]::OrdinalIgnoreCase)) {
        return @{ Result = "invalid"; Message = ("License is for product '" + $json.product + "', expected 'TPMPlugins'") }
    }

    $customer = $null
    $maint = $null
    if ($json.PSObject.Properties['customerName']) { $customer = $json.customerName }
    if ($json.PSObject.Properties['maintenanceExpiry']) { $maint = $json.maintenanceExpiry }
    return @{ Result = "valid"; CustomerName = $customer; MaintenanceExpiry = $maint }
}

function Get-LatestInstallerRelease {
    # Latest installer release from the public repo (anonymous API, no gh needed).
    try {
        $rel = Invoke-RestMethod -Uri ("https://api.github.com/repos/" + $InstallerRepo + "/releases/latest") `
            -TimeoutSec 10 -UseBasicParsing
        if ($rel.tag_name -match '(\d+\.\d+\.\d+)') {
            return @{ Version = $Matches[1]; Tag = $rel.tag_name }
        }
    } catch {}
    return $null
}

function Update-Installer {
    # Downloads the installer files at the given release tag and replaces the
    # target files. The running .ps1 can be overwritten directly (PowerShell has
    # already read it into memory), but install-update.bat may still be
    # mid-execution in the parent cmd.exe window, so an existing .bat is
    # replaced by a detached delayed copy that runs after this process and its
    # parent have exited.
    param([string]$Tag, [string]$TargetPs1, [string]$TargetBat)

    $updTemp = Join-Path $env:TEMP "tpm-installer-update"
    New-Item -ItemType Directory -Path $updTemp -Force | Out-Null
    $rawBase = "https://raw.githubusercontent.com/" + $InstallerRepo + "/" + $Tag + "/"
    $newPs1 = Join-Path $updTemp "install-update.ps1"
    $newBat = Join-Path $updTemp "install-update.bat"

    try {
        Invoke-WebRequest -Uri ($rawBase + "install-update.ps1") -OutFile $newPs1 -TimeoutSec 30 -UseBasicParsing
        Invoke-WebRequest -Uri ($rawBase + "install-update.bat") -OutFile $newBat -TimeoutSec 30 -UseBasicParsing
    } catch {
        Write-Host ("  ERROR: Failed to download the installer update: " + $_.Exception.Message) -ForegroundColor Red
        return $false
    }

    # Sanity check: the downloaded script must be non-trivial, valid PowerShell
    $parseErrors = $null; $parseTokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($newPs1, [ref]$parseTokens, [ref]$parseErrors)
    if ((Get-Item $newPs1).Length -lt 5KB -or $parseErrors.Count -gt 0) {
        Write-Host "  ERROR: The downloaded installer failed validation. Keeping the current version." -ForegroundColor Red
        return $false
    }

    try {
        Copy-Item $newPs1 $TargetPs1 -Force
        Unblock-File $TargetPs1 -ErrorAction SilentlyContinue
    } catch {
        Write-Host ("  ERROR: Could not replace " + $TargetPs1) -ForegroundColor Red
        Write-Host ("  Reason: " + $_.Exception.Message) -ForegroundColor Red
        return $false
    }

    if ($TargetBat) {
        Unblock-File $newBat -ErrorAction SilentlyContinue
        if (Test-Path $TargetBat) {
            # Replace the .bat a few seconds from now, once cmd.exe is done with it
            $replCmd = Join-Path $updTemp "replace-bat.cmd"
            $replText = '@echo off' + "`r`n" +
                        'ping -n 6 127.0.0.1 >nul' + "`r`n" +
                        'copy /y "' + $newBat + '" "' + $TargetBat + '" >nul' + "`r`n"
            [System.IO.File]::WriteAllText($replCmd, $replText, [System.Text.Encoding]::ASCII)
            Start-Process cmd -WindowStyle Hidden -ArgumentList '/c', $replCmd
        } else {
            try { Copy-Item $newBat $TargetBat -Force } catch {}
        }
    }
    return $true
}

function Show-MaintenanceStatus {
    # Reports how much maintenance period is left on a validated license.
    # Server sends maintenanceExpiry as yyyy-MM-dd.
    param([string]$MaintenanceExpiry)
    if ([string]::IsNullOrWhiteSpace($MaintenanceExpiry)) { return }
    $expiry = [DateTime]::MinValue
    if (-not [DateTime]::TryParse($MaintenanceExpiry, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref]$expiry)) { return }

    $daysLeft = [int][Math]::Floor(($expiry.Date - (Get-Date).Date).TotalDays)
    $expiryText = $expiry.ToString("yyyy-MM-dd")
    if ($daysLeft -lt 0) {
        Write-Host ("  NOTE: Your maintenance period EXPIRED on " + $expiryText + ".") -ForegroundColor Yellow
        Write-Host "  Updates released after that date are not covered by your license." -ForegroundColor Yellow
        Write-Host "  Contact TPM Inc. sales to renew your subscription." -ForegroundColor Yellow
    } elseif ($daysLeft -le 30) {
        Write-Host ("  NOTE: Your maintenance period expires on " + $expiryText + " (" + $daysLeft + " days left).") -ForegroundColor Yellow
        Write-Host "  Contact TPM Inc. sales to renew your subscription." -ForegroundColor Yellow
    } else {
        Write-Host ("  Maintenance period valid until " + $expiryText + " (" + $daysLeft + " days left).") -ForegroundColor DarkGray
    }
}

# -- Banner --
Clear-Host
Write-Host ""
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host ("       TPM Plugins Install / Update  V" + $InstallerVersion) -ForegroundColor Cyan
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host ""

# -- Check for a newer version of this installer --
if ($PSCommandPath) {
    $latestInstaller = Get-LatestInstallerRelease
    if ($latestInstaller) {
        $installerOutdated = $false
        try { $installerOutdated = ([Version]$latestInstaller.Version) -gt ([Version]$InstallerVersion) } catch {}
        if ($installerOutdated) {
            Write-Host ("  A newer version of this installer is available: V" + $InstallerVersion + " => V" + $latestInstaller.Version) -ForegroundColor Yellow
            Write-Host ("  Release notes: https://github.com/" + $InstallerRepo + "/releases") -ForegroundColor DarkGray
            Write-Host ""
            $doUpd = Read-Host "  Update the installer now? Y/n"
            if ($doUpd -ne 'n') {
                Write-Host "  Downloading installer update..." -ForegroundColor White
                $selfBat = Join-Path (Split-Path $PSCommandPath -Parent) "install-update.bat"
                if (Update-Installer -Tag $latestInstaller.Tag -TargetPs1 $PSCommandPath -TargetBat $selfBat) {
                    Write-Host ("  Installer updated to V" + $latestInstaller.Version + ".") -ForegroundColor Green
                    Write-Host "  Restarting the installer in a new window..." -ForegroundColor White
                    $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
                    if (-not [string]::IsNullOrWhiteSpace($InstallDir)) {
                        $relaunchArgs += @('-InstallDir', ('"' + $InstallDir + '"'))
                    }
                    Start-Process powershell -ArgumentList $relaunchArgs
                    exit 0
                }
                Write-Host "  Continuing with the current installer version." -ForegroundColor Yellow
                Write-Host ""
            }
        }
    }
}

# -- Check GitHub CLI --
# NOTE: Under $ErrorActionPreference = 'Stop', Windows PowerShell 5.1 turns a
# missing command and any stderr redirection (2>$null / 2>&1) on a native exe
# into TERMINATING errors, killing the script before our friendly messages can
# show. So: detect gh with Get-Command, and run gh through cmd.exe so cmd owns
# the stderr redirection and we only ever look at the exit code.
$ManualMode = $false

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "  GitHub CLI (gh) was NOT detected on this machine." -ForegroundColor Yellow
    Write-Host "  It is needed to download the plugin DLLs automatically." -ForegroundColor Yellow
    Write-Host "  To enable automatic downloads, install it from: https://cli.github.com/" -ForegroundColor White
    Write-Host "  then re-run this installer." -ForegroundColor White
    Write-Host ""
    Write-Host "  You can still continue WITHOUT GitHub CLI in manual mode:" -ForegroundColor White
    Write-Host "  the download step is skipped and you download the DLL files yourself from" -ForegroundColor DarkGray
    Write-Host "  the GitHub releases page (links will be shown for each plugin)." -ForegroundColor DarkGray
    Write-Host ""
    $goManual = Read-Host "  Continue in manual mode? Y/n"
    if ($goManual -eq 'n') {
        Write-Host "  Install GitHub CLI from https://cli.github.com/ and re-run this installer." -ForegroundColor Yellow
        Read-Host "  Press Enter to exit"
        exit 0
    }
    $ManualMode = $true
} else {
    cmd /c "gh auth status >nul 2>nul"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  GitHub CLI is not authenticated. You need access to the TPM-Repos organization." -ForegroundColor Yellow
        Write-Host ""
        $doAuth = Read-Host "  Log in to GitHub now? Y/n (n = continue in manual mode)"
        if ($doAuth -eq 'n') {
            Write-Host "  Continuing in manual mode - you will download the DLL files yourself." -ForegroundColor Yellow
            $ManualMode = $true
        } else {
            gh auth login
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  GitHub authentication failed." -ForegroundColor Red
                $goManual = Read-Host "  Continue in manual mode instead? Y/n"
                if ($goManual -eq 'n') {
                    Read-Host "  Press Enter to exit"
                    exit 1
                }
                $ManualMode = $true
            }
        }
    }
}

# -- Get install directory --
$defaultPath = "C:\Program Files\DriveWorks\TPMPlugins"
$installDir = $InstallDir
if ([string]::IsNullOrWhiteSpace($installDir)) {
    Write-Host ""
    Write-Host "  Where should TPM plugins be installed?" -ForegroundColor White
    Write-Host ("  Default: " + $defaultPath) -ForegroundColor DarkGray
    Write-Host ""
    $installDir = Read-Host "  Install directory - Enter for default"
    if ([string]::IsNullOrWhiteSpace($installDir)) {
        $installDir = $defaultPath
    }
} else {
    Write-Host ""
    Write-Host ("  Install directory: " + $installDir) -ForegroundColor DarkGray
}

# -- Check write access (folders under Program Files need administrator rights) --
if (-not (Test-DirWritable $installDir)) {
    Write-Host ""
    if (-not (Test-IsElevated)) {
        Write-Host ("  You do not have permission to write to: " + $installDir) -ForegroundColor Yellow
        Write-Host "  Locations under Program Files require ADMINISTRATOR rights." -ForegroundColor Yellow
        Write-Host "  The installer must be elevated to copy the plugin files there." -ForegroundColor Yellow
        Write-Host ""
        $elevate = Read-Host "  Relaunch this installer as administrator now? Y/n"
        if ($elevate -eq 'n') {
            Write-Host ""
            Write-Host "  To install to this location, re-run the installer as administrator:" -ForegroundColor White
            Write-Host "  right-click install-update.bat and choose 'Run as administrator'." -ForegroundColor White
            Write-Host "  Or choose an install directory you have write access to." -ForegroundColor DarkGray
            Read-Host "  Press Enter to exit"
            exit 0
        }
        try {
            Start-Process powershell -Verb RunAs -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', ('"' + $PSCommandPath + '"'),
                '-InstallDir', ('"' + $installDir + '"')
            )
            exit 0
        } catch {
            Write-Host "  Elevation was cancelled or failed." -ForegroundColor Red
            Write-Host "  Re-run the installer by right-clicking install-update.bat and" -ForegroundColor White
            Write-Host "  choosing 'Run as administrator'." -ForegroundColor White
            Read-Host "  Press Enter to exit"
            exit 1
        }
    } else {
        Write-Host ("  Cannot write to: " + $installDir) -ForegroundColor Red
        Write-Host "  The installer is already running as administrator, so this folder is" -ForegroundColor Yellow
        Write-Host "  blocked by its permissions (ACLs). Check the folder's security settings" -ForegroundColor Yellow
        Write-Host "  or choose a different install directory." -ForegroundColor Yellow
        Read-Host "  Press Enter to exit"
        exit 1
    }
}

if (-not (Test-Path $installDir)) {
    $createDir = Read-Host "  Directory does not exist. Create it? Y/n"
    if ($createDir -eq 'n') {
        Write-Host "  Aborted." -ForegroundColor Yellow
        Read-Host "  Press Enter to exit"
        exit 0
    }
    try {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        Write-Host ("  Created: " + $installDir) -ForegroundColor Green
    } catch {
        Write-Host ("  ERROR: Could not create " + $installDir) -ForegroundColor Red
        Write-Host ("  Reason: " + $_.Exception.Message) -ForegroundColor Red
        Read-Host "  Press Enter to exit"
        exit 1
    }
}

# -- If this location already has licensing set up, check it now --
$licenseFile = Join-Path $installDir "tpm-license.json"
$existingLicenseState = 'none'
if (Test-Path $licenseFile) {
    $existingKey = $null
    try { $existingKey = (Get-Content $licenseFile -Raw | ConvertFrom-Json).licenseKey } catch {}
    Write-Host ""
    if ($existingKey) {
        Write-Host "  Existing license found - checking with the license server..." -ForegroundColor White
        $check = Test-LicenseKey -Key $existingKey -ServerUrl $LicenseServerUrl `
            -PluginVersion (Get-InstalledVersion (Join-Path $installDir "TPMLicensingPlugin.dll"))
        if ($check.Result -eq 'valid') {
            $existingLicenseState = 'valid'
            $who = ""
            if ($check.CustomerName) { $who = " - licensed to " + $check.CustomerName }
            Write-Host ("  License is VALID" + $who + ".") -ForegroundColor Green
            Show-MaintenanceStatus $check.MaintenanceExpiry
        } elseif ($check.Result -eq 'invalid') {
            $existingLicenseState = 'invalid'
            Write-Host "  WARNING: The license server REJECTED the key in your existing license file:" -ForegroundColor Yellow
            Write-Host ("    " + $check.Message) -ForegroundColor Yellow
            Write-Host ("  File: " + $licenseFile) -ForegroundColor DarkGray
            Write-Host "  You will be asked for a new license key after the install." -ForegroundColor DarkGray
        } else {
            $existingLicenseState = 'unreachable'
            Write-Host ("  Could not reach the license server to check the existing license:") -ForegroundColor Yellow
            Write-Host ("    " + $check.Message) -ForegroundColor Yellow
            Write-Host "  Leaving the existing license file as-is." -ForegroundColor DarkGray
        }
    } else {
        $existingLicenseState = 'unreadable'
        Write-Host ("  WARNING: The existing license file could not be read: " + $licenseFile) -ForegroundColor Yellow
        Write-Host "  You will be asked for a new license key after the install." -ForegroundColor DarkGray
    }
}

Write-Host ""

# -- Scan installed plugins and check for latest versions --
if ($ManualMode) {
    Write-Host "  Manual mode: scanning installed plugins (GitHub version check skipped)..." -ForegroundColor White
} else {
    Write-Host "  Scanning installed plugins and checking for updates..." -ForegroundColor White
}
Write-Host ""

$pluginStatus = @()
foreach ($plugin in $Plugins) {
    $dllPath = Join-Path $installDir $plugin.PrimaryDll
    $installed = Get-InstalledVersion $dllPath
    $latest = $null
    if (-not $ManualMode) {
        $latest = Get-LatestRelease $plugin.TagPrefix
    }

    $latestVer = $null
    $latestTag = $null
    if ($latest) {
        $latestVer = $latest.Version
        $latestTag = $latest.Tag
    }

    $status = @{
        Plugin           = $plugin
        InstalledVersion = $installed
        LatestVersion    = $latestVer
        LatestTag        = $latestTag
        IsInstalled      = ($null -ne $installed)
        UpdateAvailable  = $false
        Action           = "Not available"
    }

    if ($ManualMode) {
        if ($installed) {
            $status.Action = "Installed " + $installed + " - manual mode"
        } else {
            $status.Action = "Manual install"
        }
    } elseif ($installed -and $latest) {
        $status.UpdateAvailable = Compare-Versions $installed $latest.Version
        if ($status.UpdateAvailable) {
            $status.Action = "Update " + $installed + " => " + $latest.Version
        } else {
            $status.Action = "Up to date " + $installed
        }
    } elseif ((-not $installed) -and $latest) {
        $status.Action = "Install V" + $latest.Version
    } elseif ($installed -and (-not $latest)) {
        $status.Action = "Installed " + $installed + " - no release found"
    }

    $pluginStatus += $status
}

# -- Display plugin list --
Write-Host "  +----+------------------------------------------+-----------------------------------+" -ForegroundColor DarkGray
Write-Host "  | #  | Plugin                                   | Status                            |" -ForegroundColor DarkGray
Write-Host "  +----+------------------------------------------+-----------------------------------+" -ForegroundColor DarkGray

for ($i = 0; $i -lt $pluginStatus.Count; $i++) {
    $s = $pluginStatus[$i]
    $num = ($i + 1).ToString().PadRight(2)
    $name = $s.Plugin.DisplayName
    if ($name.Length -gt 40) { $name = $name.Substring(0, 37) + "..." }
    $name = $name.PadRight(40)
    $action = $s.Action
    if ($action.Length -gt 33) { $action = $action.Substring(0, 30) + "..." }
    $action = $action.PadRight(33)

    $color = "DarkGray"
    if ((-not $s.IsInstalled) -and ($s.LatestVersion -or $ManualMode)) { $color = "White" }
    if ($s.UpdateAvailable) { $color = "Yellow" }
    if ($s.IsInstalled -and (-not $s.UpdateAvailable)) { $color = "Green" }

    Write-Host ("  | " + $num + " | " + $name + " | " + $action + " |") -ForegroundColor $color
}

Write-Host "  +----+------------------------------------------+-----------------------------------+" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Legend: " -NoNewline -ForegroundColor DarkGray
Write-Host "Green" -NoNewline -ForegroundColor Green
Write-Host " = up to date  " -NoNewline -ForegroundColor DarkGray
Write-Host "Yellow" -NoNewline -ForegroundColor Yellow
Write-Host " = update available  " -NoNewline -ForegroundColor DarkGray
Write-Host "White" -NoNewline -ForegroundColor White
Write-Host " = not installed" -ForegroundColor DarkGray
Write-Host ""

# -- Manual mode: show the download links up front --
if ($ManualMode) {
    Write-Host "  MANUAL MODE - download the plugin DLL files from GitHub:" -ForegroundColor Cyan
    Write-Host ("  All releases: https://github.com/" + $GithubRepo + "/releases") -ForegroundColor Cyan
    Write-Host "  (sign in to GitHub - you need access to the TPM-Repos organization)" -ForegroundColor DarkGray
    Write-Host ""
    for ($i = 0; $i -lt $pluginStatus.Count; $i++) {
        $p = $pluginStatus[$i].Plugin
        Write-Host ("    " + ($i + 1) + ". " + $p.Name.PadRight(18) + " https://github.com/" + $GithubRepo + "/releases?q=" + $p.TagPrefix + "&expanded=true") -ForegroundColor White
    }
    Write-Host ""
    Write-Host "  For each plugin you want, open its link, open the latest release, and" -ForegroundColor DarkGray
    Write-Host "  download ALL of its .dll files. Then select the plugins below - the" -ForegroundColor DarkGray
    Write-Host "  installer will wait while you place the files in the install folder." -ForegroundColor DarkGray
    Write-Host ""
}

# -- Select plugins to install/update --
Write-Host "  Enter plugin numbers to install or update, comma-separated, or type all:" -ForegroundColor White
Write-Host "  Example: 1,2,4  or  all" -ForegroundColor DarkGray
Write-Host ""
$selection = Read-Host "  Selection"

$selectedPlugins = @()
if ($selection.Trim().ToLower() -eq 'all') {
    if ($ManualMode) {
        $selectedPlugins = @($pluginStatus)
    } else {
        $selectedPlugins = @($pluginStatus | Where-Object {
            $_.LatestVersion -and ((-not $_.IsInstalled) -or $_.UpdateAvailable)
        })
        if ($selectedPlugins.Count -eq 0) {
            Write-Host ""
            Write-Host "  Everything is up to date! Nothing to install or update." -ForegroundColor Green
            Write-Host ""
            Read-Host "  Press Enter to exit"
            exit 0
        }
    }
} else {
    $indices = $selection -split ',' | ForEach-Object { $_.Trim() }
    foreach ($idx in $indices) {
        $num = 0
        if ([int]::TryParse($idx, [ref]$num) -and $num -ge 1 -and $num -le $pluginStatus.Count) {
            $s = $pluginStatus[$num - 1]
            if ((-not $ManualMode) -and (-not $s.LatestVersion)) {
                Write-Host ("  WARNING: No release available for " + $s.Plugin.DisplayName + ". Skipping.") -ForegroundColor Yellow
            } else {
                $selectedPlugins += $s
            }
        } else {
            Write-Host ("  WARNING: Invalid selection [" + $idx + "]. Skipping.") -ForegroundColor Yellow
        }
    }
}

if ($selectedPlugins.Count -eq 0) {
    Write-Host ""
    Write-Host "  No plugins selected. Exiting." -ForegroundColor Yellow
    Read-Host "  Press Enter to exit"
    exit 0
}

# -- Confirm selection --
Write-Host ""
Write-Host "  The following will be installed/updated:" -ForegroundColor White
foreach ($s in $selectedPlugins) {
    $actionLabel = "Install"
    if ($s.IsInstalled) { $actionLabel = "Update" }
    $verLabel = "V" + $s.LatestVersion
    if ($ManualMode) { $verLabel = "manual download" }
    Write-Host ("    - " + $s.Plugin.DisplayName + "  [" + $actionLabel + " => " + $verLabel + "]") -ForegroundColor Cyan
}
Write-Host ""
$confirm = Read-Host "  Proceed? Y/n"
if ($confirm -eq 'n') {
    Write-Host "  Aborted." -ForegroundColor Yellow
    Read-Host "  Press Enter to exit"
    exit 0
}

# -- Optionally skip the automatic download --
if (-not $ManualMode) {
    Write-Host ""
    $autoDl = Read-Host "  Download DLLs automatically via GitHub CLI? Y/n (n = download them yourself)"
    if ($autoDl -eq 'n') {
        Write-Host "  Manual mode: the download step will be skipped and links shown instead." -ForegroundColor Yellow
        $ManualMode = $true
    }
}

# -- Check whether the plugin DLLs being replaced are actually locked / in use --
$targetDlls = @()
foreach ($s in $selectedPlugins) {
    $dllPath = Join-Path $installDir $s.Plugin.PrimaryDll
    if (Test-Path $dllPath) { $targetDlls += $dllPath }
}

if ($targetDlls.Count -gt 0) {
    Write-Host ""
    Write-Host "  Checking whether the plugin files being replaced are in use..." -ForegroundColor White
    while ($true) {
        $lockedFiles = @()
        foreach ($dllPath in $targetDlls) {
            $holders = @(Get-FileLockInfo $dllPath)
            if ($holders.Count -gt 0) {
                $lockedFiles += @{ Path = $dllPath; Holders = $holders }
            }
        }
        if ($lockedFiles.Count -eq 0) {
            Write-Host "  No plugin files are locked. Continuing..." -ForegroundColor Green
            break
        }
        Write-Host ""
        Write-Host "  WARNING: These plugin files are IN USE and cannot be replaced yet:" -ForegroundColor Yellow
        foreach ($lf in $lockedFiles) {
            Write-Host ("    " + (Split-Path $lf.Path -Leaf) + " - in use by:") -ForegroundColor Yellow
            foreach ($h in $lf.Holders) {
                Write-Host ("      - " + $h.Name + " (PID " + $h.Id + ")") -ForegroundColor Yellow
            }
        }
        Write-Host ""
        Write-Host "  Close the applications listed above. To stop a Windows service, use" -ForegroundColor DarkGray
        Write-Host "  services.msc or run Stop-Service '<service name>' from an admin PowerShell." -ForegroundColor DarkGray
        Write-Host ""
        $recheck = Read-Host "  Press Enter to re-check, or type skip to continue anyway"
        if ($recheck.Trim().ToLower() -eq 'skip') {
            Write-Host "  Continuing with files still in use - file copies may fail." -ForegroundColor Yellow
            break
        }
        Write-Host ""
    }
}

# -- Download and install --
Write-Host ""
$tempDir = Join-Path $env:TEMP "tpm-plugin-install"
if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -Confirm:$false }
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

$installedCount = 0
$failedCount = 0

foreach ($s in $selectedPlugins) {
    $plugin = $s.Plugin
    $tag = $s.LatestTag
    $actionLabel = "Installing"
    if ($s.IsInstalled) { $actionLabel = "Updating" }

    # -- Manual mode: user downloads the DLLs themselves --
    if ($ManualMode) {
        Write-Host ("  " + $actionLabel + " " + $plugin.DisplayName + " (manual)...") -ForegroundColor White
        Write-Host ("    1. Open: https://github.com/" + $GithubRepo + "/releases?q=" + $plugin.TagPrefix + "&expanded=true") -ForegroundColor Cyan
        Write-Host ("       (sign in to GitHub - you need access to the TPM-Repos organization)") -ForegroundColor DarkGray
        Write-Host ("    2. Open the latest " + $plugin.TagPrefix + "_V* release and download ALL of its .dll files.") -ForegroundColor White
        Write-Host ("    3. Place the downloaded .dll files directly in: " + $installDir) -ForegroundColor White
        Write-Host ""

        $manualOk = $false
        while ($true) {
            $manualDone = Read-Host "    Press Enter once the DLL files are in place, or type skip to skip this plugin"
            if ($manualDone.Trim().ToLower() -eq 'skip') {
                Write-Host ("    Skipped " + $plugin.DisplayName) -ForegroundColor Yellow
                break
            }
            if (Test-Path (Join-Path $installDir $plugin.PrimaryDll)) {
                $manualOk = $true
                break
            }
            Write-Host ("    " + $plugin.PrimaryDll + " was not found in " + $installDir) -ForegroundColor Yellow
            Write-Host "    Make sure the .dll files are placed directly in that folder (not a subfolder)." -ForegroundColor DarkGray
        }

        if (-not $manualOk) {
            $failedCount++
            continue
        }

        # Unblock every DLL currently in the install directory
        Get-ChildItem $installDir -Filter "*.dll" | ForEach-Object {
            Unblock-File $_.FullName -ErrorAction SilentlyContinue
        }
        Write-Host ("    Verified and unblocked: " + $plugin.PrimaryDll) -ForegroundColor Green
        $installedCount++
        continue
    }

    Write-Host ("  " + $actionLabel + " " + $plugin.DisplayName + " V" + $s.LatestVersion + "...") -ForegroundColor White

    # Download all assets from the release to temp
    $pluginTemp = Join-Path $tempDir $plugin.Name
    New-Item -ItemType Directory -Path $pluginTemp -Force | Out-Null

    try {
        cmd /c ('gh release download ' + $tag + ' --repo ' + $GithubRepo +
                ' --dir "' + $pluginTemp + '" --pattern *.dll >nul 2>nul')
        if ($LASTEXITCODE -ne 0) {
            throw "Download failed"
        }
    } catch {
        Write-Host ("    ERROR: Failed to download release " + $tag) -ForegroundColor Red
        $failedCount++
        continue
    }

    # Copy downloaded files to install directory, with diagnostics and retry
    $downloadedFiles = Get-ChildItem $pluginTemp -Filter "*.dll"
    $copyFailed = $false
    while ($true) {
        $copyFailed = $false
        foreach ($file in $downloadedFiles) {
            $destPath = Join-Path $installDir $file.Name
            try {
                Copy-Item $file.FullName $destPath -Force
            } catch {
                $copyFailed = $true
                $errMsg = $_.Exception.Message
                Write-Host ("    ERROR: Failed to copy " + $file.Name) -ForegroundColor Red
                Write-Host ("    Reason: " + $errMsg) -ForegroundColor Red

                $isAccessDenied = $false
                if ($_.Exception -is [System.UnauthorizedAccessException]) { $isAccessDenied = $true }
                if ($_.Exception.InnerException -is [System.UnauthorizedAccessException]) { $isAccessDenied = $true }
                if ($errMsg -match 'denied') { $isAccessDenied = $true }

                if ($isAccessDenied) {
                    Write-Host "    This looks like a PERMISSIONS problem, not a locked file." -ForegroundColor Yellow
                    Write-Host "    Re-run the installer as administrator: right-click install-update.bat" -ForegroundColor Yellow
                    Write-Host "    and choose 'Run as administrator'." -ForegroundColor Yellow
                } else {
                    $holders = @(Get-FileLockInfo $destPath)
                    if ($holders.Count -gt 0) {
                        Write-Host "    The file is locked - it is in use by:" -ForegroundColor Yellow
                        foreach ($h in $holders) {
                            Write-Host ("      - " + $h.Name + " (PID " + $h.Id + ")") -ForegroundColor Yellow
                        }
                    } else {
                        Write-Host "    The file appears to be locked, but the program using it could not" -ForegroundColor Yellow
                        Write-Host "    be identified. Likely candidates: DriveWorks apps, SolidWorks, or" -ForegroundColor Yellow
                        Write-Host "    the DriveWorks Live service." -ForegroundColor Yellow
                    }
                }
                break
            }
        }
        if (-not $copyFailed) { break }
        Write-Host ""
        $retry = Read-Host "    Close the application(s) above, then press Enter to retry, or type skip to skip this plugin"
        if ($retry.Trim().ToLower() -eq 'skip') { break }
        Write-Host ""
    }

    if ($copyFailed) {
        $failedCount++
        continue
    }

    # Unblock all copied DLLs
    $downloadedFiles | ForEach-Object {
        $target = Join-Path $installDir $_.Name
        if (Test-Path $target) {
            Unblock-File $target -ErrorAction SilentlyContinue
        }
    }

    $fileList = ($downloadedFiles | ForEach-Object { $_.Name }) -join ", "
    Write-Host ("    Installed: " + $fileList) -ForegroundColor Green
    $installedCount++
}

# Clean up temp
Remove-Item $tempDir -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue

# -- License setup --
$needsLicense = $selectedPlugins | Where-Object { $_.Plugin.Licensed }
$licensingDllVersion = Get-InstalledVersion (Join-Path $installDir "TPMLicensingPlugin.dll")

if ($needsLicense) {
    $promptForKey = $false

    if ($existingLicenseState -eq 'none') {
        $promptForKey = $true
    } elseif ($existingLicenseState -eq 'invalid') {
        Write-Host ""
        Write-Host "  Your existing license file was rejected by the license server (see above)." -ForegroundColor Yellow
        $redo = Read-Host "  Enter a new license key now? Y/n"
        if ($redo -ne 'n') { $promptForKey = $true }
    } elseif ($existingLicenseState -eq 'unreadable') {
        Write-Host ""
        Write-Host "  Your existing license file could not be read (see above)." -ForegroundColor Yellow
        $redo = Read-Host "  Enter a license key now to recreate it? Y/n"
        if ($redo -ne 'n') { $promptForKey = $true }
    }
    # 'valid' and 'unreachable' need no further action here

    if ($promptForKey) {
        Write-Host ""
        Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "  LICENSE SETUP" -ForegroundColor Cyan
        Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  You installed licensed plugins. A license key is required." -ForegroundColor White
        Write-Host "  If you do not have one yet, contact TPM Inc." -ForegroundColor DarkGray
        Write-Host ""

        $keyToSave = $null
        $keyValidated = $false

        :keyloop while ($true) {
            $licKey = Read-Host "  Enter your license key or press Enter to skip"
            if ([string]::IsNullOrWhiteSpace($licKey)) { break }
            $licKey = $licKey.Trim()

            while ($true) {
                Write-Host ("  Validating license key with " + $LicenseServerUrl + " ...") -ForegroundColor White
                $check = Test-LicenseKey -Key $licKey -ServerUrl $LicenseServerUrl -PluginVersion $licensingDllVersion

                if ($check.Result -eq 'valid') {
                    $who = ""
                    if ($check.CustomerName) { $who = " - licensed to " + $check.CustomerName }
                    Write-Host ("  License key is VALID" + $who + ".") -ForegroundColor Green
                    Show-MaintenanceStatus $check.MaintenanceExpiry
                    $keyToSave = $licKey
                    $keyValidated = $true
                    break keyloop
                }

                if ($check.Result -eq 'invalid') {
                    Write-Host ("  The license server REJECTED this key: " + $check.Message) -ForegroundColor Red
                    Write-Host "  Check that you entered your license KEY exactly as provided by TPM Inc." -ForegroundColor Yellow
                    Write-Host "  (This is not the license server password or URL.)" -ForegroundColor Yellow
                    Write-Host ""
                    break
                }

                # Server unreachable
                Write-Host ("  Could not reach the license server: " + $check.Message) -ForegroundColor Yellow
                $choice = Read-Host "  R = retry, S = save the key without validation, Enter = skip license setup"
                $choice = $choice.Trim().ToLower()
                if ($choice -eq 'r') { continue }
                if ($choice -eq 's') {
                    $keyToSave = $licKey
                    break keyloop
                }
                break keyloop
            }
        }

        if ($keyToSave) {
            $licJson = '{' + "`n" + '  "licenseKey": "' + $keyToSave + '",' + "`n" + '  "serverUrl": "' + $LicenseServerUrl + '"' + "`n" + '}'
            $noBom = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($licenseFile, $licJson, $noBom)
            Write-Host ("  License file created: " + $licenseFile) -ForegroundColor Green
            if (-not $keyValidated) {
                Write-Host "  NOTE: The key was saved WITHOUT validation. If it is wrong, licensed" -ForegroundColor Yellow
                Write-Host "  plugins will show license errors in DriveWorks." -ForegroundColor Yellow
            }
        } else {
            Write-Host "  Skipped. Licensed plugins will show error messages until a license file is configured." -ForegroundColor Yellow
            Write-Host ("  To set up later, create " + $licenseFile + " with your license key.") -ForegroundColor DarkGray
        }
    }
}

# -- Copy installer files to install directory for future updates --
$selfPath = $PSCommandPath
if ($selfPath) {
    $selfDir = Split-Path $selfPath -Parent
    $destPs1 = Join-Path $installDir "install-update.ps1"
    $destBat = Join-Path $installDir "install-update.bat"
    $srcBat = Join-Path $selfDir "install-update.bat"

    if ($selfPath -ne $destPs1) {
        try {
            Copy-Item $selfPath $destPs1 -Force
            Unblock-File $destPs1 -ErrorAction SilentlyContinue
            if (Test-Path $srcBat) {
                Copy-Item $srcBat $destBat -Force
                Unblock-File $destBat -ErrorAction SilentlyContinue
            }
            Write-Host ("  Installer copied to " + $installDir + " for future updates.") -ForegroundColor DarkGray
        } catch {
            Write-Host "  WARNING: Could not copy installer to install directory." -ForegroundColor Yellow
        }
    }
}

# -- Summary --
Write-Host ""
Write-Host "  ================================================" -ForegroundColor DarkGray
Write-Host "  INSTALLATION COMPLETE" -ForegroundColor Green
Write-Host "  ================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host ("  Installed/Updated: " + $installedCount + " plugins") -ForegroundColor White
if ($failedCount -gt 0) {
    Write-Host ("  Failed:            " + $failedCount + " plugins") -ForegroundColor Red
}
Write-Host ("  Location:          " + $installDir) -ForegroundColor DarkGray
Write-Host ""
Write-Host "  NEXT STEPS:" -ForegroundColor Cyan
Write-Host "    1. Open DriveWorks Administrator" -ForegroundColor White
Write-Host "    2. Go to Settings, Plugin Settings" -ForegroundColor White
Write-Host "    3. Click Install and browse to the install directory" -ForegroundColor White
Write-Host "    4. Select the plugin DLLs you want to enable" -ForegroundColor White
Write-Host "    5. Restart DriveWorks" -ForegroundColor White
Write-Host ""
if ($ManualMode) {
    Write-Host "  TIP: Install GitHub CLI (https://cli.github.com/) to enable automatic" -ForegroundColor DarkGray
    Write-Host "  downloads and update checks next time you run this installer." -ForegroundColor DarkGray
    Write-Host ""
}
Write-Host "  To check for updates later, re-run install-update.ps1 from" -ForegroundColor DarkGray
Write-Host ("  " + $installDir) -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To check plugin status in DriveWorks, use:" -ForegroundColor DarkGray
Write-Host "    =TPMLicensePluginVersionCheck" -ForegroundColor DarkGray
Write-Host ""
Read-Host "  Press Enter to exit"
