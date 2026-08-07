package com.fzfstudio.ezw_ble.ble.models

object BluetoothGattStatus {
    const val HCI_CONNECTION_TIMEOUT = 8
    const val HCI_REMOTE_USER_TERMINATED_CONNECTION = 19
    const val HCI_LOCAL_HOST_TERMINATED_CONNECTION = 22
    const val HCI_LMP_RESPONSE_TIMEOUT = 34
    const val HCI_CONNECTION_FAILED_TO_BE_ESTABLISHED = 62
    const val GATT_INSUFFICIENT_AUTHORIZATION = 8

    private val gattOperationStatusMessages: Map<Int, String> = mapOf(
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
        133 to "GATT_ERROR", // Generic error. This is a very common one for various unspecified issues.
    )

    private val connectionStatusMessages: Map<Int, String> = mapOf(
        0 to "GATT_SUCCESS",
        HCI_CONNECTION_TIMEOUT to "HCI_CONNECTION_TIMEOUT",
        HCI_REMOTE_USER_TERMINATED_CONNECTION to "HCI_REMOTE_USER_TERMINATED_CONNECTION",
        HCI_LOCAL_HOST_TERMINATED_CONNECTION to "HCI_LOCAL_HOST_TERMINATED_CONNECTION",
        HCI_LMP_RESPONSE_TIMEOUT to "HCI_LMP_OR_LL_RESPONSE_TIMEOUT",
        HCI_CONNECTION_FAILED_TO_BE_ESTABLISHED to "HCI_CONNECTION_FAILED_TO_BE_ESTABLISHED",
        133 to "GATT_ERROR",
        257 to "GATT_CONN_CANCELLED_BY_LOCAL_CLIENT",
    )

    /**
     * `onConnectionStateChange` receives controller/HCI-style disconnect reasons.
     * Some numeric values overlap ATT/GATT operation status codes, so connection
     * callbacks must never reuse the characteristic/descriptor status table.
     */
    fun getConnectionStatusDescription(status: Int): String {
        return formatStatus(connectionStatusMessages[status] ?: "UNKNOWN_CONNECTION_STATUS", status)
    }

    /**
     * Characteristic/descriptor callbacks report ATT/GATT operation status.
     * In this context status 8 remains `GATT_INSUFFICIENT_AUTHORIZATION`.
     */
    fun getGattOperationStatusDescription(status: Int): String {
        return formatStatus(gattOperationStatusMessages[status] ?: "UNKNOWN_GATT_STATUS_OR_UNLISTED_ERROR", status)
    }

    private fun formatStatus(message: String, status: Int): String {
        return "$message(code=$status/0x${status.toString(16).uppercase().padStart(2, '0')})"
    }
}
