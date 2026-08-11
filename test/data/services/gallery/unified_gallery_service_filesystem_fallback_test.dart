import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

import 'package:nai_launcher/core/constants/storage_keys.dart';
import 'package:nai_launcher/core/database/datasources/gallery_data_source.dart';
import 'package:nai_launcher/core/utils/app_logger.dart';
import 'package:nai_launcher/data/services/gallery/gallery_filter_service.dart';
import 'package:nai_launcher/data/services/gallery/unified_gallery_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory galleryRoot;
  late LocalGalleryServiceImpl service;

  setUpAll(() async {
    await AppLogger.initialize(isTestEnvironment: true);
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'nai_launcher_gallery_filesystem_fallback_',
    );
    galleryRoot = await Directory(p.join(tempDir.path, 'gallery')).create();
    Hive.init(p.join(tempDir.path, 'hive'));
    await Hive.openBox(StorageKeys.settingsBox);
    await Hive.box(
      StorageKeys.settingsBox,
    ).put(StorageKeys.imageSavePath, galleryRoot.path);

    final dataSource = GalleryDataSource();
    expect(dataSource.isInitialized, isFalse);
    service = LocalGalleryServiceImpl(
      dataSource: dataSource,
      filterService: GalleryFilterService(dataSource),
    );
  });

  tearDown(() async {
    await service.dispose();
    await Hive.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
    'shows readable files before the SQLite metadata index is ready',
    () async {
      final file = File(p.join(galleryRoot.path, 'ios-generated.jpg'));
      await file.writeAsBytes(const [0xff, 0xd8, 0xff, 0xd9]);

      final discovered = await service.initialize();
      final page = await service.getPage(0).timeout(const Duration(seconds: 1));

      expect(discovered.map((item) => item.path), [file.path]);
      expect(page, hasLength(1));
      expect(page.single.path, file.path);
      expect(page.single.size, 4);
    },
  );
}
