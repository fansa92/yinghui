import '../../core/models/connection_result.dart';
import '../../core/models/server.dart';
import 'aria2_client.dart';
import 'emby_client.dart';
import 'qbittorrent_client.dart';
import 'subsonic_client.dart';
import 'transmission_client.dart';

/// Creates the native client for a server and runs a connectivity check.
/// Each service keeps its own client — there is no shared generic wrapper.
class ApiClientFactory {
  /// Structured check: ok / needsAuth / unreachable, with server
  /// version/name when the server reports them.
  static Future<ConnectionResult> testConnection(Server server) async {
    switch (server.type) {
      case ServerType.navidrome:
        return SubsonicClient(server).testConnectionResult();
      case ServerType.emby:
        return EmbyClient(server).testConnectionResult();
      case ServerType.qbittorrent:
        return QbittorrentClient(server).testConnectionResult();
      case ServerType.transmission:
        return TransmissionClient(server).testConnectionResult();
      case ServerType.aria2:
        return Aria2Client(server).testConnectionResult();
    }
  }

  /// Bool helper for callers that only need ok/not-ok.
  static Future<bool> testConnectionBool(Server server) async =>
      (await testConnection(server)).isOk;
}
