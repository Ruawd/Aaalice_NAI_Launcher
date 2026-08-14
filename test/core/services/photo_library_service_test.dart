import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nai_launcher/core/services/photo_library_service.dart';

void main() {
  test('requests access and preserves original bytes when saving', () async {
    final gateway = _FakePhotoLibraryGateway(
      hasAccessResult: false,
      requestAccessResult: true,
    );
    final service = PhotoLibraryService(gateway: gateway);
    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    await service.saveImageBytes(
      bytes,
      fileName: '/tmp/My generated image.png',
    );

    expect(gateway.requestAccessCalls, 1);
    expect(gateway.savedBytes, same(bytes));
    expect(gateway.savedName, 'My_generated_image');
  });

  test('does not request access again when it is already granted', () async {
    final gateway = _FakePhotoLibraryGateway(
      hasAccessResult: true,
      requestAccessResult: false,
    );
    final service = PhotoLibraryService(gateway: gateway);

    await service.saveImageBytes(
      Uint8List.fromList([9]),
      fileName: 'ready.jpg',
    );

    expect(gateway.requestAccessCalls, 0);
    expect(gateway.savedName, 'ready');
  });

  test('reports a denied add-only photo permission', () async {
    final gateway = _FakePhotoLibraryGateway(
      hasAccessResult: false,
      requestAccessResult: false,
    );
    final service = PhotoLibraryService(gateway: gateway);

    await expectLater(
      service.saveImageBytes(Uint8List.fromList([1])),
      throwsA(
        isA<PhotoLibrarySaveException>().having(
          (error) => error.type,
          'type',
          PhotoLibraryFailureType.accessDenied,
        ),
      ),
    );
    expect(gateway.savedBytes, isNull);
  });

  test('rejects unsupported platforms before requesting permission', () async {
    final gateway = _FakePhotoLibraryGateway(
      isSupported: false,
      hasAccessResult: true,
      requestAccessResult: true,
    );
    final service = PhotoLibraryService(gateway: gateway);

    await expectLater(
      service.saveImageBytes(Uint8List.fromList([1])),
      throwsA(
        isA<PhotoLibrarySaveException>().having(
          (error) => error.type,
          'type',
          PhotoLibraryFailureType.unsupportedPlatform,
        ),
      ),
    );
    expect(gateway.hasAccessCalls, 0);
  });

  test('maps native PhotoKit failures to user-facing failure types', () async {
    final gateway = _FakePhotoLibraryGateway(
      hasAccessResult: true,
      requestAccessResult: true,
      saveError: PlatformException(code: 'NOT_ENOUGH_SPACE'),
    );
    final service = PhotoLibraryService(gateway: gateway);

    await expectLater(
      service.saveImageBytes(Uint8List.fromList([1])),
      throwsA(
        isA<PhotoLibrarySaveException>().having(
          (error) => error.type,
          'type',
          PhotoLibraryFailureType.notEnoughSpace,
        ),
      ),
    );
  });
}

class _FakePhotoLibraryGateway implements PhotoLibraryGateway {
  _FakePhotoLibraryGateway({
    this.isSupported = true,
    required this.hasAccessResult,
    required this.requestAccessResult,
    this.saveError,
  });

  @override
  final bool isSupported;
  final bool hasAccessResult;
  final bool requestAccessResult;
  final Object? saveError;

  int hasAccessCalls = 0;
  int requestAccessCalls = 0;
  Uint8List? savedBytes;
  String? savedName;

  @override
  Future<bool> hasAccess() async {
    hasAccessCalls++;
    return hasAccessResult;
  }

  @override
  Future<bool> requestAccess() async {
    requestAccessCalls++;
    return requestAccessResult;
  }

  @override
  Future<void> putImageBytes(Uint8List bytes, {required String name}) async {
    if (saveError != null) throw saveError!;
    savedBytes = bytes;
    savedName = name;
  }
}
