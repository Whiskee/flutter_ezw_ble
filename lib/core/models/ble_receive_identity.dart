/// Frozen native receipt provenance; this value alone grants no business access.
class BleReceiveIdentity {
  const BleReceiveIdentity(
      {required this.uuid,
      required this.sessionGeneration,
      required this.attemptGeneration});
  final String uuid;
  final int sessionGeneration;
  final int attemptGeneration;

  /// Unknown, partial or malformed envelopes must remain unavailable.
  static BleReceiveIdentity? fromJson(Object? value) {
    if (value is! Map) return null;
    final uuid = value['uuid'];
    final session = value['sessionGeneration'];
    final attempt = value['attemptGeneration'];
    if (uuid is! String ||
        uuid.trim().isEmpty ||
        session is! int ||
        attempt is! int ||
        session <= 0 ||
        attempt <= 0) {
      return null;
    }
    return BleReceiveIdentity(
        uuid: uuid, sessionGeneration: session, attemptGeneration: attempt);
  }

  Map<String, Object> toJson() => {
        'uuid': uuid,
        'sessionGeneration': sessionGeneration,
        'attemptGeneration': attemptGeneration
      };

  @override
  bool operator ==(Object other) =>
      other is BleReceiveIdentity &&
      uuid == other.uuid &&
      sessionGeneration == other.sessionGeneration &&
      attemptGeneration == other.attemptGeneration;
  @override
  int get hashCode => Object.hash(uuid, sessionGeneration, attemptGeneration);
}
