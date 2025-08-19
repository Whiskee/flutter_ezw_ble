package com.fzfstudio.ezw_ble.ble.models

// 在 BleManager.kt 文件顶部或者一个合适的位置

object BluetoothGattStatus {
    val statusMessages: Map<Int, String> = mapOf(
        0 to "GATT_SUCCESS",
        1 to "GATT_INVALID_HANDLE", // HCI_ERR_INVALID_CONN_HANDLE
        2 to "GATT_READ_NOT_PERMITTED", // HCI_ERR_READ_NOT_PERMITTED
        3 to "GATT_WRITE_NOT_PERMITTED", // HCI_ERR_WRITE_NOT_PERMITTED
        4 to "GATT_INVALID_PDU", // HCI_ERR_INVALID_PDU
        5 to "GATT_INSUFFICIENT_AUTHENTICATION", // HCI_ERR_INSUFFICIENT_AUTHEN
        6 to "GATT_REQUEST_NOT_SUPPORTED", // HCI_ERR_REQ_NOT_SUPPORTED
        7 to "GATT_INVALID_OFFSET", // HCI_ERR_INVALID_OFFSET
        8 to "GATT_INSUFFICIENT_AUTHORIZATION", // HCI_ERR_INSUFFICIENT_AUTHOR
        9 to "GATT_PREPARE_QUEUE_FULL", // HCI_ERR_PREPARE_QUEUE_FULL
        10 to "GATT_ATTRIBUTE_NOT_FOUND", // HCI_ERR_ATTR_NOT_FOUND
        11 to "GATT_ATTRIBUTE_NOT_LONG", // HCI_ERR_ATTR_NOT_LONG
        12 to "GATT_INSUFFICIENT_ENCRYPTION_KEY_SIZE", // HCI_ERR_INSUFFICIENT_KEY_SIZE
        13 to "GATT_INVALID_ATTRIBUTE_VALUE_LENGTH", // HCI_ERR_INVALID_ATTR_VALUE_LEN
        14 to "GATT_UNLIKELY_ERROR", // HCI_ERR_UNLIKELY_ERROR
        15 to "GATT_INSUFFICIENT_ENCRYPTION", // HCI_ERR_INSUFFICIENT_ENCRYPT
        16 to "GATT_UNSUPPORTED_GROUP_TYPE", // HCI_ERR_UNSUPPORTED_GRP_TYPE
        17 to "GATT_INSUFFICIENT_RESOURCES", // HCI_ERR_INSUFFICIENT_RESOURCES
        19 to "GATT_CONN_TERMINATE_PEER_USER", // Connection terminated by peer user
        22 to "GATT_CONN_LMP_TIMEOUT", // Connection failed to be established due to LMP response timeout
        34 to "GATT_CONN_FAIL_ESTABLISHMENT", // Connection fail to establish
        62 to "GATT_CONN_TERMINATE_LOCAL_HOST", // Connection terminated by local host
        133 to "GATT_ERROR", // Generic error. This is a very common one for various unspecified issues.
        257 to "GATT_CONN_CANCELLED_BY_LOCAL_CLIENT", // Connection cancelled by local client
        // 你可以根据需要添加更多... 查阅 Android 源码中的 gatt_api.h 和 hci_error_code.h 会有更全面的列表
    )

    fun getStatusDescription(status: Int): String {
        return statusMessages[status] ?: "UNKNOWN_GATT_STATUS_OR_UNLISTED_ERROR (Code: $status)"
    }
}