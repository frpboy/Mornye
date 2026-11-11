import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/system_volume_provider.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_inspector.dart';
import 'package:mornye/widgets/desktop/desktop_now_playing.dart';
import 'package:mornye/widgets/mornye_player_background.dart';

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
  await CoverPalette.resolveSourceColor(file.path);
  return file.uri;
}

void main() {
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
      final tracks = StreamController<MediaItem?>();
      addTearDown(tracks.close);
      const boundary = ValueKey('expanded-player-capture');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
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
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
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
        final gradientWidget = tester
            .widget<TweenAnimationBuilder<LinearGradient>>(
              find.descendant(
                of: find.byType(MornyePlayerBackground),
                matching: find.byType(TweenAnimationBuilder<LinearGradient>),
              ),
            );
        final expected = expandedPlayerGradient(
          index < covers.length
              ? CoverPalette.peekSourceColor(covers[index].toString())
              : null,
        );
        expect(gradientWidget.tween.end, expected, reason: names[index]);
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
