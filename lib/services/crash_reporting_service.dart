import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
// The concrete HTTP transport classes are not exported by the SDK, but the
// boundary transport must wrap the real transport DURING init (before any
// integration can emit), not after. Pinned via pubspec.lock to 9.30.1.
// ignore: implementation_imports
import 'package:sentry/src/transport/http_transport.dart';
// ignore: implementation_imports
import 'package:sentry/src/transport/rate_limiter.dart';

import 'package:mornye/constants/app_info.dart';
import 'package:mornye/utils/logger.dart';

/// Minimal automatic crash reporting for fork builds.
///
/// Boundary contract (do not widen without independent review):
/// - Dart-layer events only. The native SDKs are NOT initialized
///   ([SentryFlutterOptions.autoInitializeNativeSdk] stays false), because
///   native envelopes bypass the Dart [SentryOptions.beforeSend] hook and
///   have not been proven to respect this boundary. Rust-backend native
///   crashes are therefore NOT reported yet. The Android manifest carries
///   no Sentry metadata, so the sentry-android ContentProvider auto-init
///   path has no DSN and stays dark as well.
/// - Every outgoing event is rebuilt as a fixed generic error marker with
///   fresh identity/time, fixed SDK/platform/level and our build constants.
///   No input event field survives. This intentionally sacrifices exception
///   types, stack frames and device/OS details until provenance is qualified.
/// - Final envelope boundary: [BoundaryTransport] is installed inside init,
///   before integrations can emit. It reconstructs BOTH headers and event
///   bytes, dropping attachments, traces, sessions and client reports even
///   when they are added after beforeSend. It pins the pure-Dart HTTP path.
/// - No session replay, screenshots, view hierarchy, performance traces,
///   session tracking or native breadcrumbs.
/// - Release builds only, so development runs cannot spend the shared free
///   error quota (5000 events/month org-wide at the time of writing).
///
/// The DSN is a public client identifier, not a secret; an empty
/// SENTRY_DSN dart-define disables reporting entirely. The pre-existing
/// local AppCrashService is unchanged and remains on-device only.
const String _dsn = String.fromEnvironment(
  'SENTRY_DSN',
  defaultValue:
      'https://d234d78d5c5d7847a17a68c41ac70f11@o4510460282601472.ingest.us.sentry.io/4512436384366592',
);

bool get crashReportingEnabled => kReleaseMode && _dsn.isNotEmpty;

final _log = AppLogger('CrashReporting');

// No source event field is trusted. Code provenance needs a separate,
// reviewed allowlist before it can be added. Even token-shaped strings can
// carry a title, username or path segment.
SdkVersion _boundarySdk() => SdkVersion(name: 'mornye.crash', version: '1.0.0');

/// Creates a generic error marker with fresh identity and timestamp.
/// The source is intentionally ignored, including its SDK/build contexts.
SentryEvent boundaryCrashEvent(SentryEvent source) => _genericCrashEvent();

SentryEvent _genericCrashEvent() => SentryEvent(
  eventId: SentryId.newId(),
  timestamp: DateTime.now().toUtc(),
  sdk: _boundarySdk(),
  platform: 'dart',
  logger: 'mornye.crash',
  release: 'mornye@${AppInfo.version}+${AppInfo.buildNumber}',
  dist: AppInfo.buildNumber,
  environment: 'release',
  level: SentryLevel.error,
  exceptions: [SentryException(type: 'Error', value: 'Application error')],
);

/// Final boundary, installed during init. Original event bytes, envelope
/// headers and item headers are never forwarded. At most one fresh generic
/// marker leaves per envelope containing an event. All other item types
/// (including attachments and client reports) are dropped without reading.
///
/// Reliability bounds (all process-local; nothing here claims exact-once,
/// duplicates are possible):
/// - 429 backoff: the SDK's own client-side rate limiter is null when a
///   custom transport is installed, so [HttpTransport]'s [RateLimiter] is
///   consulted here before every send. A 429 (or X-Sentry-Rate-Limits)
///   response on the error category suppresses further sends until the
///   server-provided retry window elapses.
/// - Local cap: at most [maxEventsPerMinute] error events per rolling
///   minute per process, so a crash loop cannot drain the shared free
///   quota. Excess events are dropped silently.
/// - Concurrency: sends are serialized through one chain; a send waits for
///   the previous one to settle.
/// - Deadline: each send is abandoned after [sendDeadline]; a stuck socket
///   cannot wedge the chain.
class BoundaryTransport implements Transport {
  BoundaryTransport(
    this._inner,
    this._rateLimiter,
    this._clock, {
    this.maxEventsPerMinute = 10,
    this.sendDeadline = const Duration(seconds: 30),
  });

