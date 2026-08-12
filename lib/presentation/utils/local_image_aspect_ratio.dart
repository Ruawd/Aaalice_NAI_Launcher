import 'dart:ui' as ui;

import '../../core/utils/app_logger.dart';
import '../../data/models/gallery/local_image_record.dart';

/// Returns the source image's width-to-height ratio without decoding its pixels.
Future<double> readLocalImageAspectRatio(LocalImageRecord record) async {
  final metadata = record.metadata;
  final metadataWidth = metadata?.width;
  final metadataHeight = metadata?.height;
  if (metadataWidth != null &&
      metadataHeight != null &&
      metadataWidth > 0 &&
      metadataHeight > 0) {
    return metadataWidth / metadataHeight;
  }

  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromFilePath(record.path);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    if (descriptor.width > 0 && descriptor.height > 0) {
      return descriptor.width / descriptor.height;
    }
  } catch (error) {
    AppLogger.d(
      'Failed to read gallery image aspect ratio: $error',
      'LocalImageAspectRatio',
    );
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }

  return 1.0;
}
