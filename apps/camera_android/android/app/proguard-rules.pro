# camera2_control (Camera2Control.kt) reaches the Camera2 session flutter_webrtc opened through private fields
# of libwebrtc and flutter_webrtc (SPEC 6.2, option a): keep them with their names in release builds.
-keep class org.webrtc.** { *; }
-keep class com.cloudwebrtc.webrtc.** { *; }