  final Transport _inner;
  final RateLimiter _rateLimiter;
  final DateTime Function() _clock;
  final int maxEventsPerMinute;
  final Duration sendDeadline;

  final List<DateTime> _sentAt = <DateTime>[];
  Future<SentryId?> _chain = Future<SentryId?>.value();

  @override
  Future<SentryId?> send(SentryEnvelope envelope) {
    final result = _chain.then((_) => _sendBounded(envelope));
    // Keep the chain alive after a failure so later sends still run.
    _chain = result.then((id) => id, onError: (_) => SentryId.empty());
    return result;
  }

  Future<SentryId?> _sendBounded(SentryEnvelope envelope) async {
    // Remote backoff: drop when the server rate-limited the error
    // category. The inner HTTP transport records 429/Retry-After
    // responses on this same limiter instance.
    final filtered = _rateLimiter.filter(envelope);
    if (filtered == null ||
        !filtered.items.any((item) => item.header.type == 'event')) {
      return SentryId.empty();
    }
    // Local cap: bounds shared-quota spend during error loops.
    final now = _clock();
    _sentAt.removeWhere(
      (sent) => now.difference(sent) > const Duration(minutes: 1),
    );
    if (_sentAt.length >= maxEventsPerMinute) {
      return SentryId.empty();
    }
    _sentAt.add(now);
    try {
      return await _inner
          .send(SentryEnvelope.fromEvent(_genericCrashEvent(), _boundarySdk()))
          .timeout(sendDeadline, onTimeout: SentryId.empty);
    } catch (_) {
      return SentryId.empty();
    }
  }
}

bool _initialized = false;

/// Initializes the Dart-layer Sentry SDK for release builds. Call after the
/// app's own error handlers are installed: the SDK's default integrations
/// chain onto them and capture each error exactly once. Uncaught zone errors
/// are not covered by those integrations and must call [reportCrashError].
Future<void> initCrashReporting({
  @visibleForTesting String? dsnOverride,
  @visibleForTesting bool forceEnable = false,
}) async {
  final dsn = dsnOverride ?? _dsn;
  final enabled = forceEnable || (kReleaseMode && dsn.isNotEmpty);
  if (!enabled || _initialized) return;

  try {
    await SentryFlutter.init((options) {
      options
        ..dsn = dsn
        ..release = 'mornye@${AppInfo.version}+${AppInfo.buildNumber}'
        ..dist = AppInfo.buildNumber
        ..environment = 'release'
        ..debug = false
        ..sendDefaultPii = false
        ..tracesSampleRate = 0.0
        ..enableAutoSessionTracking = false
        ..attachScreenshot = false
        ..attachViewHierarchy = false
        // The native envelope path does not pass through beforeSend; keep
        // every unqualified capture path off until envelopes are inspected.
        ..autoInitializeNativeSdk = false
        ..enableNativeCrashHandling = false
        ..enableAutoNativeBreadcrumbs = false
        ..enableNdkScopeSync = false
        ..replay.sessionSampleRate = 0.0
        ..replay.onErrorSampleRate = 0.0
        // Installed now, during init, so no integration can emit through an
        // unfiltered transport. Pins the pure-Dart HTTP path. The SAME rate
        // limiter instance is shared: the HTTP transport records 429s on it
        // and the boundary consults it before every send.
        ..transport = _boundaryTransport(options)
        ..beforeSend = _beforeSend
        // Breadcrumbs are optional free text; never record them.
        ..beforeBreadcrumb = (crumb, hint) => null;
    });
    _initialized = true;
  } catch (e) {
    // Reporting must never break startup.
    _log.w('Crash reporting init failed: $e');
  }
}

Transport _boundaryTransport(SentryOptions options) {
  final rateLimiter = RateLimiter(options);
  return BoundaryTransport(
    HttpTransport(options, rateLimiter),
    rateLimiter,
    options.clock,
  );
}

FutureOr<SentryEvent?> _beforeSend(SentryEvent event, Hint hint) =>
    boundaryCrashEvent(event);

/// Reports an uncaught zone error. No-op unless reporting initialized; the
/// SDK's own integrations cover FlutterError and PlatformDispatcher errors,
/// so those handlers must not call this.
void reportCrashError(Object error, StackTrace? stack) {
  if (!_initialized) return;
  unawaited(_capture(error, stack));
}

Future<void> _capture(Object error, StackTrace? stack) async {
  try {
    await Sentry.captureException(error, stackTrace: stack);
  } catch (_) {
    // Reporting must never throw back into the zone handler.
  }
}
