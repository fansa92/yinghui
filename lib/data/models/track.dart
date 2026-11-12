/// A single song, unified across Navidrome (Subsonic) and Emby audio.
class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    this.album = '',
    this.albumId = '',
    this.durationSeconds = 0,
    this.coverUrl,
    this.serverId = '',
    this.sourceLabel = '',
  });

  final String id;
  final String title;
  final String artist;
  final String album;
  final String albumId;
  final int durationSeconds;
  final String? coverUrl;
  final String serverId;

  /// Small label shown in the UI, e.g. "家里 Emby".
  final String sourceLabel;

  String get durationText {
    final m = durationSeconds ~/ 60;
    final s = durationSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}

/// An artist, from Subsonic `getArtists`.
class Artist {
  const Artist({
    required this.id,
    required this.name,
    this.albumCount = 0,
    this.serverId = '',
    this.sourceLabel = '',
  });

  final String id;
  final String name;
  final int albumCount;
  final String serverId;
  final String sourceLabel;
}

/// A playlist, from Subsonic `getPlaylists`.
class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    this.songCount = 0,
    this.serverId = '',
    this.sourceLabel = '',
  });

  final String id;
  final String name;
  final int songCount;
  final String serverId;
  final String sourceLabel;
}

/// An album, unified across Navidrome and Emby.
class Album {
  const Album({
    required this.id,
    required this.title,
    required this.artist,
    this.coverUrl,
    this.year,
    this.trackCount = 0,
    this.serverId = '',
    this.sourceLabel = '',
  });

  final String id;
  final String title;
  final String artist;
  final String? coverUrl;
  final int? year;
  final int trackCount;
  final String serverId;
  final String sourceLabel;
}
