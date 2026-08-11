# claude-desktop-watchdog

**Claude Desktop on Windows will not reopen, and clicking the icon does nothing. You reboot. You should not have to.**

A dead instance keeps holding the single-instance lock, so every click on the icon is
swallowed by a process that will never draw a window again. Rebooting works because it
kills the survivor. So does this, every five minutes, without taking your machine down.

One PowerShell file. No modules, no network, no telemetry. MIT.

```powershell
git clone https://github.com/tonydzi/claude-desktop-watchdog
cd claude-desktop-watchdog
powershell -ExecutionPolicy Bypass -File .\claude_desktop_watchdog.ps1 -SelfTest   # 5 fixtures, changes nothing
powershell -ExecutionPolicy Bypass -File .\claude_desktop_watchdog.ps1 -Install    # every 5 min, Scheduled Task
```

Remove it with `-Uninstall`. It keeps no state, so that is the whole rollback.

## What it decides

| what it sees | what it does |
|---|---|
| no MSIX package | nothing, logs `NO_PACKAGE` |
| no Desktop processes | launches the app |
| only current-version processes | nothing (`OK`) |
| current **and** older-version processes | kills the older ones only |
| only older-version processes | kills them, then launches |

"Older-version" means the executable path is not under the `InstallLocation` that
`Get-AppxPackage` reports right now. After an MSIX update, a survivor of the previous
package looks exactly like that.

**Two things it will never touch.** `claude-code` CLI sessions, because the filter is
strictly `C:\Program Files\WindowsApps\Claude_*` and the CLI lives under
`%APPDATA%\Claude\claude-code\<version>\claude.exe`. And healthy processes of the current
version, because no branch kills those. A watchdog that can fight the app it guards is
worse than no watchdog.

## Honest status

The mechanism is **corroborated, not yet caught in the act by us.** Two upstream reports
describe the same shape from other machines: [anthropics/claude-code#84410](https://github.com/anthropics/claude-code/issues/84410)
("while the frozen instance is alive, clicking the app icon does not open a new window,
presumably the single-instance lock is held by the dead instance... killing all `claude.exe`
processes and relaunching recovers it") and [#69987](https://github.com/anthropics/claude-code/issues/69987)
(an update aborts with `0x80073D02`, "the package could not be installed because the
following app must be closed", leaving the package unable to launch).

What we verified on our own machine: the decision table against 5 fixtures, a live run on a
healthy install (correctly does nothing), the launch path
`explorer.exe shell:AppsFolder\<PackageFamilyName>!Claude`, and install/uninstall of the
Scheduled Task. The kill-and-relaunch branch has not fired in anger here yet. When it does,
it writes a snapshot first — which is the other half of this repo.

## Capturing evidence instead of a story

The reason the failure survives is that by the time anyone describes it, the machine is
healthy again and there is nothing left to inspect. Every healing run writes one file to
`%USERPROFILE%\.claude\logs\desktop-incidents\` with the four things a maintainer will ask
for:

- `Get-AppxPackage Claude` — two entries means an update is stuck; `Status != Ok` means
  `Modified, NeedsRemediation`
- the Desktop process list with full paths, so you can see *which version* holds the lock
- the tail of `%APPDATA%\Claude\logs\main.log` (`GPU process gone`, `Starting app`, `beforeQuit`)
- AppX deployment events mentioning Claude (`0x80073D02` = the update could not close the app)

You can take the same snapshot by hand while the app is wedged, before you kill anything:

```powershell
powershell -ExecutionPolicy Bypass -File .\claude_desktop_watchdog.ps1 -CollectEvidence
```

If that file says "no Claude events in the last 60 records", it says so out loud rather than
printing an empty section. An empty section reads as "nothing happened"; the truth is "the
log window is small". Silence that looks like a result is how you end up debugging the wrong
thing.

## The one-liner, if you want no scheduled task at all

```powershell
Get-Process claude -EA SilentlyContinue | Where-Object { $_.Path -like 'C:\Program Files\WindowsApps\Claude_*' } | Stop-Process -Force
explorer.exe shell:AppsFolder\Claude_pzs8sxrjxfjjc!Claude
```

This kills *all* Desktop processes including healthy ones, which is fine when the app is
already wedged and is why the scheduled version is narrower.

## Log

One JSON line per run to `%USERPROFILE%\.claude\logs\claude_desktop_watchdog.jsonl`:

```json
{"ts":"2026-08-11T09:10:53Z","node":"HOSTNAME","actor":"claude_desktop_watchdog","event":"decision","outcome":"OK","detail":"procs=11"}
```

`OK` is the boring case and should be almost every line. `HEALED` is the one worth grepping
for — it means the class is real on your machine too, and there is a snapshot to go with it.

---

Built at [Palo Alto AI Research Lab](https://github.com/tonydzi) while running a fleet of
Claude machines. Sibling repo for macOS session hygiene:
[claude-mac-patrol](https://github.com/tonydzi/claude-mac-patrol).
