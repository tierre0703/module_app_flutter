import '../../../core/drivers/module_driver.dart';
import '../../../core/transport/transport.dart';
import '../../../data/models/channel.dart';
import '../../../data/models/module.dart';
import 'ac_dimmer_driver.dart';
import 'blind_driver.dart';
import 'dc_dimmer_driver.dart';
import 'relay_driver.dart';
import 'temperature_driver.dart';

/// Builds the correct [ModuleDriver] implementation for a [ModuleType].
class DriverFactory {
  const DriverFactory();

  ModuleDriver create(
      Module module, Transport transport, List<Channel> channels) {
    return switch (module.type) {
      ModuleType.relay =>
        RelayDriver(module: module, transport: transport, channels: channels),
      ModuleType.blind =>
        BlindDriver(module: module, transport: transport, channels: channels),
      ModuleType.dcDimmer => DcDimmerDriver(
          module: module, transport: transport, channels: channels),
      ModuleType.acDimmer => AcDimmerDriver(
          module: module, transport: transport, channels: channels),
      ModuleType.temperature => TemperatureDriver(
          module: module, transport: transport, channels: channels),
      ModuleType.hub => RelayDriver(
          module: module, transport: transport, channels: channels),
    };
  }
}
