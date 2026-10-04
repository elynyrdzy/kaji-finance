import 'package:flutter/services.dart';

import 'app_log.dart';

/// Saklar FLAG_SECURE Android (blokir screenshot & thumbnail recent-apps).
///
/// Best-effort dan tak pernah melempar: di platform tanpa channel native
/// (iOS tanpa implementasi, desktop, flutter test) kegagalan ditelan agar
/// toggle Pengaturan tetap berfungsi sebagai preferensi murni.
class SecureScreenService {
  SecureScreenService._();

  static const _channel = MethodChannel('com.el.finance/secure');

  static Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setSecure', {'enabled': enabled});
    } catch (e) {
      AppLog.error('secure.set', e);
    }
  }
}
