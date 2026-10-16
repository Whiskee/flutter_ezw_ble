package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.BleConfig
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Checks the production MethodChannel decoder, including old hosts that omit both opt-ins. */
class BleAndroidPairingConfigBridgeTest {
    @Test
    fun `old config retains legacy bond budget and parallel pending behavior`() {
        val config = decode(emptyMap())
        assertNull(config.androidBondTimeout)
        assertFalse(config.androidSerializeUnbonded)
        assertEquals(20_000.0, config.connectTimeout)
    }

    @Test
    fun `integer and double channel numbers preserve the opted in pairing policy`() {
        listOf<Number>(30_000, 30_000.0).forEach { timeout ->
            val config = decode(mapOf("androidBondTimeout" to timeout, "androidSerializeUnbonded" to true))
            assertEquals(30_000.0, config.androidBondTimeout)
            assertTrue(config.androidSerializeUnbonded)
            assertEquals(20_000.0, config.connectTimeout)
        }
    }

    private fun decode(policy: Map<String, Any>): BleConfig {
        val payload = mapOf(
            "name" to "g2", "scan" to mapOf("nameFilters" to listOf("Even_G2")),
            "privateServices" to emptyList<Any>(), "connectTimeout" to 20_000.0,
        ) + policy
        // The decoder stays private to the bridge; reflection exercises its actual defaults.
        return Class.forName("com.fzfstudio.ezw_ble.ble.BleMethodChannelKt")
            .getDeclaredMethod("toBleConfig", Map::class.java).also { it.isAccessible = true }
            .invoke(null, payload) as BleConfig
    }
}
