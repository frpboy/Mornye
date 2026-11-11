import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/desktop/desktop_now_playing.dart';
import 'package:mornye/widgets/mornye_player_background.dart';
import 'package:mornye/widgets/cached_cover_image.dart';

import 'support/fixed_settings.dart';

// Keep favourite state and collection lookups synthetic. The real player
// widget still renders, but never opens the user's library/history database.
class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

Future<Uri> _cover(Directory directory, String name, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawColor(color, BlendMode.src);
  final picture = recorder.endRecording();
  final image = await picture.toImage(128, 128);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  final file = File('${directory.path}/$name.png');
  await file.writeAsBytes(bytes!.buffer.asUint8List());
  // Use the same URI as the widget: Windows File.path may contain mixed
  // separators while URI.toFilePath canonicalizes them to backslashes.
  await CoverPalette.resolveSourceColor(file.uri.toString());
  return file.uri;
}

void main() {
  setUpAll(() async {
    for (final (family, asset) in [
      ('Inter', 'assets/fonts/InterVariable.ttf'),
      ('MaterialIcons', 'fonts/MaterialIcons-Regular.otf'),
      (
        'packages/cupertino_icons/CupertinoIcons',
        'packages/cupertino_icons/assets/CupertinoIcons.ttf',
      ),
    ]) {
      await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
    }
  });
  testWidgets(
    'expanded desktop player follows artwork with readable secondary controls',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      debugDesktopPlatformOverride = true;
      desktopInspectorPanel.value = null;
      addTearDown(() {
        debugDesktopPlatformOverride = null;
        desktopInspectorPanel.value = null;
      });
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync(
        'expanded-colours-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final covers = (await tester.runAsync(
        () => Future.wait([
          _cover(directory, 'blue', const Color(0xff1876e8)),
          _cover(directory, 'yellow', const Color(0xffffeb00)),
          _cover(directory, 'dark', const Color(0xff100530)),
          _cover(directory, 'gray', const Color(0xff808080)),
          _cover(directory, 'transparent', Colors.transparent),
        ]),
      ))!;
      for (final uri in covers.take(4)) {
        expect(CoverPalette.peekSourceColor(uri.toString()), isNotNull);
      }
      final tracks = StreamController<MediaItem?>();
      addTearDown(tracks.close);
      const boundary = ValueKey('expanded-player-capture');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(FixedSettingsNotifier.new),
            libraryCollectionsProvider.overrideWith(_Collections.new),
            playerCollectionTrackProvider.overrideWith(
              (ref, item) async => Track(
                id: item.id,
                name: item.title,
                artistName: item.artist ?? '',
                albumName: item.album ?? '',
                duration: item.duration?.inSeconds ?? 0,
                source: 'local',
              ),
            ),
            currentMediaItemProvider.overrideWithBuild(
              (ref, notifier) => tracks.stream,
            ),
            playbackStateProvider.overrideWith(
              (ref) => Stream.value(
                PlaybackState(
                  processingState: AudioProcessingState.ready,
                  updatePosition: const Duration(seconds: 72),
                ),
              ),
            ),
            playQueueProvider.overrideWith((ref) => Stream.value(const [])),
            systemVolumeProvider.overrideWith((ref) => Stream.value(0.5)),
          ],
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: RepaintBoundary(
                key: boundary,
                child: DesktopNowPlaying(
                  metadataControllerFactory: () =>
                      PlayerMetadataController(readMetadata: (_) async => {}),
                ),
              ),
            ),
          ),
        ),
      );
      final names = [
        'blue',
        'yellow',
        'dark',
        'gray',
        'transparent',
        'missing',
      ];
      for (var index = 0; index < names.length; index++) {
        if (index < covers.length) {
          // At 1280x900 the real desktop column's max decode width is520
          // (min(520, height-340)). Prewarm BEFORE mounting FileImage: a load
          // started on the fake clock cannot complete inside runAsync.
          final provider = coverImageProvider(
            covers[index].toString(),
            cacheWidth: 520,
          )!;
          final imageContext = tester.element(find.byKey(boundary));
          await tester.runAsync(
            () => precacheImage(
              provider,
              imageContext,
            ).timeout(const Duration(seconds: 15)),
          );
        }
        tracks.add(
          MediaItem(
            id: names[index],
            title: 'Cover colours',
            artist: 'Synthetic test artwork',
            album: 'Expanded player preview',
            duration: const Duration(minutes: 4),
            artUri: index < covers.length ? covers[index] : null,
            extras: const {'source': '/music/synthetic.flac'},
          ),
        );
        await tester.pump();
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 5),
        );
        if (index < covers.length) {
          final decoded = tester.widget<RawImage>(find.byType(RawImage));
          expect(
            decoded.image,
            isNotNull,
            reason: 'Synthetic cover ${names[index]} must be decoded',
          );
        }
        final background = tester.widget<MornyePlayerBackground>(
          find.byType(MornyePlayerBackground),
        );
        expect(background.expandedSurface, isTrue);
        expect(
          Theme.of(
            tester.element(find.text('Cover colours')),
          ).colorScheme.onSurfaceVariant,
          const Color(0xffe6e6eb),
        );
        final expected = expandedPlayerGradient(
          index < covers.length
              ? CoverPalette.peekSourceColor(covers[index].toString())
              : null,
        );
        final paintedBackground = tester.widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(MornyePlayerBackground),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect(
          (paintedBackground.decoration as BoxDecoration).gradient,
          expected,
          reason: 'The settled painted gradient must match ${names[index]}',
        );
        expect(tester.takeException(), isNull, reason: names[index]);
        final capturePath = Platform.environment['MORNYE_CAPTURE_DIR'];
        if (capturePath != null) {
          await tester.runAsync(() async {
            final image = await tester
                .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
                .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            await Directory(capturePath).create(recursive: true);
            await File(
              '$capturePath/expanded-${names[index]}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          });
        }
      }
      // The opt-in does not change the default shared surface used elsewhere.
      expect(
        const MornyePlayerBackground(artUri: null).expandedSurface,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
