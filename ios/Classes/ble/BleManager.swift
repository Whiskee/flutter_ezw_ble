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
        //  4、组装蓝牙数据
        let snRule = currentConfig.snRule
        //  - 4.1、根据规则获取SN
        let manufactureData = advertisementData["kCBAdvDataManufacturerData"] as? Data
        let deviceSn = parseDataToObtainSn(manufactureData: manufactureData)
        //  - 4.2、阻断发送到Flutter
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
            rssi: RSSI.intValue
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
    
//    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
//        logger.error("BleManager - willRestoreState: \(dict)")
//    }
//    
//    func centralManager(_ central: CBCentralManager, didUpdateANCSAuthorizationFor peripheral: CBPeripheral) {
//        logger.error("BleManager - didUpdateANCSAuthorizationFor")
//    }
//    
//    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
//        logger.error("BleManager - connectionEventDidOccur: event = \(event.rawValue)")
//    }
//    
//    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, timestamp: CFAbsoluteTime, isReconnecting: Bool, error: (any Error)?) {
//        logger.error("BleManager - didDisconnectPeripheral: timestamp = \(timestamp), isReconnecting = \(isReconnecting), error = \(error)")
//    }
    
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
        peripheral.discoverServices([currentConfig.uuid.serviceUUID])
        //  3、发送日志
        connectStateLog(uuid: peripheral.identifier.uuidString, state: .searchService)
        logger.info("BleManager - didConnect: \(peripheral.identifier.uuidString)")
    }

    /**
     * 设备连接失败回调
     */
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectStateLog(uuid: peripheral.identifier.uuidString, state: .disconnectFromSys)
        logger.info("BleManager - didFailToConnect(\(peripheral.identifier.uuidString)): Error = \(error)")
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
                logger.error("BleManager - didFailToConnect(\(peripheral.identifier.uuidString)): No error when disconnect by user")
            }
            return
        }
        //  2、设备已经被绑定
        if error.code == 14 {
            connectStateLog(uuid: peripheral.identifier.uuidString, state: .alreadyBound)
            logger.error("BleManager - didFailToConnect(\(peripheral.identifier.uuidString)): Error = alread bound")
            return
        }
        //  3、其它原因断连
        connectStateLog(uuid: peripheral.identifier.uuidString, state: .disconnectFromSys)
        logger.error("BleManager - didFailToConnect(\(peripheral.identifier.uuidString)): Error = \(error.localizedDescription)")
    }
    
}


// MARK: - CBPeripheralManagerDelegate
extension BleManager: CBPeripheralManagerDelegate, CBPeripheralDelegate {
    
