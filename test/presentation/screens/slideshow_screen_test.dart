import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/data/models/gallery/local_image_record.dart';
import 'package:nai_launcher/l10n/app_localizations.dart';
import 'package:nai_launcher/presentation/screens/slideshow_screen.dart';

void main() {
  test('slideshow image provider caps decode size', () {
    final provider = buildSlideshowImageProvider('C:\\tmp\\slide.png');

    expect(provider, isA<ResizeImage>());
    final resized = provider as ResizeImage;
    expect(resized.width, 4096);
    expect(resized.height, 4096);
    expect(resized.policy, ResizeImagePolicy.fit);
  });

  testWidgets('dispose does not call setState', (tester) async {
    await tester.pumpWidget(
      _wrap(
        SlideshowScreen(
          images: [
            LocalImageRecord(
              path: 'C:\\tmp\\missing_slide.png',
              size: 1,
              modifiedAt: DateTime(2026),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps full-screen controls inside phone safe areas', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _wrap(
        SlideshowScreen(
          images: [
            LocalImageRecord(
              path: 'C:\\tmp\\missing_slide.png',
              size: 1,
              modifiedAt: DateTime(2026),
            ),
          ],
        ),
      ),
    );
    await tester.pump();

    final closeButton = find.byIcon(Icons.close);
    final playButton = find.byIcon(Icons.play_arrow);
    expect(tester.getTopLeft(closeButton).dy, greaterThanOrEqualTo(47));
    expect(tester.getBottomRight(playButton).dy, lessThanOrEqualTo(852 - 34));
  });
}

Widget _wrap(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}
