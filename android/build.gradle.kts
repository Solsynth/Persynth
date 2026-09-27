allprojects {
    repositories {
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

// Registered before the evaluationDependsOn block below: that block evaluates
// :app while the root project is still configuring, and afterEvaluate throws on
// an already evaluated project.
//
// Plugin build scripts carry their own JVM targets and AGP 9 defaults a module
// whose script sets none to Java 11, so flutter_js ends up with Java 11 against
// the Kotlin 1.8 it pins itself — a pair KGP fails the build on. Pin both sides
// to the app's own 17 for every module instead of reading AGP's value, which is
// only readable after the DSL is finalised.
subprojects {
    afterEvaluate {
        val compileOptions =
            extensions.findByType(com.android.build.api.dsl.LibraryExtension::class.java)?.compileOptions
                ?: extensions.findByType(com.android.build.api.dsl.ApplicationExtension::class.java)?.compileOptions
        compileOptions?.apply {
            sourceCompatibility = JavaVersion.VERSION_17
            targetCompatibility = JavaVersion.VERSION_17
        }
        tasks.withType(org.jetbrains.kotlin.gradle.tasks.KotlinCompile::class.java).configureEach {
            compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
