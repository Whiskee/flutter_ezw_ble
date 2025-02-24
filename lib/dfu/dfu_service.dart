import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_ezw_ble/flutter_ezw_index.dart';
import 'package:mcumgr_flutter/mcumgr_flutter.dart';
import 'package:path_provider/path_provider.dart';

/// OTA升级状态
class OTAUpgradeState {
  final String deviceId;
  final FirmwareUpgradeState state;

  OTAUpgradeState(this.deviceId, this.state);
}

/// OTA升级进度
class OTAUpgradeProgress {
  final String deviceId;
  final double progress;

  OTAUpgradeProgress(this.deviceId, this.progress);
}

class DfuService {
  static final to = DfuService._();

  /// ========= Constants
  //  临时缓存当前正在进行OTA升级的设备
  final List<DfuUpdate> _upgradeTemp = [];
  //  Get: 是否有设备正在进行OTA升级
  final RxList<String> _upgradingDevices = <String>[].obs;
  RxList<String> get upgradingDevices => _upgradingDevices;
  //  监听升级状态
  final StreamController<(String, FirmwareUpgradeState)> _otaStateStreamCtl =
      StreamController.broadcast();
  Stream<(String, FirmwareUpgradeState)> get otaStateStream =>
      _otaStateStreamCtl.stream;
  //  监听升级进度
  final StreamController<(String, double)> _otaProgressStreamCtl =
      StreamController.broadcast();
  Stream<(String, double)> get otaProgressStream =>
      _otaProgressStreamCtl.stream;

  //  ========= Variables
  //  升级配置
  FirmwareUpgradeConfiguration configuration =
      const FirmwareUpgradeConfiguration();

  DfuService._();

  /// 复制固件压缩包到临时文件夹后解压
  /// - description:解压并读取固件包中的的manifest.json，获取需要上传的信息
  ///
  /// - param firmwareData [Uint8List], 固件压缩包数据,一般为ZIP格式压缩版
  ///
  Future<List<Image>> unpackZip(Uint8List firmwareData) async {
    //  1、如果数据为空，直接返回
    if (firmwareData.isEmpty) {
      return [];
    }
    //  2、复制固件到临时目录
    //  - 2.1、根据日期创建，避免创建重复的文件夹
    final prefix = 'firmware_${DateTime.now().millisecondsSinceEpoch}';
    final firmwareTemp = await getApplicationSupportDirectory();
    final tempDir = Directory('${firmwareTemp.path}/$prefix');
    await tempDir.create();
    //  - 2.2、将固件数据写入文件
    final firmwareFile = File('${tempDir.path}/firmware.zip');
    await firmwareFile.writeAsBytes(firmwareData);
    //  - 2.3、创建解压目录
    final destinationDir = Directory('${tempDir.path}/firmware');
    await destinationDir.create();
    //  3、解压复制的固件，获取所有文件
    final newFirmwareData = await firmwareFile.readAsBytes();
    final archive = ZipDecoder().decodeBytes(newFirmwareData);
    for (final entry in archive) {
      if (entry.isFile) {
        final fileBytes = entry.readBytes();
        if (fileBytes == null) {
          continue;
        }
        File('${destinationDir.path}/${entry.name}')
          ..createSync(recursive: true)
          ..writeAsBytesSync(fileBytes.toList());
      }
    }
    //  4、读取manifest.json
    final manifestFile = File('${destinationDir.path}/manifest.json');
    final manifestString = await manifestFile.readAsString();
    Map<String, dynamic> manifestJson = json.decode(manifestString);
    DfuManifest manifest;
    try {
      manifest = DfuManifest.fromJson(manifestJson);
    } catch (e) {
      await tempDir.delete(recursive: true);
      throw Exception('Failed to parse manifest.json');
    }
    //  获取解压对象
    List<Image> images = [];
    for (final file in manifest.files) {
      final firmwareFile = File('${destinationDir.path}/${file.fileName}');
      final manifestFileData = await firmwareFile.readAsBytes();
      final image = Image(
        image: int.parse(file.imageIndex),
        data: manifestFileData,
      );
      images.add(image);
    }
    //  5、删除临时文件
    await tempDir.delete(recursive: true);
    return images;
  }

