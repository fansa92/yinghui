// Fix-pass tests (2026-11-12 audit): each test below failed against the
// pre-fix code and pins the fixed behaviour. See the fix report for the
// numbered list.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yinghui/core/errors.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/data/api/aria2_client.dart';
import 'package:yinghui/data/api/emby_client.dart';
import 'package:yinghui/data/api/qbittorrent_client.dart';
import 'package:yinghui/data/api/subsonic_client.dart';
import 'package:yinghui/data/api/transmission_client.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/download_task.dart';
import 'package:yinghui/data/models/track.dart';
import 'package:yinghui/data/models/video_detail.dart';
import 'package:yinghui/data/models/video_item.dart';
import 'package:yinghui/data/repositories/download_repository.dart';
import 'package:yinghui/data/repositories/music_repository.dart';
import 'package:yinghui/data/repositories/playback_decision.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/data/repositories/video_repository.dart';
import 'package:yinghui/features/downloads/downloads_page.dart';
import 'package:yinghui/features/home/home_page.dart';
import 'package:yinghui/features/music/album_detail_page.dart';
import 'package:yinghui/features/music/music_page.dart';
import 'package:yinghui/features/player/player_service.dart';
import 'package:yinghui/features/player/video_player_page.dart';
import 'package:yinghui/features/player/video_player_service.dart';
import 'package:yinghui/features/video/video_page.dart';

Server _server({
  String id = 'srv-1',
  ServerType type = ServerType.navidrome,
  String host = 'https://example.com/',
  int port = 443,
  String username = 'yang',
  String token = 's3cret',
}) => Server(
  id: id,
  type: type,
  name: 'Test',
  host: host,
  port: port,
  username: username,
  token: token,
);

Response<dynamic> _ok(
  RequestOptions options,
  dynamic data, {
  int statusCode = 200,
  Map<String, List<String>>? headers,
}) => Response<dynamic>(
  requestOptions: options,
  data: data,
  statusCode: statusCode,
  headers: headers == null ? Headers() : Headers.fromMap(headers),
);

/// A ServerStore whose list is driven directly in widget tests, bypassing
/// the secure-storage write: `FlutterSecureStorage.write` hangs forever
/// in widget tests on this machine (in plain unit tests it throws
/// MissingPluginException at once), so `store.add` can never be awaited
/// inside a `testWidgets`.
class _MutableStore extends ServerStore {
  _MutableStore({required super.database});

  final List<Server> _list = [];

  @override
  List<Server> get servers => List.unmodifiable(_list);

  void addServer(Server server) {
    _list.add(server);
    notifyListeners();
  }
}

