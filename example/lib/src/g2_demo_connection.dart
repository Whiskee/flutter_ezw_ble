part of '../main.dart';

// G2 demo connection and business-auth flow.
//
// Keeping this as an extension leaves _MyAppState responsible for page setup and
// rendering, while this file owns reconnect orchestration, two-leg sequencing,
// authentication callbacks, persistence, and log identity helpers.

extension _G2DemoConnectionFlow on _MyAppState {
  /// Starts a user-initiated foreground connect flow from a scan result.
  Future<void> _connectDevice(BleMatchDevice match) async {
    if (!_hasActiveConfigs || !_configsReady) {
      _addLog('connectFlow blocked: BLE configs missing');
      return;
    }
    if (_connecting) {
      if (_isStaleG2ConnectFlow()) {
        _stopG2ConnectFlow(
          'connectFlow stale before search item connect: sn=${match.sn}',
        );
      } else {
        _addLog(
          'connectFlow ignored: already connecting, '
          'requestedSn=${match.sn} aggregate=[${_connectSnapshot()}]',
        );
        _notifyDetailStateChanged();
        return;
      }
    }
    await _startG2ConnectFlow(match, directConnect: false, stopScanFirst: true);
  }

  /// Initializes one two-leg G2 connect session and resets stale session state.
  Future<void> _startG2ConnectFlow(
    BleMatchDevice match, {
    required bool directConnect,
    required bool stopScanFirst,
    bool preserveKnownConnectStates = false,
  }) async {
    if (!_hasActiveConfigs || !_configsReady) {
      _addLog('connectFlow blocked: BLE configs missing');
      return;
    }
    final sequence = _sortedG2Legs(match.devices);
    if (sequence.isEmpty) {
      return;
    }
    final flowEpoch = _connectEpoch + 1;
    _addLog(
      'connectFlow start: sn=${match.sn} epoch=$flowEpoch '
      'directConnect=$directConnect stopScanFirst=$stopScanFirst '
      'devices=${sequence.indexed.map((entry) => _g2LegIdentity(entry.$2, entry.$1)).join(' ; ')}',
    );
    _cancelActiveG2AuthTimer();
    _updateDemoState(() {
      _selectedDevice = match.copy();
      _connecting = true;
      _connectStartedAt = DateTime.now();
      _g2ConnectDirectConnect = directConnect;
      _startingNextG2Leg = false;
      _connectEpoch++;
      _connectFinishAcked.clear();
      _businessConnectStarted.clear();
      _g2AuthEpochs.clear();
      _pendingG2AuthQueue.clear();
      _pendingG2ConnectLegs
        ..clear()
        ..addAll(sequence);
      _requestedG2ConnectUuids.clear();
      _activeG2AuthUuid = null;
      _activeG2AuthEpoch = null;
      for (final device in match.devices) {
        final knownState = _connectStates[device.uuid];
        final shouldPreserve = preserveKnownConnectStates &&
            knownState != null &&
            !knownState.isDisconnected &&
            !knownState.isError;
        if (!shouldPreserve) {
          _connectStates.remove(device.uuid);
        }
      }
    });
    _notifyDetailStateChanged();
    _startConnectWatchdog(match);
    if (preserveKnownConnectStates) {
      await _replaySelectedConnectStates('connectFlow restore');
    }
    if (stopScanFirst) {
      await _stopScan();
    }
    await _connectNextG2LegIfNeeded(
      preserveKnownConnectStates: preserveKnownConnectStates,
    );
  }

  /// Sends the next serial leg connect request when the current leg is ready.
  Future<void> _connectNextG2LegIfNeeded({
    bool preserveKnownConnectStates = false,
  }) async {
    if (!_connecting || _startingNextG2Leg) {
      return;
    }
    final selected = _selectedDevice;
    if (selected == null || _pendingG2ConnectLegs.isEmpty) {
      return;
    }

    BleDevice? nextDevice;
    var nextIndex = -1;
    for (var index = 0; index < _pendingG2ConnectLegs.length; index++) {
      final device = _pendingG2ConnectLegs[index];
      if (_connectStates[device.uuid]?.isConnected == true ||
          _requestedG2ConnectUuids.contains(device.uuid)) {
        continue;
      }
      nextDevice = device;
      nextIndex = index;
      break;
    }
    if (nextDevice == null) {
      return;
    }
    final device = nextDevice;

    _startingNextG2Leg = true;
    _requestedG2ConnectUuids.add(device.uuid);
    try {
      if (mounted) {
        _updateDemoState(() {
          final knownState = _connectStates[device.uuid];
          final shouldPreserve = preserveKnownConnectStates &&
              knownState != null &&
              !knownState.isDisconnected &&
              !knownState.isError;
          if (!shouldPreserve) {
            _connectStates[device.uuid] = BleConnectState.connecting;
          }
        });
        _notifyDetailStateChanged();
      }
      _addLog(
        'connectFlow leg connecting(serial): epoch=$_connectEpoch '
        '${_g2LegIdentity(device, nextIndex)} '
        'aggregate=[${_connectSnapshot(selected)}]',
      );
      await _ble.bleMC.connectDevice(
        device.belongConfig,
        device.uuid,
        device.name,
        sn: device.sn,
        directConnect: _g2ConnectDirectConnect,
      );
      _addLog(
        'connectFlow leg request sent(serial): epoch=$_connectEpoch '
        'directConnect=$_g2ConnectDirectConnect '
        '${_g2LegIdentity(device, nextIndex)}',
      );
    } catch (error) {
      _stopG2ConnectFlow(
        'connectDevice failed: ${_g2LegIdentity(device, nextIndex)} '
        '$error',
      );
    } finally {
      _startingNextG2Leg = false;
    }
  }

