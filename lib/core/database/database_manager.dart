import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../utils/app_logger.dart';
import 'asset_database_manager.dart';
import 'connection_health_monitor.dart' as health_monitor;
import 'data_source.dart' show HealthStatus;
import 'data_source_types.dart' show HealthCheckResult;
import 'connection_pool_holder.dart';
import 'datasources/cooccurrence_data_source.dart';
import 'datasources/danbooru_tag_data_source.dart';
import 'datasources/gallery_data_source.dart';
import 'datasources/translation_data_source.dart';
import 'metrics/metrics_reporter.dart' as metrics_reporter;

/// 数据库初始化状态
enum DatabaseInitState { uninitialized, initializing, initialized, error }

/// 数据库管理器
class DatabaseManager {
  DatabaseManager._();

  static DatabaseManager? _instance;

  /// 获取单例实例
  static DatabaseManager get instance {
    if (_instance == null) {
      throw StateError(
        'DatabaseManager not initialized. Call initialize() first.',
      );
    }
    return _instance!;
  }

  /// 初始化数据库管理器
  static Future<DatabaseManager> initialize({int maxConnections = 20}) async {
    if (_instance != null) {
      // 检查是否可用
      try {
        final pool = ConnectionPoolHolder.getInstanceOrNull();
        if (pool != null && pool.isInitialized && !pool.isDisposed) {
          await _instance!.ensureGalleryDataSource();
          AppLogger.d('DatabaseManager already initialized', 'DatabaseManager');
          return _instance!;
        }

        // 不可用，需要重置
        AppLogger.i(
          'DatabaseManager exists but ConnectionPool disposed, resetting...',
          'DatabaseManager',
        );
        _instance = null;
      } catch (e) {
        _instance = null;
      }
    }

    AppLogger.i('Initializing DatabaseManager...', 'DatabaseManager');

    _instance = DatabaseManager._();
    await _instance!._doInitialize(maxConnections: maxConnections);

    return _instance!;
  }

  static const String _danbooruDbName = 'danbooru.db';

  DatabaseInitState _state = DatabaseInitState.uninitialized;
  String? _dbPath;
  String? _errorMessage;
  int _configuredMaxConnections = 20;
  Future<GalleryDataSource>? _galleryInitialization;

  // 初始化完成标记
  final _initCompleter = Completer<void>();

  // 数据源
  TranslationDataSource? _translationDataSource;
  CooccurrenceDataSource? _cooccurrenceDataSource;
  DanbooruTagDataSource? _danbooruTagDataSource;
  GalleryDataSource? _galleryDataSource;

  // 健康监控器
  health_monitor.ConnectionHealthMonitor? _healthMonitor;

  // 指标报告器
  metrics_reporter.MetricsReporter? _metricsReporter;

  /// 翻译数据源
  TranslationDataSource get translationDataSource {
    if (_translationDataSource == null) {
      throw StateError('TranslationDataSource not initialized');
    }
    return _translationDataSource!;
  }

  /// 共现数据源
  CooccurrenceDataSource get cooccurrenceDataSource {
    if (_cooccurrenceDataSource == null) {
      throw StateError('CooccurrenceDataSource not initialized');
    }
    return _cooccurrenceDataSource!;
  }

  /// Danbooru 标签数据源
  DanbooruTagDataSource? get danbooruTagDataSource => _danbooruTagDataSource;

  /// 画廊数据源
  GalleryDataSource? get galleryDataSource => _galleryDataSource;

  T? getDataSource<T>(String name) {
    if (T == TranslationDataSource) {
      return _translationDataSource as T?;
    }
    if (T == CooccurrenceDataSource) {
      return _cooccurrenceDataSource as T?;
    }
    if (T == DanbooruTagDataSource) {
      return _danbooruTagDataSource as T?;
    }
    if (T == GalleryDataSource) {
      return _galleryDataSource as T?;
    }
    return null;
  }

  /// 获取初始化状态
  DatabaseInitState get state => _state;

  /// 获取数据库路径
  String? get dbPath => _dbPath;

  /// 获取错误信息
  String? get errorMessage => _errorMessage;

  /// 是否已初始化
  bool get isInitialized => _state == DatabaseInitState.initialized;

  /// 是否有错误
  bool get hasError => _state == DatabaseInitState.error;

  /// 初始化完成Future
  Future<void> get initialized => _initCompleter.future;

