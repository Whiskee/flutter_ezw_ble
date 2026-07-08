import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ezw_ble/flutter_ezw_index.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';

part 'src/g2_demo_protocol.dart';
part 'src/g2_demo_connection.dart';
part 'src/g2_demo_widgets.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  static const _g2CommonPsType = 0;
  static const _g2DeviceSettingsServiceId = 0x80;
  static const _g2AuthCommandId = 0x04;
  static const _g2PipeRoleChangeCommandId = 0x05;
  static const _g2TimeSyncCommandId = 0x80;
  static const _g2RightRole = 1;
  static const _bleConfigCacheKey = 'flutter_ezw_ble_example_ble_config_v1';
  static const _lastG2DeviceKey = 'flutter_ezw_ble_example_last_g2_device_v1';

  final _ble = EzwBle.to;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<BleMatchDevice> _scanResults = [];
  final List<String> _logs = [];
  final ValueNotifier<int> _logVersion = ValueNotifier<int>(0);
  final Map<String, BleConnectState> _connectStates = {};
  final Set<String> _connectFinishAcked = {};
  final Set<String> _businessConnectStarted = {};
  final Map<String, int> _g2AuthEpochs = {};
  final Map<String, _PendingG2Command> _pendingG2Commands = {};
  final Map<String, BleConnectModel> _latestConnectEvents = {};
  final List<String> _pendingG2AuthQueue = [];
  final List<BleDevice> _pendingG2ConnectLegs = [];
  final Set<String> _requestedG2ConnectUuids = {};
  BleState _latestBleState = BleState.unknown;
  Timer? _connectWatchdog;
  Timer? _activeG2AuthTimer;
  DateTime? _connectStartedAt;
  // App 启动时 `bootstrap` 和生命周期 `resumed` 可能同时重放配置。
  // 用同一个 Future 合并并发 reload，避免重复调用原生 initConfigs 卡住首帧。
  Future<void>? _configReloadFuture;
  // initConfigs 可能在 iOS restoration / native reconnect 排队时晚于 5s 返回。
  // 用 epoch 只接受最后一次配置下发的异步完成，避免旧 Future 反向覆盖新配置状态。
  int _configInitEpoch = 0;
  String? _activeG2AuthUuid;
  int? _activeG2AuthEpoch;
  bool _initialBootstrapStarted = false;
  bool _initialBootstrapFinished = false;

  String _platformVersion = 'Unknown';
  String _bleState = '-';
  int _connectEpoch = 0;
  int _g2SyncId = 0;
  int _g2MagicNum = 0;
  bool _scanning = false;
  bool _connecting = false;
  bool _startingNextG2Leg = false;
  bool _g2ConnectDirectConnect = false;
  bool _searchOpen = false;
  bool _configsReady = false;
  bool _bleAvailableRecoveryRunning = false;
  List<BleConfig> _activeConfigs = [];
  BleMatchDevice? _selectedDevice;

  /// Returns whether the demo has at least one runtime BLE config loaded.
  bool get _hasActiveConfigs => _activeConfigs.isNotEmpty;

  /// Looks up the `matchCount` that belongs to one scan result's own config.
  ///
  /// Scan results carry `belongConfig` per device, so G2/R1/other configs must
  /// not share a global match count.
  int _requiredMatchCountFor(BleMatchDevice match) {
    return _configForMatch(match)?.scan.matchCount ?? 1;
  }

  /// Resolves the BLE config used to produce a scan or cached-device result.
  ///
  /// The first device is enough because native scan aggregation only combines
  /// devices that came from the same `BleConfig`.
  BleConfig? _configForMatch(BleMatchDevice match) {
    if (match.devices.isEmpty) {
      return null;
    }
    return _configByName(match.devices.first.belongConfig);
  }

  /// Finds a config by its stable `BleConfig.name`.
  ///
  /// Native connect APIs route by this name, so the example keeps the same
  /// lookup rule when validating scan rows and restored cached devices.
  BleConfig? _configByName(String name) {
    for (final config in _activeConfigs) {
      if (config.name == name) {
        return config;
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initPlatformState();
    _listenBleEvents();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 首屏必须先出来。配置恢复、State Restoration 事件 drain、缓存设备恢复都放到
      // 首帧之后执行，避免 iOS 安装启动阶段看起来像卡在空白页。
      _initialBootstrapStarted = true;
      unawaited(_bootstrap());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    for (final pending in _pendingG2Commands.values) {
      pending.fail(StateError('disposed'));
    }
    _cancelConnectWatchdog();
    _cancelActiveG2AuthTimer();
    _pendingG2Commands.clear();
    _logVersion.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_initialBootstrapStarted || !_initialBootstrapFinished) {
        // iOS 首次启动会很快派发 resumed。此时 bootstrap 本身就会加载配置，
        // 这里再 join/reload 只会制造噪声，甚至让首屏导航看起来没有响应。
        _addLog('app resumed ignored: bootstrap not finished');
        return;
      }
      // iOS State Restoration can wake the process before the Flutter tree has
      // finished bootstrapping. Reloading here makes cached configs available
      // again, while `_configReloadFuture` prevents duplicate native init.
      unawaited(_reloadCachedBleConfig(reason: 'app resumed'));
    }
  }

  /// Reads platform version for diagnostics shown in the scan header.
  Future<void> _initPlatformState() async {
    try {
      _platformVersion =
          await _ble.bleMC.getPlatformVersion() ?? 'Unknown platform version';
    } on PlatformException {
      _platformVersion = 'Failed to get platform version.';
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// Restores cached config and cached device identity during app startup.
  ///
  /// Device restore is delayed until after the first frame so the home/search
  /// route can be built before reconnect events start updating visible state.
  Future<void> _bootstrap() async {
    try {
      await _reloadCachedBleConfig(reason: 'bootstrap');
      await _drainAutoReconnectEvents('bootstrap');
      if (_configsReady) {
        _restoreLastDevice();
      } else if (_hasActiveConfigs) {
        _addLog('restore cached device deferred: configs pending, reason=bootstrap');
      }
    } finally {
      _initialBootstrapFinished = true;
    }
  }

  /// Reloads BLE configs from local storage with single-flight protection.
  ///
  /// `bootstrap` and `AppLifecycleState.resumed` can overlap on physical iOS
  /// devices. Joining the in-flight Future keeps MethodChannel calls ordered and
  /// prevents two `initConfigs` calls from racing the restoration pipeline.
  Future<void> _reloadCachedBleConfig({required String reason}) async {
    final activeReload = _configReloadFuture;
    if (activeReload != null) {
      _addLog('reload BLE configs[$reason]: join in-flight reload');
      await activeReload;
      return;
    }

    final reload = _reloadCachedBleConfigLocked(reason: reason);
    _configReloadFuture = reload;
    try {
      await reload;
    } finally {
      if (identical(_configReloadFuture, reload)) {
        _configReloadFuture = null;
      }
    }
  }

  /// Performs the actual config reload once the single-flight gate is acquired.
  Future<void> _reloadCachedBleConfigLocked({required String reason}) async {
    await _loadCachedBleConfig(reason: reason);
    await _initConfigs();
  }

  void _listenBleEvents() {
    _subscriptions.addAll([
      _ble.bleStateEC.listen((state) {
        final wasBleUnavailable = _latestBleState.isBleOff ||
            _latestBleState.isBleUnauthorized ||
            _latestBleState.isBleNoLocation;
        setState(() {
          _latestBleState = state;
          _bleState = state.toString();
        });
        _addLog('bleState: $state');
        if (state.isBleAvailable) {
          unawaited(
            _handleBleAvailable(
              'bleState available',
              forceRestartConnecting: wasBleUnavailable,
            ),
          );
        }
      }),
      _ble.scanResultEC.listen((match) {
        final config = _configForMatch(match);
        if (config == null) {
          _addLog(
            'scanResult ignored: unknown config '
            'sn=${match.sn} config=${match.devices.isEmpty ? '-' : match.devices.first.belongConfig}',
          );
          return;
        }
        final requiredMatchCount = config.scan.matchCount;
        if (match.devices.length < requiredMatchCount) {
          _addLog(
            'scanResult ignored: sn=${match.sn}, config=${config.name}, '
            'devices=${match.devices.length}/$requiredMatchCount',
          );
          return;
        }
        setState(() {
          final index = _scanResults.indexWhere((item) {
            return item.isSameDevice(match) || item.sn == match.sn;
          });
          if (index >= 0) {
            _scanResults[index] = match;
          } else {
            _scanResults.insert(0, match);
          }
        });
        _addLog(
          'scanResult: sn=${match.sn}, config=${config.name}, '
          'devices=${match.devices.length}',
        );
      }),
      _ble.connectStatusEC.listen((state) {
        _latestConnectEvents[state.uuid] = state;
        _connectStates[state.uuid] = state.connectState;
        _addLog(
          'connectStatus: ${_selectedLegIdentity(state.uuid, state.name)} '
          'state=${state.connectState.name} aggregate=[${_connectSnapshot()}]',
        );

        if (_isSelectedUuid(state.uuid)) {
          _handleSelectedConnectState(state);
        } else if (_selectedDevice == null &&
            (state.connectState.isConnectFinish ||
                state.connectState.isConnected)) {
          _addLog(
            'connectStatus deferred until cached device restore: '
            'uuid=${_shortUuid(state.uuid)} state=${state.connectState.name}',
          );
        }
      }),
      _ble.receiveDataEC.listen(_handleG2ReceiveData),
      _ble.blePrintEC.listen(_addLog),
    ]);
  }

  /// Pushes cached runtime BLE configs into native Android/iOS code.
  ///
  /// Native `initConfigs` must complete quickly because the home page waits for
  /// this before cached-device reconnect. A timeout turns platform hangs into a
  /// visible log instead of leaving the app on the launch screen indefinitely.
  Future<void> _initConfigs() async {
    final configs = _activeConfigs;
    if (configs.isEmpty) {
      // Empty config is a valid runtime state: scanning is disabled until the
      // user adds at least one config from the search page.
      _configsReady = false;
      _addLog('initConfigs skipped: no cached BLE configs');
      _notifyDetailStateChanged();
      return;
    }
    final initEpoch = ++_configInitEpoch;
    _configsReady = false;
    _notifyDetailStateChanged();
    try {
      _addLog(
        'initConfigs start: configs=${configs.map((config) => '${config.name}:${config.scan.matchCount}:autoReconnect=${config.autoReconnect}').join(', ')}',
      );
      final initFuture = _ble.bleMC.initConfigs(configs);
      // The original Future keeps running after this timeout. When it completes
      // later, `_finishInitConfigs` will mark configs ready and replay cached
      // recovery. This keeps launch responsive without racing connect before
      // native has actually accepted the config table.
      unawaited(
        initFuture.then((_) {
          if (!mounted || initEpoch != _configInitEpoch) {
            return;
          }
          _finishInitConfigs(configs, reason: 'late ack');
        }).catchError((Object error) {
          if (!mounted || initEpoch != _configInitEpoch) {
            return;
          }
          _failInitConfigs(error);
        }),
      );
      // Guard the MethodChannel await because State Restoration / native
      // reconnect bugs otherwise look like a Flutter launch hang.
      await initFuture.timeout(
            const Duration(seconds: 5),
          );
      _finishInitConfigs(configs, reason: 'ack');
    } on TimeoutException catch (error) {
      _addLog('initConfigs pending: $error');
    } catch (error) {
      _failInitConfigs(error);
    }
  }

  /// Marks native config delivery as complete and replays deferred recovery.
  ///
  /// This function is intentionally idempotent because the awaited path and the
  /// late-ack callback can both observe the same MethodChannel completion.
  void _finishInitConfigs(List<BleConfig> configs, {required String reason}) {
    if (_configsReady) {
      return;
    }
    _configsReady = true;
    _addLog(
      'initConfigs success[$reason]: configs=${configs.map((config) => config.name).join(', ')}',
    );
    _notifyDetailStateChanged();
    if (_latestBleState.isBleAvailable) {
      // BLE may have become available before configs finished loading; replay
      // the recovery check after native has a valid config table.
      unawaited(_handleBleAvailable('initConfigs available'));
    }
    if (_initialBootstrapFinished) {
      unawaited(_restoreLastDevice(reason: 'initConfigs $reason'));
    }
  }

  /// Records a real native config failure.
  ///
  /// Timeout is handled separately as "pending" because the underlying
  /// MethodChannel Future can still complete and should not poison cached
  /// reconnect state.
  void _failInitConfigs(Object error) {
    _configsReady = false;
    _addLog('initConfigs: $error');
    _notifyDetailStateChanged();
  }

  /// Drains native reconnect/restoration breadcrumbs collected before Dart was ready.
  ///
  /// These logs are diagnostic only; reconnect itself is driven by native state
  /// and normal `connectStatus` events.
  Future<void> _drainAutoReconnectEvents(String reason) async {
    try {
      final events = await _ble.bleMC.drainAutoReconnectEvents();
      if (events.isEmpty) {
        return;
      }
      for (final event in events) {
        final type = event['type'] ?? 'unknown';
        final uuid = event['uuid'] ?? '';
        final name = event['name'] ?? '';
        final detail = event['detail'] ?? '';
        _addLog(
          'nativeReconnectEvent[$reason]: type=$type '
          'uuid=${_shortUuid(uuid.toString())} name=$name detail=$detail',
        );
      }
    } catch (error) {
      _addLog('nativeReconnectEvent[$reason]: $error');
    }
  }

  /// Starts scanning after making sure native has the latest runtime configs.
  Future<void> _startScan() async {
    if (!_configsReady) {
      // Configs are only pushed when missing or dirty. Re-running initConfigs
      // on every scan makes the logs noisy and can race with restoration work.
      await _initConfigs();
    }
    if (!_configsReady) {
      _addLog('startScan blocked: BLE configs missing');
      return;
    }
    try {
      final granted = await _ensureBlePermissions();
      if (!granted) {
        _addLog('startScan blocked: BLE permissions not granted');
        return;
      }
      await _ble.bleMC.startScan();
      setState(() => _scanning = true);
      _addLog('startScan: ok');
    } catch (error) {
      _addLog('startScan: $error');
    }
  }

  /// Loads the user's runtime BLE configs from SharedPreferences.
  ///
  /// The cache accepts both the old single-object shape and the new multi-config
  /// array shape; `_decodeBleConfigs` normalizes both to a list.
  Future<void> _loadCachedBleConfig({required String reason}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_bleConfigCacheKey);
      if (raw == null || raw.trim().isEmpty) {
        if (mounted) {
          _updateDemoState(() {
            _activeConfigs = [];
            _configsReady = false;
          });
          _notifyDetailStateChanged();
        }
        _addLog('load BLE configs[$reason]: empty');
        return;
      }

      final configs = _decodeBleConfigs(raw);
      if (mounted) {
        // Keep UI state local to the example. Real apps should own config
        // persistence in their business layer and call `initConfigs` explicitly.
        _updateDemoState(() {
          _activeConfigs = configs;
        });
        _notifyDetailStateChanged();
      }
      _addLog(
        'load BLE configs[$reason]: '
        '${configs.map((config) => '${config.name}:${config.scan.matchCount}').join(', ')}',
      );
    } catch (error) {
      if (mounted) {
        _updateDemoState(() {
          _activeConfigs = [];
          _configsReady = false;
        });
        _notifyDetailStateChanged();
      }
      _addLog('load BLE configs[$reason] failed: $error');
    }
  }

  /// Adds or replaces runtime BLE configs pasted by the user.
  ///
  /// Config names are treated as stable IDs. Pasting a config with an existing
  /// name updates that entry, while different names are appended so G2/R1/etc.
  /// can coexist in one search session.
  Future<void> _saveBleConfigFromJson(String rawJson) async {
    try {
      final incomingConfigs = _decodeBleConfigs(rawJson);
      final configsByName = <String, BleConfig>{
        for (final config in _activeConfigs) config.name: config,
      };
      for (final config in incomingConfigs) {
        configsByName[config.name] = config;
      }
      final configs = configsByName.values.toList(growable: false);
      final prefs = await SharedPreferences.getInstance();
      // Persist as an array even when one object was pasted. This keeps the
      // cache shape stable after the first multi-config edit.
      await prefs.setString(
        _bleConfigCacheKey,
        jsonEncode(
          configs.map((config) => config.customToJson()).toList(),
        ),
      );
      await _clearLastDevice();
      _updateDemoState(() {
        // A config edit can change scan rules or services, so clear stale scan
        // and connection state instead of pretending old rows are still valid.
        _activeConfigs = configs;
        _selectedDevice = null;
        _scanResults.clear();
        _connectStates.clear();
      });
      _notifyDetailStateChanged();
      await _initConfigs();
      _addLog(
        'BLE configs cached: '
        '${incomingConfigs.map((config) => config.name).join(', ')}',
      );
    } catch (error) {
      _addLog('BLE configs save failed: $error');
      rethrow;
    }
  }

  /// Deletes one runtime BLE config and removes dependent demo state.
  ///
  /// Removing a config invalidates scan results and cached devices that were
  /// produced by that config, but leaves unrelated configs available.
  Future<void> _deleteBleConfig(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final nextConfigs = _activeConfigs
        .where((config) => config.name != name)
        .toList(growable: false);
    if (nextConfigs.isEmpty) {
      await prefs.remove(_bleConfigCacheKey);
    } else {
      await prefs.setString(
        _bleConfigCacheKey,
        jsonEncode(
          nextConfigs.map((config) => config.customToJson()).toList(),
        ),
      );
    }
    final selectedUsesRemovedConfig = _selectedDevice?.devices.any(
          (device) => device.belongConfig == name,
        ) ??
        false;
    if (selectedUsesRemovedConfig) {
      // The detail page cannot safely reconnect a device after its config was
      // removed because native no longer knows which services to initialize.
      await _clearLastDevice();
    }
    _updateDemoState(() {
      _activeConfigs = nextConfigs;
      _configsReady = false;
      // Scan rows are config-derived. Keep rows from other configs so users do
      // not lose unrelated search context.
      _scanResults.removeWhere((match) {
        return match.devices.any((device) => device.belongConfig == name);
      });
      if (selectedUsesRemovedConfig) {
        _selectedDevice = null;
        _connectStates.clear();
      }
    });
    _notifyDetailStateChanged();
    await _initConfigs();
    _addLog('BLE config removed: $name');
  }

  /// Decodes pasted or cached BLE config JSON into validated runtime configs.
  ///
  /// The example accepts both the legacy single-object shape and the current
  /// array shape so users can paste one G2/R1 config or a complete config list.
  List<BleConfig> _decodeBleConfigs(String rawJson) {
    final decoded = jsonDecode(rawJson);
    final List<dynamic> entries;
    if (decoded is List) {
      // New cache format: a list allows G2, R1, and future configs to coexist.
      entries = decoded;
    } else if (decoded is Map) {
      // Backward-compatible paste path: a single config is normalized to a list.
      entries = [decoded];
    } else {
      throw const FormatException(
        'BLE config must be a JSON object or array',
      );
    }

    final configs = entries.map((entry) {
      if (entry is! Map) {
        throw const FormatException('Each BLE config must be a JSON object');
      }
      final configJson = _applyPlatformOverrides(
        Map<String, dynamic>.from(entry),
      );
      return BleConfig.fromJson(configJson);
    }).toList(growable: false);

    if (configs.isEmpty) {
      throw const FormatException('At least one BLE config is required');
    }
    final names = <String>{};
    for (final config in configs) {
      final name = config.name.trim();
      if (name.isEmpty) {
        throw const FormatException('BLE config name is required');
      }
      // `name` is the native routing key (`belongConfig`), so duplicates would
      // make scan rows and connect requests ambiguous.
      if (!names.add(name)) {
        throw FormatException('Duplicate BLE config name: $name');
      }
      // Scan and private services are the minimum required data for native to
      // discover a target and build the GATT readiness pipeline.
      if (config.scan.nameFilters.isEmpty) {
        throw FormatException('BLE scan nameFilters is required: $name');
      }
      if (config.privateServices.isEmpty) {
        throw FormatException('BLE privateServices is required: $name');
      }
    }
    return configs;
  }

  /// Applies optional platform-specific JSON overrides before model decoding.
  ///
  /// Runtime configs may need different scan offsets on iOS and Android. The
  /// example keeps source control free of real BLE constants by allowing pasted
  /// JSON to carry a generic `platformOverrides`/`platforms` section instead of
  /// hardcoding product rules in Dart.
  Map<String, dynamic> _applyPlatformOverrides(Map<String, dynamic> source) {
    final merged = _deepJsonCopy(source);
    final platformOverride = _resolvePlatformOverride(merged);
    if (platformOverride != null) {
      // Deep merge lets a config override only `scan.snRule.startSubIndex`
      // without duplicating the whole BleConfig object for each platform.
      _deepMergeJsonMap(merged, platformOverride);
    }

    // These metadata sections are for example-side decoding only. Remove them
    // before calling `BleConfig.fromJson` so native receives the stable model.
    merged.remove('platformOverrides');
    merged.remove('platforms');
    return merged;
  }

  /// Selects the override object for the current runtime platform.
  ///
  /// Supported shapes:
  /// `{ "platformOverrides": { "ios": { ... }, "android": { ... } } }`
  /// and `{ "platforms": { "ios": { ... }, "android": { ... } } }`.
  Map<String, dynamic>? _resolvePlatformOverride(Map<String, dynamic> source) {
    final platformKey = Platform.isIOS
        ? 'ios'
        : Platform.isAndroid
            ? 'android'
            : null;
    if (platformKey == null) {
      return null;
    }

    // Try both accepted metadata keys so users can choose a readable JSON name.
    for (final sectionKey in const ['platformOverrides', 'platforms']) {
      final section = source[sectionKey];
      if (section is! Map) {
        continue;
      }
      final override = section[platformKey];
      if (override is Map) {
        return _deepJsonCopy(Map<String, dynamic>.from(override));
      }
    }
    return null;
  }

  /// Deep-copies a JSON-like map into mutable `Map<String, dynamic>` objects.
  ///
  /// Pasted JSON is decoded as nested `Map<dynamic, dynamic>`/`List<dynamic>`;
  /// copying avoids mutating the original decoded object and gives merge code a
  /// consistent map type.
  Map<String, dynamic> _deepJsonCopy(Map<String, dynamic> source) {
    return source.map((key, value) {
      return MapEntry(key, _deepJsonValueCopy(value));
    });
  }

  /// Deep-copies one JSON value.
  ///
  /// Only maps and lists need structural copies; scalars can be reused safely.
  dynamic _deepJsonValueCopy(dynamic value) {
    if (value is Map) {
      return _deepJsonCopy(Map<String, dynamic>.from(value));
    }
    if (value is List) {
      return value.map(_deepJsonValueCopy).toList(growable: false);
    }
    return value;
  }

  /// Deep-merges `override` into `target`.
  ///
  /// Nested maps are merged recursively; all other values replace the target
  /// field. This matches how platform scan rules usually override only the
  /// offsets while keeping shared filters/services at the top level.
  void _deepMergeJsonMap(
    Map<String, dynamic> target,
    Map<String, dynamic> override,
  ) {
    for (final entry in override.entries) {
      final current = target[entry.key];
      final next = entry.value;
      if (current is Map && next is Map) {
        // Merge into a fresh child map first; assigning it back keeps the
        // original decoded map immutable from the caller's point of view.
        final mergedChild = Map<String, dynamic>.from(current);
        _deepMergeJsonMap(mergedChild, Map<String, dynamic>.from(next));
        target[entry.key] = mergedChild;
        continue;
      }
      target[entry.key] = _deepJsonValueCopy(next);
    }
  }

  Future<bool> _ensureBlePermissions() async {
    if (Platform.isIOS) {
      final status = await ph.Permission.bluetooth.request();
      final granted = status.isGranted || status.isLimited;
      _addLog('permission: iOS bluetooth=$status');
      return granted;
    }
    if (!Platform.isAndroid) {
      return true;
    }

    final permissions = <ph.Permission>[
      ph.Permission.bluetoothScan,
      ph.Permission.bluetoothConnect,
    ];
    final androidSdk = _androidSdkInt();
    if (androidSdk != null && androidSdk <= 30) {
      permissions.add(ph.Permission.locationWhenInUse);
    }
    final statuses = await permissions.request();
    final denied = statuses.entries.where((entry) {
      final status = entry.value;
      return !status.isGranted && !status.isLimited;
    }).toList();
    _addLog(
      'permission: Android sdk=${androidSdk ?? 'unknown'} ${statuses.entries.map((entry) => '${entry.key}=${entry.value}').join(', ')}',
    );
    return denied.isEmpty;
  }

  int? _androidSdkInt() {
    final match = RegExp(
      r'SDK (\d+)',
    ).firstMatch(Platform.operatingSystemVersion);
    return int.tryParse(match?.group(1) ?? '');
  }

  Future<void> _stopScan() async {
    try {
      await _ble.bleMC.stopScan();
      setState(() => _scanning = false);
      _addLog('stopScan: ok');
    } catch (error) {
      _addLog('stopScan: $error');
    }
  }

  /// Updates widget state from helper extensions without exposing raw setState.
  void _updateDemoState(VoidCallback update) {
    if (!mounted) {
      return;
    }
    setState(update);
  }

  Future<void> _openSearchPage(BuildContext routeContext) async {
    final navigator = Navigator.maybeOf(routeContext);
    if (navigator == null) {
      _addLog('open search failed: route navigator not ready');
      return;
    }

    if (_searchOpen && navigator.canPop()) {
      _addLog('open search ignored: search route already open');
      return;
    }
    if (_searchOpen) {
      _addLog('open search recovered: stale route lock cleared');
      _searchOpen = false;
    }

    _searchOpen = true;
    _addLog('open search requested');
    try {
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => _SearchPage(
            platformVersion: _platformVersion,
            bleState: _bleState,
            scanning: () => _scanning,
            connecting: () => _connecting,
            activeConfigs: () => _activeConfigs,
            requiredMatchCount: _requiredMatchCountFor,
            scanResults: _scanResults,
            selectedDevice: () => _selectedDevice,
            stateVersion: _logVersion,
            onStartScan: _startScan,
            onStopScan: _stopScan,
            onSaveConfig: _saveBleConfigFromJson,
            onDeleteConfig: _deleteBleConfig,
            onConnect: _connectDevice,
          ),
        ),
      );
    } catch (error, stackTrace) {
      _addLog('open search failed: $error');
      debugPrint('$stackTrace');
    } finally {
      _searchOpen = false;
      _addLog('open search finished');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: Scaffold(
        key: const ValueKey('ble-auto-reconnect-home'),
        appBar: AppBar(title: const Text('BLE Auto Reconnect')),
        body: SafeArea(
          child: _selectedDevice == null
              ? _EmptyDeviceHome(onAddDevice: _openSearchPage)
              : _DeviceDetailContent(
                  device: _selectedDevice!,
                  logs: _logs,
                  logVersion: _logVersion,
                  legState: _selectedLegState,
                  primaryActionLabel: _detailPrimaryActionLabel,
                  primaryActionIcon: _detailPrimaryActionIcon,
                  primaryActionEnabled: _detailPrimaryActionEnabled,
                  onPrimaryAction: _handleDetailPrimaryAction,
                  onRemove: () async {
                    await _disconnectSelected(removeBond: true);
                    await _clearLastDevice();
                    if (mounted) {
                      _updateDemoState(() {
                        _selectedDevice = null;
                        _scanResults.clear();
                      });
                      _notifyDetailStateChanged();
                    }
                  },
                ),
        ),
      ),
    );
  }
}
