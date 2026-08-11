<#
.SYNOPSIS
  Watchdog for Claude Desktop on Windows: when a stale instance holds the single-instance
  lock, the app cannot be relaunched by clicking its icon. This kills only the stale
  processes and starts the app again, so you do not have to reboot.

.DESCRIPTION
  Decision table, evaluated every run:

    no MSIX package found                  -> NO_PACKAGE (do nothing, log it)
    no Claude Desktop processes            -> LAUNCH
    only processes of the CURRENT version  -> OK (do nothing)
    current + older-version processes      -> kill the older ones only
    only older-version processes           -> kill them, then launch

  "Older-version" means the executable path does not sit under the InstallLocation that
  Get-AppxPackage reports right now. After an MSIX update that is exactly what a survivor
  of the previous package looks like.

  Second class, added in v0.2 -- the app is RUNNING but WEDGED. Processes are alive and
  current, the window is dead, and clicking the icon does nothing because the frozen
  instance still owns the single-instance lock. When the OK branch is reached, the windowed
  process is pinged:

    a window is responding                 -> OK
    every window not responding, 1st tick  -> HUNG_ARMED (nothing killed)
    every window not responding, 2nd tick  -> evidence, kill ALL Desktop procs, relaunch
    3 heals within 6 hours                 -> HUNG_BRAKE (stop healing, this needs a human)

  Why two ticks. Responding is a ping of the UI thread; it goes false while the app is
  merely busy and during the first seconds of startup. So: two consecutive ticks (~10 min)
  on the SAME pid, a 90 s startup grace, and state older than 20 minutes (sleep, reboot,
  missed ticks) counts as a first tick rather than a second one. If the window is minimized
  to the tray, MainWindowHandle is 0, there is no windowed process, and nothing is judged --
  failing open beats killing a healthy app.

  What it never touches:
    - claude-code CLI processes (%APPDATA%\Claude\claude-code\<ver>\claude.exe).
      The filter is strictly 'C:\Program Files\WindowsApps\Claude_*'.
    - healthy processes of the current version. No branch kills those, so the watchdog
      cannot fight the app it is guarding.

.PARAMETER Install
  Copy nothing, just register a Scheduled Task that runs this file every 5 minutes.

.PARAMETER Uninstall
  Remove that Scheduled Task.

.PARAMETER SelfTest
  Run the decision table against fixtures and exit non-zero on any mismatch. No side effects.

.PARAMETER CollectEvidence
  Write a snapshot (package status, process list, main.log tail, AppX deployment events)
  and exit. Nothing is killed or started. Use it while the app is actually wedged.

.NOTES
  Windows PowerShell 5.1+, no modules, no network, no telemetry. MIT.
#>
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$SelfTest,
    [switch]$CollectEvidence
)

$ErrorActionPreference = 'Stop'
$TaskName    = 'Claude-Desktop-Watchdog'
$DesktopGlob = 'C:\Program Files\WindowsApps\Claude_*'
$LogDir      = Join-Path $env:USERPROFILE '.claude\logs'
$LogFile     = Join-Path $LogDir 'claude_desktop_watchdog.jsonl'
$StateFile   = Join-Path $LogDir 'claude_desktop_watchdog.state'
$IncidentDir = Join-Path $LogDir 'desktop-incidents'

function Get-Decision {
    param([string]$InstallLocation, [string[]]$DesktopProcPaths)
    if (-not $InstallLocation)         { return 'NO_PACKAGE' }
    if ($DesktopProcPaths.Count -eq 0) { return 'LAUNCH' }
    $current = @($DesktopProcPaths | Where-Object { $_ -like "$InstallLocation*" })
    $stale   = @($DesktopProcPaths | Where-Object { $_ -notlike "$InstallLocation*" })
    if ($current.Count -gt 0 -and $stale.Count -eq 0) { return 'OK' }
    if ($current.Count -gt 0 -and $stale.Count -gt 0) { return 'KILL_STALE_ONLY' }
    return 'KILL_STALE_AND_LAUNCH'
}

