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

Device certificates are issued by an **issuing intermediate**, not directly by
the root. Two ways to make such leaves connect:

1. **Automatic (default)** - with hostname verification disabled
   (`AppConfig.tlsVerifyHostname: false`), a 5008 dial that fails with a
   *hostname-only* verification error is retried accepting the leaf. The TLS
   stack only reports a hostname mismatch **after** the chain validated to
   the installed root, so chain and validity stay enforced; unknown-CA,
   expired or otherwise bad chains still fail closed. No extra certificate
   file is needed.
2. **Explicit intermediate** - append the intermediate from the CA portal's
   **CA chain (.pem)** to `soleux_root_ca.pem` and rebuild. The loader
   installes **only the root** as the trust anchor; the intermediate is used
   purely as a leaf-issuer match (`SoleuxTlsOptions.install`), which keeps
   the strict verdict path (and stays compatible with re-enabling hostname
   verification later).

Rules that stay in force:

- the trust anchor is the self-signed root - **never** the intermediate;
- never fetch a root CA from the discovered device;
- a placeholder/misprovisioned asset fails every TLS 5008 connection closed
  with `SoleuxTLS: root CA asset ... contains no CERTIFICATE block`.

Note: assets are bundled at build time, so swapping the certificate requires a
rebuild/re-bundle for release builds.
