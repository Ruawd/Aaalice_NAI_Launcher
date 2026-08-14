import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

enum PhotoLibraryFailureType {
  unsupportedPlatform,
  accessDenied,
  notEnoughSpace,
  unsupportedFormat,
  unexpected,
}

class PhotoLibrarySaveException implements Exception {
  const PhotoLibrarySaveException(this.type, {this.cause});

  final PhotoLibraryFailureType type;
  final Object? cause;

  @override
  String toString() => cause == null
      ? 'PhotoLibrarySaveException(${type.name})'
      : 'PhotoLibrarySaveException(${type.name}, $cause)';
}

abstract interface class PhotoLibraryGateway {
  bool get isSupported;

  Future<bool> hasAccess();

  Future<bool> requestAccess();

  Future<void> putImageBytes(Uint8List bytes, {required String name});
}

class IosPhotoLibraryGateway implements PhotoLibraryGateway {
  const IosPhotoLibraryGateway();

  static const MethodChannel _channel = MethodChannel(
    'com.nailauncher/photo_library',
  );

  @override
  bool get isSupported => !kIsWeb && Platform.isIOS;

  @override
  Future<bool> hasAccess() async =>
      await _channel.invokeMethod<bool>('hasAccess') ?? false;

  @override
  Future<bool> requestAccess() async =>
      await _channel.invokeMethod<bool>('requestAccess') ?? false;

  @override
  Future<void> putImageBytes(Uint8List bytes, {required String name}) =>
      _channel.invokeMethod<void>('saveImage', {'bytes': bytes, 'name': name});
}

/// Writes original image bytes to the iOS system photo library.
///
/// This is intentionally separate from the app's local gallery. The local
/// gallery keeps NovelAI files in the configured app folder, while this
/// service creates a byte-preserving asset visible in Apple Photos.
class PhotoLibraryService {
  PhotoLibraryService({PhotoLibraryGateway? gateway})
    : _gateway = gateway ?? const IosPhotoLibraryGateway();

  static final PhotoLibraryService instance = PhotoLibraryService();

  final PhotoLibraryGateway _gateway;

  bool get isSupported => _gateway.isSupported;

  Future<void> saveImageBytes(Uint8List bytes, {String? fileName}) async {
    if (!_gateway.isSupported) {
      throw const PhotoLibrarySaveException(
        PhotoLibraryFailureType.unsupportedPlatform,
      );
    }
    if (bytes.isEmpty) {
      throw const PhotoLibrarySaveException(
        PhotoLibraryFailureType.unsupportedFormat,
      );
    }

    try {
      var granted = await _gateway.hasAccess();
      if (!granted) {
        granted = await _gateway.requestAccess();
      }
      if (!granted) {
        throw const PhotoLibrarySaveException(
          PhotoLibraryFailureType.accessDenied,
        );
      }

      await _gateway.putImageBytes(bytes, name: _safeAssetName(fileName));
    } on PhotoLibrarySaveException {
      rethrow;
    } on PlatformException catch (error) {
      throw PhotoLibrarySaveException(
        _mapPlatformFailure(error.code),
        cause: error,
      );
    } catch (error) {
      throw PhotoLibrarySaveException(
        PhotoLibraryFailureType.unexpected,
        cause: error,
      );
    }
  }

  String _safeAssetName(String? fileName) {
    final rawStem = fileName == null || fileName.trim().isEmpty
        ? ''
        : p.basenameWithoutExtension(fileName.trim());
    var stem = rawStem
        .replaceAll(RegExp(r'[^A-Za-z0-9._\-\u3400-\u9FFF]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (stem.isEmpty) {
      stem = 'nai_${DateTime.now().millisecondsSinceEpoch}';
    }
    if (stem.length > 120) {
      stem = stem.substring(0, 120);
    }
    return stem;
  }

  PhotoLibraryFailureType _mapPlatformFailure(String code) {
    return switch (code) {
      'ACCESS_DENIED' => PhotoLibraryFailureType.accessDenied,
      'NOT_ENOUGH_SPACE' => PhotoLibraryFailureType.notEnoughSpace,
      'NOT_SUPPORTED_FORMAT' => PhotoLibraryFailureType.unsupportedFormat,
      _ => PhotoLibraryFailureType.unexpected,
    };
  }
}
