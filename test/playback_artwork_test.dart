import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/playback_artwork.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('restored-artwork-');
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'SAF artwork recovers from missing scan covers and tolerates provider errors',
    () async {
      const source = 'content://example.documents/nas/song.flac';
      final cover = File('${directory.path}/recovered #1.jpg');
      await cover.writeAsBytes([1]);
      for (final missing in [null, '${directory.path}/removed.jpg']) {
        expect(
          await resolveEmbeddedArtworkUri(
            source,
            missing,
            extract: (path) async {
              expect(path, source);
              return cover.path;
            },
          ),
          cover.uri.toString(),
        );
      }
      var unnecessaryReads = 0;
      Future<String?> unexpectedRead(String _) async {
        unnecessaryReads++;
        return null;
      }

      for (final existing in [cover.path, cover.uri.toString()]) {
        expect(
          await resolveEmbeddedArtworkUri(
            source,
            existing,
            extract: unexpectedRead,
          ),
          isNull,
        );
      }
      expect(
        await resolveEmbeddedArtworkUri(
          source,
          null,
          extract: (_) async => throw const SocketException('NAS offline'),
        ),
        isNull,
      );
      for (final remote in [
        'network://share/song.flac',
        'https://example.test/song.flac',
      ]) {
        expect(
          await resolveEmbeddedArtworkUri(
            remote,
            null,
            extract: unexpectedRead,
          ),
          isNull,
        );
      }
      expect(unnecessaryReads, 0);
    },
  );

  test(
    'local files prefer embedded art over an online cover for offline use',
    () async {
      final cover = File('${directory.path}/embedded.jpg');
      await cover.writeAsBytes([1]);
      for (final source in [
        'content://example.documents/music/song.m4a',
        '${directory.path}/song.m4a',
      ]) {
        expect(
          await resolveEmbeddedArtworkUri(
            source,
            'https://example.test/cover.jpg',
            extract: (path) async {
              expect(path, source);
              return cover.path;
            },
          ),
          cover.uri.toString(),
        );
      }
      // A file without embedded art keeps its online cover.
      expect(
        await resolveEmbeddedArtworkUri(
          '${directory.path}/song.m4a',
          'https://example.test/cover.jpg',
          extract: (_) async => null,
        ),
        isNull,
      );
    },
  );

  test('Windows audio paths can recover missing or remote artwork', () async {
    final cover = File('${directory.path}/windows embedded #1.jpg');
    await cover.writeAsBytes([1]);
    for (final source in [
      r'D:\Music\song.flac',
      'D:/Music/song.flac',
      r'\\server\share\song.flac',
    ]) {
      for (final artwork in [
        null,
        r'C:\old covers\missing.jpg',
        'C:/old covers/missing.jpg',
        'https://example.test/cover.jpg',
      ]) {
        expect(
          await resolveEmbeddedArtworkUri(
            source,
            artwork,
            extract: (path) async {
              expect(path, source);
              return cover.path;
            },
          ),
          cover.uri.toString(),
          reason: 'source=$source artwork=$artwork',
        );
      }
    }
  });

  test(
    'relative and remote audio paths never trigger local extraction',
    () async {
      var reads = 0;
      for (final source in [
        'song.flac',
        'Music/song.flac',
        r'D:Music\song.flac',
        r'\Music\song.flac',
        'network://share/song.flac',
        'https://example.test/song.flac',
        'ftp://example.test/song.flac',
      ]) {
        expect(
          await resolveEmbeddedArtworkUri(
            source,
            null,
            extract: (_) async {
              reads++;
              return null;
            },
          ),
          isNull,
        );
      }
      expect(reads, 0);
    },
  );

  test('restored raw Windows covers are checked before URI schemes', () async {
    final replacement = File('${directory.path}/replacement.jpg');
    await replacement.writeAsBytes([1]);
    for (final artwork in [
      r'D:\covers\art #1.jpg',
      'D:/covers/art #1.jpg',
      r'\\server\share\art #1.jpg',
    ]) {
      final checked = <String>[];
      var lookups = 0;
      expect(
        await resolveRestoredArtworkUri(
          artwork,
          fileExists: (path) async {
            checked.add(path);
            return true;
          },
          loadLibraryCoverPath: () async {
            lookups++;
            return null;
          },
        ),
        artwork,
      );
      expect(checked, [artwork]);
      expect(lookups, 0);
      checked.clear();
      expect(
        await resolveRestoredArtworkUri(
          artwork,
          fileExists: (path) async {
            checked.add(path);
            return path == replacement.path;
          },
          loadLibraryCoverPath: () async {
            lookups++;
            return replacement.path;
          },
        ),
        replacement.uri.toString(),
      );
      expect(checked, [artwork, replacement.path]);
      expect(lookups, 1);
    }
  });

  test(
    'restored queue replaces a removed scan cover with current Library art',
    () async {
      final removed = File(
        '${directory.path}/old-scan/cover.jpg',
      ).uri.toString();
      final current = File('${directory.path}/current cover #1.jpg');
      await current.writeAsBytes([1]);
      final resolved = await resolveRestoredArtworkUri(
        removed,
        loadLibraryCoverPath: () async => current.path,
      );
      expect(resolved, current.uri.toString());
      expect(File(Uri.parse(resolved!).toFilePath()).existsSync(), isTrue);
    },
  );

  test(
    'valid local and remote covers do not trigger Library lookups',
    () async {
      final current = File('${directory.path}/cover.jpg');
      await current.writeAsBytes([1]);
      for (final artwork in [
        current.path,
        current.uri.toString(),
        'https://example.com/cover.jpg',
      ]) {
        var lookups = 0;
        final resolved = await resolveRestoredArtworkUri(
          artwork,
          loadLibraryCoverPath: () async {
            lookups++;
            return null;
          },
        );
        expect(resolved, artwork);
        expect(lookups, 0);
      }
    },
  );

  test(
    'a missing Library image or lookup failure leaves the session usable',
    () async {
      final missing = File('${directory.path}/missing.jpg').uri.toString();
      expect(
        await resolveRestoredArtworkUri(
          missing,
          loadLibraryCoverPath: () async =>
              '${directory.path}/also-missing.jpg',
        ),
        missing,
      );
      expect(
        await resolveRestoredArtworkUri(
          missing,
          loadLibraryCoverPath: () async =>
              throw StateError('Library unavailable'),
        ),
        missing,
      );
    },
  );
}
