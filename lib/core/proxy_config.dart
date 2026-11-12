import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

/// HTTP proxy for the app's server connections (desktop only).
///
/// Persisted in Settings (shared_preferences keys `yinghui_proxy_*`)
/// and applied centrally here, so all five Dio clients (Navidrome,
/// Emby, qBittorrent, Transmission, aria2) route through it.
///
/// Scope: Dio only. The installed media_kit 1.2.6 exposes no
/// http-proxy option (PlayerConfiguration has none, Player has no
/// public setProperty), so music/video playback streams do NOT go
/// through the proxy — only the API calls do. The Settings UI says
/// so; do not claim otherwise.
class ProxyConfig {
  const ProxyConfig({this.enabled = false, this.host = '', this.port = 0});

  final bool enabled;
  final String host;
  final int port;

  /// Usable: enabled, with a non-empty host and a valid port.
  /// An enabled config with a blank host or a bad port is treated
  /// as no proxy (DIRECT), never as a half-configured one.
  bool get isValid =>
      enabled && host.trim().isNotEmpty && port > 0 && port <= 65535;

  /// "host:port" for display and for findProxy.
  String get address => '${host.trim()}:$port';

  ProxyConfig copyWith({bool? enabled, String? host, int? port}) => ProxyConfig(
    enabled: enabled ?? this.enabled,
    host: host ?? this.host,
    port: port ?? this.port,
  );

  @override
  bool operator ==(Object other) =>
      other is ProxyConfig &&
      other.enabled == enabled &&
      other.host == host &&
      other.port == port;

  @override
  int get hashCode => Object.hash(enabled, host, port);
}

/// Central registry for the app's Dio instances.
///
/// Each service client calls [apply] in its constructor (one line);
/// [update] re-applies the current config to every registered Dio
/// (called from main's settings listener, so a change in Settings
/// applies without a restart). Dios created before Settings finished
/// loading get the default (disabled) config first, then the loaded
/// one via [update] — either order works.
class DioProxy {
  static ProxyConfig _config = const ProxyConfig();
  static final Set<Dio> _dios = {};

  static ProxyConfig get current => _config;

  /// Registers [dio] and applies the current config to it.
  static void apply(Dio dio) {
    _dios.add(dio);
    _applyTo(dio, _config);
  }

  /// Re-applies [config] to every registered Dio.
  static void update(ProxyConfig config) {
    _config = config;
    for (final dio in _dios) {
      _applyTo(dio, config);
    }
  }

  static void _applyTo(Dio dio, ProxyConfig config) {
    final adapter = dio.httpClientAdapter;
    // Injected mock adapters (tests) are not IO adapters: there is
    // no HttpClient to configure, so leave them alone.
    if (adapter is! IOHttpClientAdapter) return;
    // The adapter caches its HttpClient after the first request, so
    // changing createHttpClient on the existing adapter would not
    // affect later requests. Swap in a fresh adapter instead; the
    // old one's HttpClient idles out on its own (3s idle timeout).
    dio.httpClientAdapter = IOHttpClientAdapter()
      ..createHttpClient = () {
        final client = HttpClient();
        client.findProxy = (uri) =>
            config.isValid ? 'PROXY ${config.address}' : 'DIRECT';
        return client;
      };
  }

  @visibleForTesting
  static void resetForTest() {
    _dios.clear();
    _config = const ProxyConfig();
  }
}
