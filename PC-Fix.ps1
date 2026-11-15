# PC-Fix.ps1  —  Reusable PC stability repair tool
# Encapsulates the full diagnostic + repair workflow: pagefile/commit fix, injected-mod
# removal (Windhawk), junk services + autostart trim, disk cleanup, sfc repair, RAM test.
# Everything is logged and reversible (backups + restore scripts are written automatically).
#
# Usage (PowerShell):
#   .\PC-Fix.ps1                -> interactive menu
#   .\PC-Fix.ps1 -Phase diagnose   read-only health report
#   .\PC-Fix.ps1 -Phase fix       apply stability fixes (with confirmations)
#   .\PC-Fix.ps1 -Phase cleanup   free disk space
#   .\PC-Fix.ps1 -Phase sfc       system file repair (15-20 min)
#   .\PC-Fix.ps1 -Phase memtest   schedule RAM hardware test (handles BitLocker)
#   .\PC-Fix.ps1 -Phase all       fix + cleanup + sfc, then offer RAM test + reboot

param([string]$Phase = 'menu')
$ErrorActionPreference = 'Continue'
try { chcp 65001 > $null; [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$script:Root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$script:Log   = Join-Path $Root "PC-Fix-Log-$Stamp"
New-Item -ItemType Directory -Force -Path $Log | Out-Null
$script:LogFile = Join-Path $Log 'pc-fix.log'

function Log($m){ $line = "{0}  {1}" -f (Get-Date -Format s), $m; try { $line; Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch {} }
function FreeGB { [math]::Round((Get-PSDrive C).Free/1GB,2) }
function IsAdmin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

function Confirm($q){
  Write-Host ""
  $a = Read-Host "$q [y/n]"
  return ($a -match '^(y|yes|n|نعم|اه|ايه)$')
}

# ---------- DIAGNOSE (read-only) ----------
function Invoke-Diagnose {
  $report = Join-Path $Log 'diagnose-report.txt'
  $arabic = Join-Path $Log 'التقرير-بالعربي.txt'
  Log 'DIAGNOSE: start'
  $os = Get-CimInstance Win32_OperatingSystem
  $ramGB = [math]::Round($os.TotalVisibleMemorySize/1MB,1)
  $commitTotal = [math]::Round($os.TotalVirtualMemorySize/1MB,1)
  $commitFree  = [math]::Round($os.FreeVirtualMemory/1MB,1)
  $lines = @()
  $ar = @()

  $lines += "PC-Fix health report  -  $(Get-Date -Format s)"
  $lines += ("Machine: {0} {1} | Boot: {2}" -f (Get-CimInstance Win32_ComputerSystem).Manufacturer, (Get-CimInstance Win32_ComputerSystem).Model, $os.LastBootUpTime)
  $lines += ("RAM: {0} GB | Commit limit: {1} GB | Commit FREE: {2} GB" -f $ramGB, $commitTotal, $commitFree)
  $ar += ("الذاكرة (RAM): {0} جيجا | سقف الالتزام: {1} جيجا | المتاح: {2} جيجا" -f $ramGB, $commitTotal, $commitFree)
  if ($commitFree -lt 1) { $lines += "!! CRITICAL: commit free under 1 GB - memory starvation (root cause of freezes/crashes)"; $ar += "!! تحذير حرج: الذاكرة الافتراضية على وشك النفاد - ده سبب رئيسي للتجميد والكCrash" }

  $lines += "--- Pagefiles ---"
  $ar += "--- ملف الذاكرة الافتراضية (pagefile) ---"
  Get-CimInstance Win32_PageFileUsage | ForEach-Object { $l=("ACTIVE: {0} allocated={1}MB" -f $_.Name,$_.AllocatedBaseSize); $lines += $l; $ar += "مفعل: {0} بحجم {1} ميجا" -f $_.Name,$_.AllocatedBaseSize }
  Get-CimInstance Win32_PageFileSetting | ForEach-Object { $l=("CONFIGURED: {0} initial={1} max={2}" -f $_.Name,$_.InitialSize,$_.MaximumSize); $lines += $l; $ar += "مضبوط: {0} من {1} لـ {2} ميجا" -f $_.Name,$_.InitialSize,$_.MaximumSize }
  if (-not (Get-CimInstance Win32_PageFileUsage)) { $lines += "!! NO ACTIVE pagefile"; $ar += "!! مفيش pagefile شغال" }

  $lines += "--- Unexpected shutdowns (Kernel-Power 41 / 6008) last 14 days ---"
  $crashes = Get-WinEvent -FilterHashtable @{LogName='System'; Id=41,6008,1001; StartTime=(Get-Date).AddDays(-14)} -ErrorAction SilentlyContinue
  $lines += ("Count: {0}" -f ($crashes | Measure-Object).Count)
  $ar += ("عدد الرفضات/التجميدات غير الطبيعية آخر 14 يوم: {0}" -f ($crashes | Measure-Object).Count)
  $crashes | Where-Object Id -eq 1001 | ForEach-Object { $lines += ("BSOD bugcheck: {0}" -f (($_.Message -replace '\r?\n',' ').Substring(0,[Math]::Min(120,($_.Message -replace '\r?\n',' ').Length)))) }

  $lines += "--- Top crashing apps (Application Error 1000, 7 days) ---"
  Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error'; Id=1000; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Properties[0].Value } | Group-Object | Sort-Object Count -Descending | Select-Object -First 8 |
    ForEach-Object { $lines += ("{0}x  {1}" -f $_.Count,$_.Name); $ar += ("{0} مرة: {1}" -f $_.Count,$_.Name) }

  $lines += "--- Crash-looping services (SCM, 7 days) ---"
  $loopers = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Service Control Manager'; Level=2; StartTime=(Get-Date).AddDays(-7)} -MaxEvents 500 -ErrorAction SilentlyContinue |
    ForEach-Object { $m=$_.Message; $n=$null; if ($m -match 'The (.+?) service terminated'){$n=$Matches[1]} elseif ($m -match 'waiting for the (.+?) service to connect'){$n=$Matches[1]} elseif ($m -match 'response from the (.+?) service'){$n=$Matches[1]}; if($n){[pscustomobject]@{S=$n}} } |
    Group-Object S | Sort-Object Count -Descending | Select-Object -First 10
  if ($loopers) { $loopers | ForEach-Object { $lines += ("{0}x  {1}" -f $_.Count,$_.Name); $ar += ("خدمة بتقع وتقوم {0} مرة: {1}" -f $_.Count,$_.Name) } }

  $lines += "--- Disk health ---"
  Get-PhysicalDisk | ForEach-Object { $l=("{0}: {1} / {2}" -f $_.FriendlyName,$_.HealthStatus,$_.OperationalStatus); $lines += $l; $ar += ("القرص {0}: الحالة {1}" -f $_.FriendlyName,$_.HealthStatus) }
  $lines += ("C: free {0} GB" -f (FreeGB)); $ar += ("مساحة C: الفاضية {0} جيجا" -f (FreeGB))

  $lines += "--- Top memory (commit) consumers ---"
  Get-Process | Sort-Object PrivateMemorySize64 -Descending | Select-Object -First 10 | ForEach-Object { $l=("  {0} (pid {1}) commitMB={2}" -f $_.ProcessName,$_.Id,[math]::Round($_.PrivateMemorySize64/1MB)); $lines += $l; $ar += ("اعلى استهلاك: {0} - {1} ميجا" -f $_.ProcessName,[math]::Round($_.PrivateMemorySize64/1MB)) }

  $lines += "--- Injected mods (Windhawk) ---"
  $wh = Test-Path 'C:\ProgramData\Windhawk\Engine\Mods'
  $lines += ("Windhawk mods present: {0}" -f $wh); $ar += ("مودات Windhawk (بتتعمل Right-Click في كل البرامج): {0}" -f $wh)

  $lines += "--- Bogus extensionless files in System32 ---"
  foreach ($n in 'powershell','cmd','regedit') { $p = "C:\Windows\System32\$n"; if (Test-Path $p) { $i = Get-Item $p -Force; if ($i.Extension -eq '') { $lines += ("BOGUS: {0} ({1} bytes)" -f $p,$i.Length); $ar += ("ملف غريب بيكسر التشغيل: {0}" -f $p) } } }

  $lines += "--- RAM test results (Windows Memory Diagnostic) ---"
  $mt = Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-MemoryDiagnostics-Results'} -MaxEvents 3 -ErrorAction SilentlyContinue
  if ($mt) { $mt | ForEach-Object { $lines += ("{0}: {1}" -f $_.TimeCreated, ($_.Message -replace '\r?\n',' ')); $ar += ("اختبار الرامات: {0} - {1}" -f $_.TimeCreated, $_.Message) } }
  else { $lines += "never tested"; $ar += "الرامات لم يتم اختبارها من قبل" }

  $lines | Set-Content $report -Encoding UTF8
  $ar | Set-Content $arabic -Encoding UTF8
  Write-Host ""
  Write-Host "Report: $report" ; Write-Host "التقرير بالعربي: $arabic"
  $lines | ForEach-Object { Write-Host $_ }
  Log 'DIAGNOSE: done'
}

# ---------- FIX (pagefile / windhawk / services / autostart) ----------
function Invoke-Fix {
  Log 'FIX: start'
  # 1) pagefile: pick a healthy fixed NTFS drive that is not BitLocker-protected (locked at boot = pagefile never engages)
  $ramGB = [math]::Round((Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize/1MB,0)
  $cands = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object { $_.DeviceID -ne 'C:' -and $_.FreeSpace/1GB -gt 25 }
  $target = 'C:\pagefile.sys'
  foreach ($d in $cands) {
    $bl = Get-BitLockerVolume -MountPoint $d.DeviceID -ErrorAction SilentlyContinue
    if ($bl -and $bl.ProtectionStatus -eq 'On') { Log ("Skipping {0} - BitLocker protected (pagefile would never engage)." -f $d.DeviceID); continue }
    $target = "{0}\pagefile.sys" -f $d.DeviceID; break
  }
  $init = 4096; $max = if ($ramGB -le 8) { 12288 } else { 16384 }
  if ($target -eq 'C:\pagefile.sys' -and (FreeGB) -lt 15) { $init = 2048; $max = 8192 }
  Log ("Pagefile target: {0} initial={1} max={2}" -f $target,$init,$max)
  $cs = Get-CimInstance Win32_ComputerSystem
  if ($cs.AutomaticManagedPagefile) { $cs | Set-CimInstance -Property @{AutomaticManagedPagefile=$false} }
  Get-CimInstance Win32_PageFileSetting | ForEach-Object { Log ("Removing old setting: {0}" -f $_.Name); $_ | Remove-CimInstance }
  $pf = New-CimInstance -ClassName Win32_PageFileSetting -Property @{Name=$target} -ErrorAction Stop
  $pf | Set-CimInstance -Property @{InitialSize=[uint32]$init; MaximumSize=[uint32]$max}
  Log ("Pagefile set on {0} ({1}-{2} MB). Reboot required." -f $target,$init,$max)

  # 2) injected mods (Windhawk)
  $svc = Get-Service | Where-Object { $_.Name -match 'windhawk' -or $_.DisplayName -match 'Windhawk' }
  foreach ($s in $svc) { try { Stop-Service $s.Name -Force -ErrorAction Stop; Set-Service $s.Name -StartupType Disabled; Log ("Windhawk service {0} stopped+disabled" -f $s.Name) } catch { Log ("Windhawk service op failed: {0}" -f $_.Exception.Message) } }
  Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'windhawk' } | ForEach-Object { Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath | Out-Null; Log ("Windhawk task disabled: {0}" -f $_.TaskName) }
  $mods = 'C:\ProgramData\Windhawk\Engine\Mods'
  if (Test-Path $mods) { try { Rename-Item $mods 'Mods.DISABLED-BY-PCFIX' -ErrorAction Stop; Log 'Windhawk mods folder neutralized.' } catch { Log ("Mods rename failed: {0}" -f $_.Exception.Message) } }
  Get-Process | Where-Object { $_.ProcessName -like 'windhawk*' } | Stop-Process -Force -ErrorAction SilentlyContinue

  # 3) junk crash-looping services
  $patterns = @('*Anytxt*','Downloaded Maps Manager','*Print Scan Doctor*','*CCleaner*','Fing.Agent','Connected User Experiences and Telemetry')
  $bk = @{}
  foreach ($p in $patterns) {
    Get-Service | Where-Object { $_.DisplayName -like $p } | ForEach-Object {
      try {
        $bk[$_.Name] = @{ Display=$_.DisplayName; Start=(Get-CimInstance Win32_Service -Filter "Name='$($_.Name)'").StartMode }
        if ($_.Status -eq 'Running') { Stop-Service $_.Name -Force -ErrorAction Stop }
        Set-Service $_.Name -StartupType Disabled; Log ("Service disabled: {0} [{1}]" -f $_.Name,$_.DisplayName)
      } catch { Log ("Service {0} op failed: {1}" -f $_.Name,$_.Exception.Message) }
    }
  }
  $bk | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $Log 'services-backup.json')

  # 4) autostart trim (backup first)
  reg export HKCU\Software\Microsoft\Windows\CurrentVersion\Run (Join-Path $Log 'run-hkcu-backup.reg') /y | Out-Null
  reg export HKLM\Software\Microsoft\Windows\CurrentVersion\Run (Join-Path $Log 'run-hklm-backup.reg') /y | Out-Null
  $hkcuKill = @('Figma Agent','Teams','electron.app.Notion','IdeaShareKey','Gemini','MicrosoftEdgeAutoLaunch_*','GoogleUpdaterTaskUser*')
  $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
  $props = (Get-Item $runKey).Property | Where-Object { $n=$_; ($hkcuKill | Where-Object { $n -like $_ }) }
  foreach ($v in $props) { Remove-ItemProperty $runKey -Name $v -ErrorAction Continue; Log ("HKCU Run removed: {0}" -f $v) }
  $runKeyLM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
  foreach ($v in @('iTunesHelper')) { if (Get-ItemProperty $runKeyLM -Name $v -ErrorAction SilentlyContinue) { Remove-ItemProperty $runKeyLM -Name $v; Log ("HKLM Run removed: {0}" -f $v) } }

  # 5) bogus extensionless system files
  foreach ($n in 'powershell','cmd','regedit') { $p = "C:\Windows\System32\$n"; if (Test-Path $p) { $i = Get-Item $p -Force; if ($i.Extension -eq '') { Log ("Removing bogus file: {0}" -f $p); Remove-Item $p -Force -ErrorAction Continue } } }

  # 6) restore script
  $restore = @'
# Undo PC-Fix: services + autostart (pagefile/Windhawk stay - they are the fix)
$bk = Get-Content (Join-Path $PSScriptRoot 'services-backup.json') | ConvertFrom-Json
foreach ($p in $bk.PSObject.Properties) {
  $st = if ($p.Value.Start -eq 'Auto') {'Automatic'} elseif ($p.Value.Start -eq 'Disabled') {'Disabled'} else {'Manual'}
  Set-Service -Name $p.Name -StartupType $st -ErrorAction Continue
}
reg import (Join-Path $PSScriptRoot 'run-hkcu-backup.reg')
reg import (Join-Path $PSScriptRoot 'run-hklm-backup.reg')
'@
  Set-Content (Join-Path $Log 'restore-fix.ps1') -Value $restore
  Log 'FIX: done (reboot required to apply pagefile).'
  Write-Host "`nFixes applied. A REBOOT is required for the pagefile change." -ForegroundColor Green
  Write-Host "تم تطبيق الإصلاحات - لازم اعادة تشغيل عشان الpagefile يشتغل" -ForegroundColor Green
}

# ---------- CLEANUP ----------
function Invoke-Cleanup {
  Log 'CLEANUP: start'
  $before = FreeGB
  try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch {}
  foreach ($t in @('C:\Windows\Temp', "$env:LOCALAPPDATA\Temp")) {
    Get-ChildItem $t -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\Temp\\opencode' } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  }
  try {
    Stop-Service wuauserv,bits -Force -ErrorAction SilentlyContinue
    Get-ChildItem 'C:\Windows\SoftwareDistribution\Download' -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue
  } catch {}
  try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch {}
  Get-ChildItem 'C:\Windows\Logs\CBS' -Filter *.log -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue
  $after = FreeGB
  Log ("CLEANUP: freed {0} GB ({1} -> {2})" -f [math]::Round($after-$before,2),$before,$after)
  Write-Host ("Freed {0} GB. C: free now {1} GB" -f [math]::Round($after-$before,2),$after) -ForegroundColor Green
  Write-Host ("تم تحرير {0} جيجا - مساحة C: دلوقتي {1} جيجا" -f [math]::Round($after-$before,2),$after) -ForegroundColor Green
}

# ---------- SFC ----------
function Invoke-Sfc {
  Log 'SFC: start (15-20 min, do not close)'
  Write-Host "Running sfc /scannow ... 15-20 min. جاري فحص ملفات الويندوز، سيب النافذة مفتوحة." -ForegroundColor Yellow
  $null = cmd /c ("sfc /scannow > `"$Log\sfc.log`" 2>&1")
  $sr = Select-String -Path 'C:\Windows\Logs\CBS\CBS.log' -Pattern '\[SR\]' -ErrorAction SilentlyContinue | Select-Object -Last 3
  $sr | ForEach-Object { Log $_.Line }
  Log 'SFC: done'
  Write-Host "sfc finished - see log. تم الانتهاء." -ForegroundColor Green
}

# ---------- MEMTEST ----------
function Invoke-Memtest {
  Log 'MEMTEST: schedule start'
  try { Get-BitLockerVolume | ForEach-Object { Log ("BitLocker {0}: {1}/{2}" -f $_.MountPoint,$_.ProtectionStatus,$_.VolumeStatus) } } catch {}
  try { Suspend-BitLocker -MountPoint 'C:' -RebootCount 3 -ErrorAction Stop; Log 'BitLocker C: suspended for 3 reboots (auto-resumes).' } catch { Log ("Suspend failed: {0}" -f $_.Exception.Message) }
  $out = bcdedit /bootsequence '{memdiag}' 2>&1 | Out-String
  Log ("bcdedit: {0}" -f $out.Trim())
  Write-Host "RAM test scheduled. Next reboot runs it (15-30 min, hands off), then boots Windows normally." -ForegroundColor Green
  Write-Host "تم جدولة اختبار الرامات: اعادة التشغيل الجاية هيعمل الاختبار لوحده وبعدها يفتح الويندوز عادي، ومتلمسش الكيبورد وقت الاختبار." -ForegroundColor Green
}

# ---------- SELF-ELEVATE ----------
if (-not (IsAdmin) -and $Phase -ne 'diagnose') {
  Write-Host "Needs administrator rights - relaunching elevated (click Yes on UAC)..."
  Write-Host "محتاج صلاحيات admin - هفتحلك نافذة الUAC دوس Yes"
  Start-Process 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-Phase',$Phase)
  exit
}

# ---------- PHASES / MENU ----------
if ($Phase -eq 'diagnose') { Invoke-Diagnose; exit }
if ($Phase -eq 'fix')      { if (Confirm 'Apply stability fixes? Apply؟') { Invoke-Fix }; exit }
if ($Phase -eq 'cleanup')  { Invoke-Cleanup; exit }
if ($Phase -eq 'sfc')      { Invoke-Sfc; exit }
if ($Phase -eq 'memtest')  { Invoke-Memtest; exit }
if ($Phase -eq 'all')      {
  Invoke-Diagnose
  if (Confirm 'Apply fixes? Apply؟') { Invoke-Fix }
  if (Confirm 'Free disk space? تنظيف المساحة؟') { Invoke-Cleanup }
  if (Confirm 'Run system file repair now (15-20 min)? فحص ملفات الويندوز؟') { Invoke-Sfc }
  if (Confirm 'Schedule RAM test on next reboot? اختبار الرامات عند اعادة التشغيل؟') { Invoke-Memtest; if (Confirm 'Reboot NOW to run it? اعادة التشغيل دلوقتي؟') { shutdown /r /t 30 /f /c "PC-Fix: RAM test" } }
  exit
}

while ($true) {
  Write-Host ""
  Write-Host "========= PC-Fix =========" -ForegroundColor Cyan
  Write-Host " 1) Diagnose          فحص شامل (مش بيغير حاجة)"
  Write-Host " 2) Apply fixes       تطبيق الإصلاحات (محتاج اعادة تشغيل)"
  Write-Host " 3) Cleanup disk      تنظيف المساحة"
  Write-Host " 4) System file repair فحص ملفات الويندوز (15-20 دقيقة)"
  Write-Host " 5) RAM test          اختبار الرامات (15-30 دقيقة)"
  Write-Host " 6) ALL               كل حاجة بالترتيب"
  Write-Host " 0) Exit              خروج"
  $c = Read-Host "اختر رقم / choice"
  switch ($c) {
    '1' { Invoke-Diagnose }
    '2' { if (Confirm 'Apply stability fixes? Apply؟') { Invoke-Fix } }
    '3' { Invoke-Cleanup }
    '4' { Invoke-Sfc }
    '5' { Invoke-Memtest }
    '6' { & $PSCommandPath -Phase all; exit }
    '0' { exit }
  }
}