void main() {
  group('Fix 1 — subpath is preserved by every client', () {
    test('Subsonic keeps /music/ in the request URL', () async {
      Uri? seen;
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com/music/'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              seen = options.uri;
              handler.resolve(
                _ok(options, {
                  'subsonic-response': {
                    'status': 'ok',
                    'albumList2': {'album': []},
                  },
                }),
              );
            },
          ),
        );
      final client = SubsonicClient(
        _server(host: 'https://example.com/music/'),
        dio: dio,
      );
      await client.getAlbumList2();
      expect(
        seen.toString(),
        startsWith('https://example.com/music/rest/getAlbumList2'),
      );
    });

    test('Emby keeps /emby/ in the request URL', () async {
      Uri? seen;
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com/emby/'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              seen = options.uri;
              handler.resolve(_ok(options, {'Items': []}));
            },
          ),
        );
      final client = EmbyClient(
        _server(type: ServerType.emby, host: 'https://example.com/emby/'),
        dio: dio,
      );
      await client.getItems();
      expect(seen.toString(), startsWith('https://example.com/emby/Items'));
    });

    test('Transmission keeps /tr/ in the request URL', () async {
      Uri? seen;
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com/tr/'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              seen = options.uri;
              handler.resolve(
                _ok(options, {
                  'result': 'success',
                  'arguments': <String, dynamic>{},
                }),
              );
            },
          ),
        );
      final client = TransmissionClient(
        _server(type: ServerType.transmission, host: 'https://example.com/tr/'),
        dio: dio,
      );
      await client.testConnection();
      expect(seen.toString(), 'https://example.com/tr/transmission/rpc');
    });

    test('aria2 keeps /aria/ in the request URL', () async {
      Uri? seen;
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com/aria/'))
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              seen = options.uri;
              handler.resolve(
                _ok(options, {
                  'jsonrpc': '2.0',
                  'id': 1,
                  'result': {'version': '1.37.0'},
                }),
              );
            },
          ),
        );
      final client = Aria2Client(
        _server(type: ServerType.aria2, host: 'https://example.com/aria/'),
        dio: dio,
      );
      await client.testConnection();
      expect(seen.toString(), 'https://example.com/aria/jsonrpc');
    });

    test('default-constructed clients normalise baseUrl with a slash', () {
      expect(
        SubsonicClient(_server(host: 'https://example.com/music'))
            .dio
            .options
            .baseUrl,
        'https://example.com/music/',
      );
      expect(
        EmbyClient(
          _server(type: ServerType.emby, host: 'https://example.com/emby'),
        ).dio.options.baseUrl,
        'https://example.com/emby/',
      );
      expect(
        TransmissionClient(
          _server(type: ServerType.transmission, host: 'http://nas:9091'),
        ).dio.options.baseUrl,
        'http://nas:9091/',
      );
      expect(
        Aria2Client(_server(type: ServerType.aria2, host: 'http://nas:6800'))
            .dio
            .options
            .baseUrl,
        'http://nas:6800/',
      );
    });
  });

  group('Fix 1b — no double slashes in string-built URLs', () {
    test('Subsonic stream/cover URLs with a trailing-slash host', () {
      final client = SubsonicClient(_server(host: 'https://example.com/sub/'));
      expect(
        client.streamUrl('s1'),
        startsWith('https://example.com/sub/rest/stream?'),
      );
      expect(client.streamUrl('s1'), isNot(contains('//rest/')));
      expect(
        client.coverArtUrl('al-1'),
        startsWith('https://example.com/sub/rest/getCoverArt?'),
      );
    });

    test('Emby stream/image/transcode URLs with a trailing-slash host', () {
      final client = EmbyClient(
        _server(type: ServerType.emby, host: 'https://example.com/sub/'),
      );
      expect(
        client.videoStreamUrl('m1'),
        'https://example.com/sub/Videos/m1/stream?api_key=s3cret',
      );
      expect(
        client.imageUrl('m1'),
        'https://example.com/sub/Items/m1/Images/Primary?api_key=s3cret',
      );
      expect(
        client.transcodeUrl('m1'),
        startsWith('https://example.com/sub/Videos/m1/master.m3u8?'),
      );
      expect(
        client.audioUniversalUrl('m1'),
        'https://example.com/sub/Audio/m1/universal?api_key=s3cret',
      );
      const track = SubtitleTrackInfo(
        index: 2,
        deliveryUrl: '/Videos/m1/ms1/Subtitles/2/Stream.srt',
      );
      expect(
        client.subtitleUrl('m1', track),
        'https://example.com/sub/Videos/m1/ms1/Subtitles/2/Stream.srt',
      );
    });
  });

  group('Fix 2 — qBittorrent re-logs in when the SID expires (403)', () {
    test('torrentsInfo retries once after a 403 and returns tasks', () async {
      var logins = 0;
      var infoCalls = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('auth/login')) {
                logins++;
                handler.resolve(
                  _ok(
                    options,
                    'Ok',
                    headers: {
                      'set-cookie': ['SID=sid-$logins; path=/'],
                    },
                  ),
                );
                return;
              }
              infoCalls++;
              if (infoCalls == 1) {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    response: _ok(options, 'Forbidden', statusCode: 403),
                    type: DioExceptionType.badResponse,
                  ),
                );
                return;
              }
              handler.resolve(
                _ok(options, [
                  {
                    'hash': 'abc',
                    'name': 'Ubuntu.iso',
                    'state': 'downloading',
                    'progress': 0.5,
                    'dlspeed': 1000,
                    'size': 100,
                    'completed': 50,
                    'eta': 60,
                    'save_path': '/dl',
                  },
                ]),
              );
            },
          ),
        );
      final client = QbittorrentClient(
        _server(
          type: ServerType.qbittorrent,
          host: 'https://sg.kass.qzz.io/qb/',
        ),
        dio: dio,
      );
      final tasks = await client.torrentsInfo();
      expect(tasks, hasLength(1));
      expect(tasks.first.name, 'Ubuntu.iso');
      expect(logins, 2);
      expect(infoCalls, 2);
    });
  });

  group('Fix 3 — Transmission retry failure is an ApiException', () {
    test('a second 409 does not leak a raw DioException', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.reject(
                DioException(
                  requestOptions: options,
                  response: Response<dynamic>(
                    requestOptions: options,
                    statusCode: 409,
                    headers: Headers.fromMap({
                      'X-Transmission-Session-Id': ['sess-1'],
                    }),
                  ),
                  type: DioExceptionType.badResponse,
                ),
              );
            },
          ),
        );
      final client = TransmissionClient(
        _server(type: ServerType.transmission, host: 'http://nas:9091'),
        dio: dio,
      );
      expect(client.testConnection(), throwsA(isA<ApiException>()));
    });
  });

  group('Fix 4 — Subsonic single-object JSON and numeric coverArt', () {
    Map<String, dynamic> songJson() => {
      'id': 't1',
      'title': 'Midnight Drive',
      'artist': 'Neon Lights',
      'album': 'Midnight City',
      'albumId': 'a1',
      'duration': 214,
    };

    test('search3 with a single song object (not a list) parses', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                _ok(options, {
                  'subsonic-response': {
                    'status': 'ok',
                    'searchResult3': {
                      'song': songJson(),
                      'album': {
                        'id': 'a1',
                        'name': 'Midnight City',
                        'artist': 'Neon Lights',
                      },
                    },
                  },
                }),
              );
            },
          ),
        );
      final client = SubsonicClient(_server(), dio: dio);
      final result = await client.searchAll('midnight');
      expect(result.songs.length, 1);
      expect(result.songs.first.title, 'Midnight Drive');
      expect(result.albums.length, 1);
    });

    test('numeric coverArt does not throw', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                _ok(options, {
                  'subsonic-response': {
                    'status': 'ok',
                    'albumList2': {
                      'album': [
                        {
                          'id': 'a1',
                          'name': 'Midnight City',
                          'artist': 'Neon Lights',
                          'year': 2024,
                          'songCount': 12,
                          'coverArt': 123,
                        },
                      ],
                    },
                  },
                }),
              );
            },
          ),
        );
      final client = SubsonicClient(_server(), dio: dio);
      final albums = await client.getAlbumList2();
      expect(albums.length, 1);
      expect(albums.first.coverUrl, contains('id=123'));
    });

    test('getArtists with a single index object parses', () async {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                _ok(options, {
                  'subsonic-response': {
                    'status': 'ok',
                    'artists': {
                      'index': {
                        'name': 'N',
                        'artist': {
                          'id': 'ar1',
                          'name': 'Neon Lights',
                          'albumCount': 3,
                        },
                      },
                    },
                  },
                }),
              );
            },
          ),
        );
      final client = SubsonicClient(_server(), dio: dio);
      final artists = await client.getArtists();
      expect(artists.map((a) => a.name), ['Neon Lights']);
    });
  });

  group('Fix 5 — Emby subtitle fallback has no empty media source id', () {
    test('subtitleUrl without mediaSourceId omits the empty segment', () {
      final client = EmbyClient(
        _server(type: ServerType.emby, host: 'https://cf.imetyou.top'),
      );
      const track = SubtitleTrackInfo(index: 3, codec: 'ass');
      expect(
        client.subtitleUrl('m1', track),
        'https://cf.imetyou.top/Videos/m1/Subtitles/3/Stream.srt'
        '?api_key=s3cret',
      );
      expect(client.subtitleUrl('m1', track), isNot(contains('//Subtitles')));
    });

    test('allSubtitles fills mediaSourceId from the media sources', () {
      const detail = VideoDetail(
        item: VideoItem(id: 'm1', title: 'The Last Horizon'),
        subtitleTracks: [
          SubtitleTrackInfo(
            index: 2,
            codec: 'srt',
            language: 'eng',
            displayTitle: 'English',
          ),
        ],
        mediaSources: [
          MediaSourceInfo(
            id: 'ms1',
            container: 'mkv',
            streams: [
              MediaStreamInfo(type: 'Subtitle', index: 2, codec: 'srt'),
            ],
          ),
        ],
      );
      final all = detail.allSubtitles;
      expect(all.length, 1);
      expect(all.first.mediaSourceId, 'ms1');
      expect(all.first.displayTitle, 'English');
    });
  });

  group('Fix 6 — Emby parseMediaSources tolerates double Width/Height', () {
    test('Width/Height as doubles parse to int', () {
      final sources = EmbyClient.parseMediaSources({
        'MediaSources': [
          {
            'Id': 'ms1',
            'Container': 'mp4',
            'VideoCodec': 'h264',
            'AudioCodec': 'aac',
            'VideoStream': {'Width': 1920.0, 'Height': 1080.0},
            'MediaStreams': [
              {'Type': 'Video', 'Index': 0, 'Codec': 'h264'},
            ],
          },
        ],
      });
      expect(sources.length, 1);
      expect(sources.first.width, 1920);
      expect(sources.first.height, 1080);
    });
  });

  group('Fix 8 — PlaybackDecider video-only file direct-plays', () {
    test('mp4/h264 with no audio stream and no audio codec is direct', () {
      const source = MediaSourceInfo(
        id: 'ms1',
        container: 'mp4',
        videoCodec: 'h264',
        audioCodec: null,
        streams: [MediaStreamInfo(type: 'Video', index: 0, codec: 'h264')],
      );
      expect(PlaybackDecider.decide(source).isDirect, isTrue);
    });

    test('no stream info at all and no audio codec stays conservative', () {
      const source = MediaSourceInfo(
        id: 'ms1',
        container: 'mp4',
        videoCodec: 'h264',
        audioCodec: null,
      );
      expect(PlaybackDecider.decide(source).isDirect, isFalse);
    });
  });

  _fixPassPart2();
  _fixPassPart3();
  _fixPassPart4();
  _fixPassPart5();
}

