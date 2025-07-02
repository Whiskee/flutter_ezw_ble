//
//  BleManager.swift
//  flutter_ezw_ble
//
//  Created by Whiskee on 2025/1/3.
//

import Flutter
import CoreBluetooth
import Foundation
import flutter_ezw_utils

class BleManager: NSObject {
    
    //  使用静态常量来保证实例的唯一性
    static let shared = BleManager()
    
    //  =========== Constants
    //  - 蓝牙管理工具
    private var centralManager: CBCentralManager!
    //  - 缓存已连接的设备
    private lazy var connectedDevices: [BleConnectedDevice] = []
    
    //  =========== Variables
    //  - 蓝牙状态
    private lazy var bleState: Int = 0
    //  - 当前蓝牙基础配置，必须实现
    private lazy var bleConfigs: [BleConfig] = []
    //  - 搜素：获取结果临时缓存(DeviceInfo, 蓝牙对象)
    private lazy var scanResultTemp: [(BleDevice, CBPeripheral)] = []
    //  - 待连接设备
    private lazy var waitingConnectDevices: [BleEasyConnect] = []
    //  - 发起连接信息(所属蓝牙配置名称，UUID，设备名称, 发起时间， 是否是升级状态)
    //  -- 用于设备没能立马被发现时开启搜索，并从搜索中获取直接发起连接
    private lazy var startConnectInfos: [BleEasyConnect] = []
    //  - 连接超时定时器集合(UUID, Name, 倒计时定时器)
    private lazy var connectingTimeoutTimers: [(String, String, Timer)] = []
    //  - 是否正在升级中
    private lazy var upgradeDevices: [String]? = nil
    //  =========== Get/Set
    //  - 当前蓝牙状态
    var currentBleState: Int {
        get {
            return bleState
        }
    }
    // - flutte日志
    var logger: FlutterEventSink? {
        get {
            return BleEC.logger.event()
        }
    }
    
    //  私有化初始化方法，防止外部创建实例
    private override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
    }

}

// MARK: - Public Methods
extension BleManager {

    /**
     *  设置蓝牙配置
     */
    func initConfigs(configs: [BleConfig]) {
        self.bleConfigs = configs
    }
    
    /**
     * 开始扫描设备
     */
    func startScan() {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        stopScan(isStartScan: true)
        //  清空缓存
        scanResultTemp.removeAll()
        centralManager.scanForPeripherals(withServices: nil)
        logger?("[d]-BleManager::startScan")
    }
    
    /**
     * 停止扫描设备
     */
    func stopScan(isStartScan: Bool = false) {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        centralManager.stopScan()
        logger?("[d]-\(isStartScan ? "BleManager::stopScan: checking if scan is already running, stopping it first if necessary" : "BleManager::stopScan")")
    }
    
