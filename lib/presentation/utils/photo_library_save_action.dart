import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/services/photo_library_service.dart';
import '../../core/utils/localization_extension.dart';
import '../widgets/common/app_toast.dart';

bool get canSaveToSystemPhotoLibrary =>
    PhotoLibraryService.instance.isSupported;

Future<bool> saveImageToSystemPhotoLibrary(
  BuildContext context, {
  required Future<Uint8List> Function() loadBytes,
  String? fileName,
  PhotoLibraryService? service,
}) async {
  final targetService = service ?? PhotoLibraryService.instance;
  final l10n = context.l10n;

  try {
    final bytes = await loadBytes();
    await targetService.saveImageBytes(bytes, fileName: fileName);
    if (context.mounted) {
      AppToast.success(context, l10n.image_savedToPhotos);
    }
    return true;
  } on PhotoLibrarySaveException catch (error) {
    if (!context.mounted) return false;
    final message = switch (error.type) {
      PhotoLibraryFailureType.unsupportedPlatform =>
        l10n.image_photoLibraryUnsupportedPlatform,
      PhotoLibraryFailureType.accessDenied =>
        l10n.image_photoLibraryPermissionDenied,
      PhotoLibraryFailureType.notEnoughSpace =>
        l10n.image_photoLibraryNotEnoughSpace,
      PhotoLibraryFailureType.unsupportedFormat =>
        l10n.image_photoLibraryUnsupportedFormat,
      PhotoLibraryFailureType.unexpected => l10n.image_saveToPhotosFailed(
        error.cause?.toString() ?? '',
      ),
    };
    if (error.type == PhotoLibraryFailureType.accessDenied) {
      AppToast.warning(context, message);
    } else {
      AppToast.error(context, message);
    }
    return false;
  } catch (error) {
    if (context.mounted) {
      AppToast.error(context, l10n.image_saveToPhotosFailed(error.toString()));
    }
    return false;
  }
}