  /// Disconnects the selected G2 and optionally removes the system bond/cache.
  Future<void> _disconnectSelected({bool removeBond = false}) async {
    final device = _selectedDevice;
    if (device == null) {
      return;
    }
    _connectFinishAcked.removeAll(device.devices.map((item) => item.uuid));
    _businessConnectStarted.removeAll(device.devices.map((item) => item.uuid));
    _g2AuthEpochs.clear();
    _pendingG2AuthQueue.clear();
    _pendingG2ConnectLegs.clear();
    _requestedG2ConnectUuids.clear();
    _startingNextG2Leg = false;
    _cancelActiveG2AuthTimer();
    _activeG2AuthUuid = null;
    _activeG2AuthEpoch = null;
    _connectEpoch++;
    _cancelConnectWatchdog();
    _cancelPendingG2Commands(
      device.devices.map((item) => item.uuid),
      StateError(removeBond ? 'removed' : 'disconnected'),
    );
    for (final item in device.devices) {
      await _ble.bleMC.disconnectDevice(
        item.uuid,
        item.name,
        removeBond: removeBond,
      );
    }
    if (mounted) {
      _updateDemoState(() {
        _connecting = false;
        for (final item in device.devices) {
          _connectStates[item.uuid] = BleConnectState.disconnectByUser;
        }
      });
      _notifyDetailStateChanged();
    }
    _addLog(removeBond ? 'remove: complete' : 'disconnect: ok');
  }

  /// Returns the reconnect route used for cached/detail reconnects.
  bool _shouldUseDirectReconnect() {
    // Android stores a real Bluetooth address, so direct reconnect is the
    // fastest stable path. iOS stores a CoreBluetooth identifier, which can be
    // stale after cold launch, restoration, reinstall, or system cache churn;
    // scan-first lets native refresh the identifier from the current broadcast
    // while still allowing retrieveConnectedPeripherals for system-connected
    // devices that are no longer advertising.
    return !Platform.isIOS;
  }

  /// Starts a reconnect for the persisted/selected device.
  Future<void> _reconnectSelected() async {
    final device = _selectedDevice;
    if (device == null) {
      return;
    }
    if (_connecting) {
      if (_isStaleG2ConnectFlow()) {
        _stopG2ConnectFlow(
          'connectFlow stale before detail reconnect: sn=${device.sn}',
        );
      } else {
        _addLog(
          'reconnect ignored: already connecting, '
          'sn=${device.sn} aggregate=[${_connectSnapshot()}]',
        );
        _notifyDetailStateChanged();
        return;
      }
    }
    if (_isSelectedWholeConnected()) {
      return;
    }
    await _startG2ConnectFlow(
      device,
      directConnect: _shouldUseDirectReconnect(),
      stopScanFirst: false,
    );
    _addLog('reconnect requested');
  }

  /// Restarts cached-device recovery when BLE becomes available after startup.
  Future<void> _handleBleAvailable(
    String reason, {
    bool forceRestartConnecting = false,
  }) async {
    if (_bleAvailableRecoveryRunning) {
      _addLog(
          'BLE available recovery ignored: already running, reason=$reason');
      return;
    }
    if (!_configsReady) {
      _addLog(
          'BLE available recovery deferred: configs not ready, reason=$reason');
      return;
    }

    _bleAvailableRecoveryRunning = true;
    try {
      await _drainAutoReconnectEvents(reason);
      final selected = _selectedDevice;
      if (selected == null) {
        final restored =
            await _restoreLastDevice(reason: reason, logMissing: true);
        if (!restored) {
          _addLog('BLE available recovery: no cached device, reason=$reason');
        }
        return;
      }

      if (_isSelectedWholeConnected()) {
        _addLog(
          'BLE available recovery skipped: selected device already connected, '
          'reason=$reason aggregate=[${_connectSnapshot()}]',
        );
        return;
      }

      if (_connecting) {
        if (!forceRestartConnecting) {
          _addLog(
            'BLE available recovery skipped: connect already in progress, '
            'reason=$reason aggregate=[${_connectSnapshot()}]',
          );
          return;
        }
        _stopG2ConnectFlow(
          'BLE available recovery restart: reason=$reason sn=${selected.sn}',
        );
      }

      _addLog(
        'BLE available recovery: reconnect selected sn=${selected.sn} '
        'reason=$reason',
      );
      await _startG2ConnectFlow(
        selected,
        directConnect: _shouldUseDirectReconnect(),
        stopScanFirst: false,
        preserveKnownConnectStates: true,
      );
    } finally {
      _bleAvailableRecoveryRunning = false;
    }
  }

