# Soleux Device Manager — Beta Test Notes v1.0.26

**Build:** 1.0.26  
**Previous:** 1.0.25  
**Platform:** iOS (TestFlight), Android (Internal testing)  
**Target audience:** Beta testers / internal QA

---

## What's New in v1.0.26

### 1. Modbus Hub — Real-Time Event Handling

Async `output_state_changed` broadcasts from the Modbus HUB now correctly update **both** regular outputs and Modbus power outputs in real time.

**Before:** When a Modbus output was toggled by a schedule, automation, or another client, the app only showed the change after the next full `get_dashboard` poll (up to several seconds delay).

**After:** The `output_type` field in the Hub event payload is inspected:

| `output_type` value | Target |
|---------------------|--------|
| `"modbus_power"` | Modbus power output list |
| `"local"` or absent | Normal output list |

**To verify:**
1. Open a Modbus HUB control screen
2. Trigger a Modbus output change from another client (e.g., web UI, schedule, or another phone)
3. ✅ The output state updates immediately on the dashboard — no refresh needed

---

### 2. Privacy Policy

Added privacy policy documents to the repository:
- `PRIVACY.md` (English)
- `PRIVACY.ro.md` (Romanian)

Covers data collection, storage, network usage, and your rights — applicable to the App Store submission process.

---

## Known Issues

| ID | Description | Status |
|----|-------------|--------|
| — | No new known issues in this release | — |

---

## How to Test

1. **Modbus Hub event relay** — Open a Hub, watch outputs change from:
   - Another app/client sending `set_modbus_output`
   - A schedule or automation on the Hub itself
   - Physical input on the Hub

2. **General regression** — Ensure no other Hub functionality is broken:
   - Normal output ON/OFF and Pulse
   - Modbus output ON/OFF and Restart
   - Dashboard refresh (pull-to-refresh / refresh button)
   - System status display (temps, CPU, memory)

---

## Feedback

Please report any issues to **support@soleux.com** or file directly in the repository. Include:
- Build version (1.0.26)
- Platform (iOS / Android)
- Steps to reproduce
- Screenshots or logs if helpful

---

*Test cycle ends: TBD — please submit feedback within 5 business days.*