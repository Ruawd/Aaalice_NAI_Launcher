import '../database/app_database_factory.dart';
import '../utils/app_logger.dart';

/// Sqflite 启动初始化服务
///
/// 按平台初始化 SQLite 后端，全局仅执行一次，支持并发安全。
class SqfliteBootstrapService {
  SqfliteBootstrapService._();

  static final SqfliteBootstrapService instance = SqfliteBootstrapService._();

  bool _initialized = false;
  Future<void>? _initFuture;

  Future<void> ensureInitialized() async {
    if (_initialized) {
      return;
    }

    _initFuture ??= _doInitialize();
    await _initFuture;
  }

  Future<void> _doInitialize() async {
    initializeAppDatabaseFactory();
    _initialized = true;
    AppLogger.i('Platform SQLite backend initialized', 'SqfliteBootstrap');
  }
}
