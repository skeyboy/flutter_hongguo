abstract interface class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}
