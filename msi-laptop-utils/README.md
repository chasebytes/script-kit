# MSI Laptop Utilities

[← script-kit home](../README.md) · [All projects](../README.md#projects)

Utilities for inspecting MSI laptop recovery media before relying on it for a restore.

## Requirements

- Windows with PowerShell and DISM available
- Administrator access for reliable DISM inspection
- An MSI recovery drive containing `RECOVERY_DVD\Install.swm` and any numbered continuation files

## Check MSI recovery media

`Check-MSIRecovery.ps1` looks for a `RECOVERY_DVD` directory on the selected drive, discovers the `Install.swm` split-image set, and asks DISM to read each part.

From the `msi-laptop-utils` directory, run PowerShell as Administrator and provide the drive letter without a colon:

```powershell
.\Check-MSIRecovery.ps1 -DriveLetter E
```

The script reports each image part's readability and size. Passing this check confirms that DISM can read the individual files; it does not replace a test boot of the recovery media or prove that the complete restore workflow will succeed.

## What it checks

- The selected drive contains a `RECOVERY_DVD` directory.
- The base `Install.swm` file exists.
- DISM can read metadata from each discovered `Install*.swm` file.
- The discovered parts and their approximate sizes are displayed for review.

## Limits and safety

The script is read-only with respect to the recovery images: it calls `dism /Get-WimInfo` and does not apply, mount, repair, or delete them. It does not currently prove that numbered parts are contiguous, validate checksums against an MSI manifest, or test the boot environment. After a clean result, boot the recovery USB and confirm that the MSI recovery interface loads before treating the media as dependable.

If the drive or base image is missing, the script stops immediately. If DISM rejects a part, the final result is marked as failed and the relevant DISM error text is displayed.
