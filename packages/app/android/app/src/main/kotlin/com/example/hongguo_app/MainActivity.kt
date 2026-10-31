package com.example.hongguo_app

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Rational
import android.view.KeyEvent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {
    private var playbackChannel: MethodChannel? = null
    private var multicastLock: android.net.wifi.WifiManager.MulticastLock? = null
    private var tvBackDown = false

    /// The `install` call stays unanswered until the system reports on the
    /// session, because a commit the viewer has to confirm is not yet an install.
    private var installReply: MethodChannel.Result? = null

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

    /// The session's status [PendingIntent] is addressed to this activity, so a
    /// running app takes it here. [android.content.pm.PackageInstaller] answers a
    /// commit that needs the viewer's own confirmation with
    /// [android.content.pm.PackageInstaller.STATUS_PENDING_USER_ACTION] and the
    /// dialog wrapped in [Intent.EXTRA_INTENT] -- launching that wrapped intent is
    /// the only way the installer UI appears.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action != INSTALL_RESULT_ACTION) return
        val status = intent.getIntExtra(
            android.content.pm.PackageInstaller.EXTRA_STATUS,
            android.content.pm.PackageInstaller.STATUS_FAILURE
        )
        if (status == android.content.pm.PackageInstaller.STATUS_PENDING_USER_ACTION) {
            val confirm = confirmIntent(intent)
            val opened = confirm != null && runCatching { startActivity(confirm) }.isSuccess
            answerInstall(
                if (opened) "已交给系统安装器，请在弹窗中确认安装。"
                else "系统安装器没能打开，请在设置里允许本应用安装未知应用后重试。"
            )
        } else answerInstall(installWords(status, intent))
    }

    @Suppress("DEPRECATION")
    private fun confirmIntent(intent: Intent): Intent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        else intent.getParcelableExtra(Intent.EXTRA_INTENT)

    private fun installWords(
        status: Int,
        intent: Intent
    ): String = when (status) {
        android.content.pm.PackageInstaller.STATUS_SUCCESS ->
            "新版本已安装，重新打开应用即可使用。"
        else -> {
            val reason = intent.getStringExtra(
                android.content.pm.PackageInstaller.EXTRA_STATUS_MESSAGE
            )
            "系统没有完成安装${if (reason == null) "" else "（$reason）"}，" +
                "请检查「安装未知应用」权限后重试。"
        }
    }

    /// Answers the waiting `install` call exactly once: the system can deliver a
    /// second status after a rotation or a late confirm, and a [MethodChannel.Result]
    /// that has already been used must not be touched again.
    private fun answerInstall(message: String) {
        val reply = installReply ?: return
        installReply = null
        reply.success(message)
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hongguo/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "stageDir" -> {
                        val dir = java.io.File(filesDir, "updates")
                        if (!dir.isDirectory) dir.mkdirs()
                        result.success(dir.absolutePath)
                    }
                    "abi" -> result.success(Build.SUPPORTED_ABIS.toList())
                    "canInstall" -> result.success(canRequestInstalls())
                    "askPermission" -> result.success(openInstallPermissionSettings())
                    "install" -> beginInstall(call.argument<String>("path"), result)
                    else -> result.notImplemented()
                }
            }
    }

    /// Whether this app may put an APK in front of the installer at all. Below
    /// Android 8 the toggle is a global one the installer itself prompts for, so
    /// there is nothing per-app to ask -- report it as allowed and let the system
    /// dialog decide.
    private fun canRequestInstalls(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()

    /// Opens this app's 「安装未知应用」 row. Android 8+ keeps that permission out
    /// of the runtime dialog, so the only way to get it is the settings screen.
    private fun openInstallPermissionSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val intent = Intent(
            Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
            Uri.parse("package:$packageName")
        )
        return runCatching { startActivity(intent) }.isSuccess
    }

    /// Installs through a [android.content.pm.PackageInstaller] session, which
    /// streams the bytes from a path only this app can read -- so no FileProvider
    /// and no file:// URI, the shape that Android 24+ refuses outright.
    ///
    /// [reply] is left unanswered on success: the answer comes from [onNewIntent]
    /// once the system says what it did with the session.
    private fun beginInstall(path: String?, reply: MethodChannel.Result) {
        val file = path?.let { java.io.File(it) }
        if (file == null || !file.isFile) {
            reply.success("更新文件已经不在了，请重新检查更新。")
            return
        }
        // The UI asks before it gets here; this is the race where the viewer
        // revokes the permission in between, and a session committed without it
        // fails silently -- so refuse in words instead.
        if (!canRequestInstalls()) {
            reply.success("还没有允许本应用安装未知应用，请在系统设置中打开该权限后重试。")
            return
        }
        val installer = packageManager.packageInstaller
        var sessionId = -1
        installReply = reply
        try {
            val params = android.content.pm.PackageInstaller.SessionParams(
                android.content.pm.PackageInstaller.SessionParams.MODE_FULL_INSTALL
            )
            sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                java.io.FileInputStream(file).use { input ->
                    session.openWrite(file.name, 0, file.length()).use { output ->
                        input.copyTo(output)
                        session.fsync(output)
                    }
                }
                val status = Intent(this, javaClass)
                    .setAction(INSTALL_RESULT_ACTION)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                else PendingIntent.FLAG_UPDATE_CURRENT
                session.commit(PendingIntent.getActivity(this, sessionId, status, flags).intentSender)
            }
        } catch (error: Exception) {
            if (sessionId >= 0) runCatching { installer.abandonSession(sessionId) }
            answerInstall("系统没有接受这次安装，请检查「安装未知应用」权限后重试。")
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
        // A dead activity cannot answer a channel call that died with it.
        installReply = null
        super.onDestroy()
    }

    companion object {
        private const val INSTALL_RESULT_ACTION = "hongguo.update.result"
    }
}
