# claude-desktop-watchdog

**Claude Desktop on Windows will not reopen, and clicking the icon does nothing. You reboot. You should not have to.**

A dead instance keeps holding the single-instance lock, so every click on the icon is
swallowed by a process that will never draw a window again — the shape reported in [#84410](https://github.com/anthropics/claude-code/issues/84410). Rebooting works because it
kills the survivor. So does [claude_desktop_watchdog.ps1](claude_desktop_watchdog.ps1), every five minutes, without taking your machine down.

One PowerShell file, [claude_desktop_watchdog.ps1](claude_desktop_watchdog.ps1): no modules, no network, no telemetry, licensed [MIT](LICENSE).

```powershell
git clone https://github.com/tonydzi/claude-desktop-watchdog
cd claude-desktop-watchdog
powershell -ExecutionPolicy Bypass -File .\claude_desktop_watchdog.ps1 -SelfTest   # 22 fixtures, changes nothing
powershell -ExecutionPolicy Bypass -File .\claude_desktop_watchdog.ps1 -Install    # every 5 min, Scheduled Task
```

Remove it with `-Uninstall`, then delete
`%USERPROFILE%\.claude\logs\claude_desktop_watchdog.state` if you want the last trace gone.

## What it decides

| what it sees | what it does |
|---|---|
| no MSIX package | nothing, logs `NO_PACKAGE` |
| no Desktop processes | launches the app |
| only current-version processes | checks the window (below), usually `OK` |
| current **and** older-version processes | kills the older ones only |
| only older-version processes | kills them, then launches |

"Older-version" means the executable path is not under the `InstallLocation` that
`Get-AppxPackage` reports right now, and that comparison is the whole decision in [claude_desktop_watchdog.ps1](claude_desktop_watchdog.ps1).
After an MSIX update, a survivor of the previous package looks exactly like that, which is the failure in [#69987](https://github.com/anthropics/claude-code/issues/69987).

## The other failure: alive but wedged (v0.2)

Processes are current, the app is "running", and the window is dead. Clicking the icon
still does nothing, because the frozen instance owns the lock, exactly as described in [#84410](https://github.com/anthropics/claude-code/issues/84410).
Killing the process list is the known recovery named in that same report; the point of a watchdog is to notice without you.

| what it sees | what it does |
|---|---|
| a window responds | `OK` |
| no window responds, first tick | `HUNG_ARMED` — kills nothing |
| no window responds, second tick (~10 min) | evidence, kills all Desktop procs, relaunches |
| 3 heals inside 6 hours | `HUNG_BRAKE` — stops healing, says so |

`Responding` is a ping of the UI thread, and a ping is not a diagnosis: it goes false while
the app is merely busy and during the first seconds of startup. Every guard below in [claude_desktop_watchdog.ps1](claude_desktop_watchdog.ps1)
is aimed at that one weakness.

- **Two consecutive ticks on the same pid.** A different pid means the app already
  restarted, so the counter starts over rather than inheriting someone else's freeze. The
  tracked pid is the one from last tick if it is still wedged, otherwise the lowest — not
  "first in the array", because `Get-Process` order is not guaranteed and with two wedged
  windows the counter would hop between pids and never reach two.
- **90-second startup grace.** A window that has not finished coming up is not wedged, and the grace value sits at the top of [claude_desktop_watchdog.ps1](claude_desktop_watchdog.ps1).
- **State older than 20 minutes is stale.** Sleep, reboot, and skipped ticks must not add
  up to "two ticks in a row" across a weekend, so [claude_desktop_watchdog.ps1](claude_desktop_watchdog.ps1) dates every counter it writes.
- **One live window is enough.** If any window answers, nothing is killed — a second,
  wedged window never costs you the healthy one, which is the first branch [claude_desktop_watchdog.ps1](claude_desktop_watchdog.ps1) checks.
- **Crash-loop brake.** Three heals in six hours means restarting is not the fix, so [claude_desktop_watchdog.ps1](claude_desktop_watchdog.ps1)
  stops and leaves `HUNG_BRAKE` in the log for a human.
- **Minimized to the tray → `MainWindowHandle` is 0 → nothing is judged.** Failing open is
  the right side to fail on: the cost of a missed heal is a manual restart, the cost of a
  false one is your work.

The counter lives in `%USERPROFILE%\.claude\logs\claude_desktop_watchdog.state`. Deleting
it is safe; a corrupt one is read as an empty one, because a watchdog that dies on its own
state file is worse than no watchdog — that round-trip is one of the fixtures [claude_desktop_watchdog.ps1](claude_desktop_watchdog.ps1) self-tests.

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

What we verified on our own machine, 2026-08-11: both decision tables against 22 fixtures, including
the state file round-trip and a deliberately corrupted one; the self-test going red under
three mutations (heal on the first tick, ignore a responding window, pick the target by
array position); a live run on a healthy
install and from the Scheduled Task itself (correctly does nothing, logs
`hung=no (a window is responding)`); the launch path
`explorer.exe shell:AppsFolder\<PackageFamilyName>!Claude`; and install/uninstall of the
Scheduled Task.

**Neither killing branch has fired in anger here yet.** We are not going to pretend
otherwise: on this machine the Desktop window is the parent of live CLI sessions, so we
will not stage a real freeze to watch it work. When it fires on its own, it writes a
snapshot first — which is the other half of this repo.

## Capturing evidence instead of a story

The reason the failure survives is that by the time anyone describes it, the machine is
healthy again and there is nothing left to inspect, which is why [claude_desktop_watchdog.ps1](claude_desktop_watchdog.ps1) writes the snapshot before it heals. Every healing run writes one file to
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
already wedged and is why the scheduled version in [claude_desktop_watchdog.ps1](claude_desktop_watchdog.ps1) is narrower.

## Log

One JSON line per run to `%USERPROFILE%\.claude\logs\claude_desktop_watchdog.jsonl`:

```json
{"ts":"2026-08-11T09:10:53Z","node":"HOSTNAME","actor":"claude_desktop_watchdog","event":"decision","outcome":"OK","detail":"procs=11 windowed=1 hung=no (a window is responding)"}
```

Outcomes: `OK` · `LAUNCHED` · `KILLED_STALE` · `HEALED` · `HUNG_ARMED` · `HEALED_HUNG` ·
`HUNG_BRAKE` · `NO_PACKAGE` · `CRASH`.

`OK` is the boring case and should be almost every line [claude_desktop_watchdog.ps1](claude_desktop_watchdog.ps1) writes. `HEALED` and `HEALED_HUNG` are the
ones worth grepping for — they mean the class is real on your machine too, and there is a
snapshot to go with it. `HUNG_ARMED` with no `HEALED_HUNG` after it is the good outcome:
the app answered on its own and nothing was killed.

---

Published 2026-08-11, licensed [MIT](LICENSE), cite via [CITATION.cff](CITATION.cff); an agent reading this repo should start at [FOR-ROBOTS.md](FOR-ROBOTS.md).

Built at [Palo Alto AI Research Lab](https://github.com/tonydzi) while running a fleet of
Claude machines. Sibling repo for macOS session hygiene:
[claude-mac-patrol](https://github.com/tonydzi/claude-mac-patrol).

---

<!--ecosystem-map:start-->

## 🧩 One piece of a working system

This repository is one piece lifted out of a live operation: one engineer running a fleet of
machines, built with Claude as implementation collaborator; the machines reach consensus with
each other and wake the human only for money or the irreversible. It was extracted after it
survived production, not written as a demo — and it runs on its own: nothing here phones home
to the rest.

**See how the whole thing fits together → [SYSTEM.md](https://github.com/tonydzi/tonydzi/blob/main/SYSTEM.md)**

<!--ecosystem-map:end-->

## AI contributors

This project is built by a human + AI team, and the git log says so: Claude writes most of
the code, Codex and Grok review it, Gemini feeds the research. Each is credited on a commit
**only if its output changed that commit's content** — no decorative credits. Lab-wide
policy, one source for every repo: [AI-CONTRIBUTORS.md](https://github.com/tonydzi/.github/blob/main/AI-CONTRIBUTORS.md).

<!-- READ-WITH-AI:START (generated by read_with_ai.py - do not hand-edit) -->

### READ THIS WITH AI

One click and an agent reads the repo, pulls out the patterns and helps you apply them to your own work.

<a href="https://chatgpt.com/codex?prompt=Read%20this%20repo%3A%20https%3A%2F%2Fgithub.com%2Ftonydzi%2Fclaude-desktop-watchdog%20%28%E2%80%9Cclaude-desktop-watchdog%E2%80%9D%20-%20Claude%20Desktop%20on%20Windows%20will%20not%20reopen%20after%20an%20update%20and%20you%20reboot.%20A%20dead%20instance%20is%20holding%20the%20single-instance%20lock%29.%20Work%20out%20what%20problem%20it%20actually%20solves%2C%20pull%20out%20the%20reusable%20patterns%20and%20help%20me%20apply%20them%20to%20my%20own%20setup.%20Start%20by%20asking%20what%20I%20am%20working%20on."><img alt="Codex - open" src="https://img.shields.io/badge/Codex-open-000000?style=for-the-badge&logo=openai&logoColor=white"></a> <a href="https://chatgpt.com/?q=Read%20this%20repo%3A%20https%3A%2F%2Fgithub.com%2Ftonydzi%2Fclaude-desktop-watchdog%20%28%E2%80%9Cclaude-desktop-watchdog%E2%80%9D%20-%20Claude%20Desktop%20on%20Windows%20will%20not%20reopen%20after%20an%20update%20and%20you%20reboot.%20A%20dead%20instance%20is%20holding%20the%20single-instance%20lock%29.%20Work%20out%20what%20problem%20it%20actually%20solves%2C%20pull%20out%20the%20reusable%20patterns%20and%20help%20me%20apply%20them%20to%20my%20own%20setup.%20Start%20by%20asking%20what%20I%20am%20working%20on."><img alt="ChatGPT - open" src="https://img.shields.io/badge/ChatGPT-open-10a37f?style=for-the-badge&logo=openai&logoColor=white"></a> <a href="https://claude.ai/new?q=Read%20this%20repo%3A%20https%3A%2F%2Fgithub.com%2Ftonydzi%2Fclaude-desktop-watchdog%20%28%E2%80%9Cclaude-desktop-watchdog%E2%80%9D%20-%20Claude%20Desktop%20on%20Windows%20will%20not%20reopen%20after%20an%20update%20and%20you%20reboot.%20A%20dead%20instance%20is%20holding%20the%20single-instance%20lock%29.%20Work%20out%20what%20problem%20it%20actually%20solves%2C%20pull%20out%20the%20reusable%20patterns%20and%20help%20me%20apply%20them%20to%20my%20own%20setup.%20Start%20by%20asking%20what%20I%20am%20working%20on."><img alt="Claude - open" src="https://img.shields.io/badge/Claude-open-d97757?style=for-the-badge&logo=anthropic&logoColor=white"></a>

<details>
<summary>Copy the prompt (works in any agent: Gemini, Grok, a local model, your own CLI)</summary>

```text
Read this repo: https://github.com/tonydzi/claude-desktop-watchdog (“claude-desktop-watchdog” - Claude Desktop on Windows will not reopen after an update and you reboot. A dead instance is holding the single-instance lock). Work out what problem it actually solves, pull out the reusable patterns and help me apply them to my own setup. Start by asking what I am working on.
```

</details>

<sub>— TonyDzi, Palo Alto AI Research Lab · second brain, agent coordination, persistent memory: github.com/tonydzi</sub>

<!-- READ-WITH-AI:END -->
