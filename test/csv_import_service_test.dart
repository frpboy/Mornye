import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/csv_import_service.dart';

void main() {
  test(
    'cancelled enrichment returns the full list, partially enriched',
    () async {
      final tracks = List.generate(
        4,
        (i) => Track(
          id: 'csv_$i',
          name: 'Song $i',
          artistName: 'Artist',
          albumName: '',
          duration: 0,
        ),
      );
      var completed = 0;

      final enriched = await CsvImportService.enrichTracksMetadata(
        tracks,
        concurrency: 1,
        isCancelled: () => completed >= 2,
        onProgress: (current, total) => completed = current,
        lookup: (query, limit) async {
          return [
            {
              'id': 'js-1',
              'provider_id': 'jiosaavn',
              'name': query.replaceFirst('Artist ', ''),
              'artists': 'Artist',
              'album_name': 'Album',
              'duration_ms': 180000,
              'isrc': 'INH102300001',
            },
          ];
        },
      );

      expect(enriched.length, 4);
      expect(enriched[0].duration, 180);
      expect(enriched[1].duration, 180);
      expect(enriched[2].duration, 0);
      expect(enriched[2].id, 'csv_2');
      expect(enriched[3].duration, 0);
      expect(enriched[3].id, 'csv_3');
    },
  );

  test(
    'enrichment keeps the bare track when a provider lookup hangs',
    () async {
      const track = Track(
        id: 'csv_1',
        name: 'Song',
        artistName: 'Artist',
        albumName: '',
        duration: 0,
      );

      final enriched = await CsvImportService.enrichTracksMetadata(
        [track],
        lookupTimeout: const Duration(milliseconds: 50),
        lookup: (query, limit) =>
            Completer<List<Map<String, dynamic>>>().future,
      );

      expect(enriched.single.id, 'csv_1');
      expect(enriched.single.duration, 0);
    },
  );

  test(
    'playlist enrichment uses generic lookup with bounded concurrency',
    () async {
      var active = 0;
      var maxActive = 0;
      final progress = <int>[];
      final tracks = List.generate(
        5,
        (index) => Track(
          id: 'original-$index',
          name: 'Song $index',
          artistName: 'Artist',
          albumName: '',
          isrc: 'TEST0000000$index',
          duration: 0,
        ),
      );

      final enriched = await CsvImportService.enrichTracksMetadata(
        tracks,
        concurrency: 2,
        onProgress: (current, _) => progress.add(current),
        lookup: (query, limit) async {
          active++;
          if (active > maxActive) maxActive = active;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          active--;
          final index = int.parse(query.substring(query.length - 1));
          return [
            {
              'id': 'provider-$index',
              'provider_id': 'generic-provider',
              'name': 'Song $index',
              'artists': 'Artist',
              'album_name': 'Album',
              'cover_url': 'https://example.test/$index.jpg',
              'duration_ms': 180000,
              'isrc': query,
            },
          ];
        },
      );

      expect(maxActive, 2);
      expect(progress, [1, 2, 3, 4, 5]);
      expect(
        enriched.map((track) => track.id),
        tracks.map((track) => track.id),
      );
      expect(enriched.every((track) => track.duration == 180), isTrue);
      expect(enriched[3].coverUrl, 'https://example.test/3.jpg');
    },
  );

  test('ISRC enrichment rejects a provider mismatch', () async {
    const track = Track(
      id: 'original',
      name: 'Wanted Song',
      artistName: 'Wanted Artist',
      albumName: '',
      isrc: 'AAABC1200001',
      duration: 0,
    );
    var calls = 0;

    final enriched = await CsvImportService.enrichTracksMetadata(
      const [track],
      lookup: (query, limit) async {
        calls++;
        if (calls == 1) {
          return [
            {
              'id': 'wrong',
              'name': 'Other Song',
              'artists': 'Other Artist',
              'isrc': 'ZZZZZ9900000',
              'duration_ms': 100000,
            },
          ];
        }
        return [
          {
            'id': 'right',
            'name': 'Wanted Song',
            'artists': 'Wanted Artist',
            'cover_url': 'https://example.test/right.jpg',
            'duration_ms': 210000,
          },
        ];
      },
    );

    expect(calls, 2);
    expect(enriched.single.id, 'original');
    expect(enriched.single.duration, 210);
    expect(enriched.single.coverUrl, 'https://example.test/right.jpg');
  });
}
