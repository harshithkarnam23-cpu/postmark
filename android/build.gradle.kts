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
subprojects {
    project.evaluationDependsOn(":app")
    plugins.withId("com.android.library") {
        if (project.name == "file_picker") {
            project.plugins.apply("org.jetbrains.kotlin.android")
            project.tasks.configureEach {
                if (this.javaClass.name.contains("KotlinCompile")) {
                    try {
                        val kotlinOptions = this.javaClass.getMethod("getKotlinOptions").invoke(this)
                        kotlinOptions.javaClass.getMethod("setJvmTarget", String::class.java).invoke(kotlinOptions, "17")
                    } catch (e: Exception) {
                        // fallback for newer KGP
                        try {
                            val compilerOptions = this.javaClass.getMethod("getCompilerOptions").invoke(this)
                            val targetEnum = Class.forName("org.jetbrains.kotlin.gradle.dsl.JvmTarget")
                                .getField("JVM_17").get(null)
                            compilerOptions.javaClass.getMethod("getJvmTarget").returnType.let { returnType ->
                                compilerOptions.javaClass.getMethod("setJvmTarget", returnType).invoke(compilerOptions, targetEnum)
                            }
                        } catch (ex: Exception) {
                            // ignore
                        }
                    }
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
