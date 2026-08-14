import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:mocktail/mocktail.dart';
import 'package:nai_launcher/core/network/nai_api_endpoint.dart';
import 'package:nai_launcher/core/network/nai_api_endpoint_service.dart';
import 'package:nai_launcher/data/datasources/remote/nai_image_enhancement_api_service.dart';

class _MockDio extends Mock implements Dio {}

void main() {
  setUpAll(() {
    registerFallbackValue(Options());
  });

  group('NAIImageEnhancementApiService', () {
    test(
      'upscaleImage should send scale alongside source dimensions',
      () async {
        final dio = _MockDio();
        final sourceImage = _buildPng(width: 48, height: 32);
        final zipBytes = _buildZipWithSingleImage(sourceImage);
        Map<String, dynamic>? capturedData;

        when(
          () => dio.post<dynamic>(
            any(),
            data: any(named: 'data'),
            options: any(named: 'options'),
            onReceiveProgress: any(named: 'onReceiveProgress'),
          ),
        ).thenAnswer((invocation) async {
          capturedData = Map<String, dynamic>.from(
            invocation.namedArguments[#data] as Map,
          );
          return Response<dynamic>(
            data: zipBytes,
            requestOptions: RequestOptions(path: '/ai/upscale'),
          );
        });

        final service = NAIImageEnhancementApiService(dio);
        final result = await service.upscaleImage(sourceImage, scale: 2);

        expect(result, isNotEmpty);
        expect(capturedData?['scale'], equals(2));
        expect(capturedData?['width'], equals(48));
        expect(capturedData?['height'], equals(32));
      },
    );

    test('upscaleImage accepts a direct image response', () async {
      final dio = _MockDio();
      final sourceImage = _buildPng(width: 48, height: 32);
      final resultImage = _buildPng(width: 192, height: 128);

      when(
        () => dio.post<dynamic>(
          any(),
          data: any(named: 'data'),
          options: any(named: 'options'),
          onReceiveProgress: any(named: 'onReceiveProgress'),
        ),
      ).thenAnswer(
        (_) async => Response<dynamic>(
          data: resultImage,
          requestOptions: RequestOptions(path: '/ai/upscale'),
        ),
      );

      final service = NAIImageEnhancementApiService(dio);
      final result = await service.upscaleImage(sourceImage);

      expect(result, resultImage);
    });

    test(
      'upscaleImage rejects HTTP 200 JSON instead of saving it as an image',
      () async {
        final dio = _MockDio();
        final sourceImage = _buildPng(width: 48, height: 32);

        when(
          () => dio.post<dynamic>(
            any(),
            data: any(named: 'data'),
            options: any(named: 'options'),
            onReceiveProgress: any(named: 'onReceiveProgress'),
          ),
        ).thenAnswer(
          (_) async => Response<dynamic>(
            data: Uint8List.fromList(utf8.encode('{"error":"File not found"}')),
            requestOptions: RequestOptions(path: '/ai/upscale'),
          ),
        );

        final service = NAIImageEnhancementApiService(dio);

        await expectLater(
          service.upscaleImage(sourceImage),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('File not found'),
            ),
          ),
        );
      },
    );

    test(
      'upscaleImage blocks Sugar Cloud unsupported route before upload',
      () async {
        final dio = _MockDio();
        final endpointService = NaiApiEndpointService()
          ..setCurrent(
            NaiApiEndpointConfig.fromInput(
              mainBaseUrl: 'https://std.loliyc.com/novelai',
              providerType: NaiApiProviderType.shatangyun,
            ),
          );
        final service = NAIImageEnhancementApiService(dio, endpointService);

        await expectLater(
          service.upscaleImage(_buildPng(width: 48, height: 32)),
          throwsA(
            isA<UnsupportedError>().having(
              (error) => error.message,
              'message',
              contains('砂糖云'),
            ),
          ),
        );
        verifyNever(
          () => dio.post<dynamic>(
            any(),
            data: any(named: 'data'),
            options: any(named: 'options'),
            onReceiveProgress: any(named: 'onReceiveProgress'),
          ),
        );
      },
    );

    test(
      'should send source image width and height for director tools',
      () async {
        final dio = _MockDio();
        final sourceImage = _buildPng(width: 48, height: 32);
        final zipBytes = _buildZipWithSingleImage(sourceImage);
        Map<String, dynamic>? capturedData;

        when(
          () => dio.post<dynamic>(
            any(),
            data: any(named: 'data'),
            options: any(named: 'options'),
          ),
        ).thenAnswer((invocation) async {
          capturedData = Map<String, dynamic>.from(
            invocation.namedArguments[#data] as Map,
          );
          return Response<dynamic>(
            data: zipBytes,
            requestOptions: RequestOptions(path: '/augment-image'),
          );
        });

        final service = NAIImageEnhancementApiService(dio);
        final result = await service.removeBackground(sourceImage);

        expect(result, isNotEmpty);
        expect(capturedData?['req_type'], equals('bg-removal'));
        expect(capturedData?['width'], equals(48));
        expect(capturedData?['height'], equals(32));
      },
    );

    test('encodeVibe should send information_extracted to API', () async {
      final dio = _MockDio();
      final sourceImage = _buildPng(width: 32, height: 32);
      Map<String, dynamic>? capturedData;

      when(
        () => dio.post<dynamic>(
          any(),
          data: any(named: 'data'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((invocation) async {
        capturedData = Map<String, dynamic>.from(
          invocation.namedArguments[#data] as Map,
        );
        return Response<dynamic>(
          data: Uint8List.fromList(const [1, 2, 3]),
          requestOptions: RequestOptions(path: '/encode-vibe'),
        );
      });

      final service = NAIImageEnhancementApiService(dio);
      final result = await service.encodeVibe(
        sourceImage,
        model: 'nai-diffusion-4-5-full',
        informationExtracted: 0.35,
      );

      expect(result, isNotEmpty);
      expect(capturedData?['model'], equals('nai-diffusion-4-5-full'));
      expect(capturedData?['information_extracted'], equals(0.35));
      expect(capturedData?.containsKey('informationExtracted'), isFalse);
    });
  });
}

Uint8List _buildPng({required int width, required int height}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _buildZipWithSingleImage(Uint8List imageBytes) {
  final archive = Archive()
    ..addFile(ArchiveFile('result.png', imageBytes.length, imageBytes));
  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded!);
}
