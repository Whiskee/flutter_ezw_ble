part of '../main.dart';

// G2 demo protocol helpers.
//
// The example only implements the protobuf/transport subset needed for the
// reconnect demo: authentication, pipe role change, and time sync. Production
// protocol ownership should stay in even_connect or the business SDK layer.

/// Builds a compact protobuf-like message from already encoded fields.
Uint8List _pbMessage(List<Uint8List> fields) {
  final builder = BytesBuilder(copy: false);
  for (final field in fields) {
    builder.add(field);
  }
  return builder.toBytes();
}

/// Encodes an integer varint field.
Uint8List _pbVarintField(int fieldNumber, int value) {
  final builder = BytesBuilder(copy: false)
    ..add(_pbVarint((fieldNumber << 3) | 0))
    ..add(_pbVarint(value));
  return builder.toBytes();
}

/// Encodes an int32 field while preserving the device protocol's signed-value rule.
Uint8List _pbInt32Field(int fieldNumber, int value) {
  // Negative int32 values are encoded as unsigned varints by the device
  // protocol. Keep this local so time-zone sync remains byte-compatible.
  final wireValue = value < 0 ? value + (BigInt.one << 64).toInt() : value;
  return _pbVarintField(fieldNumber, wireValue);
}

/// Encodes a length-delimited bytes field.
Uint8List _pbBytesField(int fieldNumber, Uint8List value) {
  final builder = BytesBuilder(copy: false)
    ..add(_pbVarint((fieldNumber << 3) | 2))
    ..add(_pbVarint(value.length))
    ..add(value);
  return builder.toBytes();
}

/// Encodes an unsigned protobuf varint.
Uint8List _pbVarint(int value) {
  var current = value;
  final bytes = <int>[];
  while (current > 0x7F) {
    bytes.add((current & 0x7F) | 0x80);
    current >>= 7;
  }
  bytes.add(current & 0x7F);
  return Uint8List.fromList(bytes);
}

/// Reads a protobuf varint from [data] starting at [offset].
({int value, int offset})? _readPbVarint(Uint8List data, int offset) {
  var shift = 0;
  var value = 0;
  var cursor = offset;
  while (cursor < data.length && shift < 64) {
    final byte = data[cursor++];
    value |= (byte & 0x7F) << shift;
    if ((byte & 0x80) == 0) {
      return (value: value, offset: cursor);
    }
    shift += 7;
  }
  return null;
}

/// Calculates the G2 transport CRC16 used by the demo auth responses.
int _crc16(Uint8List data) {
  var crc = 0xFFFF;
  for (final byte in data) {
    final highByte = (crc >>> 8) & 0xFF;
    final lowByte = (crc << 8) & 0xFF00;
    crc = lowByte | highByte;
    crc ^= byte & 0xFF;
    crc ^= ((crc & 0xFF) >>> 4) & 0xFF;
    crc ^= (crc << 12) & 0xFFFF;
    crc ^= ((crc & 0xFF) << 5) & 0xFFFF;
  }
  return crc & 0xFFFF;
}

/// Pending command completer keyed by device command id.
class _PendingG2Command {
  _PendingG2Command(this.commandId);

  final int commandId;
  final Completer<_G2DevCfgPackage> completer = Completer<_G2DevCfgPackage>();

  /// Completes only when the response command id matches the pending request.
  void complete(_G2DevCfgPackage package) {
    if (completer.isCompleted) {
      return;
    }
    if (package.commandId != commandId) {
      completer.completeError(
        StateError('unexpected commandId=${package.commandId}'),
      );
      return;
    }
    completer.complete(package);
  }

  /// Fails the pending command without double-completing the completer.
  void fail(Object error) {
    if (!completer.isCompleted) {
      completer.completeError(error);
    }
  }
}

/// Parsed G2 transport envelope.
class _G2Transport {
  const _G2Transport({
    required this.serviceId,
    required this.resultCode,
    required this.payload,
    required this.isCrcCorrect,
  });

  final int serviceId;
  final int resultCode;
  final Uint8List payload;
  final bool isCrcCorrect;

  bool get isSuccess => resultCode == 0;

