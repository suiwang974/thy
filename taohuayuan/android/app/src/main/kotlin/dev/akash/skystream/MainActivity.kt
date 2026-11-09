package dev.akash.skystream

import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

/// 下载落盘通道（第 27 条）：视频下完后写进系统 Downloads/桃花源/，
/// 用户在文件管理器里能直接找到；App 内播本地文件也走这里拿到的真实路径。
/// Android 10+ 强制分区存储，Dart 层不能直接往公共 Downloads 写文件，
/// 只能走 MediaStore insert + ContentResolver 输出流。
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "taohuayuan/downloads")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToDownloads" -> {
                        val tempPath = call.argument<String>("tempPath")
                        val fileName = call.argument<String>("fileName")
                        val mimeType = call.argument<String>("mimeType") ?: "video/*"
                        if (tempPath == null || fileName == null) {
                            result.error("BAD_ARGS", "tempPath/fileName 缺失", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(saveToDownloads(tempPath, fileName, mimeType))
                        } catch (e: Exception) {
                            result.error("SAVE_FAILED", e.message, null)
                        }
                    }
                    "deleteFromDownloads" -> {
                        val uri = call.argument<String>("uri")?.let { Uri.parse(it) }
                        if (uri == null) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(contentResolver.delete(uri, null, null) > 0)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "resolvePath" -> {
                        val uri = call.argument<String>("uri")?.let { Uri.parse(it) }
                        result.success(uri?.let { resolvePath(it) })
                    }
                    else -> result.notImplemented()
                }
            }
        // 应用内更新通道（第 50 条）：侧载包没有 Play 商店，in-app update API 用不了，
        // 自己走 GitHub Releases 查新版 → 多段下 APK → 调系统安装器装。
        // 版本号直接读 PackageManager，不用再加 package_info_plus 依赖。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "taohuayuan/update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getVersion" -> {
                        try {
                            val pi = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                packageManager.getPackageInfo(
                                    packageName,
                                    PackageManager.PackageInfoFlags.of(0),
                                )
                            } else {
                                @Suppress("DEPRECATION")
                                packageManager.getPackageInfo(packageName, 0)
                            }
                            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                pi.longVersionCode
                            } else {
                                @Suppress("DEPRECATION")
                                pi.versionCode.toLong()
                            }
                            result.success(mapOf("versionName" to (pi.versionName ?: ""), "versionCode" to code))
                        } catch (e: Exception) {
                            result.error("VERSION_FAILED", e.message, null)
                        }
                    }
                    "canInstall" -> {
                        // Android 8 以下没有未知来源开关，默认能装。
                        val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            packageManager.canRequestPackageInstalls()
                        } else {
                            true
                        }
                        result.success(ok)
                    }
                    "openInstallSettings" -> {
                        try {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SETTINGS_FAILED", e.message, null)
                        }
                    }
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("BAD_ARGS", "path 缺失", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val file = File(path)
                            if (!file.exists()) {
                                result.error("NOT_FOUND", "安装包不存在，可能被系统清掉了，重新下载", null)
                                return@setMethodCallHandler
                            }
                            // APK 在 App 缓存目录里，别的 App 读不到路径，
                            // 只能走 FileProvider 给系统安装器一个 content:// URI。
                            val uri = FileProvider.getUriForFile(
                                this,
                                "$packageName.fileprovider",
                                file,
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun saveToDownloads(
        tempPath: String,
        fileName: String,
        mimeType: String,
    ): Map<String, String?> {
        val src = File(tempPath)
        if (!src.exists()) throw IllegalStateException("临时文件不存在")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val name = uniqueName(fileName)
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mimeType)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/桃花源")
            }
            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw IllegalStateException("MediaStore insert 失败")
            contentResolver.openOutputStream(uri)?.use { out ->
                FileInputStream(src).use { it.copyTo(out) }
            } ?: throw IllegalStateException("打不开 MediaStore 输出流")
            return mapOf("uri" to uri.toString(), "path" to resolvePath(uri))
        } else {
            // Android 9 及以下：直接写公共 Downloads（需 WRITE_EXTERNAL_STORAGE，
            // Manifest 里只给到 maxSdkVersion 28；用户手机是 Android 16，走上面那条）。
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "桃花源",
            )
            if (!dir.exists()) dir.mkdirs()
            var target = File(dir, fileName)
            var i = 1
            while (target.exists()) {
                val base = fileName.substringBeforeLast('.')
                val ext = fileName.substringAfterLast('.', "")
                target = File(dir, "$base($i).$ext")
                i++
            }
            src.copyTo(target, overwrite = true)
            return mapOf("uri" to Uri.fromFile(target).toString(), "path" to target.absolutePath)
        }
    }

    /// 同名文件已在 Downloads/桃花源/ 里时改名（name(1).mp4），别让两个文件同名。
    private fun uniqueName(fileName: String): String {
        val base = fileName.substringBeforeLast('.')
        val ext = fileName.substringAfterLast('.', "")
        var candidate = fileName
        var i = 1
        while (existsInDownloads(candidate)) {
            candidate = if (ext.isEmpty()) "$base($i)" else "$base($i).$ext"
            i++
        }
        return candidate
    }

    private fun existsInDownloads(displayName: String): Boolean {
        return try {
            contentResolver.query(
                MediaStore.Downloads.EXTERNAL_CONTENT_URI,
                arrayOf(MediaStore.Downloads._ID),
                "${MediaStore.Downloads.DISPLAY_NAME} = ?",
                arrayOf(displayName),
                null,
            )?.use { it.count > 0 } ?: false
        } catch (_: Exception) {
            false
        }
    }

    /// 自己插入的文件：DATA 列通常能取到真实路径；取不到就按 DISPLAY_NAME
    /// 拼 /storage/emulated/0/Download/桃花源/<name> 再验存在。
    private fun resolvePath(uri: Uri): String? {
        try {
            contentResolver.query(
                uri,
                arrayOf(MediaStore.Downloads.DATA),
                null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex(MediaStore.Downloads.DATA)
                    if (idx >= 0) {
                        val p = c.getString(idx)
                        if (!p.isNullOrEmpty()) return p
                    }
                }
            }
        } catch (_: Exception) {
        }
        try {
            contentResolver.query(
                uri,
                arrayOf(MediaStore.Downloads.DISPLAY_NAME),
                null, null, null,
            )?.use { c ->
                if (c.moveToFirst()) {
                    val name = c.getString(0)
                    if (!name.isNullOrEmpty()) {
                        val p = File(
                            Environment.getExternalStorageDirectory(),
                            "Download/桃花源/$name",
                        )
                        if (p.exists()) return p.absolutePath
                    }
                }
            }
        } catch (_: Exception) {
        }
        return null
    }
}
