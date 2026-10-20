package com.example.hongguo_app

import android.app.PictureInPictureParams
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var playbackChannel: MethodChannel? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        playbackChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hongguo/platform-playback")
        playbackChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
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
        super.onDestroy()
    }

}
