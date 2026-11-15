import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/crash_reporting_service.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
// The production boundary wires these same internal 9.30.1 classes; the
// tests must exercise the real classes, pinned via pubspec.lock.
// ignore: implementation_imports
import 'package:sentry/src/transport/http_transport.dart';
// ignore: implementation_imports
import 'package:sentry/src/transport/rate_limiter.dart';

const _poisonUrl = 'https://api.example.com/track/secret-title';
const _poisonPath = '/storage/emulated/0/Music/rahul/song.flac';
const _poisonName = 'rahul';

void main() {
  group('boundaryCrashEvent', () {
    SentryEvent poisonedEvent() {
      final contexts = Contexts()
        ..device = SentryDevice(
          name: "Rahul's Pixel",
          model: 'Pixel 9',
          manufacturer: 'Google',
          arch: 'arm64',
          brand: 'google',
          simulator: false,
          batteryLevel: 61,
          freeMemory: 12345,
        )
        ..operatingSystem = SentryOperatingSystem(
          name: 'Android',
          version: '16',
          kernelVersion: 'linux-$_poisonName',
        )
        ..app = SentryApp(
          name: 'Mornye',
          version: '5.3.0',
          build: '166',
          identifier: 'com.zarz.mornye',
          viewNames: ['/library/$_poisonName'],
        )
        ..culture = SentryCulture(locale: 'en-US', timezone: 'Asia/Kolkata')
        ..trace = SentryTraceContext(
          traceId: SentryId.newId(),
          spanId: SpanId.newId(),
          operation: 'test',
        );
      contexts.runtimes = [
        SentryRuntime(key: 'dart', name: 'Dart', version: '3.10.4'),
      ];
      return SentryEvent(
        user: SentryUser(id: '42', email: '$_poisonName@example.com'),
        request: SentryRequest(url: _poisonUrl),
        message: SentryMessage('failed to load $_poisonUrl'),
        transaction: '/player/$_poisonName',
        serverName: 'rahul-laptop',
        tags: {'screen': _poisonName},
        fingerprint: ['custom', _poisonName],
        modules: {'sentry': '9.30.1'},
        exceptions: [
          SentryException(
            type: 'FileSystemException',
            value: 'Cannot open $_poisonPath',
            mechanism: Mechanism(
              type: 'generic',
              handled: true,
              description: 'thrown at $_poisonPath',
              helpLink: _poisonUrl,
            ),
            stackTrace: SentryStackTrace(
              frames: [
                SentryStackFrame(
                  absPath: '/data/user/0/com.example.app/lib/main.dart',
                  fileName: 'package:mornye/main.dart',
                  function: '_main',
                  package: 'mornye',
                  module: 'mornye',
                  lineNo: 42,
                  colNo: 9,
                  contextLine: 'openFile("$_poisonPath")',
                  vars: {'path': _poisonPath},
                  rawFunction: 'raw:$_poisonName',
                  inApp: true,
                ),
                SentryStackFrame(
                  absPath: '/home/rahul/x.dart',
                  fileName: 'file:///home/rahul/lib/secret.dart',
                  function: 'load $_poisonName',
                  lineNo: 7,
                ),
              ],
            ),
          ),
        ],
        threads: [SentryThread(id: 1, name: 'isolate-$_poisonName')],
        breadcrumbs: [
          Breadcrumb(message: 'opened $_poisonUrl', data: {'u': _poisonUrl}),
        ],
        contexts: contexts,
        // ignore: deprecated_member_use
        extra: {'path': _poisonPath},
      );
    }

    test('drops every user/environment carrier by construction', () {
      final event = boundaryCrashEvent(poisonedEvent());
      expect(event.user, isNull);
      expect(event.request, isNull);
      expect(event.message, isNull);
      expect(event.breadcrumbs, isNull);
      expect(event.tags, isNull);
      expect(event.fingerprint, isNull);
      expect(event.transaction, isNull);
      expect(event.serverName, isNull);
      expect(event.threads, isNull);
      expect(event.modules, isNull);
      expect(event.debugMeta, isNull);
      // ignore: deprecated_member_use
      expect(event.extra, isNull);
    });

    test('uses only fixed metadata and no source contexts', () {
      final event = boundaryCrashEvent(poisonedEvent());
      expect(event.logger, 'mornye.crash');
      expect(event.platform, 'dart');
      expect(event.contexts.toJson(), isEmpty);
      expect(event.sdk?.name, 'mornye.crash');
      expect(event.level, SentryLevel.error);
    });

    test('replaces exception, mechanism and frames entirely', () {
      final event = boundaryCrashEvent(poisonedEvent());
      final exception = event.exceptions!.cast<SentryException>().single;
      expect(exception.type, 'Error');
      expect(exception.value, 'Application error');
      expect(exception.mechanism, isNull);
      expect(exception.stackTrace, isNull);
    });

    test('does not trust token-shaped types or forged build metadata', () {
      final source = SentryEvent(
        sdk: SdkVersion(name: _poisonName, version: _poisonName),
        release: _poisonName,
        dist: _poisonName,
        platform: _poisonName,
        environment: _poisonName,
        exceptions: [SentryException(type: _poisonName, value: null)],
      );
      final event = boundaryCrashEvent(source);
      expect(jsonEncode(event.toJson()), isNot(contains(_poisonName)));
      expect(event.eventId, isNot(source.eventId));
    });

    test('serialized JSON carries no poison anywhere', () {
      final json = jsonEncode(boundaryCrashEvent(poisonedEvent()).toJson());
      for (final poison in [_poisonUrl, _poisonPath, _poisonName]) {
        expect(json, isNot(contains(poison)));
      }
      expect(json, isNot(contains('secret.dart')));
      expect(json, isNot(contains('kernelVersion')));
    });
  });

  group('BoundaryTransport', () {
    final sdk = SdkVersion(name: 'test', version: '0.0.0');

    BoundaryTransport recorderTransport(
      Transport inner, {
      int maxEventsPerMinute = 10,
      Duration sendDeadline = const Duration(seconds: 30),
    }) {
      final options = SentryOptions();
      return BoundaryTransport(
        inner,
        RateLimiter(options),
        options.clock,
        maxEventsPerMinute: maxEventsPerMinute,
        sendDeadline: sendDeadline,
      );
    }

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

    test('drops attachment items, keeps only the event', () async {
      final seen = <String>[];
      final transport = recorderTransport(_RecordingTransport(seen));
      await transport.send(mixedEnvelope());
      expect(seen, ['event']);
    });

    test('reconstructs raw event bytes and forged envelope headers', () async {
      final recorded = <SentryEnvelope>[];
      final transport = recorderTransport(_EnvelopeRecorder(recorded));
      final forged = SentryEnvelope.fromEvent(
        SentryEvent(
          release: _poisonName,
          message: SentryMessage(_poisonUrl),
          exceptions: [SentryException(type: _poisonName, value: _poisonPath)],
        ),
        SdkVersion(name: _poisonName, version: _poisonName),
        dsn: _poisonUrl,
      );
      await transport.send(forged);
      final clean = recorded.single;
      expect(clean.header.dsn, isNull);
      expect(clean.header.traceContext, isNull);
      expect(clean.header.sdkVersion?.name, 'mornye.crash');
      expect(clean.header.eventId, isNot(forged.header.eventId));
      final bytes = await clean
          .envelopeStream(SentryOptions())
          .expand((b) => b)
          .toList();
      final body = utf8.decode(bytes);
      for (final poison in [_poisonName, _poisonPath, _poisonUrl]) {
        expect(body, isNot(contains(poison)));
      }
      expect(body, contains('Application error'));
    });

    test('honours 429 backoff recorded by the inner HTTP transport', () async {
      final sink = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var requests = 0;
      final serverSub = sink.listen((request) async {
        requests++;
        await request.drain<void>();
        request.response.statusCode = 429;
        request.response.headers.set('retry-after', '60');
        await request.response.close();
      });
      addTearDown(() async {
        await serverSub.cancel();
        await sink.close();
      });

      final options = SentryOptions(
        dsn: 'http://public@localhost:${sink.port}/1',
      );
      final rateLimiter = RateLimiter(options);
      final transport = BoundaryTransport(
        HttpTransport(options, rateLimiter),
        rateLimiter,
        options.clock,
      );
      final envelope = SentryEnvelope.fromEvent(SentryEvent(), sdk);

      await transport.send(envelope);
      expect(requests, 1);
      // The 429 with Retry-After suppresses further error sends locally:
      // no second HTTP request may leave until the window elapses.
      final id = await transport.send(envelope);
      expect(id, SentryId.empty());
      expect(requests, 1);
    });

    test('drops events beyond the local per-minute cap', () async {
      final seen = <SentryEnvelope>[];
      final transport = recorderTransport(
        _EnvelopeRecorder(seen),
        maxEventsPerMinute: 3,
      );
      final envelope = SentryEnvelope.fromEvent(SentryEvent(), sdk);
      for (var i = 0; i < 5; i++) {
        await transport.send(envelope);
      }
      expect(seen.length, 3);
    });

    test('serializes concurrent sends', () async {
      final slow = _SlowTransport(const Duration(milliseconds: 20));
      final transport = recorderTransport(slow);
      final envelope = SentryEnvelope.fromEvent(SentryEvent(), sdk);
      await Future.wait([for (var i = 0; i < 4; i++) transport.send(envelope)]);
      expect(slow.completed, 4);
      expect(slow.maxInFlight, 1);
    });

    test(
      'abandons a stuck send after the deadline and keeps the chain',
      () async {
        final transport = recorderTransport(
          _NeverTransport(),
          sendDeadline: const Duration(milliseconds: 100),
        );
        final envelope = SentryEnvelope.fromEvent(SentryEvent(), sdk);
        final id = await transport.send(envelope);
        expect(id, SentryId.empty());
        // The chain must still settle the next send instead of wedging.
        await transport.send(envelope).timeout(const Duration(seconds: 5));
      },
    );

    test('returns empty id when nothing may leave', () async {
      final seen = <String>[];
      final transport = recorderTransport(_RecordingTransport(seen));
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

  group('envelope proof (live SDK 9.30.1 against local sink)', () {
    test(
      'adversarial all-carrier event emits only the fixed generic shape',
      () async {
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

        await initCrashReporting(
          dsnOverride: 'http://public@localhost:${sink.port}/1',
          forceEnable: true,
        );

        // Poison every carrier the SDK offers: scope user, tags, custom
        // context, breadcrumb, attachment, fingerprint, transaction.
        await Sentry.configureScope((scope) async {
          await scope.setUser(SentryUser(id: _poisonName));
          await scope.setTag('poison', _poisonName);
          scope.transaction = '/player/$_poisonName';
          scope.fingerprint = [_poisonName];
          scope.setContexts('evil', {'note': _poisonPath});
          await scope.addBreadcrumb(Breadcrumb(message: 'visited $_poisonUrl'));
          scope.addAttachment(
            SentryAttachment.fromUint8List(
              Uint8List.fromList(utf8.encode(_poisonPath)),
              'evil.txt',
            ),
          );
        });

        final probe = StateError(
          'probe ${DateTime.now().microsecondsSinceEpoch} '
          '$_poisonUrl $_poisonPath $_poisonName',
        );
        await Sentry.captureException(probe, stackTrace: StackTrace.current);
        await Sentry.close();

        await arrived.future.timeout(const Duration(seconds: 20));
        expect(captured, isNotEmpty);
        final body = captured.join('\n');

        // Negative proof over the actual emitted envelope bytes.
        for (final poison in [
          _poisonUrl,
          _poisonPath,
          _poisonName,
          'evil',
          'log.txt',
        ]) {
          expect(body, isNot(contains(poison)), reason: 'leaked: $poison');
        }
        expect(body, isNot(contains('"attachment"')));
        expect(body, isNot(contains('"session"')));
        expect(body, isNot(contains('"replay')));
        expect(body, isNot(contains('client_report')));

        // Positive proof: only the fixed generic error marker arrives.
        expect(body, contains('Application error'));
        expect(body, isNot(contains('StateError')));

        // Structural proof: only allowlisted context keys in the event.
        final eventLine = body
            .split('\n')
            .firstWhere((line) => line.contains('"exception"'));
        final json = jsonDecode(eventLine) as Map<String, dynamic>;
        expect(json['contexts'], isNull);
        expect(json.keys.toSet(), {
          'event_id',
          'timestamp',
          'sdk',
          'platform',
          'logger',
          'release',
          'dist',
          'environment',
          'level',
          'exception',
        });
        expect(json['exception'], {
          'values': [
            {'type': 'Error', 'value': 'Application error'},
          ],
        });
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
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

class _EnvelopeRecorder implements Transport {
  _EnvelopeRecorder(this.seen);
  final List<SentryEnvelope> seen;
  @override
  Future<SentryId?> send(SentryEnvelope envelope) async {
    seen.add(envelope);
    return envelope.header.eventId;
  }
}

class _SlowTransport implements Transport {
  _SlowTransport(this.delay);
  final Duration delay;
  int inFlight = 0;
  int maxInFlight = 0;
  int completed = 0;

  @override
  Future<SentryId?> send(SentryEnvelope envelope) async {
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await Future<void>.delayed(delay);
      completed++;
      return envelope.header.eventId;
    } finally {
      inFlight--;
    }
  }
}

class _NeverTransport implements Transport {
  @override
  Future<SentryId?> send(SentryEnvelope envelope) =>
      Completer<SentryId?>().future;
}
