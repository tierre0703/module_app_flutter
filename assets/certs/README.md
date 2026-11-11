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
the root. When a 5008 TLS connection is rejected with
`issuer ... is not the installed Soleux CA chain`, append the intermediate to
this file:

1. Download **CA chain (.pem)** from the CA portal's "Certificates" page (it
   contains the issuing intermediate followed by the root).
2. Copy **both** certificates (or at least the issuing intermediate) into
   `assets/certs/soleux_root_ca.pem`, keeping the root in the file.
3. Rebuild. The loader installes **only the root** as the trust anchor; the
   intermediate is used purely as a leaf-issuer match
   (`SoleuxTlsOptions.install`).

Rules that stay in force:

- the trust anchor is the self-signed root - **never** the intermediate;
- never fetch a root CA from the discovered device;
- a placeholder/misprovisioned asset fails every TLS 5008 connection closed
  with `SoleuxTLS: root CA asset ... contains no CERTIFICATE block`.

Note: assets are bundled at build time, so swapping the certificate requires a
rebuild/re-bundle for release builds.
