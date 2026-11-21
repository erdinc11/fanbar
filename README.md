<div align="center">

<img src="docs/banner.svg" alt="FanBar — menu bar fan control for Apple silicon" width="100%">

# FanBar

**A tiny macOS menu bar fan controller for Apple silicon.**
Live CPU temperature, one-click fan presets, manual RPM, and a root helper you can install or remove from the menu — with zero telemetry.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](#requirements)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-M1%E2%80%93M5-5E5CE6)](#compatibility)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](#build-from-source)
[![No dependencies](https://img.shields.io/badge/dependencies-none-34C759)](#build-from-source)
[![MIT](https://img.shields.io/badge/license-MIT-34C759)](LICENSE)

</div>

## Why FanBar

Most fan utilities are either closed source or heavier than they need to be. FanBar is a small, auditable AppKit app that does one job:

- **Temperature in the menu bar.** The hottest CPU die sensor is read once per second and shown as `57°`.
- **Fan RPM in the dropdown.** The menu's first row updates live while the menu is open.
- **One-click presets.** Auto, 2.5k, 3k, 4k, 5k, and 6.8k (Full). Full always follows the fan's real `F0Mx`, never a hardcoded number.
- **Manual RPM.** Pick *Manual RPM…* and enter any value inside the fan's discovered range.
- **Helper lifecycle in the menu.** *Install Helper…* when it is missing, *Remove Helper…* when it is present. macOS asks for an administrator password once; nothing is stored.
- **Start at Login.** A single toggle backed by `SMAppService`.
- **Fail-safe by design.** The fan returns to macOS control when the app quits, the helper exits, the lease expires, or the Mac sleeps. No ownerless manual mode.
- **Nearly free to run.** ~55 MB RSS for the app, ~6 MB for the helper, and 0.0–0.7% CPU on an M3 MacBook Pro.

## Requirements

- macOS 13 or later (verified on macOS 27 Tahoe)
- Apple silicon Mac with at least one fan (verified on Mac15,3 / M3)
- Administrator password for the one-time helper install
- Xcode or Command Line Tools to build from source

## Install

1. Download `FanBar.dmg` from the latest release (or build it with `Scripts/build-dmg.sh`).
2. Open the DMG and drag **FanBar** into **Applications**.
3. The app is ad-hoc signed, not notarized. On first launch, right-click **FanBar** and choose **Open**.
4. Click the menu bar item and choose **Install Helper…**. Approve the macOS administrator prompt once.
5. Pick a fan speed — or leave it on **Auto**.

> FanBar needs a small root LaunchDaemon because macOS rejects SMC fan writes from unprivileged processes. The app itself never runs as root.

## Usage

| Menu item | What it does |
|---|---|
| `Fan: 3448 RPM` | Live actual fan speed (updates every second) |
| `Auto` | Hands the fan back to macOS |
| `2.5k` … `6.8k (Full)` | Fixed targets inside the fan's real range |
| `Manual RPM…` | Enter a custom value between the fan's minimum and maximum |
| `Start at Login` | Registers FanBar as a login item |
| `Install Helper…` / `Remove Helper…` | Installs or removes the root helper |
| `Helper: ready` | Helper reachability and state |
| `Quit` | Releases the fan to macOS and exits |

## Safety model

- **Fan writes go through one root helper.** The app and the Unix socket client stay unprivileged.
- **UID-gated socket.** The helper accepts only root and the user who installed it, checked with `getpeereid`.
- **12-second lease.** If the app stops talking, the helper restores Auto.
- **Mode-first writes.** On this M3 the SMC ignores `F0Tg` while the fan is in Auto, so the helper writes `F0Md=1` and then the target, with read-back verification.
- **Auto is `F0Md=0` only.** No target is written during release, matching the behaviour verified in OpenFan and fanctl.
- **Signal-safe shutdown.** `SIGTERM`/`SIGINT`/`SIGHUP` set an atomic flag and wake the control loop through a self-pipe; the restore runs on a normal thread, never inside the signal handler.
- **One connection, one thread.** A stalled local client cannot block the control channel.
- **Sleep and helper restarts.** The app re-applies the selected speed on wake and after a helper restart; Auto stays Auto.

## Compatibility

FanBar discovers the fan count, mode-key casing (`F0Md` or `F0md`), minimum and maximum RPM, and the available CPU sensors at launch. It never hardcodes fan limits.

| Hardware | Status |
|---|---|
| Mac15,3 — MacBook Pro 14" (M3) | Verified |
| Other Apple silicon Macs with fans | Should work; run `swift run FanBarProbe` and open an issue with the output |
| Intel Macs | Not supported |

The classic `TC0P` proximity key does not exist on Apple silicon; FanBar reads the CPU die sensor group (`Tp09`, `Tp0T`, `Tp01`, …) and reports the hottest valid value.

## Build from source

```sh
git clone https://github.com/erdinc11/fanbar.git
cd fanbar

# Build the app and install it in /Applications
bash Scripts/build-app.sh

# Or produce a DMG in dist/
bash Scripts/build-dmg.sh

# Run the tests
swift test
```

Useful scripts:

| Script | Purpose |
|---|---|
| `Scripts/build-app.sh` | Release build, app bundle, ad-hoc signature, `/Applications` install |
| `Scripts/build-dmg.sh` | Drag-to-Applications DMG in `dist/FanBar.dmg` |
| `Scripts/install-helper.sh` | CLI helper install (one sudo prompt, password never stored) |
| `Scripts/uninstall-helper.sh` | CLI helper removal |
| `Scripts/remove-macs-fan-control.sh` | Removes the third-party Macs Fan Control app/helper |

## Architecture

```
FanBar.app (unprivileged, LSUIElement)
  ├─ NSStatusItem             live CPU temperature, 1 Hz
  ├─ MenuBarController        presets, manual RPM, helper lifecycle, login item
  ├─ FanBarSMC                AppleSMC over IOKit (reads only)
  └─ HelperClient             Unix socket, one request per connection
        │
        ▼
fanbar-helper (root LaunchDaemon)
  ├─ getpeereid UID check
  ├─ FanBarSMC                F0Tg / F0Md writes
  └─ 12 s lease + 1 s re-assert + Auto fail-safe
```

SwiftPM targets: `FanBarSMC`, `FanBarCore`, `FanBarApp`, `FanBarHelper`, `FanBarProbe`, plus four XCTest suites (35 tests).

## Credits

FanBar was written from scratch, but it stands on the work of these MIT-licensed projects and public research:

- [OpenFan](https://github.com/stevenahhh/openfan) — Apple silicon SMC key catalogue and safety model
- [fanctl](https://github.com/erogol/fanctl) — Unix-socket root daemon pattern and Auto semantics
- [macos-smc-fan](https://github.com/agoodkind/macos-smc-fan) — SMC research on Apple silicon
- [Stats](https://github.com/exelban/stats) and [SMCKit](https://github.com/beltex/SMCKit) — AppleSMC protocol references
- [Asahi Linux SMC documentation](https://asahilinux.org/docs/hw/soc/smc/) — public SMC background

AppleSMC is a private interface. Apple can change it at any time; use this software at your own risk.

## License

[MIT](LICENSE)