    /**
     *  连接设备
     *  - 注意：需要在info.list中配置NSBluetoothPeripheralUsageDescription，否则无法发起连接
     */
    func connect(easyConnect: BleEasyConnect) {
        //  1、默认功能检查
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        //  2、前置操作
        //  - 2.1、停止搜索
        stopScan()
        //  - 2.1、非升级状态需要移除升级设备
        if !easyConnect.afterUpgrade {
            upgradeDevices?.removeAll(where: {$0 == easyConnect.uuid})
        }
        //  3、获取当前配置
        guard let bleConfig = findCurrentBleConfig(belongConfig: easyConnect.belongConfig, uuid: easyConnect.uuid, name: easyConnect.name) else {
            return
        }
        //  - 3.1、获取基础的私有服务
        let commonPs = bleConfig.privateServices.first { $0.type == 0 }
        //  - 3.2、检查uuid和commonPs不能为空
        guard easyConnect.uuid.isNotEmpty || easyConnect.name.isNotEmpty, let commonPs = commonPs else {
            handleConnectState(uuid: easyConnect.uuid, name: easyConnect.name, state: .emptyUuid)
            logger?("[e]-BleManage::connect-flow: Empty uuid")
            return
        }
        //  4、缓存待连接数据
        var newEasyConnect = BleEasyConnect(
            configName: bleConfig.name,
            uuid: easyConnect.uuid,
            name: easyConnect.name,
            afterUpgrade: easyConnect.afterUpgrade,
            time: Date().timeIntervalSince1970)
        newEasyConnect.bleConfig = bleConfig
        //  -- 如果不存在就缓存起来
        if !waitingConnectDevices.contains(where: { oldEasyConect in
            oldEasyConect.uuid == easyConnect.uuid || oldEasyConect.name == easyConnect.name
        }) {
            waitingConnectDevices.append(newEasyConnect)
        }
        //  - 4.1、如果缓存对象只有一个，立马执行连接，如果没有就进入等待
        if (waitingConnectDevices.count > 1) {
            logger?("[d]-BleManage::connect-flow: \(easyConnect.uuid), will start connect when last conect finish")
            return
        }
        //  4、执行连接
        //  - 4.1、查询已连接的设备
        if let device = connectedDevices.first(where: { device in
            device.peripheral.identifier.uuidString == easyConnect.uuid || device.peripheral.name == easyConnect.name
        }) {
            newEasyConnect.uuid = device.peripheral.identifier.uuidString
            centralManager.connect(device.peripheral)
            // -- 执行连接倒计时
            startConnectingCountdown(currentConfig: bleConfig, uuid: newEasyConnect.uuid, name: newEasyConnect.name, afterUpgrade: easyConnect.afterUpgrade)
            logger?("[d]-BleManage::connect-flow: \(newEasyConnect.uuid)-\(newEasyConnect.name), from connected device list, after upgrade \(easyConnect.afterUpgrade)")
        }
        //  - 4.2、在缓存中查找对应的设备
        else if let temp = scanResultTemp.first(where: { info in
            return info.0.uuid == easyConnect.uuid || info.1.name == easyConnect.name
        }) {
            newEasyConnect.uuid = temp.1.identifier.uuidString
            centralManager.connect(temp.1)
            // -- 执行连接倒计时
            startConnectingCountdown(currentConfig: bleConfig, uuid: newEasyConnect.uuid, name: newEasyConnect.name, afterUpgrade: easyConnect.afterUpgrade)
            logger?("[d]-BleManage::connect-flow: \(newEasyConnect.uuid)-\(newEasyConnect.name), from scan resul temp, after upgrade \(easyConnect.afterUpgrade)")
        }
        //  - 4.3、获取蓝牙设置页面中是否有符合的设备
        else if let device = findPeripheralFromConnected(uuid: easyConnect.uuid, name: easyConnect.name, psUUID: commonPs.serviceUUID) {
            newEasyConnect.uuid = device.identifier.uuidString
            centralManager.connect(device)
            // -- 缓存对象
            connectedDevices.append(BleConnectedDevice(belongConfig: bleConfig, peripheral: device))
            // -- 执行连接倒计时
            startConnectingCountdown(currentConfig: bleConfig, uuid: newEasyConnect.uuid, name: newEasyConnect.name, afterUpgrade: easyConnect.afterUpgrade)
            logger?("[d]-BleManage::connect-flow: \(newEasyConnect.uuid)-\(newEasyConnect.name), from bluetooth setting, after upgrade \(easyConnect.afterUpgrade)")
        }
        //  - 4.4、通过ServiceUUID查询
        else {
            //  -- 添加待连接的设备
            startConnectInfos.append(newEasyConnect)
            //  -- 根据服务特征查询设备
            startScan()
            logger?("[d]-BleManage::connect-flow: \(newEasyConnect.uuid)-\(newEasyConnect.name), no local device found, start scan device")
        }
        handleConnectState(uuid: newEasyConnect.uuid, name: easyConnect.name, state: .connecting)
    }
    
    /**
     *  设置连接成功
     */
    func setConnected(uuid: String) {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        let connectedDevice = connectedDevices.first { device in
            device.peripheral.identifier.uuidString == uuid
        }
        updateConnectedDevice(uuid: uuid, name: connectedDevice?.peripheral.name ?? "", isConnected: true)
    }
    
    /**
     *  断连
     */
    func disconnect(uuid: String) {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        //  移除待连接设备
        waitingConnectDevices.removeAll { easyConnect in
            easyConnect.uuid == uuid
        }
        let connectedDevice = connectedDevices.first { device in
            device.peripheral.identifier.uuidString == uuid
        }
        //  执行断连
        updateConnectedDevice(uuid: uuid, name: connectedDevice?.peripheral.name ?? "", isConnected: false, updateByUser: true)
        logger?("[d]-BleManage::disconnect:\(uuid), disconnect by user")
    }
    
    /**
     *
     *  发送数据
     *
     *  - 升级中不允许发送cmd
     *
     */
    func sendCmd(uuid: String, data: Data, psType: Int = 0) {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        // 如果设备在升级中且不是OTA指令，则不允许发送
        guard upgradeDevices?.contains(where: {$0 == uuid}) != true || psType != 1 else {
            logger?("[d]-BleManage::sendCmd: \(uuid), type=\(psType), cannot send non-OTA commands during upgrade")
            return
        }
        //  通过uuid无法查询设备和特征，都被视为查找不到设备
        guard let device = connectedDevices.first(where: { device in
            device.peripheral.identifier.uuidString == uuid
        }), let writeChars = device.writeCharsDic[psType] else {
            logger?("[d]-BleManage::sendCmd: \(uuid), type=\(psType), device not found")
            return
        }
        //  根据不同uuid类型获取不同的服务特征
        device.peripheral.writeValue(data, for: writeChars, type: .withoutResponse)
        logger?("[d]-BleManage::sendCmd: \(uuid), type=\(psType), \(data.hexString())")
    }