  /// OTA升级
  ///
  /// - param deviceId [String], device's MAC address (on Android) or UUID (on iOS)
  /// - param images [List<Image>], the firmware images to be updated
  ///
  void startOTAUpdate(String deviceId, List<Image> images,
      {FirmwareUpgradeConfiguration? upgradeConfiguration}) async {
    assert(deviceId.isNotEmpty && images.isNotEmpty,
        "Check your parameters please.");
    if (_upgradeTemp.any((update) => update.deviceId == deviceId)) {
      return;
    }
    //  初始化OTA升级管理器
    final UpdateManagerFactory managerFactory = FirmwareUpdateManagerFactory();
    final updateManager = await managerFactory.getUpdateManager(deviceId);
    // 必须要调用，否则无法进行OTA升级
    updateManager.setup();
    //  监听更新状态和升级进度
    updateManager.updateStateStream
        ?.listen((state) async => _otaStateStreamCtl.add((deviceId, state)));
    updateManager.progressStream.listen((event) => _otaProgressStreamCtl
        .add((deviceId, (event.bytesSent / event.imageSize) * 100)));
    //  执行OTA升级
    updateManager.update(images,
        configuration:
            upgradeConfiguration ?? const FirmwareUpgradeConfiguration());
    //  缓存当前正在进行OTA升级的设备
    _upgradeTemp.add(DfuUpdate(deviceId, updateManager));
    //  当前升级中的设备
    _upgradingDevices.value =
        _upgradeTemp.map((temp) => temp.deviceId).toList();
    //  进入升级模式
    EzwBle.to.bleMC.enterUpgradeState(deviceId);
  }

  /// 暂停OTA升级
  ///
  /// - description: 暂停指定设备的OTA升级
  ///
  void pauseOTAUpdate(String deviceId) {
    final dfuUpdate =
        _upgradeTemp.firstWhereOrNull((update) => update.deviceId == deviceId);
    dfuUpdate?.updateManger.pause();
  }

  /// 恢复OTA升级
  ///
  /// - description: 恢复指定设备的OTA升级
  ///
  void resumeOTAUpdate(String deviceId) {
    final dfuUpdate =
        _upgradeTemp.firstWhereOrNull((update) => update.deviceId == deviceId);
    dfuUpdate?.updateManger.resume();
  }

  /// 停止OTA升级
  ///
  /// - description: 停止指定设备的OTA升级,并从缓存中移除
  ///
  void stopOTAUpdate(String deviceId) {
    final dfuUpdate =
        _upgradeTemp.firstWhereOrNull((update) => update.deviceId == deviceId);
    dfuUpdate?.updateManger.cancel();
    dfuUpdate?.updateManger.kill();
    _upgradeTemp.remove(dfuUpdate);
    _upgradingDevices.value =
        _upgradeTemp.map((temp) => temp.deviceId).toList();
    //  退出升级模式
    EzwBle.to.bleMC.quiteUpgradeState(deviceId);
  }

  /// 停止所有设备的OTA升级
  void stopAllOTAUpdate() {
    for (var update in _upgradeTemp) {
      update.updateManger.cancel();
      update.updateManger.kill();
      //  退出升级模式
      EzwBle.to.bleMC.quiteUpgradeState(update.deviceId);
    }
    _upgradeTemp.clear();
    _upgradingDevices.value = [];
  }

  /// 检查设备是否正在进行OTA升级
  Future<bool> checkDeviceIsOTAUpdating(String deviceId) async =>
      await _upgradeTemp
          .firstWhereOrNull((update) => update.deviceId == deviceId)
          ?.updateManger
          .inProgress() ==
      true;
}
