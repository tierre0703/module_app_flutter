# CLOUD SERVICE PLAN — Soleux Device Manager

**Status:** Draft for approval
**Last updated:** 2026-11-02
**Owner:** Technical Project Manager / Solution Architect
**Audience:** Mobile, backend, firmware, QA, DevOps, support

**Related documents**

- `plan.md` — overall integration plan (this document refines its cloud section)
- `STATUS.md` — current implementation state
- `doc/description.md` — functional brief (§2.1 remote control, §3.1 accounts/cloud, §3.2 push)
- `doc/PROTOCOLS.md` — TCP, UDP discovery, Socket.IO
- `doc/Soleux_Control_API_Command_Specification_v0.6.md` — Control API, MQTT config, transfers
- `doc/Soleux-Mobile-TCP-Protocol.md` — mobile TCP framing

> Where this document and `plan.md` disagree on cloud specifics, this document wins.

---

## 1. Purpose

Add cloud functionality to a product whose app and modules currently communicate over **LAN TCP** or **remote host port-forwarded TCP**. The cloud must deliver the brief's account, backup, sync, push, and remote-control features on a **self-hosted server**, and must remove the need to expose module ports to the internet.

## 2. Scope

### 2.1 In scope (cloud v1)

| ID | Capability | Brief reference |
|----|------------|-----------------|
| C1 | Mandatory email/password account, session, password recovery | §3.1 |
| C2 | Automatic cloud backup and restore of modules, names, scenarios, settings | §3.1 |
| C3 | Multi-device synchronisation | §3.1 |
| C4 | Remote control outside the LAN | §2.1 |
| C5 | Push notifications: offline/online, output left on, temperature, automation | §3.2 |
| C6 | 30-day event history in the cloud | §2.4 |
| C7 | Admin console for support, fleet ops, provisioning, OTA | internal |
| C8 | OTA firmware distribution | internal / Stage 7 |

### 2.2 Out of scope (v1)

- Customer-facing web control portal (future, separate app; `plan.md §2.4`).
- Multi-location UI (schema-ready only; `plan.md §4.6`).
- Voice assistants, BMS/SCADA, energy metering.
- Fully self-hosted push (not possible: APNs/FCM are vendor services).
- Multi-region cells (architecture-ready; v1 ships one cell).

### 2.3 Assumptions

- Server hardware is available (3 × Lenovo ThinkSystem SR250 V3 class; verify exact SKU).
- The operator can provide a public domain and either a public IP or a tunnel.
- The firmware's MQTT client is available or can be enabled (see §6, decision gate D1).
- The team can operate Linux, Docker, Postgres, and a broker.
- FCM/APNs and an SMTP relay are permitted dependencies.

---

## 3. Current state (as-is)

| Area | Current implementation | Cloud gap |
|------|------------------------|-----------|
| Module control | LAN TCP Control API `:5008`; HTTP `:80/:443`; WS `:8081` (Socket.IO web UI); remote host + port forward for off-site | No device-initiated cloud path |
| Discovery | UDP broadcast / DCP; add by IP or hostname | No cloud device registry |
| Auth | Simulated: any non-empty credentials; `SessionStore` stores a boolean | No real auth, sessions, reset |
| Backup | Local JSON via `BackupService` (`exportBytes()`, versioned format v1.1) | No upload/download |
| Sync | Local `shared_preferences` stores | No multi-device sync |
| Push | Local notifications only; `firebase_messaging` declared but unused | No FCM/APNs |
| MQTT | `MqttTransport` + `FailoverTransport` exist but are not wired | No broker, no provisioning |
| Data model | `connectionType` already accepts `local_network`, `remote`, `cloud` | `cloud` unused |
| Config | `AppConfig` has `mqttHost/port/tls` from `.env.*` | No API base URL, no WS URL |

**Implication:** Phase 1 (accounts + backup + sync) can ship without firmware changes, while remote control still uses the existing TCP path. Remote control without port forwarding is the firmware-dependent phase.

---

## 4. Requirements traceability

