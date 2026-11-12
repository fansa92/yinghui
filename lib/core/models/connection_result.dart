/// Structured result of a server connectivity probe.
///
/// Three states, shown distinctly in the Servers page:
/// * [ok] — the server answered and (where needed) the credentials work.
/// * [needsAuth] — the server is reachable and recognised, but it needs
///   login / credentials (e.g. Subsonic code 10, Emby public info only,
///   qBittorrent HTTP 403). This is NOT an unreachable server.
/// * [unreachable] — no answer at all (timeout, DNS, refused, bad URL).
enum ConnectionStatus { ok, needsAuth, unreachable }

class ConnectionResult {
  const ConnectionResult({
    required this.status,
    required this.message,
    this.serverVersion,
    this.serverName,
  });

  final ConnectionStatus status;
  final String message;
  final String? serverVersion;
  final String? serverName;

  bool get isOk => status == ConnectionStatus.ok;
  bool get needsAuth => status == ConnectionStatus.needsAuth;
  bool get isUnreachable => status == ConnectionStatus.unreachable;

  factory ConnectionResult.ok({
    String message = 'Connected',
    String? serverVersion,
    String? serverName,
  }) => ConnectionResult(
    status: ConnectionStatus.ok,
    message: message,
    serverVersion: serverVersion,
    serverName: serverName,
  );

  factory ConnectionResult.needsAuth({
    String message = 'Server reachable — login required',
    String? serverVersion,
    String? serverName,
  }) => ConnectionResult(
    status: ConnectionStatus.needsAuth,
    message: message,
    serverVersion: serverVersion,
    serverName: serverName,
  );

  factory ConnectionResult.unreachable({String message = 'Unreachable'}) =>
      ConnectionResult(status: ConnectionStatus.unreachable, message: message);

  @override
  String toString() =>
      'ConnectionResult($status, $message'
      '${serverVersion != null ? ', $serverVersion' : ''}'
      '${serverName != null ? ', $serverName' : ''})';
}
