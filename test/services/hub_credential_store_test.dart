// test/services/hub_credential_store_test.dart
//
// Exercises the Hub Control API credential storage (doc/
// Soleux_Mobile_Control_API_TLS_Integration.md §"What the app needs"):
// per-module Hub admin logins persisted in the OS secure credential store -
// round-trip, per-module isolation, unreadable-payload handling and removal.
import 'package:flutter_test/flutter_test.dart';
import 'package:soleux_device_manager/services/hub_credential_store.dart';

void main() {
  late InMemorySecureKeyValueStore storage;
  late HubCredentialStore store;

  setUp(() {
    storage = InMemorySecureKeyValueStore();
    store = HubCredentialStore.forTesting(storage);
  });

  test('save/load round-trips the admin login per module', () async {
    await store.save('m1',
        const HubCredentials(username: 'admin', password: 'hub-secret'));

    final loaded = await store.load('m1');
    expect(loaded, isNotNull);
    expect(loaded!.username, 'admin');
    expect(loaded.password, 'hub-secret');
  });

  test('modules are isolated from each other', () async {
    await store.save('m1',
        const HubCredentials(username: 'admin', password: 'one'));
    await store.save('m2',
        const HubCredentials(username: 'root', password: 'two'));

    expect((await store.load('m1'))!.password, 'one');
    expect((await store.load('m2'))!.password, 'two');
  });

  test('a missing entry loads as null', () async {
    expect(await store.load('unknown'), isNull);
  });

  test('an unreadable stored payload degrades to null (re-login required)',
      () async {
    await storage.write('hub_credentials:m1', 'not-json{');
    expect(await store.load('m1'), isNull);
  });

  test('an entry with empty fields is rejected', () async {
    await storage.write(
        'hub_credentials:m1', '{"username":"","password":"x"}');
    expect(await store.load('m1'), isNull);
  });

  test('delete removes the stored login', () async {
    await store.save('m1',
        const HubCredentials(username: 'admin', password: 'hub-secret'));
    await store.delete('m1');
    expect(await store.load('m1'), isNull);
  });

  test('save replaces a previous login', () async {
    await store.save('m1',
        const HubCredentials(username: 'admin', password: 'old'));
    await store.save('m1',
        const HubCredentials(username: 'admin', password: 'new'));
    expect((await store.load('m1'))!.password, 'new');
  });
}