void _fixPassPart2() {
  group('Fix 7 — repositories reuse one client per server', () {
    late AppDatabase db;
    late ServerStore store;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      store = ServerStore(database: db);
    });

    tearDown(() async {
      await db.close();
    });

    test('music repo: two album loads create one SubsonicClient', () async {
      await store.add(_server(id: 'srv-a', username: 'yang', token: 'pw-a'));
      var factoryCalls = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                _ok(options, {
                  'subsonic-response': {
                    'status': 'ok',
                    'albumList2': {'album': []},
                  },
                }),
              );
            },
          ),
        );
      final repo = RealMusicRepository(
        store: store,
        database: db,
        clientFactory: (s) {
          factoryCalls++;
          return SubsonicClient(s, dio: dio);
        },
      );
      await repo.albums();
      await repo.albums();
      expect(factoryCalls, 1);
    });

    test('music repo: a changed token creates a fresh client', () async {
      await store.add(_server(id: 'srv-a', username: 'yang', token: 'pw-a'));
      var factoryCalls = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                _ok(options, {
                  'subsonic-response': {
                    'status': 'ok',
                    'albumList2': {'album': []},
                  },
                }),
              );
            },
          ),
        );
      final repo = RealMusicRepository(
        store: store,
        database: db,
        clientFactory: (s) {
          factoryCalls++;
          return SubsonicClient(s, dio: dio);
        },
      );
      await repo.albums();
      expect(factoryCalls, 1);
      final updated = store.servers.first.copyWith(token: 'pw-b');
      await store.update(updated);
      await repo.albums();
      expect(factoryCalls, 2);
    });

    test('video repo: two movie loads create one EmbyClient', () async {
      await store.add(
        _server(
          id: 'srv-e',
          type: ServerType.emby,
          host: 'https://cf.imetyou.top',
          username: 'yang',
          token: 'tok',
        ),
      );
      var factoryCalls = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('Users/Me')) {
                handler.resolve(_ok(options, {'Id': 'user-1'}));
                return;
              }
              handler.resolve(_ok(options, {'Items': []}));
            },
          ),
        );
      final repo = RealVideoRepository(
        store: store,
        database: db,
        clientFactory: (s) {
          factoryCalls++;
          return EmbyClient(s, dio: dio);
        },
      );
      await repo.movies();
      await repo.movies();
      expect(factoryCalls, 1);
    });

    test(
      'download repo: two refreshes create one qB client (one login)',
      () async {
        await store.add(
          _server(
            id: 'srv-qb',
            type: ServerType.qbittorrent,
            host: 'https://sg.kass.qzz.io/qb/',
            username: 'yang',
            token: 'pw',
          ),
        );
        var factoryCalls = 0;
        var logins = 0;
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                if (options.path.contains('auth/login')) {
                  logins++;
                  handler.resolve(
                    _ok(
                      options,
                      'Ok',
                      headers: {
                        'set-cookie': ['SID=s1; path=/'],
                      },
                    ),
                  );
                  return;
                }
                handler.resolve(_ok(options, []));
              },
            ),
          );
        final repo = RealDownloadRepository(
          store: store,
          database: db,
          qbFactory: (s) {
            factoryCalls++;
            return QbittorrentClient(s, dio: dio);
          },
        );
        await repo.refresh();
        await repo.refresh();
        expect(factoryCalls, 1);
        expect(logins, 1);
      },
    );
  });

  group('Fix 9 — PlayerService queue and seek guards', () {
    late _FixFakeBackend backend;
    late PlayerService service;
    late AppDatabase db;

    const tracks = [
      Track(
        id: 't1',
        title: 'One',
        artist: 'A',
        durationSeconds: 200,
        serverId: 'srv-a',
      ),
      Track(
        id: 't2',
        title: 'Two',
        artist: 'A',
        durationSeconds: 180,
        serverId: 'srv-a',
      ),
    ];

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      backend = _FixFakeBackend();
      service = PlayerService(
        streamUrlFor: (t) => 'https://example.invalid/stream?id=${t.id}',
        backendFactory: () => backend,
        history: PlaybackStore(db),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('completed firing twice advances only one track', () async {
      await service.playQueue(tracks);
      await Future<void>.delayed(Duration.zero);
      backend.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      backend.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.currentTrack?.id, 't2');
      expect(service.isPlaying, isTrue);
    });

    test('seek clamps to [0, duration]', () async {
      await service.playQueue(tracks);
      await service.seek(const Duration(seconds: 500));
      expect(service.position, const Duration(seconds: 200));
      expect(backend.lastSeek, const Duration(seconds: 200));
      await service.seek(const Duration(seconds: -5));
      expect(service.position, Duration.zero);
      expect(backend.lastSeek, Duration.zero);
    });

    test('next at the end of the queue stops and saves the position', () async {
      await service.playQueue(tracks);
      await service.next();
      await service.seek(const Duration(seconds: 20));
      await service.next();
      expect(service.isPlaying, isFalse);
      expect(backend.stopCalls, 1);
      final rows = await db.select(db.playbackHistory).get();
      final t2 = rows.firstWhere((r) => r.itemId == 't2');
      expect(t2.positionSeconds, 20);
    });

    test('playQueue([]) clears the current track and stops', () async {
      await service.playQueue(tracks);
      expect(service.hasTrack, isTrue);
      await service.playQueue([]);
      expect(service.hasTrack, isFalse);
      expect(service.currentTrack, isNull);
      expect(service.isPlaying, isFalse);
      expect(backend.stopCalls, 1);
    });
  });

  group('Fix 9b — VideoPlayerService seek clamps to duration', () {
    test('seek beyond duration clamps', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final backend = _FixFakeVideoBackend();
      final service = VideoPlayerService(
        backendFactory: () => backend,
        history: PlaybackStore(db),
      );
      addTearDown(service.dispose);
      const track = Track(
        id: 'm1',
        title: 'The Last Horizon',
        artist: '',
        durationSeconds: 7620,
        serverId: 'srv-emby',
      );
      await service.open('https://example.invalid/x', track);
      await service.seek(const Duration(seconds: 999999));
      expect(service.position, const Duration(seconds: 7620));
      expect(backend.lastSeek, const Duration(seconds: 7620));
    });
  });
}

