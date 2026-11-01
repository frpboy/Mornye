package com.zarz.mornye

import android.media.session.MediaSession
import android.support.v4.media.session.MediaSessionCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.ryanheise.audioservice.AudioServicePlugin
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AudioOutputSessionTokenTest {
    @Test
    fun compatTokenExposesTheUnderlyingFrameworkSessionToken() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val session = MediaSession(context, "mornye-output-switcher-test")

        try {
            val compatToken = MediaSessionCompat.Token.fromToken(session.sessionToken)

            assertNotNull(compatToken)
            assertSame(
                session.sessionToken,
                AudioServicePlugin.toPlatformMediaSessionToken(compatToken),
            )
            assertNull(AudioServicePlugin.toPlatformMediaSessionToken(null))
        } finally {
            session.release()
        }
    }
}
