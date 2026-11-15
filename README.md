# PC-Fix — Windows Stability Repair Tool

A single PowerShell script that automates a **real-world diagnosis & repair workflow** for a chronically crashing/freezing Windows laptop. Built after an actual case: a Lenovo laptop with 9+ hard freezes in 2 weeks, two BSODs (`0xA0 INTERNAL_POWER_ERROR`, `0x3B SYSTEM_SERVICE_EXCEPTION`), and dozens of daily app crashes.

**Root causes found & fixed on the real machine:**
1. **Memory-commit starvation** — only a tiny pagefile was actually active (the configured one lived on a BitLocker-encrypted volume that is locked early at boot, so Windows silently never engaged it). Commit hit 0 GB free → simultaneous stack-overflow crashes in unrelated processes, shell freezes, BSODs.
2. **System-wide DLL injection** — Windhawk desktop-customization mods injected into every process, crashing `dwm.exe`, `explorer.exe` and even system binaries (`schtasks.exe`, `reg.exe`).
3. **Junk churn** — six crash-looping services, bloated autostart, and a bogus extensionless `C:\Windows\System32\powershell` file that broke command resolution.
4. Verified clean along the way: `sfc /scannow` (0 corruptions) and **Windows Memory Diagnostic (no errors)**.

## What it does

| Option | Function |
|---|---|
| 1) Diagnose | Read-only health report (bilingual output): RAM/commit, pagefile state, unexpected shutdowns & BSOD codes, top crashing apps, crash-looping services, disk health, injected mods, RAM-test history — plus top memory eaters. Writes an **Arabic report** file too. |
| 2) Apply fixes | Enlarge the pagefile on a healthy **non-BitLocker-locked** volume, neutralize Windhawk injection (service/tasks/mods folder), disable junk crash-looping services, trim autostart, remove bogus extensionless system files. Everything backed up + a restore script. |
| 3) Cleanup | Temp, Windows Update cache, Delivery Optimization cache, Recycle Bin, old CBS logs. |
| 4) System file repair | `sfc /scannow` with logging. |
| 5) RAM test | **Suspends BitLocker on C: for 3 reboots first** (so the test boot doesn't demand your recovery key — a real-world gotcha), schedules the one-time Windows Memory Diagnostic, then boots back to Windows automatically. Protection auto-resumes. |
| 6) ALL | Runs the full workflow with a confirmation before each step. |

## Usage

```powershell
# copy the PC-Fix folder anywhere, then:
.\PC-Fix.ps1              # interactive menu (Arabic + English)
.\PC-Fix.ps1 -Phase all   # full workflow
```

- Needs administrator rights — the script self-elevates via UAC.
- A **reboot** is required after the fixes (pagefile), and optionally a second one for the RAM test (~15–30 min unattended).
- All actions are logged to `PC-Fix-Log-<date>\` with **backups and one-click restore scripts** (`restore-fix.ps1`, `run-hkcu-backup.reg`, …).
- If a **BitLocker recovery key** screen ever appears: the key lives in your Microsoft account → https://aka.ms/myrecoverykey

## Safety notes
- The tool only touches common software-level causes (pagefile/injection/services/autostart/file integrity/RAM test) — it is not a substitute for driver, Windows, or BIOS updates.
- Everything is reversible; logs and backups are written next to the script and are **never** uploaded anywhere.

## التعليمات بالعربي
موجودة كاملة في ملف [`قراءة-أولا.md`](./قراءة-أولا.md) — وانقله على أي لابتوب تاني وشغله بنفس الخطوات.
