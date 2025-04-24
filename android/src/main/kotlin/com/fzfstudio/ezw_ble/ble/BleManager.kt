package com.fzfstudio.ezw_ble.ble

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
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import com.fzfstudio.ezw_ble.ble.extension.toBleDevice
import com.fzfstudio.ezw_utils.extension.toHexString
import com.fzfstudio.ezw_ble.ble.models.BleCmd
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_ble.ble.models.BleConnectModel
import com.fzfstudio.ezw_ble.ble.models.BleConnectTemp
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BleMatchDevice
import com.fzfstudio.ezw_ble.ble.models.enums.BleUuidType
import com.fzfstudio.ezw_ble.ble.services.BleStateListener
import com.fzfstudio.ezw_ble.ble.services.BleStateListener.BluetoothStateCallback
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.lang.ref.WeakReference
import java.util.Timer
import java.util.TimerTask
import java.util.UUID
import java.util.regex.Pattern

class BleManager private constructor() {

    private val tag: String = "BleManager"

    companion object {
        val instance: BleManager = BleManager()
    }

    /// =========== Constants
    //  - 主线程工局
    private val mainScope by lazy {
        MainScope()
    }
    //  - 搜索配置
    private val scanSettings by lazy {
        ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
    }
    //  - 搜索回调
    private val scanCallback: ScanCallback by lazy {
        object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
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
                //  3、组装蓝牙数据
                //  - 3.1、获取SN数据
                val snRule = currentConfig.snRule
                val deviceSn = parseDataToObtainSn(result.scanRecord?.bytes)
                //  - 3.2、阻断发送到Flutter
                //  -- a、SN无法被解析的
                //  -- b、不包含标识的设备
                if (deviceSn.isEmpty() ||
                    (snRule.scanFilterMarks.isNotEmpty() && !snRule.scanFilterMarks.any { deviceSn.contains(it) })) {
                    return
                }
                //  4、发送设备到Flutter
                //  - 4.1、创建设备自定义模型对象,并缓存
                val bleDevice = device.toBleDevice(deviceSn, result.rssi)
                scanResultTemp.add(bleDevice)
                //  - 4.2、判断是否需要根据SN组合设备，不需要就直接提交
                if (snRule.matchCount < 2) {
                    sendMatchDevices(deviceSn, listOf(bleDevice))
                    return
                }
                //  - 4.3、从缓存中获取到相同的sn,
                val matchDevices = scanResultTemp.filter { it.sn == bleDevice.sn }
                //  -- 判断是否达到组合设备数量上限后，如果没有达到就不处理
                if (matchDevices.size != snRule.matchCount) {
                    return
                }
                sendMatchDevices(deviceSn, matchDevices)
            }
            override fun onBatchScanResults(results: List<ScanResult>) { Log.i(tag, "Start scan: batch = $results") }
            override fun onScanFailed(errorCode: Int) { Log.e(tag, "Start scan: error = $errorCode") }
        }
    }
    //  - 缓存已连接的设备
    private val connectedDevices: MutableList<BleDevice> = mutableListOf()
    //  - 蓝牙连接回调
    private val connectCallBacks: MutableList<Pair<String, BluetoothGattCallback>> = mutableListOf()

    /// =========== Variables
    private var weakContext: WeakReference<Context>? = null
    //  - 蓝牙管理工具
    private lateinit var bluetoothManager: BluetoothManager
    //  - 系统蓝牙状态监听
    private lateinit var bleStateListener: BleStateListener
    //  - 当前蓝牙状态,默认无状态
    private var bleState: Int = 0
    //  - 当前蓝牙权限,默认无权限
    private var blePermission: Boolean = false
    //  - 当前蓝牙定位权限，默认无权限
    private var bleLocation: Boolean = false
    //  - 当前蓝牙基础配置，必须实现
    private var currentConfig: BleConfig = BleConfig.empty()
    //  - 搜素结果临时缓存(DeviceInfo, 蓝牙对象)
    private val scanResultTemp: MutableList<BleDevice> = mutableListOf()
    //  - 待连接设备缓存（UUID，SN）
    private val waitingConnectDevices: MutableList<BleConnectTemp> = mutableListOf()
    //  - 是否正在升级中
    private val upgradeDevices: MutableList<String> = mutableListOf()

    /// =========== Get/Set
    //  - 蓝牙状态
    val currentBleState
        get() = if (!bleLocation) 6 else if (!blePermission) 3 else bleState

    //  - 蓝牙业务处理
    private val bluetoothAdapter: BluetoothAdapter
        get() = bluetoothManager.adapter

    /// =========== Method: Public

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
        if (!bluetoothAdapter.isEnabled) {
            val enableBtIntent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
            context.startActivity(enableBtIntent)
            Log.i(tag, "Init: bluetooth not enable, try enable ")
        }
        //  主动查询蓝牙工具状态
        bleState = if (bluetoothAdapter.isEnabled) 5 else 4
        //  注册监听：蓝牙状态
        bleStateListener = BleStateListener(context)
        bleStateListener.register(createBleStateListener())
        Log.i(tag, "Init: success")
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
            Log.i(tag, "Ble status listener: permission = $blePermission")
            //  2、位置信息权限
            bleLocation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                it.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED &&
                        it.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
            }
            // 在较旧版本中，不检查权限，因为 BLUETOOTH_ADMIN 是从 API 23 开始引入的
            else {
                true
            }
            Log.i(tag, "Ble status listener: location = $bleLocation")
            BleEC.BLE_STATE.event?.success(currentBleState)
            Log.i(tag, "Ble status listener: status = $currentBleState")
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
     */
    fun enableConfig(config: BleConfig) {
        this.currentConfig = config
    }

    /**
     *  开启扫描
     */
    fun startScan() {
        if (!checkIsFunctionCanBeCalled()) {
            return
        }
        //  移除历史记录
        scanResultTemp.clear()
        bluetoothAdapter.bluetoothLeScanner?.startScan(null, scanSettings, scanCallback)
        Log.i(tag, "Start scan: success")
    }

    /**
     *  停止扫描
     */
    fun stopScan() {
        if (!checkIsFunctionCanBeCalled()) {
            return
        }
        bluetoothAdapter.bluetoothLeScanner?.stopScan(scanCallback)
        Log.i(tag, "Stop scan: success")
    }

    /*
     *  连接设备
     */
    @Synchronized
    fun connect(uuid: String, sn: String, isWaitingDevice: Boolean = false, afterUpgrade: Boolean = false) {
        if (!checkIsFunctionCanBeCalled() ) {
            return
        }
        //  1、uuid为空不处理
        if (uuid.isEmpty()) {
            connectStateLog(uuid, BleConnectState.EMPTY_UUID)
            Log.w(tag,"Start connect: $uuid, Empty uuid")
            return
        }
        //  - 如果非升级模式下有升级状态的数据需要清除
        if (!afterUpgrade && upgradeDevices.contains(uuid)) {
            upgradeDevices.remove(uuid)
        }
        //  2、缓存连接对象，如果缓存中超过1个就等待考前的连接完成后再开始执行
        if (!waitingConnectDevices.any { it.uuid == uuid }) {
            waitingConnectDevices.add(BleConnectTemp(uuid, sn, afterUpgrade))
        }
        if (waitingConnectDevices.size > 1) {
            val currentIndex = waitingConnectDevices.indexOfFirst { it.uuid == uuid }
            val lastDevice = waitingConnectDevices[currentIndex - 1]
            connectStateLog(uuid, BleConnectState.CONNECTING)
            Log.w(tag,"Start connect: $uuid, waiting ${lastDevice.uuid} finish connecting")
            return
        }
        //  3、查询设备是否已经在连接缓存中
        var bleDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        //  4、获取新的连接对象
        val remoteDevice = bluetoothAdapter.getRemoteDevice(uuid)
        if (remoteDevice == null) {
            connectStateLog(uuid, BleConnectState.NO_DEVICE_FOUND)
            Log.w(tag,"Start connect: $uuid, no device found")
            return
        }
        //  5、获取BleDevice，并执行连接
        if (bleDevice == null) {
            bleDevice = remoteDevice.toBleDevice(sn, 0)
            connectedDevices.add(bleDevice)
        }
        //  6、执行连接
        val connectCallBack = createConnectCallBack()
        bleDevice.gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            remoteDevice.connectGatt(weakContext?.get(), false, connectCallBack, BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_2M)
        } else {
            remoteDevice.connectGatt(weakContext?.get(), false, connectCallBack)
        }
        //  7、读取信号值
        bleDevice.gatt?.readRemoteRssi()
        //  8、开启连接超时定时器
        val timeoutTimer = Timer()
        timeoutTimer.schedule(object : TimerTask() {
            override fun run() {
                connectStateLog(uuid, BleConnectState.TIMEOUT)
                Log.i(tag, "Start connect: $uuid, connect time out")
                disconnectDevice(uuid)
            }
        }, currentConfig.connectTimeout.toLong() + (if (afterUpgrade) currentConfig.upgradeSwapTime.toLong() else 0))
        waitingConnectDevices.firstOrNull { it.uuid == uuid }?.timeoutTimer = timeoutTimer
        //  9、待连接中的设备已经处于连接中，不再发送
        if (!isWaitingDevice) {
            connectStateLog(uuid, BleConnectState.CONNECTING)
        }
        Log.i(tag, "Start connect: $uuid, connecting, after upgrade = $afterUpgrade")
    }

    /**
     * 断连设备
     */
    fun disconnect(uuid: String) {
        if (!checkIsFunctionCanBeCalled() ) {
            return
        }
        //  1、执行设备断连
        disconnectDevice(uuid)
        connectStateLog(uuid, BleConnectState.DISCONNECT_BY_MYSELF)
        Log.i(tag, "Disconnect: $uuid, finish")
    }

    /**
     *  主动设置连接成功
     */
    fun setConnected(uuid: String) {
        if (!checkIsFunctionCanBeCalled() || uuid.isEmpty()) {
            return
        }
        connectStateLog(uuid, BleConnectState.CONNECTED)
        Log.i(tag, "Connected: $uuid, finish")
    }

    /**
     *
     *  发送数据
     *
     */
    fun sendCmd(uuid: String, data: ByteArray, isOtaCmd: Boolean = false, uuidType: BleUuidType = BleUuidType.COMMON) {
        if (!checkIsFunctionCanBeCalled() || uuid.isEmpty()) {
            return
        }
        if (upgradeDevices.contains(uuid) && !isOtaCmd) {
            Log.i(tag, "SendCmd: $uuid, Cannot send commands during upgrade")
            return
        }
        deviceSendCmd(uuid, data, uuidType)
    }

    /**
     *  进入升级模式
     */
    fun enterUpgradeState(uuid: String) {
        if (upgradeDevices.contains(uuid)) {
            return
        }
        upgradeDevices.add(uuid)
        connectStateLog(uuid, BleConnectState.UPGRADE)
        Log.i(tag, "EnterUpgradeState: $uuid Into upgrade state")
    }

    /**
     *  退出升级模式
     */
    fun quiteUpgradeState(uuid: String) {
        if (!upgradeDevices.contains(uuid)){
            return
        }
        upgradeDevices.remove(uuid)
        Log.i(tag, "QuiteUpgradeState: $uuid had quite upgrade state")
    }

    /// =========== Method: Private

    /**
     *  检查是否添加了蓝牙配置
     */
    private fun checkBleConfigIsConfigured(): Boolean {
        if (currentConfig.isEmpty()) {
            Log.e(tag, "checkBleConfigIsConfigured: Bluetooth configuration has not been configured yet")
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
        if (bleState != 5) {
            Log.e(tag, "checkIsFunctionCanBeCalled: ble status = $bleState")
            return false
        }
        if (!checkBleConfigIsConfigured()) {
            return false
        }
        return true
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
            Log.i( tag,"Ble statue listener: Original state = $state, to even state = $bleState")
            //  检查蓝牙权限
            checkBluetoothPermission()
        }

        override fun onDeviceBondStateChanged(device: BluetoothDevice, isBonded: Boolean) {
            val connectedDevice = findConnectedDevice(device.address)
            //  1、不处理非连接设备的绑定状态
            if (connectedDevice == null) {
                Log.e( tag, "Ble status listener - bond state: ${device.address} not connected device")
                return
            }
            //  2、如果没有绑定成功就结束
            if (!isBonded) {
                Log.e( tag, "Ble status listener - bond state: ${device.address} unable to bind")
                return
            }
            //  3、检查当前设备连接状态，如果出现异常就不处理
            if (connectedDevice.connectState.isError) {
                Log.i( tag, "Ble status listener - bond state: ${device.address} is ${connectedDevice.connectState}, bound failure")
                return
            }
            //  4、绑定成功就开始搜索服务
            connectedDevice.gatt?.discoverServices()
            connectStateLog(connectedDevice.uuid, BleConnectState.SEARCH_SERVICE)
            Log.i( tag, "Ble status listener - bond state: ${device.address} is bonded, start search services")
        }
    }

    /**
     *  解析数据获取SN
     */
    private fun parseDataToObtainSn(bytes: ByteArray?): String {
        var sn = ""
        //  1、获取到的数据为空直接返回空
        if (bytes == null) {
            return sn.toString()
        }
        val snRule = currentConfig.snRule
        var startIndex = snRule.startSubIndex
        if (startIndex > bytes.size) {
            startIndex = 0
        }
        var endIndex = bytes.size
        if (snRule.byteLength > 0 && endIndex > (snRule.byteLength - startIndex)) {
            endIndex = snRule.byteLength
        }
        sn = String(bytes, Charsets.UTF_8)
        sn = String(bytes.copyOfRange(startIndex, endIndex), Charsets.UTF_8)
        return replaceControlCharacters(sn)
    }

    /**
     *  正则替换字符
     */
    private fun replaceControlCharacters(preSn: String): String {
        if (currentConfig.snRule.replaceRex.isEmpty()) {
            return preSn
        }
        // 编译正则表达式
        val pattern = Pattern.compile(currentConfig.snRule.replaceRex)
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
        val matchDevice = BleMatchDevice(sn, currentConfig.name, devices)
        val json = matchDevice.toJson()
        BleEC.SCAN_RESULT.event?.success(matchDevice.toJson())
        Log.i(tag, "Send match devices: $json)")
    }

    /**
     * 连接回调
     */
    private fun createConnectCallBack() = object : BluetoothGattCallback() {
        //  连接状态监听
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val device = gatt.device
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                Log.i(tag, "Connect call back: ${device.address}, contact device, state = STATE_CONNECTED(code:2)")
                //  5、建立配对
                if (device.bondState == BluetoothDevice.BOND_BONDED) {
                    gatt.discoverServices()
                    connectStateLog(device.address, BleConnectState.SEARCH_SERVICE)
                    Log.i(tag, "Connect call back: ${device.address}, device is bonded, start search services")
                } else {
                    device.createBond()
                    Log.i(tag, "Connect call back: ${device.address}, device not bond, start binding")
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                //  移除连接对象，升级中的对象不处理
                if (upgradeDevices.contains(device.address)) {
                    return
                }
                connectCallBacks.removeAll { it.first == device.address  }
                connectStateLog(device.address, BleConnectState.DISCONNECT_FROM_SYS)
                Log.e(tag, "Connect call back: ${gatt.device.address}, state = STATE_DISCONNECTED(code:0)")
            }
        }
        //  服务发现
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val address = gatt.device.address
            //  1、获取服务失败，直接返回
            if (status != BluetoothGatt.GATT_SUCCESS) {
                connectStateLog(address, BleConnectState.SERVICE_FAIL)
                Log.e(tag, "Connect call back: $address, discover service failure")
                return
            }
            //  发现服务：
            currentConfig.uuids.forEach { uuid ->
                val service = uuid.service
                //  2、获取读/写服务
                val server = gatt.getService(uuid.serviceUUID)
                val characteristic = server?.getCharacteristic(uuid.readCharsUUID)
                if (characteristic == null) {
                    Log.e(tag, "Connect call back: $address, ${service}, characteristic service not found")
                    connectStateLog(address, BleConnectState.CHARS_FAIL)
                    return
                }
                //  3、开启读服务数据时监听
                val setCharsNotifySuccess = gatt.setCharacteristicNotification(characteristic, true)
                Log.i(tag, "Connect call back: $address, ${service}, set chars notify success = $setCharsNotifySuccess")
                //  4、开启写服务数据监听
                //  获取与给定 BluetoothGattCharacteristic 关联的描述符。描述符本质上是与特性相关的附加信息，可以包括例如 客户端配置描述符（Client Characteristic Configuration Descriptor，简称 CCCD）或 描述特性的格式、权限
                var descriptor = characteristic.getDescriptor(UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"))
                val isWrite = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS
                } else {
                    descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    gatt.writeDescriptor(descriptor)
                }
                Log.i(tag, "Connect call back: $address, ${service}, enable descriptor and write = $isWrite")
            }
            //
            val bleDevice = connectedDevices.firstOrNull { it.uuid == address }
            //  5、必须请求MTU
            val changeMtu = gatt.requestMtu(currentConfig.mtu)
            Log.i(tag, "Connect call back: $address, change mtu = ${currentConfig.mtu}, is success = $changeMtu")
            bleDevice?.gatt = gatt
            mainScope.launch {
                //  延迟200ms，避免设备没有准备好出现设备繁忙的问题
                delay(200)
                connectStateLog(address, BleConnectState.CONNECT_FINISH)
                Log.i(tag, "Connect call back: $address, connect finish")
            }
        }
        //  发送数据后回调
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            super.onCharacteristicChanged(gatt, characteristic, value)
            val bleCmdMap = BleCmd(gatt.device.address, value, true).toMap()
            mainScope.launch {
                BleEC.RECEIVE_DATA.event?.success(bleCmdMap)
                Log.i(tag, "Send cmd - replay: ${gatt.device.address}, success = true, value = ${value.toHexString()}, type = ${characteristic.writeType}")
            }
        }
    }

    /**
     * 移除连接舍比gatt数据
     */
    private fun disconnectDevice(uuid: String) {
        //  1、执行设备断连
        val connectedDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        connectedDevice?.gatt?.disconnect()
        connectedDevice?.gatt?.close()
        connectedDevice?.gatt = null
        //  2、移除待连接设备对象
        val connectTemp =  waitingConnectDevices.firstOrNull {
            it.uuid == uuid
        }
        connectTemp?.timeoutTimer?.cancel()
        connectTemp?.timeoutTimer = null
        waitingConnectDevices.remove(connectTemp)
    }

    /**
     *  连接状态打印
     */
    private fun connectStateLog(uuid: String, state: BleConnectState) {
        //  1、处理断连和错误连接
        if (state.isDisconnected || state.isError) {
            disconnectDevice(uuid)
        }
        //  2、处理连接成功
        else if (state.isConnected) {
            //  移除待连接中的对象
            waitingConnectDevices.removeAll {
                it.timeoutTimer?.cancel()
                it.timeoutTimer = null
                it.uuid == uuid
            }
        }
        //  3、非连接流程，查询是否有待连接设备，如果有就开始连接
        if (!state.isConnecting && !upgradeDevices.contains(uuid) && waitingConnectDevices.isNotEmpty()) {
            val waitingDevice = waitingConnectDevices.first()
            connect(waitingDevice.uuid, waitingDevice.sn, true, waitingDevice.afterUpgrade)
        }
        mainScope.launch {
            val connectModel = BleConnectModel(uuid, state)
            BleEC.CONNECT_STATUS.event?.success(connectModel.toJson())
        }
    }

    /**
     * 给设备发送指令
     */
    @Synchronized
    private fun deviceSendCmd(uuid: String, data: ByteArray?, uuidType: BleUuidType = BleUuidType.COMMON) {
        val connectedDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        val dataHex = data?.toHexString()
        if (connectedDevice?.gatt == null || dataHex == null) {
            BleEC.RECEIVE_DATA.event?.success(BleCmd.fail(uuid).toMap())
            Log.e(tag, "Send cmd: $uuid, $uuidType, $dataHex, gatt is null, please reconnect first")
            return
        }
        val targetUuid = currentConfig.uuids.firstOrNull { uuid -> uuid.type == uuidType }
        if (targetUuid == null) {
            BleEC.RECEIVE_DATA.event?.success(BleCmd.fail(uuid).toMap())
            Log.i(tag, "Send cmd: $uuid, $uuidType, $dataHex, can not found uuid type")
            return
        }
        val characteristic = connectedDevice.gatt!!.getService(targetUuid.serviceUUID)?.getCharacteristic(targetUuid.writeCharsUUID)
        if (characteristic == null) {
            BleEC.RECEIVE_DATA.event?.success(BleCmd.fail(uuid).toMap())
            Log.i(tag, "Send cmd: $uuid, ${targetUuid.type}|${targetUuid.service}, $dataHex, no write chars found")
            return
        }
        var isSuccess = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val status = connectedDevice.gatt!!.writeCharacteristic(characteristic, data, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
            isSuccess = status == BluetoothStatusCodes.SUCCESS
            Log.i(tag, "Send cmd: $uuid, ${targetUuid.type}|${targetUuid.service}, $dataHex, write status = $status")
        } else {
            characteristic.value = data
            isSuccess = connectedDevice.gatt!!.writeCharacteristic(characteristic)
            Log.i("BleDevice", "Send cmd: $uuid, ${targetUuid.type}|${targetUuid.service}, $dataHex, isSuccess = $isSuccess")
        }
        if (!isSuccess) {
            BleEC.RECEIVE_DATA.event?.success(BleCmd.fail(uuid).toMap())
        }
    }
}
