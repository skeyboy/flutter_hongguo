package com.example.hongguo_app

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import android.view.KeyEvent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var playbackChannel: MethodChannel? = null
    private var multicastLock: android.net.wifi.WifiManager.MulticastLock? = null
    private var tvBackDown = false

    @Suppress("DEPRECATION")
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        // The TV flavor uses the .tv application id suffix. Route physical Back
        // through Android once, rather than both Flutter focus keys and popRoute.
        if (packageName.endsWith(".tv") && event.keyCode == KeyEvent.KEYCODE_BACK) {
            when (event.action) {
                KeyEvent.ACTION_DOWN -> if (event.repeatCount == 0) tvBackDown = true
                KeyEvent.ACTION_UP -> {
                    val shouldBack = tvBackDown && !event.isCanceled
                    tvBackDown = false
                    if (shouldBack) onBackPressed()
                }
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        if (packageName.endsWith(".tv")) {
            // Never let Activity's root fallback finish the TV task.
            flutterEngine?.navigationChannel?.popRoute()
            return
        }
        super.onBackPressed()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hongguo/tv-device")
            .setMethodCallHandler { call, result ->
                if (call.method == "profile") {
                    val manager = getSystemService(android.content.Context.UI_MODE_SERVICE) as android.app.UiModeManager
                    val memory = getSystemService(android.content.Context.ACTIVITY_SERVICE) as android.app.ActivityManager
                    result.success(mapOf(
                        "television" to (manager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION),
                        "leanback" to packageManager.hasSystemFeature("android.software.leanback"),
                        "lowRam" to memory.isLowRamDevice
                    ))
                } else result.notImplemented()
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hongguo/multicast")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        val wifi = getSystemService(android.content.Context.WIFI_SERVICE) as android.net.wifi.WifiManager
                        val lock = multicastLock ?: wifi.createMulticastLock("hongguo-ssdp").apply {
                            setReferenceCounted(false)
                        }
                        multicastLock = lock
                        if (!lock.isHeld) lock.acquire()
                        result.success(true)
                    }
                    "release" -> {
                        multicastLock?.let { if (it.isHeld) it.release() }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        playbackChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hongguo/platform-playback")
        playbackChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "available" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    packageManager.hasSystemFeature(android.content.pm.PackageManager.FEATURE_PICTURE_IN_PICTURE))
                "enter" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                        result.success(false)
                    } else {
                        try {
                            val width = call.argument<Int>("width") ?: 9
                            val height = call.argument<Int>("height") ?: 16
                            val ratio = (width.toDouble() / height.coerceAtLeast(1)).coerceIn(1.0 / 2.39, 2.39)
                            val params = PictureInPictureParams.Builder()
                                .setAspectRatio(Rational((ratio * 1000).toInt(), 1000)).build()
                            result.success(enterPictureInPictureMode(params))
                        } catch (error: Exception) {
                            result.error("pip_unavailable", "系统未允许进入画中画", null)
                        }
                    }
                }
                "exit" -> {
                    val intent = Intent(this, MainActivity::class.java)
                    intent.addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    startActivity(intent)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
    override fun onPictureInPictureModeChanged(active: Boolean, config: Configuration) {
        super.onPictureInPictureModeChanged(active, config)
        playbackChannel?.invokeMethod("pip", active)
    }
    override fun onDestroy() {
        // A dismissed PiP must not leave an unannounced audio-only player when
        // the user has not enabled background playback.
        playbackChannel?.invokeMethod("pip", false)
        multicastLock?.let { if (it.isHeld) it.release() }
        super.onDestroy()
    }

}
