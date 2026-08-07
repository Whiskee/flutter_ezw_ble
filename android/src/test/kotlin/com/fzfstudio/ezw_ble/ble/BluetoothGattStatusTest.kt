package com.fzfstudio.ezw_ble.ble

import com.fzfstudio.ezw_ble.ble.models.BluetoothGattStatus
import kotlin.test.Test
import kotlin.test.assertEquals

internal class BluetoothGattStatusTest {
    @Test
    fun sameNumericStatusKeepsSeparateConnectionAndGattOperationSemantics() {
        assertEquals(
            "HCI_CONNECTION_TIMEOUT(code=8/0x08)",
            BluetoothGattStatus.getConnectionStatusDescription(8),
        )
        assertEquals(
            "GATT_INSUFFICIENT_AUTHORIZATION(code=8/0x08)",
            BluetoothGattStatus.getGattOperationStatusDescription(8),
        )
    }

    @Test
    fun androidConnectionCallbackStatusesUseHciDisconnectMeanings() {
        assertEquals(
            "HCI_REMOTE_USER_TERMINATED_CONNECTION(code=19/0x13)",
            BluetoothGattStatus.getConnectionStatusDescription(19),
        )
        assertEquals(
            "HCI_LOCAL_HOST_TERMINATED_CONNECTION(code=22/0x16)",
            BluetoothGattStatus.getConnectionStatusDescription(22),
        )
        assertEquals(
            "HCI_LMP_OR_LL_RESPONSE_TIMEOUT(code=34/0x22)",
            BluetoothGattStatus.getConnectionStatusDescription(34),
        )
        assertEquals(
            "HCI_CONNECTION_FAILED_TO_BE_ESTABLISHED(code=62/0x3E)",
            BluetoothGattStatus.getConnectionStatusDescription(62),
        )
    }
}
