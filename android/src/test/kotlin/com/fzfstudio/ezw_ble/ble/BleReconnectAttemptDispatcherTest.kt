package com.fzfstudio.ezw_ble.ble

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** 首轮多目标 activation 必须在调用方随后开始 scan 前同步创建全部 pending。 */
class BleReconnectAttemptDispatcherTest {
    @Test
    fun `initial multi-target activation opens every pending gatt before caller starts scan`() {
        val events = mutableListOf<String>()
        val scheduledDelays = mutableListOf<Long>()
        val dispatcher = BleReconnectAttemptDispatcher(
            scheduler = BleReconnectAttemptScheduler { delayMs, _ ->
                scheduledDelays += delayMs
                BleReconnectScheduleHandle {}
            },
            gattStarter = { uuid, _ -> events += "pending:$uuid" },
        )

        listOf("left", "right", "ring").forEach { uuid ->
            dispatcher.dispatch(uuid, 0L)
        }
        // 模拟 MethodChannel 返回后 even_connect 紧接着发起并行扫描。
        events += "scan"

        assertEquals(
            listOf("pending:left", "pending:right", "pending:ring", "scan"),
            events,
        )
        assertTrue(scheduledDelays.isEmpty(), "首轮 activation 不能经过异步 scheduler")
    }

    @Test
    fun `terminal retry alone uses injected scheduler`() {
        val events = mutableListOf<String>()
        var deferred: (() -> Unit)? = null
        val dispatcher = BleReconnectAttemptDispatcher(
            scheduler = BleReconnectAttemptScheduler { delayMs, attempt ->
                events += "scheduled:$delayMs"
                deferred = attempt
                BleReconnectScheduleHandle {}
            },
            gattStarter = { uuid, _ -> events += "pending:$uuid" },
        )

        dispatcher.dispatch("left", 1500L)
        assertEquals(listOf("scheduled:1500"), events)

        deferred?.invoke()
        assertEquals(listOf("scheduled:1500", "pending:left"), events)
    }

    @Test
    fun `retry forwards schedule generation so cancelled timer cannot own a newer attempt`() {
        var deferred: (() -> Unit)? = null
        var receivedGeneration: Long? = null
        val dispatcher = BleReconnectAttemptDispatcher(
            scheduler = BleReconnectAttemptScheduler { _, attempt ->
                deferred = attempt
                BleReconnectScheduleHandle {}
            },
            gattStarter = { _, generation -> receivedGeneration = generation },
        )

        dispatcher.dispatch("ring", 250L, scheduleGeneration = 7L)
        deferred?.invoke()

        assertEquals(7L, receivedGeneration)
    }
}
