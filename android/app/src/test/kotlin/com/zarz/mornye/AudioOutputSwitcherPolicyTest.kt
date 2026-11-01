package com.zarz.mornye

import android.os.Build
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioOutputSwitcherPolicyTest {
    @Test
    fun sessionTokenOverloadRequiresAndroid16Point1AndAnActiveToken() {
        val android15 = Build.VERSION_CODES.VANILLA_ICE_CREAM
        val android16 = Build.VERSION_CODES.BAKLAVA

        assertFalse(
            shouldUseSessionBoundOutputSwitcher(
                apiLevel = android15,
                baklavaExtensionVersion = 1,
                hasPlatformSessionToken = true,
            ),
        )
        assertFalse(
            shouldUseSessionBoundOutputSwitcher(
                apiLevel = android16,
                baklavaExtensionVersion = 0,
                hasPlatformSessionToken = true,
            ),
        )
        assertFalse(
            shouldUseSessionBoundOutputSwitcher(
                apiLevel = android16,
                baklavaExtensionVersion = 1,
                hasPlatformSessionToken = false,
            ),
        )
        assertTrue(
            shouldUseSessionBoundOutputSwitcher(
                apiLevel = android16,
                baklavaExtensionVersion = 1,
                hasPlatformSessionToken = true,
            ),
        )
    }
}
