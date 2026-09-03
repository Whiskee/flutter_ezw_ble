package com.fzfstudio.ezw_ble.ble

import android.bluetooth.BluetoothDevice
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState

/** Android framework 的原始 bondState；UNKNOWN 必须保持 fail-closed。 */
internal enum class SystemBondState {
    NONE,
    BONDING,
    BONDED,
    UNKNOWN,
}

/** Gate 授权后、GATT readiness 启动前的唯一下一步。 */
internal enum class GateGrantedBondAction {
    DISCOVER_SERVICES,
    START_BOND,
    WAIT_FOR_BOND,
}

/** 当前系统配对广播对 exact Gate owner 的影响。 */
internal enum class BondBroadcastAction {
    IGNORE,
    DISCOVER_SERVICES,
    FAIL_BINDING,
}

/** 将 Android 常量收敛成可单测、可穷举的配对状态。 */
internal fun systemBondStateOf(rawState: Int): SystemBondState = when (rawState) {
    BluetoothDevice.BOND_NONE -> SystemBondState.NONE
    BluetoothDevice.BOND_BONDING -> SystemBondState.BONDING
    BluetoothDevice.BOND_BONDED -> SystemBondState.BONDED
    else -> SystemBondState.UNKNOWN
}

/**
 * 选择 Gate owner 的 bond-first 起点。
 *
 * 1、未启用主动系统配对的配置（如 G1）直接发现服务。
 * 2、Android G2/R1 已配对时不重复 createBond；未配对才主动发起。
 * 3、系统已在配对或返回未知状态时只等待权威广播/既有超时，不重复触发系统动作。
 */
internal fun decideGateGrantedBondAction(
    initiateBinding: Boolean,
    bondState: SystemBondState,
): GateGrantedBondAction {
    if (!initiateBinding || bondState == SystemBondState.BONDED) {
        return GateGrantedBondAction.DISCOVER_SERVICES
    }
    return when (bondState) {
        SystemBondState.NONE -> GateGrantedBondAction.START_BOND
        SystemBondState.BONDING,
        SystemBondState.UNKNOWN,
        -> GateGrantedBondAction.WAIT_FOR_BOND
        SystemBondState.BONDED -> GateGrantedBondAction.DISCOVER_SERVICES
    }
}

/**
 * 已经完成首次服务发现、但旧固件没有可执行 5403 时的防御性兼容决策。
 *
 * Android G2 正常配置会在服务发现前完成 Bond，因此通常直接继续普通 Notify；如果
 * 旧配置或 Bond 竞态仍呈现未配对，才在同一 admission/GATT 上补建系统 Bond。
 */
internal fun decideMissingSecurityGateBondAction(
    bondState: SystemBondState,
): GateGrantedBondAction = decideGateGrantedBondAction(
    initiateBinding = true,
    bondState = bondState,
)

/**
 * 消费 bond 广播时只允许 START_BINDING 中的主动配对会话推进。
 *
 * 1、成功广播恢复同一 GATT 的服务发现。
 * 2、只有明确的 BONDING -> NONE 才视为用户拒绝/系统配对失败。
 * 3、其余迟到、重复、false-config 或其它业务状态全部忽略。
 */
internal fun decideBondBroadcastAction(
    initiateBinding: Boolean,
    connectState: BleConnectState,
    bondState: SystemBondState,
    previousBondState: SystemBondState,
): BondBroadcastAction {
    if (!initiateBinding || connectState != BleConnectState.START_BINDING) {
        return BondBroadcastAction.IGNORE
    }
    if (bondState == SystemBondState.BONDED) {
        return BondBroadcastAction.DISCOVER_SERVICES
    }
    if (previousBondState == SystemBondState.BONDING && bondState == SystemBondState.NONE) {
        return BondBroadcastAction.FAIL_BINDING
    }
    return BondBroadcastAction.IGNORE
}

/**
 * createBond(false) 只表示调用瞬间未能启动；先复查 framework 状态以消除同步广播竞态。
 */
internal fun shouldFailRejectedCreateBond(
    createBondStarted: Boolean,
    connectState: BleConnectState,
    bondState: SystemBondState,
): Boolean = !createBondStarted &&
    connectState == BleConnectState.START_BINDING &&
    (bondState == SystemBondState.NONE || bondState == SystemBondState.UNKNOWN)
