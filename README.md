# TPM DriveWorks Plugins

Install and update TPM DriveWorks plugins.

## Quick Install

1. Download `install-update.bat` and `install-update.ps1` from this repository
2. Right-click `install-update.bat` and select **Run as administrator**
3. Follow the on-screen prompts to select and install plugins

The installer will:
- Show all available plugins and their latest versions
- Detect any already-installed plugins and available updates
- Download selected plugins directly from GitHub
- Automatically unblock DLLs after download
- Set up your license file if needed
- Copy itself to the install directory for easy future updates

## Available Plugins

| Plugin | Description | Licensed |
|--------|-------------|----------|
| **TPMLicensing** | License validation (required for all licensed plugins) | No |
| **TPMSPP** | Stored procedure parameters, SQL query execution, and form controls | Yes |
| **TPMUISetting** | CSS custom property reader for DriveWorks forms | Yes |
| **TPMGroupSettings** | Group-level settings reader | Yes |
| **TPMDynamicIcons** | Dynamic SVG icon rendering with 20K+ icons and color support | Yes |
| **TPMSafeSPExecutor** | Injection-safe stored procedure executor | No |
| **TPMTempAM** | Account management database lookup | No |

## After Installation

1. Open **DriveWorks Administrator**
2. Go to **Settings > Plugin Settings**
3. Click **Install** and browse to your install directory
4. Select the plugin DLLs you want to enable
5. Restart DriveWorks

## Updating Plugins

Re-run `install-update.ps1` from your install directory (the installer copies itself there during installation). It will detect installed versions and show available updates.

## License Setup

Licensed plugins require a `tpm-license.json` file in the same directory as the plugin DLLs. The installer can create this for you, or you can create it manually:

```json
{
  "licenseKey": "YOUR-LICENSE-KEY",
  "serverUrl": "https://license.tpmautomation.com"
}
```

Contact TPM Inc. to obtain a license key.

## Checking Plugin Status

Once installed, use this function in any DriveWorks rule to check license status and available updates for all plugins:

```
=TPMLicensePluginVersionCheck()
```

## Requirements

- Windows with PowerShell 5.1 or later
- [GitHub CLI (gh)](https://cli.github.com/) authenticated with access to the TPM-Repos organization
- DriveWorks 22.3 or later
- Internet connection for downloading plugins
