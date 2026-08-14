import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;
import 'package:nai_launcher/core/enums/precise_ref_type.dart';
import 'package:nai_launcher/core/network/nai_api_endpoint.dart';
import 'package:nai_launcher/core/network/nai_api_endpoint_service.dart';
import 'package:nai_launcher/data/datasources/remote/nai_image_enhancement_api_service.dart';
import 'package:nai_launcher/data/datasources/remote/nai_image_generation_api_service.dart';
import 'package:nai_launcher/data/models/image/image_params.dart';
import 'package:nai_launcher/data/models/vibe/vibe_reference.dart';

void main() {
  test(
    'Sugar Cloud sends the full NovelAI payload and accepts task events',
    () async {
      final adapter = _PendingDioAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final endpointService = NaiApiEndpointService()
        ..setCurrent(
          NaiApiEndpointConfig.fromInput(
            mainBaseUrl: 'https://std.loliyc.com/api/generate',
            providerType: NaiApiProviderType.shatangyun,
          ),
        );
      final service = NAIImageGenerationApiService(
        dio,
        NAIImageEnhancementApiService(dio, endpointService),
        endpointService,
        accessTokenProvider: () async => 'STD-test-token',
      );

      final streamChunks = await service
          .generateImageStream(const ImageParams(prompt: 'sugar stream'))
          .toList();
      expect(streamChunks.single.error, contains('Streaming is not allowed'));
      expect(adapter.requests, isEmpty);

      final resultFuture = service.generateImage(
        const ImageParams(prompt: 'sugar test'),
      );
      await _waitForRequestCount(adapter, 1);

      final generationRequest = adapter.requests[0].options;
      expect(
        generationRequest.uri.toString(),
        'https://std.loliyc.com/novelai',
      );
      expect(generationRequest.data, isA<Map<String, dynamic>>());
      final requestData = Map<String, dynamic>.from(
        generationRequest.data as Map,
      );
      expect(requestData['input'], contains('sugar test'));
      expect(requestData['action'], 'generate');
      expect(requestData['model'], 'nai-diffusion-4-full');
      final parameters = Map<String, dynamic>.from(
        requestData['parameters'] as Map,
      );
      expect(parameters['width'], 832);
      expect(parameters['height'], 1216);
      expect(parameters['steps'], 28);
      expect(generationRequest.responseType, ResponseType.stream);
      // Inpaint/img2img bodies can contain multiple large base64 PNGs. The
      // provider-level task timeout bounds the whole operation, so uploads
      // must not be killed by the old 30-second send timeout.
      expect(generationRequest.sendTimeout, const Duration(minutes: 5));
      expect(generationRequest.headers['Content-Type'], 'application/json');
      expect(
        generationRequest.headers['Authorization'],
        'Bearer STD-test-token',
      );
      expect(generationRequest.extra['skipAuth'], isNot(true));
      final openTaskStream = adapter.requests[0].completeWithOpenTextStream(
        '{"status":"wait","data":"已连接"}\n\n'
        '{"status":"wait","data":"生成中 50%"}\n\n'
        '{"status":"success","url":"/img/generated.png"}\n\n',
      );

      await _waitForRequestCount(adapter, 2);
      final imageRequest = adapter.requests[1].options;
      expect(
        imageRequest.uri.toString(),
        'https://std.loliyc.com/img/generated.png',
      );
      expect(imageRequest.extra['skipAuth'], isTrue);
      final png = _solidPng(width: 64, height: 64, r: 8, g: 9, b: 10);
      adapter.requests[1].completeWithImage(png);

      final result = await resultFuture;
      expect(result.$1, hasLength(1));
      expect(result.$1.single, orderedEquals(png));
      await openTaskStream.close();
    },
  );

  test(
    'Sugar Cloud routes img2img through its source-aware web task',
    () async {
      final adapter = _PendingDioAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final endpointService = NaiApiEndpointService()
        ..setCurrent(
          NaiApiEndpointConfig.fromInput(
            mainBaseUrl: 'https://std.loliyc.com/generate',
            providerType: NaiApiProviderType.shatangyun,
          ),
        );
      final service = NAIImageGenerationApiService(
        dio,
        NAIImageEnhancementApiService(dio, endpointService),
        endpointService,
        accessTokenProvider: () async => 'STD-test-token',
      );
      final source = _solidPng(width: 128, height: 128, r: 4, g: 5, b: 6);

      final resultFuture = service.generateImage(
        ImageParams(
          prompt: 'sugar img2img',
          action: ImageGenerationAction.img2img,
          sourceImage: source,
          width: 128,
          height: 128,
          strength: 0.42,
          noise: 0.17,
          cfgRescale: 0.25,
          varietyPlus: true,
        ),
      );
      await _waitForRequestCount(adapter, 1);

      final request = adapter.requests.single.options;
      expect(request.uri.toString(), 'https://std.loliyc.com/generate');
      expect(request.extra['skipAuth'], isTrue);
      expect(request.data, isA<String>());
      final body = Map<String, dynamic>.from(
        jsonDecode(request.data as String) as Map,
      );
      expect(body['model'], 'nai-diffusion-4-full');
      expect(body['size'], '128x128');
      expect(body['i2i_force'], '0.42');
      expect(body['i2i_cl'], '1');
      final addition = Map<String, dynamic>.from(body['addition'] as Map);
      expect(
        addition['imageToImageBase64'],
        startsWith('data:image/png;base64,'),
      );

      adapter.requests.single.completeWithTextStream(
        '{"status":"success","url":"/img/img2img.png"}\n\n',
      );
      await _waitForRequestCount(adapter, 2);
      final resultImage = _solidPng(
        width: 128,
        height: 128,
        r: 100,
        g: 110,
        b: 120,
      );
      adapter.requests[1].completeWithImage(resultImage);

      final result = await resultFuture;
      expect(result.$1.single, orderedEquals(resultImage));
    },
  );

  test(
    'Sugar Cloud uses source-aware img2img then locally composites inpaint',
    () async {
      final adapter = _PendingDioAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final endpointService = NaiApiEndpointService()
        ..setCurrent(
          NaiApiEndpointConfig.fromInput(
            mainBaseUrl: 'https://std.loliyc.com/api/generate',
            providerType: NaiApiProviderType.shatangyun,
          ),
        );
      final service = NAIImageGenerationApiService(
        dio,
        NAIImageEnhancementApiService(dio, endpointService),
        endpointService,
        accessTokenProvider: () async => 'STD-test-token',
      );
      final source = _solidPng(width: 256, height: 256, r: 10, g: 20, b: 30);
      final mask = _rectMaskPng(
        width: 256,
        height: 256,
        x: 112,
        y: 112,
        rectWidth: 32,
        rectHeight: 32,
      );

      final resultFuture = service.generateImage(
        ImageParams(
          prompt: 'sugar inpaint',
          action: ImageGenerationAction.infill,
          sourceImage: source,
          maskImage: mask,
          width: 256,
          height: 256,
          inpaintStrength: 0.65,
        ),
      );
      await _waitForRequestCount(adapter, 1);

      final request = adapter.requests.single.options;
      expect(request.uri.toString(), 'https://std.loliyc.com/generate');
      expect(request.extra['skipAuth'], isTrue);
      final body = Map<String, dynamic>.from(
        jsonDecode(request.data as String) as Map,
      );
      // Sugar's Raven `/novelai` converter silently turns infill into
      // text-to-image. Its web task does honour imageToImageBase64, so use the
      // base model there and retain the official mask for local compositing.
      expect(body['model'], 'nai-diffusion-4-full');
      expect(body['i2i_force'], '0.65');
      expect(body['i2i_cl'], '1');
      final addition = Map<String, dynamic>.from(body['addition'] as Map);
      expect(
        addition['imageToImageBase64'],
        startsWith('data:image/png;base64,'),
      );

      adapter.requests.single.completeWithTextStream(
        '{"status":"success","url":"/img/inpaint.png"}\n\n',
      );
      await _waitForRequestCount(adapter, 2);
      final generated = _solidPng(
        width: 256,
        height: 256,
        r: 200,
        g: 210,
        b: 220,
      );
      adapter.requests[1].completeWithImage(generated);

      final result = await resultFuture;
      expect(result.$1, hasLength(1));
      final composited = img.decodeImage(result.$1.single)!;
      final untouched = composited.getPixel(0, 0);
      expect(
        (untouched.r.toInt(), untouched.g.toInt(), untouched.b.toInt()),
        (10, 20, 30),
      );
      final repainted = composited.getPixel(128, 128);
      expect(
        (repainted.r.toInt(), repainted.g.toInt(), repainted.b.toInt()),
        (200, 210, 220),
      );
    },
  );

  test(
    'Sugar Cloud keeps multi-character and Precise Reference parameters',
    () async {
      final adapter = _PendingDioAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final endpointService = NaiApiEndpointService()
        ..setCurrent(
          NaiApiEndpointConfig.fromInput(
            mainBaseUrl: 'https://std.loliyc.com/novelai',
            providerType: NaiApiProviderType.shatangyun,
          ),
        );
      final service = NAIImageGenerationApiService(
        dio,
        NAIImageEnhancementApiService(dio, endpointService),
        endpointService,
        accessTokenProvider: () async => 'STD-test-token',
      );
      final reference = _solidPng(width: 128, height: 128, r: 30, g: 40, b: 50);

      final resultFuture = service.generateImage(
        ImageParams(
          prompt: 'sugar references',
          model: 'nai-diffusion-4-5-full',
          width: 128,
          height: 128,
          useCoords: true,
          characters: const [
            CharacterPrompt(
              prompt: '1girl, red hair',
              negativePrompt: 'blue hair',
              positionX: 0.2,
              positionY: 0.8,
            ),
          ],
          preciseReferences: [
            PreciseReference(
              image: reference,
              type: PreciseRefType.character,
              strength: 0.75,
              fidelity: 0.4,
            ),
          ],
        ),
      );
      await _waitForRequestCount(adapter, 1);

      final data = Map<String, dynamic>.from(
        adapter.requests.single.options.data as Map,
      );
      final parameters = Map<String, dynamic>.from(data['parameters'] as Map);
      expect(parameters['use_coords'], isTrue);
      expect(parameters['characterPrompts'], hasLength(1));
      expect(parameters['director_reference_images'], hasLength(1));
      expect(parameters['director_reference_descriptions'], hasLength(1));
      expect(parameters['director_reference_strength_values'], [0.75]);
      expect(parameters['director_reference_secondary_strength_values'], [0.6]);

      adapter.requests.single.completeWithImage(
        _solidPng(width: 128, height: 128, r: 80, g: 90, b: 100),
      );
      final result = await resultFuture;
      expect(result.$1, hasLength(1));
    },
  );

  test('Sugar Cloud sends raw Vibe images through its task adapter', () async {
    final adapter = _PendingDioAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final endpointService = NaiApiEndpointService()
      ..setCurrent(
        NaiApiEndpointConfig.fromInput(
          mainBaseUrl: 'https://std.loliyc.com/novelai',
          providerType: NaiApiProviderType.shatangyun,
        ),
      );
    final service = NAIImageGenerationApiService(
      dio,
      NAIImageEnhancementApiService(dio, endpointService),
      endpointService,
      accessTokenProvider: () async => 'STD-test-token',
    );
    final rawImage = _solidPng(width: 128, height: 128, r: 22, g: 33, b: 44);

    final resultFuture = service.generateImage(
      ImageParams(
        prompt: 'sugar raw vibe',
        model: 'nai-diffusion-4-5-full',
        action: ImageGenerationAction.img2img,
        sourceImage: rawImage,
        width: 128,
        height: 128,
        strength: 0.33,
        characters: const [
          CharacterPrompt(
            prompt: '1girl, green eyes',
            negativePrompt: 'red eyes',
            positionX: 0.2,
            positionY: 0.8,
          ),
        ],
        vibeReferencesV4: [
          VibeReference(
            displayName: 'raw-vibe.png',
            vibeEncoding: '',
            rawImageData: rawImage,
            strength: 0.55,
            infoExtracted: 0.66,
          ),
        ],
      ),
    );
    await _waitForRequestCount(adapter, 1);

    final request = adapter.requests.single.options;
    expect(request.uri.toString(), 'https://std.loliyc.com/generate');
    expect(request.sendTimeout, const Duration(minutes: 5));
    expect(request.extra['skipAuth'], isTrue);
    expect(request.data, isA<String>());
    final body = Map<String, dynamic>.from(
      jsonDecode(request.data as String) as Map,
    );
    expect(body['token'], 'STD-test-token');
    expect(body['size'], '128x128');
    expect(body['i2i_force'], '0.33');
    final addition = Map<String, dynamic>.from(body['addition'] as Map);
    expect(
      addition['imageToImageBase64'],
      startsWith('data:image/png;base64,'),
    );
    final vibes = addition['vibeTransferList'] as List;
    expect(vibes, hasLength(1));
    expect(
      (vibes.single as Map)['base64'],
      startsWith('data:image/png;base64,'),
    );
    expect((vibes.single as Map)['ref_strength'], 0.55);
    expect((vibes.single as Map)['info_extract'], 0.66);
    final roles = addition['multiRoleList'] as List;
    expect(roles, hasLength(1));
    expect((roles.single as Map)['position'], 'B4');

    adapter.requests.single.completeWithTextStream(
      '{"status":"success","url":"/img/raw-vibe.png"}\n\n',
    );
    await _waitForRequestCount(adapter, 2);
    adapter.requests[1].completeWithImage(
      _solidPng(width: 128, height: 128, r: 120, g: 130, b: 140),
    );
    final result = await resultFuture;
    expect(result.$1, hasLength(1));
  });

  test('Sugar Cloud preserves an existing Vibe encoding', () async {
    final adapter = _PendingDioAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final endpointService = NaiApiEndpointService()
      ..setCurrent(
        NaiApiEndpointConfig.fromInput(
          mainBaseUrl: 'https://std.loliyc.com/novelai',
          providerType: NaiApiProviderType.shatangyun,
        ),
      );
    final service = NAIImageGenerationApiService(
      dio,
      NAIImageEnhancementApiService(dio, endpointService),
      endpointService,
      accessTokenProvider: () async => 'STD-test-token',
    );
    final rawImage = _solidPng(width: 64, height: 64, r: 11, g: 22, b: 33);

    final resultFuture = service.generateImage(
      ImageParams(
        prompt: 'sugar encoded vibe',
        model: 'nai-diffusion-4-5-full',
        width: 64,
        height: 64,
        vibeReferencesV4: [
          VibeReference(
            displayName: 'encoded-vibe',
            vibeEncoding: 'existing-vibe-encoding',
            rawImageData: rawImage,
            strength: 0.44,
            infoExtracted: 0.77,
          ),
        ],
      ),
    );
    await _waitForRequestCount(adapter, 1);

    final request = adapter.requests.single.options;
    expect(request.uri.toString(), 'https://std.loliyc.com/novelai');
    final data = Map<String, dynamic>.from(request.data as Map);
    final parameters = Map<String, dynamic>.from(data['parameters'] as Map);
    expect(parameters['reference_image_multiple'], ['existing-vibe-encoding']);
    expect(parameters['reference_strength_multiple'], [0.44]);
    expect(parameters['reference_information_extracted_multiple'], [0.77]);

    adapter.requests.single.completeWithImage(
      _solidPng(width: 64, height: 64, r: 70, g: 80, b: 90),
    );
    final result = await resultFuture;
    expect(result.$1, hasLength(1));
  });

  test('Sugar Cloud failed task event becomes a visible exception', () async {
    final adapter = _PendingDioAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final endpointService = NaiApiEndpointService()
      ..setCurrent(
        NaiApiEndpointConfig.fromInput(
          mainBaseUrl: 'https://std.loliyc.com/novelai',
          providerType: NaiApiProviderType.shatangyun,
        ),
      );
    final service = NAIImageGenerationApiService(
      dio,
      NAIImageEnhancementApiService(dio, endpointService),
      endpointService,
      accessTokenProvider: () async => 'STD-test-token',
    );

    final result = service.generateImage(
      const ImageParams(prompt: 'surface sugar error'),
    );
    await _waitForRequestCount(adapter, 1);
    adapter.requests.single.completeWithTextStream(
      '{"status":"wait","data":"已连接"}\n\n'
      '{"status":"failed","data":"授权 Key 已失效"}\n\n',
    );

    await expectLater(
      result,
      throwsA(predicate((error) => error.toString().contains('授权 Key 已失效'))),
    );
    expect(adapter.requests, hasLength(1));
  });

  test(
    'generation-only provider skips stream and uses NovelAI ZIP endpoint',
    () async {
      final adapter = _PendingDioAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final endpointService = NaiApiEndpointService()
        ..setCurrent(
          NaiApiEndpointConfig.fromInput(
            mainBaseUrl: 'https://gateway.example/nai',
            imageBaseUrl: 'https://images.gateway.example/nai',
            supportsSubscriptionApi: false,
            supportsStreamingApi: false,
          ),
        );
      final service = NAIImageGenerationApiService(
        dio,
        NAIImageEnhancementApiService(dio, endpointService),
        endpointService,
      );

      final streamChunks = await service
          .generateImageStream(const ImageParams(prompt: 'compatibility'))
          .toList();
      expect(adapter.requests, isEmpty);
      expect(streamChunks, hasLength(1));
      expect(streamChunks.single.error, contains('Streaming is not allowed'));

      final resultFuture = service.generateImage(
        const ImageParams(prompt: 'compatibility'),
      );
      await _waitForRequestCount(adapter, 1);
      final request = adapter.requests.single.options;
      expect(
        request.uri.toString(),
        'https://images.gateway.example/nai/ai/generate-image',
      );
      expect(request.data, isA<Map<String, dynamic>>());
      final requestData = request.data as Map<String, dynamic>;
      expect(requestData['action'], 'generate');
      expect(requestData['parameters'], isA<Map<String, dynamic>>());

      adapter.requests.single.completeWithZipImage(
        _solidPng(width: 64, height: 64, r: 1, g: 2, b: 3),
      );
      final result = await resultFuture;
      expect(result.$1, hasLength(1));
    },
  );

  test('completed older request must not clear newer cancel token', () async {
    final adapter = _PendingDioAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final endpointService = NaiApiEndpointService();
    final service = NAIImageGenerationApiService(
      dio,
      NAIImageEnhancementApiService(dio, endpointService),
      endpointService,
    );

    final first = service.generateImage(
      const ImageParams(prompt: 'first request'),
    );
    final firstHandled = first
        .then<Object?>((_) => null)
        .catchError((_) => null);
    await _waitForRequestCount(adapter, 1);

    final second = service.generateImage(
      const ImageParams(prompt: 'second request'),
    );
    final secondHandled = second
        .then<Object?>((_) => null)
        .catchError((_) => null);
    await _waitForRequestCount(adapter, 2);

    adapter.requests[0].completeWithEmptyZip();
    await firstHandled;

    service.cancelGeneration();

    expect(
      await adapter.requests[1].cancelledWithin(
        const Duration(milliseconds: 100),
      ),
      isTrue,
    );

    adapter.requests[1].completeWithError(
      DioException(
        requestOptions: adapter.requests[1].options,
        type: DioExceptionType.cancel,
      ),
    );
    await secondHandled;
  });

  test(
    'completed older stream request must not clear newer cancel token',
    () async {
      final adapter = _PendingDioAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final endpointService = NaiApiEndpointService();
      final service = NAIImageGenerationApiService(
        dio,
        NAIImageEnhancementApiService(dio, endpointService),
        endpointService,
      );

      final first = service
          .generateImageStream(const ImageParams(prompt: 'first stream'))
          .drain<Object?>();
      final firstHandled = first
          .then<Object?>((_) => null)
          .catchError((_) => null);
      await _waitForRequestCount(adapter, 1);

      final second = service
          .generateImageStream(const ImageParams(prompt: 'second stream'))
          .drain<Object?>();
      final secondHandled = second
          .then<Object?>((_) => null)
          .catchError((_) => null);
      await _waitForRequestCount(adapter, 2);

      adapter.requests[0].completeWithError(
        DioException(
          requestOptions: adapter.requests[0].options,
          type: DioExceptionType.cancel,
        ),
      );
      await firstHandled;

      service.cancelGeneration();

      expect(
        await adapter.requests[1].cancelledWithin(
          const Duration(milliseconds: 100),
        ),
        isTrue,
      );

      adapter.requests[1].completeWithError(
        DioException(
          requestOptions: adapter.requests[1].options,
          type: DioExceptionType.cancel,
        ),
      );
      await secondHandled;
    },
  );

  test(
    'non-stream inpaint returns one display and transparent patch artifact',
    () async {
      final adapter = _PendingDioAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final endpointService = NaiApiEndpointService();
      final service = NAIImageGenerationApiService(
        dio,
        NAIImageEnhancementApiService(dio, endpointService),
        endpointService,
      );
      final source = _solidPng(width: 256, height: 256, r: 10, g: 20, b: 30);
      final mask = _rectMaskPng(
        width: 256,
        height: 256,
        x: 112,
        y: 112,
        rectWidth: 32,
        rectHeight: 32,
      );
      final generated = _solidPng(
        width: 256,
        height: 256,
        r: 200,
        g: 210,
        b: 220,
      );

      final resultFuture = service.generateImageArtifactsCancellable(
        ImageParams(
          action: ImageGenerationAction.infill,
          model: 'nai-diffusion-4-5-full-inpainting',
          width: 256,
          height: 256,
          sourceImage: source,
          maskImage: mask,
        ),
      );
      await _waitForRequestCount(adapter, 1);
      adapter.requests.single.completeWithZipImage(generated);

      final artifacts = await resultFuture.timeout(const Duration(seconds: 2));
      expect(artifacts, hasLength(1));
      final display = img.decodeImage(artifacts.single.displayImageBytes)!;
      final patch = img.decodeImage(artifacts.single.transparentPatchBytes!)!;
      final reconstructed = img.decodeImage(source)!;
      img.compositeImage(reconstructed, patch, blend: img.BlendMode.alpha);

      expect((display.width, display.height), equals((256, 256)));
      expect((patch.width, patch.height), equals((256, 256)));
      expect(display.getPixel(0, 0).r.toInt(), equals(10));
      expect(display.getPixel(128, 128).r.toInt(), greaterThan(190));
      expect(patch.getPixel(0, 0).a.toInt(), equals(0));
      expect(patch.getPixel(128, 128).a.toInt(), equals(255));
      _expectSameImagePixels(reconstructed, display);
    },
  );

  test('stream cancelled before listen must not start a request', () async {
    final adapter = _PendingDioAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final endpointService = NaiApiEndpointService();
    final service = NAIImageGenerationApiService(
      dio,
      NAIImageEnhancementApiService(dio, endpointService),
      endpointService,
    );

    final stream = service.generateImageStream(
      const ImageParams(prompt: 'cancel before listen'),
    );
    service.cancelGeneration();

    final chunksFuture = stream.toList();
    await _waitForOptionalRequest(adapter);
    if (adapter.requests.isNotEmpty) {
      adapter.requests.single.completeWithEmptyStream();
    }
    final chunks = await chunksFuture.timeout(
      const Duration(milliseconds: 100),
    );

    expect(adapter.requests, isEmpty);
    expect(chunks, hasLength(1));
    expect(chunks.single.error, contains('Cancelled'));
  });

  test('stream completes only from final event image', () async {
    final adapter = _PendingDioAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final endpointService = NaiApiEndpointService();
    final service = NAIImageGenerationApiService(
      dio,
      NAIImageEnhancementApiService(dio, endpointService),
      endpointService,
    );

    final chunksFuture = service
        .generateImageStream(const ImageParams(prompt: 'final'))
        .toList();
    await _waitForRequestCount(adapter, 1);

    final preview = Uint8List.fromList([1, 2, 3]);
    final finalImage = Uint8List.fromList([9, 8, 7]);
    adapter.requests.single.completeWithMsgpackMessages([
      {
        'event_type': 'intermediate',
        'samp_ix': 0,
        'step_ix': 0,
        'image': preview,
      },
      {'event_type': 'final', 'samp_ix': 0, 'image': finalImage},
    ]);

    final chunks = await chunksFuture.timeout(const Duration(seconds: 2));

    expect(chunks, hasLength(2));
    expect(chunks.first.hasPreview, isTrue);
    expect(chunks.first.sampleIndex, 0);
    expect(chunks.first.previewImage, orderedEquals(preview));
    expect(chunks.last.hasFinalImage, isTrue);
    expect(chunks.last.sampleIndex, 0);
    expect(chunks.last.finalImage, orderedEquals(finalImage));
  });

  test('stream ending without final event returns error', () async {
    final adapter = _PendingDioAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final endpointService = NaiApiEndpointService();
    final service = NAIImageGenerationApiService(
      dio,
      NAIImageEnhancementApiService(dio, endpointService),
      endpointService,
    );

    final chunksFuture = service
        .generateImageStream(const ImageParams(prompt: 'missing final'))
        .toList();
    await _waitForRequestCount(adapter, 1);

    final preview = Uint8List.fromList([1, 2, 3]);
    adapter.requests.single.completeWithMsgpackMessages([
      {
        'event_type': 'intermediate',
        'samp_ix': 0,
        'step_ix': 0,
        'image': preview,
      },
    ]);

    final chunks = await chunksFuture.timeout(const Duration(seconds: 2));

    expect(chunks, hasLength(2));
    expect(chunks.first.previewImage, orderedEquals(preview));
    expect(chunks.last.hasError, isTrue);
    expect(chunks.last.error, contains('No final image'));
    expect(chunks.last.hasFinalImage, isFalse);
  });

  test('stream preserves sample indexes for multi-sample finals', () async {
    final adapter = _PendingDioAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final endpointService = NaiApiEndpointService();
    final service = NAIImageGenerationApiService(
      dio,
      NAIImageEnhancementApiService(dio, endpointService),
      endpointService,
    );

    final chunksFuture = service
        .generateImageStream(const ImageParams(prompt: 'multi', nSamples: 2))
        .toList();
    await _waitForRequestCount(adapter, 1);

    final first = Uint8List.fromList([1]);
    final second = Uint8List.fromList([2]);
    adapter.requests.single.completeWithMsgpackMessages([
      {'event_type': 'final', 'samp_ix': 1, 'image': second},
      {'event_type': 'final', 'samp_ix': 0, 'image': first},
    ]);

    final chunks = await chunksFuture.timeout(const Duration(seconds: 2));

    expect(chunks, hasLength(2));
    expect(chunks[0].sampleIndex, 1);
    expect(chunks[0].finalImage, orderedEquals(second));
    expect(chunks[1].sampleIndex, 0);
    expect(chunks[1].finalImage, orderedEquals(first));
    expect(chunks.any((chunk) => chunk.hasError), isFalse);
  });

  test(
    'stream inpaint preview reuses full-frame artifacts and final composites',
    () async {
      final adapter = _PendingDioAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final endpointService = NaiApiEndpointService();
      final service = NAIImageGenerationApiService(
        dio,
        NAIImageEnhancementApiService(dio, endpointService),
        endpointService,
      );

      final source = _solidPng(width: 256, height: 256, r: 10, g: 20, b: 30);
      final mask = _rectMaskPng(
        width: 256,
        height: 256,
        x: 120,
        y: 120,
        rectWidth: 16,
        rectHeight: 16,
      );
      final generated = _solidPng(
        width: 256,
        height: 256,
        r: 200,
        g: 210,
        b: 220,
      );

      final chunksFuture = service
          .generateImageStream(
            ImageParams(
              action: ImageGenerationAction.infill,
              model: 'nai-diffusion-4-5-full-inpainting',
              width: 256,
              height: 256,
              sourceImage: source,
              maskImage: mask,
            ),
          )
          .toList();
      await _waitForRequestCount(adapter, 1);

      adapter.requests.single.completeWithMsgpackMessages([
        {
          'event_type': 'intermediate',
          'samp_ix': 0,
          'step_ix': 0,
          'image': generated,
        },
        {'event_type': 'final', 'samp_ix': 0, 'image': generated},
      ]);

      final chunks = await chunksFuture.timeout(const Duration(seconds: 2));
      final placement = chunks.first.focusedPreviewPlacement;
      final decoded = img.decodeImage(chunks.last.finalImage!)!;

      expect(chunks, hasLength(2));
      expect(placement, isNotNull);
      expect(placement!.sourceImage, orderedEquals(source));
      expect(placement.hasMask, isTrue);
      expect(placement.xPercent, 0);
      expect(placement.yPercent, 0);
      expect(placement.widthPercent, 1);
      expect(placement.heightPercent, 1);
      final previewMask = img.decodeImage(placement.maskImage!)!;
      expect(previewMask.width, 256);
      expect(previewMask.height, 256);
      expect(previewMask.getPixel(0, 0).a.toInt(), 0);
      expect(previewMask.getPixel(128, 128).a.toInt(), greaterThan(250));

      expect(decoded.getPixel(0, 0).r.toInt(), equals(10));
      expect(decoded.getPixel(0, 0).g.toInt(), equals(20));
      expect(decoded.getPixel(0, 0).b.toInt(), equals(30));
      expect(decoded.getPixel(128, 128).r.toInt(), greaterThan(190));
      expect(decoded.getPixel(128, 128).g.toInt(), greaterThan(200));
      expect(decoded.getPixel(128, 128).b.toInt(), greaterThan(210));
    },
  );

  test('focused stream preview keeps raw crop and carries placement', () async {
    final adapter = _PendingDioAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final endpointService = NaiApiEndpointService();
    final service = NAIImageGenerationApiService(
      dio,
      NAIImageEnhancementApiService(dio, endpointService),
      endpointService,
    );

    final source = _solidPng(width: 256, height: 256, r: 10, g: 20, b: 30);
    final mask = _rectMaskPng(
      width: 256,
      height: 256,
      x: 96,
      y: 96,
      rectWidth: 64,
      rectHeight: 64,
    );
    final previewCrop = _solidPng(
      width: 128,
      height: 128,
      r: 120,
      g: 130,
      b: 140,
    );
    final finalCrop = _solidPng(
      width: 128,
      height: 128,
      r: 220,
      g: 230,
      b: 240,
    );

    final chunksFuture = service
        .generateImageStream(
          ImageParams(
            action: ImageGenerationAction.infill,
            model: 'nai-diffusion-4-5-full-inpainting',
            width: 256,
            height: 256,
            sourceImage: source,
            maskImage: mask,
          ),
          focusedInpaintEnabled: true,
          minimumContextMegaPixels: 32,
          focusedSelectionRect: const Rect.fromLTWH(96, 96, 64, 64),
        )
        .toList();
    await _waitForRequestCount(adapter, 1);

    adapter.requests.single.completeWithMsgpackMessages([
      {
        'event_type': 'intermediate',
        'samp_ix': 0,
        'step_ix': 0,
        'image': previewCrop,
      },
      {'event_type': 'final', 'samp_ix': 0, 'image': finalCrop},
    ]);

    final chunks = await chunksFuture.timeout(const Duration(seconds: 2));
    final preview = chunks.first;
    final placement = preview.focusedPreviewPlacement;
    final decodedFinal = img.decodeImage(chunks.last.finalImage!)!;

    expect(chunks, hasLength(2));
    expect(preview.hasPreview, isTrue);
    expect(preview.previewImage, orderedEquals(previewCrop));
    expect(placement, isNotNull);
    expect(placement!.sourceImage, orderedEquals(source));
    expect(placement.hasMask, isTrue);
    final previewMask = img.decodeImage(placement.maskImage!)!;
    expect(previewMask.width, equals(1024));
    expect(previewMask.height, equals(1024));
    expect(previewMask.getPixel(0, 0).a.toInt(), equals(0));
    expect(previewMask.getPixel(512, 512).a.toInt(), equals(255));
    expect(placement.xPercent, closeTo(0.25, 0.001));
    expect(placement.yPercent, closeTo(0.25, 0.001));
    expect(placement.widthPercent, closeTo(0.5, 0.001));
    expect(placement.heightPercent, closeTo(0.5, 0.001));
    expect(decodedFinal.width, equals(256));
    expect(decodedFinal.height, equals(256));
    expect(decodedFinal.getPixel(0, 0).r.toInt(), equals(10));
    expect(decodedFinal.getPixel(128, 128).r.toInt(), greaterThan(210));
    expect(decodedFinal.getPixel(128, 128).g.toInt(), greaterThan(220));
    expect(decodedFinal.getPixel(128, 128).b.toInt(), greaterThan(230));
  });

  test('stream outpaint final preserves official raw service image', () async {
    final adapter = _PendingDioAdapter();
    final dio = Dio()..httpClientAdapter = adapter;
    final endpointService = NaiApiEndpointService();
    final service = NAIImageGenerationApiService(
      dio,
      NAIImageEnhancementApiService(dio, endpointService),
      endpointService,
    );

    final source = _solidPng(width: 256, height: 256, r: 10, g: 20, b: 30);
    final mask = _rectMaskPng(
      width: 256,
      height: 256,
      x: 224,
      y: 0,
      rectWidth: 32,
      rectHeight: 256,
    );
    final generated = _solidPng(
      width: 256,
      height: 256,
      r: 200,
      g: 210,
      b: 220,
    );

    final chunksFuture = service
        .generateImageStream(
          ImageParams(
            action: ImageGenerationAction.infill,
            model: 'nai-diffusion-4-5-full-inpainting',
            width: 256,
            height: 256,
            sourceImage: source,
            maskImage: mask,
            isOutpaint: true,
          ),
        )
        .toList();
    await _waitForRequestCount(adapter, 1);

    adapter.requests.single.completeWithMsgpackMessages([
      {'event_type': 'final', 'samp_ix': 0, 'image': generated},
    ]);

    final chunks = await chunksFuture.timeout(const Duration(seconds: 2));
    final decoded = img.decodeImage(chunks.single.finalImage!)!;

    expect(decoded.getPixel(0, 0).r.toInt(), equals(200));
    expect(decoded.getPixel(0, 0).g.toInt(), equals(210));
    expect(decoded.getPixel(0, 0).b.toInt(), equals(220));
    expect(decoded.getPixel(240, 128).r.toInt(), equals(200));
    expect(decoded.getPixel(240, 128).g.toInt(), equals(210));
    expect(decoded.getPixel(240, 128).b.toInt(), equals(220));
  });

  test('cancelGeneration must abort the connection on the wire', () async {
    // 真实 socket 验证：取消必须让服务器观察到连接断开，
    // 否则 NovelAI 不会释放账号并发额度，后续请求持续 429。
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close());

    final requestReceived = Completer<void>();
    final connectionClosed = Completer<void>();
    server.listen((socket) {
      socket.listen(
        (_) {
          if (!requestReceived.isCompleted) requestReceived.complete();
        },
        onDone: () {
          if (!connectionClosed.isCompleted) connectionClosed.complete();
        },
        onError: (_) {
          if (!connectionClosed.isCompleted) connectionClosed.complete();
        },
      );
    });

    // 与 imageGenerationDioClient 一致：默认 HTTP/1.1 适配器
    final dio = Dio();
    final endpointService = NaiApiEndpointService()
      ..setCurrent(
        NaiApiEndpointConfig.fromInput(mainBaseUrl: '127.0.0.1:${server.port}'),
      );
    final service = NAIImageGenerationApiService(
      dio,
      NAIImageEnhancementApiService(dio, endpointService),
      endpointService,
    );

    final generation = service
        .generateImageStream(const ImageParams(prompt: 'abort on wire'))
        .drain<Object?>()
        .then<Object?>((_) => null)
        .catchError((_) => null);

    // 服务器已收到请求但故意不响应（模拟 NAI 正在排队出图）
    await requestReceived.future.timeout(const Duration(seconds: 10));
    expect(connectionClosed.isCompleted, isFalse);

    service.cancelGeneration();

    await connectionClosed.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => fail(
        'cancelGeneration() did not abort the connection: the server never '
        'observed a disconnect, so NovelAI would keep the per-account '
        'generation slot busy',
      ),
    );

    await generation;
  });
}

