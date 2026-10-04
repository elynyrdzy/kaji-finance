package com.el.finance

import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Jangan diganti ke FlutterActivity: BiometricPrompt local_auth wajib FragmentActivity.
class MainActivity: FlutterFragmentActivity() {
    private val channelName = "com.el.finance/secure"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // FLAG_SECURE default MATI agar tak memblokir user; Flutter
        // menyinkronkan nilai prefs via channel ini saat startup & tiap
        // toggle di Pengaturan (lihat SecureScreenService).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method == "setSecure") {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    runOnUiThread {
                        if (enabled) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }
}
