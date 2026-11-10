# Soleux root CA provisioning

`soleux_root_ca.pem` is the single trust anchor for the Control API command
channel on port 5008 when a module advertises `API_TLS:1`
(doc/Soleux_Mobile_Control_API_TLS_Integration.md).

Currently installed: the **Soleux Development root** (copied from
`creds/Soleux-Root-CA.pem`, which is identical to `creds/Soleux-Root-CA.crt`).
Verify it out of band before relying on it:

- subject: `O=Soleux Development CA, CN=Soleux Development CA Root CA`
  (self-signed),
- validity: 2026-11-09 to 2076-10-27,
- SHA-256 fingerprint:
  `B8:B1:98:04:07:9D:32:E3:85:D2:2F:E8:EA:31:F3:26:00:DA:99:AA:A2:82:F4:E7:AD:33:87:E9:39:F8:74:8A`
  (through a separate trusted channel, per doc §"What the app needs").

Rules that stay in force:

- install only a root (self-signed) certificate as the anchor - **not** the
  "CA chain (.pem)" download, which carries the issuing intermediate in front
  of the root. The asset loader tolerates a chain file: it takes the
  self-signed certificate as the anchor and treats the intermediate only as a
  leaf-issuer candidate;
- never fetch a root CA from the discovered device;
- a placeholder/misprovisioned asset fails every TLS 5008 connection closed
  with `SoleuxTLS: root CA asset ... contains no CERTIFICATE block`.

Note: assets are bundled at build time, so swapping the certificate requires a
rebuild/re-bundle for release builds.
