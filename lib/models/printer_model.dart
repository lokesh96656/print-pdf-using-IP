/// Represents a network printer identified by IP (and optional name/port/path).
/// Used for IP-based printing; in future you can map IP to PDF types for direct routing.
class PrinterModel {
  PrinterModel({
    required this.id,
    required this.ip,
    this.name,
    this.port = 631,
    this.ippPath,
  });

  final String id;
  final String ip;
  final String? name;
  final int port;
  /// Optional IPP path, e.g. "/ipp/print". If set, only this path is tried (HP printers often need a specific path or port 280).
  final String? ippPath;

  String get displayLabel => name != null && name!.isNotEmpty
      ? '$name ($ip:$port)'
      : '$ip:$port';

  Map<String, dynamic> toJson() => {
        'id': id,
        'ip': ip,
        'name': name,
        'port': port,
        'ippPath': ippPath,
      };

  factory PrinterModel.fromJson(Map<String, dynamic> json) {
    return PrinterModel(
      id: json['id'] as String,
      ip: json['ip'] as String,
      name: json['name'] as String?,
      port: (json['port'] as num?)?.toInt() ?? 631,
      ippPath: json['ippPath'] as String?,
    );
  }
}
