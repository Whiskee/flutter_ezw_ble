package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.enums.BleLoggerTag
import kotlin.test.Test
import kotlin.test.assertEquals

/** Exercises Android's real ScanCallback entry point so callback name collisions cannot hide in source checks. */
class BleScanPipelineTest {

    @Test
    fun `scan failure forwards its code once and logs once`() {
        val reportedCodes = mutableListOf<Int>()
        val logs = mutableListOf<Pair<BleLoggerTag, String>>()
        val pipeline = BleScanPipeline(
            bleConfigs = { emptyList() },
            scanPureMode = { false },
            scanResultTemp = mutableListOf<BleDevice>(),
            expirePendingScanConnects = {},
            tryConnectFromPendingScan = {},
            emitMatchDevices = { _, _ -> },
            reportScanFailure = { reportedCodes.add(it) },
            sendLog = { tag, message -> logs.add(tag to message) },
        )

        // A platform failure must return after one manager handoff; recursive dispatch previously overflowed here.
        pipeline.onScanFailed(2)

        assertEquals(listOf(2), reportedCodes)
        assertEquals(listOf(BleLoggerTag.e to "Start scan: error = 2"), logs)
    }
}