    /**
     *  进入升级模式
     */
    func enterUpgradeState(uuid: String) {
        guard upgradeDevices?.contains(where: {$0 == uuid}) != true else {
            return
        }
        upgradeDevices?.append(uuid)
        let connectedDevice = connectedDevices.first(where: { $0.peripheral.identifier.uuidString == uuid })
        handleConnectState(uuid: uuid, name: connectedDevice?.peripheral.name ?? "", state: .upgrade)
        logger?("[d]-BleManage::enterUpgradeState: \(uuid), enter upgrade state")
    }
    
    /**
     *  退出升级模式
     */
    func quiteUpgradeState(uuid: String) {
        guard upgradeDevices?.contains(where: {$0 == uuid}) == true else {
            return
        }
        upgradeDevices?.removeAll(where: { $0 == uuid })
        let connectedDevice = connectedDevices.first(where: { $0.peripheral.identifier.uuidString == uuid })
        handleConnectState(uuid: uuid, name: connectedDevice?.peripheral.name ?? "", state: .connected)
        logger?("[d]-BleManage::quiteUpgradeState(\(uuid)): Had Quite upgrade state")
    }
}

// MARK: - Private Methods
extension BleManager {
    
    /**
     *  检查是否设置了蓝牙配置，且正确设置了基础私有服务
     */
    private func checkBleConfigIsConfigured() -> Bool {
        guard let commonPs = bleConfigs.first?.privateServices.first else {
            logger?("[d]-BleManager::checkBleConfigIsConfigured: Bluetooth configuration has not been configured or not setting private service yet")
            return false
        }
        guard commonPs.type == 0 else {
            logger?("[d]-BleManager::checkBleConfigIsConfigured: The first type of private service must be 0, where 0 represents the basic private service.")
            return false
        }
        return true
    }
    
    /**
     * 检查是否可以调用方法
     *
     * 1、检查蓝牙状态，2、检查是否启用蓝牙配置
    */
    private func checkIsFunctionCanBeCalled() -> Bool {
           if (bleState != 5) {
               logger?("[d]-BleManager::checkBleConfigIsConfigured: ble status = \(self.bleState)")
               return false
           }
           if (!checkBleConfigIsConfigured()) {
               return false
           }
           return true
       }
    
    /**
     *  查找相应的蓝牙配置
     */
    private func findCurrentBleConfig(belongConfig: String, uuid: String, name: String) -> BleConfig? {
        guard let currentConfig = bleConfigs.first(where: { config in
            config.name == belongConfig
        })  else {
            handleConnectState(uuid: uuid, name: name, state: .noBleConfigFound)
            return nil
        }
        return currentConfig
    }
    
