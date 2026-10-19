package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.os.Build

/**
 * Android 主机侧 2M PHY 请求。
 *
 * `connectGatt(..., PHY_LE_2M)` 只是建连 hint，多数机型连上后仍停在 1M。
 * 真正切 PHY 必须在 GATT 就绪后调用 [BluetoothGatt.setPreferredPhy]；结果只记日志，
 * 失败不得阻断连接完成或 OTA 传输。iOS CoreBluetooth 没有对等公开 API。
 */
internal object BleAndroidPreferredPhy {

    /** 在当前 GATT session 上请求 TX/RX 都走 LE 2M。 */
    fun requestLe2m(
        gatt: BluetoothGatt?,
        endpoint: String,
        reason: String,
        logger: (String) -> Unit,
    ) {
        if (gatt == null) {
            logger("[ezw_ble][phy] skip 2M endpoint=$endpoint reason=$reason gatt=null")
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            logger("[ezw_ble][phy] skip 2M endpoint=$endpoint reason=$reason api=${Build.VERSION.SDK_INT}")
            return
        }
        try {
            // 先读当前 PHY，方便对照 onPhyUpdate 是否真的从 1M 切到 2M。
            gatt.readPhy()
            gatt.setPreferredPhy(
                BluetoothDevice.PHY_LE_2M,
                BluetoothDevice.PHY_LE_2M,
                BluetoothDevice.PHY_OPTION_NO_PREFERRED,
            )
            logger("[ezw_ble][phy] request 2M endpoint=$endpoint reason=$reason")
        } catch (error: Exception) {
            logger(
                "[ezw_ble][phy] request 2M failed endpoint=$endpoint reason=$reason " +
                    "error=${error.message}",
            )
        }
    }

    /**
     * 记录本机控制器是否支持 LE 2M。
     *
     * `onPhyUpdate` 返回 `status=0` 但仍是 1M 时，靠这条日志区分是手机不支持，
     * 还是外设在 LL_PHY_RSP 中拒绝了 2M。
     */
    fun logAdapterCapability(
        bluetoothAdapter: BluetoothAdapter,
        logger: (String) -> Unit,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            logger("[ezw_ble][phy] host le2M=unsupported api=${Build.VERSION.SDK_INT}")
            return
        }
        logger(
            "[ezw_ble][phy] host le2M=${bluetoothAdapter.isLe2MPhySupported} " +
                "leCoded=${bluetoothAdapter.isLeCodedPhySupported}",
        )
    }

    /** 把 Android PHY 常量转成可读名称，便于 logcat 对照现场 1M/2M。 */
    fun describe(phy: Int): String = when (phy) {
        BluetoothDevice.PHY_LE_1M -> "1M"
        BluetoothDevice.PHY_LE_2M -> "2M"
        BluetoothDevice.PHY_LE_CODED -> "CODED"
        else -> "unknown($phy)"
    }
}