| Brief requirement | Cloud service component | App change |
|-------------------|-------------------------|------------|
| Mandatory account | GoTrue (Supabase Auth) + JWT | Replace `SessionStore` |
| Password recovery email | GoTrue + SMTP relay | Forgot-password screen calls API |
| Automatic backup/restore | Postgres + MinIO/Garage + `BackupService` | Upload/download `exportBytes()` |
| Multi-device sync | Postgres + Realtime/delta API, LWW on `updatedAt` | drift outbox + merge |
| Remote control (MQTT) | EMQX + ACLs + per-device credentials | Wire `MqttTransport`, add router |
| Push alerts | Worker + FCM/APNs | `firebase_messaging` + deep links |
| 30-day history | Partitioned `event_logs` | Optional cloud history view |
| Module status | `device_status` latest state + presence | Read from cloud when remote |

---

## 5. Target architecture

```
                        Internet
                           │
            ┌──────────────▼───────────────┐
            │ Traefik / Caddy              │  443 (HTTPS) · 8883 (MQTT/TLS)
            │ api. · mqtt. · admin. · ota. │  Let's Encrypt, rate limits
            └───┬───────────┬───────────┬──┘
                │           │           │
      ┌─────────▼──┐  ┌─────▼──────┐  ┌─▼────────────┐
      │ Supabase   │  │ EMQX       │  │ MinIO/Garage │
      │ GoTrue     │  │ 3-node     │  │ backups, OTA │
      │ PostgREST  │  │ cluster    │  │ signed URLs  │
      │ Realtime   │  └─────▲──────┘  └──────────────┘
      │ Storage    │        │ MQTT/TLS 8883 or WSS 443
      │ Studio     │        │
      └─────┬──────┘   ┌────┴─────┐
            │          │ Devices  │  outbound only, no port forwarding
      ┌─────▼──────┐   └──────────┘
      │ Postgres   │
      │ primary +  │        ┌────────────────────┐
      │ 2 replicas │◄───────┤ worker (NestJS)    │ telemetry, push, OTA
      └────────────┘        └────────────────────┘

      App ── LAN TCP/HTTP/WS ──► module        (fast path, offline-first, unchanged)
      App ── MQTT/TLS ────────► EMQX ──► module (remote path)
      App ── HTTPS ───────────► API (auth, sync, backup, OTA manifest)
```

### 5.1 Design principles

1. **LAN first, cloud fallback.** Local control must work with no internet (`plan.md §2.3`).
2. **Devices never accept inbound internet connections.** All remote traffic is device-initiated MQTT.
3. **Cloud observes; the broker controls.** Commands do not round-trip through the API/worker.
4. **One identity, two audiences.** Users and devices both authenticate to EMQX, with different credential types and ACLs.
5. **Postgres is the source of truth.** Broker auth/authz reads from the API backed by Postgres.
6. **No secrets in the app or in logs.** Device secrets are write-only and hashed at rest.

---

## 6. Transport strategy

### 6.1 Roles

| Transport | Role | Cloud-safe |
|-----------|------|------------|
| LAN TCP `:5008` | Command/control fast path | LAN only |
| LAN HTTP `:80/:443` | Config, reads, backup, firmware upload | LAN only (HTTPS + auth if remote) |
| LAN WS `:8081` | Live status/event stream (Socket.IO) | LAN only |
| MQTT `:8883` / WSS `:443` | Remote control, presence, telemetry | **Yes** (device-initiated) |
| HTTPS `:443` | Auth, sync, backup, OTA manifest | Yes |

WS is the web-UI Socket.IO endpoint today; the Control API spec still marks WS command transport as reserved. Treat WS as a **LAN** transport unless firmware confirms an outbound WSS client.

### 6.2 Routing policy (app)

```
command → LAN WS (if connected) → LAN TCP → LAN HTTP → MQTT → queue
config  → LAN HTTP → (cloud metadata only)
stream  → LAN WS/TCP subscription, else MQTT status subscription
```

Implement as a `TransportRouter` behind the existing `Transport` interface. `FailoverTransport` becomes one policy inside it; `MqttTransport` becomes the remote adapter.

