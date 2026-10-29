package com.example.camera2_webrtc

import android.content.Context
import android.graphics.Rect
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.ColorSpaceTransform
import android.hardware.camera2.params.RggbChannelVector
import android.hardware.camera2.params.TonemapCurve
import android.os.Build
import android.os.Handler
import android.os.SystemClock
import android.util.Log
import android.util.Range
import android.view.Surface
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.GetUserMediaImpl
import org.webrtc.Camera2Capturer
import org.webrtc.CameraEnumerationAndroid
import kotlin.math.abs
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Option (a) of SPEC 6.2: reach the Camera2 session that flutter_webrtc's capturer has opened
 * (by reflection, the way flutter_webrtc's own CameraUtils sets zoom and focus) and replace its
 * repeating request with one that carries the manual settings. The video keeps flowing into the
 * same WebRTC source; nothing about the stream is rebuilt.
 */
class Camera2Control(private val context: Context) {
    /** Manual setting of one parameter, in the shape of contracts/common.json CameraControl. */
    data class Control(val mode: String, val value: Double?, val preset: String?)

    private class Session(
        val device: CameraDevice,
        val captureSession: CameraCaptureSession,
        val surface: Surface,
        val handler: Handler,
        val fpsRange: Range<Int>,
        val characteristics: CameraCharacteristics,
        val width: Int,
        val height: Int,
    )

    private val controls = mutableMapOf<String, Control>()

    // Latest values reported by the camera (CaptureResult), read from the camera thread.
    @Volatile private var latest: Map<String, Any?> = emptyMap()
    @Volatile private var lastError: String? = null
    private var colorTransform: ColorSpaceTransform? = null
    private var lastIso: Int? = null
    private var lastExposureNs: Long? = null

    // When each parameter was last requested, and how long the camera took to report it applied.
    private val requestedAt = mutableMapOf<String, Long>()
    private val appliedAfterMs = mutableMapOf<String, Long>()

    private val callback =
        object : CameraCaptureSession.CaptureCallback() {
            override fun onCaptureCompleted(
                session: CameraCaptureSession,
                request: CaptureRequest,
                result: TotalCaptureResult,
            ) {
                record(result)
            }
        }

    fun deviceInfo(): Map<String, Any?> =
        mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "brand" to Build.BRAND,
            "model" to Build.MODEL,
            "device" to Build.DEVICE,
            "android" to Build.VERSION.RELEASE,
            "sdk" to Build.VERSION.SDK_INT,
            "display" to Build.DISPLAY,
            "hardware" to Build.HARDWARE,
            // The Android emulator: its camera runs at a few fps, so delays there say little.
            "emulator" to (Build.HARDWARE == "ranchu" || Build.HARDWARE == "goldfish"),
            "harmony_os" to harmonyOsVersion(),
        )

    /** What the camera of this track supports, per parameter, in the shape of ParamCapability. */
    fun capabilities(trackId: String): Map<String, Any?> {
        val s = session(trackId)
        val c = s.characteristics
        val caps = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)?.toList() ?: emptyList()
        val manualSensor = CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR in caps
        val manualPost = CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING in caps
        val params = mutableMapOf<String, Any?>()

        val minFocus = c.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f
        val afModes = c.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)?.toList() ?: emptyList()
        params["focus"] =
            if (minFocus > 0f && CameraMetadata.CONTROL_AF_MODE_OFF in afModes) {
                param(listOf("auto", "manual"), 0.0, minFocus.toDouble(), minFocus / 100.0)
            } else {
                unsupported()
            }

        val iso = c.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
        params["iso"] =
            if (manualSensor && iso != null) {
                param(listOf("auto", "manual"), iso.lower.toDouble(), iso.upper.toDouble(), 1.0)
            } else {
                unsupported()
            }

        val exposure = c.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
        params["exposure"] =
            if (manualSensor && exposure != null) {
                // At most 1/30 s, so the stream keeps 30 fps (SPEC 6.2).
                param(listOf("auto", "manual"), exposure.lower.toDouble(), min(exposure.upper, FRAME_NS).toDouble(), 100_000.0)
            } else {
                unsupported()
            }

        val compensation = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
        params["brightness"] =
            if (compensation != null && compensation.lower < compensation.upper) {
                param(listOf("auto", "manual"), compensation.lower.toDouble(), compensation.upper.toDouble(), 1.0)
            } else {
                unsupported()
            }

        val toneModes = c.get(CameraCharacteristics.TONEMAP_AVAILABLE_TONE_MAP_MODES)?.toList() ?: emptyList()
        params["contrast"] =
            if (CameraMetadata.TONEMAP_MODE_CONTRAST_CURVE in toneModes) {
                param(listOf("auto", "manual"), -50.0, 50.0, 1.0)
            } else {
                unsupported()
            }

        val awbModes = c.get(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES)?.toList() ?: emptyList()
        val presets = PRESETS.filterValues { it in awbModes }.keys.toList()
        val wbModes = mutableListOf("auto")
        if (presets.isNotEmpty()) wbModes += "preset"
        if (manualPost && CameraMetadata.CONTROL_AWB_MODE_OFF in awbModes) wbModes += "manual"
        params["white_balance"] =
            if (wbModes.size > 1) {
                param(wbModes, 2000.0, 9000.0, 100.0, presets)
            } else {
                unsupported()
            }

        val zoomRange = zoomRatioRange(c)
        params["zoom"] =
            if (zoomRange != null && zoomRange.upper > 1f) {
                param(listOf("manual"), zoomRange.lower.toDouble(), zoomRange.upper.toDouble(), 0.1)
            } else {
                unsupported()
            }

        return mapOf(
            "camera_id" to s.device.id,
            "hardware_level" to hardwareLevel(c.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)),
            "capabilities" to caps.map { capabilityName(it) },
            "capture_size" to "${s.width}x${s.height}",
            "fps_range" to "${s.fpsRange.lower}-${s.fpsRange.upper}",
            "params" to params,
        )
    }

    /** Applies one parameter and returns the setting actually requested (the value clamped to the range). */
    fun set(trackId: String, param: String, mode: String, value: Double?, preset: String?): Map<String, Any?> {
        val s = session(trackId)
        @Suppress("UNCHECKED_CAST")
        val capability = (capabilities(trackId)["params"] as Map<String, Map<String, Any?>>)[param]
            ?: throw IllegalArgumentException("unsupported_param: $param")
        if (capability["supported"] != true) throw IllegalArgumentException("unsupported_param: $param")
        @Suppress("UNCHECKED_CAST")
        val modes = capability["modes"] as List<String>
        if (mode !in modes) throw IllegalArgumentException("unsupported_mode: $param $mode")
        val clamped =
            if (mode == "manual") {
                val v = value ?: throw IllegalArgumentException("out_of_range: $param needs a value")
                v.coerceIn(capability["min"] as Double, capability["max"] as Double)
            } else {
                null
            }
        if (mode == "preset" && preset !in PRESETS) throw IllegalArgumentException("unsupported_mode: preset $preset")
        // Exposure compensation only steers auto exposure (SPEC 6.2): with manual ISO or exposure it does nothing.
        val manualSensor = listOf("iso", "exposure").any { controls[it]?.mode == "manual" }
        if (param == "brightness" && mode == "manual" && manualSensor) {
            throw IllegalArgumentException("unsupported_mode: brightness needs auto ISO and exposure")
        }
        val control = Control(mode, clamped, if (mode == "preset") preset else null)
        synchronized(this) {
            controls[param] = control
            requestedAt[param] = SystemClock.elapsedRealtime()
            appliedAfterMs.remove(param)
        }
        applyControls(s)
        return mapOf("param" to param, "mode" to control.mode, "value" to control.value, "preset" to control.preset)
    }

    /** Back to what flutter_webrtc requested: every parameter automatic. */
    fun reset(trackId: String) {
        synchronized(this) {
            controls.clear()
            requestedAt.clear()
            appliedAfterMs.clear()
        }
        applyControls(session(trackId))
    }

    /** The camera's latest reported values and how long each requested change took to show up. */
    fun state(): Map<String, Any?> =
        synchronized(this) {
            mapOf(
                "result" to latest,
                "applied_after_ms" to appliedAfterMs.toMap(),
                "pending" to requestedAt.keys.filter { it !in appliedAfterMs },
                "error" to lastError,
            )
        }

    private fun applyControls(s: Session) {
        val request =
            synchronized(this) {
                buildRequest(s)
            }
        s.handler.post {
            try {
                s.captureSession.setRepeatingRequest(request, callback, s.handler)
                lastError = null
            } catch (e: CameraAccessException) {
                fail("setRepeatingRequest", e)
            } catch (e: IllegalStateException) {
                fail("setRepeatingRequest", e)
            }
        }
    }

    private fun buildRequest(s: Session): CaptureRequest {
        val c = s.characteristics
        val b = s.device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
        b.addTarget(s.surface)
        b.set(CaptureRequest.CONTROL_MODE, CameraMetadata.CONTROL_MODE_AUTO)
        b.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, s.fpsRange)

        val iso = controls["iso"]?.takeIf { it.mode == "manual" }
        val exposure = controls["exposure"]?.takeIf { it.mode == "manual" }
        if (iso != null || exposure != null) {
            // Manual sensor: AE is off, so both values are needed; the missing one keeps what AE last chose.
            b.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_OFF)
            val isoRange = c.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
            b.set(CaptureRequest.SENSOR_SENSITIVITY, iso?.value?.toInt() ?: lastIso ?: isoRange?.lower ?: 100)
            b.set(CaptureRequest.SENSOR_EXPOSURE_TIME, exposure?.value?.toLong() ?: min(lastExposureNs ?: FRAME_NS / 2, FRAME_NS))
            b.set(CaptureRequest.SENSOR_FRAME_DURATION, FRAME_NS)
        } else {
            b.set(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_ON)
            b.set(CaptureRequest.CONTROL_AE_LOCK, false)
            val brightness = controls["brightness"]?.takeIf { it.mode == "manual" }?.value
            if (brightness != null) b.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, brightness.toInt())
        }

        val focus = controls["focus"]?.takeIf { it.mode == "manual" }?.value
        val afModes = c.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)?.toList() ?: emptyList()
        if (focus != null) {
            b.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_OFF)
            b.set(CaptureRequest.LENS_FOCUS_DISTANCE, focus.toFloat())
        } else if (CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_VIDEO in afModes) {
            b.set(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
        }

        val wb = controls["white_balance"]
        when (wb?.mode) {
            "preset" -> b.set(CaptureRequest.CONTROL_AWB_MODE, PRESETS.getValue(wb.preset!!))
            "manual" -> {
                b.set(CaptureRequest.CONTROL_AWB_MODE, CameraMetadata.CONTROL_AWB_MODE_OFF)
                b.set(CaptureRequest.COLOR_CORRECTION_MODE, CameraMetadata.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX)
                b.set(CaptureRequest.COLOR_CORRECTION_GAINS, gainsForKelvin(wb.value ?: 5000.0))
                b.set(CaptureRequest.COLOR_CORRECTION_TRANSFORM, colorTransform ?: IDENTITY)
            }
            else -> b.set(CaptureRequest.CONTROL_AWB_MODE, CameraMetadata.CONTROL_AWB_MODE_AUTO)
        }

        val contrast = controls["contrast"]?.takeIf { it.mode == "manual" }?.value
        if (contrast != null) {
            b.set(CaptureRequest.TONEMAP_MODE, CameraMetadata.TONEMAP_MODE_CONTRAST_CURVE)
            val curve = contrastCurve(contrast)
            b.set(CaptureRequest.TONEMAP_CURVE, TonemapCurve(curve, curve, curve))
        }

        val zoom = controls["zoom"]?.value
        if (zoom != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                b.set(CaptureRequest.CONTROL_ZOOM_RATIO, zoom.toFloat())
            } else {
                val active = c.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)!!
                val w = (active.width() / zoom).toInt()
                val h = (active.height() / zoom).toInt()
                val left = active.left + (active.width() - w) / 2
                val top = active.top + (active.height() - h) / 2
                b.set(CaptureRequest.SCALER_CROP_REGION, Rect(left, top, left + w, top + h))
            }
        }
        return b.build()
    }

    private fun record(result: TotalCaptureResult) {
        val values = mutableMapOf<String, Any?>()
        values["frame"] = result.frameNumber
        result.get(CaptureResult.SENSOR_SENSITIVITY)?.let {
            values["iso"] = it
            lastIso = it
        }
        result.get(CaptureResult.SENSOR_EXPOSURE_TIME)?.let {
            values["exposure"] = it
            lastExposureNs = it
        }
        result.get(CaptureResult.LENS_FOCUS_DISTANCE)?.let { values["focus"] = it.toDouble() }
        result.get(CaptureResult.CONTROL_AE_EXPOSURE_COMPENSATION)?.let { values["brightness"] = it }
        result.get(CaptureResult.CONTROL_AE_MODE)?.let { values["ae_mode"] = it }
        result.get(CaptureResult.CONTROL_AF_MODE)?.let { values["af_mode"] = it }
        result.get(CaptureResult.CONTROL_AWB_MODE)?.let { values["awb_mode"] = it }
        result.get(CaptureResult.TONEMAP_MODE)?.let { values["tonemap_mode"] = it }
        result.get(CaptureResult.COLOR_CORRECTION_TRANSFORM)?.let { colorTransform = it }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            result.get(CaptureResult.CONTROL_ZOOM_RATIO)?.let { values["zoom"] = it.toDouble() }
        }
        if (values["zoom"] == null) {
            val crop = result.get(CaptureResult.SCALER_CROP_REGION)
            val active = latestActiveWidth
            if (crop != null && active != null && crop.width() > 0) values["zoom"] = active.toDouble() / crop.width()
        }
        latest = values
        synchronized(this) {
            val now = SystemClock.elapsedRealtime()
            for ((param, at) in requestedAt) {
                if (param !in appliedAfterMs && matches(param, values)) appliedAfterMs[param] = now - at
            }
        }
    }

    @Volatile private var latestActiveWidth: Int? = null

    /** Whether the camera reports the requested setting of a parameter. */
    private fun matches(param: String, r: Map<String, Any?>): Boolean {
        val control = controls[param] ?: return false
        val v = control.value
        fun near(actual: Any?, tolerance: Double): Boolean =
            actual is Number && v != null && abs(actual.toDouble() - v) <= tolerance
        return when (param) {
            "iso" -> if (control.mode == "manual") near(r["iso"], max(1.0, v!! * 0.1)) else r["ae_mode"] == CameraMetadata.CONTROL_AE_MODE_ON
            "exposure" -> if (control.mode == "manual") near(r["exposure"], v!! * 0.1) else r["ae_mode"] == CameraMetadata.CONTROL_AE_MODE_ON
            "focus" -> if (control.mode == "manual") near(r["focus"], max(0.05, v!! * 0.05)) else r["af_mode"] != CameraMetadata.CONTROL_AF_MODE_OFF
            "brightness" -> if (control.mode == "manual") near(r["brightness"], 0.5) else true
            "contrast" -> if (control.mode == "manual") r["tonemap_mode"] == CameraMetadata.TONEMAP_MODE_CONTRAST_CURVE else true
            "white_balance" ->
                when (control.mode) {
                    "preset" -> r["awb_mode"] == PRESETS[control.preset]
                    "manual" -> r["awb_mode"] == CameraMetadata.CONTROL_AWB_MODE_OFF
                    else -> r["awb_mode"] == CameraMetadata.CONTROL_AWB_MODE_AUTO
                }
            "zoom" -> near(r["zoom"], max(0.02, v!! * 0.02))
            else -> false
        }
    }

    private fun session(trackId: String): Session {
        val plugin = FlutterWebRTCPlugin.sharedSingleton ?: throw IllegalStateException("flutter_webrtc is not initialized")
        val handler = privateField(plugin, "methodCallHandler")
        val getUserMedia = privateField(handler, "getUserMediaImpl") as GetUserMediaImpl
        val info = getUserMedia.getCapturerInfo(trackId) ?: throw IllegalStateException("no capturer for track $trackId")
        val capturer = info.capturer
        if (capturer !is Camera2Capturer) throw IllegalStateException("capturer is ${capturer.javaClass.name}, not Camera2Capturer")
        val current = privateField(capturer, "currentSession")
        val device = privateField(current, "cameraDevice") as CameraDevice
        val format = privateField(current, "captureFormat") as CameraEnumerationAndroid.CaptureFormat
        val fpsUnitFactor = privateField(current, "fpsUnitFactor") as Int
        val manager = context.getSystemService(Context.CAMERA_SERVICE) as android.hardware.camera2.CameraManager
        val characteristics = manager.getCameraCharacteristics(device.id)
        latestActiveWidth = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)?.width()
        return Session(
            device = device,
            captureSession = privateField(current, "captureSession") as CameraCaptureSession,
            surface = privateField(current, "surface") as Surface,
            handler = privateField(current, "cameraThreadHandler") as Handler,
            fpsRange = Range(format.framerate.min / fpsUnitFactor, format.framerate.max / fpsUnitFactor),
            characteristics = characteristics,
            width = format.width,
            height = format.height,
        )
    }

    private fun fail(what: String, e: Exception) {
        lastError = "$what: ${e.javaClass.simpleName}: ${e.message}"
        Log.e(TAG, lastError, e)
    }

    private fun param(
        modes: List<String>,
        min: Double,
        max: Double,
        step: Double,
        presets: List<String> = emptyList(),
    ): Map<String, Any?> =
        mapOf("supported" to true, "modes" to modes, "min" to min, "max" to max, "step" to step, "presets" to presets)

    private fun unsupported(): Map<String, Any?> = mapOf("supported" to false, "modes" to emptyList<String>(), "presets" to emptyList<String>())

    private fun zoomRatioRange(c: CameraCharacteristics): Range<Float>? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            c.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)?.let { return it }
        }
        val maxDigital = c.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: return null
        return Range(1f, maxDigital)
    }

    companion object {
        private const val TAG = "Camera2Control"
        private const val FRAME_NS = 1_000_000_000L / 30

        val PRESETS =
            mapOf(
                "incandescent" to CameraMetadata.CONTROL_AWB_MODE_INCANDESCENT,
                "fluorescent" to CameraMetadata.CONTROL_AWB_MODE_FLUORESCENT,
                "warm_fluorescent" to CameraMetadata.CONTROL_AWB_MODE_WARM_FLUORESCENT,
                "daylight" to CameraMetadata.CONTROL_AWB_MODE_DAYLIGHT,
                "cloudy_daylight" to CameraMetadata.CONTROL_AWB_MODE_CLOUDY_DAYLIGHT,
                "twilight" to CameraMetadata.CONTROL_AWB_MODE_TWILIGHT,
                "shade" to CameraMetadata.CONTROL_AWB_MODE_SHADE,
            )

        private val IDENTITY = ColorSpaceTransform(intArrayOf(1, 1, 0, 1, 0, 1, 0, 1, 1, 1, 0, 1, 0, 1, 0, 1, 1, 1))

        private fun privateField(obj: Any, name: String): Any {
            var cls: Class<*>? = obj.javaClass
            while (cls != null) {
                try {
                    val field = cls.getDeclaredField(name)
                    field.isAccessible = true
                    return field.get(obj) ?: throw IllegalStateException("${cls.simpleName}.$name is null (camera not open yet?)")
                } catch (e: NoSuchFieldException) {
                    cls = cls.superclass
                }
            }
            throw IllegalStateException("no field $name in ${obj.javaClass.name}: flutter_webrtc or libwebrtc changed")
        }

        /** RGGB gains that neutralize light of the given color temperature (approximation, good enough for a spike). */
        fun gainsForKelvin(kelvin: Double): RggbChannelVector {
            val t = kelvin / 100.0
            val r = if (t <= 66) 255.0 else (329.698727446 * (t - 60).pow(-0.1332047592)).coerceIn(0.0, 255.0)
            val g =
                if (t <= 66) {
                    (99.4708025861 * ln(t) - 161.1195681661).coerceIn(1.0, 255.0)
                } else {
                    (288.1221695283 * (t - 60).pow(-0.0755148492)).coerceIn(1.0, 255.0)
                }
            val b = if (t >= 66) 255.0 else if (t <= 19) 1.0 else (138.5177312231 * ln(t - 10) - 305.0447927307).coerceIn(1.0, 255.0)
            return RggbChannelVector((g / r).toFloat(), 1f, 1f, (g / b).toFloat())
        }

        /** Linear contrast around mid-grey: -50 flattens, +50 doubles the slope. */
        fun contrastCurve(contrast: Double): FloatArray {
            val slope = 1.0 + contrast / 50.0
            val points = 33
            return FloatArray(points * 2) { i ->
                val x = (i / 2) / (points - 1.0)
                if (i % 2 == 0) x.toFloat() else (0.5 + (x - 0.5) * slope).coerceIn(0.0, 1.0).toFloat()
            }
        }

        private fun hardwareLevel(level: Int?): String =
            when (level) {
                CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "legacy"
                CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "limited"
                CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "full"
                CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "level_3"
                CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL -> "external"
                else -> "unknown($level)"
            }

        private fun capabilityName(capability: Int): String =
            when (capability) {
                CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_BACKWARD_COMPATIBLE -> "backward_compatible"
                CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR -> "manual_sensor"
                CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_POST_PROCESSING -> "manual_post_processing"
                CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_RAW -> "raw"
                CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_READ_SENSOR_SETTINGS -> "read_sensor_settings"
                CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_BURST_CAPTURE -> "burst_capture"
                CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_CONSTRAINED_HIGH_SPEED_VIDEO -> "constrained_high_speed_video"
                CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA -> "logical_multi_camera"
                else -> capability.toString()
            }

        /** HarmonyOS version on Huawei phones, or null elsewhere. HarmonyOS NEXT does not run Android apps at all. */
        private fun harmonyOsVersion(): String? =
            try {
                val buildEx = Class.forName("com.huawei.system.BuildEx")
                val brand = buildEx.getMethod("getOsBrand").invoke(null) as? String
                if (brand.equals("harmony", ignoreCase = true)) {
                    val properties = Class.forName("android.os.SystemProperties")
                    properties.getMethod("get", String::class.java).invoke(null, "hw_sc.build.platform.version") as? String ?: "unknown"
                } else {
                    null
                }
            } catch (e: Exception) {
                null
            }
    }
}
