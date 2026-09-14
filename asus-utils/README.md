# ASUS utilities

[Script-kit home](../README.md) · [GTA investigation](../gtaV/README.md)

## Official Armoury Crate removal

`Uninstall-ArmouryCrate.ps1` wraps the **official ASUS interactive uninstaller**. It does not guess removal commands or delete ASUS drivers, services or registry trees. Windows PowerShell 5.1+ is supported; apply from Administrator PowerShell.

ASUS's [current FAQ](https://www.asus.com/us/support/faq/1041654/) directs users to download the **Armoury Crate Uninstall Tool**, extract it, run it and restart. The [official download page](https://www.asus.com/supportonly/armoury%20crate/helpdesk_download/) lists version 2.3.7.0 as of 2026-09-08, and states that it removes Armoury Crate and Aura Creator related components. The wrapper uses your downloaded copy so a future download URL is not guessed or frozen in code.

1. Download from the linked official support page and extract into a dedicated directory (not the whole Downloads directory).
2. Preview, pointing at the extracted executable:

```powershell
.\Uninstall-ArmouryCrate.ps1 -ToolPath 'C:\path\extracted\Armoury Crate Uninstall Tool.exe'
```

3. Add `-Apply` to that command to launch the official interactive tool. Review/follow its UI.
4. Restart Windows to complete removal. The script never automatically reboots.

With no arguments, it simply writes the guide/plan. Before executing it requires a valid ASUSTeK Authenticode signature, records the executable SHA-256/version, copies the extracted package to its run directory and checks the staged executable hash. It snapshots relevant services before/after and records the process exit code. Exit code alone is not treated as proof of successful removal. Package dependencies are copied together; only the launcher signature is verified. Use an unmodified, newly extracted official package.

ASUS advises restarting and rerunning the tool if removal fails; preserve `ACUTLog_*.logE` from its directory for ASUS support if it fails again. The staged tool runs in the output directory so those logs remain with the audit where the vendor honors its working directory; the vendor may also write its normal system/temp logs. There is no automatic rollback of an official uninstall. Reinstalling later requires ASUS's installer and may require reconfiguring lighting/fan/performance preferences.

## Output and isolation first

This utility shares GTA's audit helpers and writes **all wrapper output under `gtaV/output/<run>/`**, already ignored by Git. Each run contains plan, transcript, journal, errors and run identity/script hashes. It depends on the sibling `gtaV` folder.

For the current kick investigation, test reversible service isolation first using `gtaV/Repair-Gta.ps1 -IsolationOnly -DisableServiceName 'ArmouryCrateService','ArmouryCrateControlInterface' -Apply`. That operation has a saved restore path and is distinct from uninstalling. Razer, BattlEye and unrelated ASUS services remain untouched. Residual Armoury processes, tasks or drivers can still affect the test; capture them after isolation and restart if needed. A negative two-service test does not exclude the entire ASUS software stack.
