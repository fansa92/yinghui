import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yinghui/core/models/server.dart';
import 'package:yinghui/core/settings.dart';
import 'package:yinghui/data/api/subsonic_client.dart';
import 'package:yinghui/data/db/app_database.dart';
import 'package:yinghui/data/models/track.dart';
import 'package:yinghui/data/repositories/fake_repos.dart';
import 'package:yinghui/data/repositories/music_repository.dart';
import 'package:yinghui/data/repositories/playback_store.dart';
import 'package:yinghui/data/repositories/server_store.dart';
import 'package:yinghui/features/music/music_page.dart';
import 'package:yinghui/features/player/player_service.dart';

Server _server({
  String id = 'srv-1',
  String host = '192.168.1.10',
  int port = 4533,
  String username = 'yang',
  String token = 's3cret',
}) => Server(
  id: id,
  type: ServerType.navidrome,
  name: 'Test Navidrome',
  host: host,
  port: port,
  username: username,
  token: token,
);

/// A Dio that answers Subsonic calls from [respond], keyed by the
/// endpoint name in the request path (e.g. `getAlbumList2`).
Dio _mockSubsonicDio(
  Map<String, dynamic> Function(RequestOptions options) respond,
) {
  return Dio()
    ..interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final data = respond(options);
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'subsonic-response': data},
            ),
          );
        },
      ),
    );
}

Map<String, dynamic> _albumJson({
  String id = 'a1',
  String name = 'Midnight City',
  String artist = 'Neon Lights',
  int year = 2024,
  int songCount = 12,
  String? coverArt,
}) => {
  'id': id,
  'name': name,
  'artist': artist,
  'year': year,
  'songCount': songCount,
  'coverArt': ?coverArt,
};

Map<String, dynamic> _songJson({
  String id = 't1',
  String title = 'Midnight Drive',
  String artist = 'Neon Lights',
  String album = 'Midnight City',
  int duration = 214,
  String? coverArt,
}) => {
  'id': id,
  'title': title,
  'artist': artist,
  'album': album,
  'albumId': 'a1',
  'duration': duration,
  'coverArt': ?coverArt,
};

