import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/data/models/gallery/local_image_record.dart';
import 'package:nai_launcher/data/models/gallery/nai_image_metadata.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/widgets/gallery/gallery_grid.dart';
import 'package:nai_launcher/presentation/widgets/gallery/local_image_card_3d.dart';
import 'package:visibility_detector/visibility_detector.dart';

void main() {
  testWidgets('local gallery cards preserve each source image aspect ratio', (
    tester,
  ) async {
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
    addTearDown(
      () => VisibilityDetectorController.instance.updateInterval =
          const Duration(milliseconds: 500),
    );

    final portrait = LocalImageRecord(
      path: '/missing/portrait.png',
      size: 42,
      modifiedAt: DateTime(2026, 8, 12),
      metadata: const NaiImageMetadata(width: 600, height: 1200),
    );
    final landscape = LocalImageRecord(
      path: '/missing/landscape.png',
      size: 42,
      modifiedAt: DateTime(2026, 8, 12),
      metadata: const NaiImageMetadata(width: 1200, height: 600),
    );

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 800,
              child: GalleryGrid(
                images: [portrait, landscape],
                columns: 2,
                spacing: 12,
                padding: const EdgeInsets.all(16),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final cards = tester
        .widgetList<LocalImageCard3D>(find.byType(LocalImageCard3D))
        .toList();
    expect(cards, hasLength(2));

    const itemWidth = (400 - 32 - 12) / 2;
    expect(cards[0].width, closeTo(itemWidth, 0.001));
    expect(cards[0].height, closeTo(itemWidth / 0.5, 0.001));
    expect(cards[1].width, closeTo(itemWidth, 0.001));
    expect(cards[1].height, closeTo(itemWidth / 2, 0.001));
    expect(cards[0].height, isNot(equals(cards[1].height)));
  });
}