  /// Replays cached native connect events after local device restore.
  Future<void> _replaySelectedConnectStates(String reason) async {
    final selected = _selectedDevice;
    if (selected == null) {
      return;
    }
    final replayEvents = selected.devices
        .map((device) => _latestConnectEvents[device.uuid])
        .whereType<BleConnectModel>()
        .where((event) {
      return event.connectState.isConnectFinish ||
          event.connectState.isConnected;
    }).toList();
    if (replayEvents.isEmpty) {
      return;
    }
    _addLog(
      'replay connectStatus: reason=$reason '
      'events=${replayEvents.map((event) => '${_shortUuid(event.uuid)}:${event.connectState.name}').join(', ')}',
    );
    for (final event in replayEvents) {
      if (_isSelectedUuid(event.uuid)) {
        await _handleSelectedConnectState(event);
      }
    }
  }

  /// Returns true when an event belongs to the current detail device.
  bool _isSelectedUuid(String uuid) {
    final selected = _selectedDevice;
    if (selected == null) {
      return false;
    }
    return selected.devices.any((device) => device.uuid == uuid);
  }

  /// Handles native connect state and converts connectFinish into G2 auth.
  Future<void> _handleSelectedConnectState(BleConnectModel state) async {
    if (state.connectState.isConnectFinish &&
        !_connectFinishAcked.contains(state.uuid)) {
      _resumeBusinessConnectFlowIfNeeded('native connectFinish');
      _connectFinishAcked.add(state.uuid);
      _g2AuthEpochs[state.uuid] = _connectEpoch;
      _addLog(
        'connectFinish -> AUTHENTICATION queued: '
        '${_selectedLegIdentity(state.uuid, state.name)} epoch=$_connectEpoch '
        'aggregate=[${_connectSnapshot()}]',
      );
      _queueG2Authentication(state.uuid);
    }

    final selected = _selectedDevice;
    if (selected == null) {
      return;
    }
    if (_connecting && state.connectState == BleConnectState.disconnectByUser) {
      _addLog(
        'ignore stale disconnectByUser while connecting: '
        '${_selectedLegIdentity(state.uuid, state.name)} '
        'aggregate=[${_connectSnapshot()}]',
      );
      return;
    }
    final terminalFailure =
        state.connectState.isError || state.connectState.isDisconnectFromSys;
    if (terminalFailure) {
      _stopG2ConnectFlow(
        'connect stopped: ${_selectedLegIdentity(state.uuid, state.name)} '
        'state=${state.connectState.name} aggregate=[${_connectSnapshot()}]',
      );
      return;
    }

    final allConnected = selected.devices.every((device) {
      return _connectStates[device.uuid]?.isConnected == true;
    });
    if (allConnected) {
      _cancelConnectWatchdog();
      await _saveLastDevice(selected);
      _pendingG2ConnectLegs.clear();
      _requestedG2ConnectUuids.clear();
      _connectStartedAt = null;
      _updateDemoState(() => _connecting = false);
      _notifyDetailStateChanged();
      _addLog(
        'connectFlow all connected: sn=${selected.sn} '
        'aggregate=[${_connectSnapshot()}]',
      );
      _closeSearchPageIfOpen();
      return;
    }

    if (_connecting && state.connectState.isConnected) {
      await _connectNextG2LegIfNeeded();
    }
  }

  /// Resumes visible connecting state when native recovery races ahead of UI.
  void _resumeBusinessConnectFlowIfNeeded(String reason) {
    final selected = _selectedDevice;
    if (_connecting || selected == null || _isSelectedWholeConnected()) {
      return;
    }
    _updateDemoState(() => _connecting = true);
    _startConnectWatchdog(selected);
    _notifyDetailStateChanged();
    _addLog(
      'connectFlow resumed: reason=$reason '
      'epoch=$_connectEpoch aggregate=[${_connectSnapshot()}]',
    );
  }

  /// Returns to the home detail page after a search-list connect succeeds.
  void _closeSearchPageIfOpen() {
    if (!_searchOpen) {
      return;
    }
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      _addLog('close search failed: navigator not ready');
      return;
    }
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  /// Computes the single detail-page primary action label.
  String _detailPrimaryActionLabel() {
    if (_isSelectedConnectInProgress()) {
      return 'Connecting';
    }
    return _isSelectedWholeConnected() ? 'Disconnect' : 'Reconnect';
  }

  /// Computes the single detail-page primary action icon.
  IconData _detailPrimaryActionIcon() {
    if (_isSelectedConnectInProgress()) {
      return Icons.sync;
    }
    return _isSelectedWholeConnected()
        ? Icons.link_off
        : Icons.bluetooth_connected;
  }

  /// Disables manual actions while a connect session is in progress.
  bool _detailPrimaryActionEnabled() => !_isSelectedConnectInProgress();

  /// Routes the detail primary button to disconnect or reconnect.
  Future<void> _handleDetailPrimaryAction() {
    if (_isSelectedConnectInProgress()) {
      _addLog(
        'detail action ignored: connect in progress '
        'aggregate=[${_connectSnapshot()}]',
      );
      _notifyDetailStateChanged();
      return Future.value();
    }
    if (_isSelectedWholeConnected()) {
      return _disconnectSelected();
    }
    return _reconnectSelected();
  }

  /// Returns the latest native/business state for one selected detail leg.
  BleConnectState _selectedLegState(String uuid) {
    return _connectStates[uuid] ?? BleConnectState.none;
  }

