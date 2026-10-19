# Privacy Policy — Soleux Device Manager

**Last updated:** October 18, 2026

---

## 1. Introduction

Soleux Device Manager ("the App") is a local network configuration and monitoring tool for Soleux hardware modules (Relay, PDU, AC Dimmer, DC Dimmer, and temperature modules). This Privacy Policy explains what data the App collects, how it is used, and your rights regarding that data.

By using the App, you consent to the practices described in this policy.

---

## 2. Data Controller

The App is developed and published by **Soleux**.  
Contact: [support@soleux.com](mailto:support@soleux.com)

---

## 3. Data We Collect

The App is designed to operate **primarily on your local network**. No data is sent to external servers unless you explicitly enable cloud features. Below is a complete breakdown of what data is stored and processed:

### 3.1 Data Stored Locally (on your device)

All configuration data is stored locally using the device's built-in storage (key-value store and SQLite database). This includes:

| Category | Data Points |
|----------|------------|
| **Module Configuration** | Module ID, name, type, IP address, TCP port, firmware version, serial number, MAC address, connection type (local/remote/cloud), online/offline status, last-seen timestamp |
| **Channel/Output Settings** | Channel names, icons, ON/OFF state, brightness levels, step sizes, physical input names, input modes |
| **Temperature Thresholds** | Min/max temperature thresholds per module, device system info (CPU usage, memory, uptime, network info) |
| **Rooms & Zones** | Room IDs and names used to organize modules |
| **Scenarios** | Scenario IDs, names, icons, types, room assignments, show-in-home flag, background colors, actions per channel |
| **Automations** | Automation IDs, names, trigger types (time-based or device-state-based), schedules, watched module/channel/input indices, actions |
| **App Preferences** | Theme mode (light/dark/system), language locale, home theme palette, notification toggles, default temperature threshold, output-on threshold hours, command transport mode, location name, custom colors |
| **Session State** | Signed-in boolean flag (no credentials stored) |
| **Event Logs** | 30-day rolling history of module actions, scenario runs, automation triggers — timestamps, titles, subtitles |
| **Notification History** | Offline/restored/firmware event notifications (30-day retention) |

### 3.2 Data Transmitted Over Your Local Network

To discover and control Soleux hardware modules, the App sends and receives data over your local network:

- **UDP broadcast discovery** — the App sends a discovery packet to your local network to find Soleux modules
- **TCP commands** — ON/OFF, brightness, and configuration commands are sent directly to modules via TCP (port 5008, JSON protocol)
- **Module status responses** — modules respond with their current state, readings, and diagnostic information

This communication stays entirely within your local network and is not transmitted over the internet.

### 3.3 Data You May Choose to Export

The App includes a **backup/restore** feature that allows you to export all local configuration to a JSON file. This file is saved to your device's file system. You control where it is stored and whether you share it with anyone. No data is automatically uploaded to any server.

### 3.4 Cloud Features (Future / Opt-In Only)

The App's codebase includes architectural scaffolding for the following future cloud features. **These are NOT active unless you explicitly configure and enable them:**

- **MQTT Remote Access** — If enabled, module commands and status data would be transmitted through an MQTT broker you configure. This requires you to provide the broker address, port, and TLS settings. You choose whether to use this feature.
- **Firebase Cloud Sync** — If enabled in a future release, account credentials and configuration backups could be synchronized via Firebase. This would require explicit consent during setup.
- **Push Notifications** — If enabled in a future release, Firebase Cloud Messaging (FCM) could send notifications to your device.

**At present (version 1.0.25), none of the above cloud features are operational.** All app functionality is local-network-only.

---

## 4. How We Use Data

| Purpose | Data Used |
|---------|-----------|
| **Module discovery & control** | Module IP, port, status data, channel state |
| **Configuration persistence** | All module, room, scenario, and automation settings |
| **Scenario & automation execution** | Scenario and automation definitions, trigger conditions |
| **Event history** | Event logs to display recent activity |
| **Notification delivery** | Notification history, temperature thresholds |
| **App personalization** | Theme, language, and UI preferences |
| **Backup & restore** | All local configuration (user-initiated export/import) |

We **do not** use your data for advertising, profiling, analytics, or any form of automated decision-making.

---

## 5. Analytics & Crash Reporting

The App **does not contain any analytics, telemetry, or crash-reporting tools**. No usage data is collected or transmitted. This is by design — all monitoring features are hardware-specific (e.g., module temperature, CPU usage) and operate entirely on your local network.

---

## 6. Data Retention

