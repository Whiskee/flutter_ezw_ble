package com.fzfstudio.ezw_ble.ble

import android.content.Context
import io.flutter.plugin.common.MethodChannel
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.mockito.Mockito

class BleOtaDebugLogPolicyTest {
    @AfterTest
    fun resetPolicy() {
        BleOtaDebugLogPolicy.setEnabled(false)
    }

    @Test
    fun `disabled detail does not evaluate strings or call logger`() {
        BleOtaDebugLogPolicy.setEnabled(false)
        var formatted = 0
        var emitted = 0
        repeat(10_000) {
            BleOtaDebugLogPolicy.logPacketDetail({ emitted++ }) { formatted++; "packet" }
            BleOtaDebugLogPolicy.logWriteCallback(1, true, { emitted++ }) { formatted++; "callback" }
        }
        assertEquals(0, formatted)
        assertEquals(0, emitted)

        BleOtaDebugLogPolicy.setEnabled(true)
        BleOtaDebugLogPolicy.logPacketDetail({ emitted++ }) { formatted++; "packet" }
        BleOtaDebugLogPolicy.logWriteCallback(1, true, { emitted++ }) { formatted++; "callback" }
        assertEquals(2, formatted)
        assertEquals(2, emitted)
        BleOtaDebugLogPolicy.setEnabled(false)
        BleOtaDebugLogPolicy.logPacketDetail({ emitted++ }) { formatted++; "packet" }
        assertEquals(2, formatted, "turning off takes effect before the next interpolation")
    }

    @Test
    fun `debug disabled preserves non ota unknown and failed callback messages`() {
        BleOtaDebugLogPolicy.setEnabled(false)
        val emitted = mutableListOf<String>()
        listOf(0 to true, null to true, 1 to false, 0 to false, null to false).forEach { (type, success) ->
            BleOtaDebugLogPolicy.logWriteCallback(type, success, emitted::add) { "$type:$success" }
        }
        assertEquals(listOf("0:true", "null:true", "1:false", "0:false", "null:false"), emitted)
    }

    @Test
    fun `receive detail is lazy only for known ota and restores immediately with debug`() {
        BleOtaDebugLogPolicy.setEnabled(false)
        var formatted = 0
        val emitted = mutableListOf<String>()
        repeat(10_000) {
            BleOtaDebugLogPolicy.logReceiveCallback(1, emitted::add) { formatted++; "ota" }
        }
        assertEquals(0, formatted)
        assertEquals(emptyList(), emitted)
        listOf(0, 2, null).forEach { type ->
            BleOtaDebugLogPolicy.logReceiveCallback(type, emitted::add) { formatted++; "$type" }
        }
        BleOtaDebugLogPolicy.setEnabled(true)
        BleOtaDebugLogPolicy.logReceiveCallback(1, emitted::add) { formatted++; "ota" }
        BleOtaDebugLogPolicy.setEnabled(false)
        BleOtaDebugLogPolicy.logReceiveCallback(1, emitted::add) { formatted++; "disabled" }
        assertEquals(4, formatted)
        assertEquals(listOf("0", "2", "null", "ota"), emitted)
    }

    @Test
    fun `existing method channel updates policy without requiring initialized ble context`() {
        val context = Mockito.mock(Context::class.java)
        val result = Mockito.mock(MethodChannel.Result::class.java)
        val method = BleMC.from("setDebugLoggingEnabled")
        method.handle(context, true, result)
        assertTrue(BleOtaDebugLogPolicy.enabled)
        method.handle(context, false, result)
        assertFalse(BleOtaDebugLogPolicy.enabled)
        method.handle(context, "true", result)
        assertFalse(BleOtaDebugLogPolicy.enabled, "non-Boolean arguments must fail closed")
        Mockito.verify(result, Mockito.times(3)).success(null)
        Mockito.verifyNoInteractions(context)
    }
}
