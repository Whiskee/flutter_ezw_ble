import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('example keeps BLE config values out of source control', () {
    final sources = Directory('example/lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');

    expect(sources, isNot(contains('BlePrivateService(')));
    expect(sources, isNot(contains('BleScan(')));
    expect(sources, isNot(contains('00002760')));
    expect(sources, isNot(contains('Even G2')));
    expect(sources, isNot(contains("'S20'")));
    expect(sources, isNot(contains('"S20"')));
  });

  test('example caches runtime BLE configs instead of hardcoding them', () {
    final mainSource = File('example/lib/main.dart').readAsStringSync();
    final widgetSource =
        File('example/lib/src/g2_demo_widgets.dart').readAsStringSync();

    expect(mainSource, contains('_bleConfigCacheKey'));
    expect(mainSource, contains('SharedPreferences.getInstance'));
    expect(mainSource, contains('_activeConfigs'));
    expect(mainSource, contains('_decodeBleConfigs'));
    expect(mainSource, contains('decoded is List'));
    expect(mainSource, contains('BleConfig.fromJson'));
    expect(mainSource, contains('config.customToJson()'));
    expect(mainSource, contains('_applyPlatformOverrides'));
    expect(mainSource, contains('platformOverrides'));
    expect(mainSource, contains('_requiredMatchCountFor'));
    expect(widgetSource, contains('BLE config JSON'));
    expect(widgetSource, contains('Paste BleConfig JSON'));
  });

  test('example treats initConfigs timeout as pending instead of config failure', () {
    final mainSource = File('example/lib/main.dart').readAsStringSync();

    expect(mainSource, contains('int _configInitEpoch'));
    expect(mainSource, contains('initConfigs pending:'));
    expect(mainSource, contains("_finishInitConfigs(configs, reason: 'late ack')"));
    expect(
      mainSource,
      contains('restore cached device deferred: configs pending'),
    );
    expect(mainSource, contains('Future can still complete'));
  });
}