/// Fake audio backend for the fix-pass PlayerService tests.
class _FixFakeBackend implements PlayerBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  String? openedUrl;
  Duration? lastSeek;
  int playCalls = 0;
  int pauseCalls = 0;
  int stopCalls = 0;

  void emitCompleted() => _completed.add(true);

  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;
  @override
  Stream<bool> get completed => _completed.stream;

  @override
  Future<void> open(String url) async {
    openedUrl = url;
    _duration.add(const Duration(seconds: 200));
  }

  @override
  Future<void> play() async {
    playCalls++;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _playing.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
    _position.add(position);
  }

  double _volume = 1.0;
  double? lastVolume;

  @override
  double get volume => _volume;

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    lastVolume = _volume;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _playing.add(false);
  }

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
  }
}

/// Fake video backend for the fix-pass VideoPlayerService tests.
class _FixFakeVideoBackend implements VideoBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  String? openedUrl;
  Duration? openedStart;
  Duration? lastSeek;
  String? subtitleUrl;

  void emitPosition(Duration position) => _position.add(position);
  void emitCompleted() => _completed.add(true);

  @override
  Stream<bool> get playing => _playing.stream;
  @override
  Stream<Duration> get position => _position.stream;
  @override
  Stream<Duration> get duration => _duration.stream;
  @override
  Stream<bool> get completed => _completed.stream;
  @override
  Object? get videoController => null;

  @override
  Future<void> open(
    String url, {
    Duration startPosition = Duration.zero,
  }) async {
    openedUrl = url;
    openedStart = startPosition;
    _duration.add(const Duration(seconds: 7620));
  }

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
    _position.add(position);
  }

  @override
  Future<void> stop() async => _playing.add(false);

  @override
  Future<void> setSubtitleTrack(String? url) async {
    subtitleUrl = url;
  }

  @override
  Future<void> dispose() async {
    await _playing.close();
    await _position.close();
    await _duration.close();
    await _completed.close();
  }
}

