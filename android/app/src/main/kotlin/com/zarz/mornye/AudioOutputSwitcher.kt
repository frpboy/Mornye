package com.zarz.mornye

import android.content.Context
import android.media.MediaRouter2
import android.os.Build
import android.os.ext.SdkExtensions
import com.ryanheise.audioservice.AudioServicePlugin

/**
 * Opens the system output picker against Mornye's active media session when
 * Android exposes the session-specific API.
 */
internal object AudioOutputSwitcher {
    fun show(context: Context): Boolean {
        val router = MediaRouter2.getInstance(context)
        val sessionToken = AudioServicePlugin.getPlatformMediaSessionToken()
        val extensionVersion =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
                SdkExtensions.getExtensionVersion(Build.VERSION_CODES.BAKLAVA)
            } else {
                0
            }

        return if (
            shouldUseSessionBoundOutputSwitcher(
                apiLevel = Build.VERSION.SDK_INT,
                baklavaExtensionVersion = extensionVersion,
                hasPlatformSessionToken = sessionToken != null,
            )
        ) {
            router.showSystemOutputSwitcher(checkNotNull(sessionToken))
        } else {
            router.showSystemOutputSwitcher()
        }
    }
}

/**
 * The token overload is available with B Extensions v1 (Android 16.1).
 * Keep the public API 34 picker as a fallback for older builds and sessions
 * that have not connected yet.
 */
internal fun shouldUseSessionBoundOutputSwitcher(
    apiLevel: Int,
    baklavaExtensionVersion: Int,
    hasPlatformSessionToken: Boolean,
): Boolean =
    apiLevel >= Build.VERSION_CODES.BAKLAVA &&
        baklavaExtensionVersion >= 1 &&
        hasPlatformSessionToken
