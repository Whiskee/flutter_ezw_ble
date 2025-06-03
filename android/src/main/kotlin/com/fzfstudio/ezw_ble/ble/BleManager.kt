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
import com.fzfstudio.ezw_ble.ble.models.BleCmd
import com.fzfstudio.ezw_ble.ble.models.BleConfig
import com.fzfstudio.ezw_ble.ble.models.BleConnectModel
import com.fzfstudio.ezw_ble.ble.models.BleConnectTemp
import com.fzfstudio.ezw_ble.ble.models.BleDevice
import com.fzfstudio.ezw_ble.ble.models.BleGatt
import com.fzfstudio.ezw_ble.ble.models.BleMatchDevice
import com.fzfstudio.ezw_ble.ble.models.BleSnRule
import com.fzfstudio.ezw_ble.ble.models.enums.BleConnectState
import com.fzfstudio.ezw_ble.ble.services.BleStateListener
import com.fzfstudio.ezw_ble.ble.services.BleStateListener.BluetoothStateCallback
import com.fzfstudio.ezw_utils.extension.toHexString
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import java.lang.ref.WeakReference
import java.util.LinkedList
import java.util.Queue
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
    //  - 缓存已连接的设备
    private val connectedDevices: MutableList<BleDevice> = mutableListOf()
    //  - 蓝牙连接回调
    private val connectCallBacks: MutableList<Pair<String, BluetoothGattCallback>> = mutableListOf()
    //  - 搜素结果临时缓存(DeviceInfo, 蓝牙对象)
    private val scanResultTemp: MutableList<BleDevice> = mutableListOf()
    //  - 待连接设备缓存（UUID，SN）
    private val waitingConnectDevices: MutableList<BleConnectTemp> = mutableListOf()
    //  - 私有服务读写操作队列(私有服务类型，Descriptor)
    private val descriptorQueue: Queue<Pair<Int, BluetoothGattDescriptor>> = LinkedList()
    //  - 是否正在升级中
    private val upgradeDevices: MutableList<String> = mutableListOf()
    //  - 指令发送队列
    private val sendCmdQueue: Queue<BleCmd> = LinkedList()

    /// =========== Private Variables
    private var weakContext: WeakReference<Context>? = null
    //  - 蓝牙管理工具
    private lateinit var bluetoothManager: BluetoothManager
    //  - 系统蓝牙状态监听
    private lateinit var bleStateListener: BleStateListener
    //  - 蓝牙搜索回调
    private var scanCallback: ScanCallback = object : ScanCallback() {
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
            //  3、通过蓝牙配置文件中的scan获取目标设备
            val bleConfig = bleConfigs.firstOrNull { config -> config.scan.nameFilters.firstOrNull { filter ->
                device.name.contains(filter)
            }  != null
            }
            if (bleConfig == null) {
                return
            }
            //  3、组装蓝牙数据
            var deviceSn = device.name
            //  - 3.1、获取SN数据
            val snRule = bleConfig.scan.snRule
            if (snRule != null) {
                deviceSn = parseDataToObtainSn(result.scanRecord?.bytes, snRule)
                //  - 3.2、阻断发送到Flutter
                //  -- a、SN无法被解析的
                //  -- b、不包含标识的设备
                if (deviceSn.isEmpty() ||
                    (snRule.filters.isNotEmpty() && !snRule.filters.any { deviceSn.contains(it) })) {
                    return
                }
            }
            //  4、发送设备到Flutter
            //  - 4.1、创建设备自定义模型对象,并缓存
            val bleDevice = device.toBleDevice(bleConfig, deviceSn, result.rssi)
            scanResultTemp.add(bleDevice)
            //  - 4.2、判断是否需要根据SN组合设备，不需要就直接提交
            if (bleConfig.scan.matchCount < 2) {
                sendMatchDevices(deviceSn, listOf(bleDevice))
                return
            }
            //  - 4.3、从缓存中获取到相同的sn,
            val matchDevices = scanResultTemp.filter { it.sn == bleDevice.sn }
            //  -- 判断是否达到组合设备数量上限后，如果没有达到就不处理
            if (matchDevices.size != bleConfig.scan.matchCount) {
                return
            }
            sendMatchDevices(deviceSn, matchDevices)
        }
        override fun onBatchScanResults(results: List<ScanResult>) { Log.i(tag, "Start scan: batch = $results") }
        override fun onScanFailed(errorCode: Int) { Log.e(tag, "Start scan: error = $errorCode") }
    }
    //  - 当前蓝牙状态,默认无状态
    private var bleState: Int = 0
    //  - 当前蓝牙权限,默认无权限
    private var blePermission: Boolean = false
    //  - 当前蓝牙定位权限，默认无权限
    private var bleLocation: Boolean = false
    //  - 当前蓝牙基础配置，必须实现
    private var bleConfigs: List<BleConfig> = listOf()

    /// =========== Public Variable
    //  - 设备回复最大的MTU
    var myMtu = 0

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
     *
     * @param newConfigs 要设置的蓝牙配置
     */
    fun initConfigs(newConfigs: List<BleConfig>) {
        bleConfigs = newConfigs
    }

    /**
     *  开启扫描
     */
    fun startScan() {
        if (!checkIsFunctionCanBeCalled()) {
            return
        }
        //  1、执行搜索先优先执行停止搜索
        stopScan()
        //  2、移除历史记录
        scanResultTemp.clear()
        //  3、执行搜索
        bluetoothAdapter.bluetoothLeScanner?.startScan(null, scanSettings, scanCallback)
        Log.i(tag, "Start scan: success")
    }

    /**
     *  停止扫描
     */
    fun stopScan(isStartScan: Boolean = false) {
        if (!checkIsFunctionCanBeCalled()) {
            return
        }
        bluetoothAdapter.bluetoothLeScanner?.stopScan(scanCallback)
        Log.i(tag, if (isStartScan) "Start scan: checking if scan is already running, stopping it first if necessary" else "Stop scan: success")
    }

    /*
     *  连接设备
     */
    @Synchronized
    fun connect(belongConfig: String, uuid: String, sn: String, isWaitingDevice: Boolean = false, afterUpgrade: Boolean = false) {
        if (!checkIsFunctionCanBeCalled() ) {
            return
        }
        //  1、uuid为空不处理
        if (uuid.isEmpty()) {
            handleConnectState(uuid, BleConnectState.EMPTY_UUID)
            Log.w(tag,"Start connect: $uuid, Empty uuid")
            return
        }
        //  2、获取蓝牙配置
        val bleConfig = bleConfigs.firstOrNull { it.name == belongConfig }
        if (bleConfig == null) {
            handleConnectState(uuid, BleConnectState.NO_BLE_CONFIG_FOUND)
            Log.w(tag,"Start connect: $uuid, no config")
            return
        }
        //  3、如果非升级模式下有升级状态的数据需要清除
        if (!afterUpgrade && upgradeDevices.contains(uuid)) {
            upgradeDevices.remove(uuid)
        }
        //  4、缓存连接对象，如果缓存中超过1个就等待考前的连接完成后再开始执行
        if (!waitingConnectDevices.any { it.uuid == uuid }) {
            waitingConnectDevices.add(BleConnectTemp(bleConfig, uuid, sn, afterUpgrade))
        }
        if (waitingConnectDevices.size > 1) {
            val currentIndex = waitingConnectDevices.indexOfFirst { it.uuid == uuid }
            val lastDevice = waitingConnectDevices[currentIndex - 1]
            handleConnectState(uuid, BleConnectState.CONNECTING)
            Log.w(tag,"Start connect: $uuid, waiting ${lastDevice.uuid} finish connecting")
            return
        }
        //  3、查询设备是否已经在连接缓存中
        var bleDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        //  4、获取新的连接对象
        val remoteDevice = bluetoothAdapter.getRemoteDevice(uuid)
        if (remoteDevice == null || remoteDevice.name == null) {
            handleConnectState(uuid, BleConnectState.NO_DEVICE_FOUND)
            Log.w(tag,"Start connect: $uuid, no device found")
            return
        }
        //  5、获取BleDevice，并执行连接
        if (bleDevice == null) {
            bleDevice = remoteDevice.toBleDevice(bleConfig, sn, 0)
            connectedDevices.add(bleDevice)
        }
        //  6、执行连接:默认获取基础私有服务的Gatt进行处理
        val connectCallBack = createConnectCallBack()
        val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            remoteDevice.connectGatt(weakContext?.get(), false, connectCallBack, BluetoothDevice.TRANSPORT_LE)
        } else {
            remoteDevice.connectGatt(weakContext?.get(), false, connectCallBack)
        }
        bleDevice.gattMap[0] = BleGatt(gatt)
        //  7、读取信号值
        gatt?.readRemoteRssi()
        //  8、开启连接超时定时器
        val timeoutTimer = Timer()
        timeoutTimer.schedule(object : TimerTask() {
            override fun run() {
                handleConnectState(uuid, BleConnectState.TIMEOUT)
                Log.i(tag, "Start connect: $uuid, connect time out")
                disconnectDevice(uuid)
            }
        }, bleConfig.connectTimeout.toLong() + (if (afterUpgrade) bleConfig.upgradeSwapTime.toLong() else 0),)
        waitingConnectDevices.firstOrNull { it.uuid == uuid }?.timeoutTimer = timeoutTimer
        //  9、待连接中的设备已经处于连接中，不再发送
        if (!isWaitingDevice) {
            handleConnectState(uuid, BleConnectState.CONNECTING)
        }
        Log.i(tag, "Start connect: $uuid connecting, belong config = ${bleDevice.belongConfig}, after upgrade = $afterUpgrade")
    }

    /**
     * 断连设备
     */
    fun disconnect(uuid: String) {
        if (!checkIsFunctionCanBeCalled() ) {
            return
        }
        //  1、执行设备断连
        handleConnectState(uuid, BleConnectState.DISCONNECT_BY_MYSELF)
        Log.i(tag, "Disconnect: $uuid, finish")
    }

    /**
     *  主动设置连接成功
     */
    fun setConnected(uuid: String) {
        if (!checkIsFunctionCanBeCalled() || uuid.isEmpty()) {
            return
        }
        handleConnectState(uuid, BleConnectState.CONNECTED)
        Log.i(tag, "Connected: $uuid, finish")
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
        if (upgradeDevices.contains(uuid) && psType == 1) {
            Log.i(tag, "Send cmd: $uuid, Cannot send commands during upgrade")
            return
        }
        sendCmdQueue.add(BleCmd(uuid, psType, data, false))
        //  如果只有一个，就立马poll出来
        if (sendCmdQueue.size == 1) {
            sendCmdQueue.poll()
            connectedDevices.firstOrNull { it.uuid == uuid }?.writeCharacteristic(data, psType)
        }
        Log.i(tag, "Send cmd: $uuid\n--type=$psType\n--length=${data.size}\n--data=${data.toHexString()}")
    }

    /**
     *  进入升级模式
     */
    fun enterUpgradeState(uuid: String) {
        if (upgradeDevices.contains(uuid)) {
            return
        }
        upgradeDevices.add(uuid)
        handleConnectState(uuid, BleConnectState.UPGRADE)
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
        val commonPs = bleConfigs.first().privateServices.firstOrNull()
        if (commonPs == null) {
            Log.e(tag, "CheckBleConfigIsConfigured: Bluetooth configuration has not been configured or not setting private service yet")
            return false
        }
        if (commonPs.type != 0) {
            Log.e(tag, "CheckBleConfigIsConfigured: The first type of private service must be 0, where 0 represents the basic private service.")
            return false
        }
        return true
    }

    /**
     * 检查蓝牙是否可用
     */
    private fun checkBleStatus(): Boolean {
        if (bleState != 5) {
            Log.e(tag, "CheckIsFunctionCanBeCalled: ble status = $bleState")
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
                handleConnectState(connectedDevice.uuid, BleConnectState.BOUND_FAIL)
                return
            }
            //  3、检查当前设备连接状态，如果出现异常就不处理
            if (connectedDevice.connectState.isError) {
                Log.i( tag, "Ble status listener - bond state: ${device.address} is ${connectedDevice.connectState}, bound failure")
                handleConnectState(connectedDevice.uuid, BleConnectState.BOUND_FAIL)
                return
            }
            //  4、主动绑定时，需要进入CONNECT_FINISH流程，如果是眼镜主动绑定，则默认进入CONNECT_FINISH
            if (connectedDevice.belongConfig.initiateBinding) {
                handleConnectState(connectedDevice.uuid, BleConnectState.CONNECT_FINISH)
            }
            Log.i( tag, "Ble status listener - bond state: ${device.address} is bonded, ${connectedDevice.myGatt}, finish connect")
        }
    }

    /**
     *  解析数据获取SN
     */
    private fun parseDataToObtainSn(bytes: ByteArray?, snRule: BleSnRule): String {
        var sn = ""
        //  1、获取到的数据为空直接返回空
        if (bytes == null) {
            return sn.toString()
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
        Log.i(tag, "Send match devices: $json)")
    }

    /**
     * 连接回调
     */
    private fun createConnectCallBack() = object : BluetoothGattCallback() {

        /// 是否服务处理状态
        private var isPsHandleFinish = true

        //  连接状态监听
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val device = gatt.device
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                gatt.discoverServices()
                handleConnectState(device.address, BleConnectState.SEARCH_SERVICE)
                Log.i(tag, "Connect call back: ${device.address}, had contact device, state = STATE_CONNECTED(code:2), start search services")
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                //  升级中的对象不处理
                if (upgradeDevices.contains(device.address)) {
                    return
                }
                connectCallBacks.removeAll { it.first == device.address  }
                handleConnectState(device.address, BleConnectState.DISCONNECT_FROM_SYS)
                Log.e(tag, "Connect call back: ${gatt.device.address}, state = STATE_DISCONNECTED(code:0)")
            }
        }

        //  服务发现
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            //  1、获取服务所匹配的连接设备
            val address = gatt.device.address
            val currentDevice = connectedDevices.firstOrNull { it.uuid == gatt.device.address } ?: return
            //  2、获取服务失败，直接返回
            if (status != BluetoothGatt.GATT_SUCCESS) {
                handleConnectState(address, BleConnectState.SERVICE_FAIL)
                Log.e(tag, "Connect call back: $address, discover service failure")
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
                    Log.e(tag, "Connect call back: $address, ${service}, write characteristic not found")
                    handleConnectState(address, BleConnectState.CHARS_FAIL)
                    isPsHandleFinish = false
                    return
                }
                val readChars = server.getCharacteristic(uuid.readCharsUUID)
                if (readChars == null) {
                    Log.e(tag, "Connect call back: $address, ${service}, read characteristic not found")
                    handleConnectState(address, BleConnectState.CHARS_FAIL)
                    isPsHandleFinish = false
                    return
                }
                //  3、开启读服务数据时监听
                val setCharsNotifySuccess = gatt.setCharacteristicNotification(readChars, true)
                Log.i(tag, "Connect call back: $address, ${service}, set chars notify success = $setCharsNotifySuccess")
                //  4、开启写服务数据监听
                //  获取与给定 BluetoothGattCharacteristic 关联的描述符。描述符本质上是与特性相关的附加信息，可以包括例如 客户端配置描述符（Client Characteristic Configuration Descriptor，简称 CCCD）或 描述特性的格式、权限
                val descriptor = readChars.getDescriptor(UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"))
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
            Log.i(tag, "Connect call back: ${gatt?.device?.address}, is descriptor write success = ${status == BluetoothGatt. GATT_SUCCESS}")
            processNextDescriptor(gatt)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int
        ) {
            super.onCharacteristicRead(gatt, characteristic, value, status)
            Log.i(tag, "Connect call back: ${gatt.device.address}, read uuid = ${characteristic.uuid}, read chars value = ${value.toHexString()}, status = $status")
        }

        //  发送数据后回调
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            super.onCharacteristicChanged(gatt, characteristic, value)
            mainScope.launch {
                val connectedDevice = findConnectedDevice(gatt.device.address)
                //  1、获取配置中的私有服务
                val currentUuid = connectedDevice?.belongConfig?.privateServices?.firstOrNull { uuid ->
                    uuid.readCharsUUID == characteristic.uuid
                }
                if (currentUuid == null) {
                    Log.i(tag, "Receive cmd: ${gatt.device.address} receive fail, not found current uuid")
                    return@launch
                }
                //  2、解析数据
                val bleCmdMap = BleCmd(gatt.device.address, currentUuid.type, value, true).toMap()
                BleEC.RECEIVE_DATA.event?.success(bleCmdMap)
                Log.i(tag, "Receive cmd: ${gatt.device.address}\n--type=${currentUuid.type}\n--length=${value.size}\n--chartsType=${characteristic.writeType}\n--data=${value.toHexString()}")
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt?,
            characteristic: BluetoothGattCharacteristic?,
            status: Int
        ) {
            super.onCharacteristicWrite(gatt, characteristic, status)
            val address = gatt?.device?.address
            if (address.isNullOrEmpty()) {
                sendCmdQueue.clear()
                return
            }
            sendCmdQueue.poll()?.let { cmd ->
                connectedDevices.firstOrNull { it.uuid == address }?.writeCharacteristic(cmd.data, cmd.psType)
            }
            Log.i(tag, "Send cmd: ${gatt.device.address}, write is success = ${status == BluetoothGatt.GATT_SUCCESS}")
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
            val item = descriptorQueue.poll()
            val descriptor = item!!.second
            val isWrite = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS
            } else {
                descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                gatt.writeDescriptor(descriptor)
            }
            Log.i(tag, "Connect call back: ${gatt.device.address}, psType=${item.first}, enable descriptor and write = $isWrite")
        }

        override fun onMtuChanged(gatt: BluetoothGatt?, mtu: Int, status: Int) {
            super.onMtuChanged(gatt, mtu, status)
            Log.i(tag, "Connect call back: ${gatt?.device?.address}, change mtu ${if (status == BluetoothGatt. GATT_SUCCESS )  "success" else "fail"}, new mtu value = $mtu, connecting flow is finish")
            gatt?.let {
                connectingFlowFinish(it, mtu)
            }
        }

        /**
         * 请求设备mtu
         */
        private fun requestDeviceMtu(gatt: BluetoothGatt) {
            val device = findConnectedDevice(gatt.device.address)
            if (device == null) {
                return
            }
            val belongConfig = device.belongConfig
            //  4、MTU大于0则发起MTU修改
            gatt.requestMtu(belongConfig.mtu)
            Log.i(tag, "Connect call back: ${device.uuid}, enable all descriptor, request mtu to = ${belongConfig.mtu}")
        }

        /**
         * 连接流程执行完毕
         */
        private fun connectingFlowFinish(gatt: BluetoothGatt, mtu: Int) {
            //  1、获取链接设备
            val address = gatt.device.address
            val device = findConnectedDevice(address)
            if (device == null) {
                return
            }
            val belongConfig = device.belongConfig
            //  6、如果是主动互动发起绑定则调用createBond，并通过绑定回调处理连接状态
            if (belongConfig.initiateBinding && gatt.device.bondState != BluetoothDevice.BOND_BONDED) {
                gatt.device.createBond()
                Log.i(tag, "Connect call back: $address, start create bond")
                handleConnectState(address!!, BleConnectState.START_BINDING)
                return
            }
            //  - 6.1、如果不需要则直接完成连接流程
            handleConnectState(address!!, BleConnectState.CONNECT_FINISH, mtu = mtu)
            Log.i(tag, "Connect call back: $address, connect finish")
        }

    }

    /**
     * 移除连接舍比gatt数据
     */
    private fun disconnectDevice(uuid: String) {
        //  1、执行设备断连
        val connectedDevice = connectedDevices.firstOrNull { it.uuid == uuid }
        //  - 1.1、断连所有GATT
        connectedDevice?.gattMap?.values?.forEach { gatt ->
            gatt.gatt?.disconnect()
            gatt.gatt?.close()
        }
        connectedDevice?.gattMap?.clear()
        //  2、移除待连接设备对象
        val connectTemp =  waitingConnectDevices.firstOrNull {
            it.uuid == uuid
        }
        connectTemp?.timeoutTimer?.cancel()
        connectTemp?.timeoutTimer = null
        waitingConnectDevices.remove(connectTemp)
        //  清楚剩余所有队列数据
        sendCmdQueue.clear()
    }

    /**
     *  处理连接状态
     */
    private fun handleConnectState(uuid: String, state: BleConnectState, mtu: Int = 512) {
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
            connect(waitingDevice.belongConfig.name, waitingDevice.uuid, waitingDevice.sn, true, waitingDevice.afterUpgrade)
        }
        mainScope.launch {
            val connectModel = BleConnectModel(uuid, state, mtu)
            BleEC.CONNECT_STATUS.event?.success(connectModel.toJson())
        }
    }

}