### 6.3 Decision gate D1 — firmware MQTT

**Verify on a real module:** does the firmware implement the `mqtt` configuration section and `test_mqtt` action from the Control API spec, and does it maintain an outbound TLS connection?

| Result | Path |
|--------|------|
| **Yes** | Path A: provision broker credentials; app pushes MQTT config over LAN; module connects outbound. **Recommended.** |
| **No** | Path B: LAN gateway (Pi/industrial PC) with an outbound tunnel (`frp`/`rathole`/WireGuard) to a cloud relay; or firmware update. |

Path B is a bridge, not the end state. It adds one always-on box per site and a new security surface.

### 6.4 Port-forwarding retirement

1. Keep `connectionType = 'remote'` working during migration.
2. Onboard new modules with cloud credentials (`connectionType = 'cloud'`).
3. After a module is cloud-verified, prompt the user to close the forwarded port.
4. Rotate any credentials that were exposed while forwarding.
5. Publish a support note: no inbound ports, no static IP required.

### 6.5 MQTT topic and ACL scheme

```
t/{tenantId}/{locationId}/{moduleId}/status     retained last state, QoS1
t/{tenantId}/{locationId}/{moduleId}/events     QoS1
t/{tenantId}/{locationId}/{moduleId}/control    QoS1
t/{tenantId}/{locationId}/{moduleId}/ota        QoS1
t/{tenantId}/{locationId}/{moduleId}/ota/ack    QoS1
```

| Principal | Publish | Subscribe |
|-----------|---------|-----------|
| App user | `.../control`, `.../ota` | `t/{tenant}/{location}/+/status`, `.../events`, `.../ota/ack` |
| Device | `.../status`, `.../events`, `.../ota/ack` | `.../control`, `.../ota` |
| Worker | `.../ota` | `t/+/+/+/status`, `t/+/+/+/events`, `t/+/+/+/ota/ack` |

- Device username: `dev_{moduleId}`; app username: `usr_{userId}`.
- Retained status on `status`; `clean_start=false` with session expiry for devices.
- ACLs enforced by EMQX HTTP authz against Postgres (single source of truth).

---

## 7. Self-hosted platform

### 7.1 Stack

| Layer | Choice | Notes |
|-------|--------|-------|
| OS | Ubuntu 24.04 LTS | SSH keys only, UFW, unattended-upgrades |
| Orchestration | **Phase 1:** Docker Compose + Coolify/Dokploy. **Phase 2:** k3s + CloudNativePG + EMQX Helm | Do not start with Kubernetes |
| Database | Postgres 16, 1 primary + 2 streaming replicas, PgBouncer | WAL archiving, PITR |
| Auth | Supabase GoTrue | RS256 JWT, refresh tokens, SMTP |
| API | PostgREST + Realtime | RLS on `owner_id` / `location_id` |
| Objects | MinIO distributed, or Garage (3-node friendly) | Buckets: `backups`, `firmware`, `exports`; versioning |
| Broker | EMQX 5.x, 3-node cluster | TLS 8883 + WSS 443/`/mqtt` |
| Worker | NestJS or Fastify (Node) | Telemetry ingest, alerts, push, OTA |
| Ingress | Traefik or Caddy | Let's Encrypt; SANs for api/mqtt/admin/ota |
| Admin | Next.js + Refine + shadcn/ui | Separate deployment (§13) |
| Monitoring | Prometheus + Grafana + Loki + Uptime Kuma | Postgres/EMQX/node exporters |
| Secrets | SOPS/age or Docker secrets | Never in git or images |
| CI/CD | GitHub Actions → GHCR → Coolify/k3s | Migrations via Flyway or Supabase CLI |

### 7.2 Hard dependencies that cannot be self-hosted

| Dependency | Why | Mitigation |
|------------|-----|------------|
| **FCM / APNs** | Apple/Google control push delivery | Free; required for §3.2 |
| **SMTP relay** | Deliverability to Gmail/Outlook | Use Brevo/SES/Postmark; self-hosted Mailu is possible but fragile |
| **DNS / certificates** | Public trust | Public domain + Let's Encrypt; Cloudflare DNS optional |
| **Public IP or tunnel** | Reachability | Public IP in a DC, or Cloudflare Tunnel |

