import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:mornye/constants/app_info.dart';
import 'package:mornye/utils/logger.dart';

/// Minimal automatic crash reporting for fork builds.
///
/// Boundary contract (do not widen without envelope-level qualification):
/// - Dart-layer events only. The native SDKs are NOT initialized
///   ([SentryFlutterOptions.autoInitializeNativeSdk] stays false), because
///   native envelopes bypass the Dart [SentryOptions.beforeSend] hook and
///   have not been proven to respect this boundary. Rust-backend native
///   crashes are therefore NOT reported yet.
/// - Fixed generic errors plus trusted minimal metadata only. Exception
///   VALUES, event messages and breadcrumbs are free text that can contain
///   URLs, local music paths or titles, so they never leave the device;
///   regex redaction of free text is not treated as qualification. What
///   leaves: exception TYPE (code), stack frames (package:/dart: locations,
///   code provenance), app version, OS and generic device metadata.
/// - Final envelope validation: [BoundaryTransport] wraps the configured
///   transport and drops every envelope item that is not an error event or
///   a client report, so attachments, transactions, replays, profiles and
///   logs cannot leave even if an option is ever misconfigured or the SDK
///   adds data after beforeSend.
/// - No session replay, no screenshots, no view hierarchy, no performance
///   traces, no session tracking, no native breadcrumbs.
/// - Release builds only, so development runs cannot spend the shared free
///   error quota (5000 events/month org-wide at the time of writing).
///
/// The DSN is a public client identifier, not a secret; an empty
/// SENTRY_DSN dart-define disables reporting entirely.
const String _dsn = String.fromEnvironment(
  'SENTRY_DSN',
  defaultValue:
      'https://d234d78d5c5d7847a17a68c41ac70f11@o4510460282601472.ingest.us.sentry.io/4512436384366592',
);

bool get crashReportingEnabled => kReleaseMode && _dsn.isNotEmpty;

final _log = AppLogger('CrashReporting');

/// Rebuilds one frame with code provenance only: the package:/dart:
/// fileName, function and location. Absolute paths, runtime variable
/// values and build-machine source excerpts are dropped.
SentryStackFrame _cleanFrame(SentryStackFrame frame) => SentryStackFrame(
  fileName: frame.fileName,
  function: frame.function,
  module: frame.module,
  lineNo: frame.lineNo,
  colNo: frame.colNo,
  inApp: frame.inApp,
  package: frame.package,
  platform: frame.platform,
  rawFunction: frame.rawFunction,
);

SentryStackTrace? _cleanStackTrace(SentryStackTrace? stackTrace) =>
    stackTrace == null
    ? null
    : SentryStackTrace(
        frames: stackTrace.frames
            .cast<SentryStackFrame>()
            .map(_cleanFrame)
            .toList(),
      );

/// Event-level boundary applied to every outgoing event. Returns the
/// scrubbed event; exposed for tests.
SentryEvent scrubSentryEvent(SentryEvent event) {
  event
    ..user = null
    ..request = null
    ..message = null
    ..breadcrumbs = null
    // Arbitrary key-value context can hold paths or content metadata; the
    // SDK adds nothing here we need.
    // ignore: deprecated_member_use
    ..extra = {};

  for (final exception
      in event.exceptions?.cast<SentryException>() ??
          const <SentryException>[]) {
    exception
      ..value = null
      ..stackTrace = _cleanStackTrace(exception.stackTrace);
  }

  for (final thread
      in event.threads?.cast<SentryThread>() ?? const <SentryThread>[]) {
    thread.stacktrace = _cleanStackTrace(thread.stacktrace);
  }

  // A device name is often a personal name ("Rahul's Pixel").
  event.contexts.device?.name = null;

  return event;
}

/// Final envelope boundary: only error events and client reports may leave
/// the device. Wraps whatever transport the SDK configured (the concrete
/// HTTP transport classes are not part of the SDK's public API, so this is
/// installed on the options object right after init).
class BoundaryTransport implements Transport {
  BoundaryTransport(this._inner);

  final Transport _inner;

  // SentryItemType is not part of the SDK's public exports; these are its
  // 'event' and 'client_report' constants.
  static const Set<String> _allowedItemTypes = {'event', 'client_report'};

  @override
  Future<SentryId?> send(SentryEnvelope envelope) {
    final items = envelope.items
        .cast<SentryEnvelopeItem>()
        .where((item) => _allowedItemTypes.contains(item.header.type))
        .toList();
    if (items.isEmpty) {
      return Future.value(SentryId.empty());
    }
    return _inner.send(SentryEnvelope(envelope.header, items));
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

  SentryFlutterOptions? configuredOptions;
  try {
    await SentryFlutter.init((options) {
      configuredOptions = options;
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
        ..beforeSend = _beforeSend
        ..beforeBreadcrumb = _beforeBreadcrumb;
    });
    // Install the final envelope boundary on the live transport.
    final installed = configuredOptions;
    if (installed != null) {
      installed.transport = BoundaryTransport(installed.transport);
    }
    _initialized = true;
  } catch (e) {
    // Reporting must never break startup.
    _log.w('Crash reporting init failed: $e');
  }
}

FutureOr<SentryEvent?> _beforeSend(SentryEvent event, Hint hint) =>
    scrubSentryEvent(event);

// Breadcrumbs are optional free text; never record them.
Breadcrumb? _beforeBreadcrumb(Breadcrumb? breadcrumb, Hint hint) => null;

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
