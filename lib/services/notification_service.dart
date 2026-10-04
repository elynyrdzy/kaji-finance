import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../l10n/app_strings.dart';
import '../utils/money_format.dart';
import 'secure_db_service.dart';

/// Data ringkasan harian (dibangun provider, dijadwalkan service).
/// Murni data — komposisi teks ada di [NotificationService.composeDigest]
/// agar bisa di-unit-test tanpa database.
class GoalDue {
  final String name;

  /// Sisa hari (negatif = lewat tenggat).
  final int daysLeft;

  /// Rupiah utuh (Phase 4).
  final int remaining;
  const GoalDue({
    required this.name,
    required this.daysLeft,
    required this.remaining,
  });
}

class WalletLow {
  final String name;

  /// Rupiah utuh (Phase 4).
  final int balance;
  const WalletLow({required this.name, required this.balance});
}

class DigestData {
  /// Rupiah utuh (Phase 4).
  final int spentToday;

  /// Hari sejak transaksi terakhir (-1 = belum ada transaksi sama sekali).
  final int daysSinceLastTx;

  /// Sisa uang bulanan, rupiah utuh (null = uang bulanan 0/tak diatur).
  final int? allowanceLeft;
  final List<GoalDue> goalsDue;
  final List<WalletLow> lowWallets;

  const DigestData({
    required this.spentToday,
    required this.daysSinceLastTx,
    required this.allowanceLeft,
    this.goalsDue = const [],
    this.lowWallets = const [],
  });
}

/// Saklar isi digest (1:1 dengan preferensi pengguna).
class DigestOptions {
  final bool budget;
  final bool goals;
  final bool wallets;
  final bool nudge;
  const DigestOptions({
    this.budget = true,
    this.goals = true,
    this.wallets = true,
    this.nudge = true,
  });
}

