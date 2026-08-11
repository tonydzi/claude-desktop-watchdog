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
    Write-Output "$($cases.Count - $fail)/$($cases.Count) passed"
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
        'OK'         { Write-Log 'OK' "procs=$($paths.Count)" }
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
