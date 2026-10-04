package com.el.finance

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

// Alarm terjadwal (ringkasan harian) hangus saat reboot — receiver ini
// menampilkan pengingat generik SEKALI agar pengguna membuka aplikasi,
// yang lalu menghitung ulang + menjadwalkan digest sebenarnya
// (lihat digest_scheduler + RootShell). Tanpa dependensi plugin apa pun:
// cukup baca flag preferensi langsung dari file XML Flutter.
//
// Batasan jujur: isi digest personal (angka terbaru) hanya bisa dihitung
// Flutter yang sedang hidup — receiver tak bisa membacanya.
class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val CHANNEL_ID = "kaji_reminder"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) return
        try {
            // Android 13+: tanpa izin notifikasi, post meledak — cek dulu.
            if (Build.VERSION.SDK_INT >= 33 &&
                ContextCompat.checkSelfPermission(
                    context, Manifest.permission.POST_NOTIFICATIONS
                ) != PackageManager.PERMISSION_GRANTED
            ) return

            val sp = context.getSharedPreferences(
                "FlutterSharedPreferences", Context.MODE_PRIVATE
            )
            // Kunci preferensi ter-scope profil (cerminkan scopedProfileKey
            // Dart: default polos, sisanya "flutter.p_<id>_<key>").
            val active = sp.getString("flutter.kaji_active_profile", null)
                ?: "default"
            val enabledKey = if (active == "default") {
                "flutter.kaji_digest_enabled"
            } else {
                "flutter.p_${active}_kaji_digest_enabled"
            }
            if (!sp.getBoolean(enabledKey, false)) return

            val langKey = if (active == "default") {
                "flutter.kaji_lang"
            } else {
                "flutter.p_${active}_kaji_lang"
            }
            val id = sp.getString(langKey, "id") == "en"

            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE)
                        as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        if (id) "Reminders" else "Pengingat",
                        NotificationManager.IMPORTANCE_DEFAULT
                    )
                )
            }

            val launch = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
            val pending = PendingIntent.getActivity(
                context, 9001, launch,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val notif = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(
                    if (id) "Kaji Finance digest" else "Ringkasan Kaji Finance"
                )
                .setContentText(
                    if (id) "Open the app for today's summary"
                    else "Buka aplikasi untuk ringkasan hari ini"
                )
                .setContentIntent(pending)
                .setAutoCancel(true)
                .build()
            manager.notify(9002, notif)
        } catch (_: Exception) {
            // Receiver tak boleh crash boot — gagal diam-diam.
        }
    }
}
