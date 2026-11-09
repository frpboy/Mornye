import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/sqlite_helpers.dart' as sqlite;
import 'package:mornye/utils/desktop_platform.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show databaseFactoryFfi;

void main() {
  test(
    'factory override preserves default selection and mocked desktop transport',
    () {
      final previousFactory = databaseFactoryOrNull;
      final previousOverride = sqlite.debugAppDatabaseFactory;
      final previousDesktop = debugDesktopPlatformOverride;
      addTearDown(() {
        databaseFactory = previousFactory;
        sqlite.debugAppDatabaseFactory = previousOverride;
        debugDesktopPlatformOverride = previousDesktop;
      });

      expect(sqlite.debugAppDatabaseFactory, isNull);
      databaseFactory = databaseFactorySqflitePlugin;
      debugDesktopPlatformOverride = false;
      sqlite.ensureAppDatabaseFactory();
      expect(databaseFactory, same(databaseFactorySqflitePlugin));

      debugDesktopPlatformOverride = true;
      sqlite.ensureAppDatabaseFactory();
      expect(
        databaseFactory,
        same(
          Platform.isMacOS ? databaseFactorySqflitePlugin : databaseFactoryFfi,
        ),
      );

      // The fixture keeps desktop layout while opting into the channel mock.
      sqlite.debugAppDatabaseFactory = databaseFactorySqflitePlugin;
      sqlite.ensureAppDatabaseFactory();
      expect(debugDesktopPlatformOverride, isTrue);
      expect(databaseFactory, same(databaseFactorySqflitePlugin));
      sqlite.ensureAppDatabaseFactory();
      expect(databaseFactory, same(databaseFactorySqflitePlugin));
    },
  );
}
