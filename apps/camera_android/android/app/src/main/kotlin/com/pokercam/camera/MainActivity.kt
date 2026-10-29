package com.pokercam.camera

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Platform channels of the camera app: pokercam/camera2 (SPEC 6.2) and pokercam/device (SPEC 6.3, 6.4). */
class MainActivity : FlutterActivity() {
    private lateinit var camera: Camera2Control
    private lateinit var device: DeviceStatus
    private var permissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        camera = Camera2Control(applicationContext)
        device = DeviceStatus(applicationContext)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "pokercam/camera2").setMethodCallHandler { call, result -> guarded(result) { camera(call, result) } }
        MethodChannel(messenger, "pokercam/device").setMethodCallHandler { call, result -> guarded(result) { device(call, result) } }
    }

    private fun guarded(result: MethodChannel.Result, body: () -> Unit) {
        try {
            body()
        } catch (e: CameraError) {
            result.error(e.code, e.message, null)
        } catch (e: Exception) {
            // Mostly "camera not open yet" or a flutter_webrtc that no longer has the fields option (a) reads.
            result.error("camera_unavailable", "${e.javaClass.simpleName}: ${e.message}", null)
        }
    }

    private fun camera(call: MethodCall, result: MethodChannel.Result) {
        val trackId = { call.argument<String>("trackId")!! }
        when (call.method) {
            "deviceInfo" -> result.success(camera.deviceInfo())
            "capabilities" -> result.success(camera.capabilities(trackId()))
            "set" ->
                camera.set(
                    trackId = trackId(),
                    param = call.argument<String>("param")!!,
                    mode = call.argument<String>("mode")!!,
                    value = (call.argument<Any>("value") as? Number)?.toDouble(),
                    preset = call.argument<String>("preset"),
                ) { answer -> result.success(answer) }
            "apply" -> result.success(camera.apply(trackId(), call.argument<Map<String, Map<String, Any?>>>("settings")!!))
            "reset" -> {
                camera.reset(trackId())
                result.success(null)
            }
            "forget" -> {
                camera.forget()
                result.success(null)
            }
            "state" -> result.success(camera.state())
            else -> result.notImplemented()
        }
    }

    private fun device(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "snapshot" -> result.success(device.snapshot())
            "identity" -> result.success(mapOf("android_id" to device.androidId(), "model" to device.model()))
            "permissions" -> result.success(permissionState())
            "requestPermissions" -> {
                val missing = runtimePermissions().filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
                if (missing.isEmpty()) {
                    result.success(permissionState())
                } else {
                    permissionResult?.success(permissionState())
                    permissionResult = result
                    requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST)
                }
            }
            "requestBatteryExemption" -> {
                if (!device.ignoresBatteryOptimizations()) {
                    @Suppress("BatteryLife") // SPEC 6.3: a camera that streams for hours must not be put to sleep.
                    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName"))
                    startActivity(intent)
                }
                result.success(null)
            }
            "startService" -> {
                val intent =
                    Intent(this, StreamService::class.java)
                        .putExtra(StreamService.EXTRA_TITLE, call.argument<String>("title"))
                        .putExtra(StreamService.EXTRA_TEXT, call.argument<String>("text"))
                        .putExtra(StreamService.EXTRA_CHANNEL, call.argument<String>("channel"))
                startForegroundService(intent)
                result.success(null)
            }
            "stopService" -> {
                stopService(Intent(this, StreamService::class.java))
                result.success(null)
            }
            "keepScreenOn" -> {
                if (call.argument<Boolean>("on") == true) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun runtimePermissions(): List<String> =
        listOf(Manifest.permission.CAMERA) +
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) listOf(Manifest.permission.POST_NOTIFICATIONS) else emptyList()

    private fun permissionState(): Map<String, Boolean> =
        mapOf(
            "camera" to (checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED),
            "notifications" to
                (
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
                ),
            "battery_unrestricted" to device.ignoresBatteryOptimizations(),
        )

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST) {
            permissionResult?.success(permissionState())
            permissionResult = null
        }
    }

    companion object {
        private const val PERMISSION_REQUEST = 42
    }
}
