package com.fzfstudio.ezw_ble.ble.extension

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

internal class BluetoothDeviceExtTest {
    @Test
    fun resolveBleDeviceName_prefersRemoteNameWhenPresent() {
        val resolvedName = resolveBleDeviceName(
            remoteName = "Even G2_32_R_E40F4F",
            requestName = "Even G2_32_R_STALE",
            cachedScanName = "Even G2_32_R_OLDER",
        )

        assertEquals("Even G2_32_R_E40F4F", resolvedName)
    }

    @Test
    fun resolveBleDeviceName_prefersConnectParameterWhenRemoteNameIsMissing() {
        val resolvedName = resolveBleDeviceName(
            remoteName = null,
            requestName = "Even G2_32_R_E40F4F",
            cachedScanName = "Even G2_32_R_OLD",
        )

        assertEquals("Even G2_32_R_E40F4F", resolvedName)
    }

    @Test
    fun resolveBleDeviceName_treatsBlankRemoteNameAsMissing() {
        val resolvedName = resolveBleDeviceName(
            remoteName = " ",
            requestName = "Even G2_32_R_E40F4F",
            cachedScanName = null,
        )

        assertEquals("Even G2_32_R_E40F4F", resolvedName)
    }

    @Test
    fun resolveBleDeviceName_usesCachedScanNameWhenRemoteAndRequestNamesAreMissing() {
        val resolvedName = resolveBleDeviceName(
            remoteName = null,
            requestName = "",
            cachedScanName = "Even G2_32_R_E40F4F",
        )

        assertEquals("Even G2_32_R_E40F4F", resolvedName)
    }

    @Test
    fun resolveBleDeviceName_returnsNullWhenAllNamesAreMissing() {
        val resolvedName = resolveBleDeviceName(
            remoteName = null,
            requestName = " ",
            cachedScanName = "",
        )

        assertNull(resolvedName)
    }
}
