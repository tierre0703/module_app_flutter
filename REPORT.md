# Daily Change Report — module_app_flutter

**Report range:** Sep 11, 2026 → Nov 2, 2026 (today)
**Generated:** Mon, Nov 2, 2026
**Data source:** git history (`HEAD`, all branches merged to `main`)

## Overview

| Metric | Value |
|---|---|
| Commits in range | 216 (incl. merge commits) |
| Active coding days | 22 |
| Version span | v1.0.8 → v1.0.30(22) |
| Main contributors | tierre0703, devcraft |

### Theme summary by week

- **Sep 11–13** — Device connection hardening (TCP keep-alive, foreground service, status polling) + first wave of Scenario color-picking UI.
- **Sep 14–17** — CI/CD build-out (fastlane iOS deploy, macOS build, release artifacts), backup/restore feature, event broadcast handling, dimmer/slider sync fixes, module system log with filter & pagination.
- **Oct 1–5** — Ports migration (5005 → 5008), module type selection, module state sync, security fix for blocked modules (PR #21).
- **Oct 10–14** — iOS/TestFlight stabilization, 7 PRs merged in one day (input/output editor behavior, backup naming, orphaned scenario fix), launch image & version strings.
- **Oct 16–22** — **Modbus HUB support** (docs, HUB screens, event broadcasting) + complete tile-grid UI rework with drag & drop.
- **Oct 27** — Final version bump v1.0.30(22).

---

## Daily breakdown

### 2026-09-11 (19 commits, ~63 files, +3,447 / -746)

v1.0.8 (merged via devcraft). Focus: Android background behavior and device status reliability.
- Android: foreground service setting, notification permission (`checkSelfPermission`) fixes, `backgroundPollFrequency` config, `moduleKeepAliveService.kt` onTimeout signature fix.
- Connection: TCP connection closed by peer periodically — fixed; keep device alive; replaced `hello` with `get_device_state` polling instead of device events; `ce30d13` module_status_scheduler `onLifecycleChanged`.
- Status mirroring of live status to modules; opened device status polled every 1 s.
- UI/docs: scenario card format change (applied then reverted), text tweaks, app version synchronization, specification doc → v0.6.
- Merge: `v1_0_8` branch into main (devcraft).

### 2026-09-13 (13 commits, ~93 files, +4,421 / -2,154)

Scenario color personalization + empty-state polish; merged v1.0.8 → v1.0.11.
- Removed mock data from the codebase (`879cbbf`).
- Scenario color picker: custom color add/remove, background in scenario screen, live color preview in the picker.
- Removed filled IconButton style; empty-state centering in configuration screen ("no modules added yet") and home-screen no-modules handling.
- Version bumps; PR merges #3 (v1_0_8), #4 (v1_0_10).

### 2026-09-14 (22 commits, ~67 files, +758 / -426)

CI day — fully debugging the iOS deploy pipeline in GitHub Actions.
- `ios_deploy` build script in `build_deploy.yml`; fastlane exception/keychain/code-signing failures fixed iteratively (provisioning profile creds, cert for distribution, fastlane key_content).
- CocoaPods: pod install version mismatch, cocoapods version display, `bundle install`, gem cocoapods added.
- Quality gates: format check, flutter analyze check on commit.
- Merge: PR #5 (v1_0_11).

### 2026-09-15 (15 commits, ~235 files, +8,798 / -1,316)

Backup/restore + CI expansion; version v1.0.12 (PR #7 merged).
- Backup/restore: full UI + logic implementation, `replaceAll` in stores, read/write local-storage permission.
- CI: macOS GitHub Actions build addition, push build artifacts to GitHub Releases, ipa path fixes.
- Tooling: GitHub Action deprecated marker-out, moved to githooks pre-commit; login skip; disabled all builds except iOS (later commit).
- Merge: PR #6 (ios_deploy). Version bump v1.0.12.

### 2026-09-16 (15 commits, ~51 files, +2,066 / -789)

Automation rework + event broadcasting groundwork; v1.0.13.
- AUTOMATION CHANGES (`f0bde0a`); hide inputs/outputs; minor tweaks.
- Event handling implementation + event broadcasting testcase addition (PR #9).
- keepAlive → "hello" replacement (reverted then re-applied by devcraft).
- Empty-state centering in event history screen; Android notification icon; pre-commit githook disabled.

### 2026-09-17 (21 commits, ~62 files, +2,322 / -650)

Dimmer/slider sync day; v1.0.14 → 1.0.16.
- Dimmer event handling; `actual_pwm` → `set_pwm` (reverted by devcraft, later re-applied).
- Scenario editor screen dimmer sync; scenario card manual dimming slider syncing issue; mark out fallback.
- Module-specific system log; event history commented out.
- New features: filter addition, pagination addition + goto-page-number function.
- Versions: 1.0.14(5) → 1.0.15(6) → 1.0.16(7).

### 2026-10-01 (9 commits, ~42 files, +937 / -140)

State sync & post-release fixes; v1.0.17 → 1.0.18.
- Module screen takes snapshot when first opened; customized input/output names retrieved from modules.
- Edit Scenario — Slider Target not pointing at target output; Quick Scenario slider flickering (get_device_state vs user sliding conflicts).
- Merges: PR #12 (module_state_sync), PR #13 (slider target). Version up to 1.0.18.

### 2026-10-04 (12 commits, ~138 files, +3,280 / -2,242)

Port migration + module info editing; PRs #17, #18, #19, #20 merged.
- Default ports changed 5005 → 5008; TCP port → 5008; tcpport issue fixes.
- Module type selection in the edit-module-info dialog (PR #20).
- Restore/backup logic (`beb19de`).
- State logic: default module state = offline, changing-state-to-suspect logic changes, manual mode error fixes.

### 2026-10-05 (6 commits, ~21 files, +210 / -101)

Security + iOS strings; v1.0.19.
- API port and heartbeat port removal (PR #21) — fixes "when a module is blocked in security, the app shows it as connected and working".
- iOS plist proper `NS*UsageDescription` strings; formatting; version 1.0.19.

### 2026-10-10 (4 commits, ~44 files, +1,591 / -59)

iOS build configuration day.
- iOS build config + build fixes ("ios build fix" ×2), merge branch main.

### 2026-10-11 (10 commits, ~43 files, +1,808 / -976)

Connection model rework; PR #30 merged.
- Status check now based on socket connection only; unknown → online switching fix; "hello not working properly with module status" fix.
- Socket connect modified to accept IP **and hostname**; removal of AT legacy protocol fallback (`b644cbc`).
- Discovered-module screen: multi-select add (PR #28/#30); icon changes, UI fixes; iOS build.

### 2026-10-12 (19 commits, ~188 files, +4,903 / -2,273)

Big merge day — 7 PRs merged (v1.0.21):
- PR #31 — no heartbeat (5007) check when in port-forward mode.
- PR #32 — Input editor: enable/disable behavior modification.
- PR #33 — Output/channel editor: remove → enable/disable.
- PR #34 — Settings: disable http/https selection.
- PR #35 — Backup file naming convention.
- PR #36 — Module deletion no longer orphanes scenarios.
- Also: input toggle enable/disable, touchApp icon removal, dart format fixes, TestFlight issue fixes, v1.0.21.
- (Merge commit `4c9b7ab` recorded 2026-10-13 00:00 UTC, part of PR #36.)

### 2026-10-14 (5 commits, ~14 files, +38 / -45)

Release packaging; v1.0.23 → v1.0.24.
- Launch image replacement; iOS purpose strings added; version bumps.

### 2026-10-16 (9 commits, ~26 files, +3,085 / -419)

**Modbus HUB introduction** — the biggest feature of the month.
- `modbus HUB control API documentation` added (`01db97f`).
- HUB addition + import modification; hub screen modification; button replace; build error fixes.
- Theming: dark mode background alpha (reverted by tierre0703, then background modification by devcraft).

### 2026-10-17 (2 commits, ~5 files, +157 / -108)

Module action UX.
- Snackbar/toast when applying a module action; bottom space added to module list in configuration.

### 2026-10-18 (4 commits, ~6 files, +168 / -72)

Event broadcasting fixes + cleanup; v1.0.25.
- Event broadcasting fixes; build issue fixes; home screen — scenario card action removed.

### 2026-10-19 (4 commits, ~8 files, +642 / -7)

- Event broadcasting + event broadcasting log output; pulse disable; v1.0.26(18).

### 2026-10-20 (11 commits, ~35 files, +711 / -260)

HUB integration fixes; v1.0.27 → 1.0.28.
- Automation/scenario changes according to Modbus HUB; modbus issue fixes; automation screen issue fixes; hub addition issues.
- UI: action buttons right-aligned, spacing with new button in scenario/automation screen, module-name ellipsis fix on module screen.

### 2026-10-21 (6 commits, ~11 files, +519 / -247)

Tile grid rework (day 1).
- Tile grid replacement; drag & drop; drag handle added & placement adjusted; grid fixes and grid handle.

### 2026-10-22 (9 commits, ~16 files, +557 / -358)

Tile grid rework (day 2), with trial-and-error cycle; released v1.0.29(21).
- Grid tile width → full; grid tile style; tile_grid changes; `grid tile UI changes` made then reverted (plus "UI trash" and "what's this change?" cleanups); final UI fixes.

### 2026-10-27 (1 commit, 1 file, +1 / -1)

- Version bump: **v1.0.30(22)** — latest commit on `main`.

### 2026-10-13 (0 diff)

- Merge-only day (PR #36 merge recorded at 00:00 UTC); no content changes of its own.

---

## Version history in range

| Version | Date | Commit |
|---|---|---|
| v1.0.8 | Sep 11 | `0317c11` |
| v1.0.10 / v1.0.11 | Sep 13 | PRs #4, #5 |
| v1.0.12 | Sep 15 | `64d3c1e` |
| v1.0.13 | Sep 16 | `dd57f5f` |
| v1.0.14(5) / v1.0.15(6) / v1.0.16(7) | Sep 17 | `a53e280`, `7844193`, `bd34da5` |
| v1.0.17 / v1.0.18 | Oct 1 | `da484e6`, `21271a6` |
| v1.0.19 | Oct 5 | `4cc2f7e` |
| v1.0.21 | Oct 12 | `6e8deac` |
| v1.0.23 / v1.0.24 | Oct 14 | `37370d6`, `a8a57a5` |
| v1.0.25 | Oct 18 | `eb901c0` |
| v1.0.26(18) | Oct 19 | `c9e2b70` |
| v1.0.27(19) / v1.0.28(20) | Oct 20 | `c880510`, `9a40508` |
| v1.0.29(21) | Oct 22 | `d76ba17` |
| v1.0.30(22) | Oct 27 | `923c7af` |

> Note: date attribution uses commit author dates (UTC). Merge commits reference the PRs they merged. Per-day file/change counts are approximate (merge repetitions excluded where possible).
