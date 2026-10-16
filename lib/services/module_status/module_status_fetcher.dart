// lib/services/module_status/module_status_fetcher.dart
//
// Expandable contract for turning raw PDU responses into live module state.
//
// Each [ModuleType] gets its own fetcher so the transport + status service stay
// module-agnostic. Only the *standard relay* fetcher exists today (see
// relay_module_status_fetcher.dart, driven by PROTOCOLS.md §1); dimmer /
// temperature / blind fetchers can be added later by implementing this
// interface and registering it - no changes to the service or transport.
import '../../models/models.dart';
import 'pdu_protocol.dart';
import 'relay_module_status_fetcher.dart';

/// Fetches + applies the live status for one module type.
abstract class ModuleStatusFetcher {
  /// The module type this fetcher is responsible for.
  ModuleType get type;

  /// `AT+...` commands issued sequentially to capture the full status dump.
  List<String> get fetchCommands;

  /// Persists the parsed responses into [module] (status, temperature, per
  /// channel on/off) once every command returned `OK`.
  void apply(DeviceModule module, List<PduResponse> responses);
}

/// Registry keyed by [ModuleType]. Start with the relay fetcher registered and
/// extend by calling [register] for each new module type added later.
class ModuleStatusFetcherRegistry {
  final Map<ModuleType, ModuleStatusFetcher> _fetchers = {};

  ModuleStatusFetcherRegistry() {
    _registerBuiltIns();
  }

  void _registerBuiltIns() {
    register(const RelayModuleStatusFetcher());
    register(const DimmerModuleStatusFetcher(ModuleType.dimmerDc));
    register(const DimmerModuleStatusFetcher(ModuleType.dimmerAc));
    register(const HubModuleStatusFetcher());
  }

  /// Registers (or replaces) the fetcher for its module type.
  void register(ModuleStatusFetcher fetcher) =>
      _fetchers[fetcher.type] = fetcher;

  /// Returns the fetcher for [type], or null if not yet implemented.
  ModuleStatusFetcher? forType(ModuleType type) => _fetchers[type];

  /// The set of module types the registry knows how to fetch today.
  Set<ModuleType> get supportedTypes => _fetchers.keys.toSet();
}

/// Fetcher for hub modules (Modbus Hub mini, Hub v1.0). The Hub uses the
/// JSON protocol 1 on TCP port 5008. Its live output state is parsed during
/// the `_probeSoleuxJson` probe, but the fetcher is registered so the
/// legacy-fetcher gate in `_refreshOne` does not block hub modules.
class HubModuleStatusFetcher implements ModuleStatusFetcher {
  const HubModuleStatusFetcher();

  @override
  ModuleType get type => ModuleType.hub;

  @override
  List<String> get fetchCommands => const [];

  @override
  void apply(DeviceModule module, List<PduResponse> responses) {
    // State is applied by the Control API JSON path; connectivity comes from
    // the heartbeat monitor.
  }
}

/// Fetcher for dimmer modules (DC PWM / AC phase-cut). Real dimmers speak the
/// Control API: their live output state is parsed by [SoleuxJsonFetcher] during
/// fetcher exists so the legacy-fetcher gate in `_refreshOne` does not block
/// dimmer modules from reaching that JSON probe. There is no legacy AT dimmer
/// dump, so the AT path carries no commands and just reports reachability.
class DimmerModuleStatusFetcher implements ModuleStatusFetcher {
  const DimmerModuleStatusFetcher(this.type);

  @override
  final ModuleType type;

  @override
  List<String> get fetchCommands => const [];

  @override
  void apply(DeviceModule module, List<PduResponse> responses) {
    // State is applied by the Control API path; connectivity comes from the
    // heartbeat monitor.
  }
}