void _fixPassPart3() {
  group('Fix 10 — VideoPlayerPage resume and initial subtitle', () {
    late AppDatabase db;
    late _FixFakeVideoBackend backend;
    late VideoPlayerService service;

    const item = VideoItem(
      id: 'm1',
      title: 'The Last Horizon',
      durationSeconds: 7620,
      playbackPositionSeconds: 60,
      serverId: 'srv-emby',
    );

    const subtitles = [
      SubtitleTrackInfo(index: 2, codec: 'srt', language: 'eng'),
    ];

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      backend = _FixFakeVideoBackend();
      service = VideoPlayerService(
        backendFactory: () => backend,
        history: PlaybackStore(db),
      );
    });

    tearDown(() async {
      service.dispose();
      await db.close();
    });

    Future<void> pumpPage(
      WidgetTester tester, {
      required _FixFakeVideoRepo repo,
      SettingsService? settings,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: VideoPlayerPage(
            item: item,
            repo: repo,
            history: PlaybackStore(db),
            subtitles: subtitles,
            service: service,
            settings: settings,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('initial subtitle is applied on direct play', (tester) async {
      final repo = _FixFakeVideoRepo();
      await pumpPage(tester, repo: repo, settings: SettingsService());
      expect(backend.openedUrl, contains('/Videos/m1/stream'));
      expect(backend.subtitleUrl, 'https://example.invalid/sub.srt');
    });

    testWidgets('quality change re-opens at the current position', (
      tester,
    ) async {
      final repo = _FixFakeVideoRepo();
      await pumpPage(tester, repo: repo, settings: SettingsService());
      expect(backend.openedStart, const Duration(seconds: 60));
      // Playback has advanced past the stored resume point.
      backend.emitPosition(const Duration(seconds: 100));
      await tester.pump();
      // Pick 720p from the quality sheet.
      await tester.tap(find.byTooltip('清晰度'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('720p'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(repo.lastQuality, VideoQuality.p720);
      expect(backend.openedStart, const Duration(seconds: 100));
    });
  });
}

/// Fake video repo for the VideoPlayerPage fix tests.
class _FixFakeVideoRepo implements VideoRepository {
  VideoQuality? lastQuality;

  @override
  bool get hasCredentials => true;

  @override
  Future<({PlaybackDecision decision, String url})> decidePlayback(
    VideoItem item, {
    VideoQuality quality = VideoQuality.direct,
    SubtitleTrackInfo? subtitle,
  }) async {
    lastQuality = quality;
    if (quality == VideoQuality.direct) {
      return (
        decision: const PlaybackDecision(kind: PlaybackKind.direct),
        url: 'https://example.invalid/Videos/m1/stream',
      );
    }
    return (
      decision: PlaybackDecision(
        kind: PlaybackKind.transcode,
        maxStreamingBitrate: quality.maxStreamingBitrate,
      ),
      url: 'https://example.invalid/Videos/m1/master.m3u8',
    );
  }

  @override
  String subtitleUrlFor(VideoItem item, SubtitleTrackInfo track) =>
      'https://example.invalid/sub.srt';

  @override
  Future<void> reportProgress(
    VideoItem item,
    Duration position, {
    bool isPaused = false,
  }) async {}

  @override
  Future<void> markPlayed(VideoItem item) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _fixPassPart4() {
  group('Fix 11 — Downloads addTask validates its input', () {
    late AppDatabase db;
    late ServerStore store;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      store = ServerStore(database: db);
    });

    tearDown(() async {
      await db.close();
    });

    Future<RealDownloadRepository> makeRepo({
      required List<String> calls,
    }) async {
      await store.add(
        _server(
          id: 'srv-qb',
          type: ServerType.qbittorrent,
          host: 'https://sg.kass.qzz.io/qb/',
          username: 'yang',
          token: 'pw',
        ),
      );
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              calls.add(options.path);
              if (options.path.contains('auth/login')) {
                handler.resolve(
                  _ok(
                    options,
                    'Ok',
                    headers: {
                      'set-cookie': ['SID=s1; path=/'],
                    },
                  ),
                );
                return;
              }
              if (options.path.contains('torrents/info')) {
                handler.resolve(_ok(options, []));
                return;
              }
              handler.resolve(_ok(options, 'Ok.'));
            },
          ),
        );
      return RealDownloadRepository(
        store: store,
        database: db,
        qbFactory: (s) => QbittorrentClient(s, dio: dio),
      );
    }

    test(
      'empty and garbage input are rejected without a network call',
      () async {
        final calls = <String>[];
        final repo = await makeRepo(calls: calls);
        expect(await repo.addTask(magnetOrUrl: ''), isFalse);
        expect(await repo.addTask(magnetOrUrl: '   '), isFalse);
        expect(await repo.addTask(magnetOrUrl: 'hello world'), isFalse);
        expect(
          await repo.addTask(magnetOrUrl: 'ftp://example.com/x.torrent'),
          isFalse,
        );
        expect(calls, isEmpty);
      },
    );

    test('magnet and http(s) URLs are accepted', () async {
      final calls = <String>[];
      final repo = await makeRepo(calls: calls);
      expect(
        await repo.addTask(magnetOrUrl: 'magnet:?xt=urn:btih:abc'),
        isTrue,
      );
      expect(
        await repo.addTask(magnetOrUrl: 'https://example.com/x.torrent'),
        isTrue,
      );
      expect(calls, contains('api/v2/torrents/add'));
    });
  });

  group('Fix 12 — Downloads delete honours a failed native delete', () {
    late AppDatabase db;
    late ServerStore store;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      store = ServerStore(database: db);
    });

    tearDown(() async {
      await db.close();
    });

    test('qB delete returning non-200 keeps the task', () async {
      await store.add(
        _server(
          id: 'srv-qb',
          type: ServerType.qbittorrent,
          host: 'https://sg.kass.qzz.io/qb/',
          username: 'yang',
          token: 'pw',
        ),
      );
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('auth/login')) {
                handler.resolve(
                  _ok(
                    options,
                    'Ok',
                    headers: {
                      'set-cookie': ['SID=s1; path=/'],
                    },
                  ),
                );
                return;
              }
              if (options.path.contains('torrents/info')) {
                handler.resolve(
                  _ok(options, [
                    {
                      'hash': 'abc',
                      'name': 'Ubuntu.iso',
                      'state': 'downloading',
                      'progress': 0.5,
                      'dlspeed': 1000,
                      'size': 100,
                      'completed': 50,
                      'eta': 60,
                      'save_path': '/dl',
                    },
                  ]),
                );
                return;
              }
              if (options.path.contains('torrents/delete')) {
                // qB accepted the request but did not delete (201).
                handler.resolve(_ok(options, '', statusCode: 201));
                return;
              }
              handler.resolve(_ok(options, 'Ok.'));
            },
          ),
        );
      final repo = RealDownloadRepository(
        store: store,
        database: db,
        qbFactory: (s) => QbittorrentClient(s, dio: dio),
      );
      await repo.refresh();
      expect(repo.tasks, hasLength(1));
      final task = repo.tasks.first;
      expect(await repo.deleteTask(task), isFalse);
      expect(repo.tasks, hasLength(1));
      expect(repo.tasks.first.name, 'Ubuntu.iso');
    });

    test('aria2 remove returning another gid keeps the task', () async {
      await store.add(
        _server(
          id: 'srv-aria',
          type: ServerType.aria2,
          host: 'http://192.168.1.10:6800',
          username: '',
          token: '',
        ),
      );
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final data = options.data as Map<String, dynamic>;
              switch (data['method']) {
                case 'aria2.tellActive':
                  handler.resolve(
                    _ok(options, {
                      'jsonrpc': '2.0',
                      'id': 1,
                      'result': [
                        {
                          'gid': 'gid-1',
                          'status': 'active',
                          'totalLength': '100',
                          'completedLength': '50',
                          'downloadSpeed': '10',
                          'files': [
                            {'path': '/data/Album.flac'},
                          ],
                        },
                      ],
                    }),
                  );
                case 'aria2.tellWaiting':
                case 'aria2.tellStopped':
                  handler.resolve(
                    _ok(options, {'jsonrpc': '2.0', 'id': 1, 'result': []}),
                  );
                case 'aria2.remove':
                  // Server answered, but not with this gid.
                  handler.resolve(
                    _ok(options, {
                      'jsonrpc': '2.0',
                      'id': 1,
                      'result': 'other-gid',
                    }),
                  );
                default:
                  handler.resolve(
                    _ok(options, {'jsonrpc': '2.0', 'id': 1, 'result': 'ok'}),
                  );
              }
            },
          ),
        );
      final repo = RealDownloadRepository(
        store: store,
        database: db,
        ariaFactory: (s) => Aria2Client(s, dio: dio),
      );
      await repo.refresh();
      expect(repo.tasks, hasLength(1));
      expect(await repo.deleteTask(repo.tasks.first), isFalse);
      expect(repo.tasks, hasLength(1));
    });
  });

  group('Fix 13 — Downloads refresh coalesces overlapping calls', () {
    test('three concurrent refreshes run at most two fetch rounds', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = ServerStore(database: db);
      await store.add(
        _server(
          id: 'srv-qb',
          type: ServerType.qbittorrent,
          host: 'https://sg.kass.qzz.io/qb/',
          username: 'yang',
          token: 'pw',
        ),
      );
      var infoCalls = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              if (options.path.contains('auth/login')) {
                handler.resolve(
                  _ok(
                    options,
                    'Ok',
                    headers: {
                      'set-cookie': ['SID=s1; path=/'],
                    },
                  ),
                );
                return;
              }
              infoCalls++;
              await Future<void>.delayed(const Duration(milliseconds: 100));
              handler.resolve(
                _ok(options, [
                  {
                    'hash': 'abc',
                    'name': 'Ubuntu.iso',
                    'state': 'downloading',
                    'progress': 0.5,
                    'dlspeed': 1000,
                    'size': 100,
                    'completed': 50,
                    'eta': 60,
                    'save_path': '/dl',
                  },
                ]),
              );
            },
          ),
        );
      final repo = RealDownloadRepository(
        store: store,
        database: db,
        qbFactory: (s) => QbittorrentClient(s, dio: dio),
      );
      await Future.wait([repo.refresh(), repo.refresh(), repo.refresh()]);
      expect(infoCalls, 2);
      expect(repo.tasks, hasLength(1));
      expect(repo.tasks.first.name, 'Ubuntu.iso');
    });
  });

  group('Fix 17 — qB testConnectionResult survives a post-login failure', () {
    test(
      'version check throwing after login still returns needsAuth',
      () async {
        var versionCalls = 0;
        final dio = Dio()
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (options, handler) {
                if (options.path.contains('auth/login')) {
                  handler.resolve(
                    _ok(
                      options,
                      'Ok',
                      headers: {
                        'set-cookie': ['SID=s1; path=/'],
                      },
                    ),
                  );
                  return;
                }
                versionCalls++;
                if (versionCalls == 1) {
                  handler.reject(
                    DioException(
                      requestOptions: options,
                      response: _ok(options, 'Forbidden', statusCode: 403),
                      type: DioExceptionType.badResponse,
                    ),
                  );
                  return;
                }
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.connectionError,
                    error: 'connection reset',
                  ),
                );
              },
            ),
          );
        final client = QbittorrentClient(
          _server(
            type: ServerType.qbittorrent,
            host: 'https://sg.kass.qzz.io/qb/',
            username: 'yang',
            token: 'pw',
          ),
          dio: dio,
        );
        final result = await client.testConnectionResult();
        expect(result.needsAuth, isTrue);
      },
    );
  });

  group('Fix 18 — seriesDetail sorts seasons and episodes', () {
    test('seasons by index, episodes by season then episode', () async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = ServerStore(database: db);
      await store.add(
        _server(
          id: 'srv-e',
          type: ServerType.emby,
          host: 'https://cf.imetyou.top',
          username: 'yang',
          token: 'tok',
        ),
      );
      Map<String, dynamic> episode(String id, int season, int ep) => {
        'Id': id,
        'Name': 'E$ep',
        'Type': 'Episode',
        'SeriesId': 's1',
        'SeasonId': 'se$season',
        'ParentIndexNumber': season,
        'IndexNumber': ep,
        'RunTimeTicks': 10000000,
        'UserData': {'PlayedPercentage': 0, 'PlaybackPositionTicks': 0},
      };
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('Users/Me')) {
                handler.resolve(_ok(options, {'Id': 'user-1'}));
                return;
              }
              if (options.path.contains('/Seasons')) {
                handler.resolve(
                  _ok(options, {
                    'Items': [
                      {'Id': 'se2', 'Name': 'Season 2', 'IndexNumber': 2},
                      {'Id': 'se0', 'Name': 'Specials', 'IndexNumber': 0},
                      {'Id': 'se1', 'Name': 'Season 1', 'IndexNumber': 1},
                    ],
                  }),
                );
                return;
              }
              if (options.path.contains('/Episodes')) {
                handler.resolve(
                  _ok(options, {
                    'Items': [
                      episode('e2', 1, 2),
                      episode('e3', 2, 1),
                      episode('e1', 1, 1),
                    ],
                  }),
                );
                return;
              }
              handler.resolve(
                _ok(options, {'Id': 's1', 'Name': 'Show', 'Type': 'Series'}),
              );
            },
          ),
        );
      final repo = RealVideoRepository(
        store: store,
        database: db,
        clientFactory: (s) => EmbyClient(s, dio: dio),
      );
      final detail = await repo.seriesDetail('s1', 'srv-e');
      expect(detail.seasons.map((s) => s.indexNumber), [0, 1, 2]);
      expect(detail.episodes.map((e) => e.id), ['e1', 'e2', 'e3']);
    });
  });

  group(
    'Fix 14 — DownloadsPage restarts polling when the interval changes',
    () {
      testWidgets('settings change re-starts the timer', (tester) async {
        SharedPreferences.setMockInitialValues({});
        final settings = SettingsService();
        await settings.load();
        final repo = _FixFakeDownloadRepo();
        final db = AppDatabase.forExecutor(NativeDatabase.memory());
        addTearDown(() async => db.close());
        final store = ServerStore(database: db);
        addTearDown(repo.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: DownloadsPage(repo: repo, store: store, settings: settings),
            ),
          ),
        );
        await tester.pump();
        expect(repo.startPollingCalls, [5]);
        await settings.setPollingIntervalSeconds(10);
        await tester.pump();
        expect(repo.startPollingCalls, [5, 10]);
        repo.stopPolling();
      });
    },
  );
}

