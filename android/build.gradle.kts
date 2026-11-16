buildscript {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

allprojects {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    buildscript {
        repositories {
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            maven { url = uri("https://maven.aliyun.com/repository/public") }
            maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
            google()
            mavenCentral()
            gradlePluginPortal()
        }
    }
}
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.variant.LibraryAndroidComponentsExtension>(
            "androidComponents",
        ) {
            finalizeDsl { library ->
                // Older plugins need API 36 for current AndroidX dependencies.
                // Preserve any higher or preview SDK explicitly requested by a plugin.
                if (library.compileSdkPreview == null) {
                    library.compileSdk = maxOf(library.compileSdk ?: 0, 36)
                }
                if (project.name == "flutter_webrtc") {
                    check(project.file("../pubspec.yaml").readLines().any {
                        it.trim() == "version: 1.6.3"
                    }) { "Review android/webrtc_patch before upgrading flutter_webrtc from 1.6.3" }
                    // Keep the published plugin and native SDK, replacing only the
                    // Android observer affected by the onAddTrack JNI crash.
                    // The replacement is intentionally flat so this exclusion
                    // matches only the upstream package-relative source path.
                    val patchedJava = library.sourceSets.getByName("main").java as
                        com.android.build.gradle.api.AndroidSourceDirectorySet
                    patchedJava.filter.exclude("com/cloudwebrtc/webrtc/PeerConnectionObserver.java")
                    patchedJava.srcDir(rootProject.file("webrtc_patch/java"))
                    library.sourceSets.getByName("test").java.srcDir(
                        rootProject.file("webrtc_patch/test")
                    )
                }
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
