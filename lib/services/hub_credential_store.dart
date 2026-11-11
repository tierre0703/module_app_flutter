// lib/services/hub_credential_store.dart
//
// Secure storage for the Hub Control API login (doc/
// Soleux_Mobile_Control_API_TLS_Integration.md §"What the app needs"):
// the Hub's web administrator username/password used to `authenticate` a
// TLS command session (raw TLS JSON) or the Basic-auth command endpoint.
//
// Storage contract (doc §"Connection sequence"):
//   - credentials live in the OS secure credential store (Android Keystore /
//     iOS Keychain via flutter_secure_storage) - never in plain SQLite,
//   - values are never logged and never leave this class unencrypted.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Pluggable secure key/value backend (real: flutter_secure_storage;
/// tests: in-memory).
abstract class SecureKeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecureKeyValueStore implements SecureKeyValueStore {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e, st) {
      debugPrint('HubCredentialStore: secure read failed: $e\n$st');
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e, st) {
      debugPrint('HubCredentialStore: secure write failed: $e\n$st');
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e, st) {
      debugPrint('HubCredentialStore: secure delete failed: $e\n$st');
    }
  }
}

/// In-memory backend for tests (never used in production wiring).
class InMemorySecureKeyValueStore implements SecureKeyValueStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// One Hub admin login (username + password). Treated as a secret: never
/// `toString()`/log this object.
@immutable
class HubCredentials {
  final String username;
  final String password;

  const HubCredentials({required this.username, required this.password});

  Map<String, Object?> toJson() => {'username': username, 'password': password};

  static HubCredentials? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final username = raw['username'];
    final password = raw['password'];
    if (username is! String || password is! String) return null;
    if (username.isEmpty || password.isEmpty) return null;
    return HubCredentials(username: username, password: password);
  }
}

/// Per-module Hub credential storage.
class HubCredentialStore {
  final SecureKeyValueStore _storage;

  HubCredentialStore({SecureKeyValueStore? storage})
      : _storage = storage ?? FlutterSecureKeyValueStore();

  /// App-wide shared instance.
  static HubCredentialStore shared = HubCredentialStore();

  /// Isolated instance for tests.
  @visibleForTesting
  static HubCredentialStore forTesting(SecureKeyValueStore storage) =>
      HubCredentialStore(storage: storage);

  String _key(String moduleId) => 'hub_credentials:$moduleId';

  /// The stored Hub admin login for [moduleId], or null.
  Future<HubCredentials?> load(String moduleId) async {
    final raw = await _storage.read(_key(moduleId));
    if (raw == null || raw.isEmpty) return null;
    try {
      return HubCredentials.fromJson(jsonDecode(raw));
    } catch (e) {
      debugPrint('HubCredentialStore: stored credentials for $moduleId are '
          'unreadable; requiring re-login');
      return null;
    }
  }

  /// Stores (or replaces) the Hub admin login for [moduleId].
  Future<void> save(String moduleId, HubCredentials credentials) =>
      _storage.write(_key(moduleId), jsonEncode(credentials.toJson()));

  /// Removes the stored login for [moduleId] (e.g. after a logout or a
  /// device replacement).
  Future<void> delete(String moduleId) => _storage.delete(_key(moduleId));
}
