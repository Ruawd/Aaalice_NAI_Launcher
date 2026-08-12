import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nai_launcher/core/storage/floating_button_position_storage.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/router/app_branch.dart';
import 'package:nai_launcher/presentation/router/app_router.dart';

class _MockNavigationShell extends Mock implements StatefulNavigationShell {
  @override
  String toString({DiagnosticLevel minLevel = DiagnosticLevel.info}) =>
      '_MockNavigationShell';
}

class _FakeFloatingButtonPositionStorage extends FloatingButtonPositionStorage {
  @override
  Future<FloatingButtonPositionData> load() async =>
      const FloatingButtonPositionData();

  @override
  Future<void> savePosition(double x, double y) async {}

  @override
  Future<void> saveExpandedState(bool isExpanded) async {}
}

class _FakeLocalStorageService extends LocalStorageService {}

void main() {
  testWidgets('portrait navigation separates galleries and exposes all items', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final navigationShell = _MockNavigationShell();
    when(
      () => navigationShell.currentIndex,
    ).thenReturn(AppBranch.generation.index);
    when(() => navigationShell.goBranch(any())).thenReturn(null);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          floatingButtonPositionStorageProvider.overrideWith(
            (ref) => _FakeFloatingButtonPositionStorage(),
          ),
          localStorageServiceProvider.overrideWith(
            (ref) => _FakeLocalStorageService(),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MobileShell(
            navigationShell: navigationShell,
            content: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();

    final labels = tester
        .widgetList<NavigationDestination>(find.byType(NavigationDestination))
        .map((destination) => destination.label)
        .toList();
    expect(labels, ['生成', '本地画廊', '在线画廊', '词库', '设置', '更多']);

    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('mobile-all-destinations')),
      findsOneWidget,
    );
    for (final branch in allNavigationBranches) {
      expect(
        find.byKey(ValueKey('mobile-destination-${branch.name}')),
        findsOneWidget,
      );
    }
    expect(find.text('Vibe 库', skipOffstage: false), findsOneWidget);
    expect(find.text('精准参考库', skipOffstage: false), findsOneWidget);
    expect(find.text('随机配置', skipOffstage: false), findsOneWidget);
    expect(find.text('统计仪表盘', skipOffstage: false), findsOneWidget);
    expect(find.text('Discord 社群', skipOffstage: false), findsOneWidget);
    expect(find.text('GitHub 仓库', skipOffstage: false), findsOneWidget);

    final vibeTile = find.byKey(
      const ValueKey('mobile-destination-vibeLibrary'),
    );
    await tester.ensureVisible(vibeTile);
    await tester.tap(vibeTile);
    await tester.pumpAndSettle();
    verify(
      () => navigationShell.goBranch(AppBranch.vibeLibrary.index),
    ).called(1);
    expect(tester.takeException(), isNull);
  });
}