/// Fake download repo that records polling calls, for the page test.
class _FixFakeDownloadRepo extends ChangeNotifier
    implements DownloadRepository {
  final startPollingCalls = <int>[];

  @override
  bool get hasCredentials => true;
  @override
  List<Server> get usableDownloaders => [];

  /// Per-page server filter (unused by this fake: it has no tasks).
  @override
  String? serverFilter;

  @override
  List<DownloadTask> get tasks => [];
  @override
  Map<String, String> get errors => {};
  @override
  bool get isLoading => false;
  @override
  List<DownloadTask> get activeTasks => [];
  @override
  int get totalSpeedBytesPerSec => 0;

  @override
  Future<void> refresh() async {}

  @override
  Future<bool> addTask({
    required String magnetOrUrl,
    String? downloaderServerId,
    String? savePath,
  }) async => false;

  @override
  Future<bool> pauseTask(DownloadTask task) async => false;
  @override
  Future<bool> resumeTask(DownloadTask task) async => false;
  @override
  Future<bool> deleteTask(
    DownloadTask task, {
    bool deleteFiles = false,
  }) async => false;
  @override
  Future<bool> retryTask(DownloadTask task) async => false;

  @override
  void startPolling({int intervalSeconds = 5}) {
    startPollingCalls.add(intervalSeconds);
  }

  @override
  void stopPolling() {}
}