  /// Parses the binary transport frame emitted by the G2 private service.
  static _G2Transport? tryParse(Uint8List data) {
    const headerLength = 8;
    const crcLength = 2;
    if (data.length < headerLength || data[0] != 0xAA) {
      return null;
    }
    final packetLen = data[3];
    final packetTotalNum = data[4];
    final packetSerialNum = data[5];
    final serviceId = data[6];
    final flags = data[7];
    final resultCode = (flags >> 1) & 0x0F;
    if (data.length < headerLength + packetLen) {
      return null;
    }
    // Only the final packet carries CRC. The demo commands are single-packet,
    // but keeping the packet check makes logs correct if firmware fragments.
    final hasCrc = packetTotalNum == packetSerialNum && packetLen >= crcLength;
    final payloadLength = packetLen - (hasCrc ? crcLength : 0);
    final payload = Uint8List.fromList(
      data.sublist(headerLength, headerLength + payloadLength),
    );
    var isCrcCorrect = true;
    if (hasCrc) {
      final crcOffset = headerLength + payloadLength;
      final expected = data[crcOffset] | (data[crcOffset + 1] << 8);
      isCrcCorrect = _crc16(payload) == expected;
    }
    return _G2Transport(
      serviceId: serviceId,
      resultCode: resultCode,
      payload: resultCode == 0 ? payload : Uint8List(0),
      isCrcCorrect: isCrcCorrect,
    );
  }
}

/// Parsed G2 device-settings payload used by authentication callbacks.
class _G2DevCfgPackage {
  const _G2DevCfgPackage({
    required this.commandId,
    required this.magicRandom,
    this.authSecAuth,
  });

  final int commandId;
  final int magicRandom;
  final bool? authSecAuth;

  /// Parses the small subset of device-settings protobuf fields used by the demo.
  static _G2DevCfgPackage? tryParse(Uint8List data) {
    var offset = 0;
    int? commandId;
    int? magicRandom;
    bool? authSecAuth;

    while (offset < data.length) {
      final tag = _readPbVarint(data, offset);
      if (tag == null) {
        return null;
      }
      offset = tag.offset;
      final fieldNumber = tag.value >> 3;
      final wireType = tag.value & 0x07;

      if (wireType == 0) {
        final value = _readPbVarint(data, offset);
        if (value == null) {
          return null;
        }
        offset = value.offset;
        if (fieldNumber == 1) {
          commandId = value.value;
        } else if (fieldNumber == 2) {
          magicRandom = value.value;
        }
      } else if (wireType == 2) {
        final length = _readPbVarint(data, offset);
        if (length == null) {
          return null;
        }
        offset = length.offset;
        final end = offset + length.value;
        if (end > data.length) {
          return null;
        }
        final message = Uint8List.fromList(data.sublist(offset, end));
        offset = end;
        if (fieldNumber == 3) {
          // Authentication response is the only nested message the example
          // needs to inspect before calling deviceConnected.
          authSecAuth = _parseAuthSecAuth(message);
        }
      } else {
        return null;
      }
    }

    if (commandId == null || magicRandom == null) {
      return null;
    }
    return _G2DevCfgPackage(
      commandId: commandId,
      magicRandom: magicRandom,
      authSecAuth: authSecAuth,
    );
  }

  /// Parses nested AuthMgr.secAuth from the authentication response.
  static bool? _parseAuthSecAuth(Uint8List data) {
    var offset = 0;
    while (offset < data.length) {
      final tag = _readPbVarint(data, offset);
      if (tag == null) {
        return null;
      }
      offset = tag.offset;
      final fieldNumber = tag.value >> 3;
      final wireType = tag.value & 0x07;
      if (wireType == 0) {
        final value = _readPbVarint(data, offset);
        if (value == null) {
          return null;
        }
        offset = value.offset;
        if (fieldNumber == 1) {
          return value.value == 1;
        }
      } else if (wireType == 2) {
        final length = _readPbVarint(data, offset);
        if (length == null) {
          return null;
        }
        // Unknown nested length-delimited fields are skipped instead of
        // failing, because firmware may add fields unrelated to secAuth.
        offset = length.offset + length.value;
      } else {
        return null;
      }
    }
    return null;
  }
}
