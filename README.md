# TPM DriveWorks Plugins (frozen line)

The TPM-named DriveWorks plugins stopped receiving development on 14 October 2026. TPM Inc. is now Hawk Ridge Systems LLC, and new customers use the separate Hawk Ridge Systems plugin line: https://github.com/TPM-Repos/HRSPluginsPublicRelease

Existing TPM installations keep working. To install or update them, download the installer from the **latest release** on this repository's Releases page, not from the repository files: the release carries `install-update.bat` and `install-update.ps1`; put both in the DriveWorks plugin folder and run `install-update.bat`. The installer takes every plugin package from the Hawk Ridge Systems licence server with your licence key and verifies each one against a publisher-signed release record before installing it.

The installer scripts are no longer committed in this repository, so nothing here can be fetched over raw.githubusercontent.com and run unverified. Installers older than 1.4.0 that still try to update themselves that way simply keep their current version; replace them with the files from the latest release once.

## After installation

1. Open DriveWorks Administrator, Settings, Plugin Settings.
2. Install the plugin DLLs from the install folder and restart DriveWorks.

## Moving to the Hawk Ridge Systems plugins

Every TPM function, task and plugin title is marked obsolete inside DriveWorks and points at its HRS counterpart. A site migration (project rewrite plus the HRS plugins and licence key) is done with Hawk Ridge Systems; contact your HRS representative.