    /**
     *  获取设备更新状态
     */
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        logger.info("BleManager - peripheralManagerDidUpdateState: Peripheral manager = \(peripheral.isAdvertising), state = \(peripheral.state.rawValue)")
    }
    
    
    /**
     *  服务发现回调
     */
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            connectStateLog(uuid: peripheral.identifier.uuidString, state: .serviceFail)
            logger.error("BleManager - didDiscoverServices(\(peripheral.identifier.uuidString)): Error = \(error)")
            return
        }
        guard let services = peripheral.services else {
            return
        }
        //  1、获取是否有服务的回调
        guard let connectService = services.first(where: { service in
            service.uuid.isEqual(currentConfig.uuid.serviceUUID)
        }) else {
            connectStateLog(uuid: peripheral.identifier.uuidString, state: .serviceFail)
            logger.error("BleManager - didDiscoverServices(\(peripheral.identifier.uuidString)): Errpr = Service not found")
            return
        }
        //  2、服务发现成功就获取读写服务
        peripheral.discoverCharacteristics(nil, for: connectService)
        connectStateLog(uuid: peripheral.identifier.uuidString, state: .searchChars)
        logger.info("BleManager - didDiscoverServices(\(peripheral.identifier.uuidString)): Success")
    }
    
    /**
     *  读写特征回调
     */
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        //  1、处理错误回调
        guard error == nil else {
            connectStateLog(uuid: peripheral.identifier.uuidString, state: .charsFail)
            logger.error("BleManager - didDiscoverCharacteristicsFor(\(peripheral.identifier.uuidString)): Error = \(error)")
            return
        }
        //  2、获取读/写服务
        guard service.uuid.isEqual(currentConfig.uuid.serviceUUID),
              let characteristics = service.characteristics else {
            connectStateLog(uuid: peripheral.identifier.uuidString, state: .charsFail)
            logger.error("BleManager - didDiscoverCharacteristicsFor(\(peripheral.identifier.uuidString)): Error = Chars not found")
            return
        }
        //  - 根据UUID获取匹配上的读写特征，然后更新已连接设备数据
        //  -- 注意：此处要注意UUID是否正确，否则会报The request is not support
        let writeChars = currentConfig.uuid.writeCharUUID == nil ? nil : characteristics.first { chars in
            chars.uuid.isEqual(currentConfig.uuid.writeCharUUID)
        }
        let readChars = currentConfig.uuid.readCharUUID == nil ? nil : characteristics.first { chars in
            chars.uuid.isEqual(currentConfig.uuid.readCharUUID)
        }
        updateConnectedDevice(uuid: peripheral.identifier.uuidString, writeChars: writeChars, readChars: readChars)
        //  3、更新连接状态
        connectStateLog(uuid: peripheral.identifier.uuidString, state: .connectFinish)
        logger.info("BleManager - didDiscoverCharacteristicsFor(\(peripheral.identifier.uuidString)): Success")
    }
    
    /**
     *  特征订阅状态
     */
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            logger.error("BleManager - update notification state(\(peripheral.identifier.uuidString)): Error = \(error)")
            return
        }
        guard characteristic.isNotifying else {
            logger.error("BleManager -  update notification state(\(peripheral.identifier.uuidString)): Error = no notifying")
            return
        }
        logger.info("BleManager -  update notification state(\(peripheral.identifier.uuidString)): Success")
    }
    
    /**
     *  获取设备下发指令数据
     */
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else {
            logger.error("BleManager - cmd response(\(peripheral.identifier.uuidString)): Error = \(error)")
            return
        }
        guard let data = characteristic.value else {
            logger.error("BleManager - cmd response(\(peripheral.identifier.uuidString)): No data")
            return
        }
        let bleCmdMap = BleCmd(uuid: peripheral.identifier.uuidString, data: data, isSuccess: error == nil).toMap()
        BleEC.receiveData.event()?(bleCmdMap)
        logger.info("BleManager - cmd response(\(peripheral.identifier.uuidString)): \(data.hexString())")
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
        logger.info("BleManager - startScan")
    }
    
    /**
     * 停止扫描设备
     */
    func stopScan() {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        centralManager.stopScan()
        logger.info("BleManager - stopScan")
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
            logger.error("BleManage - connect: Empty uuid")
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
            logger.info("BleManage - connect(\(uuid)): From connected device list, after upgrade \(afterUpgrade)")
        }
        //  - 3.2、在缓存中查找对应的设备
        else if let temp = scanResultTemp.first(where: { info in
            return info.0.uuid == uuid
        }) {
            centralManager.connect(temp.1)
            // -- 执行连接倒计时
            startConnectingCountdown(uuid: uuid, afterUpgrade: afterUpgrade)
            logger.info("BleManage - connect(\(uuid)): From scan resul temp, after upgrade \(afterUpgrade)")
        }
        //  - 3.3、获取蓝牙设置页面中是否有符合的设备
        else if let device = findPeripheralFromConnected(uuidStr: uuid) {
            centralManager.connect(device)
            // -- 缓存对象
            connectedDevices.append(BleConnectedDevice(peripheral: device))
            // -- 执行连接倒计时
            startConnectingCountdown(uuid: uuid, afterUpgrade: afterUpgrade)
            logger.info("BleManage - connect(\(uuid)): From bluetooth setting, after upgrade \(afterUpgrade)")
        }
        //  - 3.4、通过ServiceUUID查询
        else {
            //  -- 添加待连接的设备
            startConnectInfos.append((uuid, Date().timeIntervalSince1970, afterUpgrade))
            //  -- 根据服务特征查询设备
            startScan()
            logger.info("BleManage - connect(\(uuid)): No local device found, start scan device")
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
        logger.info("BleManage - disconnect(\(uuid): Disconnect by user")
    }
    
    /**
     *
     *  发送数据
     *
     *  - 升级中不允许发送cmd
     *
     */
    func sendCmd(uuid: String, data: Data) {
        guard checkIsFunctionCanBeCalled() else {
            return
        }
        guard upgradeDevices?.contains(where: {$0 == uuid}) != true else {
            logger.info("BleManage - sendCmd(\(uuid)): Cannot send commands during upgrade")
            return
        }
        guard let device = connectedDevices.first(where: { device in
            device.peripheral.identifier.uuidString == uuid
        }), let writeChars = device.writeChars else {
            logger.info("BleManage - sendCmd(\(uuid)): Device not found")
            return
        }
        device.peripheral.writeValue(data, for: writeChars, type: .withoutResponse)
        logger.info("BleManage - sendCmd(\(uuid)): \(data.hexString())")
    }
        
    /**
     *  进入升级模式
     */
    func enterUpgradeState(uuid: String) {
        if upgradeDevices?.contains(where: {$0 == uuid}) == true {
            return
        }
        upgradeDevices?.append(uuid)
        connectStateLog(uuid: uuid, state: .upgrade)
        logger.info("BleManage - enterUpgradeState(\(uuid)): Enter upgrade state")
    }
    
    /**
     *  退出升级模式
     */
    func quiteUpgradeState(uuid: String) {
        guard upgradeDevices?.contains(where: {$0 == uuid}) == true else {
            return
        }
        upgradeDevices?.removeAll(where: { $0 == uuid })
        logger.info("BleManage - quiteUpgradeState(\(uuid)): Had Quite upgrade state")
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
            logger.info("BleManager - checkBleConfigIsConfigured: Bluetooth configuration has not been configured yet")
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
               logger.info("BleManager - checkBleConfigIsConfigured: ble status = \(self.bleState)")
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
        let connectedPeripherals = centralManager.retrieveConnectedPeripherals(withServices: [currentConfig.uuid.serviceUUID])
        return connectedPeripherals.first { device in
            device.identifier.uuidString == uuidStr
        }
    }
    
    /**
     *  解析数据获取SN
     */
    private func parseDataToObtainSn(manufactureData: Data?) -> String {
        var sn: String = ""
        //  如果byteLength为0，则处理所有长度Data的数据
        guard currentConfig.snRule.byteLength != 0 else {
            if let manufactureData = manufactureData {
                sn = String(data: manufactureData, encoding: .utf8) ?? ""
            }
            return replaceControlCharacters(in: sn)
        }
        //  如果byteLength大于0，则根据规则解析Data
        if var manufactureData = manufactureData,
           manufactureData.count == currentConfig.snRule.byteLength {
            let subrange = currentConfig.snRule.startSubIndex..<manufactureData.endIndex
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
                logger.info("BleManager - centralManager - search(\(connectUuid)): No device found")
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
                logger.info("BleManager - centralManager - search(\(connectUuid)): Device has been found, start connecting, after upgrade \(connectDevice.2)")
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
            logger.info("BleManager - centralManager - sendMatchDevices: \(jsonDic)")
        } catch {
            logger.error("BleManager - centralManager - sendMatchDevices: \(error)")
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
        logger.info("BleManage - connect(\(uuid)): Start connect time out timer")
    }
    
    /**
     *  更新缓存设备数据
     */
    private func updateConnectedDevice(uuid: String,
                                       peripheral: CBPeripheral? = nil,
                                       writeChars: CBCharacteristic? = nil,
                                       readChars: CBCharacteristic? = nil,
                                       isConnected: Bool? = nil,
                                       updateByUser: Bool = false) {
        //  1、没有缓存就不更新
        guard uuid.isNotEmpty, connectedDevices.isNotEmpty else {
            return;
        }
        //  2、获取缓存设备
        guard  let index = connectedDevices.firstIndex(where: { device in
            device.peripheral.identifier.uuidString == uuid
        }) else {
            connectStateLog(uuid: uuid, state: updateByUser ? .disconnectByUser : .disconnectFromSys)
            logger.error("BleManager - updateConnectedDevice(\(uuid)): No cache device object")
            return
        }
        //  2、更新缓存设备信息
        var connectedDevice = connectedDevices[index]
        //  - 设置写
        if let writeChars = writeChars {
            connectedDevice.writeChars = writeChars
        }
        //  - 设置读
        if let readChars = readChars {
            connectedDevice.readChars = readChars
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
        logger.info("BleManager - updateConnectedDevice: Peripheral state = \(connectedDevice.peripheral.state.rawValue), \(connectedDevice.toString())")
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
            logger.info("BleManage - connect flow(\(uuid)): \(state.rawValue), Stop connect time out")
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