  /// 执行初始化
  Future<void> _doInitialize({required int maxConnections}) async {
    _state = DatabaseInitState.initializing;
    _configuredMaxConnections = maxConnections;

    try {
      // 标签目录与共现库是补全功能的可选资产。它们体积较大，且在部分
      // 移动设备上可能安装/校验失败；这不应阻止运行时数据库和本地画廊启动。
      await _initializeOptionalDataSources();

      _dbPath = await _getDatabasePath(_danbooruDbName);
      await _ensureConnectionPool();

      await _registerRuntimeDataSources();
      _startHealthMonitoring();
      _startMetricsReporting();

      _state = DatabaseInitState.initialized;
      _initCompleter.complete();

      AppLogger.i('DatabaseManager initialized', 'DatabaseManager');
    } catch (e, stack) {
      _state = DatabaseInitState.error;
      _errorMessage = e.toString();

      if (!_initCompleter.isCompleted) {
        _initCompleter.completeError(e, stack);
      }

      AppLogger.e(
        'DatabaseManager initialization failed',
        e,
        stack,
        'DatabaseManager',
      );
      rethrow;
    }
  }

  Future<void> _initializeOptionalDataSources() async {
    var assetDatabasesReady = false;
    try {
      await AssetDatabaseManager.initialize();
      assetDatabasesReady = true;
    } catch (e, stack) {
      AppLogger.e(
        'Optional asset databases are unavailable; continuing with runtime database',
        e,
        stack,
        'DatabaseManager',
      );
    }

    _translationDataSource = TranslationDataSource();
    try {
      await _translationDataSource!.initialize();
    } catch (e, stack) {
      AppLogger.e(
        'Optional TranslationDataSource initialization failed',
        e,
        stack,
        'DatabaseManager',
      );
    }

    _cooccurrenceDataSource = CooccurrenceDataSource();
    if (!assetDatabasesReady) {
      AppLogger.w(
        'Skipping CooccurrenceDataSource because asset databases are unavailable',
        'DatabaseManager',
      );
      return;
    }

    try {
      await _cooccurrenceDataSource!.initialize();
    } catch (e, stack) {
      AppLogger.e(
        'Optional CooccurrenceDataSource initialization failed',
        e,
        stack,
        'DatabaseManager',
      );
    }
  }

  Future<void> _ensureConnectionPool() async {
    _dbPath ??= await _getDatabasePath(_danbooruDbName);
    final current = ConnectionPoolHolder.getInstanceOrNull();
    if (current != null && current.isInitialized && !current.isDisposed) {
      return;
    }

    Future<void> openPool(int connections) async {
      final existing = ConnectionPoolHolder.getInstanceOrNull();
      if (existing == null) {
        await ConnectionPoolHolder.initialize(
          dbPath: _dbPath!,
          maxConnections: connections,
        );
      } else {
        await ConnectionPoolHolder.reset(
          dbPath: _dbPath!,
          maxConnections: connections,
        );
      }
    }

    try {
      await openPool(_configuredMaxConnections);
    } catch (e, stack) {
      final canUseSingleConnection =
          (Platform.isAndroid || Platform.isIOS) &&
          _configuredMaxConnections > 1;
      if (!canUseSingleConnection) rethrow;

      AppLogger.e(
        'Mobile connection pool initialization failed; retrying with one connection',
        e,
        stack,
        'DatabaseManager',
      );
      _configuredMaxConnections = 1;
      await ConnectionPoolHolder.reset(
        dbPath: _dbPath!,
        maxConnections: _configuredMaxConnections,
      );
    }
  }