State this in any "fully self-hosted" claim: push and email remain vendor-dependent.

### 7.3 Environments

| Env | Topology | Purpose |
|-----|----------|---------|
| `dev` | Local Docker Compose + local EMQX | Feature work |
| `staging` | 1 node, separate subdomain + broker | Pre-release, TestFlight/Play internal |
| `prod` | 3 nodes, HA topology | Customers |

Separate Supabase/EMQX/FCM projects per environment. Migrations, broker ACLs, and dashboards live in git.

---

## 8. Deployment topology

### 8.1 Phase 1 — simple (start here)

| Node | Services |
|------|----------|
| 1 | Traefik, Supabase stack, Postgres primary, MinIO |
| 2 | EMQX, worker, monitoring |
| 3 | Postgres replica, MinIO replica, offsite backup target, staging |

Characteristics: single point of failure on node 1; acceptable for beta and early production; RTO hours.

### 8.2 Phase 2 — HA

| Node | Services |
|------|----------|
| 1–3 | k3s control plane + workers; CloudNativePG (1 primary, 2 replicas); EMQX 3-node; MinIO/Garage; Supabase services as Deployments; Traefik |

Characteristics: survives one node failure; rolling maintenance; RTO minutes. Requires runbooks and quarterly failover drills.

### 8.3 Network and TLS

- DNS: `api.`, `mqtt.`, `admin.`, `ota.` → server public IP (or tunnel).
- Ports inbound: `80` (ACME redirect), `443` (HTTPS/WSS), `8883` (MQTT/TLS). SSH restricted by IP.
- No inbound access to module ports, Postgres, MinIO, EMQX dashboard.
- If behind NAT/CGNAT: Cloudflare Tunnel for HTTP and a small VPS relay for MQTT, or a single VPS reverse proxy.
- MQTT over WSS on 443 is the fallback for restrictive networks; devices may use TCP 8883.

### 8.4 Hardware baseline (per node)

| Item | Minimum | Recommended |
|------|---------|-------------|
| CPU | 8C/16T Xeon E-2300 class | same or better |
| RAM | 64 GB | 128 GB |
| Storage | 2 × SSD RAID1 | NVMe, separate volume for Postgres/WAL |
| Network | 1 GbE | 10 GbE inter-node |
| Power | Redundant PSU if available | + UPS |
| Management | XClarity / IPMI | remote KVM |

---

## 9. Data model

All tables carry `id`, `created_at`, `updated_at` (UTC). Tenancy: `locations.owner_id`; everything else hangs off `location_id`.

| Table | Key fields |
|-------|------------|
| `locations` | `owner_id`, `name`, `timezone`, `region`, `is_primary` |
| `modules` | `location_id`, `region`, `type`, `name`, `ip`, `mac`, `mqtt_client_id`, `firmware`, `last_seen_at`, `cloud_enabled` |
| `channels` | `module_id`, `idx`, `name`, `icon`, `enabled` |
| `inputs` | `module_id`, `idx`, `mode`, `bound_type`, `bound_id` |
| `rooms` | `location_id`, `name`, `sort` |
| `scenarios` | `location_id`, `room_id`, `name`, `type`, `show_in_home`, `sort` |
| `scenario_actions` | `scenario_id`, `sort`, `action_type`, `channel_id`, `brightness_pct` |
| `device_status` | `module_id` PK, `values` jsonb, `source`, `updated_at` |
| `event_logs` | `location_id`, `module_id`, `type`, `payload` jsonb, `occurred_at` (partitioned by day) |
| `temperature_alerts` | `module_id`, `min_c`, `max_c`, `enabled`, `last_triggered_at` |
| `push_tokens` | `user_id`, `device_id`, `platform`, `token`, `updated_at` |
| `device_credentials` | `module_id` PK, `username`, `secret_hash`, `rotated_at`, `revoked_at`, `last_used_at` |
| `firmware_releases` | `device_type`, `version`, `channel`, `object_key`, `sha256`, `size_bytes`, `notes` |
| `firmware_rollouts` | `release_id`, `scope` jsonb, `percent`, `state`, `scheduled_at` |
| `firmware_rollout_targets` | `rollout_id`, `module_id`, `state`, `attempts`, `last_error` |
| `provisioning_codes` | `code_hash` PK, `module_id`, `cell_id`, `expires_at`, `used_at` |
| `admin_users` | `user_id`, `role`, `region_scope` |
| `admin_audit_log` | `actor_id`, `action`, `target_type`, `target_id`, `before`, `after`, `ip`, `request_id` |
| `support_notes` | `subject_type`, `subject_id`, `author_id`, `body` |
| `cells` | `id`, `region`, `api_url`, `mqtt_url`, `status` |