function Get-HungVerdict {
    <# The whole "is it wedged" decision, as a pure function: no processes, no disk, so it
       can be tested. Every rule below exists because of a specific way this can go wrong.

       -Windowed     @( @{ ProcId=<int>; Responding=<bool>; AgeSec=<int> } ) -- windowed
                     processes of the CURRENT version only
       -Prior        last tick's state @{ pid; count; ts } or $null
       -NowEpoch     current time in epoch seconds (passed in, not read, so tests can lie)
       -RecentHeals  epoch seconds of previous heals (crash-loop brake)

       Returns @{ Verdict = 'NONE'|'ARM'|'HEAL'|'BRAKE'; Count; ProcId; Reason } #>
    param(
        [array]$Windowed,
        $Prior,
        [double]$NowEpoch,
        [array]$RecentHeals = @(),
        [int]$MaxGapSec  = 1200,
        [int]$MinAgeSec  = 90,
        [int]$MaxHeals6h = 3
    )
    # No windowed process: minimized to tray, or the app is simply not up. Judge nothing.
    if (-not $Windowed -or @($Windowed).Count -eq 0) {
        return @{ Verdict = 'NONE'; Count = 0; ProcId = 0; Reason = 'no windowed process (tray or not running)' }
    }
    # One live window is enough. Otherwise a second, wedged window would cost you the healthy one.
    foreach ($w in $Windowed) {
        if ($w.Responding) { return @{ Verdict = 'NONE'; Count = 0; ProcId = 0; Reason = 'a window is responding' } }
    }
    # A window legitimately does not answer while the app is still coming up.
    $oldest = (@($Windowed) | ForEach-Object { [int]$_.AgeSec } | Measure-Object -Maximum).Maximum
    if ($oldest -lt $MinAgeSec) {
        return @{ Verdict = 'NONE'; Count = 0; ProcId = 0; Reason = "startup grace (oldest ${oldest}s < ${MinAgeSec}s)" }
    }
    # Which one we are counting. Not "first in the array": Get-Process order is not
    # guaranteed, so with TWO wedged windows the counter would hop between pids and never
    # reach two. Keep following the pid from last tick if it is still wedged; otherwise the
    # lowest, which is stable whatever order the list arrives in.
    $ids    = @(@($Windowed) | ForEach-Object { [int]$_.ProcId } | Sort-Object)
    $target = [int]$ids[0]
    if ($Prior -and ($ids -contains [int]$Prior.pid)) { $target = [int]$Prior.pid }
    $count  = 1
    $why    = 'first not-responding tick'
    if ($Prior -and [int]$Prior.pid -eq $target -and ($NowEpoch - [double]$Prior.ts) -le $MaxGapSec) {
        # Same pid, fresh state: this really is the second tick of one freeze.
        $count = [int]$Prior.count + 1
        $why   = "not responding $count ticks in a row (pid $target)"
    } elseif ($Prior -and [int]$Prior.pid -eq $target) {
        $why = "stale state, gap $([int]($NowEpoch - [double]$Prior.ts))s -- counting from 1"
    } elseif ($Prior -and [int]$Prior.pid -ne 0) {
        $why = "different pid (was $([int]$Prior.pid), now $target) -- counting from 1"
    }
    if ($count -lt 2) { return @{ Verdict = 'ARM'; Count = $count; ProcId = $target; Reason = $why } }
    $fresh = @(@($RecentHeals) | Where-Object { $_ -and ($NowEpoch - [double]$_) -le 21600 })
    if ($fresh.Count -ge $MaxHeals6h) {
        return @{ Verdict = 'BRAKE'; Count = $count; ProcId = $target
                  Reason = "$($fresh.Count) heals in the last 6h -- crash loop, a restart is not the fix" }
    }
    return @{ Verdict = 'HEAL'; Count = $count; ProcId = $target; Reason = $why }
}

function Read-HungState {
    # Missing or corrupt file means "clean slate", never a crash of the watchdog itself.
    if (-not (Test-Path $StateFile)) { return $null }
    try {
        $j = Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return @{ pid = [int]$j.pid; count = [int]$j.count; ts = [double]$j.ts; heals = @($j.heals) }
    } catch { return $null }
}

