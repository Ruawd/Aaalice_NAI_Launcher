import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/data/models/gallery/local_image_record.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/screens/image_comparison_screen.dart';

void main() {
  testWidgets('keeps overlay controls inside phone safe areas', (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ImageComparisonScreen(
            images: [
              LocalImageRecord(
                path: 'C:\\tmp\\missing_comparison_1.png',
                size: 1,
                modifiedAt: DateTime(2026),
              ),
              LocalImageRecord(
                path: 'C:\\tmp\\missing_comparison_2.png',
                size: 1,
                modifiedAt: DateTime(2026),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final closeButton = find.byIcon(Icons.close);
    final hint = find.textContaining('缩放');
    expect(tester.getTopLeft(closeButton).dy, greaterThanOrEqualTo(47));
    expect(tester.getBottomRight(hint).dy, lessThanOrEqualTo(852 - 34));
  });
}