void main() {
  group('Subsonic music endpoints (mocked Dio)', () {
    test('getAlbumList2 parses albums, coverArt becomes a URL', () async {
      final dio = _mockSubsonicDio(
        (_) => {
          'status': 'ok',
          'albumList2': {
            'album': [
              _albumJson(coverArt: 'al-1'),
              _albumJson(
                id: 'a2',
                name: 'Blue Hour',
                artist: 'Aurora Field',
                year: 2023,
                songCount: 9,
              ),
            ],
          },
        },
      );
      final client = SubsonicClient(_server(), dio: dio);
      final albums = await client.getAlbumList2();
      expect(albums.length, 2);
      expect(albums.first.title, 'Midnight City');
      expect(albums.first.coverUrl, contains('/rest/getCoverArt?'));
      expect(albums.first.coverUrl, contains('id=al-1'));
      expect(albums[1].coverUrl, isNull);
    });

    test('searchAll parses songs, albums and artists', () async {
      final dio = _mockSubsonicDio(
        (_) => {
          'status': 'ok',
          'searchResult3': {
            'song': [_songJson()],
            'album': [_albumJson()],
            'artist': [
              {'id': 'ar1', 'name': 'Neon Lights', 'albumCount': 3},
            ],
          },
        },
      );
      final client = SubsonicClient(_server(), dio: dio);
      final result = await client.searchAll('midnight');
      expect(result.songs.length, 1);
      expect(result.songs.first.title, 'Midnight Drive');
      expect(result.albums.length, 1);
      expect(result.artists.length, 1);
      expect(result.artists.first.albumCount, 3);
    });

    test('getAlbum returns album + its tracks', () async {
      final dio = _mockSubsonicDio(
        (_) => {
          'status': 'ok',
          'album': {
            ..._albumJson(),
            'song': [_songJson(), _songJson(id: 't2', title: 'City Lights')],
          },
        },
      );
      final client = SubsonicClient(_server(), dio: dio);
      final result = await client.getAlbum('a1');
      expect(result.album.title, 'Midnight City');
      expect(result.tracks.length, 2);
      expect(result.tracks[1].title, 'City Lights');
    });

    test('getArtists flattens the index', () async {
      final dio = _mockSubsonicDio(
        (_) => {
          'status': 'ok',
          'artists': {
            'index': [
              {
                'name': 'N',
                'artist': [
                  {'id': 'ar1', 'name': 'Neon Lights', 'albumCount': 3},
                ],
              },
              {
                'name': 'A',
                'artist': [
                  {'id': 'ar2', 'name': 'Aurora Field', 'albumCount': 2},
                ],
              },
            ],
          },
        },
      );
      final client = SubsonicClient(_server(), dio: dio);
      final artists = await client.getArtists();
      expect(artists.map((a) => a.name), ['Neon Lights', 'Aurora Field']);
    });

    test('getStarred2, star/unstar and playlists parse', () async {
      String? seenPath;
      Map<String, dynamic>? seenQuery;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              seenPath = options.path;
              seenQuery = Map<String, dynamic>.from(options.queryParameters);
              final data = switch (seenPath) {
                _ when seenPath!.contains('getStarred2') => {
                  'status': 'ok',
                  'starred2': {
                    'song': [_songJson()],
                    'album': [_albumJson()],
                  },
                },
                _ when seenPath!.contains('getPlaylists') => {
                  'status': 'ok',
                  'playlists': {
                    'playlist': [
                      {'id': 'p1', 'name': 'Road Trip', 'songCount': 5},
                    ],
                  },
                },
                _ when seenPath!.contains('getPlaylist') => {
                  'status': 'ok',
                  'playlist': {
                    'entry': [_songJson()],
                  },
                },
                _ when seenPath!.contains('getGenres') => {
                  'status': 'ok',
                  'genres': {
                    'genre': [
                      {'value': 'Rock'},
                      {'value': 'Electronic'},
                    ],
                  },
                },
                _ => {'status': 'ok'},
              };
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {'subsonic-response': data},
                ),
              );
            },
          ),
        );
      final client = SubsonicClient(_server(), dio: dio);
      final starred = await client.getStarred2();
      expect(starred.songs.length, 1);
      expect(starred.albums.length, 1);
      expect(await client.star(id: 't1'), isTrue);
      expect(seenQuery?['id'], 't1');
      expect(await client.unstar(albumId: 'a1'), isTrue);
      expect(seenQuery?['albumId'], 'a1');
      final playlists = await client.getPlaylists();
      expect(playlists.single.name, 'Road Trip');
      expect(await client.getPlaylist('p1'), hasLength(1));
      expect(await client.getGenres(), ['Rock', 'Electronic']);
    });
  });

  group('RealMusicRepository merge / dedupe / fallback', () {
    late AppDatabase db;
    late ServerStore store;

    setUp(() {
      db = AppDatabase.forExecutor(NativeDatabase.memory());
      store = ServerStore(database: db);
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> addServers() async {
      await store.add(_server(id: 'srv-a', username: 'yang', token: 'pw-a'));
      await store.add(_server(id: 'srv-b', username: 'yang', token: 'pw-b'));
    }

    RealMusicRepository makeRepo(
      SubsonicClient Function(Server server) factory,
    ) =>
        RealMusicRepository(store: store, database: db, clientFactory: factory);

    test(
      'no credentials -> hasCredentials false, albums fall back to fake',
      () async {
        final repo = makeRepo((s) => SubsonicClient(s));
        expect(repo.hasCredentials, isFalse);
        expect(await repo.albums(), FakeMusicRepo.albums);
      },
    );

    test('albums merge across servers and dedupe by title+artist', () async {
      await addServers();
      Dio dioFor(String id) {
        final albums = id == 'srv-a'
            ? [
                _albumJson(),
                _albumJson(id: 'a2', name: 'Blue Hour', artist: 'Aurora Field'),
              ]
            : [
                // Same title+artist as server A: must dedupe to one.
                _albumJson(id: 'a1-dup'),
                _albumJson(id: 'a3', name: 'Golden Hour', artist: 'Coastline'),
              ];
        return _mockSubsonicDio(
          (_) => {
            'status': 'ok',
            'albumList2': {'album': albums},
          },
        );
      }

      final repo = makeRepo((s) => SubsonicClient(s, dio: dioFor(s.id)));
      final albums = await repo.albums();
      expect(albums.map((a) => a.title), [
        'Midnight City',
        'Blue Hour',
        'Golden Hour',
      ]);
      // The first server's copy wins the dedupe.
      expect(albums.first.serverId, 'srv-a');
      expect(albums.first.sourceLabel, 'Test Navidrome');
    });

    test('one server down does not blank the list', () async {
      await addServers();
      Dio dioFor(String id) {
        if (id == 'srv-b') {
          return Dio()
            ..interceptors.add(
              InterceptorsWrapper(
                onRequest: (options, handler) {
                  handler.reject(
                    DioException(
                      requestOptions: options,
                      type: DioExceptionType.connectionTimeout,
                    ),
                  );
                },
              ),
            );
        }
        return _mockSubsonicDio(
          (_) => {
            'status': 'ok',
            'albumList2': {
              'album': [_albumJson()],
            },
          },
        );
      }

      final repo = makeRepo((s) => SubsonicClient(s, dio: dioFor(s.id)));
      final albums = await repo.albums();
      expect(albums.map((a) => a.title), ['Midnight City']);
    });

    test('toggleStar flips local favourite and calls star/unstar', () async {
      await addServers();
      final starredIds = <String>[];
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (options.path.contains('star')) {
                starredIds.add(
                  '${options.path}:${options.queryParameters['id']}',
                );
              }
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'subsonic-response': {'status': 'ok'},
                  },
                ),
              );
            },
          ),
        );
      final repo = makeRepo((s) => SubsonicClient(s, dio: dio));
      const track = Track(
        id: 't1',
        title: 'Midnight Drive',
        artist: 'Neon Lights',
        serverId: 'srv-a',
      );
      expect(await repo.isStarredTrack(track), isFalse);
      expect(await repo.toggleStarTrack(track), isTrue);
      expect(await repo.isStarredTrack(track), isTrue);
      expect(starredIds, contains('rest/star:t1'));
      expect(await repo.toggleStarTrack(track), isFalse);
    });
  });

  group('PlayerService with a fake backend', () {
    late _FakeBackend backend;
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
      backend = _FakeBackend();
      service = PlayerService(
        streamUrlFor: (t) => 'https://example.invalid/rest/stream?id=${t.id}',
        backendFactory: () => backend,
        history: PlaybackStore(db),
      );
    });

    tearDown(() async {
      await db.close();
    });

    test('playQueue opens the first track and starts playing', () async {
      await service.playQueue(tracks);
      await Future<void>.delayed(Duration.zero);
      expect(service.currentTrack?.id, 't1');
      expect(backend.openedUrl, contains('id=t1'));
      expect(service.isPlaying, isTrue);
      // History row written on track start.
      final rows = await db.select(db.playbackHistory).get();
      expect(rows.length, 1);
      expect(rows.single.itemId, 't1');
    });

    test('next advances, previous restarts then goes back', () async {
      await service.playQueue(tracks);
      await service.next();
      expect(service.currentTrack?.id, 't2');
      expect(backend.openedUrl, contains('id=t2'));
      // Position > 3s: previous restarts the current track.
      backend.emitPosition(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      await service.previous();
      expect(service.currentTrack?.id, 't2');
      expect(backend.seekCalls, 1);
      // Position <= 3s: previous goes to the previous track.
      backend.emitPosition(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      await service.previous();
      expect(service.currentTrack?.id, 't1');
    });

    test('togglePlay pauses and saves the position', () async {
      await service.playQueue(tracks);
      await Future<void>.delayed(Duration.zero);
      expect(service.isPlaying, isTrue);
      await service.togglePlay();
      await Future<void>.delayed(Duration.zero);
      expect(service.isPlaying, isFalse);
      expect(backend.pauseCalls, 1);
    });

    test('completed auto-advances to the next track', () async {
      await service.playQueue(tracks);
      backend.emitCompleted();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.currentTrack?.id, 't2');
    });

    test('empty stream URL opens nothing', () async {
      final noUrl = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: () => backend,
      );
      await noUrl.playQueue(tracks);
      expect(backend.openedUrl, isNull);
    });
  });

  group('MusicPage empty state (no credentials)', () {
    testWidgets('shows "No Navidrome account yet"', (tester) async {
      final db = AppDatabase.forExecutor(NativeDatabase.memory());
      addTearDown(() async => db.close());
      final store = ServerStore(database: db);
      final repo = RealMusicRepository(store: store, database: db);
      final player = PlayerService(
        streamUrlFor: (_) => '',
        backendFactory: _FakeBackend.new,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MusicPage(
            repo: repo,
            player: player,
            store: store,
            settings: SettingsService(),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('还没有 Navidrome 账号'), findsOneWidget);
      expect(find.text('去服务器页'), findsOneWidget);
      expect(find.text('Midnight City'), findsNothing);
    });
  });
}

/// Fake audio backend: no native code, streams driven by the test.
class _FakeBackend implements PlayerBackend {
  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  String? openedUrl;
  int playCalls = 0;
  int pauseCalls = 0;
  int seekCalls = 0;

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
    seekCalls++;
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
