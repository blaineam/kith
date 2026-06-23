plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.blaineam.haven"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.blaineam.haven"
        minSdk = 29
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        // We ship prebuilt .so files in jniLibs; keep the APK to the ABIs we build.
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
        release {
            isMinifyEnabled = false   // tighten later; JNA + reflection need care under R8
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    // Per-ABI APKs so a sideloadable arm64 build is ~half the size of the universal one.
    splits {
        abi {
            isEnable = true
            reset()
            include("arm64-v8a", "x86_64")
            isUniversalApk = true   // also keep a universal one for the emulator
        }
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.10.01")
    implementation(composeBom)

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("androidx.activity:activity-compose:1.9.3")

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.navigation:navigation-compose:2.8.3")

    // UniFFI Kotlin bindings need JNA (the Android @aar variant) + coroutines.
    implementation("net.java.dev.jna:jna:5.14.0@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // Persisted identity / prefs, encrypted at rest by the Android Keystore.
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // QR: generate + decode with zxing-core; scan with a custom in-app CameraX UI.
    implementation("com.google.zxing:core:3.5.3")
    implementation("androidx.camera:camera-core:1.3.4")
    implementation("androidx.camera:camera-camera2:1.3.4")
    implementation("androidx.camera:camera-lifecycle:1.3.4")
    implementation("androidx.camera:camera-view:1.3.4")
    implementation("androidx.camera:camera-video:1.3.4")

    // In-app browser (Chrome Custom Tabs) for opening shared links inside Haven.
    implementation("androidx.browser:browser:1.8.0")

    // Background sync (serverless, like the iOS BGAppRefreshTask) for local notifications.
    implementation("androidx.work:work-runtime-ktx:2.9.1")

    // Biometric (per-circle Face/fingerprint lock).
    implementation("androidx.biometric:biometric:1.1.0")

    // EXIF orientation for picked photos (so they aren't sideways/blank).
    implementation("androidx.exifinterface:exifinterface:1.3.7")

    // Nearby Connections — offline mesh over BLE/Wi-Fi (the Android take on MultipeerConnectivity).
    implementation("com.google.android.gms:play-services-nearby:19.3.0")

    // WebRTC (maintained libwebrtc fork, prebuilt .so) for mesh group calls — Android side of
    // the same DTLS-SRTP media + SDP/ICE-over-sealed-channel design as iOS.
    implementation("io.getstream:stream-webrtc-android:1.3.8")

    // Video filter transcode (MediaCodec + OpenGL decode→shader→encode). Apache-2.0, bundled in
    // the APK — no Google services, offline, de-Google-able. We feed it our own GLSL so the look
    // matches the iOS FilterSpec pipeline exactly (incl. Kodak Gold). Photos use the same shader
    // via an offscreen GL pass, so photo + video + iOS are pixel-consistent.
    implementation("com.github.MasayukiSuda:Mp4Composer-android:v0.4.1")

    debugImplementation("androidx.compose.ui:ui-tooling")

    // --- Tests ---
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")

    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
    androidTestImplementation(platform("androidx.compose:compose-bom:2024.10.01"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
