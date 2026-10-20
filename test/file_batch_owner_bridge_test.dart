import 'package:flutter/services.dart';
import 'package:flutter_ezw_ble/flutter_ezw_ble_method_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_ezw_ble');
  final calls = <MethodCall>[];
  Object? reply;

  setUp(() {
    calls.clear();
    reply = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('native reservation token is forwarded verbatim on a single batch',
      () async {
    final ble = MethodChannelEzwBle();
    reply = 'native-instance:batch-1';
    final token = await ble.beginFilePacketBatch('left');
    expect(token, reply);
    expect(calls.single.method, 'beginFilePacketBatch');
    expect(calls.single.arguments, {'uuid': 'left'});
    reply = null;
    final packets = [
      Uint8List.fromList([1, 2]),
      Uint8List.fromList([3])
    ];
    await ble.sendFilePacketBatch('left', packets, fileBatchToken: token);
    expect(calls.last.method, 'sendFilePacketBatch');
    expect(calls.last.arguments, {
      'uuid': 'left',
      'packets': packets,
      'psType': 3,
      'fileBatchToken': token,
    });
  });

  for (final revoked in [true, false]) {
    test('cancel returns the explicit native acknowledgement $revoked',
        () async {
      reply = revoked;
      expect(
        await MethodChannelEzwBle()
            .cancelFilePacketBatch('left', 'native-token'),
        revoked,
      );
      expect(calls.single.method, 'cancelFilePacketBatch');
      expect(calls.single.arguments,
          {'uuid': 'left', 'fileBatchToken': 'native-token'});
    });
  }

  for (final malformed in <Object?>[
    null,
    '',
    '   ',
    false,
    7,
    <String, int>{}
  ]) {
    test('begin refuses malformed native token $malformed', () async {
      reply = malformed;
      await expectLater(MethodChannelEzwBle().beginFilePacketBatch('left'),
          throwsA(isA<PlatformException>()));
      expect(calls, hasLength(1));
    });
  }

  for (final malformed in <Object?>[null, 0, 'false', <String, int>{}]) {
    test('cancel does not interpret unknown reply $malformed as absent',
        () async {
      reply = malformed;
      await expectLater(
          MethodChannelEzwBle().cancelFilePacketBatch('left', 'native-token'),
          throwsA(isA<PlatformException>()));
      expect(calls, hasLength(1));
    });
  }

  test('native error never falls back to legacy writes', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw PlatformException(code: 'file_write_unavailable');
    });
    final ble = MethodChannelEzwBle();
    await expectLater(
        ble.beginFilePacketBatch('left'), throwsA(isA<PlatformException>()));
    await expectLater(ble.cancelFilePacketBatch('left', 'token'),
        throwsA(isA<PlatformException>()));
    await expectLater(
        ble.sendFilePacketBatch(
            'left',
            [
              Uint8List.fromList([1])
            ],
            fileBatchToken: 'token'),
        throwsA(isA<PlatformException>()));
    expect(calls.map((call) => call.method), [
      'beginFilePacketBatch',
      'cancelFilePacketBatch',
      'sendFilePacketBatch',
    ]);
  });

  test('missing native API never falls back to legacy writes', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      throw MissingPluginException('No owned batch support');
    });
    final ble = MethodChannelEzwBle();
    await expectLater(ble.beginFilePacketBatch('left'),
        throwsA(isA<MissingPluginException>()));
    await expectLater(ble.cancelFilePacketBatch('left', 'token'),
        throwsA(isA<MissingPluginException>()));
    await expectLater(
        ble.sendFilePacketBatch(
            'left',
            [
              Uint8List.fromList([1])
            ],
            fileBatchToken: 'token'),
        throwsA(isA<MissingPluginException>()));
    expect(calls.map((call) => call.method), [
      'beginFilePacketBatch',
      'cancelFilePacketBatch',
      'sendFilePacketBatch',
    ]);
  });

  test('blank supplied token is rejected rather than sent as unowned',
      () async {
    for (final token in ['', '  ']) {
      await expectLater(
          MethodChannelEzwBle().sendFilePacketBatch(
            'left',
            [
              Uint8List.fromList([1])
            ],
            fileBatchToken: token,
          ),
          throwsArgumentError);
      await expectLater(
          MethodChannelEzwBle().cancelFilePacketBatch('left', token),
          throwsArgumentError);
    }
    expect(calls, isEmpty);
  });

  test('new ownership APIs reject blank endpoints before native', () async {
    final ble = MethodChannelEzwBle();
    await expectLater(ble.beginFilePacketBatch(' '), throwsArgumentError);
    await expectLater(
        ble.cancelFilePacketBatch('', 'token'), throwsArgumentError);
    expect(calls, isEmpty);
  });

  test('omitted token preserves the exact legacy arguments', () async {
    final packets = [
      Uint8List.fromList([1])
    ];
    await MethodChannelEzwBle().sendFilePacketBatch('left', packets);
    expect(calls.single.arguments,
        {'uuid': 'left', 'packets': packets, 'psType': 3});
  });
}
