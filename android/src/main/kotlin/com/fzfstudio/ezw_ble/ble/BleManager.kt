package com.fzfstudio.ezw_ble.ble

import BleLoggerTag
import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Context.BLUETOOTH_SERVICE
import android.content.pm.PackageManager
import android.os.Build
import com.fzfstudio.ezw_ble.ble.extension.toBleDevice
import com.fzfstudio.ezw_ble.ble.models.BleCmd
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleConnectModel
import com.fzfstudio.ezw_ble.ble.models.BleConnectTemp
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BleGatt
import com.fzfstudio.ezw_ble.ble.models.BleMatchDevice
import com.fzfstudio.ezw_ble.ble.models.BleSnRule
import com.fzfstudio.ezw_ble.ble.models.BluetoothGattStatus
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_ble.ble.services.BleStateListener
import com.fzfstudio.ezw_ble.ble.services.BleStateListener.BluetoothStateCallback
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.lang.ref.WeakReference
import java.util.Collections
import java.util.LinkedList
import java.util.Queue
import java.util.Timer
import java.util.TimerTask
import java.util.UUID
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.regex.Pattern
import kotlin.time.Duration.Companion.milliseconds
import kotlin.uuid.Uuid

class BleManager private constructor() {

    companion object {
        val instance: BleManager = BleManager()
        //  CCCD特征符号UUID
        val cccdDescriptor = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    /// =========== Constants
    //  - 主线程工局
    private val mainScope by lazy {
        MainScope()
    }
    //  - 搜索配置
    private val scanSettings by lazy {
        ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
    }
    //  - 缓存已连接的设备
    private val connectedDevices: MutableList<BleDevice> = Collections.synchronizedList(mutableListOf())
    //  - 搜素结果临时缓存(DeviceInfo, 蓝牙对象)
    private val scanResultTemp: MutableList<BleDevice> = mutableListOf()
    //  - 待连接设备缓存（UUID，SN）
    private val waitingConnectDevices: MutableList<BleConnectTemp> = mutableListOf()
    //  - 私有服务读写操作队列(私有服务类型，Descriptor)
    private val descriptorQueue: Queue<Pair<Int, BluetoothGattDescriptor>> = LinkedList()
    //  - 是否正在升级中
    private val upgradeDevices: MutableList<String> = mutableListOf()
    //  - 指令发送队列
    private val sendCmdQueue: ConcurrentLinkedQueue<BleCmd> = ConcurrentLinkedQueue()

    /// =========== Private Variables
    private var weakContext: WeakReference<Context>? = null
    //  - 蓝牙管理工具
    private lateinit var bluetoothManager: BluetoothManager
    //  - 系统蓝牙状态监听
    private lateinit var bleStateListener: BleStateListener
    //  - 蓝牙搜索状态，是否正在搜索中
    private var isScanning = false
    //  - 搜索纯净模式
    private var scanPureMode: Boolean = false
    //  - 蓝牙搜索回调
    private var scanCallback: ScanCallback? = null
    //  - 当前蓝牙状态,默认无状态
    private var bleState: Int = 0
    //  - 当前蓝牙权限,默认无权限
    private var blePermission: Boolean = false
    //  - 当前蓝牙定位权限，默认无权限
    private var bleLocation: Boolean = false
    //  - 当前蓝牙基础配置，必须实现
    private var bleConfigs: List<BleConfig> = listOf()
    //  - 正在执行断连的设备
    private var disconnectingDevices: MutableList<Pair<String, BleConnectState>> = mutableListOf()

    /// =========== Get
    //  - 蓝牙状态
    val currentBleState
        get() = if (!bleLocation) 6 else if (!blePermission) 3 else bleState
    //  - 蓝牙业务处理
    private val bluetoothAdapter: BluetoothAdapter
        get() = bluetoothManager.adapter

    /**
     * 初始化工具
     */
    fun init(context: Context) {
        weakContext = WeakReference(context)
        //  初始化蓝牙工具
        bluetoothManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.getSystemService(BluetoothManager::class.java)
        } else {
            context.getSystemService(BLUETOOTH_SERVICE) as BluetoothManager
        }
        //  主动查询蓝牙工具状态
        bleState = if (bluetoothAdapter.isEnabled) 5 else 4
        //  注册监听：蓝牙状态
        bleStateListener = BleStateListener(context)
        bleStateListener.register(createBleStateListener())
        sendLog(BleLoggerTag.d, "Init: success")
    }