    /**
     *  通过uuid获取蓝牙设置页面已经匹配过的设备
     */
    private func findPeripheralFromConnected(uuid: String, name: String, psUUID: CBUUID)-> CBPeripheral? {
        let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: [psUUID])
        return connectedPeripherals.first { device in
            device.identifier.uuidString == uuid || device.name == name
        }
    }
    
    
    /**
     *  解析数据获取MAC地址
     */
    private func parseDataToMac(manufactureData: Data?, macRule: BleMacRule?) -> String {
        var mac: String = ""
        //  根据SnRule截取manufacture中的数据
        if var manufactureData = manufactureData, let macRule = macRule {
            var startIndex = macRule.startIndex
            if startIndex > manufactureData.count {
                startIndex = 0
            }
            var endIndex = macRule.endIndex
            if manufactureData.count < macRule.endIndex {
                endIndex = manufactureData.endIndex
            }
            manufactureData = manufactureData.subdata(in: startIndex..<endIndex)
            var hexList = manufactureData.map {
                String(format: "%02X", $0)
            }
            if macRule.isReverse {
                hexList = hexList.reversed()
            }
            mac = hexList.joined(separator: ":")
        }
        return mac
    }
    
    
    /**
     *  解析数据获取SN
     */
    private func parseDataToObtainSn(manufactureData: Data?, snRule: BleSnRule?) -> String {
        var sn: String = ""
        //  根据SnRule截取manufacture中的数据
        if var manufactureData = manufactureData, let snRule = snRule {
            var startIndex = snRule.startSubIndex
            if startIndex > manufactureData.count {
                startIndex = 0
            }
            var endIndex = manufactureData.endIndex
            if snRule.byteLength > 0, manufactureData.count > snRule.byteLength {
                endIndex = snRule.byteLength
            }
            let subRange = startIndex..<endIndex
            manufactureData = manufactureData.subdata(in: subRange)
            sn = String(data: manufactureData, encoding: .utf8) ?? ""
        }
        return replaceControlCharacters(in: sn, snRule: snRule)
    }
    
    /**
     *  正则替换字符
     */
    private func replaceControlCharacters(in preSn: String, snRule: BleSnRule?) -> String {
        guard let snRule = snRule, snRule.replaceRex.isNotEmpty else {
            return preSn
        }
        // 创建正则表达式对象
        guard let regex = try? NSRegularExpression(pattern: snRule.replaceRex, options: []) else {
            return preSn
        }
        // 执行替换操作，用空字符串替换匹配到的字符
        let nsString = preSn as NSString
        let sn = regex.stringByReplacingMatches(in: preSn, options: [], range: NSRange(location: 0, length: nsString.length), withTemplate: "")
        return sn
    }
    
    /**
     *  本地无待连接设备信息，通过扫描获取设备并连接
     */
    private func startConnectWithoutLocalStorage(peripheral: CBPeripheral, rssi: Int) -> Bool {
        guard startConnectInfos.isNotEmpty else {
            return true
        }
        //  1、遍历执行设备连接
        for connectDevice in startConnectInfos {
            guard let bleConfig = connectDevice.bleConfig else {
                startConnectInfos.removeAll()
                stopScan()
                handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .noBleConfigFound)
                logger?("[e]-BleManager::centralManager - search: \(connectDevice.uuid)-\(connectDevice.name), no config found")
                return false
            }
            //  - 1.1、执行连接
            //  -- 1.1.2、是否可以移除
            var canRemove: Bool = false
            //  - 1.2、设置搜索超时（时间戳获取到的余数为秒）
            if Date().timeIntervalSince1970 - connectDevice.time! > bleConfig.connectTimeout / 1000 {
                handleConnectState(uuid: connectDevice.uuid, name: peripheral.name ?? "", state: .noDeviceFound)
                canRemove = true
                logger?("[d]-BleManager::centralManager - search: \(connectDevice.uuid)-\(connectDevice.name), no device found")
            }
            //  - 1.3、如果找到对应的UUID就执行连接
            else if connectDevice.uuid == peripheral.identifier.uuidString || connectDevice.name == peripheral.name! {
                //  -- 1.3.2、开始新的倒计时
                startConnectingCountdown(currentConfig: bleConfig, uuid: peripheral.identifier.uuidString, name: peripheral.name!, afterUpgrade: connectDevice.afterUpgrade)
                //  -- 默认添加到缓存中
                if !connectedDevices.contains(where: { device in
                    device.peripheral.identifier.uuidString == connectDevice.uuid || connectDevice.name == peripheral.name!
                }) {
                    connectedDevices.append(BleConnectedDevice(belongConfig: bleConfig, peripheral: peripheral))
                }
                //  -- 1.3.3、检查待连接设备的uuid是否为空，如果为空就补全
                if var easyConnect = waitingConnectDevices.first(where: { easyConnect in
                    easyConnect.uuid == peripheral.identifier.uuidString || easyConnect.name == peripheral.name
                }), easyConnect.uuid.isEmpty  {
                    easyConnect.uuid = peripheral.identifier.uuidString
                }
                //  -- 1.3.4、再次更新连接状态
                handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? connectDevice.name, state: .connecting, tag: "from search device")
                //  -- 1.3.5、开始连接
                centralManager.connect(peripheral)
                canRemove = true
                logger?("[d]-BleManager::centralManager - search: \(connectDevice.uuid)-\(connectDevice.name), device has been found, start connecting, after upgrade \(connectDevice.afterUpgrade)")
            }
            //  - 检查是否可以移除对象
            if (canRemove) {
                startConnectInfos.removeAll { info in
                    info.uuid == connectDevice.uuid || info.name == connectDevice.name
                }
                if startConnectInfos.isEmpty {
                    stopScan()
                }
            }
        }
        return false
    }
    
    /**
     *  发送配对设备到Flutter
     */
    private func sendMatchDevices(sn: String, devices: [BleDevice]) {
        //  - 4.3、将结果发送到Flutter
        let matchDevice = BleMatchDevice(sn: sn, devices: devices)
        do {
            guard let jsonDic = try matchDevice.toJsonString() else {
                return
            }
            BleEC.scanResult.event()?(jsonDic)
            logger?("[d]-BleManager::centralManager - sendMatchDevices: \(jsonDic)")
        } catch {
            logger?("[e]-BleManager::centralManager - sendMatchDevices: error = \(error)")
        }
    }
    
    /**
     *  开始连接后，执行连接超时倒计时
     */
    private func startConnectingCountdown(currentConfig: BleConfig, uuid: String, name: String, afterUpgrade: Bool) {
        //  1、检查是否存在相同的
        guard !connectingTimeoutTimers.contains(where: { info in
            info.0 == uuid || info.1 == name
        }) else {
            return
        }
        //  2、创建连接超时倒计时定时器
        let timer = Timer.scheduledTimer(withTimeInterval: (currentConfig.connectTimeout + (afterUpgrade ? currentConfig.upgradeSwapTime : 0)) / 1000, repeats: false) { [weak self] timer in
            guard self?.connectedDevices.first(where: { device in
                device.peripheral.identifier.uuidString == uuid || device.peripheral.name == name
            })?.isConnected != true else {
                return
            }
            self?.disconnect(uuid: uuid)
            self?.handleConnectState(uuid: uuid, name: name, state: .timeout)
        }
        connectingTimeoutTimers.append((uuid, name, timer))
        logger?("[d]-BleManage::connect-flow: \(uuid)-\(name), start connect time out timer")
    }
    
    /**
     *  更新缓存设备数据
     */
    private func updateConnectedDevice(uuid: String,
                                       name: String,
                                       writeChars: CBCharacteristic? = nil,
                                       readChars: CBCharacteristic? = nil,
                                       psType: Int = 0,
                                       isConnected: Bool? = nil,
                                       updateByUser: Bool = false) {
        //  1、没有缓存就不更新
        guard uuid.isNotEmpty, connectedDevices.isNotEmpty else {
            logger?("[e]-BleManager::updateConnectedDevice: \(uuid), not found device")
            return;
        }

        //  2、获取缓存设备
        guard  let index = connectedDevices.firstIndex(where: { device in
            device.peripheral.identifier.uuidString == uuid || device.peripheral.name == name
        }) else {
            handleConnectState(uuid: uuid, name: name, state: updateByUser ? .disconnectByUser : .disconnectFromSys)
            logger?("[e]-BleManager::updateConnectedDevice: \(uuid), no cache device object")
            return
        }
        //  3、更新缓存设备信息
        var connectedDevice = connectedDevices[index]
        //  - 设置写
        if let writeChars = writeChars {
            connectedDevice.writeCharsDic[psType] = writeChars
        }
        //  - 设置读
        if let readChars = readChars {
            connectedDevice.readCharsDic[psType] = readChars
            //  - 开始订阅读特征变化值，即开启接收设备数据
            connectedDevice.peripheral.setNotifyValue(true, for: readChars)
        }
        //  - 设置连接状态
        if let isConnected = isConnected {
            connectedDevice.isConnected = isConnected
            //  - 回复连接成功
            if isConnected {
                handleConnectState(uuid: uuid, name: name, state: .connected)
            }
            //  - 发起断连
            else {
                centralManager.cancelPeripheralConnection(connectedDevice.peripheral)
                handleConnectState(uuid: uuid, name: name, state: updateByUser ? .disconnectByUser : .disconnectFromSys)
            }
        }
        connectedDevices[index] = connectedDevice
        logger?("[d]-BleManager::updateConnectedDevice: \(uuid), state = \(connectedDevice.peripheral.state), device = \(connectedDevice.toString())")
    }
    
    /**
     *  连接状态打印
     */
    private func handleConnectState(uuid: String, name: String, state: BleConnectState, mtu: Int = 247, tag: String = "") {
        let fromTag = "\(tag.isNotEmpty ? " -- from: \(tag)" : "\"\"")"
        //  1、超时定时器处理
        //  - 缓存中有定时器数据
        //  - 失败或者连接成功就要停止（即非连接状态）
        if let index = connectingTimeoutTimers.firstIndex(where: { info in
            info.0 == uuid || info.1 == name
        }), !state.isConnecting() {
            //  -- 1.1、移除定时器
            let timer = connectingTimeoutTimers[index]
            timer.2.invalidate()
            connectingTimeoutTimers.remove(at: index)
            logger?("[d]-BleManage::connect-flow: \(uuid)-\(name), state = \(state.rawValue), stop connect timer \(fromTag)")
        }
        //  2、设备连接状态为失败或断连就要设置连接设备连接状态为false
        if state.isError() || state.isDisconnected(), let index = connectedDevices.firstIndex(where: { $0.peripheral.identifier.uuidString == uuid || $0.peripheral.name == name }) {
            var device = connectedDevices[index]
            device.isConnected = false
            device.readCharsNotify = 0
            connectedDevices[index] = device
            logger?("[d]-BleManage::connect-flow: \(uuid)-\(name), state = \(state) \(fromTag)")
        }
        //  3、移除待连接设备
        if !state.isConnecting() {
            //  -- 3.1、断连则移除当前待连接设备
            waitingConnectDevices.removeAll { easyConnect in
                easyConnect.uuid == uuid || easyConnect.name == name
            }
            //  -- 3.2、如果连接失败或断连，则移除所有等待连接设备
            if state.isError() {
                waitingConnectDevices.removeAll()
            }
            //  -- 3.3、如果连接成功，则连接下一个
            else if state.isConnected(), let newConnect = waitingConnectDevices.first {
                connect(easyConnect: newConnect)
            }
            //  打印待连接设备数量
            logger?("[d]-BleManage::connect-flow: \(uuid)-\(name), remove from waiting connect device list, remaining count = \(waitingConnectDevices.count) \(fromTag)")
        }
        //  3、发送连接状态
        let connectModel = BleConnectModel(uuid: uuid, name: name, connectState: state, mtu: mtu)
        let jsonString = try? connectModel.toJsonString() ?? ""
        BleEC.connectStatus.event()?(jsonString)
    }
    
    /**
     * 获取设备的 MTU 值
     */
    private func getDeviceMTU(peripheral: CBPeripheral) -> Int {
        // 方法1: 通过 maximumWriteValueLength 获取 (推荐)
        let maxWriteLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
        let attMTU = maxWriteLength + 3  // ATT_MTU = 数据载荷 + 3字节ATT头部
        logger?("[d]-BleManager::getDeviceMTU: \(peripheral.identifier.uuidString), mtu = \(attMTU), max write length = \(maxWriteLength)")
        return attMTU
    }
}


