# Current Status — Soleux Device Manager

Derived from `doc/description.md`. Each item reflects actual state of the Flutter codebase under `lib/`.
Ast: `✅` implemented · `🟡` partial (notes follow) · `❌` not implemented / sim-only.

> Note: the running app is `lib/screens/` + `lib/services/` (launched from `lib/main.dart`). The earlier `lib/features/` scaffold is not wired to launch.

---

## Project Stages (per description §V)

- [x] ✅ **Stage 1 — Planning and Kick-off** *(declared current stage)* — `plan.md`, `doc/description.md`, `doc/PROTOCOLS.md`, `pubspec.yaml` in place.
- [x] 🟡 **Stage 2 — UI/UX Design and Prototyping** — code-driven prototype instead of Figma; theme tokens, 27 screens, ARB-based copy. No exported interactive Figma deliverable.
- [x] 🟡 **Stage 3 — Hardware Delivery & Technical Documentation** — `doc/PROTOCOLS.md` (TCP ASCII, UDP discovery, WebSocket) written; integration contract partly codable. Physical units / test bench **not in repo**.
- [ ] 🟡 **Stage 4 — Technical Development (Implementation)** — most UI and local persistence done; live transport and cloud scaffolding only partial.
- [ ] ❌ **Stage 5 — Final Testing (QA) and Optimization** — not started.
- [ ] ❌ **Stage 6 — Launch and Publication in Stores** — `playStore`/`appStore` metadata not prepared.
- [ ] ❌ **Stage 7 — Post-Launch Support and Maintenance** — analytics/crash reporting not wired.

---

## Application Structure (Main Navigation)

- [x] ✅ Bottom **NavigationBar** with four primary tabs (Home / Configuration / Scenarios / Settings) — `RootShell` in `lib/main.dart`.
- [x] ✅ Tab state preservation across switches — `IndexedStack`.

---

## I. Home Section

- [x] ✅ Quick-access scenarios (those with `showInHome == true`) on Home — `HomeScreen._QuickScenarioCard`.
- [x] ✅ Drag-and-drop reordering — `ReorderableListView` + `ScenarioStore.move`.
- [x] ✅ Prominent red banner for offline modules (`_AlertBanner`).
- [x] ✅ Tapping banner navigates to **Notification History** (`/system-status` route).
- [x] ✅ Notification History records real OFFLINE / RESTORED / FIRMWARE events as they happen (`StatusLogStore` + `NotificationMonitor`), persists them to shared_preferences (`StatusLogRepository`), and raises the matching OS notification.
- [x] ✅ Temperature card per module on Home; reads `ModuleStore.internalTempC`.
- [x] ✅ Per-module min/max temperature thresholds (`tempMinC` / `tempMaxC`) — settable on `TemperatureModuleScreen`.
- [x] ✅ Temperature alert renders as a second `_AlertBanner` (same component as offline).
- [x] ✅ Real-time updates from local TCP probes (where supported — see Configuration §2.3 caveat).

---

## II. Configuration Section

### 2.1 Adding and Managing Modules

- [x] ✅ Self-discovery broadcast handler — `ModuleDiscovery` (UDP `:8000`, see `doc/PROTOCOLS.md §2`), surfaced in `AddModuleScreen`.
- [x] ✅ Add modules by IP address (manual fallback with TCP port selection).
- [x] ✅ Module list (Device List) with online/offline status dot — `ConfigurationScreen`.

### Hybrid Communication Protocol

- [x] ✅ **Local Control** — `LanTransport` (TCP :5008) and per-module persistent `ModuleCommandService` with auto-reconnect.
- [x] 🟡 **Remote Control (MQTT)** — `MqttTransport` class exists (`core/transport/mqtt_transport.dart`) and `mqtt_client` package is in `pubspec.yaml`, but **no consumer wires it** in screens/services. Failover is also a class only, not bound.
- [x] ❌ Per-command LAN→MQTT failover resolver — `FailoverTransport` implemented as a class but **not instantiated** anywhere in the running app.

### 2.2 Detailed Control Interface (Channels and Outputs)

- [x] ✅ List of all module outputs (e.g. 8 on the seeded relay) — `RelayControlScreen`.
- [x] ✅ Large ON/OFF direct-command button per output (≥48dp touch targets).
- [x] ✅ Output naming — `ChannelEditorScreen`.
- [x] ✅ Icon per output — same editor, `kChannelIconChoices`.
- [x] ✅ Physical input configuration (`InputEditorScreen`):
  - [x] ✅ Momentary mode
  - [x] ✅ Toggle mode
  - [x] ✅ Associated mode (linked to a channel name; scenario binding shows as `<name> (scenario)` label)
- [x] 🟡 Physical-input → scenario binding — represented in the dropdown only; no scheduler reacts when the input changes state.

### 2.3 Extended Control Types (Dedicated Modules)