function Write-HungState {
    param([int]$TargetPid, [int]$Count, [double]$Ts, [array]$Heals)
    try {
        if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force $LogDir | Out-Null }
        $keep = @(@($Heals) | Where-Object { $_ -and ($Ts - [double]$_) -le 86400 })   # 24h, file cannot grow
        @{ pid = $TargetPid; count = $Count; ts = $Ts; heals = $keep } |
            ConvertTo-Json -Compress | Set-Content -Path $StateFile -Encoding UTF8
    } catch { }   # state is a convenience, not a precondition: an unwritable file must not stop the watchdog
}

function Write-Log {
    param([string]$Outcome, [string]$Detail)
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force $LogDir | Out-Null }
    $rec = [ordered]@{
        ts      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        node    = $env:COMPUTERNAME
        actor   = 'claude_desktop_watchdog'
        event   = 'decision'
        outcome = $Outcome
        detail  = $Detail
    } | ConvertTo-Json -Compress
    Add-Content -Path $LogFile -Value $rec -Encoding UTF8
}

function Save-Evidence {
    <# A bug report needs artifacts from the moment of failure. By the time a human
       describes the symptom, the machine is usually healthy again and there is nothing
       left to look at. This grabs the four things upstream asks for. #>
    param([string]$Reason)
    try {
        if (-not (Test-Path $IncidentDir)) { New-Item -ItemType Directory -Force $IncidentDir | Out-Null }
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
        $out   = Join-Path $IncidentDir "incident-$stamp.txt"
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("reason: $Reason")
        $lines.Add("host: $env:COMPUTERNAME   utc: $stamp")
        $lines.Add("--- Get-AppxPackage Claude (two entries = update stuck; Status != Ok = NeedsRemediation) ---")
        Get-AppxPackage -Name 'Claude' | ForEach-Object {
            $lines.Add(("{0}  Status={1}  {2}" -f $_.Version, $_.Status, $_.InstallLocation)) }
        $lines.Add("--- Claude Desktop processes (path tells you which version holds the lock) ---")
        Get-Process claude -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -like $DesktopGlob } |
            ForEach-Object { $lines.Add(("pid={0} start={1} responding={2} {3}" -f $_.Id, $_.StartTime, $_.Responding, $_.Path)) }
        $lines.Add("--- main.log tail (look for 'GPU process gone', 'Starting app', 'beforeQuit') ---")
        $mainLog = Join-Path $env:APPDATA 'Claude\logs\main.log'
        if (Test-Path $mainLog) { Get-Content $mainLog -Tail 80 | ForEach-Object { $lines.Add($_) } }
        else { $lines.Add("(main.log not found at $mainLog)") }
        $lines.Add("--- AppX deployment events (0x80073D02 = update could not close the app) ---")
        try {
            $ev = @(Get-WinEvent -LogName 'Microsoft-Windows-AppXDeploymentServer/Operational' -MaxEvents 60 -ErrorAction Stop |
                    Where-Object { $_.Message -like '*Claude*' })
            if ($ev.Count -eq 0) {
                $lines.Add("(no Claude events in the last 60 records. That is NOT evidence no update happened - the window is small.)")
            } else {
                $ev | ForEach-Object { $lines.Add(("{0}  id={1}  {2}" -f $_.TimeCreated, $_.Id, ($_.Message -split "`n")[0])) }
            }
        } catch { $lines.Add("(AppXDeploymentServer log unreadable: $($_.Exception.Message))") }
        Set-Content -Path $out -Value $lines -Encoding UTF8
        return $out
    } catch { return "evidence-failed: $($_.Exception.Message)" }
}

