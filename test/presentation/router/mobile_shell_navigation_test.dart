import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nai_launcher/core/storage/floating_button_position_storage.dart';
import 'package:nai_launcher/core/storage/local_storage_service.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/providers/account_manager_provider.dart';
import 'package:nai_launcher/presentation/providers/auth_provider.dart';
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

class _FakeAuthNotifier extends AuthNotifier {
  @override
  AuthState build() => const AuthState(status: AuthStatus.unauthenticated);
}

class _FakeAccountManagerNotifier extends AccountManagerNotifier {
  @override
  AccountManagerState build() => const AccountManagerState();
}

void main() {
  testWidgets('keeps landscape shell controls outside notches', (tester) async {
    tester.view.physicalSize = const Size(1200, 700);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(left: 47, right: 47);
    addTearDown(tester.view.reset);

    final navigationShell = _navigationShell();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          floatingButtonPositionStorageProvider.overrideWith(
            (ref) => _FakeFloatingButtonPositionStorage(),
          ),
          localStorageServiceProvider.overrideWith(
            (ref) => _FakeLocalStorageService(),
          ),
          authNotifierProvider.overrideWith(_FakeAuthNotifier.new),
          accountManagerNotifierProvider.overrideWith(
            _FakeAccountManagerNotifier.new,
          ),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: DesktopShell(
            navigationShell: navigationShell,
            content: const Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                key: ValueKey('landscape-page-control'),
                width: 48,
                height: 48,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester
          .getTopLeft(find.byKey(const ValueKey('landscape-page-control')))
          .dx,
      greaterThanOrEqualTo(47),
    );
    expect(
      tester
          .getBottomRight(find.byKey(const ValueKey('landscape-page-control')))
          .dx,
      lessThanOrEqualTo(1200 - 47),
    );
  });

  testWidgets('keeps page controls below the phone status bar', (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.reset);

    final navigationShell = _navigationShell();

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
            content: const Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                key: ValueKey('page-top-control'),
                width: 48,
                height: 48,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.getTopLeft(find.byKey(const ValueKey('page-top-control'))).dy,
      47,
    );
    expect(
      find.byKey(const ValueKey('mobile-shell-safe-area')),
      findsOneWidget,
    );
  });

  testWidgets('portrait navigation separates galleries and exposes all items', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final navigationShell = _navigationShell();

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

_MockNavigationShell _navigationShell() {
  final navigationShell = _MockNavigationShell();
  when(
    () => navigationShell.currentIndex,
  ).thenReturn(AppBranch.generation.index);
  when(() => navigationShell.goBranch(any())).thenReturn(null);
  return navigationShell;
}
