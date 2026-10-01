package com.zcode.zcode_app

import android.content.Intent
import android.net.Uri
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val channelName = "app/updater"
    private val pipChannelName = "app/pip"
    private val displayChannelName = "app/display"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "install" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("invalid_args", "path is null", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val file = File(path)
                            val uri: Uri = FileProvider.getUriForFile(
                                this, "$packageName.fileprovider", file
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("install_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // 悬浮窗进度监视器: 悬浮窗独立引擎里轻点会话页 → 主 App 回前台
        // (悬浮窗引擎无法启动 Activity, 必须经主引擎转调)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pipChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bringToForeground" -> {
                        try {
                            val launch = packageManager
                                .getLaunchIntentForPackage(packageName)
                                ?.apply {
                                    addFlags(
                                        Intent.FLAG_ACTIVITY_NEW_TASK or
                                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                                    )
                                }
                            if (launch != null) startActivity(launch)
                            result.success(launch != null)
                        } catch (e: Exception) {
                            result.error("foreground_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // 屏幕常亮 (设置页开关): FLAG_KEEP_SCREEN_ON 加/清
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, displayChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "keepScreenOn" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        if (enabled) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
