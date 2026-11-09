plugins {
    id("com.android.application")
}

android {
    namespace = "com.syncview.receiver"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.syncview.receiver"
        minSdk = 30
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Assinado com a chave de debug: o app é só para uso pessoal via USB.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
