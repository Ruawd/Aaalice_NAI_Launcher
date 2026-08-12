import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:nai_launcher/core/constants/storage_keys.dart';
import 'package:nai_launcher/data/models/tag_library/tag_library_entry.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/providers/tag_library_page_provider.dart';
import 'package:nai_launcher/presentation/screens/tag_library_page/tag_library_page_screen.dart';
import 'package:nai_launcher/presentation/screens/tag_library_page/widgets/entry_add_dialog.dart';
import 'package:nai_launcher/presentation/widgets/tag_library/tag_library_picker_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveTempDir;
  final flutterErrors = <FlutterErrorDetails>[];
  void Function(FlutterErrorDetails details)? previousOnError;

  setUpAll(() async {
    hiveTempDir = await Directory.systemTemp.createTemp(
      'nai_launcher_tag_library_mobile_',
    );
    Hive.init(hiveTempDir.path);
    await Hive.openBox(StorageKeys.settingsBox);
  });

  tearDownAll(() async {
    await Hive.close();
    if (await hiveTempDir.exists()) {
      await hiveTempDir.delete(recursive: true);
    }
  });

  setUp(() async {
    flutterErrors.clear();
    previousOnError = FlutterError.onError;
    FlutterError.onError = flutterErrors.add;
    await Hive.box(StorageKeys.settingsBox).clear();
  });

  tearDown(() {
    FlutterError.onError = previousOnError;
  });

  Widget buildTestApp(Widget child) {
    return ProviderScope(
      overrides: [
        tagLibraryPageNotifierProvider.overrideWith(
          _MobileTagLibraryNotifier.new,
        ),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  void usePhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  void expectNoOverflow() {
    expect(
      flutterErrors.where(
        (details) => details.exceptionAsString().contains('overflowed by'),
      ),
      isEmpty,
    );
  }

  testWidgets('添加条目弹窗在手机上使用单栏且字段保持正常宽度', (tester) async {
    usePhoneViewport(tester);

    await tester.pumpWidget(
      buildTestApp(
        const EntryAddDialog(categories: [], initialContent: '1girl, solo'),
      ),
    );
    await tester.pumpAndSettle();

    final fields = tester.widgetList<EditableText>(find.byType(EditableText));
    expect(fields.length, greaterThanOrEqualTo(3));
    for (final field in find.byType(EditableText).evaluate()) {
      expect(field.size!.width, greaterThan(250));
    }
    expectNoOverflow();
  });

  testWidgets('词库预览弹窗在手机上将筛选项纵向排列并显示双列卡片', (tester) async {
    usePhoneViewport(tester);

    await tester.pumpWidget(buildTestApp(const TagLibraryPickerDialog()));
    await tester.pumpAndSettle();

    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 2);
    expect(find.text('搜索词条...'), findsOneWidget);
    expect(find.text('全部分类'), findsOneWidget);
    expectNoOverflow();
  });

  testWidgets('完整词库页在手机上隐藏固定侧栏并从分类按钮打开底部面板', (tester) async {
    usePhoneViewport(tester);

    await tester.pumpWidget(buildTestApp(const TagLibraryPageScreen()));
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsOneWidget);
    final categoryButton = find.byKey(
      const Key('tag-library-mobile-categories'),
    );
    expect(categoryButton, findsOneWidget);
    expect(find.text('分类'), findsNothing);

    await tester.tap(categoryButton);
    await tester.pumpAndSettle();

    expect(find.text('分类'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);
    expectNoOverflow();
  });
}

class _MobileTagLibraryNotifier extends TagLibraryPageNotifier {
  @override
  TagLibraryPageState build() => TagLibraryPageState(
    entries: [
      TagLibraryEntry(
        id: 'entry-1',
        name: '测试条目一',
        content: '1girl, solo',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
      TagLibraryEntry(
        id: 'entry-2',
        name: '测试条目二',
        content: 'blue eyes, long hair',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    ],
  );
}