// MARK: - CBCentralManagerDelegate
extension BleManager: CBCentralManagerDelegate {
 
    /**
     *  蓝牙状态监听
     */
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bleState = central.state.rawValue
        BleEC.bleState.event()?(bleState)
        logger?("[d]-BleManager::centralManagerDidUpdateState: State = \(central.state.label), code = \(central.state.rawValue)")
    }
    
    /**
     * 设备发现回调
     */
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        //  1、过滤名称为空的对象
        guard peripheral.name?.isEmpty == false else {
            return
        }
        logger?("[d]-BleManager::centralManagerDidDiscover: name = \(String(describing: peripheral.name)), uuid = \(peripheral.identifier.uuidString), rssi = \(RSSI)")
        //  2、发起连接处理：如果startConnectUuid不为空，说明本地查询不到设备，需要通过查询获取
        guard startConnectWithoutLocalStorage(peripheral: peripheral, rssi: RSSI.intValue) else {
            return
        }
        //  3、已缓存的不再处理
        //  -- 由于已经过滤了重复项，所以不用担心会重复发送已经发送过的对象
        guard !scanResultTemp.contains(where: { info in
            info.0.uuid == peripheral.identifier.uuidString
        }) else {
            return
        }
        //  4、获取蓝牙配置：根据scan内容去筛选是匹配的设备，如果不是不进行下一步
        guard let bleConfig = bleConfigs.first(where: { config in
            config.scan.nameFilters.first { filter in
                peripheral.name?.contains(filter) == true
            } != nil
        }) else {
            return
        }
        //  5、规则解析
        let manufactureData = advertisementData["kCBAdvDataManufacturerData"] as? Data
        //  - 5.1、获取MAC地址
        let deviceMac = parseDataToMac(manufactureData: manufactureData, macRule: bleConfig.scan.macRule)
        //  - 5.2、根据SN组装蓝牙数据
        var deviceSn = peripheral.name ?? ""
        let snRule = bleConfig.scan.snRule
        if let snRule = snRule {
            deviceSn = parseDataToObtainSn(manufactureData: manufactureData, snRule: snRule)
            //  - 5.2.1、阻断发送到Flutter
            //  -- a、SN无法被解析的
            //  -- b、不包含标识的设备
            if deviceSn.isEmpty ||
                snRule.filters.isNotEmpty,
               !snRule.filters.contains(where: { mark in
                   return deviceSn.contains(mark)
               }) {
                return
            }
        }
        //  6、发送设备到Flutter
        //  - 6.1、创建设备自定义模型对象,并缓存
        let bleDevice = peripheral.toBleDevice(
            belongConfig: bleConfig.name,
            sn: deviceSn,
            rssi: RSSI.intValue,
            mac: deviceMac,
        )
        scanResultTemp.append((bleDevice, peripheral))
        //  - 6.2、判断是否需要根据SN组合设备，不需要就直接提交
        guard bleConfig.scan.matchCount > 1 else {
            sendMatchDevices(sn: deviceSn, devices: [bleDevice])
            return
        }
        //  - 6.3、从缓存中获取到相同的sn,且没有发送成功的
        let matchDevices = scanResultTemp.filter({ info in
            info.0.sn == bleDevice.sn
        }).map { info in
            info.0
        }
        //  -- 判断是否达到组合设备数量上限后，如果没有达到就不处理
        guard matchDevices.count >= bleConfig.scan.matchCount else {
            return
        }
        sendMatchDevices(sn: deviceSn, devices: matchDevices)
    }
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        logger?("[e]-BleManager::willRestoreState: \(dict)")
    }
    
    func centralManager(_ central: CBCentralManager, didUpdateANCSAuthorizationFor peripheral: CBPeripheral) {
        logger?("[e]-BleManager::didUpdateANCSAuthorizationFor")
    }
    
    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        logger?("[e]-BleManager::connectionEventDidOccur: event = \(event.rawValue)")
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) {
        logger?("[e]-BleManager::didDisconnectPeripheral: timestamp = \(timestamp), isReconnecting = \(isReconnecting), error = \(String(describing: error))")
    }
    
    /**
     * 设备连接成功回调
     */
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let tag = "didConnect"
        //  1、检查是否获取到了蓝牙配置
        guard let bleConfig = waitingConnectDevices.first(where: { easyConnect in
            easyConnect.uuid == peripheral.identifier.uuidString || easyConnect.name == peripheral.name
        })?.bleConfig else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .noBleConfigFound, tag: tag)
            return
        }
        //  2、更新已连接缓存设备信息
        let uuid = peripheral.identifier.uuidString
        connectedDevices.removeAll { device in
            device.peripheral.identifier.uuidString == uuid
        }
        connectedDevices.append(BleConnectedDevice(belongConfig: bleConfig, peripheral: peripheral))
        //  3、获取设备服务
        peripheral.delegate = self
        let services = bleConfig.privateServices.map { $0.serviceUUID }
        peripheral.discoverServices(services)
        //  4、发送日志
        handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .searchService, tag: tag)
        logger?("[d]-BleManager::didConnect: \(peripheral.identifier.uuidString)")
    }

    /**
     * 设备连接失败回调
     */
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .disconnectFromSys)
        logger?("[e]-BleManager::didFailToConnect：\(peripheral.identifier.uuidString), Error = \(String(describing: error))")
    }

    /**
     *  设备断连回调
     */
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let tag = "didDisconnect"
        //  1、获取我正在连接的设备
        guard let myDevice = connectedDevices.first(where: {$0.peripheral.identifier.uuidString == peripheral.identifier.uuidString}) else {
            logger?("[e]-BleManager::didFailToConnect: \(peripheral.identifier.uuidString), not my connected device")
            return
        }
        //  2、如果error为空，说明为用户主动操作断连
        guard let error = error as? NSError else {
            //  不执行执行断连
            //  - 已经断连就不再处理
            //  - 没有退出升级状态的不用处理
            if myDevice.isConnected {
                handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .disconnectByUser, tag: tag)
                logger?("[e]-BleManager::didFailToConnect: \(peripheral.identifier.uuidString), No error when disconnect by user")
            }
            return
        }
        //  3、设备已经被绑定
        if error.code == 14 {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .alreadyBound, tag: tag)
            logger?("[e]-BleManager::didFailToConnect: \(peripheral.identifier.uuidString), Error = alread bound")
            return
        }
        //  4、其它原因断连
        handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .disconnectFromSys, tag: tag)
        logger?("[e]-BleManager::didFailToConnect: \(peripheral.identifier.uuidString), error = \(error.localizedDescription)")
    }
    
}