void _fixPassPart5() {
  group('Fix 15 — pages load when credentials appear after first build', () {
    testWidgets('MusicPage loads albums added to the store later', (
      tester,
    ) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = _MutableStore(database: db);
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                _ok(options, {
                  'subsonic-response': {
                    'status': 'ok',
                    'albumList2': {
                      'album': [
                        {
                          'id': 'a1',
                          'name': 'Midnight City',
                          'artist': 'Neon Lights',
                          'year': 2024,
                          'songCount': 12,
                        },
                      ],
                    },
                  },
                }),
              );
            },
          ),
        );
      final repo = RealMusicRepository(
        store: store,
        database: db,
        clientFactory: (s) => SubsonicClient(s, dio: dio),
      );
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _FixFakeBackend.new,
      );
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MusicPage(
              repo: repo,
              player: player,
              store: store,
              settings: SettingsService(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('还没有 Navidrome 账号'), findsOneWidget);
      store.addServer(_server(id: 'srv-a', username: 'yang', token: 'pw'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Midnight City'), findsOneWidget);
      expect(find.text('还没有 Navidrome 账号'), findsNothing);
    });

    testWidgets('VideoPage loads movies added to the store later', (
      tester,
    ) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = _MutableStore(database: db);
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final path = options.path;
              if (path.contains('Users/Me')) {
                handler.resolve(_ok(options, {'Id': 'user-1'}));
                return;
              }
              handler.resolve(
                _ok(options, {
                  'Items': [
                    {
                      'Id': 'm1',
                      'Name': 'The Last Horizon',
                      'ProductionYear': 2024,
                      'Type': 'Movie',
                      'RunTimeTicks': 76200000000,
                      'UserData': {
                        'PlayedPercentage': 0,
                        'PlaybackPositionTicks': 0,
                      },
                    },
                  ],
                }),
              );
            },
          ),
        );
      final repo = RealVideoRepository(
        store: store,
        database: db,
        clientFactory: (s) => EmbyClient(s, dio: dio),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VideoPage(
              repo: repo,
              store: store,
              history: PlaybackStore(db),
              settings: SettingsService(),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('还没有 Emby 账号'), findsOneWidget);
      store.addServer(
        _server(
          id: 'srv-e',
          type: ServerType.emby,
          host: 'https://cf.imetyou.top',
          username: 'yang',
          token: 'tok',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('The Last Horizon'), findsWidgets);
      expect(find.text('还没有 Emby 账号'), findsNothing);
    });

    testWidgets('DownloadsPage refreshes when a downloader is added later', (
      tester,
    ) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = _MutableStore(database: db);
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('auth/login')) {
                handler.resolve(
                  _ok(
                    options,
                    'Ok',
                    headers: {
                      'set-cookie': ['SID=s1; path=/'],
                    },
                  ),
                );
                return;
              }
              handler.resolve(
                _ok(options, [
                  {
                    'hash': 'abc',
                    'name': 'Ubuntu.iso',
                    'state': 'downloading',
                    'progress': 0.5,
                    'dlspeed': 1000,
                    'size': 100,
                    'completed': 50,
                    'eta': 60,
                    'save_path': '/dl',
                  },
                ]),
              );
            },
          ),
        );
      final repo = RealDownloadRepository(
        store: store,
        database: db,
        qbFactory: (s) => QbittorrentClient(s, dio: dio),
      );
      addTearDown(repo.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadsPage(
              repo: repo,
              store: store,
              settings: SettingsService(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      repo.stopPolling();
      expect(find.text('还没有下载器账号'), findsOneWidget);
      store.addServer(
        _server(
          id: 'srv-qb',
          type: ServerType.qbittorrent,
          host: 'https://sg.kass.qzz.io/qb/',
          username: 'yang',
          token: 'pw',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      repo.stopPolling();
      expect(find.text('Ubuntu.iso'), findsOneWidget);
      expect(find.text('还没有下载器账号'), findsNothing);
    });
  });

  group('Fix 16 — AlbumDetailPage shows the server star state', () {
    testWidgets('a server-starred track starts with a filled heart', (
      tester,
    ) async {
      final repo = _FixFakeMusicRepo();
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _FixFakeBackend.new,
      );
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: AlbumDetailPage(
            album: const Album(
              id: 'a1',
              title: 'Midnight City',
              artist: 'Neon Lights',
              serverId: 'srv-a',
            ),
            repo: repo,
            player: player,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Only the server-starred track has a filled heart; the album
      // button and the other track start unstarred.
      expect(find.byIcon(Icons.favorite), findsOneWidget);
      // Tapping the other track's star fills its heart too.
      final tile = find.ancestor(
        of: find.text('City Lights'),
        matching: find.byType(ListTile),
      );
      final starButton = find.descendant(
        of: tile,
        matching: find.byIcon(Icons.favorite_border),
      );
      await tester.tap(starButton);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.favorite), findsNWidgets(2));
    });
  });

  group('Fix 19 — HomePage shows real library data, never demo data', () {
    testWidgets('real titles appear, demo titles do not', (tester) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = _MutableStore(database: db);
      final history = PlaybackStore(db);
      await history.recordStart(
        const Track(
          id: 't1',
          title: 'Midnight Drive',
          artist: 'Neon Lights',
          serverId: 'srv-a',
        ),
      );
      final embyDio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('Users/Me')) {
                handler.resolve(_ok(options, {'Id': 'user-1'}));
                return;
              }
              handler.resolve(
                _ok(options, {
                  'Items': [
                    {
                      'Id': 'm1',
                      'Name': 'The Last Horizon',
                      'ProductionYear': 2024,
                      'Type': 'Movie',
                      'RunTimeTicks': 76200000000,
                      'UserData': {
                        'PlayedPercentage': 62,
                        'PlaybackPositionTicks': 47244000000,
                      },
                    },
                  ],
                }),
              );
            },
          ),
        );
      final musicDio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(
                _ok(options, {
                  'subsonic-response': {
                    'status': 'ok',
                    'albumList2': {
                      'album': [
                        {
                          'id': 'a1',
                          'name': 'Midnight City',
                          'artist': 'Neon Lights',
                          'year': 2024,
                          'songCount': 12,
                        },
                      ],
                    },
                  },
                }),
              );
            },
          ),
        );
      final qbDio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.resolve(_ok(options, []));
            },
          ),
        );
      store.addServer(_server(id: 'srv-a', username: 'yang', token: 'pw'));
      store.addServer(
        _server(
          id: 'srv-e',
          type: ServerType.emby,
          host: 'https://cf.imetyou.top',
          username: 'yang',
          token: 'tok',
        ),
      );
      final musicRepo = RealMusicRepository(
        store: store,
        database: db,
        clientFactory: (s) => SubsonicClient(s, dio: musicDio),
      );
      final videoRepo = RealVideoRepository(
        store: store,
        database: db,
        clientFactory: (s) => EmbyClient(s, dio: embyDio),
      );
      final downloadRepo = RealDownloadRepository(
        store: store,
        database: db,
        qbFactory: (s) => QbittorrentClient(s, dio: qbDio),
      );
      addTearDown(downloadRepo.dispose);
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _FixFakeBackend.new,
      );
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomePage(
              store: store,
              downloadRepo: downloadRepo,
              musicRepo: musicRepo,
              videoRepo: videoRepo,
              history: history,
              player: player,
              settings: SettingsService(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('The Last Horizon'), findsWidgets);
      expect(find.text('Midnight Drive'), findsOneWidget);
      expect(find.text('Midnight City'), findsOneWidget);
      // Demo-only titles must never appear once real data is wired.
      expect(find.text('Mountain Pass'), findsNothing);
      expect(find.text('Silent Echo'), findsNothing);
      expect(find.text('Paper Planes'), findsNothing);
      expect(find.text('Blue Hour'), findsNothing);
    });

    testWidgets('no servers: hint shown, demo titles absent', (tester) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = ServerStore(database: db);
      final musicRepo = RealMusicRepository(store: store, database: db);
      final videoRepo = RealVideoRepository(store: store, database: db);
      final downloadRepo = RealDownloadRepository(store: store, database: db);
      addTearDown(downloadRepo.dispose);
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _FixFakeBackend.new,
      );
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomePage(
              store: store,
              downloadRepo: downloadRepo,
              musicRepo: musicRepo,
              videoRepo: videoRepo,
              history: PlaybackStore(db),
              player: player,
              settings: SettingsService(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('还没有服务器'), findsWidgets);
      expect(find.text('The Last Horizon'), findsNothing);
      expect(find.text('Midnight City'), findsNothing);
      expect(find.text('Mountain Pass'), findsNothing);
    });
  });
}