- [x] ✅ Dedicated `RelayControlScreen` (ON/OFF).
- [x] ✅ Dedicated `BlindControlScreen` (UP / DOWN with toggle-stop on second press of same direction).
- [x] ✅ Dedicated `DimmerDcScreen` (4 × 12–24V PWM, slider + edit).
- [x] ✅ Dedicated `DimmerAcScreen` (4 × 220V, slider + edit).
- [x] ✅ Dedicated `TemperatureModuleScreen` (read + per-module min/max thresholds).
- [x] ✅ Advanced thermostat explicitly disabled (`Coming Soon` row, brief §2.3 Level 1).
- [x] 🟡 Live wire integration: `ModuleStatusService.registerFetcher` registry has a `RelayModuleStatusFetcher` only. Dimmer/DC/AC/Blind/Temperature drivers exist but fall back to local state (no continuous live TCP fetcher wired for those types yet).

### 2.4 Automations and Scenarios (Scenes)

- [x] ✅ Tap-to-run action scenarios — `ScenariosScreen` + `ScenarioEditorScreen`.
- [x] ✅ Unlimited custom scenarios — `ScenarioStore` (no cap).
- [x] ✅ Multiple actions per scenario across relay + dimmer outputs.
- [x] ✅ Precise 0–100 % brightness incl. 0 % = OFF, 100 % = ON — `ScenarioAction.brightnessPct`.
- [x] ✅ "Manual dimming Slider" scenario — `ManualDimmingSliderScreen`, openable from Home.
- [x] ✅ Smart Automations (IF … THEN …):
  - [x] ✅ UI for time-of-day trigger — `AutomationEditorScreen`.
  - [x] ✅ UI for device-state trigger — same.
  - [x] 🟡 **Trigger execution** — `AutomationTriggerType` is captured, but there is **no background scheduler that fires automated rules**; they only fire when the toggle is enabled in the UI.
- [x] ✅ Event History with **30-day rolling retention** — `EventLogStore` (prune by `retention = Duration(days: 30)`) + `EventHistoryScreen`.

### 2.5 Organization by Rooms (Zones)

- [x] ✅ Create / rename / reorder / delete rooms — `RoomsScreen` + `RoomStore`.
- [x] ✅ Assign scenarios to a room — `ScenarioEditorScreen` (room dropdown), persisted as `Scenario.roomName`.
- [x] ✅ Rooms strip on Home, opening a bottom sheet of room scenarios.

---

## III. Settings Section

### 3.1 Account Management and Cloud Synchronization

- [x] 🟡 **Mandatory account screen (Login, Register, Forgot password)** — present, but auth is **simulated**: any non-empty email/password navigates into the app. No real auth backend.
- [x] 🟡 Account management UI — `AccountScreen` (profile + change password + last-backup timestamp).
- [x] 🟡 Cloud backup / restore button — present and shows a snackbar/last-backup; **no actual network upload**. SharedPreferences-backed local persistence is in place for modules/rooms/scenarios.
- [x] 🟡 Multi-device sync — *architecture deferred*; stores persist locally, no Firestore sync.
- [x] 🟡 Password recovery by email — screen flips to a "check your inbox" confirmation; no email is actually sent.
- [x] ❌ Firebase Auth / Firestore wiring — packages declared in `pubspec.yaml`, `**/google-services.json` & `**/GoogleService-Info.plist` intentionally gitignored, **no `Firebase.initializeApp` / `FirebaseAuth` / `cloud_firestore` import exists in `lib/`**.

### 3.2 Push Notifications

- [x] ✅ Per-alert toggles in `NotificationsSettingsScreen` (offline, temperature, output-left-on, automation triggered), persisted via `SettingsStore`.
- [x] ✅ Background-aware scheduler + monitor — `BackgroundStatusWorker` + `ModuleStatusScheduler` + `NotificationMonitor`.
- [x] ✅ Local notifications fire on:
  - [x] ✅ Module went offline / came back online.
  - [x] ✅ Module temperature out of configured range.
  - [x] ✅ Output left ON longer than threshold (default 12 h, user-configurable via `NotificationsSettingsScreen`).
  - [x] ✅ Automation triggered (when toggled).
- [x] ❌ **Cloud push (FCM/APNs)** — `firebase_messaging` is in `pubspec.yaml` but no `FirebaseMessaging` usage in `lib/`.

---

## IV. General and Technical Requirements

### 4.1 UI/UX

- [x] ✅ Minimalist, high-contrast Material 3 design system — `AppTheme` + `theme_palettes.dart`.
- [x] ✅ Large controls, generous touch targets, semantically colored (online/offline, alert/normal).

### 4.2 Architecture and Scalability

- [x] ✅ Single-location v1 UX (per brief). Room grouping visible; **no multi-location UI**, which is in line with the brief's v1 scope.
- [ ] ❌ Explicit Location selector and per-location scope in UI — intentionally deferred to v1.1.

### 4.3 Localization and Language Support

- [x] ✅ English (`app_en.arb`) — Launch locale.
- [x] ✅ Romanian (`app_ro.arb`) — Launch locale; `LanguageSettingsScreen` selector.
- [x] ✅ ARB/codegen pipeline via `flutter_localizations` + `AppLocalizations`.
- [x] ✅ Locale-aware formatting via `intl` (declared).
- [x] 🟡 Spanish / French / German — listed under a **Coming Soon** card; no ARB catalogs yet (pipeline ready, no strings).

---

## Explicitly Out of Current Scope (per description.md)

- [x] ✅ Cloud / web admin portal — surfaced as out-of-scope in `account_screen.dart` notes.
- [x] ✅ Advanced thermostat / multi-zone temperature — `Coming Soon` badge on `TemperatureModuleScreen`.
