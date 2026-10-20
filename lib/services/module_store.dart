// lib/services/module_store.dart
//
// App-wide, single source of truth for the DeviceModule list. Any screen that
// needs the fleet (Configuration list, Home temperature/offline alerts, module
// detail screens) reads from this store and rebuilds via [ListenableBuilder] /
// addListener when it changes.
//
// The module_status service holds a reference to this store and writes into it
// after each status pass, so live online/offline + temperature + output states
// flow to every screen automatically. All reads/writes go through here so the
// in-memory list and the persisted copy (ModuleRepository) stay in sync.
import 'package:flutter/foundation.dart';

import '../data/module_repository.dart';
import '../models/models.dart';

class ModuleStore extends ChangeNotifier {
  ModuleStore._();

  /// App-wide shared instance used by the launch path and every screen.
  static ModuleStore shared = ModuleStore._();

  /// Creates an isolated store for tests (backed by the same persistence).
  @visibleForTesting
  static ModuleStore forTesting() => ModuleStore._();

  ModuleRepository? _repo;
  List<DeviceModule> _modules = [];
  bool _loaded = false;

  /// The current fleet (unmodifiable view).
  List<DeviceModule> get modules => List.unmodifiable(_modules);

  /// True once [init] has completed (successfully or not).
  bool get loaded => _loaded;

  bool get isEmpty => _modules.isEmpty;

  /// The module with [id], or null.
  DeviceModule? byId(String id) {
    for (final m in _modules) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// Loads the persisted fleet exactly once. Safe to call repeatedly.
  Future<void> init() async {
    if (_loaded) return;
    try {
      _repo = await ModuleRepository.load();
      _modules = _repo!.fetch();
    } catch (e, st) {
      debugPrint('ModuleStore: loading fleet failed: $e\n$st');
      _modules = [];
    }
    _loaded = true;
    notifyListeners();
  }

  /// Persists the current list and broadcasts a change.
  Future<void> commit() async {
    await _repo?.saveAll(_modules);
    notifyListeners();
  }

  /// Replaces the in-memory fleet (used by the status service after a pass).
  Future<void> replaceAll(List<DeviceModule> list) async {
    await init();
    _modules = List.of(list);
    await commit();
  }

  /// Inserts [module] or, when an id already exists, merges it into the stored
  /// copy so user-defined channel names/icons survive a re-add (e.g. a device
  /// picked up again by discovery).
  Future<void> upsert(DeviceModule module) async {
    await init();
    final index = _modules.indexWhere((m) => m.id == module.id);
    if (index < 0) {
      _modules.add(module);
    } else {
      _modules[index] = _merge(_modules[index], module);
    }
    await commit();
  }

  /// Removes the module with [id].
  Future<void> remove(String id) async {
    await init();
    _modules.removeWhere((m) => m.id == id);
    await commit();
  }

  /// Applies [mutator] to the in-memory module with [id] then persists.
  Future<DeviceModule?> update(
      String id, void Function(DeviceModule) mutator) async {
    final module = byId(id);
    if (module == null) return null;
    mutator(module);
    await commit();
    return module;
  }

  /// Merges a freshly (re-)discovered [fresh] module into the stored
  /// [existing] copy. Module-level identity follows the fresh copy; channel
  /// and input entries that already exist keep their user-defined
  /// name/icon/label, while entries introduced by the fresh copy are appended
  /// unchanged - so a re-add never resets names the user customized.
  DeviceModule _merge(DeviceModule existing, DeviceModule fresh) {
    existing.name = fresh.name;
    existing.ipAddress = fresh.ipAddress;
    existing.tcpPort = fresh.tcpPort;
    existing.roomName = fresh.roomName;
    // Connectivity status is owned by the heartbeat monitor, so it is not
    // copied from the freshly discovered `fresh` copy here.

    final priorChannels = List.of(existing.channels);
    final priorInputs = List.of(existing.inputs);

    existing.channels
      ..clear()
      ..addAll([
        for (var i = 0; i < fresh.channels.length; i++)
          i < priorChannels.length
              ? ChannelOutput(
                  id: priorChannels[i].id,
                  name: priorChannels[i].name,
                  icon: priorChannels[i].icon,
                  isOn: fresh.channels[i].isOn,
                  brightness: fresh.channels[i].brightness,
                  isModbusPower: priorChannels[i].isModbusPower,
                )
              : fresh.channels[i],
      ]);

    existing.inputs
      ..clear()
      ..addAll([
        for (var i = 0; i < fresh.inputs.length; i++)
          i < priorInputs.length
              ? PhysicalInput(
                  id: priorInputs[i].id,
                  name: priorInputs[i].name,
                  mode: priorInputs[i].mode,
                  enabled: priorInputs[i].enabled,
                  state: priorInputs[i].state,
                )
              : fresh.inputs[i],
      ]);

    return existing;
  }
}
