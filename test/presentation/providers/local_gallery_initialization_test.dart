import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:nai_launcher/core/exceptions/gallery_exceptions.dart';
import 'package:nai_launcher/data/models/gallery/local_image_record.dart';
import 'package:nai_launcher/data/services/gallery/unified_gallery_service.dart';
import 'package:nai_launcher/presentation/providers/local_gallery_provider.dart';

void main() {
  testWidgets('waits for gallery readiness beyond the old 10 second limit', (
    tester,
  ) async {
    final pendingService = _MockLocalGalleryService();
    final readyService = _MockLocalGalleryService();
    final readyCompleter = Completer<LocalGalleryService>();
    when(() => pendingService.isInitialized).thenReturn(false);
    when(() => readyService.isInitialized).thenReturn(true);

    final galleryServiceNotifier = _ControlledGalleryServiceNotifier(
      initialState: pendingService,
      readyFuture: readyCompleter.future,
    );
    final container = ProviderContainer(
      overrides: [
        galleryServiceProvider.overrideWith(() => galleryServiceNotifier),
      ],
    );
    addTearDown(container.dispose);

    var completed = false;
    final serviceFuture = container
        .read(localGalleryNotifierProvider.notifier)
        .getService();
    unawaited(serviceFuture.then((_) => completed = true));

    for (var i = 0; i < 105; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(completed, isFalse);

    readyCompleter.complete(readyService);
    await tester.pump();

    expect(await serviceFuture, same(readyService));
  });

  test(
    'propagates the real initialization exception from the service',
    () async {
      final pendingService = _MockLocalGalleryService();
      final readyCompleter = Completer<LocalGalleryService>();
      when(() => pendingService.isInitialized).thenReturn(false);

      final container = ProviderContainer(
        overrides: [
          galleryServiceProvider.overrideWith(
            () => _ControlledGalleryServiceNotifier(
              initialState: pendingService,
              readyFuture: readyCompleter.future,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      const error = GalleryScanException(message: 'slow storage failed');
      final expectation = expectLater(
        container.read(localGalleryNotifierProvider.notifier).getService(),
        throwsA(same(error)),
      );
      readyCompleter.completeError(error);

      await expectation;
    },
  );

  test(
    'retry creates a fresh service and recovers from initialization error',
    () async {
      final readyService = _MockLocalGalleryService();
      when(() => readyService.isInitialized).thenReturn(true);
      when(() => readyService.totalCount).thenReturn(0);
      when(() => readyService.filteredCount).thenReturn(0);
      when(
        () => readyService.getPage(any(), pageSize: any(named: 'pageSize')),
      ).thenAnswer((_) async => <LocalImageRecord>[]);

      const failedService = ErrorGalleryService(error: 'database unavailable');
      final galleryServiceNotifier = _ControlledGalleryServiceNotifier(
        initialState: failedService,
        readyFuture: Future.value(failedService),
        onReinitialize: () async => readyService,
      );
      final container = ProviderContainer(
        overrides: [
          galleryServiceProvider.overrideWith(() => galleryServiceNotifier),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(localGalleryNotifierProvider.notifier)
          .retryInitialization();

      final state = container.read(localGalleryNotifierProvider);
      expect(galleryServiceNotifier.reinitializeCount, 1);
      expect(state.isInitialized, isTrue);
      expect(state.error, isNull);
      expect(state.isLoading, isFalse);
    },
  );
}

class _MockLocalGalleryService extends Mock implements LocalGalleryService {}

class _ControlledGalleryServiceNotifier extends GalleryService {
  _ControlledGalleryServiceNotifier({
    required this.initialState,
    required Future<LocalGalleryService> readyFuture,
    this.onReinitialize,
  }) : _readyFuture = readyFuture;

  final LocalGalleryService initialState;
  final Future<LocalGalleryService> Function()? onReinitialize;
  Future<LocalGalleryService> _readyFuture;
  int reinitializeCount = 0;

  @override
  LocalGalleryService build() => initialState;

  @override
  Future<LocalGalleryService> get ready => _readyFuture;

  @override
  Future<LocalGalleryService> reinitialize() async {
    reinitializeCount++;
    final service = await onReinitialize!.call();
    _readyFuture = Future.value(service);
    state = service;
    return service;
  }
}