| Data Type | Retention Period |
|-----------|-----------------|
| Module configuration | Until deleted or factory reset |
| Rooms, scenarios, automations | Until deleted by the user |
| Event logs | 30 days rolling |
| Notification history | 30 days rolling |
| Backup files | As long as you keep them on your device |

Local data persists until you:
- Delete it through the App's settings
- Uninstall the App
- Manually delete the App's data folder
- Use the factory reset feature of your Soleux modules

---

## 7. Data Security

### 7.1 Local Storage

- All data is stored in the device's application sandbox (standard for Flutter apps)
- No encryption is applied to local storage (the data never leaves your device)
- No passwords, API keys, or authentication tokens for cloud services are stored (no cloud services are currently active)

### 7.2 Local Network Communication

- Communication with Soleux modules occurs over your **local TCP/UDP network**
- No encryption is applied to local network commands (standard for local-network industrial protocols)
- Data never traverses the public internet unless you configure a cloud transport

### 7.3 Third-Party Services

The App declares dependencies on the following third-party services in its codebase, but **none are currently active or receive any data**:

- **Firebase Auth** — declared as a dependency, not initialized
- **Cloud Firestore** — declared as a dependency, not initialized
- **Firebase Cloud Messaging** — declared as a dependency, not initialized
- **MQTT** — transport class exists, not wired to any user interface

When and if these services become active in future releases, you will be notified and asked for explicit consent before any data is transmitted.

---

## 8. Your Rights

Depending on your jurisdiction (e.g., GDPR in the European Union, CCPA in California), you may have the following rights:

| Right | How to Exercise |
|-------|----------------|
| **Access** | All your data is visible within the App's interface. You can also export a complete backup via Settings → Backup |
| **Rectification** | Edit any module, room, scenario, or automation directly in the App |
| **Deletion** | Delete individual items via the App's interface. To delete all data, uninstall the App or clear its data folder |
| **Data Portability** | Use the backup feature to export all data as a JSON file |
| **Withdraw Consent** | Uninstall the App or clear its data at any time |
| **Lodge a Complaint** | Contact your local data protection authority. Reach us first at [support@soleux.com](mailto:support@soleux.com) |

To request deletion of data that may have been transmitted (in future cloud-enabled versions), contact [support@soleux.com](mailto:support@soleux.com).

---

## 9. Third-Party Services & Data Sharing

The App does **not** share your data with any third party. We do not sell, rent, or trade your information.

The following third-party libraries are used within the App but process data only on your device:

| Library | Purpose | Data Access |
|---------|---------|-------------|
| Flutter / Dart SDK | Application framework | Platform-level access (standard for apps) |
| Riverpod | State management | None — in-memory only |
| drift (SQLite) | Local database | All local configuration |
| shared_preferences | Local key-value store | User preferences, session state |
| dio / darft:io Socket | HTTP/TCP networking | Module communication data |
| multicast_dns (mDNS) | Local service discovery | Network packets only |

No third-party analytics, advertising, or social media services are integrated.

---

## 10. Children's Privacy

The App is a professional/industrial device management tool intended for adults responsible for installing and maintaining electrical and automation equipment. It is not directed at children, and we do not knowingly collect data from anyone under the age of 13 (or the applicable age of digital consent in your jurisdiction).

---

## 11. Changes to This Privacy Policy

We may update this Privacy Policy as the App evolves. When changes are made:

- The "Last updated" date at the top of this document will be revised
- For material changes, we may display a notice within the App after updating

We encourage you to review this policy periodically.

---

## 12. Contact

For questions about this Privacy Policy or your data:

- **Email:** [support@soleux.com](mailto:support@soleux.com)
- **Response time:** We aim to respond within 5 business days

---

## 13. Jurisdiction-Specific Disclosures

### 13.1 European Economic Area (GDPR)

- **Legal basis for processing:** Legitimate interest (device operation) and consent (configuration storage)
- **Data Protection Officer (DPO):** Not required — we do not process personal data on a large scale
- **Cross-border transfers:** No personal data is transferred outside your local network or the EEA

### 13.2 California (CCPA/CPRA)

- **Right to opt out:** The App does not sell personal information, so no opt-out is necessary
- **Category of personal information collected:** Identifiers (device serial numbers, MAC addresses, IP addresses), commercial information (device configurations), internet/network activity (local network communications)
- **No sensitive personal information** is collected

### 13.3 United Kingdom (UK GDPR)

The above GDPR disclosures apply equally to users in the United Kingdom.

---

*© 2026 Soleux. All rights reserved.*