### 9.1 Retention and partitioning

- `event_logs`: partition by day; drop partitions older than 30 days via `pg_cron` or the worker. Never `DELETE` row-by-row.
- `device_status`: upsert latest state; optionally keep a 7-day history table if needed.
- `admin_audit_log`: append-only; retain 12–24 months; revoke `UPDATE`/`DELETE` from the app role.
- Backups: object storage lifecycle to cold storage after 30 days.

### 9.2 RLS / authorization

- App users: `owner_id = auth.uid()` for locations; all child rows via `location_id` join.
- Devices: no direct DB access; only MQTT credentials.
- Worker/admin: service role, server-side only.
- `region_scope` filters admin access per cell when multi-cell is enabled.

---

## 10. Device provisioning and onboarding

```
Admin console                     App (LAN)                    Module
   │ create claim code + QR            │                            │
   ├──────────────────────────────────►│ scan                       │
   │                                   ├─ POST /provision/claim     │
   │                                   │  {code, moduleFingerprint}  │
   │                                   │◄ creds + topic + cell      │
   │                                   ├── Control API (LAN) ──────►│ set MQTT config
   │                                   │                            ├─ connect EMQX
   │◄──── module shows cloud-online ───┴────────────────────────────┘
```

- Claim code: 10 characters, 15-minute TTL, single use, hashed at rest.
- QR payload contains no secret: `{v:1, code, cell}`.
- The app writes MQTT config to the module over the existing LAN Control API (`mqtt` section) or the user enters it in the module web UI.
- Re-provisioning rotates the credential and revokes the old one; the old session is kicked.

---

## 11. Security model

### 11.1 Identities

| Principal | Credential | Scope |
|-----------|------------|-------|
| User | Supabase JWT (short-lived + refresh) | Own locations |
| Device | Per-device username + secret (argon2 hash), or client cert | Its own module topics |
| Worker | Service account / internal mTLS | All locations (server-side) |
| Admin | Supabase JWT + role claim + TOTP | Per role/region |

### 11.2 Controls

- TLS 1.2+ everywhere; HSTS on HTTP; MQTT TLS required for remote.
- Broker rate limits, max packet size, keepalive 30–60 s, reconnect backoff on devices.
- Per-device ACL; no shared device keys; rotate on compromise.
- Postgres roles: `app`, `worker`, `readonly`; no superuser in app config.
- Backups encrypted at rest, offsite, restore drilled monthly.
- Audit log append-only; command log for state-changing actions.
- Secrets in SOPS/Docker secrets; never in the Flutter app or logs.

### 11.3 Threat table

| Threat | Mitigation |
|--------|------------|
| Internet-exposed module port | Retire port forwarding; device-initiated MQTT only |
| Stolen device secret | Rotate via console; kick session; per-device ACL limits blast radius |
| Cross-tenant data access | RLS + ACL derived from JWT/username; tests per role |
| JWT replay | Short TTL, refresh rotation, TLS, revocation |
| Malicious firmware upload | SHA-256 + signature check on device; upload restricted to admins |
| Admin account takeover | MFA, Cloudflare Access/VPN, step-up auth, audit |
| Broker DDoS / connection flood | Rate limits, connection caps, fail2ban, provider DDoS protection |
| Backup exfiltration | Private buckets, signed URLs, least-privilege keys, encryption |

