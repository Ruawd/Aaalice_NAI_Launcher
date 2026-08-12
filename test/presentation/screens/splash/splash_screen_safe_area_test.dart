import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/providers/warmup_provider.dart';
import 'package:nai_launcher/presentation/screens/splash/splash_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:nai_launcher/core/constants/app_version.dart';

class _FakeWarmupNotifier extends WarmupNotifier {
  @override
  WarmupState build() => WarmupState.initial();
}

void main() {
  setUpAll(() async {
    PackageInfo.setMockInitialValues(
      appName: 'NAI Launcher',
      packageName: 'nai_launcher',
      version: '1.5.0',
      buildNumber: '34',
      buildSignature: '',
    );
    await AppVersion.initialize();
  });

  testWidgets('keeps splash content inside phone safe areas', (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          warmupNotifierProvider.overrideWith(_FakeWarmupNotifier.new),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SplashScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(tester.getTopLeft(find.text('NAI Launcher')).dy, greaterThan(47));
    expect(
      tester.getBottomRight(find.text('1.5.0')).dy,
      lessThanOrEqualTo(852 - 34),
    );
  });
}
