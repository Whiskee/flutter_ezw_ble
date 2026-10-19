import 'dart:typed_data';

/// Native admission metadata for one already-framed G2 RAW window.
///
/// This is independent of analytics tokens. It neither changes packet bytes nor
/// grants queue credit: native observes the real notification for measurement
/// only, without resetting the 64-packet budget or releasing a wait.
class BleOtaWindow {
  BleOtaWindow({required this.windowId, required Uint8List expectedAck})
      : expectedAck = Uint8List.fromList(expectedAck);

  final String windowId;
  final Uint8List expectedAck;

  Map<String, Object> toJson() => {
        'windowId': windowId,
        'expectedAck': expectedAck,
      };
}

/// A native-issued receipt, carried back only after strict Dart ACK validation.
/// The legacy `otaWindowCredit` wire key now carries timing only, not budget
/// authority. Missing receipt is unknown, never fabricated success.
class BleOtaWindowReceipt {
  const BleOtaWindowReceipt({required this.windowId, required this.receiptId});

  final String windowId;
  final String receiptId;

  bool get isValid =>
      windowId.trim().isNotEmpty &&
      windowId.length <= 128 &&
      receiptId.trim().isNotEmpty &&
      receiptId.length <= 128;

  static BleOtaWindowReceipt? fromJson(Object? raw) {
    if (raw is! Map ||
        raw['windowId'] is! String ||
        raw['receiptId'] is! String) {
      return null;
    }
    final receipt = BleOtaWindowReceipt(
      windowId: raw['windowId'] as String,
      receiptId: raw['receiptId'] as String,
    );
    return receipt.isValid ? receipt : null;
  }

  Map<String, Object> toJson() => {
        'windowId': windowId,
        'receiptId': receiptId,
      };
}
