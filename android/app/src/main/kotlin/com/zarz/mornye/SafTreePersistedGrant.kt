package com.zarz.mornye

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.util.Log

/**
 * Persist and verify the read/write grant required for the selected download tree.
 *
 * Library read access has a separate policy and must not use this helper.
 */
internal fun persistSafTreeGrant(
    contentResolver: ContentResolver,
    treeUri: Uri,
    returnedFlags: Int,
): Boolean {
    val requiredAccess = Intent.FLAG_GRANT_READ_URI_PERMISSION or
        Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    if ((returnedFlags and requiredAccess) != requiredAccess) {
        return false
    }

    return try {
        contentResolver.takePersistableUriPermission(treeUri, requiredAccess)
        contentResolver.persistedUriPermissions.any { permission ->
            permission.uri == treeUri &&
                permission.isReadPermission &&
                permission.isWritePermission
        }
    } catch (error: Exception) {
        Log.w("Mornye", "Could not persist selected SAF tree permission", error)
        false
    }
}