---

## 12. Application changes

| Change | File / area | Notes |
|--------|-------------|-------|
| Real auth | `lib/services/session_store.dart` | Supabase/GoTrue client; persist tokens in `flutter_secure_storage` |
| Cloud config | `lib/core/config/app_config.dart`, `.env.*` | Add `API_BASE_URL`, `MQTT_WS_URL`, `CLOUD_ENABLED` |
| Backup upload/download | `lib/services/backup_service.dart` | Reuse `exportBytes()`; add signed-URL upload/restore |
| Sync engine | new `lib/services/sync/` | drift outbox, LWW, delta pull, conflict UI |
| Transport router | `lib/core/transport/` | Priority policy; wire `MqttTransport` |
| MQTT auth | `lib/core/transport/mqtt_transport.dart` | JWT or device credentials; WSS support |
| Push | `pubspec.yaml` → `firebase_messaging` | Token registration, deep links, foreground/background |
| Connection type | `lib/models/models.dart`, `lib/screens/add_module_screen.dart` | Use existing `'cloud'` value |
| Provisioning | new screen/service | Claim code, push MQTT config over LAN |

---

## 13. Admin console

Separate Next.js deployment at `admin.`; internal only. Details:

| Aspect | Decision |
|--------|----------|
| Stack | Next.js App Router + Refine + shadcn/ui + TanStack Table |
| Auth | Supabase JWT + `admin_role` claim + TOTP; SSO optional |
| Data access | Server-side service role only; never in the browser |
| Network | Cloudflare Access or VPN/IP allowlist in front |
| Roles | `superadmin`, `admin`, `support`, `auditor` |
| Audit | Every mutation writes `admin_audit_log` |

### 13.1 Screens

Dashboard · Users · Locations · Modules · Provisioning · Firmware · Rollouts · Events · Audit · Cells · Settings.

### 13.2 Admin API (BFF)

```
GET  /api/admin/overview
GET  /api/admin/users?q=&page=
GET  /api/admin/users/:id
POST /api/admin/users/:id/reset-password
POST /api/admin/users/:id/revoke-sessions
GET  /api/admin/modules?type=&status=&firmware=&cell=
GET  /api/admin/modules/:id
POST /api/admin/modules/:id/reconnect
POST /api/admin/modules/:id/rotate-credentials
POST /api/admin/modules/:id/disable-cloud
GET  /api/admin/releases
POST /api/admin/releases
GET  /api/admin/rollouts
POST /api/admin/rollouts
POST /api/admin/rollouts/:id/(pause|resume|rollback)
GET  /api/admin/events?module=&type=&from=&to=
GET  /api/admin/audit?actor=&action=&from=&to=
POST /api/admin/provisioning/codes
GET  /api/admin/cells
```

### 13.3 Broker integration

- EMQX REST v5 for client inspection and session kick.
- EMQX HTTP auth/authz → API → Postgres, so credential rotation is immediate.
- Connection counts and session IDs surfaced on module detail.

---

## 14. OTA

### 14.1 Flow

1. Admin uploads firmware → `firmware/{device_type}/{version}/`; server computes SHA-256.
2. Create release (draft), then rollout with scope, percentage, schedule.
3. Worker publishes `ota` command with a 15-minute signed URL + hash + version.
4. Device downloads over HTTPS, verifies hash/signature, applies, publishes progress.
5. Worker updates `firmware_rollout_targets`; retries with backoff.
6. Rollback publishes the previous release and marks the rollout `rolled_back`.

### 14.2 Guardrails

- Ramp 5% → 25% → 100%; halt on >5% failure rate or 10 consecutive failures.
- Retry cap 3; maintenance window per location.
- Signed URLs only; no public bucket.

### 14.3 Caveat

Cloud OTA requires firmware to **pull a URL over HTTPS**. If the current firmware only accepts a LAN upload via the Control API, the console can only notify/queue until a firmware update adds pull support.

---

## 15. Observability and operations

### 15.1 SLOs