    /**
     * 检查是否有蓝牙权限
     */
    fun checkBluetoothPermission() {
        weakContext?.get()?.let {
            // 1、蓝牙权限
            // Android 12 (API 31) 及以上使用 BLUETOOTH_SCAN 和 BLUETOOTH_CONNECT 权限
            blePermission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                it.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED &&
                        it.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
            }
            // 在 Android 12 之前使用 BLUETOOTH_ADMIN 权限
            else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                it.checkSelfPermission(Manifest.permission.BLUETOOTH_ADMIN) == PackageManager.PERMISSION_GRANTED
            }
            // 在较旧版本中，不检查权限，因为 BLUETOOTH_ADMIN 是从 API 23 开始引入的
            else {
                true
            }
            sendLog(BleLoggerTag.d, "Ble status listener: permission = $blePermission")
            //  2、位置信息权限
            bleLocation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                it.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED &&
                        it.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
            }
            // 在较旧版本中，不检查权限，因为 BLUETOOTH_ADMIN 是从 API 23 开始引入的
            else {
                true
            }
            BleEC.BLE_STATE.event?.success(currentBleState)
            sendLog(BleLoggerTag.d, "Ble status listener: location = $bleLocation, status = $currentBleState")
        }
    }

    /// 查找已连接的设备
    fun findConnectedDevice(uuid: String?): BleDevice? = if (uuid.isNullOrEmpty())
        null
    else
        connectedDevices.firstOrNull { it.uuid == uuid  }

    /// =========== Method: Flutter Method

    /**
     * 开启（设置）蓝牙配置
     *
     * @param newConfigs 要设置的蓝牙配置
     */
    fun initConfigs(newConfigs: List<BleConfig>) {
        bleConfigs = newConfigs
    }

    /**
     *  开启扫描
     */
    fun startScan(pureModel: Boolean = false) {
        if (!checkIsFunctionCanBeCalled() || isScanning) {
            return
        }
        //  1、是否开启纯净搜索模式
        scanPureMode = pureModel
        //  2、执行搜索先优先执行停止搜索
        stopScan()
        //  3、执行搜索
        isScanning = true
        //  4、移除历史记录
        scanResultTemp.clear()
        //  5、创建搜索回调
        scanCallback = createScanCallBack()
        //  6、开始搜索
        bluetoothAdapter.bluetoothLeScanner?.startScan(null, scanSettings, scanCallback)
        sendLog(BleLoggerTag.d, "Start scan: success")
    }

    /**
     *  停止扫描
     */
    fun stopScan(isStartScan: Boolean = false) {
        if (!checkIsFunctionCanBeCalled()) {
            return
        }
        if (scanCallback == null) {
            sendLog(BleLoggerTag.d, "Stop scan: scan call back is null")
            return
        }
        //  停止时关闭纯净模式
        scanPureMode = false
        isScanning = false
        bluetoothAdapter.bluetoothLeScanner?.stopScan(scanCallback)
        scanCallback = null
        sendLog(BleLoggerTag.d, if (isStartScan) "Stop scan: checking if scan is already running, stopping it first if necessary" else "Stop scan: success")
    }

    /*
     *  连接设备
     */
    @Synchronized
    fun connect(belongConfig: String, uuid: String, name: String, sn: String, isWaitingDevice: Boolean = false, afterUpgrade: Boolean = false, retryWhenNoFoudDevice: Boolean = true) {
        if (!checkIsFunctionCanBeCalled() ) {
            return
        }
        //  1、uuid为空不处理
        if (uuid.isEmpty()) {
            handleConnectState(uuid, name, BleConnectState.EMPTY_UUID)
            sendLog(BleLoggerTag.e, "Start connect: $uuid, Empty uuid")
            return
        }
        //  2、获取蓝牙配置
        val bleConfig = bleConfigs.firstOrNull { it.name == belongConfig }
        if (bleConfig == null) {
            handleConnectState(uuid, name, BleConnectState.NO_BLE_CONFIG_FOUND)
            sendLog(BleLoggerTag.e, "Start connect: $uuid, no config")
            return
        }
        //  3、如果非升级模式下有升级状态的数据需要清除
        if (!afterUpgrade && upgradeDevices.contains(uuid)) {
            upgradeDevices.remove(uuid)
        }
        //  4、获取新的连接对象
        val remoteDevice = bluetoothAdapter.getRemoteDevice(uuid)
        //  - bondState = 12
        sendLog(BleLoggerTag.e, "Start connect: $uuid, remote device = ${remoteDevice.name}, state = ${remoteDevice.bondState}")
        if (retryWhenNoFoudDevice && (remoteDevice == null || remoteDevice.name == null)) {
            handleConnectState(uuid, name, BleConnectState.CONNECTING)
            startScan()
            mainScope.launch {
                delay(5000)
                connect(belongConfig, uuid, name, sn, isWaitingDevice, afterUpgrade, false)
            }
            sendLog(BleLoggerTag.e, "Start connect: $uuid, can not get device from remote, start scan device to retry")
            return
        }
        if (remoteDevice == null || remoteDevice.name == null) {
            handleConnectState(uuid, name, BleConnectState.NO_DEVICE_FOUND)
            sendLog(BleLoggerTag.e, "Start connect: $uuid, no device found")
            return
        }
        //  6、缓存连接对象，如果缓存中超过1个就等待考前的连接完成后再开始执行
        if (!waitingConnectDevices.any { it.uuid == uuid }) {
            waitingConnectDevices.add(BleConnectTemp(bleConfig, uuid, name, sn, afterUpgrade))
        }
        if (waitingConnectDevices.size > 1) {
            //  - 4.1、设置待连接设备进入连接状态，并等待上一个设备完成
            handleConnectState(uuid, name, BleConnectState.CONNECTING)
            //  - 4.2、打印上一个正在连接的设备
            val lastDevice = waitingConnectDevices.firstOrNull { it.uuid != uuid }
            sendLog(BleLoggerTag.d, "Start connect: $uuid, waiting ${lastDevice?.uuid} finish connecting")
            return
        }
        //  7、查询设备是否已经在连接缓存中，如果不在就创建
        var bleDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        if (bleDevice == null) {
            bleDevice = remoteDevice.toBleDevice(bleConfig, sn, 0)
            connectedDevices.add(bleDevice)
        }
        //  8、执行连接:默认获取基础私有服务的Gatt进行处理
        val connectCallBack = createConnectCallBack()
        val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            remoteDevice.connectGatt(weakContext?.get(), false, connectCallBack, BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_2M)
        } else {
            remoteDevice.connectGatt(weakContext?.get(), false, connectCallBack)
        }
        //  - 缓存刷新的gatt
        bleDevice.gattMap[0] = BleGatt(gatt)
        //  9、读取信号值
        gatt?.readRemoteRssi()
        //  10、开启连接超时定时器
        val timeoutTimer = Timer()
        timeoutTimer.schedule(object : TimerTask() {
            override fun run() {
                sendLog(BleLoggerTag.e, "Start connect: $uuid, connect time out")
                //  1、超时断连则记录断连状态，避免系统断连导致重复执行断连状态
                disconnectingDevices.removeAll {
                    it.first == uuid
                }
                disconnectingDevices.add(Pair(uuid, BleConnectState.TIMEOUT))
                //  2、执行超时断连
                handleConnectState(uuid, name, BleConnectState.TIMEOUT)
            }
        }, bleConfig.connectTimeout.toLong() + (if (afterUpgrade) bleConfig.upgradeSwapTime.toLong() else 0),)
        waitingConnectDevices.firstOrNull { it.uuid == uuid }?.timeoutTimer = timeoutTimer
        //  11、待连接中的设备已经处于连接中，不再发送
        if (!isWaitingDevice) {
            handleConnectState(uuid, name, BleConnectState.CONNECTING)
        }
        sendLog(BleLoggerTag.d, "Start connect: $uuid connecting, belong config = ${bleDevice.belongConfig}, after upgrade = $afterUpgrade")
    }

    /**
     * 断连设备
     */
    fun disconnect(uuid: String, removeBond: Boolean = false) {
        sendLog(BleLoggerTag.d, "Star disconnect: $uuid by user")
        //  1、获取已连接设备
        val connectedDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        //  2、执行断连
        handleConnectState(uuid, connectedDevice?.name ?: "", BleConnectState.DISCONNECT_BY_USER, removeBond)
    }

    /**
     *  主动设置连接成功
     */
    fun setConnected(uuid: String) {
        if (!checkIsFunctionCanBeCalled() || uuid.isEmpty()) {
            return
        }
        sendLog(BleLoggerTag.d, "$uuid is already connected")
        val connectedDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        handleConnectState(uuid, connectedDevice?.name ?: "", BleConnectState.CONNECTED)
    }

    /**
     *
     *  发送数据
     *
     *  @param uuid 发送指令设备
     *  @param data 指令数据
     *  @param psType 私有服务类型
     *
     */
    fun sendCmd(uuid: String, data: ByteArray, psType: Int = 0) {
        if (!checkIsFunctionCanBeCalled() || uuid.isEmpty()) {
            return
        }
        if (upgradeDevices.contains(uuid) && psType != 1) {
            sendLog(BleLoggerTag.e, "Send cmd: $uuid, Cannot send commands during upgrade")
            return
        }
        sendCmdQueue.add(BleCmd(uuid, psType, data, false))
        //  如果只有一个，就立马poll出来
        if (sendCmdQueue.size == 1) {
            sendCmdQueue.poll()
            connectedDevices.firstOrNull { it.uuid == uuid }?.writeCharacteristic(data, psType)
        }
    }

    /**
     *  进入升级模式
     */
    fun enterUpgradeState(uuid: String) {
        if (upgradeDevices.contains(uuid)) {
            return
        }
        upgradeDevices.add(uuid)
        val connectedDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        handleConnectState(uuid, connectedDevice?.name ?: "", BleConnectState.UPGRADE)
        sendLog(BleLoggerTag.d, "EnterUpgradeState: $uuid Into upgrade state")
    }

    /**
     *  退出升级模式
     */
    fun quiteUpgradeState(uuid: String) {
        if (!upgradeDevices.contains(uuid)){
            return
        }
        val connectedDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        handleConnectState(uuid, connectedDevice?.name ?: "", BleConnectState.CONNECTED)
        upgradeDevices.remove(uuid)
        sendLog(BleLoggerTag.d, "QuiteUpgradeState: $uuid had quite upgrade state")
    }

    /**
     * 清除连接缓存
     */
    fun cleanConnectCache() {
        waitingConnectDevices.forEach {
            it.timeoutTimer?.cancel()
        }
        waitingConnectDevices.clear()
        disconnectingDevices.clear()
    }

    /**
     * 重置
     */
    fun reset() {
        stopScan()
        // 创建副本避免并发修改异常
        val devicesToDisconnect = connectedDevices.toList()
        devicesToDisconnect.forEach {
            disconnect(it.uuid)
        }
        connectedDevices.clear()
        scanResultTemp.clear()
        cleanConnectCache()
        descriptorQueue.clear()
        upgradeDevices.clear()
        sendCmdQueue.clear()
        disconnectingDevices.clear()
        sendLog(BleLoggerTag.d, "Reset: success")
    }

    /// =========== Method: Private

    /**
     *  检查是否添加了蓝牙配置
     */
    private fun checkBleConfigIsConfigured(): Boolean {
        val commonPs = bleConfigs.firstOrNull()?.privateServices?.firstOrNull()
        if (commonPs == null) {
            sendLog(BleLoggerTag.e, "CheckBleConfigIsConfigured: Bluetooth configuration has not been configured or not setting private service yet")
            return false
        }
        if (commonPs.type != 0) {
            sendLog(BleLoggerTag.e, "CheckBleConfigIsConfigured: The first type of private service must be 0, where 0 represents the basic private service.")
            return false
        }
        return true
    }

    /**
     * 检查蓝牙是否可用
     */
    private fun checkBleStatus(): Boolean {
        if (bleState != 5) {
            sendLog(BleLoggerTag.e, "CheckIsFunctionCanBeCalled: ble status = $bleState")
            return false
        }
        return true
    }

    /**
     * 检查是否可以调用方法
     *
     * @exception 1、检查蓝牙状态，2、检查是否启用蓝牙配置
     */
    private fun checkIsFunctionCanBeCalled(): Boolean {
        if (!checkBleStatus()) {
            return false
        }
        if (!checkBleConfigIsConfigured()) {
            return false
        }
        return true
    }

    /**
     * 检查系统蓝牙是否开启（避免在蓝牙关闭/崩溃时触发 Binder 调用导致 DeadObjectException）
     */
    private fun isBluetoothEnabled(): Boolean = try {
        bluetoothAdapter.isEnabled
    } catch (e: Exception) {
        false
    }

    /**
     * 创建蓝牙状态监听器
     */
    private fun createBleStateListener(): BluetoothStateCallback = object : BluetoothStateCallback {
        override fun onBluetoothStateChanged(state: Int) {
            //  监听获取蓝牙开关
            bleState = when (state) {
                //  蓝牙关闭
                BluetoothAdapter.STATE_OFF -> 4
                //  蓝牙开启
                BluetoothAdapter.STATE_ON -> 5
                //  错误处理
                BluetoothAdapter.ERROR -> 0
                //  不处理：正在关闭/打开
                //  BluetoothAdapter.STATE_TURNING_OFF
                //  BluetoothAdapter.STATE_TURNING_ON
                else -> return
            }
            if (bleState != 5) {
                //  清除所有升级设备数据，避免执行OTA退出时出现状态回连问题
                upgradeDevices.clear()
                //  断连所有设备: 若设备已经断连了，就不再处理，避免状态重复断连
                connectedDevices.forEach {
                    if (it.isConnected) {
                        disconnect(it.uuid)
                    }
                }
            }
            sendLog(BleLoggerTag.d, "Ble statue listener: Original state = $state, to even state = $bleState")
            //  检查蓝牙权限
            checkBluetoothPermission()
        }

        override fun onDeviceBondStateChanged(device: BluetoothDevice, isBonded: Boolean) {
            val connectedDevice = findConnectedDevice(device.address)
            //  1、不处理非连接设备的绑定状态
            if (connectedDevice == null) {
                sendLog(BleLoggerTag.e, "Ble status listener - bond state: ${device.address} not connected device")
                return
            }
            //  2、如果没有绑定成功就结束
            if (!isBonded) {
                //  - 存在已经配对过的设备，蓝牙密钥信息丢失，
                //  - 发起连接会立马返回断连或则绑定失败，导致执行了断连，此时超时连接定时器已经关闭
                //  - 但是此时服务搜索又可以执行，会使连接进入连接中，一直无法退出
                //  - 所以阻断执行boundFail的流程，等待超时关闭连接
                if (connectedDevice.connectState.isConnecting || connectedDevice.connectState.isDisconnected) {
                    return
                }
                //  - 只有连接成功后才执行搜索，确保再次连接设备时设备能被重新刷新，避免连接旧的连接信息
                mainScope.launch {
                    startScan()
                }
                sendLog(BleLoggerTag.e, "Ble status listener - bond state: ${device.address} unable to bind")
                handleConnectState(connectedDevice.uuid, connectedDevice.name, BleConnectState.BOUND_FAIL)
                return
            }
            //  3、如果眼镜已经连接了就不再执行绑定
            if (connectedDevice.connectState.isConnected) {
                sendLog(BleLoggerTag.e, "Ble status listener - bond state: ${device.address} bind success")
                return
            }
            //  4、检查当前设备连接状态，如果出现异常就不处理
            if (connectedDevice.connectState.isError) {
                sendLog(BleLoggerTag.e, "Ble status listener - bond state: ${device.address} is ${connectedDevice.connectState}, bound failure")
                handleConnectState(connectedDevice.uuid, connectedDevice.name, BleConnectState.BOUND_FAIL)
                return
            }
            //  5、主动绑定时，需要进入CONNECT_FINISH流程，如果是眼镜主动绑定，则默认进入CONNECT_FINISH
            if (connectedDevice.belongConfig.initiateBinding) {
                handleConnectState(connectedDevice.uuid, connectedDevice.name, BleConnectState.CONNECT_FINISH)
            }
            sendLog(BleLoggerTag.d, "Ble status listener - bond state: ${device.address} is bonded, state = ${connectedDevice.connectState}, finish connect")
        }
    }

    /// 创建蓝牙搜索回调
    private fun createScanCallBack(): ScanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            try {
                val device = result.device
                //  1、过滤：无名称设备
                if (device.name.isNullOrEmpty()) {
                    return
                }
                //  2、过滤已经缓存过的对象
                //  -- 由于已经过滤了重复项，所以不用担心会重复发送已经发送过的对象
                if (scanResultTemp.firstOrNull { it.uuid == device.address } != null) {
                    return
                }
                //  3、通过蓝牙配置文件中的scan获取目标设备
                val bleConfig = bleConfigs.firstOrNull { config -> config.scan.nameFilters.firstOrNull { filter ->
                    device.name.contains(filter)
                }  != null
                }
                if (bleConfig == null) {
                    return
                }
                //  4、检查是否是纯净模式
                if (scanPureMode) {
                    val deviceSn = UUID.randomUUID().toString()
                    //  - 4.1、创建设备自定义模型对象,并缓存
                    val bleDevice = device.toBleDevice(bleConfig, deviceSn, result.rssi)
                    scanResultTemp.add(bleDevice)
                    //  - 4.2、判断是否需要根据SN组合设备，不需要就直接提交
                    sendMatchDevices(deviceSn, listOf(bleDevice))
                    return
                }
                //  5、组装蓝牙数据
                var deviceSn = device.name
                //  - 5.1、获取SN数据
                val snRule = bleConfig.scan.snRule
                if (snRule != null) {
                    deviceSn = parseDataToObtainSn(result.scanRecord?.bytes, snRule)
                    //  - 5.2、阻断发送到Flutter
                    //  -- a、SN无法被解析的
                    //  -- b、不包含标识的设备
                    if (deviceSn.isEmpty() ||
                        (snRule.filters.isNotEmpty() && !snRule.filters.any { deviceSn.contains(it) })) {
                        return
                    }
                }
                //  6、发送设备到Flutter
                //  - 6.1、创建设备自定义模型对象,并缓存
                val bleDevice = device.toBleDevice(bleConfig, deviceSn, result.rssi)
                scanResultTemp.add(bleDevice)
                //  - 6.2、判断是否需要根据SN组合设备，不需要就直接提交
                if (bleConfig.scan.matchCount < 2) {
                    sendMatchDevices(deviceSn, listOf(bleDevice))
                    return
                }
                //  - 6.3、从缓存中获取到相同的sn,
                val matchDevices = scanResultTemp.filter { it.sn == bleDevice.sn }
                //  -- 判断是否达到组合设备数量上限后，如果没有达到就不处理
                if (matchDevices.size != bleConfig.scan.matchCount) {
                    return
                }
                sendMatchDevices(deviceSn, matchDevices)
            } catch (error: Exception) {
                sendLog(BleLoggerTag.e, "Start scan: scanning error = ${error.message}")
            }
        }
        override fun onBatchScanResults(results: List<ScanResult>) { sendLog(BleLoggerTag.d, "Start scan: batch = $results") }
        override fun onScanFailed(errorCode: Int) { sendLog(BleLoggerTag.e, "Start scan: error = $errorCode") }
    }

    /**
     *  解析数据获取SN
     */
    private fun parseDataToObtainSn(bytes: ByteArray?, snRule: BleSnRule): String {
        var sn = ""
        //  1、获取到的数据为空直接返回空
        if (bytes == null) {
            return sn
        }
        var startIndex = snRule.startSubIndex
        if (startIndex > bytes.size) {
            startIndex = 0
        }
        var endIndex = bytes.size
        if (snRule.byteLength > 0 && endIndex > (snRule.byteLength - startIndex)) {
            endIndex = snRule.byteLength
        }
        sn = String(bytes.copyOfRange(startIndex, endIndex), Charsets.UTF_8)
        return replaceControlCharacters(sn, snRule)
    }

    /**
     *  正则替换字符
     */
    private fun replaceControlCharacters(preSn: String, snRule: BleSnRule): String {
        if (snRule.replaceRex.isEmpty()) {
            return preSn
        }
        // 编译正则表达式
        val pattern = Pattern.compile(snRule.replaceRex)
        // 获取匹配器
        val matcher = pattern.matcher(preSn)
        // 替换所有匹配的子串
        return matcher.replaceAll("")
    }

    /**
     *  发送配对设备到Flutter
     */
    private fun sendMatchDevices(sn: String, devices: List<BleDevice>) {
        //  - 4.3、将结果发送到Flutter
        val matchDevice = BleMatchDevice(sn, devices)
        val json = matchDevice.toJson()
        BleEC.SCAN_RESULT.event?.success(matchDevice.toJson())
        sendLog(BleLoggerTag.d, "Send match devices: $json)")
    }

    /**
     * 连接回调
     */
    @OptIn(ExperimentalStdlibApi::class)
    private fun createConnectCallBack() = object : BluetoothGattCallback() {

        /// 是否服务处理状态
        private var isPsHandleFinish = false

        //  连接状态监听
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val device = gatt.device
            descriptorQueue.clear()
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                gatt.discoverServices()
                handleConnectState(device.address, device.name, BleConnectState.SEARCH_SERVICE)
                sendLog(BleLoggerTag.d, "Connect call back: ${device.address} had contact device, state = STATE_CONNECTED(code:2), start search services")
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (!isBluetoothEnabled()) {
                    sendLog(BleLoggerTag.e, "Connect call back: ${gatt.device.address}, not handle disconnect form state change, will call disconnect method in the ble state Listener")
                    return
                }
                isPsHandleFinish = false
                val myDevice = connectedDevices.firstOrNull { it.uuid == device.address  }
                if (myDevice == null)   {
                    sendLog(BleLoggerTag.e, "Connect call back: ${gatt.device.address} not my connected device, state = STATE_DISCONNECTED(code:$status)")
                    return
                }
                //  如果断连发生时已经在连接中了，就不要断连
                if (myDevice.connectState.isConnecting) {
                    sendLog(BleLoggerTag.e, "Connect call back: ${gatt.device.address} is start new connecting, stop disconnect flow, keep connecting")
                    return
                }
                //  如果断连的设备是手动断连的，就不再执行系统断连处理
                val disconnectDevice = disconnectingDevices.firstOrNull { it.first == myDevice.uuid }
                if (disconnectDevice != null) {
                    disconnectingDevices.remove(disconnectDevice)
                    sendLog(BleLoggerTag.e, "Connect call back: ${gatt.device.address} is disconnecting witch state = ${disconnectDevice.second}, stop disconnect flow form system")
                    return
                }
                //  - 执行断开连接，确保被释放
                try {
                    gatt.close()
                } catch (closeError: Exception) {
                    sendLog(BleLoggerTag.e, "Connect call back: ${gatt.device.address} close gatt exception: ${closeError.message}")
                }
                //  - 如果报授权问题，刷新gatt
                if (status == BluetoothGatt.GATT_INSUFFICIENT_AUTHORIZATION) {
                    refreshDeviceCache(gatt)
                }
                //  -- 打印
                sendLog(BleLoggerTag.e, "Connect call back: ${gatt.device.address} state = STATE_DISCONNECTED(code:${BluetoothGattStatus.getStatusDescription(status)})")
                //  -- GATT_CONN_LMP_TIMEOUT, 移除配对导致的出现的GATT_CONN_LMP_TIMEOUT，就不执行操作
                if (status == 22) {
                    return
                }
                //  -- 执行连接状态处理
                handleConnectState(device.address, device.name,BleConnectState.DISCONNECT_FROM_SYS)
            }
        }

        //  服务发现
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            //  1、获取服务所匹配的连接设备
            val address = gatt.device.address
            val name = gatt.device.name
            val currentDevice = connectedDevices.firstOrNull { it.uuid == gatt.device.address } ?: return
            //  2、获取服务失败，直接返回
            if (status != BluetoothGatt.GATT_SUCCESS) {
                handleConnectState(address, name, BleConnectState.SERVICE_FAIL)
                sendLog(BleLoggerTag.e, "Connect call back: $address, discover service failure")
                return
            }
            //  3、处理私有服务：
            //  - PrivateService是否处理状态
            isPsHandleFinish = true
            //  - 获取去设备蓝牙配置信息
            currentDevice.belongConfig.privateServices.forEach { uuid ->
                val service = uuid.service
                //  2、获取读/写服务
                val server = gatt.getService(uuid.serviceUUID)
                val writeChars = server?.getCharacteristic(uuid.writeCharsUUID)
                if (writeChars == null) {
                    sendLog(BleLoggerTag.e, "Connect call back: $address, ${service}, write characteristic not found")
                    handleConnectState(address, name,BleConnectState.CHARS_FAIL)
                    isPsHandleFinish = false
                    return
                }
                val readChars = server.getCharacteristic(uuid.readCharsUUID)
                if (readChars == null) {
                    sendLog(BleLoggerTag.e, "Connect call back: $address, ${service}, read characteristic not found")
                    handleConnectState(address, name,BleConnectState.CHARS_FAIL)
                    isPsHandleFinish = false
                    return
                }
                //  3、开启读服务数据时监听
                val setCharsNotifySuccess = gatt.setCharacteristicNotification(readChars, true)
                sendLog(BleLoggerTag.d, "Connect call back: $address, ${service}, set chars notify success = $setCharsNotifySuccess")
                //  4、开启写服务数据监听
                //  获取与给定 BluetoothGattCharacteristic 关联的描述符。描述符本质上是与特性相关的附加信息，可以包括例如 客户端配置描述符（Client Characteristic Configuration Descriptor，简称 CCCD）或 描述特性的格式、权限
                val descriptor = readChars.getDescriptor(cccdDescriptor)
                descriptorQueue.add(Pair(uuid.type, descriptor))
                //  缓存读写特征
                currentDevice.gattMap[uuid.type] = BleGatt(gatt, writeChars, readChars)
            }
            if (!isPsHandleFinish) {
                return
            }
            //  处理下一个对
            processNextDescriptor(gatt)
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt?,
            descriptor: BluetoothGattDescriptor?,
            status: Int
        ) {
            super.onDescriptorWrite(gatt, descriptor, status)
            if (!isPsHandleFinish) {
                return
            }
            sendLog(BleLoggerTag.d, "Connect call back: ${gatt?.device?.address} is descriptor write success = ${status == BluetoothGatt. GATT_SUCCESS}")
            processNextDescriptor(gatt)
        }

        //  发送数据后回调(未来会被废弃，但是目前是可以兼容所有蓝牙推送)
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt?,
            characteristic: BluetoothGattCharacteristic?
        ) {
            super.onCharacteristicChanged(gatt, characteristic)
            if (gatt == null || characteristic == null) {
                sendLog(BleLoggerTag.e, "Receive cmd: ${gatt?.device?.address} receive fail, gatt or characteristic is null")
                return
            }
            val connectedDevice = findConnectedDevice(gatt.device.address)
            //  1、获取配置中的私有服务
            val currentUuid = connectedDevice?.belongConfig?.privateServices?.firstOrNull { uuid ->
                uuid.readCharsUUID == characteristic.uuid
            }
            if (currentUuid == null) {
                sendLog(BleLoggerTag.e, "Receive cmd: ${gatt.device.address} receive fail, not found current uuid")
                return
            }
            //  2、解析数据
            val bleCmdMap = BleCmd(gatt.device.address, currentUuid.type, characteristic.value, true).toMap()
            mainScope.launch {
                BleEC.RECEIVE_DATA.event?.success(bleCmdMap)
            }
            sendLog(BleLoggerTag.d, "Receive cmd（old）: ${gatt.device.address}\n--type=${currentUuid.type}\n--length=${characteristic.value.size}\n--chartsType=${characteristic.writeType}\n--data=${characteristic.value.toHexString()}")
        }

