import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const syntheticEvidenceNames = {
  'keyboard-material-macOS.png',
  'keyboard-material-windows.png',
  'keyboard-mornye-macOS.png',
  'keyboard-mornye-windows.png',
  'band-160x320.png',
  'reference-160x320.png',
  'difference-160x320.png',
  'difference-160x320.json',
};

bool get syntheticEvidenceEnabled =>
    Platform.environment['MORNYE_SYNTHETIC_EVIDENCE_DIR']?.isNotEmpty == true;

Future<void> _save(String name, List<int> bytes) async {
  if (!syntheticEvidenceNames.contains(name) || bytes.length > 1024 * 1024) {
    throw StateError('Synthetic evidence name or size rejected');
  }
  final runner = Directory(Platform.environment['RUNNER_TEMP']!);
  if (await runner.resolveSymbolicLinks() != runner.absolute.path) {
    throw StateError('Synthetic runner path rejected');
  }
  final expected = '${runner.path}/mornye-synthetic-evidence';
  if (Platform.environment['MORNYE_SYNTHETIC_EVIDENCE_DIR'] != expected) {
    throw StateError('Synthetic evidence directory rejected');
  }
  final directory = Directory(expected);
  if (await FileSystemEntity.type(expected, followLinks: false) ==
      FileSystemEntityType.link) {
    throw StateError('Synthetic evidence symlink rejected');
  }
  await directory.create();
  if (await directory.resolveSymbolicLinks() != directory.absolute.path) {
    throw StateError('Synthetic evidence path rejected');
  }
  final file = File('${directory.path}/$name');
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw StateError('Synthetic evidence destination already exists');
  }
  await file.writeAsBytes(bytes, flush: true);
}

// Defer capture errors until teardown so existing assertions still run.
Future<void> _captureSafely(
  WidgetTester tester,
  Future<void> Function() capture,
) async {
  try {
    await tester.runAsync(capture);
  } catch (_) {
    addTearDown(() => fail('Synthetic visual capture failed'));
  }
}

Future<void> captureSyntheticKeyboard(
  WidgetTester tester,
  Finder boundary,
  String name,
) async {
  if (!syntheticEvidenceEnabled) return;
  await _captureSafely(tester, () async {
    final image = await tester
        .renderObject<RenderRepaintBoundary>(boundary)
        .toImage();
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await _save(name, png!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

Future<void> captureSyntheticBand(
  WidgetTester tester,
  Uint8List band,
  Uint8List reference,
) async {
  if (!syntheticEvidenceEnabled) return;
  await _captureSafely(tester, () async {
    if (band.length != 160 * 320 * 4 || reference.length != band.length) {
      throw StateError('Synthetic diagnostic dimensions rejected');
    }
    Future<void> png(String name, Uint8List rgba) async {
      final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: 160,
        height: 320,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      try {
        final data = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        await _save(name, data!.buffer.asUint8List());
      } finally {
        frame.image.dispose();
        codec.dispose();
        descriptor.dispose();
        buffer.dispose();
      }
    }

    final difference = Uint8List(band.length);
    final positions = <Map<String, int>>[];
    var aboveOne = 0;
    var maximum = 0;
    for (var i = 0; i < band.length; i++) {
      final delta = (band[i] - reference[i]).abs();
      if (delta > maximum) maximum = delta;
      difference[i] = i % 4 == 3 ? 255 : (delta * 64).clamp(0, 255);
      if (delta > 1) {
        aboveOne++;
        if (positions.length < 128) {
          positions.add({
            'x': (i ~/ 4) % 160,
            'y': (i ~/ 4) ~/ 160,
            'channel': i % 4,
            'band': band[i],
            'reference': reference[i],
            'difference': delta,
          });
        }
      }
    }
    await png('band-160x320.png', band);
    await png('reference-160x320.png', reference);
    await png('difference-160x320.png', difference);
    await _save(
      'difference-160x320.json',
      utf8.encode(
        jsonEncode({
          'width': 160,
          'height': 320,
          'maximum_channel_difference': maximum,
          'channels_above_one': aboveOne,
          'first_128_positions': positions,
          'difference_png_rgb_scale': 64,
        }),
      ),
    );
  });
}