| Metric | Target |
|--------|--------|
| Remote command success | > 99.5% |
| Remote command p95 latency | < 1 s |
| API availability | 99.5% (Phase 1) / 99.9% (Phase 2) |
| Push delivery (accepted) | > 99% |
| Backup RPO / RTO | 5 min / 1 h |

### 15.2 Dashboards and alerts

- Node, Postgres, EMQX, MinIO, Traefik exporters → Prometheus/Grafana.
- Alerts: broker connection drop, DB replication lag, disk > 80%, certificate expiry < 14 days, 5xx rate, backup failure, OTA failure spike.
- Uptime Kuma for external probes (`/health`, MQTT connect test).
- Sentry for app, admin, worker.

### 15.3 Runbooks (to write)

1. Postgres failover / restore.
2. EMQX node replacement.
3. Certificate renewal failure.
4. Device mass-offline triage.
5. Credential compromise / rotation.
6. OTA rollback.
7. Region/cell onboarding (Phase 2).

---

## 16. Capacity and sizing

Assumptions: telemetry every 10 s, ~500 B payload, latest-state persisted every 30 s, events on change, 30-day retention, 1–2 app users per location.

| Topology | Comfortable modules | Tuned | Stretch |
|----------|---------------------|-------|---------|
| 1 node | 1,500–2,500 | ~5,000 | 8,000–10,000 |
| 3 nodes (self-hosted, Supabase + EMQX + MinIO) | 4,000–6,000 | 10,000–15,000 | 25,000–50,000 |

Bottlenecks in order: Postgres write rate, event-log growth, broker fan-out, inter-node network, memory. Levers: raise telemetry interval, batch upserts, partition event logs, store events not heartbeats, move OTA/backups to object storage, add a 4th node for Postgres.

Validate with `emqtt-bench`, `pgbench`, and a 24-hour soak before committing to a number.

---

## 17. Delivery plan

| Phase | Deliverable | Effort | Depends on |
|-------|-------------|--------|------------|
| **0 — Foundations** | DNS/TLS, 3 nodes hardened, Compose/Coolify, Postgres, MinIO, CI/CD, env config | 3–5 days | hardware, domain |
| **1 — Identity + backup/sync** | Real auth, reset, sessions, backup upload/download, delta sync | 2–3 weeks | Phase 0 |
| **2 — Remote control** | EMQX cluster, provisioning, app MQTT + router, port-forward retirement | 2–3 weeks | D1 (firmware MQTT) |
| **3 — Telemetry + push** | Ingest, alert rules, FCM/APNs, deep links | 1–2 weeks | Phase 2 |
| **4 — OTA** | Releases, rollouts, progress, rollback | 1–2 weeks | D2 (firmware pull) |
| **5 — Admin console** | Read-only → safe writes → provisioning → OTA pages | 2–4 weeks | Phase 1 |
| **6 — HA + hardening** | k3s/CloudNativePG/EMQX cluster, monitoring, DR drills, pen-test | 2–3 weeks | Phases 1–5 |

**Total:** ~12–18 weeks with 1–2 engineers; Phases 1 and 5 can run partly in parallel.

### 17.1 Definition of done (per phase)

- Feature works on real hardware on iOS + Android.
- Automated tests for the new code paths (unit + integration where applicable).
- No secrets in logs; audit entries for privileged actions.
- Runbook updated; dashboard panels exist.
- `STATUS.md` updated.

---