/// Fake music repo for the AlbumDetailPage star test: track t1 is
/// starred on the server, t2 is not.
class _FixFakeMusicRepo implements MusicRepository {
  final _starredTracks = {'t1'};

  @override
  bool get hasCredentials => true;

  @override
  Future<({Album album, List<Track> tracks})> album(
    String albumId,
    String serverId,
  ) async => (
    album: const Album(
      id: 'a1',
      title: 'Midnight City',
      artist: 'Neon Lights',
      serverId: 'srv-a',
    ),
    tracks: const [
      Track(
        id: 't1',
        title: 'Midnight Drive',
        artist: 'Neon Lights',
        album: 'Midnight City',
        durationSeconds: 214,
        serverId: 'srv-a',
      ),
      Track(
        id: 't2',
        title: 'City Lights',
        artist: 'Neon Lights',
        album: 'Midnight City',
        durationSeconds: 187,
        serverId: 'srv-a',
      ),
    ],
  );

  @override
  Future<({List<Track> songs, List<Album> albums})> starred({
    String? serverId,
  }) async => (
    songs: _starredTracks
        .map(
          (id) => Track(
            id: id,
            title: id == 't1' ? 'Midnight Drive' : 'City Lights',
            artist: 'Neon Lights',
            serverId: 'srv-a',
          ),
        )
        .toList(),
    albums: <Album>[],
  );

  @override
  Future<bool> toggleStarTrack(Track track) async {
    if (_starredTracks.contains(track.id)) {
      _starredTracks.remove(track.id);
      return false;
    }
    _starredTracks.add(track.id);
    return true;
  }

  @override
  Future<bool> toggleStarAlbum(Album album) async => false;

  @override
  Future<bool> isStarredTrack(Track track) async =>
      _starredTracks.contains(track.id);

  @override
  Future<bool> isStarredAlbum(Album album) async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
