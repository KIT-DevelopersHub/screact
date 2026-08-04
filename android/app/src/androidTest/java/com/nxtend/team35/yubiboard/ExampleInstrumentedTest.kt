package com.nxtend.team35.yubiboard

import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.opencv.android.OpenCVLoader
import com.nxtend.team35.yubiboard.diagnostics.AppDiagnostics

import org.junit.Test
import org.junit.runner.RunWith

import org.junit.Assert.*

/**
 * Instrumented test, which will execute on an Android device.
 *
 * See [testing documentation](http://d.android.com/tools/testing).
 */
@RunWith(AndroidJUnit4::class)
class ExampleInstrumentedTest {
    @Test
    fun nativeDependenciesAndModelArePackaged() {
        val appContext = InstrumentationRegistry.getInstrumentation().targetContext
        assertEquals("com.nxtend.team35.yubiboard", appContext.packageName)
        assertTrue(OpenCVLoader.initLocal())
        appContext.assets.open("hand_landmarker.task").use { model ->
            assertTrue(model.available() > 0)
        }
    }

    @Test
    fun debugDiagnosticsCollectEvents() {
        assertTrue(BuildConfig.DEBUG)
        AppDiagnostics.clear()
        AppDiagnostics.event("instrumentation", "probe", mapOf("device" to android.os.Build.MODEL))
        assertEquals("probe", AppDiagnostics.snapshot().events.single().name)
    }
}