//        //  发送数据后回调（新指令推送接口，有不兼容风险）
//        override fun onCharacteristicChanged(
//            gatt: BluetoothGatt,
//            characteristic: BluetoothGattCharacteristic,
//            value: ByteArray
//        ) {
//            super.onCharacteristicChanged(gatt, characteristic, value)
//            val connectedDevice = findConnectedDevice(gatt.device.address)
//            //  1、获取配置中的私有服务
//            val currentUuid = connectedDevice?.belongConfig?.privateServices?.firstOrNull { uuid ->
//                uuid.readCharsUUID == characteristic.uuid
//            }
//            if (currentUuid == null) {
//                sendLog(BleLoggerTag.e,"Receive cmd: ${gatt.device.address} receive fail, not found current uuid")
//                return
//            }
//            //  2、解析数据
//            val bleCmdMap = BleCmd(gatt.device.address, currentUuid.type, value, true).toMap()
//            mainScope.launch {
//                BleEC.RECEIVE_DATA.event?.success(bleCmdMap)
//            }
//            sendLog(BleLoggerTag.d,"Receive cmd（new）: ${gatt.device.address}\n--type=${currentUuid.type}\n--length=${value.size}\n--chartsType=${characteristic.writeType}\n--data=${value.toHexString()}")
//        }

        /// 写入数据回调
        override fun onCharacteristicWrite(
            gatt: BluetoothGatt?,
            characteristic: BluetoothGattCharacteristic?,
            status: Int
        ) {
            super.onCharacteristicWrite(gatt, characteristic, status)
            gatt?.device?.address?.let { uuid ->
                sendCmdQueue.poll()?.let { cmd ->
                    connectedDevices.firstOrNull { it.uuid == uuid }?.writeCharacteristic(cmd.data, cmd.psType)
                    sendLog(BleLoggerTag.d, "Send cmd: ${gatt.device.address}, write call back is success = ${status == BluetoothGatt.GATT_SUCCESS}")
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt?, mtu: Int, status: Int) {
            super.onMtuChanged(gatt, mtu, status)
            if (!isPsHandleFinish) {
                return
            }
            sendLog(BleLoggerTag.d, "Connect call back: ${gatt?.device?.address} change mtu ${if (status == BluetoothGatt. GATT_SUCCESS )  "success" else "fail"}, new mtu value = $mtu, connecting flow is finish")
            gatt?.let {
                connectingFlowFinish(it, mtu)
            }
        }

        //* ============== User Method ============== *//

        /**
         * 队列处理 - 执行Descriptor
         */
        private fun processNextDescriptor(gatt: BluetoothGatt?) {
            if (gatt == null) {
                descriptorQueue.clear()
                return
            }
            //  1、如果队列内容为空，就表示处理完成
            if (descriptorQueue.isEmpty()) {
                requestDeviceMtu(gatt)
                return
            }
            //  2、执行写特征使能
            val item = descriptorQueue.poll() ?: return
            val descriptor = item.second
            val isWrite = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS
            } else {
                descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                gatt.writeDescriptor(descriptor)
            }
            sendLog(BleLoggerTag.d, "Connect call back: ${gatt.device.address} desUuid = ${descriptor.uuid}, chars = ${descriptor.characteristic.uuid}, psType=${item.first}, enable descriptor and write = $isWrite")
        }

        /**
         * 请求设备mtu
         */
        private fun requestDeviceMtu(gatt: BluetoothGatt) {
            val device = findConnectedDevice(gatt.device.address) ?: return
            val belongConfig = device.belongConfig
            //  4、MTU大于0则发起MTU修改
            gatt.requestMtu(belongConfig.mtu)
            sendLog(BleLoggerTag.d, "Connect call back: ${device.uuid} enable all descriptor, request mtu to = ${belongConfig.mtu}")
        }

        /**
         * 连接流程执行完毕
         */
        private fun connectingFlowFinish(gatt: BluetoothGatt, mtu: Int) {
            //  1、获取链接设备
            val address = gatt.device.address
            val name = gatt.device.name
            val device = findConnectedDevice(address) ?: return
            val belongConfig = device.belongConfig
            //  6、如果是主动互动发起绑定则调用createBond，并通过绑定回调处理连接状态
            if (belongConfig.initiateBinding && gatt.device.bondState != BluetoothDevice.BOND_BONDED) {
                gatt.device.createBond()
                sendLog(BleLoggerTag.d, "Connect call back: $address, start create bond")
                handleConnectState(address!!, name,BleConnectState.START_BINDING)
                return
            }
            //  - 6.1、如果不需要则直接完成连接流程
            handleConnectState(address!!, name, BleConnectState.CONNECT_FINISH, mtu = mtu)
            sendLog(BleLoggerTag.d, "Connect call back: $address, connect finish")
        }

    }

    /**
     * 移除连接舍比gatt数据
     */
    private fun disconnectDevice(uuid: String, state: BleConnectState, removeBond: Boolean = false) {
        //  1、除了系统断连的状态，其它状态发起断连，都要加入到断连中
        if (state != BleConnectState.DISCONNECT_FROM_SYS) {
            disconnectingDevices.removeAll {
                it.first == uuid
            }
            disconnectingDevices.add(Pair(uuid, state))
        }
        //  2、获取已连接的设备并执行断连
        val connectedDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        //  - 2.1、connectedDevice 本身可能为 null，需要安全调用
        connectedDevice?.let { device ->
             //  - 如果蓝牙为开启，所有的Gatt就不会有任何连接，所以不需要断连
             device.gattMap.values.forEach { bleGatt -> 
                //  - 重命名 gatt 变量以避免与 bleGatt.gatt 混淆
                try {
                    val gatt = bleGatt.gatt
                    if (gatt != null) {
                        mainScope.launch {
                            //  会执行onConnectionStateChange
                            gatt.disconnect()
                            //  延迟释放 GATT，避免断连操作未完成导致无法释放
                            delay(300L)
                            try {
                                gatt.close()
                                sendLog(BleLoggerTag.d, "${device.name} had disconnected")
                            } catch (closeError: Exception) {
                                sendLog(BleLoggerTag.e, "Exception during gatt.close for $uuid: ${closeError.message}")
                            }
                        }
                    }
                } catch (e: Exception) {
                    sendLog(BleLoggerTag.e, "Exception during gatt.disconnect for $uuid: ${e.message}")
                }
            }
            //  - 执行移除配对
            if (removeBond) {
                removeBond(device.uuid)
            }
            device.gattMap.clear()
            sendLog(BleLoggerTag.d, "${device.name} clear all gatt")
        }
        //  3、安全移除等待连接的设备，并清理其定时器
        waitingConnectDevices.removeAll { temp ->
            if (temp.uuid == uuid) {
                temp.timeoutTimer?.cancel()
                temp.timeoutTimer = null
                true
            } else false
        }
        // 假设 sendCmdQueue 是 ConcurrentLinkedQueue
        sendCmdQueue.clear() // ConcurrentLinkedQueue.clear() 是线程安全的
    }

    /**
     *  处理连接状态
     */
    private fun handleConnectState(uuid: String, name: String, state: BleConnectState, removeBond: Boolean = false, mtu: Int = 247) {
        //  1、处理正在连接
        if (state.isConnecting) {
            disconnectingDevices.removeAll {
                it.first == uuid
            }
        }
        //  2、处理断连和错误连接
        else if (state.isDisconnected || state.isError) {
            disconnectDevice(uuid, state, removeBond)
        }
        //  3、处理连接成功
        else if (state.isConnected) {
            // 安全移除等待连接的设备，并清理其定时器
            waitingConnectDevices.removeAll {
                if (it.uuid == uuid) {
                    it.timeoutTimer?.cancel()
                    it.timeoutTimer = null
                    true
                } else false
            }
            //  从断连中设备列表中移除当前设备
            disconnectingDevices.removeAll {
                it.first == uuid
            }
        }
        //  4、非连接流程，查询是否有待连接设备，如果有就开始连接
        if (!state.isConnecting && !upgradeDevices.contains(uuid) && waitingConnectDevices.isNotEmpty()) {
            val waitingDevice = waitingConnectDevices.first()
            connect(waitingDevice.belongConfig.name, waitingDevice.uuid, waitingDevice.name, waitingDevice.sn, true, waitingDevice.afterUpgrade)
        }
        //  5、发送连接状态
        mainScope.launch {
            val connectModel = BleConnectModel(uuid,  name, state, mtu)
            BleEC.CONNECT_STATUS.event?.success(connectModel.toJson())
        }
    }

    /**
     * 清除GATT缓存信息（利用反射读取gatt中的"refresh"）
	 * Clears the internal cache and forces a refresh of the services from the
	 * remote device.
	 */
    private fun refreshDeviceCache(gatt: BluetoothGatt?): Boolean {
        gatt?.let {
            try {
                val localMethod = it.javaClass.getMethod("refresh")
                if (localMethod != null) {
                    val refresh = localMethod.invoke(it) as Boolean
                    sendLog(BleLoggerTag.d, "${gatt.device.address}-${gatt
                        .device.name} refresh gatt device cache success = $refresh")
                    return refresh
                }
            } catch (localException: Exception) {
                sendLog(BleLoggerTag.e, "${gatt.device.address}-${gatt
                    .device.name} refresh gatt device cache error: ${localException.message}")
            }
        }
        return false
    }

    /**
     *  移除配对
     */
    private fun removeBond(address: String) {
        val device: BluetoothDevice = bluetoothAdapter.getRemoteDevice(address)
        try {
            val method = device.javaClass.getMethod("removeBond")
            val result = method.invoke(device) as Boolean
            sendLog(BleLoggerTag.d, "$address, remove bond result: $result")
        } catch (e: Exception) {
            sendLog(BleLoggerTag.e, "$address, remove bond error: ${e.message}")
        }
    }

    /**
     *  处理日志
     */
    private fun sendLog(tag: BleLoggerTag, log: String) {
        mainScope.launch {
            BleEC.LOGGER.event?.success("${tag.tag}BleManager::$log")
        }
    }
}