## 18. Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Firmware has no working MQTT client | Medium | High | Verify D1 first; fall back to gateway/relay or schedule firmware work |
| Firmware cannot pull OTA URL | Medium | Medium | OTA limited to notify + LAN upload until firmware update |
| No public IP / behind CGNAT | Medium | High | Cloudflare Tunnel + VPS relay, or colocate |
| Self-host ops burden | High | Medium | Phase 1 Compose first; managed fallback option; on-call plan |
| Supabase self-host HA complexity | Medium | High | Start non-HA; k3s only in Phase 6; accept community Helm risk |
| Port-forwarding users resist migration | Medium | Medium | Dual-run, in-app prompts, support notes, credential rotation |
| Push/email vendor dependency | High | Low | Explicitly documented; budget and accounts early |
| Capacity underestimate | Medium | Medium | Load test before launch; conservative 4–6k per 3-node cell |
| Single-region latency worldwide | Medium | Medium | Cell architecture ready; add regions on triggers |
| Data residency in some markets | Low (v1) | High | Regional cells; legal review before entering CN/RU |
| Certificate/TLS expiry outage | Low | High | cert-manager + expiry alerts + auto-renew test |
| Device clock skew breaks TLS | Medium | Medium | NTP on devices; tolerate ±5 min; document |

---

## 19. Open questions / decision gates

| # | Question | Blocks | Owner |
|---|----------|--------|-------|
| D1 | Does the firmware's MQTT client work today (`test_mqtt`)? | Phase 2 path A/B | Firmware |
| D2 | Can firmware pull an OTA URL over HTTPS? | Phase 4 | Firmware |
| D3 | Public IP + domain, or NAT/tunnel? | Phase 0 | Infra |
| D4 | Is self-hosting contractual or a preference? | stack choice, Phase 6 | Product |
| D5 | Who is on call for DB/broker failures? | Phase 6 | Ops |
| D6 | Target countries at launch? (CN/RU change deployment) | cell plan | Product |
| D7 | Expected fleet size, telemetry interval, payload size? | capacity | Product |
| D8 | SMTP provider and sender domain? | Phase 1 | Ops |
| D9 | Firebase project + APNs key available? | Phase 3 | Mobile |
| D10 | Admin staff count and role assignment? | Phase 5 | Support |

---

## 20. Appendix

### A. Environment variables (app)

```dotenv
APP_ENV=prod
API_BASE_URL=https://api.example.com
MQTT_HOST=mqtt.example.com
MQTT_PORT=8883
MQTT_TLS=true
MQTT_WS_URL=wss://mqtt.example.com/mqtt
CLOUD_ENABLED=true
LAN_COMMAND_TIMEOUT_MS=300
DISCOVERY_PORT=5353
EVENT_LOG_RETENTION_DAYS=30
```

### B. Server-side environment (per service)

```
SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY (server only)
POSTGRES_* (app/worker/readonly roles)
EMQX_API_URL, EMQX_API_KEY, EMQX_API_SECRET
EMQX_AUTH_SHARED_SECRET (HTTP auth/authz)
MINIO_ENDPOINT, MINIO_ACCESS_KEY, MINIO_SECRET_KEY, MINIO_BUCKET_*
SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_FROM
FCM_SERVICE_ACCOUNT_JSON, APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY
SENTRY_DSN, CELL_ID
```

### C. Repo touchpoints

| Concern | Path |
|---------|------|
| Transport interfaces | `lib/core/transport/transport.dart`, `lan_transport.dart`, `mqtt_transport.dart`, `failover_transport.dart` |
| Command service | `lib/services/module_status/module_command_service.dart` |
| HTTP control | `lib/services/module_status/soleux_http_service.dart` |
| Config | `lib/core/config/app_config.dart`, `.env.dev/.staging/.prod` |
| Auth/session | `lib/services/session_store.dart`, `lib/screens/account_screen.dart` |
| Backup | `lib/services/backup_service.dart` |
| Stores | `lib/services/*_store.dart` |
| Model | `lib/models/models.dart` |
| Add module | `lib/screens/add_module_screen.dart` |
| Push | `pubspec.yaml` (`firebase_messaging`), `lib/services/notification_service.dart` |

### D. Glossary

- **Cell** — one self-contained regional deployment: Supabase + EMQX + object storage + worker.
- **Control API** — transport-neutral JSON command model on TCP `:5008`, HTTP/HTTPS.
- **LWW** — last-write-wins conflict resolution using `updated_at`.
- **RPO/RTO** — recovery point/time objective.
- **WSS** — MQTT or WebSocket over TLS on 443.

---

*End of plan. Review D1–D10 before Phase 0 kickoff; update this document as decisions are made.*
