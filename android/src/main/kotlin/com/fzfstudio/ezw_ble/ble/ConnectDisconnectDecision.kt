package com.fzfstudio.ezw_ble.ble

internal enum class DisconnectDuringConnectDecision {
    HANDLE_DISCONNECT,
    IGNORE_STALE_DISCONNECT,
}

internal fun decideDisconnectDuringConnect(
    isConnecting: Boolean,
    isCurrentGatt: Boolean,
): DisconnectDuringConnectDecision {
    return if (isConnecting && !isCurrentGatt) {
        DisconnectDuringConnectDecision.IGNORE_STALE_DISCONNECT
    } else {
        DisconnectDuringConnectDecision.HANDLE_DISCONNECT
    }
}

internal fun shouldIgnoreGattConnLmpTimeout(isConnecting: Boolean): Boolean {
    return !isConnecting
}
