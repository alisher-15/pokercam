plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.pokercam.camera"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // branding/default/brand.json android_application_id; per brand from stage 8.
        applicationId = "com.pokercam.camera"
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
