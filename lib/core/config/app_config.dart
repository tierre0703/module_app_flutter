enum AppEnv { dev, staging, prod }

class AppConfig {
  final AppEnv env;
  final String mqttHost;
  final int mqttPort;
  final bool mqttUseTls;
  final int lanCommandTimeoutMs;
  final int discoveryPort;
  final int eventLogRetentionDays;

  /// Code-level TLS switch for the Control API command channel on port 5008
  /// (doc/Soleux_Mobile_Control_API_TLS_Integration.md §"What the app needs").
  ///
  ///   - `null` (all environments): each module's own discovery-advertised
  ///     `API_TLS` flag decides - an enrolled Hub with `API_TLS:1` is dialled
  ///     with TLS, the plaintext-migration `API_TLS:0`/absent
  ///     families stay plaintext;
  ///   - `true` / `false`: forces TLS on / off for every module's 5008 port
  ///     regardless of the advertised flag (a developer escape hatch, e.g.
  ///     to bisect a broken handshake against a plaintext device family that
  ///     cannot speak TLS yet).
  ///
  /// This is deliberately a build-time constant, not a user preference:
  /// certificate trust is a deployment decision, not a UI toggle.
  final bool? apiTlsEnabled;

  /// Asset that ships the independently provisioned Soleux root CA
  /// (`Root CA (.pem)` from the CA portal, after its SHA-256 fingerprint was
  /// verified through a separate trusted channel - doc §"What the app
  /// needs"). The file becomes the single trust anchor for Control API TLS
  /// connections; never fetch a root CA from the discovered device.
  ///
  /// The default points at the placeholder bundled with the app; replace the
  /// file's contents with the real root before connecting to a TLS Hub.
  /// A misconfigured asset fails the TLS handshake closed with a clear
  /// diagnostic (never a fallback to plaintext or blind acceptance).
  final String? soleuxRootCaAsset;

  /// Code-level switch for TLS **hostname verification** on the Control API
  /// command channel (doc/Soleux_Mobile_Control_API_TLS_Integration.md
  /// §"Recommended transport" requires the DNS SAN to match the saved device
  /// ID; this switch relaxes that).
  ///
  /// The app dials 5008 by IP and the Hub certificate carries a DNS SAN but
  /// no IP SAN, so the platform hostname check always fails and the app-side
  /// verdict re-judges the hostname-mismatched leaf. With this switch
  /// enabled, the verdict additionally requires the certificate's DNS SAN to
  /// equal the module's saved device ID (`<ModelNumber>-<SerialNumber>`,
  /// discovery `DEVICE_ID`). With it disabled (default), the saved device ID
  /// is not required: the certificate is accepted as long as it chains to
  /// the installed Soleux root CA (issuer match) and its validity window
  /// holds - chain validation is never disabled.
  ///
  /// This is deliberately a build-time constant, not a user preference:
  /// certificate trust policy is a deployment decision, not a UI toggle.
  final bool tlsVerifyHostname;

  const AppConfig({
    required this.env,
    required this.mqttHost,
    required this.mqttPort,
    required this.mqttUseTls,
    required this.lanCommandTimeoutMs,
    required this.discoveryPort,
    required this.eventLogRetentionDays,
    this.apiTlsEnabled,
    this.tlsVerifyHostname = false,
    this.soleuxRootCaAsset = 'assets/certs/soleux_root_ca.pem',
  });

  static AppConfig fromEnv(AppEnv env) {
    return switch (env) {
      AppEnv.dev => const AppConfig(
          env: AppEnv.dev,
          mqttHost: 'broker.local',
          mqttPort: 8883,
          mqttUseTls: true,
          lanCommandTimeoutMs: 300,
          discoveryPort: 5353,
          eventLogRetentionDays: 30,
        ),
      AppEnv.staging => const AppConfig(
          env: AppEnv.staging,
          mqttHost: 'staging-broker.example.com',
          mqttPort: 8883,
          mqttUseTls: true,
          lanCommandTimeoutMs: 300,
          discoveryPort: 5353,
          eventLogRetentionDays: 30,
        ),
      AppEnv.prod => const AppConfig(
          env: AppEnv.prod,
          mqttHost: 'broker.example.com',
          mqttPort: 8883,
          mqttUseTls: true,
          lanCommandTimeoutMs: 300,
          discoveryPort: 5353,
          eventLogRetentionDays: 30,
        ),
    };
  }
}
