enum ModuleType { relay, blind, dcDimmer, acDimmer, temperature, hub }

enum ModuleStatus { online, offline, unknown }

class Module {
  final String id;
  final String? locationId;
  final int? roomId;
  final ModuleType type;
  final String name;
  final String ip;
  final String? macAddress;
  final String? firmware;
  final ModuleStatus status;
  final DateTime? lastSeenAt;

  const Module({
    required this.id,
    this.locationId,
    this.roomId,
    required this.type,
    required this.name,
    required this.ip,
    this.macAddress,
    this.firmware,
    this.status = ModuleStatus.unknown,
    this.lastSeenAt,
  });

  Module copyWith({
    String? id,
    ModuleType? type,
    String? name,
    String? ip,
    String? macAddress,
    String? firmware,
    ModuleStatus? status,
    DateTime? lastSeenAt,
  }) {
    return Module(
      id: id ?? this.id,
      locationId: locationId,
      roomId: roomId,
      type: type ?? this.type,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      macAddress: macAddress ?? this.macAddress,
      firmware: firmware ?? this.firmware,
      status: status ?? this.status,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'locationId': locationId,
        'roomId': roomId,
        'type': type.name,
        'name': name,
        'ip': ip,
        'mac': macAddress,
        'firmware': firmware,
        'status': status.name,
        'lastSeenAt': lastSeenAt?.toIso8601String(),
      };

  factory Module.fromJson(Map<String, Object?> json) => Module(
        id: json['id'] as String,
        locationId: json['locationId'] as String?,
        roomId: json['roomId'] as int?,
        type: ModuleType.values.byName(json['type'] as String),
        name: json['name'] as String,
        ip: json['ip'] as String,
        macAddress: json['mac'] as String?,
        firmware: json['firmware'] as String?,
        status: ModuleStatus.values.firstWhere(
          (s) => s.name == json['status'],
          orElse: () => ModuleStatus.unknown,
        ),
        lastSeenAt: json['lastSeenAt'] != null
            ? DateTime.tryParse(json['lastSeenAt'] as String)
            : null,
      );
}
