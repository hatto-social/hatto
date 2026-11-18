plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Report-only. The task is not wired to assemble, and reports are not copied into assets.
    id("com.jaredsburrows.license")
}

android {
    namespace = "social.hatto.hatto_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "social.hatto.hatto_mobile"
        // rslib's Android sqlite path assumes a modern NDK. 24 matches current Flutter.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        ndk {
            // 32-bit x86 emulators are not a v0 target. x86_64 stays for the emulator.
            abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")
        }
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

// `tools/license/gen-notices.sh` runs `licenseReleaseReport`. Nothing in the
// app runtime reads the plugin's output directory. The committed JSON is
// `assets/licenses/android-deps.json`.
licenseReport {
    generateCsvReport = false
    generateHtmlReport = false
    generateJsonReport = false
    generateJsonFullReport = true
    generateTextReport = false
    copyCsvReportToAssets = false
    copyHtmlReportToAssets = false
    copyJsonReportToAssets = false
    copyJsonFullReportToAssets = false
    copyTextReportToAssets = false
    showVersions = true
}
