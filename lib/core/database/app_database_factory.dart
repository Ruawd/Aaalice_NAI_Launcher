import 'dart:io';

import 'package:sqflite/sqflite.dart' as native_sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

/// Selects the SQLite backend that is supported by the current platform.
///
/// Desktop builds keep using `sqflite_common_ffi`, while Android and iOS use
/// the native `sqflite` plugin. In particular, the FFI factory is documented
/// for desktop only and must not be used as the primary database backend on
/// iOS.
ffi.DatabaseFactory get appDatabaseFactory {
  if (Platform.isAndroid || Platform.isIOS) {
    return native_sqflite.databaseFactorySqflitePlugin;
  }
  return ffi.databaseFactoryFfi;
}

/// Initializes the process-wide sqflite factory before any database is opened.
void initializeAppDatabaseFactory() {
  if (!(Platform.isAndroid || Platform.isIOS)) {
    ffi.sqfliteFfiInit();
  }

  final selectedFactory = appDatabaseFactory;
  var alreadySelected = false;
  try {
    alreadySelected = identical(ffi.databaseFactory, selectedFactory);
  } on StateError {
    // The global factory has not been initialized yet.
  }
  if (!alreadySelected) {
    ffi.databaseFactory = selectedFactory;
  }
}
