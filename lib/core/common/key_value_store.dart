import 'package:shared_preferences/shared_preferences.dart';

/// Type-safe key-value wrapper over SharedPreferences
/// (generic server version; app-specific keys belong to
/// their owning feature, doc/02 §3.2 core/common).
class KeyValueStore {
  KeyValueStore({required SharedPreferences sharedPreferences})
      : _prefs = sharedPreferences;

  final SharedPreferences _prefs;

  Future<void> reload() async {
    await _prefs.reload();
  }

  String? getString(String key) {
    return _prefs.getString(key);
  }

  Future<bool> setString(String key, String value) {
    return _prefs.setString(key, value);
  }

  int? getInt(String key) {
    return _prefs.getInt(key);
  }

  Future<bool> setInt(String key, int value) {
    return _prefs.setInt(key, value);
  }

  bool? getBool(String key) {
    return _prefs.getBool(key);
  }

  Future<bool> setBool(String key, bool value) {
    return _prefs.setBool(key, value);
  }

  Future<bool> remove(String key) {
    return _prefs.remove(key);
  }

  bool containsKey(String key) {
    return _prefs.containsKey(key);
  }
}