if ($SelfTest) {
    $cases = @(
        @{ n = 'no package';      loc = '';                 procs = @();                                   want = 'NO_PACKAGE' },
        @{ n = 'no processes';    loc = 'C:\PF\Wa\Claude_2'; procs = @();                                  want = 'LAUNCH' },
        @{ n = 'healthy current'; loc = 'C:\PF\Wa\Claude_2'; procs = @('C:\PF\Wa\Claude_2\app\Claude.exe'); want = 'OK' },
        @{ n = 'only stale';      loc = 'C:\PF\Wa\Claude_2'; procs = @('C:\PF\Wa\Claude_1\app\Claude.exe',
                                                                       'C:\PF\Wa\Claude_1\app\Claude.exe'); want = 'KILL_STALE_AND_LAUNCH' },
        @{ n = 'mixed';           loc = 'C:\PF\Wa\Claude_2'; procs = @('C:\PF\Wa\Claude_2\app\Claude.exe',
                                                                       'C:\PF\Wa\Claude_1\app\Claude.exe'); want = 'KILL_STALE_ONLY' }
    )
    $fail = 0
    foreach ($c in $cases) {
        $got = Get-Decision -InstallLocation $c.loc -DesktopProcPaths $c.procs
        if ($got -eq $c.want) { Write-Output "PASS: $($c.n) -> $got" }
        else { Write-Output "FAIL: $($c.n) -> got '$got', want '$($c.want)'"; $fail++ }
    }

    # --- wedged-app branch: one case per way it could misfire -------------------------
    $NOW  = 1000000.0
    $hung = @{ ProcId = 42; Responding = $false; AgeSec = 600 }
    $armed = @{ pid = 42; count = 1; ts = ($NOW - 300) }
    $hcases = @(
        @{ n = 'hung: no windowed process (tray)'; w = @();          p = $armed; want = 'NONE' },
        @{ n = 'hung: a window responds -> reset'; w = @(@{ ProcId = 42; Responding = $true;  AgeSec = 600 }); p = $armed; want = 'NONE' },
        @{ n = 'hung: first tick does not heal';   w = @($hung);      p = $null;  want = 'ARM'  },
        @{ n = 'hung: second tick heals';          w = @($hung);      p = $armed; want = 'HEAL' },
        @{ n = 'hung: stale state = first tick';   w = @($hung);      p = @{ pid = 42; count = 1; ts = ($NOW - 9000) }; want = 'ARM' },
        @{ n = 'hung: different pid = restart';    w = @($hung);      p = @{ pid = 7;  count = 1; ts = ($NOW - 300) };  want = 'ARM' },
        @{ n = 'hung: young process is not judged'; w = @(@{ ProcId = 42; Responding = $false; AgeSec = 10 }); p = $armed; want = 'NONE' },
        @{ n = 'hung: one of two windows alive';   w = @($hung, @{ ProcId = 43; Responding = $true; AgeSec = 600 }); p = $armed; want = 'NONE' },
        # two wedged windows: array order must not reset the counter
        @{ n = 'hung: two wedged, keep following the tracked pid'; w = @(@{ ProcId = 43; Responding = $false; AgeSec = 600 }, $hung); p = $armed; want = 'HEAL' }
    )
    foreach ($c in $hcases) {
        $r = Get-HungVerdict -Windowed $c.w -Prior $c.p -NowEpoch $NOW
        if ($r.Verdict -eq $c.want) { Write-Output "PASS: $($c.n) -> $($r.Verdict)" }
        else { Write-Output "FAIL: $($c.n) -> got '$($r.Verdict)', want '$($c.want)' ($($r.Reason))"; $fail++ }
    }
    # NB: in PowerShell the comma binds tighter than arithmetic, so @($NOW - 600, $NOW - 1200)
    # is parsed as a subtraction of arrays and throws. Each element needs its own parentheses.
    $freshHeals = @([double]($NOW - 600), [double]($NOW - 1200), [double]($NOW - 1800))
    $oldHeals   = @([double]($NOW - 30000), [double]($NOW - 40000), [double]($NOW - 50000))
    $r = Get-HungVerdict -Windowed @($hung) -Prior $armed -NowEpoch $NOW -RecentHeals $freshHeals
    if ($r.Verdict -eq 'BRAKE') { Write-Output 'PASS: hung: 3 heals in 6h -> BRAKE' }
    else { Write-Output "FAIL: hung: brake -> got '$($r.Verdict)', want 'BRAKE'"; $fail++ }
    $r = Get-HungVerdict -Windowed @($hung) -Prior $armed -NowEpoch $NOW -RecentHeals $oldHeals
    if ($r.Verdict -eq 'HEAL') { Write-Output "PASS: hung: yesterday's heals do not brake" }
    else { Write-Output "FAIL: hung: stale heals -> got '$($r.Verdict)', want 'HEAL'"; $fail++ }
    # with no prior state the target is picked deterministically (lowest pid), not "first in the array"
    $r1 = Get-HungVerdict -Windowed @(@{ ProcId = 77; Responding = $false; AgeSec = 600 }, @{ ProcId = 42; Responding = $false; AgeSec = 600 }) -Prior $null -NowEpoch $NOW
    $r2 = Get-HungVerdict -Windowed @(@{ ProcId = 42; Responding = $false; AgeSec = 600 }, @{ ProcId = 77; Responding = $false; AgeSec = 600 }) -Prior $null -NowEpoch $NOW
    if ($r1.ProcId -eq 42 -and $r2.ProcId -eq 42) { Write-Output 'PASS: hung: the target does not depend on process order' }
    else { Write-Output "FAIL: hung: target depends on order ($($r1.ProcId) vs $($r2.ProcId))"; $fail++ }
    $total = $cases.Count + $hcases.Count + 3

    # --- the counter travels through DISK, so test that wiring too ---------------------
    $realState = $StateFile
    $StateFile = Join-Path $env:TEMP ("cdw-selftest-{0}.state" -f $PID)
    if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
    try {
        $T = 2000000.0
        $v = Get-HungVerdict -Windowed @($hung) -Prior (Read-HungState) -NowEpoch $T
        Write-HungState $v.ProcId $v.Count $T @()
        $s = Read-HungState
        if ($s -and [int]$s.count -eq 1 -and [int]$s.pid -eq 42) { Write-Output 'PASS: state: count and pid survive the file' }
        else { Write-Output "FAIL: state: count=$($s.count) pid=$($s.pid), want 1/42"; $fail++ }
        $v = Get-HungVerdict -Windowed @($hung) -Prior $s -NowEpoch ($T + 300) -RecentHeals @($s.heals)
        if ($v.Verdict -eq 'HEAL') { Write-Output 'PASS: state: second tick through disk heals' }
        else { Write-Output "FAIL: state: second tick -> '$($v.Verdict)', want 'HEAL'"; $fail++ }
        Write-HungState 0 0 ($T + 300) (@($s.heals) + ($T + 300))    # what the live HEAL branch writes
        $s = Read-HungState
        if ([int]$s.count -eq 0 -and @($s.heals).Count -eq 1) { Write-Output 'PASS: state: count reset, heal remembered' }
        else { Write-Output "FAIL: state: count=$($s.count) heals=$(@($s.heals).Count), want 0/1"; $fail++ }
        Set-Content -Path $StateFile -Value '{ not json at all' -Encoding UTF8
        if ($null -eq (Read-HungState)) { Write-Output 'PASS: state: corrupt file reads as a clean slate' }
        else { Write-Output 'FAIL: state: corrupt file did not read as null'; $fail++ }
        Write-HungState 0 0 $T @([double]($T - 200000), [double]($T - 100), [double]($T - 50))
        if (@((Read-HungState).heals).Count -eq 2) { Write-Output 'PASS: state: heals older than 24h are pruned' }
        else { Write-Output 'FAIL: state: stale heals were not pruned'; $fail++ }
        $total += 5
    } finally {
        if (Test-Path $StateFile) { Remove-Item $StateFile -Force -ErrorAction SilentlyContinue }
        $StateFile = $realState
    }

    Write-Output "$($total - $fail)/$total passed"
    exit ([int]($fail -gt 0))
}

