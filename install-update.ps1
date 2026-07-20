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
    [string]$LicenseServerUrl = "https://license.tpmautomation.com"
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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
        $releases = gh release list --repo $GithubRepo --limit 50 2>$null
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

# -- Banner --
Clear-Host
Write-Host ""
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host "       TPM Plugins Install / Update               " -ForegroundColor Cyan
Write-Host "  ================================================" -ForegroundColor Cyan
Write-Host ""

# -- Check GitHub CLI --
$ghCheck = gh --version 2>$null
if (-not $?) {
    Write-Host "  ERROR: GitHub CLI is required but not installed." -ForegroundColor Red
    Write-Host "  Download from: https://cli.github.com/" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to exit"
    exit 1
}

$authCheck = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  GitHub CLI is not authenticated. You need access to the TPM-Repos organization." -ForegroundColor Yellow
    Write-Host ""
    $doAuth = Read-Host "  Log in to GitHub now? Y/n"
    if ($doAuth -eq 'n') {
        Write-Host "  Cannot proceed without GitHub authentication." -ForegroundColor Red
        Read-Host "  Press Enter to exit"
        exit 1
    }
    gh auth login
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: GitHub authentication failed." -ForegroundColor Red
        Read-Host "  Press Enter to exit"
        exit 1
    }
}

# -- Get install directory --
$defaultPath = "C:\Program Files\DriveWorks\TPMPlugins"
Write-Host "  Where should TPM plugins be installed?" -ForegroundColor White
Write-Host ("  Default: " + $defaultPath) -ForegroundColor DarkGray
Write-Host ""
$installDir = Read-Host "  Install directory - Enter for default"
if ([string]::IsNullOrWhiteSpace($installDir)) {
    $installDir = $defaultPath
}

if (-not (Test-Path $installDir)) {
    $createDir = Read-Host "  Directory does not exist. Create it? Y/n"
    if ($createDir -eq 'n') {
        Write-Host "  Aborted." -ForegroundColor Yellow
        Read-Host "  Press Enter to exit"
        exit 0
    }
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Write-Host ("  Created: " + $installDir) -ForegroundColor Green
}

Write-Host ""

# -- Scan installed plugins and check for latest versions --
Write-Host "  Scanning installed plugins and checking for updates..." -ForegroundColor White
Write-Host ""

$pluginStatus = @()
foreach ($plugin in $Plugins) {
    $dllPath = Join-Path $installDir $plugin.PrimaryDll
    $installed = Get-InstalledVersion $dllPath
    $latest = Get-LatestRelease $plugin.TagPrefix

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

    if ($installed -and $latest) {
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
    if ((-not $s.IsInstalled) -and $s.LatestVersion) { $color = "White" }
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

# -- Select plugins to install/update --
Write-Host "  Enter plugin numbers to install or update, comma-separated, or type all:" -ForegroundColor White
Write-Host "  Example: 1,2,4  or  all" -ForegroundColor DarkGray
Write-Host ""
$selection = Read-Host "  Selection"

$selectedPlugins = @()
if ($selection.Trim().ToLower() -eq 'all') {
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
} else {
    $indices = $selection -split ',' | ForEach-Object { $_.Trim() }
    foreach ($idx in $indices) {
        $num = 0
        if ([int]::TryParse($idx, [ref]$num) -and $num -ge 1 -and $num -le $pluginStatus.Count) {
            $s = $pluginStatus[$num - 1]
            if (-not $s.LatestVersion) {
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
    Write-Host ("    - " + $s.Plugin.DisplayName + "  [" + $actionLabel + " => V" + $s.LatestVersion + "]") -ForegroundColor Cyan
}
Write-Host ""
$confirm = Read-Host "  Proceed? Y/n"
if ($confirm -eq 'n') {
    Write-Host "  Aborted." -ForegroundColor Yellow
    Read-Host "  Press Enter to exit"
    exit 0
}

# -- Check if DriveWorks is running --
$dwProcesses = Get-Process -Name "DriveWorks*" -ErrorAction SilentlyContinue
if ($dwProcesses) {
    Write-Host ""
    Write-Host "  WARNING: DriveWorks appears to be running. Plugin DLLs may be locked." -ForegroundColor Yellow
    Write-Host "  Please close DriveWorks before continuing." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter when DriveWorks is closed"
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

    Write-Host ("  " + $actionLabel + " " + $plugin.DisplayName + " V" + $s.LatestVersion + "...") -ForegroundColor White

    # Download all assets from the release to temp
    $pluginTemp = Join-Path $tempDir $plugin.Name
    New-Item -ItemType Directory -Path $pluginTemp -Force | Out-Null

    try {
        gh release download $tag --repo $GithubRepo --dir $pluginTemp --pattern "*.dll" 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Download failed"
        }
    } catch {
        Write-Host ("    ERROR: Failed to download release " + $tag) -ForegroundColor Red
        $failedCount++
        continue
    }

    # Copy downloaded files to install directory
    $downloadedFiles = Get-ChildItem $pluginTemp -Filter "*.dll"
    $copyFailed = $false
    foreach ($file in $downloadedFiles) {
        try {
            Copy-Item $file.FullName (Join-Path $installDir $file.Name) -Force
        } catch {
            Write-Host ("    ERROR: Failed to copy " + $file.Name + " - file may be locked.") -ForegroundColor Red
            Write-Host "    Close DriveWorks and try again." -ForegroundColor Yellow
            $failedCount++
            $copyFailed = $true
            break
        }
    }

    if ($copyFailed) { continue }

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
$licenseFile = Join-Path $installDir "tpm-license.json"

if ($needsLicense -and (-not (Test-Path $licenseFile))) {
    Write-Host ""
    Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  LICENSE SETUP" -ForegroundColor Cyan
    Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  You installed licensed plugins. A license key is required." -ForegroundColor White
    Write-Host "  If you do not have one yet, contact TPM Inc." -ForegroundColor DarkGray
    Write-Host ""

    $licKey = Read-Host "  Enter your license key or press Enter to skip"
    if (-not [string]::IsNullOrWhiteSpace($licKey)) {
        $licJson = '{' + "`n" + '  "licenseKey": "' + $licKey + '",' + "`n" + '  "serverUrl": "' + $LicenseServerUrl + '"' + "`n" + '}'
        $noBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($licenseFile, $licJson, $noBom)
        Write-Host ("  License file created: " + $licenseFile) -ForegroundColor Green
    } else {
        Write-Host "  Skipped. Licensed plugins will show error messages until a license file is configured." -ForegroundColor Yellow
        Write-Host ("  To set up later, create " + $licenseFile + " with your license key.") -ForegroundColor DarkGray
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
Write-Host "  To check for updates later, re-run install-update.ps1 from" -ForegroundColor DarkGray
Write-Host ("  " + $installDir) -ForegroundColor DarkGray
Write-Host ""
Write-Host "  To check plugin status in DriveWorks, use:" -ForegroundColor DarkGray
Write-Host "    =TPMLicensePluginVersionCheck" -ForegroundColor DarkGray
Write-Host ""
Read-Host "  Press Enter to exit"
