import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/widgets/common/image_detail/components/detail_top_bar.dart';
import 'package:nai_launcher/presentation/widgets/common/image_detail/image_detail_data.dart';

void main() {
  testWidgets('shows an explicit save-to-Photos action for image details', (
    tester,
  ) async {
    var saveCalls = 0;
    final image = GeneratedImageDetailData(
      imageBytes: Uint8List.fromList([1, 2, 3]),
      showSaveButton: false,
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            body: DetailTopBar(
              currentIndex: 0,
              totalImages: 1,
              currentImage: image,
              onClose: () {},
              onSaveToPhotos: () => saveCalls++,
            ),
          ),
        ),
      ),
    );

    final action = find.byKey(const ValueKey('detail-save-to-photos'));
    expect(action, findsOneWidget);
    expect(find.byTooltip('保存到相册'), findsOneWidget);

    await tester.tap(action);
    expect(saveCalls, 1);
  });
}
