package com.example.camera2_webrtc

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val control = Camera2Control(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "spike/camera2").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "deviceInfo" -> result.success(control.deviceInfo())
                    "capabilities" -> result.success(control.capabilities(call.argument<String>("trackId")!!))
                    "set" ->
                        result.success(
                            control.set(
                                trackId = call.argument<String>("trackId")!!,
                                param = call.argument<String>("param")!!,
                                mode = call.argument<String>("mode")!!,
                                value = (call.argument<Any>("value") as? Number)?.toDouble(),
                                preset = call.argument<String>("preset"),
                            ),
                        )
                    "reset" -> {
                        control.reset(call.argument<String>("trackId")!!)
                        result.success(null)
                    }
                    "state" -> result.success(control.state())
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("camera2", "${e.javaClass.simpleName}: ${e.message}", null)
            }
        }
    }
}
