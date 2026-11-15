import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/crash_reporting_service.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

void main() {
  group('scrubSentryEvent', () {
    SentryEvent buildEvent() {
      final contexts = Contexts()..device = SentryDevice(name: "Rahul's Pixel");
      return SentryEvent(
        user: SentryUser(id: '42', email: 'rahul@example.com'),
        request: SentryRequest(url: 'https://api.example.com/private'),
        message: SentryMessage(
          'failed to load https://api.example.com/x?id=secret',
        ),
        exceptions: [
          SentryException(
            type: 'FileSystemException',
            value: 'Cannot open /storage/emulated/0/Music/song.flac',
            stackTrace: SentryStackTrace(
              frames: [
                SentryStackFrame(
                  absPath: '/data/user/0/com.example.app/lib/main.dart',
                  fileName: 'package:mornye/main.dart',
                  function: 'main',
                  lineNo: 42,
                  vars: {'path': '/home/rahul/Music'},
                ),
              ],
            ),
          ),
        ],
        breadcrumbs: [
          Breadcrumb(
            message: 'opened https://api.example.com/track/123',
            data: {'url': 'https://api.example.com/track/123'},
          ),
        ],
        contexts: contexts,
        // ignore: deprecated_member_use
        extra: {'path': '/home/rahul/Music'},
      );
    }

    test('removes all optional free text and identity', () {
      final event = scrubSentryEvent(buildEvent());
      expect(event.user, isNull);
      expect(event.request, isNull);
      expect(event.message, isNull);
      expect(event.breadcrumbs, isNull);
      // ignore: deprecated_member_use
      expect(event.extra, isEmpty);
      expect(event.contexts.device?.name, isNull);
    });

    test('keeps only exception type and code-provenance frames', () {
      final event = scrubSentryEvent(buildEvent());
      final exception = event.exceptions!.cast<SentryException>().first;
      expect(exception.type, 'FileSystemException');
      expect(exception.value, isNull);
      final frame = exception.stackTrace!.frames.cast<SentryStackFrame>().first;
      expect(frame.fileName, 'package:mornye/main.dart');
      expect(frame.function, 'main');
      expect(frame.lineNo, 42);
      expect(frame.absPath, isNull);
      expect(frame.vars, isEmpty);
      final json = frame.toJson().toString();
      expect(json, isNot(contains('rahul')));
      expect(json, isNot(contains('abs_path')));
    });

    test('serializes to JSON without any path, URL or title', () {
      final event = scrubSentryEvent(buildEvent());
      final json = jsonEncode(event.toJson());
      expect(json, isNot(contains('api.example.com')));
      expect(json, isNot(contains('/storage/emulated/0')));
      expect(json, isNot(contains('rahul')));
      expect(json, isNot(contains('song.flac')));
    });
  });

  group('BoundaryTransport', () {
    final sdk = SdkVersion(name: 'test', version: '0.0.0');

    SentryEnvelope mixedEnvelope() => SentryEnvelope.fromEvent(
      SentryEvent(),
      sdk,
      attachments: [
        SentryAttachment.fromUint8List(
          Uint8List.fromList(utf8.encode('secret bytes')),
          'log.txt',
        ),
      ],
    );

    test('drops attachment items, keeps the event', () async {
      final seen = <String>[];
      final transport = BoundaryTransport(_RecordingTransport(seen));
      await transport.send(mixedEnvelope());
      expect(seen, ['event']);
    });

    test('returns empty id when nothing may leave', () async {
      final seen = <String>[];
      final transport = BoundaryTransport(_RecordingTransport(seen));
      final base = mixedEnvelope();
      final attachmentsOnly = SentryEnvelope(
        base.header,
        base.items
            .cast<SentryEnvelopeItem>()
            .where((item) => item.header.type == 'attachment')
            .toList(),
      );
      final id = await transport.send(attachmentsOnly);
      expect(id, SentryId.empty());
      expect(seen, isEmpty);
    });
  });

  group('envelope proof (live SDK against local sink)', () {
    test('real transport emits only scrubbed event envelopes', () async {
      final sink = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final captured = <String>[];
      final arrived = Completer<void>();
      final serverSub = sink.listen((request) async {
        var bytes = <int>[];
        await for (final chunk in request) {
          bytes.addAll(chunk);
        }
        if (request.headers.value('content-encoding') == 'gzip') {
          bytes = gzip.decode(bytes);
        }
        captured.add(utf8.decode(bytes));
        request.response.statusCode = 200;
        await request.response.close();
        if (!arrived.isCompleted) arrived.complete();
      });
      addTearDown(() async {
        await serverSub.cancel();
        await sink.close();
      });

      final dsn = 'http://public@localhost:${sink.port}/1';
      await initCrashReporting(dsnOverride: dsn, forceEnable: true);

      final probe = StateError(
        'probe ${DateTime.now().microsecondsSinceEpoch} '
        'https://api.example.com/track/secret-title '
        '/storage/emulated/0/Music/rahul/song.flac',
      );
      await Sentry.captureException(probe, stackTrace: StackTrace.current);
      await Sentry.close();

      await arrived.future.timeout(const Duration(seconds: 20));
      expect(captured, isNotEmpty);
      final body = captured.join('\n');
      // Negative proof: no URL, no local path, no personal string, no
      // free-text exception value, no attachment/session/replay items.
      expect(body, isNot(contains('api.example.com')));
      expect(body, isNot(contains('secret-title')));
      expect(body, isNot(contains('/storage/emulated/0')));
      expect(body, isNot(contains('rahul')));
      expect(body, isNot(contains('"attachment"')));
      expect(body, isNot(contains('"session"')));
      expect(body, isNot(contains('"replay')));
      // Positive proof: the generic error still arrives.
      expect(body, contains('StateError'));
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}

class _RecordingTransport implements Transport {
  _RecordingTransport(this.seen);
  final List<String> seen;

  @override
  Future<SentryId?> send(SentryEnvelope envelope) async {
    for (final item in envelope.items.cast<SentryEnvelopeItem>()) {
      seen.add(item.header.type);
    }
    return SentryId.newId();
  }
}
