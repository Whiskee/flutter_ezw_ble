//
//  BleManager.swift
//  EvenConnect
//
//  Created by Whiskee on 2025/1/3.
//

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
    private lazy var currentConfig: BleConfig = BleConfig.empty()
    //  - 搜素结果临时缓存(DeviceInfo, 蓝牙对象)
    private lazy var scanResultTemp: [(BleDevice, CBPeripheral)] = []
    //  - 发起连接信息(UUID, 发起时间, 是否是升级状态)
    private lazy var startConnectInfos: [(String, TimeInterval, Bool)] = []
    //  - 连接超时定时器集合
    private lazy var connectingTimeoutTimers: [(String, Timer)] = []
    //  - 是否正在升级中
    private lazy var upgradeDevices: [String]? = nil
    //  =========== Get/Set
    var currentBleState: Int {
        get {
            return bleState
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
     *  根据Tag，启用蓝牙配置
     */
    func enableConfig(config: BleConfig) {
        currentConfig = config
    }
    
    /**
     * 开始扫描设备
     */
    func startScan() {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        //  清空缓存
        scanResultTemp.removeAll()
        centralManager.scanForPeripherals(withServices: nil)
        logger.info("BleManager::startScan")
    }
    
    /**
     * 停止扫描设备
     */
    func stopScan() {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        centralManager.stopScan()
        logger.info("BleManager::stopScan")
    }
    
    /**
     *  连接设备
     *  - 注意：需要在info.list中配置NSBluetoothPeripheralUsageDescription，否则无法发起连接
     */
    func connect(uuid: String, afterUpgrade: Bool = false) {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        //  1、uuid为空不处理
        guard !uuid.isEmpty else {
            connectStateLog(uuid: uuid, state: .emptyUuid)
            logger.error("BleManage::connect: Empty uuid")
            return
        }
        //  2、停止扫描,移除升级状态
        if startConnectInfos.isEmpty {
            stopScan()
        }
        if !afterUpgrade {
            upgradeDevices?.removeAll(where: {$0 == uuid})
        }
        //  3、执行连接
        //  - 3.1、查询已连接的设备
        if let device = connectedDevices.first(where: { device in
            device.peripheral.identifier.uuidString == uuid
        }) {
            centralManager.connect(device.peripheral)
            // -- 执行连接倒计时
            startConnectingCountdown(uuid: uuid, afterUpgrade: afterUpgrade)
            logger.info("BleManage::connect(\(uuid)): From connected device list, after upgrade \(afterUpgrade)")
        }
        //  - 3.2、在缓存中查找对应的设备
        else if let temp = scanResultTemp.first(where: { info in
            return info.0.uuid == uuid
        }) {
            centralManager.connect(temp.1)
            // -- 执行连接倒计时
            startConnectingCountdown(uuid: uuid, afterUpgrade: afterUpgrade)
            logger.info("BleManage::connect(\(uuid)): From scan resul temp, after upgrade \(afterUpgrade)")
        }
        //  - 3.3、获取蓝牙设置页面中是否有符合的设备
        else if let device = findPeripheralFromConnected(uuidStr: uuid) {
            centralManager.connect(device)
            // -- 缓存对象
            connectedDevices.append(BleConnectedDevice(peripheral: device))
            // -- 执行连接倒计时
            startConnectingCountdown(uuid: uuid, afterUpgrade: afterUpgrade)
            logger.info("BleManage::connect(\(uuid)): From bluetooth setting, after upgrade \(afterUpgrade)")
        }
        //  - 3.4、通过ServiceUUID查询
        else {
            //  -- 添加待连接的设备
            startConnectInfos.append((uuid, Date().timeIntervalSince1970, afterUpgrade))
            //  -- 根据服务特征查询设备
            startScan()
            logger.info("BleManage::connect(\(uuid)): No local device found, start scan device")
        }
        connectStateLog(uuid: uuid, state: .connecting)
    }
    
    /**
     *  设置连接成功
     */
    func setConnected(uuid: String) {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        updateConnectedDevice(uuid: uuid, isConnected: true)
    }
    
    /**
     *  断连
     */
    func disconnect(uuid: String) {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        updateConnectedDevice(uuid: uuid, isConnected: false, updateByUser: true)
        logger.info("BleManage::disconnect(\(uuid): Disconnect by user")
    }
    
    /**
     *
     *  发送数据
     *
     *  - 升级中不允许发送cmd
     *
     */
    func sendCmd(uuid: String, data: Data, uuidType: BleUuidType = .common) {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        // 如果设备在升级中且不是OTA指令，则不允许发送
        guard upgradeDevices?.contains(where: {$0 == uuid}) != true || uuidType.isOta else {
            logger.info("BleManage::sendCmd: \(uuid), cannot send non-OTA commands during upgrade")
            return
        }
        //  通过uuid无法查询设备和特征，都被视为查找不到设备
        guard let device = connectedDevices.first(where: { device in
            device.peripheral.identifier.uuidString == uuid
        }), let writeChars = device.writeCharsDic[uuidType] else {
            logger.info("BleManage::sendCmd: \(uuid), device not found")
            return
        }
        //  根据不同uuid类型获取不同的服务特征
        device.peripheral.writeValue(data, for: writeChars, type: .withoutResponse)
        logger.info("BleManage::sendCmd(\(uuid)): \(data.hexString())")
    }
        
    /**
     *  进入升级模式
     */
    func enterUpgradeState(uuid: String) {
        guard upgradeDevices?.contains(where: {$0 == uuid}) != true else {
            return
        }
        upgradeDevices?.append(uuid)
        connectStateLog(uuid: uuid, state: .upgrade)
        logger.info("BleManage::enterUpgradeState: \(uuid), enter upgrade state")
    }
    
    /**
     *  退出升级模式
     */
    func quiteUpgradeState(uuid: String) {
        guard upgradeDevices?.contains(where: {$0 == uuid}) == true else {
            return
        }
        upgradeDevices?.removeAll(where: { $0 == uuid })
        connectStateLog(uuid: uuid, state: .connected)
        logger.info("BleManage::quiteUpgradeState(\(uuid)): Had Quite upgrade state")
    }
}

// MARK: - Private Methods
extension BleManager {
    
    /**
     *  检查是否添加了蓝牙配置
     */
    private func checkBleConfigIsConfigured() -> Bool {
        let isEnableConfig = !currentConfig.isEmpty()
        if !isEnableConfig {
            logger.info("BleManager::checkBleConfigIsConfigured: Bluetooth configuration has not been configured yet")
        }
        return isEnableConfig
    }
    
    /**
     * 检查是否可以调用方法
     *
     * 1、检查蓝牙状态，2、检查是否启用蓝牙配置
    */
    private func checkIsFunctionCanBeCalled() -> Bool {
           if (bleState != 5) {
               logger.info("BleManager::checkBleConfigIsConfigured: ble status = \(self.bleState)")
               return false
           }
           if (!checkBleConfigIsConfigured()) {
               return false
           }
           return true
       }
    
    /**
     *  通过uuid获取蓝牙设置页面已经匹配过的设备
     */
    private func findPeripheralFromConnected(uuidStr: String)-> CBPeripheral? {
        let commonUuid = currentConfig.uuids.first {$0.type == .common }!
        let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: [commonUuid.serviceUUID])
        return connectedPeripherals.first { device in
            device.identifier.uuidString == uuidStr
        }
    }
    
    /**
     *  解析数据获取MAC地址
     */
    private func parseDataToMac(manufactureData: Data?) -> String {
        var mac: String = ""
        //  根据SnRule截取manufacture中的数据
        if var manufactureData = manufactureData, let macRule = currentConfig.macRule {
            var startIndex = macRule.startIndex
            if startIndex > manufactureData.count {
                startIndex = 0
            }
            var endIndex = macRule.endIndex
            if manufactureData.count > macRule.endIndex {
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
    private func parseDataToObtainSn(manufactureData: Data?) -> String {
        var sn: String = ""
        //  根据SnRule截取manufacture中的数据
        if var manufactureData = manufactureData {
            var startIndex = currentConfig.snRule.startSubIndex
            if startIndex > manufactureData.count {
                startIndex = 0
            }
            var endIndex = manufactureData.endIndex
            if currentConfig.snRule.byteLength > 0, manufactureData.count > currentConfig.snRule.byteLength {
                endIndex = currentConfig.snRule.byteLength
            }
            let subrange = startIndex..<endIndex
            manufactureData = manufactureData.subdata(in: subrange)
            sn = String(data: manufactureData, encoding: .utf8) ?? ""
        }
        return replaceControlCharacters(in: sn)
    }
    
    /**
     *  正则替换字符
     */
    private func replaceControlCharacters(in preSn: String) -> String {
        guard currentConfig.snRule.replaceRex.isNotEmpty else {
            return preSn
        }
        // 创建正则表达式对象
        guard let regex = try? NSRegularExpression(pattern: currentConfig.snRule.replaceRex, options: []) else {
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
        //  执行设备连接
        for connectDevice in startConnectInfos {
            let connectUuid: String = connectDevice.0
            var canRemove: Bool = false
            //  - 设置搜索超时（时间戳获取到的余数为秒）
            if Date().timeIntervalSince1970 - connectDevice.1 > currentConfig.connectTimeout / 1000 {
                connectStateLog(uuid: connectUuid, state: .noDeviceFound)
                canRemove = true
                logger.info("BleManager::centralManager - search: \(connectUuid), no device found")
            }
            //  - 如果找到对应的UUID就执行连接
            else if connectDevice.0 == peripheral.identifier.uuidString {
                centralManager.connect(peripheral)
                startConnectingCountdown(uuid: connectUuid, afterUpgrade: connectDevice.2)
                //  默认添加到缓存中
                if !connectedDevices.contains(where: { device in
                    device.peripheral.identifier.uuidString == peripheral.identifier.uuidString
                }) {
                    connectedDevices.append(BleConnectedDevice(peripheral: peripheral))
                }
                canRemove = true
                logger.info("BleManager::centralManager - search: \(connectUuid), device has been found, start connecting, after upgrade \(connectDevice.2)")
            }
            //  - 检查是否可以移除对象
            if (canRemove) {
                startConnectInfos.removeAll { info in
                    info.0 == connectUuid
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
        let matchDevice = BleMatchDevice(sn: sn, belongConfig: currentConfig.name, devices: devices)
        do {
            guard let jsonDic = try matchDevice.toJsonString() else {
                return
            }
            BleEC.scanResult.event()?(jsonDic)
            logger.info("BleManager::centralManager - sendMatchDevices: \(jsonDic)")
        } catch {
            logger.error("BleManager::centralManager - sendMatchDevices: \(error)")
        }
    }
    
    /**
     *  开始连接后，执行连接超时倒计时
     */
    private func startConnectingCountdown(uuid: String, afterUpgrade: Bool) {
        //  1、检查是否存在相同的
        guard !connectingTimeoutTimers.contains(where: { info in
            info.0 == uuid
        }) else {
            return
        }
        //  2、创建连接超时倒计时定时器
        let timer = Timer.scheduledTimer(withTimeInterval: (currentConfig.connectTimeout + (afterUpgrade ? currentConfig.upgradeSwapTime : 0)) / 1000, repeats: false) { [weak self] timer in
            guard self?.connectedDevices.first(where: { device in
                device.peripheral.identifier.uuidString == uuid
            })?.isConnected != true else {
                return
            }
            self?.disconnect(uuid: uuid)
            self?.connectStateLog(uuid: uuid, state: .timeout)
        }
        connectingTimeoutTimers.append((uuid, timer))
        logger.info("BleManage::connect(\(uuid)): Start connect time out timer")
    }
    
    /**
     *  更新缓存设备数据
     */
    private func updateConnectedDevice(uuid: String,
                                       peripheral: CBPeripheral? = nil,
                                       writeChars: CBCharacteristic? = nil,
                                       readChars: CBCharacteristic? = nil,
                                       uuidType: BleUuidType = .common,
                                       isConnected: Bool? = nil,
                                       updateByUser: Bool = false) {
        //  1、没有缓存就不更新
        guard uuid.isNotEmpty, connectedDevices.isNotEmpty else {
            logger.error("BleManager::updateConnectedDevice(\(uuid)): Not found device")
            return;
        }
        //  2、获取缓存设备
        guard  let index = connectedDevices.firstIndex(where: { device in
            device.peripheral.identifier.uuidString == uuid
        }) else {
            connectStateLog(uuid: uuid, state: updateByUser ? .disconnectByUser : .disconnectFromSys)
            logger.error("BleManager::updateConnectedDevice(\(uuid)): No cache device object")
            return
        }
        //  3、更新缓存设备信息
        var connectedDevice = connectedDevices[index]
        //  - 设置写
        if let writeChars = writeChars {
            connectedDevice.writeCharsDic[uuidType] = writeChars
        }
        //  - 设置读
        if let readChars = readChars {
            connectedDevice.readCharsDic[uuidType] = readChars
            //  - 开始订阅读特征变化值，即开启接收设备数据
            connectedDevice.peripheral.setNotifyValue(true, for: readChars)
        }
        //  - 设置连接状态
        if let isConnected = isConnected {
            connectedDevice.isConnected = isConnected
            //  - 回复连接成功
            if isConnected {
                connectStateLog(uuid: uuid, state: .connected)
            }
            //  - 发起断连
            else {
                centralManager.cancelPeripheralConnection(connectedDevice.peripheral)
                connectStateLog(uuid: uuid, state: updateByUser ? .disconnectByUser : .disconnectFromSys)
            }
        }
        connectedDevices[index] = connectedDevice
        logger.info("BleManager::updateConnectedDevice: Peripheral state = \(connectedDevice.peripheral.state.rawValue), \(connectedDevice.toString())")
    }
    
    /**
     *  连接状态打印
     */
    private func connectStateLog(uuid: String, state: BleConnectState) {
        //  1、超时定时器处理
        //  - 缓存中有定时器数据
        //  - 失败或者连接成功就要停止（即非连接状态）
        if let index = connectingTimeoutTimers.firstIndex(where: { info in
            info.0 == uuid
        }), !state.isConnecting() {
            //  -- 移除定时器
            let timer = connectingTimeoutTimers[index]
            timer.1.invalidate()
            connectingTimeoutTimers.remove(at: index)
            logger.info("BleManage::connect - flow: (\(uuid)), state = \(state.rawValue), stop connect timer")
        }
        //  2、设备连接状态为失败或断连就要设置连接设备连接状态为false
        if state.isError() || state.isDisconnected(), let index = connectedDevices.firstIndex(where: { $0.peripheral.identifier.uuidString == uuid }) {
            var device = connectedDevices[index]
            device.isConnected = false
            connectedDevices[index] = device
        }
        //  3、发送连接状态
        let connectModel = BleConnectModel(uuid: uuid, connectState: state)
        let jsonString = try? connectModel.toJsonString() ?? ""
        BleEC.connectStatus.event()?(jsonString)
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
        logger.info("BleManager - centralManagerDidUpdateState: State = \(central.state.label), code = \(central.state.rawValue)")
    }
    
    /**
     * 设备发现回调
     */
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        //  1、过滤名称为空的对象
        guard peripheral.name?.isEmpty == false else {
            return
        }
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
        //  4、规则解析
        let manufactureData = advertisementData["kCBAdvDataManufacturerData"] as? Data
        //  - 4.1、获取MAC地址
        let deviceMac = parseDataToMac(manufactureData: manufactureData)
        //  - 4.2、根据SN组装蓝牙数据
        let snRule = currentConfig.snRule
        let deviceSn = parseDataToObtainSn(manufactureData: manufactureData)
        //  - 4.2.1、阻断发送到Flutter
        //  -- a、SN无法被解析的
        //  -- b、不包含标识的设备
        if deviceSn.isEmpty ||
            snRule.scanFilterMarks.isNotEmpty,
           !snRule.scanFilterMarks.contains(where: { mark in
               return deviceSn.contains(mark)
           }) {
            return
        }
        //  5、发送设备到Flutter
        //  - 5.1、创建设备自定义模型对象,并缓存
        let bleDevice = peripheral.toBleDevice(
            sn: deviceSn,
            belongConfig: currentConfig.name,
            rssi: RSSI.intValue,
            mac: deviceMac,
        )
        scanResultTemp.append((bleDevice, peripheral))
        //  - 5.2、判断是否需要根据SN组合设备，不需要就直接提交
        guard snRule.matchCount > 1 else {
            sendMatchDevices(sn: deviceSn, devices: [bleDevice])
            return
        }
        //  - 5.3、从缓存中获取到相同的sn,且没有发送成功的
        let matchDevices = scanResultTemp.filter({ info in
            info.0.sn == bleDevice.sn
        }).map { info in
            info.0
        }
        //  -- 判断是否达到组合设备数量上限后，如果没有达到就不处理
        guard matchDevices.count >= snRule.matchCount else {
            return
        }
        sendMatchDevices(sn: deviceSn, devices: matchDevices)
    }
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        logger.error("BleManager::willRestoreState: \(dict)")
    }
    
    func centralManager(_ central: CBCentralManager, didUpdateANCSAuthorizationFor peripheral: CBPeripheral) {
        logger.error("BleManager::didUpdateANCSAuthorizationFor")
    }
    
    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        logger.error("BleManager::connectionEventDidOccur: event = \(event.rawValue)")
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) {
        logger.error("BleManager::didDisconnectPeripheral: timestamp = \(timestamp), isReconnecting = \(isReconnecting), error = \(error)")
    }
    
    /**
     * 设备连接成功回调
     */
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        //  1、与设备取得首次连接,缓存连接设备
        if !connectedDevices.contains(where: { device in
            device.peripheral.identifier.uuidString == peripheral.identifier.uuidString
        }) {
            connectedDevices.append(BleConnectedDevice(peripheral: peripheral))
        }
        //  2、获取设备服务
        peripheral.delegate = self
        let services = currentConfig.uuids.map { $0.serviceUUID }
        peripheral.discoverServices(services)
        //  3、发送日志
        connectStateLog(uuid: peripheral.identifier.uuidString, state: .searchService)
        logger.info("BleManager::didConnect: \(peripheral.identifier.uuidString)")
    }

    /**
     * 设备连接失败回调
     */
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectStateLog(uuid: peripheral.identifier.uuidString, state: .disconnectFromSys)
        logger.info("BleManager::didFailToConnect(\(peripheral.identifier.uuidString)): Error = \(error)")
    }

    /**
     *  设备断连回调
     */
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        //  1、如果error为空，说明为用户主动操作断连
        guard let error = error as? NSError else {
            //  不执行执行断连
            //  - 已经断连就不再处理
            //  - 没有退出升级状态的不用处理
            if connectedDevices.first(where: {$0.peripheral.identifier.uuidString == peripheral.identifier.uuidString})?.isConnected ?? false,
                upgradeDevices?.contains(where: {$0 == peripheral.identifier.uuidString}) != true {
                connectStateLog(uuid: peripheral.identifier.uuidString, state: .disconnectByUser)
                logger.error("BleManager::didFailToConnect(\(peripheral.identifier.uuidString)): No error when disconnect by user")
            }
            return
        }
        //  2、设备已经被绑定
        if error.code == 14 {
            connectStateLog(uuid: peripheral.identifier.uuidString, state: .alreadyBound)
            logger.error("BleManager::didFailToConnect(\(peripheral.identifier.uuidString)): Error = alread bound")
            return
        }
        //  3、其它原因断连
        connectStateLog(uuid: peripheral.identifier.uuidString, state: .disconnectFromSys)
        logger.error("BleManager::didFailToConnect(\(peripheral.identifier.uuidString)): Error = \(error.localizedDescription)")
    }
    
}


// MARK: - CBPeripheralManagerDelegate
extension BleManager: CBPeripheralManagerDelegate, CBPeripheralDelegate {
    
    /**
     *  获取设备更新状态
     */
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        logger.info("BleManager::peripheralManagerDidUpdateState: Peripheral manager = \(peripheral.isAdvertising), state = \(peripheral.state.rawValue)")
    }
    
    
    /**
     *  服务发现回调
     */
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            connectStateLog(uuid: peripheral.identifier.uuidString, state: .serviceFail)
            logger.error("BleManager::didDiscoverServices: \(peripheral.identifier.uuidString), error = \(error)")
            return
        }
        guard let services = peripheral.services else {
            connectStateLog(uuid: peripheral.identifier.uuidString, state: .serviceFail)
            logger.error("BleManager::didDiscoverServices: \(peripheral.identifier.uuidString)), error = Service not found")
            return
        }
        services.forEach { service in
            guard currentConfig.uuids.first(where: { uuidService in
                currentConfig.uuids.contains { $0.service == service.uuid.uuidString }
            }) != nil else {
                connectStateLog(uuid: peripheral.identifier.uuidString, state: .serviceFail)
                logger.error("BleManager::didDiscoverServices: \(peripheral.identifier.uuidString)), error = Service not found")
                return
            }
            peripheral.discoverCharacteristics(nil, for: service)
            logger.info("BleManager::didDiscoverServices: \(peripheral.identifier.uuidString), service = \(service.uuid.uuidString)")
        }
        connectStateLog(uuid: peripheral.identifier.uuidString, state: .searchChars)
    }
    
    /**
     *  读写特征回调
     */
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        //  1、处理错误回调
        guard error == nil else {
            connectStateLog(uuid: peripheral.identifier.uuidString, state: .charsFail)
            logger.error("BleManager::didDiscoverCharacteristicsFor: \(peripheral.identifier.uuidString), error = \(error)")
            return
        }
        //  2、不处理没有在BleUuid中配置的Service
        guard let targetUuid = currentConfig.uuids.first(where: { uuid in
            uuid.serviceUUID == service.uuid
        }) else {
            connectStateLog(uuid: peripheral.identifier.uuidString, state: .charsFail)
            logger.error("BleManager::didDiscoverCharacteristicsFor: \(peripheral.identifier.uuidString), error =  ")
            return
        }
        //  3、获取读写特征
        let writeChars = service.characteristics?.first { write in
            write.uuid == targetUuid.writeCharUUID
        }
        let readChars = service.characteristics?.first { read in
            read.uuid == targetUuid.readCharUUID
        }
        if writeChars == nil || readChars == nil {
            connectStateLog(uuid: peripheral.identifier.uuidString, state: .charsFail)
            logger.error("BleManager::didDiscoverCharacteristicsFor: \(peripheral.identifier.uuidString), error = Chars not found")
            return
        }
        updateConnectedDevice(uuid: peripheral.identifier.uuidString, writeChars: writeChars, readChars: readChars, uuidType: targetUuid.type)
        logger.info("BleManager::didDiscoverCharacteristicsFor: \(peripheral.identifier.uuidString), uuidType = \(targetUuid.type.rawValue), write = \(writeChars!.uuid.uuidString), read = \(readChars!.uuid.uuidString)")
    }
    
    /**
     *  特征订阅状态
     */
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            //  配对授权失败
            if let error = error as NSError?, error.domain == CBATTErrorDomain, error.code == 5 {
                connectStateLog(uuid: peripheral.identifier.uuidString, state: .boundFail)
            }
            logger.error("BleManager::update notification state: \(peripheral.identifier.uuidString), error = \(error)")
            return
        }
        guard characteristic.isNotifying else {
            logger.error("BleManager::update notification state: \(peripheral.identifier.uuidString), error = no notifying")
            return
        }
        //  当全部的Uuids特征信息全部获取完,且设备未连接，则发送连接流程完成
        if let connectedDevice = connectedDevices.first(where: { device  in
            device.peripheral.identifier.uuidString == peripheral.identifier.uuidString
        }), connectedDevice.writeCharsDic.keys.count == currentConfig.uuids.count, !connectedDevice.isConnected {
            self.connectStateLog(uuid: peripheral.identifier.uuidString, state: .connectFinish)
        }
        logger.info("BleManager::update notification state: \(peripheral.identifier.uuidString), chars = \(characteristic.uuid.uuidString)")
    }
    
    /**
     *  获取设备下发指令数据
     */
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            logger.error("BleManager::cmd response: \(peripheral.identifier.uuidString), error = \(error)")
            return
        }
        guard let data = characteristic.value else {
            logger.error("BleManager::cmd response: \(peripheral.identifier.uuidString), error = No data")
            return
        }
        let bleCmdMap = BleCmd(uuid: peripheral.identifier.uuidString, data: data, isSuccess: error == nil).toMap()
        BleEC.receiveData.event()?(bleCmdMap)
        logger.info("BleManager::cmd response: \(peripheral.identifier.uuidString), chars = \(characteristic.uuid.uuidString), data = \(data.hexString())")
    }
    
}
