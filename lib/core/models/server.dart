/// A media/download server. One entry per service instance — a user may
/// have two Emby servers, a NAS qBittorrent and a VPS Transmission, etc.
///
/// [token] holds the secret for this server and must never be written to
/// plain storage or logs: Navidrome password, Emby access token (obtained
/// by [EmbyClient.authenticate]), qBittorrent/Transmission password, or
/// the aria2 RPC secret. It is persisted only via flutter_secure_storage.
enum ServerType { navidrome, emby, qbittorrent, transmission, aria2 }

extension ServerTypeLabel on ServerType {
  String get label => switch (this) {
    ServerType.navidrome => 'Navidrome',
    ServerType.emby => 'Emby',
    ServerType.qbittorrent => 'qBittorrent',
    ServerType.transmission => 'Transmission',
    ServerType.aria2 => 'aria2',
  };

  /// Default port for the service, used to prefill the add-server form.
  int get defaultPort => switch (this) {
    ServerType.navidrome => 4533,
    ServerType.emby => 8096,
    ServerType.qbittorrent => 8080,
    ServerType.transmission => 9091,
    ServerType.aria2 => 6800,
  };
}

class Server {
  Server({
    required this.id,
    required this.type,
    required this.name,
    required this.host,
    required this.port,
    this.username = '',
    this.token = '',
    this.isDefault = false,
  });

  final String id;
  final ServerType type;
  final String name;

  /// Host as typed by the user: either a bare host/IP ("192.168.1.10")
  /// or a full URL ("https://music.example.com"). Never contains a port.
  final String host;
  final int port;
  final String username;

  /// Secret (see class doc). Never log this.
  final String token;
  final bool isDefault;

  /// Base URL for Dio. A bare host gets `http://` + port; a full URL is
  /// used as-is (its port, if any, wins over [port]).
  String get baseUrl {
    final h = host.trim();
    if (h.startsWith('http://') || h.startsWith('https://')) return h;
    return 'http://$h:$port';
  }

  Server copyWith({
    String? id,
    ServerType? type,
    String? name,
    String? host,
    int? port,
    String? username,
    String? token,
    bool? isDefault,
  }) => Server(
    id: id ?? this.id,
    type: type ?? this.type,
    name: name ?? this.name,
    host: host ?? this.host,
    port: port ?? this.port,
    username: username ?? this.username,
    token: token ?? this.token,
    isDefault: isDefault ?? this.isDefault,
  );

  /// Non-secret fields only. [token] is deliberately excluded — it is
  /// stored separately in flutter_secure_storage.
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'name': name,
    'host': host,
    'port': port,
    'username': username,
    'isDefault': isDefault,
  };

  factory Server.fromJson(Map<String, dynamic> json) => Server(
    id: json['id'] as String,
    type: ServerType.values.byName(json['type'] as String),
    name: json['name'] as String,
    host: json['host'] as String,
    port: (json['port'] as num).toInt(),
    username: (json['username'] as String?) ?? '',
    isDefault: (json['isDefault'] as bool?) ?? false,
  );
}
