import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the purchases keep entitlements and open reports between starts.
abstract interface class PurchaseStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// [PurchaseStorage] in the keychain / Keystore: entitlements unlock paid
/// features, so they do not sit in plain preferences.
class SecurePurchaseStorage implements PurchaseStorage {
  const SecurePurchaseStorage([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// [PurchaseStorage] in memory, for tests.
class MemoryPurchaseStorage implements PurchaseStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