  /// Returns true while any selected G2 leg is still inside connect readiness.
  bool _isSelectedConnectInProgress() {
    if (_connecting) {
      return true;
    }
    final selected = _selectedDevice;
    if (selected == null || _isSelectedWholeConnected()) {
      return false;
    }
    return selected.devices.any((device) {
      final state = _connectStates[device.uuid];
      return state != null && state.isConnecting;
    });
  }

  /// Returns true only when every selected G2 leg is business-connected.
  bool _isSelectedWholeConnected() {
    final selected = _selectedDevice;
    if (selected == null) {
      return false;
    }
    return selected.devices.every((device) {
      return _connectStates[device.uuid]?.isConnected == true;
    });
  }

  /// Persists reconnect identity after both legs are connected.
  Future<void> _saveLastDevice(BleMatchDevice device) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        'sn': device.sn,
        'devices': _sortedG2Legs(device.devices).map((item) {
          return <String, dynamic>{
            'belongConfig': item.belongConfig,
            'uuid': item.uuid,
            'name': item.name,
            'sn': item.sn,
            'rssi': item.rssi,
            'mac': item.mac,
          };
        }).toList(),
      };
      await prefs.setString(_MyAppState._lastG2DeviceKey, jsonEncode(payload));
      _addLog('cached device: sn=${device.sn}');
    } catch (error) {
      _addLog('cache device failed: $error');
    }
  }

  /// Clears persisted reconnect identity after full remove.
  Future<void> _clearLastDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_MyAppState._lastG2DeviceKey);
      _addLog('cached device removed');
    } catch (error) {
      _addLog('remove cached device failed: $error');
    }
  }

  /// Restores the last connected G2 and immediately starts native direct connect.
  Future<bool> _restoreLastDevice({
    String reason = 'bootstrap',
    bool logMissing = false,
  }) async {
    if (!mounted || _selectedDevice != null || !_hasActiveConfigs) {
      return false;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_MyAppState._lastG2DeviceKey);
      if (raw == null || raw.isEmpty) {
        if (logMissing) {
          _addLog('restore cached device skipped: no cache, reason=$reason');
        }
        return false;
      }
      final device = _decodeCachedDevice(raw);
      if (device == null || device.devices.isEmpty) {
        await prefs.remove(_MyAppState._lastG2DeviceKey);
        _addLog('cached device invalid, removed');
        return false;
      }
      final config = _configForMatch(device);
      if (config == null || device.devices.length < config.scan.matchCount) {
        await prefs.remove(_MyAppState._lastG2DeviceKey);
        _addLog('cached device invalid, removed');
        return false;
      }
      final configMismatch = device.devices
          .any((item) => _configByName(item.belongConfig) == null);
      if (configMismatch) {
        await prefs.remove(_MyAppState._lastG2DeviceKey);
        _addLog('cached device invalid, removed');
        return false;
      }
      _updateDemoState(() {
        _selectedDevice = device.copy();
        final index = _scanResults.indexWhere((item) {
          return item.isSameDevice(device) || item.sn == device.sn;
        });
        if (index >= 0) {
          _scanResults[index] = device;
        } else {
          _scanResults.insert(0, device);
        }
      });
      _addLog('restore cached device: sn=${device.sn} reason=$reason');
      await _startG2ConnectFlow(
        device,
        directConnect: _shouldUseDirectReconnect(),
        stopScanFirst: false,
        preserveKnownConnectStates: true,
      );
      return true;
    } catch (error) {
      _addLog('restore cached device failed: $error');
      return false;
    }
  }

  /// Decodes persisted identity without trusting old or partial cache payloads.
  BleMatchDevice? _decodeCachedDevice(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final sn = decoded['sn'];
    final devicesJson = decoded['devices'];
    if (sn is! String || devicesJson is! List) {
      return null;
    }
    final devices = <BleDevice>[];
    for (final item in devicesJson) {
      if (item is! Map) {
        continue;
      }
      final map = Map<String, dynamic>.from(item);
      final belongConfig = map['belongConfig'];
      final uuid = map['uuid'];
      final name = map['name'];
      final deviceSn = map['sn'];
      if (belongConfig is! String ||
          uuid is! String ||
          name is! String ||
          deviceSn is! String) {
        continue;
      }
      devices.add(
        BleDevice(
          belongConfig,
          uuid,
          name,
          deviceSn,
          map['rssi'] is int ? map['rssi'] as int : 0,
          mac: map['mac'] is String ? map['mac'] as String : '',
        ),
      );
    }
    if (devices.isEmpty) {
      return null;
    }
    return BleMatchDevice(sn, devices: devices);
  }

  /// Handles common-service notifications and resolves pending G2 commands.
  Future<void> _handleG2ReceiveData(BleCmd cmd) async {
    if (cmd.psType != _MyAppState._g2CommonPsType || cmd.data == null) {
      return;
    }
    final transport = _G2Transport.tryParse(cmd.data!);
    if (transport == null ||
        transport.serviceId != _MyAppState._g2DeviceSettingsServiceId) {
      if (_isSelectedUuid(cmd.uuid)) {
        _addLog(
          'G2 receive ignored: ${_selectedLegIdentity(cmd.uuid)} '
          'parse=${transport == null ? 'transport-failed' : 'service-${transport.serviceId}'} '
          'len=${cmd.data?.length ?? 0}',
        );
      }
      return;
    }
    final devCfg = _G2DevCfgPackage.tryParse(transport.payload);
    if (devCfg == null) {
      if (_isSelectedUuid(cmd.uuid)) {
        _addLog(
          'G2 receive devCfg decode failed: ${_selectedLegIdentity(cmd.uuid)} '
          'result=${transport.resultCode} crc=${transport.isCrcCorrect} '
          'payloadLen=${transport.payload.length}',
        );
      }
      _completePendingG2Command(
        cmd.uuid,
        transport.serviceId,
        -1,
        StateError('dev config decode failed'),
      );
      return;
    }

    final pendingKey =
        _pendingG2Key(cmd.uuid, transport.serviceId, devCfg.magicRandom);
    final pending = _pendingG2Commands.remove(pendingKey);
    if (_isSelectedUuid(cmd.uuid)) {
      _addLog(
        'G2 receive: ${_selectedLegIdentity(cmd.uuid)} '
        'cmd=0x${devCfg.commandId.toRadixString(16)} magic=${devCfg.magicRandom} '
        'success=${transport.isSuccess} crc=${transport.isCrcCorrect} '
        'authSecAuth=${devCfg.authSecAuth} pending=${pending != null}',
      );
    }
    if (pending != null) {
      if (transport.isSuccess && transport.isCrcCorrect) {
        pending.complete(devCfg);
      } else {
        pending.fail(
          StateError(
            'transport failed result=${transport.resultCode} crc=${transport.isCrcCorrect}',
          ),
        );
      }
    }

    if (_isSelectedUuid(cmd.uuid) &&
        transport.isSuccess &&
        transport.isCrcCorrect &&
        devCfg.commandId == _MyAppState._g2AuthCommandId &&
        devCfg.authSecAuth == true) {
      final authEpoch = _g2AuthEpochs[cmd.uuid];
      if (authEpoch != null) {
        _addLog(
          'AUTHENTICATION success callback: ${_selectedLegIdentity(cmd.uuid)} '
          'authEpoch=$authEpoch currentEpoch=$_connectEpoch',
        );
        _cancelActiveG2AuthTimer();
        await _completeG2BusinessConnect(cmd.uuid, authEpoch);
        _finishActiveG2Authentication(cmd.uuid, authEpoch);
      } else {
        _addLog(
          'AUTHENTICATION success without active epoch: '
          '${_selectedLegIdentity(cmd.uuid)} currentEpoch=$_connectEpoch',
        );
      }
    }
  }

  /// Queues authentication so only one leg auth exchange is active at a time.
  void _queueG2Authentication(String uuid) {
    if (_pendingG2AuthQueue.any((item) => item == uuid) ||
        _activeG2AuthUuid == uuid) {
      _addLog(
          'AUTHENTICATION queue ignored duplicate: ${_selectedLegIdentity(uuid)}');
      return;
    }
    _pendingG2AuthQueue.add(uuid);
    _addLog(
      'AUTHENTICATION queue size=${_pendingG2AuthQueue.length} '
      'active=${_activeG2AuthUuid ?? '-'}',
    );
    unawaited(_drainG2AuthenticationQueue());
  }

  /// Starts the next queued authentication request when the active one completes.
  Future<void> _drainG2AuthenticationQueue() async {
    if (!_connecting ||
        _activeG2AuthUuid != null ||
        _pendingG2AuthQueue.isEmpty) {
      _addLog(
        'AUTHENTICATION drain skipped: connecting=$_connecting '
        'active=${_activeG2AuthUuid ?? '-'} '
        'queue=${_pendingG2AuthQueue.length}',
      );
      return;
    }
    final uuid = _takeNextG2AuthUuid();
    if (uuid == null) {
      return;
    }
    final authEpoch = _g2AuthEpochs[uuid] ?? _connectEpoch;
    _activeG2AuthUuid = uuid;
    _activeG2AuthEpoch = authEpoch;
    _startActiveG2AuthTimer(uuid, authEpoch);
    _addLog(
      'AUTHENTICATION start(serial): ${_selectedLegIdentity(uuid)} '
      'authEpoch=$authEpoch queueLeft=${_pendingG2AuthQueue.length}',
    );
    try {
      await _sendG2StartPair(uuid);
    } catch (error) {
      if (_activeG2AuthUuid == uuid && _activeG2AuthEpoch == authEpoch) {
        _addLog(
          'AUTHENTICATION send wait failed, keep waiting success callback: '
          '${_selectedLegIdentity(uuid)} authEpoch=$authEpoch error=$error',
        );
      }
    }
  }

  /// Picks the next auth target, preferring the right leg for pipe setup.
  String? _takeNextG2AuthUuid() {
    if (_pendingG2AuthQueue.isEmpty) {
      return null;
    }
    final rightIndex = _pendingG2AuthQueue.indexWhere(_isRightLeg);
    final index = rightIndex >= 0 ? rightIndex : 0;
    return _pendingG2AuthQueue.removeAt(index);
  }

  /// Clears the active auth head after its success callback is accepted.
  void _finishActiveG2Authentication(String uuid, int authEpoch) {
    if (_activeG2AuthUuid != uuid || _activeG2AuthEpoch != authEpoch) {
      _addLog(
        'AUTHENTICATION success not active head: ${_selectedLegIdentity(uuid)} '
        'authEpoch=$authEpoch active=${_activeG2AuthUuid ?? '-'}',
      );
      return;
    }
    _cancelActiveG2AuthTimer();
    _activeG2AuthUuid = null;
    _activeG2AuthEpoch = null;
    _addLog(
      'AUTHENTICATION finish(serial): ${_selectedLegIdentity(uuid)} '
      'queueLeft=${_pendingG2AuthQueue.length}',
    );
    unawaited(_drainG2AuthenticationQueue());
  }

  /// Sends the G2 authentication request required before deviceConnected.
  Future<void> _sendG2StartPair(String uuid) async {
    _addLog(
      'AUTHENTICATION send start: ${_selectedLegIdentity(uuid)} '
      'epoch=$_connectEpoch',
    );
    final authMgr = _pbMessage([
      _pbVarintField(1, 1),
      _pbVarintField(2, Platform.isIOS ? 3 : 4),
    ]);
    await _sendG2DevCfgCommand(
      uuid,
      _MyAppState._g2AuthCommandId,
      oneofFieldNumber: 3,
      payload: authMgr,
      syncBoth: false,
      timeout: const Duration(milliseconds: 500),
      maxRetry: 1,
    );
    _addLog('AUTHENTICATION sent: $uuid');
  }

  /// Runs post-auth setup and notifies native that business connect is done.
  Future<void> _completeG2BusinessConnect(String uuid, int authEpoch) async {
    if (!_isActiveG2Auth(uuid, authEpoch)) {
      _addLog(
        'business connect skipped stale auth: ${_selectedLegIdentity(uuid)} '
        'authEpoch=$authEpoch currentEpoch=$_connectEpoch',
      );
      return;
    }
    if (!_businessConnectStarted.add(uuid)) {
      _addLog(
        'business connect duplicate ignored: ${_selectedLegIdentity(uuid)} '
        'epoch=$authEpoch',
      );
      return;
    }
    await _ble.bleMC.devicePreConnected(uuid);
    _addLog('devicePreConnected: ${_selectedLegIdentity(uuid)}');
    if (!_isActiveG2Auth(uuid, authEpoch)) {
      _addLog(
        'business connect stopped after preConnected: '
        '${_selectedLegIdentity(uuid)} authEpoch=$authEpoch currentEpoch=$_connectEpoch',
      );
      return;
    }
    try {
      if (_isRightLeg(uuid)) {
        await _sendG2SelectPipeChannel(uuid);
        if (!_isActiveG2Auth(uuid, authEpoch)) {
          _addLog(
            'business connect stopped after PIPE_ROLE_CHANGE: '
            '${_selectedLegIdentity(uuid)} authEpoch=$authEpoch currentEpoch=$_connectEpoch',
          );
          return;
        }
        await _sendG2TimeSync(uuid);
      }
    } catch (error) {
      _addLog('post-auth command failed: $uuid, $error');
    } finally {
      if (_isActiveG2Auth(uuid, authEpoch)) {
        await _ble.bleMC.deviceConnected(uuid);
        _addLog('deviceConnected: ${_selectedLegIdentity(uuid)}');
      }
    }
  }

  /// Selects the right-leg pipe channel after authentication.
  Future<void> _sendG2SelectPipeChannel(String uuid) async {
    final roleChange =
        _pbMessage([_pbVarintField(1, _MyAppState._g2RightRole)]);
    await _sendG2DevCfgCommand(
      uuid,
      _MyAppState._g2PipeRoleChangeCommandId,
      oneofFieldNumber: 4,
      payload: roleChange,
    );
    _addLog('PIPE_ROLE_CHANGE(RIGHT) sent: $uuid');
  }

  /// Sends current wall-clock time and timezone to the selected leg.
  Future<void> _sendG2TimeSync(String uuid) async {
    final now = DateTime.now();
    final timestamp = now.millisecondsSinceEpoch ~/ 1000;
    final hours = now.timeZoneOffset.inHours;
    final minutes = now.timeZoneOffset.inMinutes % 60;
    final timezone = (hours * 4 + (minutes ~/ 15)).clamp(-128, 128);
    final timeSync = _pbMessage([
      _pbVarintField(1, timestamp),
      _pbInt32Field(2, timezone),
    ]);
    await _sendG2DevCfgCommand(
      uuid,
      _MyAppState._g2TimeSyncCommandId,
      oneofFieldNumber: 0x80,
      payload: timeSync,
    );
    _addLog('TIME_SYNC sent: $uuid');
  }

  /// Sends one device-settings command and waits for the matching response.
  Future<_G2DevCfgPackage> _sendG2DevCfgCommand(
    String uuid,
    int commandId, {
    required int oneofFieldNumber,
    required Uint8List payload,
    bool syncBoth = true,
    Duration timeout = const Duration(milliseconds: 1000),
    int maxRetry = 1,
  }) async {
    final magicRandom = _nextG2MagicNum();
    final devCfg = _pbMessage([
      _pbVarintField(1, commandId),
      _pbVarintField(2, magicRandom),
      _pbBytesField(oneofFieldNumber, payload),
    ]);
    final data = _buildG2Transport(
      devCfg,
      serviceId: _MyAppState._g2DeviceSettingsServiceId,
      syncBoth: syncBoth,
    );
    final pendingKey = _pendingG2Key(
        uuid, _MyAppState._g2DeviceSettingsServiceId, magicRandom);

    Object? lastError;
    for (var attempt = 0; attempt <= maxRetry; attempt++) {
      final pending = _PendingG2Command(commandId);
      _pendingG2Commands[pendingKey] = pending;
      await _ble.bleMC.sendCmd(uuid, data, psType: _MyAppState._g2CommonPsType);
      _addLog(
        'send G2 cmd: ${_selectedLegIdentity(uuid)} '
        'commandId=0x${commandId.toRadixString(16)} magic=$magicRandom '
        'attempt=${attempt + 1}/${maxRetry + 1} timeout=${timeout.inMilliseconds}ms',
      );
      try {
        return await pending.completer.future.timeout(timeout);
      } catch (error) {
        lastError = error;
        _addLog(
          'G2 cmd wait failed: ${_selectedLegIdentity(uuid)} '
          'commandId=0x${commandId.toRadixString(16)} magic=$magicRandom '
          'attempt=${attempt + 1}/${maxRetry + 1} error=$error',
        );
        if (_pendingG2Commands[pendingKey] == pending) {
          _pendingG2Commands.remove(pendingKey);
        }
      }
    }
    throw TimeoutException(
      'G2 command 0x${commandId.toRadixString(16)} timeout: $lastError',
      timeout,
    );
  }

  /// Fails and removes one pending command by transport identity.
  void _completePendingG2Command(
    String uuid,
    int serviceId,
    int magicRandom,
    Object error,
  ) {
    final pending = _pendingG2Commands.remove(
      _pendingG2Key(uuid, serviceId, magicRandom),
    );
    pending?.fail(error);
  }

  /// Builds the pending-command key used to match async notifications.
  String _pendingG2Key(String uuid, int serviceId, int magicRandom) =>
      '$uuid|$serviceId|$magicRandom';

  /// Rejects stale auth callbacks from older connect sessions.
  bool _isActiveG2Auth(String uuid, int authEpoch) {
    return _isSelectedUuid(uuid) &&
        _g2AuthEpochs[uuid] == authEpoch &&
        _connectEpoch == authEpoch;
  }

  /// Cancels pending command completers for selected device UUIDs.
  void _cancelPendingG2Commands(Iterable<String> uuids, Object error) {
    final uuidSet = uuids.toSet();
    final keys = _pendingG2Commands.keys.toList();
    for (final key in keys) {
      final uuid = key.split('|').first;
      if (!uuidSet.contains(uuid)) {
        continue;
      }
      final pending = _pendingG2Commands.remove(key);
      pending?.fail(error);
    }
  }

  /// Returns the next one-byte transport sync id.
  int _nextG2SyncId() {
    _g2SyncId++;
    if (_g2SyncId > 255) {
      _g2SyncId = 0;
    }
    return _g2SyncId;
  }

  /// Returns the next one-byte command correlation id.
  int _nextG2MagicNum() {
    _g2MagicNum++;
    if (_g2MagicNum > 255) {
      _g2MagicNum = 0;
    }
    return _g2MagicNum;
  }

  /// Wraps a device-settings protobuf payload in the G2 transport frame.
  Uint8List _buildG2Transport(
    Uint8List payload, {
    required int serviceId,
    required bool syncBoth,
  }) {
    final crc = _crc16(payload);
    final builder = BytesBuilder(copy: false)
      ..addByte(0xAA)
      ..addByte((2 << 4) | 1)
      ..addByte(_nextG2SyncId())
      ..addByte(payload.length + 2)
      ..addByte(1)
      ..addByte(1)
      ..addByte(serviceId)
      ..addByte(syncBoth ? 0x20 : 0x00)
      ..add(payload)
      ..addByte(crc & 0xFF)
      ..addByte((crc >> 8) & 0xFF);
    return builder.toBytes();
  }

  /// Returns true when the selected device name marks the UUID as right leg.
  bool _isRightLeg(String uuid) {
    final selected = _selectedDevice;
    if (selected == null) {
      return false;
    }
    final device = selected.devices.firstWhere(
      (item) => item.uuid == uuid,
      orElse: () => selected.devices.first,
    );
    return _g2LegSide(device.name) == 'R';
  }

  /// Formats aggregate leg states for readable reconnect logs.
  String _connectSnapshot([BleMatchDevice? source]) {
    final device = source ?? _selectedDevice;
    if (device == null) {
      return 'no selected device';
    }
    return _sortedG2Legs(device.devices).indexed.map((entry) {
      final state = _connectStates[entry.$2.uuid]?.name ?? 'none';
      return '${_g2LegLabel(entry.$2, entry.$1)}=$state/${_shortUuid(entry.$2.uuid)}';
    }).join(', ');
  }

  /// Formats the selected leg identity for logs.
  String _selectedLegIdentity(String uuid, [String? fallbackName]) {
    final selected = _selectedDevice;
    if (selected != null) {
      final legs = _sortedG2Legs(selected.devices);
      for (final entry in legs.indexed) {
        if (entry.$2.uuid == uuid) {
          return _g2LegIdentity(entry.$2, entry.$1);
        }
      }
    }
    final name = (fallbackName == null || fallbackName.isEmpty)
        ? 'Unknown'
        : fallbackName;
    return 'Unknown leg name=$name uuid=${_shortUuid(uuid)}';
  }

  /// Formats one leg identity with name, UUID, and MAC fallback.
  String _g2LegIdentity(BleDevice device, int index) {
    return '${_g2LegLabel(device, index)} name=${device.name} '
        'uuid=${_shortUuid(device.uuid)} mac=${_displayMac(device)}';
  }

  /// Shortens UUIDs in logs while preserving enough identity for debugging.
  String _shortUuid(String uuid) {
    if (uuid.length <= 8) {
      return uuid;
    }
    return '${uuid.substring(0, 8)}...';
  }

  /// Adds a UI-visible log entry and mirrors it to debugPrint.
  void _addLog(String message) {
    debugPrint('[G2Demo] $message');
    if (!mounted) {
      return;
    }
    _updateDemoState(() {
      _logs.insert(0, '${DateTime.now().toIso8601String()}  $message');
      if (_logs.length > 120) {
        _logs.removeLast();
      }
      _logVersion.value++;
    });
  }

  /// Stops the current connect session and clears all pending async work.
  void _stopG2ConnectFlow(String reason) {
    final selected = _selectedDevice;
    final uuids =
        selected?.devices.map((item) => item.uuid) ?? const <String>[];
    _connectEpoch++;
    _cancelConnectWatchdog();
    _connectFinishAcked.clear();
    _businessConnectStarted.clear();
    _g2AuthEpochs.clear();
    _pendingG2AuthQueue.clear();
    _pendingG2ConnectLegs.clear();
    _requestedG2ConnectUuids.clear();
    _startingNextG2Leg = false;
    _connectStartedAt = null;
    _cancelActiveG2AuthTimer();
    _activeG2AuthUuid = null;
    _activeG2AuthEpoch = null;
    _cancelPendingG2Commands(uuids, StateError(reason));
    if (mounted) {
      _updateDemoState(() {
        _connecting = false;
        if (selected != null) {
          for (final item in selected.devices) {
            final state = _connectStates[item.uuid];
            if (state != null && state.isConnecting) {
              _connectStates[item.uuid] = BleConnectState.timeout;
            }
          }
        }
      });
      _notifyDetailStateChanged();
    }
    _addLog('$reason aggregate=[${_connectSnapshot()}]');
  }

  /// Starts a whole-device watchdog for stuck native or auth callbacks.
  void _startConnectWatchdog(BleMatchDevice device) {
    _cancelConnectWatchdog();
    final timeout = _connectWatchdogTimeout(device);
    _connectStartedAt ??= DateTime.now();
    _addLog(
      'connect watchdog start: sn=${device.sn} '
      'legs=${device.devices.length} timeout=${timeout.inSeconds}s',
    );
    _connectWatchdog = Timer(timeout, () {
      if (!_connecting) {
        return;
      }
      _stopG2ConnectFlow('connect watchdog timeout: sn=${device.sn}');
    });
  }

  /// Cancels the whole-device connect watchdog.
  void _cancelConnectWatchdog() {
    _connectWatchdog?.cancel();
    _connectWatchdog = null;
  }

  /// Calculates a watchdog long enough for serial two-leg G2 connection.
  Duration _connectWatchdogTimeout(BleMatchDevice device) {
    final legCount = device.devices.isEmpty ? 1 : device.devices.length;
    final milliseconds = (legCount * 28000) + 15000;
    return Duration(milliseconds: milliseconds.clamp(45000, 90000));
  }

  /// Detects a stale UI connecting flag that no longer has active async work.
  bool _isStaleG2ConnectFlow() {
    if (!_connecting) {
      return false;
    }
    if (_connectWatchdog == null) {
      return true;
    }
    final selected = _selectedDevice;
    if (selected == null) {
      return true;
    }
    final startedAt = _connectStartedAt;
    if (startedAt != null &&
        DateTime.now().difference(startedAt) >
            _connectWatchdogTimeout(selected) + const Duration(seconds: 5)) {
      return true;
    }
    return false;
  }

  /// Starts a per-auth timeout so missing success callbacks fail visibly.
  void _startActiveG2AuthTimer(String uuid, int authEpoch) {
    _cancelActiveG2AuthTimer();
    _activeG2AuthTimer = Timer(const Duration(seconds: 8), () {
      if (_activeG2AuthUuid != uuid || _activeG2AuthEpoch != authEpoch) {
        return;
      }
      _stopG2ConnectFlow(
        'AUTHENTICATION timeout waiting success callback: '
        '${_selectedLegIdentity(uuid)} authEpoch=$authEpoch',
      );
    });
  }

  /// Cancels the active authentication timeout.
  void _cancelActiveG2AuthTimer() {
    _activeG2AuthTimer?.cancel();
    _activeG2AuthTimer = null;
  }

  /// Notifies the detail page builders that derived connection state changed.
  void _notifyDetailStateChanged() {
    _logVersion.value++;
  }
}
