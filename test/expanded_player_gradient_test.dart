import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/widgets/mornye_player_background.dart';

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return x > y ? (x + 0.05) / (y + 0.05) : (y + 0.05) / (x + 0.05);
}

void main() {
  test('expanded gradient keeps light text readable across cover hues', () {
    const subtitle = Color(0xffe6e6eb);
    for (var hue = 0.0; hue < 360; hue += 5) {
      for (final lightness in [0.01, 0.2, 0.5, 0.8, 0.99]) {
        final source = HSLColor.fromAHSL(1, hue, 1, lightness).toColor();
        final colors = expandedPlayerGradient(source).colors;
        expect(colors.first.computeLuminance(), lessThanOrEqualTo(0.12));
        for (var i = 1; i < colors.length; i++) {
          expect(
            colors[i].computeLuminance(),
            lessThan(colors[i - 1].computeLuminance()),
          );
        }
        for (var i = 0; i < colors.length - 1; i++) {
          for (var t = 0.0; t <= 1; t += 0.1) {
            final background = Color.lerp(colors[i], colors[i + 1], t)!;
            expect(_contrast(subtitle, background), greaterThanOrEqualTo(4.5));
            expect(
              _contrast(Colors.white, background),
              greaterThanOrEqualTo(4.5),
            );
          }
        }
      }
    }
  });

  test('missing and near-gray artwork have a neutral fallback', () {
    for (final source in <Color?>[
      null,
      Colors.black,
      Colors.white,
      const Color(0xff7d8085),
    ]) {
      for (final color in expandedPlayerGradient(source).colors) {
        expect(color.r, color.g);
        expect(color.g, color.b);
      }
    }
  });

  testWidgets(
    'expanded background resolves, transitions and respects reduced motion',
    (tester) async {
      tester.view.physicalSize = const Size(640, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync(
        'expanded-surface-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final covers = <Uri>[];
      await tester.runAsync(() async {
        for (final colour in [
          const Color(0xff1876e8),
          const Color(0xffffeb00),
          const Color(0xff100530),
          const Color(0xff808080),
          Colors.transparent,
        ]) {
          final recorder = ui.PictureRecorder();
          Canvas(recorder).drawColor(colour, BlendMode.src);
          final picture = recorder.endRecording();
          final image = await picture.toImage(128, 128);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          picture.dispose();
          final file = File('${directory.path}/${covers.length}.png');
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          covers.add(file.uri);
          // Use the same URI as the widget: Windows File.path may contain mixed
          // separators while URI.toFilePath canonicalizes them to backslashes.
          await CoverPalette.resolveSourceColor(file.uri.toString());
        }
      });
      for (final uri in covers.take(4)) {
        expect(CoverPalette.peekSourceColor(uri.toString()), isNotNull);
      }
      const capture = ValueKey('surface');
      Future<void> show(Uri? uri, {bool reduced = false}) => tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(640, 480),
              disableAnimations: reduced,
            ),
            child: RepaintBoundary(
              key: capture,
              child: MornyePlayerBackground(artUri: uri, expandedSurface: true),
            ),
          ),
        ),
      );
      LinearGradient current() =>
          (tester
                          .widget<DecoratedBox>(
                            find
                                .descendant(
                                  of: find.byType(MornyePlayerBackground),
                                  matching: find.byType(DecoratedBox),
                                )
                                .first,
                          )
                          .decoration
                      as BoxDecoration)
                  .gradient!
              as LinearGradient;
      const names = [
        'blue',
        'yellow',
        'dark',
        'gray',
        'transparent',
        'missing',
      ];
      for (var i = 0; i < names.length; i++) {
        final uri = i < covers.length ? covers[i] : null;
        await show(uri);
        await tester.pump(const Duration(milliseconds: 500));
        expect(
          current(),
          expandedPlayerGradient(
            uri == null ? null : CoverPalette.peekSourceColor(uri.toString()),
          ),
          reason: names[i],
        );
        final output = Platform.environment['MORNYE_CAPTURE_DIR'];
        if (output != null) {
          await tester.runAsync(() async {
            final image = await tester
                .renderObject<RenderRepaintBoundary>(find.byKey(capture))
                .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            await Directory(output).create(recursive: true);
            await File(
              '$output/background-${names[i]}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          });
        }
      }
      await show(covers.first, reduced: true);
      await tester.pump();
      expect(
        current(),
        expandedPlayerGradient(
          CoverPalette.peekSourceColor(covers.first.toString()),
        ),
      );
      await show(covers[1], reduced: true);
      await tester.pump();
      expect(
        current(),
        expandedPlayerGradient(
          CoverPalette.peekSourceColor(covers[1].toString()),
        ),
      );
      // Rapid A -> B -> no-art cannot retain a stale cover tint.
      await show(covers[0]);
      await show(covers[1]);
      await show(null);
      await tester.pump(const Duration(milliseconds: 500));
      expect(current(), expandedPlayerGradient(null));
      expect(tester.takeException(), isNull);
    },
  );
}
