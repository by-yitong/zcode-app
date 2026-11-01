import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名: CI 环境变量优先, 其次 android/key.properties (本地, 已 gitignore)。
// 两者都没有时回退 debug 签名, 保证 flutter run --release 依然可用。
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) load(FileInputStream(f))
}
val ksStoreFile = System.getenv("ANDROID_KEYSTORE_FILE") ?: keystoreProperties.getProperty("storeFile")
val ksStorePassword = System.getenv("ANDROID_STORE_PASSWORD") ?: keystoreProperties.getProperty("storePassword")
val ksKeyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: keystoreProperties.getProperty("keyAlias")
val ksKeyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: keystoreProperties.getProperty("keyPassword")
val hasReleaseSigning = listOf(ksStoreFile, ksStorePassword, ksKeyAlias, ksKeyPassword).all { !it.isNullOrBlank() }

android {
    namespace = "com.zcode.zcode_app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications 需要 core library desugaring
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.zcode.zcode_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(ksStoreFile!!)
                storePassword = ksStorePassword
                keyAlias = ksKeyAlias
                keyPassword = ksKeyPassword
            }
        }
    }

    buildTypes {
        debug {
            // Debug 变体装成独立包 (com.zcode.zcode_app.debug), 与 release
            // 共存: 签名/数据互不干扰, flutter run 不会覆盖 release 包。
            applicationIdSuffix = ".debug"
            manifestPlaceholders["launcherLabel"] = "ZCode 调试"
        }
        release {
            // 有正式签名 (key.properties 或环境变量) 时用之, 否则回退 debug 以便本地 --release 试跑。
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            manifestPlaceholders["launcherLabel"] = "ZCode"
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
