// lib/services/module_status/relay_module_status_fetcher.dart
//
// DEPRECATED — legacy AT status fetcher for the standard relay / PDU module.
// Current modules are refreshed through the Control API (JSON) on port 5008;
// this fetcher is no longer exercised by a production path and is retained
// solely so the legacy `AT+` stack can be deleted in one follow-up step.
//
// Implemented against the TCP ASCII protocol in doc/PROTOCOLS.md §1
// (commands #2, #3, #6, #14).
//
// The base class reconciles temperature, output/input counts, output/input
// states and module identity; this subclass only states which commands expose
// that topology for a standard relay.
import '../../models/models.dart';
import 'base_module_status_fetcher.dart';
import 'pdu_protocol.dart';

@Deprecated('The legacy AT protocol is no longer supported; the Control API '
    '(TCP 5008) is the only protocol. Retained for the staged removal.')
class RelayModuleStatusFetcher extends BaseModuleStatusFetcher {
  const RelayModuleStatusFetcher();

  @override
  ModuleType get type => ModuleType.relay;

  @override
  List<String> get fetchCommands => const [
        // ignore: deprecated_member_use_from_same_package
        PduAtCommands.version, // AT+VER      identity + RELAY_COUNT
        // ignore: deprecated_member_use_from_same_package
        PduAtCommands.temperature, // AT+TEMP      SYSTEMP
        // ignore: deprecated_member_use_from_same_package
        PduAtCommands.allOutputStates, // AT+OUTSTAT  OUT:<pin>:<ON|OFF>
        // ignore: deprecated_member_use_from_same_package
        PduAtCommands.allInputStates, // AT+INSTAT   IN:<pin>:<ON|OFF>
        // ignore: deprecated_member_use_from_same_package
        PduAtCommands.channelNames, // AT+CHNAMES  CHNAME_<IN|OUT>:<pin>:<name>
      ];
}