// MARK: - CBPeripheralManagerDelegate
extension BleManager: CBPeripheralManagerDelegate, CBPeripheralDelegate {
    
    /**
     *  获取设备更新状态
     */
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        logger?("[d]-BleManager::peripheralManagerDidUpdateState: Peripheral manager = \(peripheral.isAdvertising), state = \(peripheral.state.rawValue)")
    }
    
    
    /**
     *  服务发现回调
     */
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let tag = "didDiscoverSerices"
        //  1、根据条件判断服务是否正常获取
        //  - 1.1、搜索服务出现异常错误
        guard error == nil else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .serviceFail, tag: tag)
            logger?("[d]-BleManager::didDiscoverServices: \(peripheral.identifier.uuidString), search service fail = \(String(describing: error))")
            return
        }
        //  - 1.2、没有查询到配置
        guard let bleConfig = waitingConnectDevices.first(where: { easyConnect in
            easyConnect.uuid == peripheral.identifier.uuidString || easyConnect.name == peripheral.name
        })?.bleConfig else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .noBleConfigFound, tag: tag)
            return
        }
        //  - 1.3、没有获取服务
        guard let services = peripheral.services else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .serviceFail, tag: tag)
            return
        }
        //  2、只获取需要注册的服务
        let myServices = services.filter { service in
            bleConfig.privateServices.contains { ps in
                ps.service == service.uuid.uuidString
            }
        }
        //  - 2.1、便利发现所有私有服务的读写特征
        myServices.forEach { service in
            peripheral.discoverCharacteristics(nil, for: service)
            logger?("[d]-BleManager::didDiscoverServices: \(peripheral.identifier.uuidString), service = \(service.uuid.uuidString)")
        }
        handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .searchChars, tag: tag)
    }
    
    /**
     *  读写特征回调
     */
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let tag = "didDiscoverCharacteristics"
        //  1、处理错误回调
        guard error == nil else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .charsFail, tag: tag)
            logger?("[e]-BleManager::didDiscoverCharacteristicsFor: \(peripheral.identifier.uuidString), error = \(String(describing: error))")
            return
        }
        //  2、获取设备所属蓝牙配置
        guard let bleConfig = waitingConnectDevices.first(where: { easyConnect in
            easyConnect.uuid == peripheral.identifier.uuidString || easyConnect.name == peripheral.name
        })?.bleConfig else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .noBleConfigFound, tag: tag)
            return
        }
        //  3、不处理不在配置中的私有服务
        guard let privateService = bleConfig.privateServices.first(where: { uuid in
            uuid.serviceUUID == service.uuid
        }) else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .charsFail, tag: tag)
            logger?("[e]-BleManager::didDiscoverCharacteristicsFor: \(peripheral.identifier.uuidString), error =  ")
            return
        }
        //  4、获取读写特征
        let writeChars = service.characteristics?.first { write in
            write.uuid == privateService.writeCharUUID
        }
        let readChars = service.characteristics?.first { read in
            read.uuid == privateService.readCharUUID
        }
        if writeChars == nil || readChars == nil {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .charsFail, tag: tag)
            logger?("[e]-BleManager::didDiscoverCharacteristicsFor: \(peripheral.identifier.uuidString), error = Chars not found")
            return
        }
        updateConnectedDevice(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", writeChars: writeChars, readChars: readChars, psType: privateService.type)
        logger?("[d]-BleManager::didDiscoverCharacteristicsFor: \(peripheral.identifier.uuidString), psType = \(privateService.type), write = \(writeChars!.uuid.uuidString), read = \(readChars!.uuid.uuidString)")
    }
    
    /**
     *  特征订阅状态
     */
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let tag = "didUpdateNotification"
        if let error = error {
            //  配对授权失败
            if let error = error as NSError?, error.domain == CBATTErrorDomain, error.code == 5 {
                handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .boundFail, tag: tag)
            }
            logger?("[e]-BleManager::update notification state: \(peripheral.identifier.uuidString), error = \(error)")
            return
        }
        //  2、获取设备所属蓝牙配置
        guard let bleConfig = waitingConnectDevices.first(where: { easyConnect in
            easyConnect.uuid == peripheral.identifier.uuidString || easyConnect.name == peripheral.name
        })?.bleConfig else {
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .noBleConfigFound, tag: tag)
            return
        }
        guard characteristic.isNotifying else {
            logger?("[e]-BleManager::update notification state: \(peripheral.identifier.uuidString), error = no notifying")
            return
        }
        //  当全部的Uuids特征信息全部获取完,且设备未连接，则发送连接流程完成
        guard let connectedIndex = connectedDevices.firstIndex(where: { device in
            device.peripheral.identifier.uuidString == peripheral.identifier.uuidString
        }) else {
            logger?("[e]-BleManager::update notification state: \(peripheral.identifier.uuidString), error = no notifying")
            return
        }
        logger?("[d]-BleManager::update notification state: \(peripheral.identifier.uuidString), chars = \(characteristic.uuid.uuidString)")
        //  检查是否可以连接
        var connectedDevice = connectedDevices[connectedIndex]
        connectedDevice.readCharsNotify += 1
        connectedDevices[connectedIndex] = connectedDevice
        if connectedDevice.isReadCharsNotifySuccess, !connectedDevice.isConnected {
            //  获取MTU
            let mtu = getDeviceMTU(peripheral: peripheral)
            handleConnectState(uuid: peripheral.identifier.uuidString, name: peripheral.name ?? "", state: .connectFinish, mtu: mtu, tag: tag)
            logger?("[d]-BleManager::update notification state: \(peripheral.identifier.uuidString), connect finish, writeCharsCount = \(connectedDevice.writeCharsDic.keys.count), ps = \(bleConfig.privateServices.count)")
        }

    }
    
    /**
     *  获取设备下发指令数据
     */
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            logger?("[e]-BleManager::cmd response: \(peripheral.identifier.uuidString), error = \(String(describing: error))")
            return
        }
        //  1、检查是否有应答数据
        guard let data = characteristic.value else {
            logger?("[e]-BleManager::cmd response: \(peripheral.identifier.uuidString), error = No data")
            return
        }
        //  2、设备是否存在并连接中
        guard let device = connectedDevices.first(where: { device in
            device.peripheral.identifier.uuidString == peripheral.identifier.uuidString
        }) else {
            logger?("[e]-BleManager::cmd response: \(peripheral.identifier.uuidString), device had already disconnected")
            return
        }
        //  3、获取对应的私有服务类型
        guard let privateService = device.belongConfig.privateServices.first(where: { uuid in
            uuid.readCharUUID == characteristic.uuid
        }) else {
            logger?("[e]-BleManager::cmd response: \(peripheral.identifier.uuidString), can not find chars")
            return
        }
        //  4、发送指令到flutter
        let bleCmdMap = BleCmd(uuid: peripheral.identifier.uuidString, psType: privateService.type, data: data, isSuccess: error == nil).toMap()
        BleEC.receiveData.event()?(bleCmdMap)
        logger?("[d]-BleManager::cmd response（char）: \(peripheral.identifier.uuidString), chars = \(characteristic.uuid.uuidString), data = \(data.hexString())")
    }
    
}