if ($Install) {
    $self = $MyInvocation.MyCommand.Path
    schtasks /Create /SC MINUTE /MO 5 /TN $TaskName /F `
        /TR "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "schtasks /Create failed with $LASTEXITCODE"; exit 1 }
    schtasks /Run /TN $TaskName | Out-Null
    Write-Output "installed: '$TaskName' runs every 5 minutes -> $self"
    Write-Output "log: $LogFile"
    exit 0
}

if ($Uninstall) {
    schtasks /Delete /TN $TaskName /F | Out-Null
    Write-Output "removed: '$TaskName' (exit $LASTEXITCODE)"
    exit 0
}

if ($CollectEvidence) {
    $f = Save-Evidence 'MANUAL'
    Write-Output $f
    exit ([int]($f -like 'evidence-failed*'))
}

try {
    $pkg = Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue |
           Where-Object { $_.PackageFamilyName -like '*pzs8sxrjxfjjc' } | Select-Object -First 1
    $loc = if ($pkg) { $pkg.InstallLocation } else { '' }

    $desktopProcs = @(Get-Process claude -ErrorAction SilentlyContinue |
                      Where-Object { $_.Path -like $DesktopGlob })
    $paths = @($desktopProcs | ForEach-Object { $_.Path })

    switch (Get-Decision -InstallLocation $loc -DesktopProcPaths $paths) {
        'OK' {
            # Current-version processes are alive. But is the WINDOW alive?
            $now      = [double][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $st       = Read-HungState
            $heals    = if ($st) { @($st.heals) } else { @() }
            $windowed = @($desktopProcs |
                Where-Object { $_.MainWindowHandle -ne 0 -and $_.Path -like "$loc*" } |
                ForEach-Object {
                    # The process can die between Get-Process and the property read, and
                    # .Responding then throws -- with $ErrorActionPreference = 'Stop' that
                    # would crash the whole watchdog for nothing. Gone -> simply not judged;
                    # all gone -> $windowed is empty -> NONE, and Get-Decision handles
                    # "the app is not running" on the next tick.
                    $resp = $null
                    try { $resp = [bool]$_.Responding } catch { }
                    if ($null -ne $resp) {
                        $age = 99999
                        try { $age = [int]((Get-Date) - $_.StartTime).TotalSeconds } catch { }
                        @{ ProcId = $_.Id; Responding = $resp; AgeSec = $age }
                    }
                })
            $v = Get-HungVerdict -Windowed $windowed -Prior $st -NowEpoch $now -RecentHeals $heals
            switch ($v.Verdict) {
                'NONE' {
                    Write-HungState 0 0 $now $heals
                    Write-Log 'OK' "procs=$($paths.Count) windowed=$($windowed.Count) hung=no ($($v.Reason))"
                }
                'ARM' {
                    Write-HungState $v.ProcId $v.Count $now $heals
                    Write-Log 'HUNG_ARMED' "pid=$($v.ProcId) $($v.Reason) -- healing next tick unless it answers"
                }
                'BRAKE' {
                    Write-HungState $v.ProcId $v.Count $now $heals
                    Write-Log 'HUNG_BRAKE' "pid=$($v.ProcId) NOT healing: $($v.Reason)"
                }
                'HEAL' {
                    $ev = Save-Evidence 'HUNG'      # snapshot BEFORE the kill or there is no evidence
                    $desktopProcs | Stop-Process -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 3
                    Start-Process explorer.exe "shell:AppsFolder\$($pkg.PackageFamilyName)!Claude"
                    Write-HungState 0 0 $now (@($heals) + $now)
                    Write-Log 'HEALED_HUNG' "killed=$($desktopProcs.Count) wedged procs (pid $($v.ProcId), $($v.Reason)); relaunched; evidence=$ev"
                }
            }
        }
        'NO_PACKAGE' { Write-Log 'NO_PACKAGE' 'Claude MSIX package not found' }
        'LAUNCH' {
            Start-Process explorer.exe "shell:AppsFolder\$($pkg.PackageFamilyName)!Claude"
            Write-Log 'LAUNCHED' 'no desktop processes were running'
        }
        'KILL_STALE_ONLY' {
            $ev    = Save-Evidence 'KILL_STALE_ONLY'
            $stale = @($desktopProcs | Where-Object { $_.Path -notlike "$loc*" })
            $stale | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Log 'KILLED_STALE' "killed=$($stale.Count); current untouched; evidence=$ev"
        }
        'KILL_STALE_AND_LAUNCH' {
            $ev    = Save-Evidence 'KILL_STALE_AND_LAUNCH'
            $stale = @($desktopProcs | Where-Object { $_.Path -notlike "$loc*" })
            $stale | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
            Start-Process explorer.exe "shell:AppsFolder\$($pkg.PackageFamilyName)!Claude"
            Write-Log 'HEALED' "killed=$($stale.Count) stale; relaunched; evidence=$ev"
        }
    }
    exit 0
}
catch {
    try { Write-Log 'CRASH' $_.Exception.Message } catch {}
    exit 4
}
