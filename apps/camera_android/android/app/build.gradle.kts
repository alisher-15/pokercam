import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The brand of this build (SPEC 10.1): tools/brand/brand.ts passes branding/<brand>/brand.json flattened as
// --dart-define-from-file, and Flutter hands the defines to Gradle base64-encoded. Without them (flutter run,
// the emulator test) the app is the default code name with a neutral label.
val dartDefines: Map<String, String> =
    (project.findProperty("dart-defines") as String?)
        ?.split(",")
        ?.mapNotNull {
            val entry = String(Base64.getDecoder().decode(it), Charsets.UTF_8)
            entry.split("=", limit = 2).takeIf { pair -> pair.size == 2 }?.let { pair -> pair[0] to pair[1] }
        }
        ?.toMap() ?: emptyMap()

android {
    namespace = "com.pokercam.camera"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        resValues = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // brand.json android_application_id; the namespace above is the code's and never changes.
        applicationId = dartDefines["BRAND_ANDROID_APPLICATION_ID"] ?: "com.pokercam.camera"
        // brand.json app_name: the launcher's label (AndroidManifest.xml reads @string/app_name).
        resValue("string", "app_name", dartDefines["BRAND_APP_NAME"] ?: "Camera")
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 10+: thermal status and Camera2 as the spike used them (SPEC 2, 6.4).
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Signed with the debug key until each brand gets its own (stage 8).
            signingConfig = signingConfigs.getByName("debug")
            // camera2_control reads private fields of libwebrtc and flutter_webrtc: R8 must keep them.
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // flutter_webrtc uses libwebrtc as an `implementation` dependency, so its classes are not on the app's
    // compile classpath. Camera2Control needs Camera2Capturer: the same version as flutter_webrtc 1.6.3 (stage 1 spike).
    implementation("io.github.webrtc-sdk:android:150.7871.04")
}