class DigestContent {
  final String title;
  final String body;
  const DigestContent({required this.title, required this.body});
}

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _inited = false;
  static bool _tzReady = false;

  /// ID stabil untuk ringkasan harian (cancel + ganti jadwal andal
  /// lintas restart — String.hashCode tidak stabil antar-run).
  static const digestId = 9001;

  /// Bahasa aktif untuk judul terjemah di notifikasi seketika.
  /// Diisi penjadwal/UI sebelum alert (default id).
  static String _lang = 'id';
  static void setLanguage(String code) => _lang = code;

  /// Penerima ketukan notifikasi, didaftarkan main.dart:
  /// (payload, actionId). Payload: 'digest' | 'budget' | 'savings' | 'add'.
  /// ActionId: 'add' bila tombol Catat ditekan, null bila badan diketuk.
  static void Function(String? payload, String? actionId)? onResponse;

  static Future<void> init() async {
    if (_inited) return;
    // Gagal init (perangkat aneh) tidak boleh meledak ke pemanggil:
    // semua show* dipanggil unawaited dari provider.
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const ios = DarwinInitializationSettings();
      const settings = InitializationSettings(android: android, iOS: ios);
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: (r) {
          try {
            onResponse?.call(r.payload, r.actionId);
          } catch (_) {
            // best-effort: callback ketuk notifikasi tak boleh meledak.
          }
        },
      );
    } catch (e) {
      SecureDbService.noteError('Notif: init plugin gagal: $e');
    }
    _inited = true;
  }

  static void _ensureTimeZones() {
    if (_tzReady) return;
    try {
      tzdata.initializeTimeZones();
    } catch (e) {
      SecureDbService.noteError('Notif: init timezone gagal: $e');
    }
    _tzReady = true;
  }

  static Future<bool> requestPermission() async {
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidImpl != null) {
      final granted = await androidImpl.requestNotificationsPermission();
      return granted ?? false;
    }
    return true;
  }

  /// Status izin notifikasi via permission_handler — sumber kebenaran
  /// tunggal untuk UI (membedakan ditolak biasa vs permanen).
  static Future<PermissionStatus> notificationStatus() async {
    try {
      return await Permission.notification.status;
    } catch (_) {
      return PermissionStatus.denied;
    }
  }

  /// Pastikan izin ada: minta bila belum diputuskan/ditolak biasa.
  /// Return false bila ditolak permanen (pemanggil arahkan ke Pengaturan
  /// sistem) atau gagal. Fallback ke API flutter_local_notifications
  /// bila permission_handler gagal.
  static Future<bool> ensurePermission() async {
    try {
      var s = await Permission.notification.status;
      if (s.isGranted || s.isLimited) return true;
      if (s.isPermanentlyDenied) return false;
      s = await Permission.notification.request();
      return s.isGranted || s.isLimited;
    } catch (_) {
      return requestPermission();
    }
  }

  /// Buka halaman info aplikasi di Pengaturan sistem (untuk izin yang
  /// ditolak permanen — satu-satunya jalan mengaktifkan kembali).
  static Future<void> openSystemSettings() async {
    try {
      await openAppSettings();
    } catch (_) {
      // best-effort: navigasi ke Pengaturan sistem gagal → user tetap di aplikasi.
    }
  }

  /// Bisa menjadwal alarm tepat-waktu? (Android 12+ perlu izin
  /// SCHEDULE_EXACT_ALARM; tanpa itu jadwal fallback inexact.)
  static Future<bool> canScheduleExact() async {
    try {
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await androidImpl?.canScheduleExactNotifications() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Minta izin alarm tepat-waktu ke sistem (Android 12+). Return true
  /// bila diberikan (atau tak diperlukan di Android lama).
  static Future<bool> requestExactAlarms() async {
    try {
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl == null) return true;
      return await androidImpl.requestExactAlarmsPermission() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Hash stabil lintas restart (pengganti String.hashCode untuk ID
  /// notifikasi agar notif yang sama menimpa, bukan menumpuk).
  static int stableId(String s) {
    var h = 0x811c9dc5;
    for (var i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h = (h * 0x01000193) & 0xffffffff;
    }
    return h & 0x7fffffff;
  }

  /// Tingkat alert anggaran dari persen: 0 aman, 1 setengah (50%),
  /// 2 menipis (80%), 3 habis (100%).
  static int budgetAlertLevel(double percent) {
    if (percent >= 1.0) return 3;
    if (percent >= 0.8) return 2;
    if (percent >= 0.5) return 1;
    return 0;
  }

  static Future<void> showBudgetAlert({
    required String id,
    required String category,
    required double percent,
    required int spent,
    required int limit,
    int tier = 2,
    String? extra,
    double? projectedPct,
  }) async {
    await init();
    // Lazy permission (P1-2): minta hanya saat alert pertama benar-benar
    // mau tampil, bukan tiap cold start. Batal diam-diam bila ditolak.
    try {
      if (!await ensurePermission()) return;
    } catch (_) {
      return;
    }
    final pct = (percent * 100).toStringAsFixed(0);
    final title = tier <= 1
        ? AppStrings.fill('budgetHalfTitle', _lang, {'name': category})
        : pct == '100'
            ? AppStrings.fill('budgetDepletedTitle', _lang, {'name': category})
            : AppStrings.fill('budgetLowTitle', _lang, {'name': category});
    var body = AppStrings.fill('budgetAlertBody', _lang, {
      'p': pct,
      's': MoneyFormat.format(spent),
      'l': MoneyFormat.format(limit),
    });
    if (extra != null && extra.isNotEmpty) body = '$body • $extra';
    if (projectedPct != null && projectedPct > 1.0) {
      body = '$body • ${AppStrings.fill('budgetProjected', _lang, {
            'p': (projectedPct * 100).toStringAsFixed(0)
          })}';
    }
    const androidDetails = AndroidNotificationDetails(
      'kaji_budget',
      'Budget Alerts',
      channelDescription: 'Notifikasi saat budget hampir habis',
      importance: Importance.high,
      priority: Priority.high,
      color: Color(0xFF4EDEA3),
    );
    const details = NotificationDetails(android: androidDetails);
    // show() di luar try/catch = unhandled async error di pemanggil
    // unawaited (provider). Kegagalan notif tak boleh merusak alur data.
    try {
      await _plugin.show(
        stableId('budget:$id'),
        title,
        body,
        details,
        payload: 'budget',
      );
    } catch (e) {
      SecureDbService.noteError('Notif: budget alert "$id" gagal tampil: $e');
    }
  }

  static Future<void> showSimple(String title, String body) async {
    await init();
    // Lazy permission (P1-2): tile Tes di Settings sudah ensurePermission
    // dulu, tapi pemanggil lain tetap aman — tolak diam-diam bila blocked.
    try {
      if (!await ensurePermission()) return;
    } catch (_) {
      return;
    }
    const androidDetails = AndroidNotificationDetails(
      'kaji_general',
      'Kaji Finance',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
    );
    const details = NotificationDetails(android: androidDetails);
    try {
      await _plugin.show(
        DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
        title,
        body,
        details,
      );
    } catch (e) {
      SecureDbService.noteError('Notif: showSimple gagal: $e');
    }
  }

  // --- Ringkasan harian terjadwal ---

  /// Susun judul + isi digest dari data. Murni (tanpa I/O) agar
  /// bisa di-unit-test. Baris belanja hari ini selalu ada sehingga
  /// isi tak pernah kosong.
  static DigestContent composeDigest(
    DigestData d,
    DigestOptions o,
    String lang,
  ) {
    final lines = <String>[
      AppStrings.fill('digestSpentToday', lang, {
        'amount': MoneyFormat.format(d.spentToday),
      }),
    ];
    if (o.budget && d.allowanceLeft != null) {
      lines.add(
        AppStrings.fill('digestBudgetLeft', lang, {
          'amount': MoneyFormat.format(d.allowanceLeft!),
        }),
      );
    }
    if (o.goals) {
      for (final g in d.goalsDue) {
        lines.add(
          g.daysLeft < 0
              ? AppStrings.fill('digestGoalOverdue', lang, {
                  'name': g.name,
                  'n': -g.daysLeft,
                  'amount': MoneyFormat.format(g.remaining),
                })
              : AppStrings.fill('digestGoalDue', lang, {
                  'name': g.name,
                  'n': g.daysLeft,
                  'amount': MoneyFormat.format(g.remaining),
                }),
        );
      }
    }
    if (o.wallets) {
      for (final w in d.lowWallets) {
        lines.add(
          AppStrings.fill('digestWalletLow', lang, {
            'name': w.name,
            'amount': MoneyFormat.format(w.balance),
          }),
        );
      }
    }
    if (o.nudge && d.daysSinceLastTx >= 2) {
      lines.add(AppStrings.fill('digestNoTx', lang, {'n': d.daysSinceLastTx}));
    }
    return DigestContent(
      title: AppStrings.get('digestNotifTitle', lang),
      body: lines.join('\n'),
    );
  }

  /// Kemunculan lokal berikutnya untuk jam:menit (basis zona perangkat).
  /// Murni terhadap [now] agar bisa di-unit-test.
  static DateTime nextDailyOccurrence(DateTime now, int hour, int minute) {
    var next = DateTime(now.year, now.month, now.day, hour, minute);
    if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
    return next;
  }

  /// Jadwalkan SATU kemunculan berikutnya pukul [hour]:[minute]
  /// (tanpa pengulangan harian).
  ///
  /// Pengulangan harian (`matchDateTimeComponents`) SENGAJA tidak dipakai:
  /// isinya dibekukan saat dijadwalkan sehingga pengulangan menampilkan
  /// data basi. Satu-tembak selalu segar karena [refreshDigestSchedule]
  /// dijadwalkan ulang tiap aplikasi dipakai (pause/cold start/impor/
  /// ganti bahasa) dan BootReceiver memancing buka aplikasi pasca-reboot.
  /// Tanpa database zona-IANA: jam lokal dikonversi ke UTC; pengulangan
  /// tak ada sehingga isu geser DST tak berlaku (Indonesia tanpa DST).
  static Future<void> scheduleDailyDigest({
    required DigestContent content,
    required int hour,
    required int minute,
    required bool exact,
    required String addLabel,
    required String viewLabel,
  }) async {
    await init();
    _ensureTimeZones();
    try {
      if (!await ensurePermission()) return;
    } catch (_) {
      return;
    }
    try {
      await _plugin.cancel(digestId);
      final next = nextDailyOccurrence(DateTime.now(), hour, minute);
      final androidDetails = AndroidNotificationDetails(
        'kaji_reminder',
        'Pengingat',
        channelDescription: 'Ringkasan harian & pengingat Kaji Finance',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        color: const Color(0xFF4EDEA3),
        actions: [
          AndroidNotificationAction('add', addLabel),
          AndroidNotificationAction('view', viewLabel),
        ],
      );
      const iosDetails = DarwinNotificationDetails();
      final details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );
      await _plugin.zonedSchedule(
        digestId,
        content.title,
        content.body,
        tz.TZDateTime.from(next.toUtc(), tz.UTC),
        details,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        payload: 'digest',
      );
    } catch (e) {
      SecureDbService.noteError('Notif: jadwalkan digest gagal: $e');
    }
  }

  static Future<void> cancelDailyDigest() async {
    try {
      await _plugin.cancel(digestId);
    } catch (_) {
      // best-effort: batalkan jadwal gagal → jadwal lama mungkin tetap bunyi sekali.
    }
  }

  // --- Pengingat tagihan rutin (channel kaji_reminder yang sama) ---

  /// ID stabil per (tagihan, H-x) agar jadwal menimpa, bukan menumpuk.
  static int recurringReminderId(String billId, int daysBefore) =>
      stableId('recur:$billId:$daysBefore');

  /// Jadwalkan SATU pengingat pukul 08:00 lokal pada (dueDate − daysBefore).
  /// Dilewati diam-diam bila momennya sudah lewat. daysBefore ∈ {3,1,0}.
  static Future<void> scheduleRecurringBillReminder({
    required String billId,
    required String name,
    required int amount,
    required DateTime dueDate,
    required int daysBefore,
  }) async {
    await init();
    _ensureTimeZones();
    try {
      if (!await ensurePermission()) return;
    } catch (_) {
      return;
    }
    try {
      final day = DateTime(
        dueDate.year,
        dueDate.month,
        dueDate.day,
      ).subtract(Duration(days: daysBefore));
      final at = DateTime(day.year, day.month, day.day, 8, 0);
      if (!at.isAfter(DateTime.now())) return;
      final when = daysBefore >= 3
          ? AppStrings.fill('recurringWhen3', _lang)
          : daysBefore >= 1
              ? AppStrings.fill('recurringWhen1', _lang)
              : AppStrings.fill('recurringWhen0', _lang);
      const androidDetails = AndroidNotificationDetails(
        'kaji_reminder',
        'Pengingat',
        channelDescription: 'Ringkasan harian & pengingat Kaji Finance',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        color: Color(0xFF4EDEA3),
      );
      const iosDetails = DarwinNotificationDetails();
      const details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );
      await _plugin.zonedSchedule(
        recurringReminderId(billId, daysBefore),
        AppStrings.get('recurringDueTitle', _lang),
        AppStrings.fill('recurringDueBody', _lang, {
          'name': name,
          'amount': MoneyFormat.format(amount),
          'when': when,
        }),
        tz.TZDateTime.from(at.toUtc(), tz.UTC),
        details,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: 'recurring:$billId',
      );
    } catch (e) {
      SecureDbService.noteError('Notif: jadwalkan tagihan gagal: $e');
    }
  }

  /// Batalkan ketiga slot H-3/H-1/H0 satu tagihan (hapus/nonaktif).
  static Future<void> cancelRecurringBillReminders(String billId) async {
    try {
      for (final h in const [3, 1, 0]) {
        await _plugin.cancel(recurringReminderId(billId, h));
      }
    } catch (_) {
      // best-effort.
    }
  }

  /// Tampilkan SEKARANG pengingat jatuh tempo (dipakai uji + fallback
  /// bila jadwal terlewat). Channel kaji_reminder yang sama.
  static Future<void> showRecurringDueNow({
    required String name,
    required int amount,
    required int daysLeft,
  }) async {
    await init();
    try {
      if (!await ensurePermission()) return;
    } catch (_) {
      return;
    }
    final when = daysLeft <= 0
        ? AppStrings.fill('recurringWhen0', _lang)
        : daysLeft == 1
            ? AppStrings.fill('recurringWhen1', _lang)
            : AppStrings.fill('recurringDueIn', _lang, {'n': daysLeft});
    const androidDetails = AndroidNotificationDetails(
      'kaji_reminder',
      'Pengingat',
      channelDescription: 'Ringkasan harian & pengingat Kaji Finance',
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      color: Color(0xFF4EDEA3),
    );
    const details = NotificationDetails(android: androidDetails);
    try {
      await _plugin.show(
        stableId('recur:now:$name:$amount'),
        AppStrings.get('recurringDueTitle', _lang),
        AppStrings.fill('recurringDueBody', _lang, {
          'name': name,
          'amount': MoneyFormat.format(amount),
          'when': when,
        }),
        details,
        payload: 'recurring',
      );
    } catch (e) {
      SecureDbService.noteError('Notif: tagihan seketika gagal: $e');
    }
  }
}
