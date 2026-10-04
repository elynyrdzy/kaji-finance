/// Bus navigasi ringan antar-widget tanpa circular import.
///
/// [RootShell] mendaftarkan pemindah tab-nya di sini saat initState,
/// widget di mana saja (mis. profil di [AppHeader]) bisa memintanya.
/// Fallback: bila belum terdaftar (mis. di luar shell), pemanggil
/// memakai push halaman manual.
library app_nav;

import 'package:flutter/material.dart';

class AppNav {
  AppNav._();

  static void Function(int index)? goToTab;

  /// Navigator global — dipakai handler ketukan notifikasi
  /// (NotificationService.onResponse) yang tak punya BuildContext.
  /// Didaftarkan MaterialApp di main.dart.
  static GlobalKey<NavigatorState>? navigatorKey;
}