  /// Ensures the runtime database and local-gallery tables are available.
  ///
  /// This can recover a partially initialized manager after an optional bundled
  /// autocomplete database failed during startup.
  Future<GalleryDataSource> ensureGalleryDataSource() {
    final current = _galleryDataSource;
    if (current != null &&
        current.isInitialized &&
        ConnectionPoolHolder.isInitialized) {
      return Future.value(current);
    }

    final active = _galleryInitialization;
    if (active != null) return active;

    final operation = _doEnsureGalleryDataSource();
    _galleryInitialization = operation;
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(_galleryInitialization, operation)) {
            _galleryInitialization = null;
          }
        },
        onError: (Object _, StackTrace __) {
          if (identical(_galleryInitialization, operation)) {
            _galleryInitialization = null;
          }
        },
      ),
    );
    return operation;
  }

  Future<GalleryDataSource> _doEnsureGalleryDataSource() async {
    await _ensureConnectionPool();
    final dataSource = _galleryDataSource ?? GalleryDataSource();
    _galleryDataSource = dataSource;
    if (!dataSource.isInitialized) {
      await dataSource.initialize();
    }
    return dataSource;
  }

  /// 获取数据库路径
  Future<String> _getDatabasePath(String dbName) async {
    final appDir = await getApplicationSupportDirectory();
    final dbDir = Directory(p.join(appDir.path, 'databases'));
    if (!await dbDir.exists()) {
      await dbDir.create(recursive: true);
    }
    return p.join(dbDir.path, dbName);
  }

  /// 获取数据库连接（通过 Holder 获取当前有效实例）
  Future<Database> acquireDatabase() async {
    return await ConnectionPoolHolder.instance.acquire();
  }

  /// 释放数据库连接
  Future<void> releaseDatabase(Database db) async {
    await ConnectionPoolHolder.instance.release(db);
  }

  /// 获取数据库统计信息
  Future<Map<String, dynamic>> getStatistics() async {
    final pool = ConnectionPoolHolder.instance;
    final db = await pool.acquire();

    try {
      // 获取数据库文件大小
      final dbFile = File(_dbPath!);
      final fileSize = await dbFile.exists() ? await dbFile.length() : 0;

      // 获取表统计
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      );

      final tableStats = <String, int>{};
      for (final row in tables) {
        final tableName = row['name'] as String;
        final countResult = await db.rawQuery(
          'SELECT COUNT(*) as count FROM "$tableName"',
        );
        tableStats[tableName] = countResult.first['count'] as int? ?? 0;
      }

      return {
        'dbPath': _dbPath,
        'fileSize': fileSize,
        'tables': tableStats,
        'tableCount': tables.length,
        'connectionPool': {
          'maxConnections': _configuredMaxConnections,
          'available': pool.availableCount,
          'inUse': pool.inUseCount,
        },
      };
    } finally {
      await pool.release(db);
    }
  }

  Future<Map<String, int>> getCoreAssetStatistics() async {
    var translationCount = 0;
    var cooccurrenceCount = 0;
    try {
      translationCount = await _translationDataSource?.getCount() ?? 0;
    } catch (e) {
      AppLogger.w(
        'Unable to read optional translation statistics: $e',
        'DatabaseManager',
      );
    }
    try {
      final source = _cooccurrenceDataSource;
      if (source != null && source.isInitialized) {
        cooccurrenceCount = await source.getCount();
      }
    } catch (e) {
      AppLogger.w(
        'Unable to read optional cooccurrence statistics: $e',
        'DatabaseManager',
      );
    }

    return {
      'translations': translationCount,
      'cooccurrences': cooccurrenceCount,
    };
  }

  Future<void> recover() async {
    try {
      await ConnectionPoolHolder.reset(
        dbPath: _dbPath!,
        maxConnections: _configuredMaxConnections,
      );
      _galleryDataSource = null;
      await ensureGalleryDataSource();
      AppLogger.i('Database recovery completed', 'DatabaseManager');
    } catch (e, stack) {
      AppLogger.e('Database recovery failed', e, stack, 'DatabaseManager');
      throw StateError('Recovery failed: $e');
    }
  }

  /// 快速健康检查
  Future<HealthCheckResult> quickHealthCheck() async {
    try {
      // 检查资产数据库
      final assetHealth = await AssetDatabaseManager.instance
          .checkDatabasesExist();
      if (!assetHealth) {
        return HealthCheckResult(
          status: HealthStatus.corrupted,
          message: 'Asset databases missing',
          timestamp: DateTime.now(),
        );
      }

      // 检查 Danbooru 数据库
      final pool = ConnectionPoolHolder.instance;
      final db = await pool.acquire();

      try {
        final result = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' LIMIT 1",
        );

        return HealthCheckResult(
          status: HealthStatus.healthy,
          message: 'Database is healthy',
          details: {'tableCount': result.length},
          timestamp: DateTime.now(),
        );
      } catch (e) {
        return HealthCheckResult(
          status: HealthStatus.corrupted,
          message: 'Database health check failed: $e',
          timestamp: DateTime.now(),
        );
      } finally {
        await pool.release(db);
      }
    } catch (e) {
      return HealthCheckResult(
        status: HealthStatus.corrupted,
        message: 'Failed to acquire database connection: $e',
        timestamp: DateTime.now(),
      );
    }
  }

  /// 关闭数据库管理器
  Future<void> dispose() async {
    _healthMonitor?.stop();
    _healthMonitor?.dispose();
    _healthMonitor = null;

    _metricsReporter?.stopReporting();
    _metricsReporter = null;

    try {
      await _translationDataSource?.dispose();
    } catch (e) {
      AppLogger.d(
        'Failed to dispose translation data source: $e',
        'DatabaseManager',
      );
    }

    try {
      await _cooccurrenceDataSource?.dispose();
    } catch (e) {
      AppLogger.d(
        'Failed to dispose cooccurrence data source: $e',
        'DatabaseManager',
      );
    }

    try {
      await _danbooruTagDataSource?.dispose();
    } catch (e) {
      AppLogger.d(
        'Failed to dispose Danbooru tag data source: $e',
        'DatabaseManager',
      );
    }

    try {
      await _galleryDataSource?.dispose();
    } catch (e) {
      AppLogger.d(
        'Failed to dispose gallery data source: $e',
        'DatabaseManager',
      );
    }
    _galleryDataSource = null;
    _galleryInitialization = null;

    await ConnectionPoolHolder.dispose();

    _state = DatabaseInitState.uninitialized;
    _instance = null;

    AppLogger.i('DatabaseManager disposed', 'DatabaseManager');
  }

  Future<void> _registerRuntimeDataSources() async {
    _danbooruTagDataSource = DanbooruTagDataSource();
    try {
      await _danbooruTagDataSource!.initialize();
    } catch (e, stack) {
      AppLogger.e(
        'Failed to initialize DanbooruTagDataSource',
        e,
        stack,
        'DatabaseManager',
      );
    }

    try {
      await ensureGalleryDataSource();
    } catch (e, stack) {
      AppLogger.e(
        'Failed to initialize GalleryDataSource',
        e,
        stack,
        'DatabaseManager',
      );
      rethrow;
    }

    await _warmupConnectionPool();
  }

  Future<void> _warmupConnectionPool() async {
    try {
      final result = await ConnectionPoolHolder.warmup(
        connections: _configuredMaxConnections,
        timeout: const Duration(seconds: 5),
      );

      if (result.success) {
        AppLogger.i(
          'Connection pool warmed up: ${result.validatedConnections} connections in ${result.duration.inMilliseconds}ms',
          'DatabaseManager',
        );
      } else {
        AppLogger.w(
          'Connection pool warmup incomplete: ${result.validatedConnections} connections. Error: ${result.error}',
          'DatabaseManager',
        );
      }
    } catch (e, stack) {
      AppLogger.e(
        'Failed to warmup connection pool',
        e,
        stack,
        'DatabaseManager',
      );
    }
  }

  void _startHealthMonitoring() {
    try {
      _healthMonitor = health_monitor.ConnectionHealthMonitor(
        config: health_monitor.HealthCheckConfig(),
        onStatusChange: (oldStatus, newStatus, result) {
          AppLogger.w(
            'Database health changed: $oldStatus -> $newStatus '
                '(latency: ${result.connectionAcquireLatency.inMilliseconds}ms, '
                'failureRate: ${result.failureRate.toStringAsFixed(2)}%)',
            'DatabaseManager',
          );
        },
        onAlert: (alertType, message, result) {
          AppLogger.e(
            'Database health alert [$alertType]: $message',
            null,
            null,
            'DatabaseManager',
          );
        },
      );
      _healthMonitor!.start();
    } catch (e, stack) {
      AppLogger.e(
        'Failed to start health monitoring',
        e,
        stack,
        'DatabaseManager',
      );
    }
  }

  void _startMetricsReporting() {
    try {
      _metricsReporter = metrics_reporter.MetricsReporter();

      const isProduction = bool.fromEnvironment(
        'dart.vm.product',
        defaultValue: false,
      );
      const reportInterval = isProduction
          ? Duration(minutes: 5)
          : Duration(minutes: 10);

      _metricsReporter!.startReporting(interval: reportInterval);
    } catch (e, stack) {
      AppLogger.e(
        'Failed to start metrics reporting',
        e,
        stack,
        'DatabaseManager',
      );
    }
  }
}