Future<void> _waitForOptionalRequest(_PendingDioAdapter adapter) async {
  for (var attempt = 0; attempt < 10; attempt += 1) {
    if (adapter.requests.isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> _waitForRequestCount(
  _PendingDioAdapter adapter,
  int expectedCount,
) async {
  // 聚焦重绘与精准参考预处理已移入后台 isolate；完整测试套件并行运行
  // 大量图片/数据库用例时可能超过 5 秒。条件满足即返回，放宽上限不会
  // 拖慢正常通过路径。
  for (var attempt = 0; attempt < 3000; attempt += 1) {
    if (adapter.requests.length >= expectedCount) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Expected $expectedCount request(s), got ${adapter.requests.length}.');
}

class _PendingDioAdapter implements HttpClientAdapter {
  final List<_PendingRequest> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final request = _PendingRequest(options, cancelFuture);
    requests.add(request);
    return request.response.future;
  }

  @override
  void close({bool force = false}) {}
}

Uint8List _solidPng({
  required int width,
  required int height,
  required int r,
  required int g,
  required int b,
}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(image));
}

Uint8List _rectMaskPng({
  required int width,
  required int height,
  required int x,
  required int y,
  required int rectWidth,
  required int rectHeight,
}) {
  final mask = img.Image(width: width, height: height);
  img.fill(mask, color: img.ColorRgba8(0, 0, 0, 255));
  for (var py = y; py < y + rectHeight; py++) {
    for (var px = x; px < x + rectWidth; px++) {
      mask.setPixelRgba(px, py, 255, 255, 255, 255);
    }
  }
  return Uint8List.fromList(img.encodePng(mask));
}

class _PendingRequest {
  _PendingRequest(this.options, Future<void>? cancelFuture) {
    cancelFuture?.then((_) {
      if (!_cancelled.isCompleted) {
        _cancelled.complete();
      }
    });
  }

  final RequestOptions options;
  final Completer<ResponseBody> response = Completer<ResponseBody>();
  final Completer<void> _cancelled = Completer<void>();

  Future<bool> cancelledWithin(Duration timeout) async {
    try {
      await _cancelled.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  void completeWithEmptyZip() {
    final bytes = ZipEncoder().encode(Archive()) ?? const <int>[];
    response.complete(
      ResponseBody.fromBytes(
        bytes,
        200,
        headers: {
          Headers.contentTypeHeader: ['application/x-zip-compressed'],
        },
      ),
    );
  }

  void completeWithZipImage(Uint8List imageBytes) {
    final archive = Archive()
      ..addFile(ArchiveFile('image.png', imageBytes.length, imageBytes));
    final bytes = ZipEncoder().encode(archive) ?? const <int>[];
    response.complete(
      ResponseBody.fromBytes(
        bytes,
        200,
        headers: {
          Headers.contentTypeHeader: ['application/x-zip-compressed'],
        },
      ),
    );
  }

  void completeWithJson(Map<String, dynamic> data) {
    response.complete(
      ResponseBody.fromString(
        jsonEncode(data),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      ),
    );
  }

  void completeWithTextStream(String data) {
    response.complete(
      ResponseBody.fromString(
        data,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
        },
      ),
    );
  }

  StreamController<Uint8List> completeWithOpenTextStream(String data) {
    final controller = StreamController<Uint8List>();
    response.complete(
      ResponseBody(
        controller.stream,
        200,
        headers: {
          Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
        },
      ),
    );
    controller.add(Uint8List.fromList(utf8.encode(data)));
    return controller;
  }

  void completeWithImage(Uint8List imageBytes) {
    response.complete(
      ResponseBody.fromBytes(
        imageBytes,
        200,
        headers: {
          Headers.contentTypeHeader: ['image/png'],
        },
      ),
    );
  }

  void completeWithEmptyStream() {
    response.complete(
      ResponseBody.fromBytes(
        const <int>[],
        200,
        headers: {
          Headers.contentTypeHeader: ['application/x-msgpack'],
        },
      ),
    );
  }

  void completeWithMsgpackMessages(List<Map<String, Object?>> messages) {
    final bytes = <int>[];
    for (final message in messages) {
      final encoded = msgpack.serialize(message);
      final length = encoded.length;
      bytes
        ..add((length >> 24) & 0xFF)
        ..add((length >> 16) & 0xFF)
        ..add((length >> 8) & 0xFF)
        ..add(length & 0xFF)
        ..addAll(encoded);
    }
    response.complete(
      ResponseBody.fromBytes(
        Uint8List.fromList(bytes),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/x-msgpack'],
        },
      ),
    );
  }

  void completeWithError(Object error) {
    response.completeError(error);
  }
}

void _expectSameImagePixels(img.Image actual, img.Image expected) {
  expect((actual.width, actual.height), (expected.width, expected.height));
  for (var y = 0; y < actual.height; y++) {
    for (var x = 0; x < actual.width; x++) {
      final a = actual.getPixel(x, y);
      final b = expected.getPixel(x, y);
      expect(
        (a.r.toInt(), a.g.toInt(), a.b.toInt(), a.a.toInt()),
        (b.r.toInt(), b.g.toInt(), b.b.toInt(), b.a.toInt()),
        reason: 'Pixel mismatch at $x,$y',
      );
    }
  }
}
