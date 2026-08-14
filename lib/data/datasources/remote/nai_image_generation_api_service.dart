import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:msgpack_dart/msgpack_dart.dart' as msgpack;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/models/image_generation_artifact.dart';
import '../../../core/network/dio_client.dart';
import '../../../core/network/nai_api_endpoint_service.dart';
import '../../../core/network/request_builders/nai_image_request_builder.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/focused_inpaint_utils.dart';
import '../../../core/utils/inpaint_mask_utils.dart';
import '../../../core/utils/isolate_pool.dart';
import '../../../core/utils/nai_api_utils.dart';
import '../../../core/utils/zip_utils.dart';
import '../../models/image/image_params.dart';
import '../../models/image/image_stream_chunk.dart';
import 'nai_image_enhancement_api_service.dart';

part 'nai_image_generation_api_service.g.dart';

// 管道计时开关（false=关闭，true=打开日志）
const bool _enablePipelineTracing = true;
const Duration _shatangyunGenerationTimeout = Duration(minutes: 5);

/// NovelAI Image Generation API 服务
/// 处理图像生成相关的 API 调用，包括流式和非流式生成
class NAIImageGenerationApiService {
  final Dio _dio;
  final NAIImageEnhancementApiService _enhancementService;
  final NaiApiEndpointService _endpointService;
  final Future<String?> Function()? _accessTokenProvider;

  NAIImageGenerationApiService(
    this._dio,
    this._enhancementService,
    this._endpointService, {
    Future<String?> Function()? accessTokenProvider,
  }) : _accessTokenProvider = accessTokenProvider;

  // ==================== 采样器映射 ====================

  /// 根据模型版本映射采样器
  ///
  /// DDIM 在不同模型版本中有不同的行为：
  /// - V1/V2: 直接使用 ddim
  /// - V3: 需要映射到 ddim_v3
  /// - V4+: 不原生支持 DDIM，回退到 Euler Ancestral
  String _mapSamplerForModel(String sampler, String model) {
    if (sampler == Samplers.ddim || sampler == Samplers.ddimV3) {
      // V3 模型需要使用 ddim_v3
      if (model.contains('diffusion-3')) {
        AppLogger.i('Mapping DDIM to DDIM v3 for model: $model', 'ImgGen');
        return Samplers.ddimV3;
      }

      // V4 及以后版本不原生支持 DDIM
      if (model.contains('diffusion-4') || model == 'N/A') {
        AppLogger.w(
          'Model $model does not support DDIM sampler, '
              'falling back to Euler Ancestral',
          'ImgGen',
        );
        return Samplers.kEulerAncestral;
      }
    }

    return sampler;
  }

  // ==================== 图像生成 API ====================

  /// 取消令牌
  CancelToken? _currentCancelToken;

  /// 生成图像（统一方法，支持所有模式）
  ///
  /// [params] 图像生成参数
  /// [onProgress] 进度回调
  ///
  /// 返回 (图像列表, Vibe哈希映射)
  /// - 图像列表：生成的图像字节数据
  /// - Vibe哈希映射：key=vibeReferencesV4索引, value=编码哈希
  Future<(List<Uint8List>, Map<int, String>)> generateImage(
    ImageParams params, {
    void Function(int, int)? onProgress,
    bool focusedInpaintEnabled = false,
    double minimumContextMegaPixels = 88.0,
    Rect? focusedSelectionRect,
  }) async {
    final result = await _generateImageArtifacts(
      params,
      onProgress: onProgress,
      focusedInpaintEnabled: focusedInpaintEnabled,
      minimumContextMegaPixels: minimumContextMegaPixels,
      focusedSelectionRect: focusedSelectionRect,
    );
    return (
      result.$1
          .map((artifact) => artifact.displayImageBytes)
          .toList(growable: false),
      result.$2,
    );
  }

  Future<(List<ImageGenerationArtifact>, Map<int, String>)>
  _generateImageArtifacts(
    ImageParams params, {
    void Function(int, int)? onProgress,
    bool focusedInpaintEnabled = false,
    double minimumContextMegaPixels = 88.0,
    Rect? focusedSelectionRect,
  }) async {
    final focusedRequest = await _prepareFocusedInpaint(
      params,
      enabled: focusedInpaintEnabled,
      minimumContextMegaPixels: minimumContextMegaPixels,
      focusedSelectionRect: focusedSelectionRect,
    );
    final effectiveParams = _applyFocusedRequest(params, focusedRequest);

    // NovelAI 官方说明 Precise Reference 与 Vibe Transfer 不兼容。
    // 当前策略是保留 Precise Reference，并在请求构建阶段跳过 Vibe Transfer。
    final hasVibes = effectiveParams.hasVibeReferencesV4;
    if (hasVibes && effectiveParams.hasPreciseReferences) {
      AppLogger.d(
        'Both Vibe Transfer and Precise Reference are enabled; skipping vibe payload in favor of Precise Reference',
        'ImgGen',
      );
    }

    // Precise Reference 仅 V4.5 模型支持，其他模型时忽略数据。
    final effectivePreciseRefs = effectiveParams.isV45Model
        ? effectiveParams.enabledPreciseReferences
        : <PreciseReference>[];
    final endpoint = _endpointService.current;
    final useShatangyunRawVibeTask =
        endpoint.isShatangyun &&
        effectiveParams.action != ImageGenerationAction.infill &&
        effectivePreciseRefs.isEmpty &&
        effectiveParams.enabledVibeReferencesV4.any(
          (vibe) =>
              vibe.vibeEncoding.isEmpty &&
              vibe.rawImageData?.isNotEmpty == true,
        );

    final cancelToken = CancelToken();
    _currentCancelToken = cancelToken;

    try {
      // 0. 采样器版本映射
      final effectiveSampler = _mapSamplerForModel(
        effectiveParams.sampler,
        effectiveParams.model,
      );

      final requestBuildResult = await NAIImageRequestBuilder(
        params: effectiveParams,
        encodeVibe: _enhancementService.encodeVibe,
        preciseReferences: effectivePreciseRefs,
        vibeTransferHandledExternally: useShatangyunRawVibeTask,
      ).build(sampler: effectiveSampler);

      final vibeEncodingMap = requestBuildResult.vibeEncodingMap;
      final effectiveNegativePrompt =
          requestBuildResult.effectiveNegativePrompt;
      final requestParameters = requestBuildResult.requestParameters;

      // 打印请求参数以便调试
      AppLogger.d(
        'Request parameters: model=${effectiveParams.model}, isV4=${effectiveParams.isV4Model}, ucPreset=${effectiveParams.ucPreset}',
        'ImgGen',
      );
      AppLogger.d(
        'Effective negative_prompt: $effectiveNegativePrompt',
        'ImgGen',
      );

      // 打印完整请求体（调试用）
      if (effectiveParams.isV4Model) {
        AppLogger.d(
          'V4 use_coords: ${requestParameters['use_coords']}',
          'ImgGen',
        );
        AppLogger.d(
          'V4 legacy_v3_extend: ${requestParameters['legacy_v3_extend']}',
          'ImgGen',
        );
        AppLogger.d(
          'V4 legacy_uc: ${requestParameters['legacy_uc']}',
          'ImgGen',
        );
        AppLogger.d(
          'V4 v4_prompt: ${requestParameters['v4_prompt']}',
          'ImgGen',
        );
        AppLogger.d(
          'V4 v4_negative_prompt: ${requestParameters['v4_negative_prompt']}',
          'ImgGen',
        );
        AppLogger.d(
          'V4 characterPrompts: ${requestParameters['characterPrompts']}',
          'ImgGen',
        );
        // 打印完整请求 JSON 以便与 Python SDK 对比
        AppLogger.d(
          'V4 FULL parameters JSON: ${jsonEncode(requestParameters)}',
          'ImgGen',
        );
      }

      // 3. 根据模式添加额外参数
      final String action = effectiveParams.action.value;

      // 4. 构造请求数据（对齐官网格式）
      final requestData = requestBuildResult.requestData;

      AppLogger.d(
        'Generating image with action: $action, model: ${effectiveParams.model}',
        'ImgGen',
      );

      // ========== 详细调试日志（对比官网格式）==========
      if (effectivePreciseRefs.isNotEmpty) {
        AppLogger.d('=== NON-STREAM CHARACTER REFERENCE DEBUG ===', 'ImgGen');
        AppLogger.d(
          'characterReferences count: ${effectivePreciseRefs.length}',
          'ImgGen',
        );
        AppLogger.d('isV4Model: ${effectiveParams.isV4Model}', 'ImgGen');

        final directorReferenceImages =
            requestParameters['director_reference_images'] as List? ?? const [];
        for (int i = 0; i < effectivePreciseRefs.length; i++) {
          final ref = effectivePreciseRefs[i];
          final encodedImageChars = i < directorReferenceImages.length
              ? (directorReferenceImages[i] as String).length
              : 0;
          AppLogger.d(
            'CharRef[$i] image: ${ref.image.length} bytes -> request base64: $encodedImageChars chars, type: ${ref.type}, strength: ${ref.strength}, fidelity: ${ref.fidelity}',
            'ImgGen',
          );
        }

        AppLogger.d(
          'director_reference_descriptions: ${jsonEncode(requestParameters['director_reference_descriptions'])}',
          'ImgGen',
        );
        AppLogger.d(
          'director_reference_information_extracted: ${requestParameters['director_reference_information_extracted']}',
          'ImgGen',
        );
        AppLogger.d(
          'director_reference_strength_values: ${requestParameters['director_reference_strength_values']}',
          'ImgGen',
        );
        AppLogger.d(
          'director_reference_secondary_strength_values: ${requestParameters['director_reference_secondary_strength_values']}',
          'ImgGen',
        );
        AppLogger.d(
          'normalize_reference_strength_multiple: ${requestParameters['normalize_reference_strength_multiple']}',
          'ImgGen',
        );

        // 打印完整请求 JSON（隐藏 base64 图像数据）
        final debugRequestData = Map<String, dynamic>.from(requestData);
        final debugParams = Map<String, dynamic>.from(
          debugRequestData['parameters'] as Map<String, dynamic>,
        );
        // 隐藏图像 base64 数据
        if (debugParams.containsKey('director_reference_images')) {
          final images = debugParams['director_reference_images'] as List;
          debugParams['director_reference_images'] = images
              .map((img) => '[BASE64_IMAGE_${(img as String).length}_chars]')
              .toList();
        }
        if (debugParams.containsKey('reference_image_multiple')) {
          final images = debugParams['reference_image_multiple'] as List;
          debugParams['reference_image_multiple'] = images
              .map((img) => '[BASE64_IMAGE_${(img as String).length}_chars]')
              .toList();
        }
        if (debugParams.containsKey('image')) {
          debugParams['image'] =
              '[BASE64_IMAGE_${(debugParams['image'] as String).length}_chars]';
        }
        debugRequestData['parameters'] = debugParams;
        AppLogger.d(
          'FULL REQUEST JSON (images hidden): ${jsonEncode(debugRequestData)}',
          'ImgGen',
        );
        AppLogger.d('==========================================', 'ImgGen');
      }

      // 5. 发送请求。砂糖云通常使用完整 `/novelai` 适配器；只有
      // 尚未编码的原始 Vibe 图片走 `/generate`，由砂糖云在任务内部编码。
      // 其余兼容服务继续按 NovelAI ZIP 响应处理。
      if (endpoint.isShatangyun) {
        final images = useShatangyunRawVibeTask
            ? await _generateWithShatangyunRawVibeTask(
                endpoint.shatangyunTaskGenerationUrl,
                requestData,
                effectiveParams,
                cancelToken: cancelToken,
                onProgress: onProgress,
              )
            : await _generateWithShatangyun(
                endpoint.imageGenerationUrl,
                requestData,
                cancelToken: cancelToken,
                onProgress: onProgress,
              );
        final artifacts = await _compositeInpaintImages(
          images,
          params,
          focusedRequest,
          requestBuildResult,
        );
        if (artifacts.isEmpty) {
          throw Exception('砂糖云响应中没有可用图片');
        }
        return (artifacts, vibeEncodingMap);
      }

      final response = await _dio.post(
        endpoint.imageGenerationUrl,
        data: requestData,
        cancelToken: cancelToken,
        onReceiveProgress: onProgress,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Accept': 'application/x-zip-compressed'},
        ),
      );

      // 6. 解压 ZIP 响应
      final zipBytes = response.data as Uint8List;
      final artifacts = await _compositeInpaintImages(
        ZipUtils.extractAllImages(zipBytes),
        params,
        focusedRequest,
        requestBuildResult,
      );

      if (artifacts.isEmpty) {
        throw Exception('No images found in response');
      }

      // 返回图像和 Vibe 编码哈希映射
      return (artifacts, vibeEncodingMap);
    } finally {
      if (identical(_currentCancelToken, cancelToken)) {
        _currentCancelToken = null;
      }
    }
  }

  Future<List<Uint8List>> _generateWithShatangyun(
    String generationUrl,
    Map<String, dynamic> requestData, {
    required CancelToken cancelToken,
    void Function(int, int)? onProgress,
  }) async {
    AppLogger.i('Using Sugar Cloud full NovelAI adapter', 'ImgGen');
    try {
      return await _runShatangyunTask(
        generationUrl,
        requestData,
        cancelToken: cancelToken,
        onProgress: onProgress,
      ).timeout(_shatangyunGenerationTimeout);
    } on TimeoutException {
      cancelToken.cancel('Sugar Cloud generation timed out');
      throw Exception('砂糖云生成超过 5 分钟，任务已停止，请稍后重试');
    }
  }

  Future<List<Uint8List>> _generateWithShatangyunRawVibeTask(
    String generationUrl,
    Map<String, dynamic> requestData,
    ImageParams params, {
    required CancelToken cancelToken,
    void Function(int, int)? onProgress,
  }) async {
    AppLogger.i('Using Sugar Cloud raw Vibe task adapter', 'ImgGen');
    final sampleCount = params.nSamples.clamp(1, 16);
    try {
      return await _runShatangyunRawVibeTask(
        generationUrl,
        requestData,
        params,
        cancelToken: cancelToken,
        onProgress: onProgress,
      ).timeout(Duration(minutes: 5 * sampleCount));
    } on TimeoutException {
      cancelToken.cancel('Sugar Cloud generation timed out');
      throw Exception('砂糖云生成超过 5 分钟，任务已停止，请稍后重试');
    }
  }

  Future<List<Uint8List>> _runShatangyunRawVibeTask(
    String generationUrl,
    Map<String, dynamic> requestData,
    ImageParams params, {
    required CancelToken cancelToken,
    void Function(int, int)? onProgress,
  }) async {
    final token = _normalizeProviderToken(await _accessTokenProvider?.call());
    if (token.isEmpty) {
      throw Exception('未读取到砂糖云 Token，请重新登录该账号');
    }

    final parameters = Map<String, dynamic>.from(
      requestData['parameters'] as Map? ?? const <String, dynamic>{},
    );
    final sourceImage = parameters['image']?.toString();
    final roleData = <Map<String, dynamic>>[];
    final characterPrompts = parameters['characterPrompts'] as List?;
    if (characterPrompts != null) {
      for (final rawCharacter in characterPrompts) {
        if (rawCharacter is! Map) continue;
        final character = Map<String, dynamic>.from(rawCharacter);
        final center = character['center'] is Map
            ? Map<String, dynamic>.from(character['center'] as Map)
            : const <String, dynamic>{};
        final position = _shatangyunGridPosition(
          (center['x'] as num?)?.toDouble() ?? 0.5,
          (center['y'] as num?)?.toDouble() ?? 0.5,
        );
        final negative = character['uc']?.toString() ?? '';
        roleData.add({
          'prompt': character['prompt']?.toString() ?? '',
          'negative_prompt': negative,
          'position': position,
          'negativePrompt': negative,
        });
      }
    }

    final vibeData = <Map<String, dynamic>>[];
    for (final vibe in params.enabledVibeReferencesV4) {
      final rawImage = vibe.rawImageData;
      if (rawImage == null || rawImage.isEmpty) continue;
      vibeData.add({
        'base64': _shatangyunImageDataUrl(rawImage),
        'info_extract': vibe.infoExtracted,
        'ref_strength': vibe.strength,
        'infoExtract': vibe.infoExtracted,
        'refStrength': vibe.strength,
      });
    }

    final payload = <String, dynamic>{
      'ch': false,
      'tag': requestData['input']?.toString() ?? '',
      'token': token,
      'model': requestData['model']?.toString() ?? 'nai-diffusion-4-5-full',
      'artist': '',
      'size':
          '${parameters['width'] ?? params.width}x'
          '${parameters['height'] ?? params.height}',
      'steps': '${parameters['steps'] ?? params.steps}',
      'scale': '${parameters['scale'] ?? params.scale}',
      'cfg': '${parameters['cfg_rescale'] ?? params.cfgRescale}',
      'sampler': parameters['sampler']?.toString() ?? params.sampler,
      'negative': parameters['negative_prompt']?.toString() ?? '',
      'seed': '${parameters['seed'] ?? ''}',
      'other': _shatangyunSmeaMode(params),
      'varity': params.varietyPlus ? '1' : '0',
      'decrisp': params.decrisp ? '1' : '0',
      'nocache': 1,
      'noise_schedule':
          parameters['noise_schedule']?.toString() ?? params.noiseSchedule,
      'stream': 1,
      'addition': {
        'imageToImageBase64':
            params.action == ImageGenerationAction.img2img &&
                sourceImage != null &&
                sourceImage.isNotEmpty
            ? 'data:image/png;base64,$sourceImage'
            : null,
        'vibeTransferList': vibeData,
        'multiRoleList': roleData,
        'characterKeep': const {
          'base64': null,
          'keep_vibe': false,
          'strength': 0.8,
          'keepVibe': false,
        },
      },
      'i2i_force': '${parameters['strength'] ?? params.strength}',
      'i2i_cl': params.action == ImageGenerationAction.img2img ? '1' : '',
      'git_token': '',
      'git_repo': '',
    };

    final sampleCount = params.nSamples.clamp(1, 16);
    final baseSeed = int.tryParse(payload['seed']?.toString() ?? '');
    final images = <Uint8List>[];
    for (var sampleIndex = 0; sampleIndex < sampleCount; sampleIndex++) {
      final samplePayload = Map<String, dynamic>.from(payload);
      if (baseSeed != null && sampleIndex > 0) {
        samplePayload['seed'] = '${(baseSeed + sampleIndex) % 4294967296}';
      }

      final response = await _dio.post<ResponseBody>(
        generationUrl,
        data: jsonEncode(samplePayload),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          receiveTimeout: _shatangyunGenerationTimeout,
          // Raw Vibe and img2img requests can contain several base64 images.
          // Do not apply a short upload-only timeout; the enclosing task
          // timeout still cancels the whole operation if it really stalls.
          sendTimeout: _shatangyunGenerationTimeout,
          headers: const {
            'Accept': 'text/plain, application/json, text/event-stream',
            'Content-Type': 'text/event-stream',
            'Origin': 'https://www.loliyc.com',
            'Referer': 'https://www.loliyc.com/std/image.html',
          },
          // The browser task endpoint reads its token from the JSON body.
          extra: const {'skipAuth': true},
        ),
      );
      final body = response.data;
      if (body == null) throw Exception('砂糖云返回了空响应');
      images.addAll(
        await _readShatangyunTextResponse(
          body.stream,
          requestOptions: response.requestOptions,
          baseUri: Uri.parse(generationUrl),
          cancelToken: cancelToken,
          onProgress: onProgress,
        ),
      );
    }
    return images;
  }

  String _shatangyunSmeaMode(ImageParams params) {
    if (!params.isV3Model) return '0';
    if (params.smeaAuto) {
      if (params.smeaDyn) return '5';
      if (params.smea) return '4';
      return '1';
    }
    if (params.smeaDyn) return '3';
    if (params.smea) return '2';
    return '0';
  }

  String _shatangyunGridPosition(double x, double y) {
    final column = (x.clamp(0.0, 1.0) * 4).round().clamp(0, 4);
    final row = (y.clamp(0.0, 1.0) * 4).round().clamp(0, 4) + 1;
    return '${String.fromCharCode('A'.codeUnitAt(0) + column)}$row';
  }

  String _shatangyunImageDataUrl(Uint8List bytes) {
    var mime = 'image/png';
    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      mime = 'image/jpeg';
    } else if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      mime = 'image/gif';
    } else if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      mime = 'image/webp';
    }
    return 'data:$mime;base64,${base64Encode(bytes)}';
  }

  Future<List<Uint8List>> _runShatangyunTask(
    String generationUrl,
    Map<String, dynamic> requestData, {
    required CancelToken cancelToken,
    void Function(int, int)? onProgress,
  }) async {
    final token = _normalizeProviderToken(await _accessTokenProvider?.call());
    if (token.isEmpty) {
      throw Exception('未读取到砂糖云 Token，请重新登录该账号');
    }

    final response = await _dio.post<ResponseBody>(
      generationUrl,
      // `/novelai` is Sugar Cloud's official-parameter adapter. Keep the
      // complete request intact so img2img, inpaint, Vibe/Precise Reference,
      // multi-character prompts and future NovelAI fields are not discarded.
      data: requestData,
      cancelToken: cancelToken,
      options: Options(
        responseType: ResponseType.stream,
        receiveTimeout: _shatangyunGenerationTimeout,
        // Focused inpaint uploads both the resized source PNG and its mask.
        // On mobile networks this can legitimately take longer than 30s.
        // The enclosing five-minute task timeout remains the hard limit.
        sendTimeout: _shatangyunGenerationTimeout,
        headers: {
          'Authorization': 'Bearer $token',
          'Accept':
              'application/json, application/x-zip-compressed, image/*, '
              'text/plain, text/event-stream',
          'Content-Type': 'application/json',
        },
      ),
    );

    final body = response.data;
    if (body == null) throw Exception('砂糖云返回了空响应');

    final contentType =
        response.headers.value(Headers.contentTypeHeader)?.toLowerCase() ?? '';
    if (_isShatangyunTextContentType(contentType)) {
      return _readShatangyunTextResponse(
        body.stream,
        requestOptions: response.requestOptions,
        baseUri: Uri.parse(generationUrl),
        cancelToken: cancelToken,
        onProgress: onProgress,
      );
    }

    final responseBytes = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      if (cancelToken.isCancelled) {
        throw DioException(
          requestOptions: response.requestOptions,
          type: DioExceptionType.cancel,
          error: 'User cancelled',
        );
      }
      responseBytes.add(chunk);
    }

    final bytes = responseBytes.takeBytes();
    if (bytes.isEmpty) throw Exception('砂糖云返回了空响应');

    // Accept direct NovelAI-style ZIPs and direct image responses too. This
    // keeps the adapter forward-compatible if Sugar Cloud changes its wrapper
    // without changing the request contract.
    if (_looksLikeImage(bytes)) {
      onProgress?.call(100, 100);
      return [bytes];
    }
    final archivedImages = ZipUtils.extractAllImages(bytes);
    if (archivedImages.isNotEmpty) {
      onProgress?.call(100, 100);
      return archivedImages;
    }

    // Be tolerant of a missing/incorrect Content-Type header.
    return _readShatangyunTextResponse(
      Stream<Uint8List>.value(bytes),
      requestOptions: response.requestOptions,
      baseUri: Uri.parse(generationUrl),
      cancelToken: cancelToken,
      onProgress: onProgress,
    );
  }

  bool _isShatangyunTextContentType(String contentType) {
    return contentType.contains('json') ||
        contentType.startsWith('text/') ||
        contentType.contains('event-stream');
  }

  Future<List<Uint8List>> _readShatangyunTextResponse(
    Stream<Uint8List> byteStream, {
    required RequestOptions requestOptions,
    required Uri baseUri,
    required CancelToken cancelToken,
    void Function(int, int)? onProgress,
  }) async {
    var pendingText = '';
    var receivedEvents = 0;
    var completed = false;
    final locations = <String>[];

    void processEvent(Map<String, dynamic> event) {
      receivedEvents++;
      final status = event['status']?.toString().toLowerCase() ?? '';
      AppLogger.d(
        'Sugar Cloud event #$receivedEvents: status=$status',
        'ImgGen',
      );
      if (status == 'failed' ||
          status == 'fail' ||
          status == 'error' ||
          event.containsKey('error')) {
        final detail = _extractProviderError(event);
        throw Exception(detail.isEmpty ? '砂糖云生成失败' : '砂糖云生成失败：$detail');
      }

      for (final location in _extractShatangyunImageLocations(event)) {
        if (!locations.contains(location)) locations.add(location);
      }
      if (status == 'success') {
        if (locations.isEmpty) {
          throw Exception('砂糖云任务成功但没有返回图片地址');
        }
        completed = true;
        onProgress?.call(100, 100);
      } else if (status.isEmpty && locations.isNotEmpty) {
        completed = true;
        onProgress?.call(100, 100);
      } else {
        onProgress?.call(_shatangyunEventProgress(event, receivedEvents), 100);
      }
    }

    void processText(String text) {
      for (final event in _decodeShatangyunResponseText(text)) {
        processEvent(event);
        if (completed) return;
      }
    }

    final textStream = byteStream
        .map<List<int>>((chunk) => chunk)
        .transform(utf8.decoder);
    await for (final textChunk in textStream) {
      if (cancelToken.isCancelled) {
        throw DioException(
          requestOptions: requestOptions,
          type: DioExceptionType.cancel,
          error: 'User cancelled',
        );
      }

      pendingText += textChunk;
      final blocks = pendingText.split(RegExp(r'\r?\n\r?\n'));
      pendingText = blocks.removeLast();
      for (final block in blocks) {
        processText(block);
        if (completed) break;
      }

      // `/novelai` commonly returns one JSON object without SSE separators.
      // Parse it as soon as a complete object arrives instead of waiting for
      // the server to close a keep-alive stream (the old iOS hang).
      if (!completed && pendingText.trim().isNotEmpty) {
        final completeJson = _tryDecodeShatangyunJson(pendingText.trim());
        if (completeJson != null) {
          for (final event in completeJson) {
            processEvent(event);
            if (completed) break;
          }
          pendingText = '';
        }
      }
      if (completed) break;
    }

    final remainingText = pendingText.trim();
    if (!completed && remainingText.isNotEmpty) {
      processText(remainingText);
    }

    // A few compatible deployments return a plain URL/base64 value rather
    // than a JSON wrapper.
    if (locations.isEmpty && remainingText.isNotEmpty) {
      locations.addAll(_extractShatangyunImageLocations(remainingText));
    }
    if (locations.isEmpty) {
      final detail = _extractProviderError(remainingText);
      throw Exception(
        detail.isEmpty || receivedEvents > 0
            ? '砂糖云没有返回可识别的图片'
            : '砂糖云没有返回图片：$detail',
      );
    }

    final images = <Uint8List>[];
    for (final location in locations) {
      images.add(
        await _loadShatangyunImage(
          location,
          baseUri: baseUri,
          cancelToken: cancelToken,
          onProgress: onProgress,
        ),
      );
    }
    return images;
  }

  List<Map<String, dynamic>> _decodeShatangyunResponseText(String text) {
    if (text.isEmpty) return const [];

    final wholeResponse = _tryDecodeShatangyunJson(text);
    if (wholeResponse != null) return wholeResponse;

    final result = <Map<String, dynamic>>[];
    for (final block in text.split(RegExp(r'\r?\n\r?\n'))) {
      result.addAll(_decodeShatangyunEventBlock(block));
    }
    return result;
  }

  List<Map<String, dynamic>> _decodeShatangyunEventBlock(String block) {
    final payloadLines = <String>[];
    for (final rawLine in const LineSplitter().convert(block)) {
      final line = rawLine.trim();
      if (line.isEmpty ||
          line.startsWith(':') ||
          line.startsWith('event:') ||
          line.startsWith('id:') ||
          line.startsWith('retry:')) {
        continue;
      }
      payloadLines.add(
        line.startsWith('data:') ? line.substring(5).trim() : line,
      );
    }
    if (payloadLines.isEmpty) return const [];

    final joined = payloadLines.join('\n');
    final decoded = _tryDecodeShatangyunJson(joined);
    if (decoded != null) return decoded;

    return [
      for (final line in payloadLines) ...?_tryDecodeShatangyunJson(line),
    ];
  }

  List<Map<String, dynamic>>? _tryDecodeShatangyunJson(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return [Map<String, dynamic>.from(decoded)];
      }
      if (decoded is List) {
        return [
          for (final item in decoded)
            if (item is Map) Map<String, dynamic>.from(item),
        ];
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  int _shatangyunEventProgress(Map<String, dynamic> event, int eventCount) {
    final raw = event['progress'] ?? event['percent'];
    if (raw is num) {
      final value = raw <= 1 ? raw * 100 : raw;
      return value.round().clamp(1, 95);
    }
    final data = event['data']?.toString() ?? '';
    final match = RegExp(r'(\d{1,3})\s*%').firstMatch(data);
    if (match != null) {
      return (int.tryParse(match.group(1)!) ?? 1).clamp(1, 95);
    }
    return (eventCount * 10).clamp(5, 90);
  }

  String _normalizeProviderToken(String? value) => (value ?? '')
      .trim()
      .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s+'), '');

  List<String> _extractShatangyunImageLocations(dynamic responseData) {
    final result = <String>[];

    void addLocation(dynamic value) {
      if (value is String && value.trim().isNotEmpty) {
        final normalized = value.trim();
        final lower = normalized.toLowerCase();
        final looksLikeLocation =
            lower.startsWith('https://') ||
            lower.startsWith('http://') ||
            lower.startsWith('/') ||
            lower.startsWith('data:image/') ||
            RegExp(
              r'\.(png|jpe?g|webp|gif)(\?.*)?$',
              caseSensitive: false,
            ).hasMatch(normalized) ||
            (normalized.length > 128 &&
                RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(normalized));
        if (!looksLikeLocation) return;
        if (!result.contains(normalized)) result.add(normalized);
        return;
      }
      if (value is List) {
        for (final item in value) {
          addLocation(item);
        }
        return;
      }
      if (value is Map) {
        for (final key in const [
          'url',
          'image_url',
          'b64_json',
          'data',
          'images',
          'output',
          'result',
          'original_response',
        ]) {
          addLocation(value[key]);
        }
      }
    }

    addLocation(responseData);
    return result;
  }

  String _extractProviderError(dynamic responseData) {
    if (responseData is Map) {
      for (final key in const ['detail', 'message', 'error', 'data']) {
        final value = responseData[key];
        if (value is String && value.trim().isNotEmpty) return value.trim();
      }
      final original = responseData['original_response'];
      if (original is Map) return _extractProviderError(original);
    }
    if (responseData is String) return responseData.trim();
    return '';
  }

  Future<Uint8List> _loadShatangyunImage(
    String location, {
    required Uri baseUri,
    required CancelToken cancelToken,
    void Function(int, int)? onProgress,
  }) async {
    if (location.startsWith('data:image/')) {
      final comma = location.indexOf(',');
      if (comma < 0 || !location.substring(0, comma).contains(';base64')) {
        throw Exception('砂糖云返回了无效的内嵌图片');
      }
      try {
        return Uint8List.fromList(base64Decode(location.substring(comma + 1)));
      } on FormatException {
        throw Exception('砂糖云返回的内嵌图片无法解码');
      }
    }

    // Some OpenAI-style gateways return raw base64 in `b64_json`.
    if (!location.contains('://') &&
        !location.startsWith('/') &&
        location.length > 128) {
      try {
        final bytes = Uint8List.fromList(base64Decode(location));
        if (_looksLikeImage(bytes)) return bytes;
      } on FormatException {
        // Continue and report the location as invalid below.
      }
    }

    final parsed = Uri.tryParse(location);
    if (parsed == null) throw Exception('砂糖云返回了无效的图片地址');
    final imageUri = parsed.hasScheme ? parsed : baseUri.resolveUri(parsed);
    if (imageUri.scheme != 'https' && imageUri.scheme != 'http') {
      throw Exception('砂糖云返回了不支持的图片地址');
    }

    final response = await _dio.get<dynamic>(
      imageUri.toString(),
      cancelToken: cancelToken,
      onReceiveProgress: onProgress,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Accept': 'image/*'},
        // The generated image is public. Never forward the user's API token
        // to a URL returned inside a provider response.
        extra: {'skipAuth': true},
      ),
    );
    final data = response.data;
    final bytes = data is Uint8List
        ? data
        : data is List<int>
        ? Uint8List.fromList(data)
        : Uint8List(0);
    if (!_looksLikeImage(bytes)) {
      throw Exception('砂糖云返回的图片数据无效或不完整');
    }
    return bytes;
  }

  bool _looksLikeImage(Uint8List bytes) {
    if (bytes.length < 12) return false;
    final isPng =
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47;
    final isJpeg = bytes[0] == 0xFF && bytes[1] == 0xD8;
    final isGif =
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38;
    final isWebp =
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50;
    return isPng || isJpeg || isGif || isWebp;
  }

  /// 生成图像（可取消版本） - 保持向后兼容
  ///
  /// 注意: 此方法仅返回图像列表，不返回 Vibe 哈希映射
  /// 如需获取 Vibe 哈希，请直接使用 generateImage()
  Future<List<Uint8List>> generateImageCancellable(
    ImageParams params, {
    void Function(int, int)? onProgress,
    bool focusedInpaintEnabled = false,
    double minimumContextMegaPixels = 88.0,
    Rect? focusedSelectionRect,
  }) async {
    final result = await generateImage(
      params,
      onProgress: onProgress,
      focusedInpaintEnabled: focusedInpaintEnabled,
      minimumContextMegaPixels: minimumContextMegaPixels,
      focusedSelectionRect: focusedSelectionRect,
    );
    return result.$1; // 返回图像列表部分
  }

  Future<List<ImageGenerationArtifact>> generateImageArtifactsCancellable(
    ImageParams params, {
    void Function(int, int)? onProgress,
    bool focusedInpaintEnabled = false,
    double minimumContextMegaPixels = 88.0,
    Rect? focusedSelectionRect,
  }) async {
    final result = await _generateImageArtifacts(
      params,
      onProgress: onProgress,
      focusedInpaintEnabled: focusedInpaintEnabled,
      minimumContextMegaPixels: minimumContextMegaPixels,
      focusedSelectionRect: focusedSelectionRect,
    );
    return result.$1;
  }

  /// 取消当前生成
  void cancelGeneration() {
    final token = _currentCancelToken;
    // WARNING 级：release 文件日志可见，用于排查取消是否命中在途请求
    AppLogger.w(
      'cancelGeneration: hasInFlightToken=${token != null}',
      'ImgGen',
    );
    token?.cancel('User cancelled');
    _currentCancelToken = null;
  }

  // ==================== 流式图像生成 API ====================

  /// 流式生成图像（支持渐进式预览）
  ///
  /// [params] 图像生成参数
  ///
  /// 返回 ImageStreamChunk 流，包含渐进式预览和最终图像
  Stream<ImageStreamChunk> generateImageStream(
    ImageParams params, {
    bool focusedInpaintEnabled = false,
    double minimumContextMegaPixels = 88.0,
    Rect? focusedSelectionRect,
  }) {
    if (!_endpointService.current.supportsStreamingApi) {
      return Stream.value(
        ImageStreamChunk.error(
          'Streaming is not allowed by the configured provider',
        ),
      );
    }

    final cancelToken = CancelToken();
    _currentCancelToken = cancelToken;

    return _generateImageStreamWithToken(
      params,
      cancelToken: cancelToken,
      focusedInpaintEnabled: focusedInpaintEnabled,
      minimumContextMegaPixels: minimumContextMegaPixels,
      focusedSelectionRect: focusedSelectionRect,
    );
  }

  Stream<ImageStreamChunk> _generateImageStreamWithToken(
    ImageParams params, {
    required CancelToken cancelToken,
    bool focusedInpaintEnabled = false,
    double minimumContextMegaPixels = 88.0,
    Rect? focusedSelectionRect,
  }) async* {
    final pipelineStopwatch = Stopwatch()..start();
    final stageName = focusedInpaintEnabled
        ? 'FocusedInpaint'
        : 'NormalInpaint';

    if (_enablePipelineTracing) {
      AppLogger.i('[Pipeline:$stageName] ===== START =====', 'PipelineTrace');
    }

    if (cancelToken.isCancelled) {
      yield ImageStreamChunk.error('Cancelled');
      return;
    }

    final prepStopwatch = Stopwatch()..start();
    final focusedRequest = await _prepareFocusedInpaint(
      params,
      enabled: focusedInpaintEnabled,
      minimumContextMegaPixels: minimumContextMegaPixels,
      focusedSelectionRect: focusedSelectionRect,
    );
    prepStopwatch.stop();
    if (_enablePipelineTracing) {
      AppLogger.i(
        '[Pipeline:$stageName] _prepareFocusedInpaint: ${prepStopwatch.elapsedMilliseconds}ms',
        'PipelineTrace',
      );
    }

    final effectiveParams = _applyFocusedRequest(params, focusedRequest);

    // NovelAI 官方说明 Precise Reference 与 Vibe Transfer 不兼容。
    // 当前策略是保留 Precise Reference，并在请求构建阶段跳过 Vibe Transfer。
    final hasVibes = effectiveParams.hasVibeReferencesV4;
    if (hasVibes && effectiveParams.hasPreciseReferences) {
      AppLogger.d(
        'Both Vibe Transfer and Precise Reference are enabled (stream); skipping vibe payload in favor of Precise Reference',
        'ImgGen',
      );
    }

    // Precise Reference 仅 V4.5 模型支持，其他模型时忽略数据。
    final effectivePreciseRefs = effectiveParams.isV45Model
        ? effectiveParams.enabledPreciseReferences
        : <PreciseReference>[];

    try {
      if (cancelToken.isCancelled) {
        yield ImageStreamChunk.error('Cancelled');
        return;
      }

      final buildStopwatch = Stopwatch()..start();
      final requestBuildResult = await NAIImageRequestBuilder(
        params: effectiveParams,
        encodeVibe: _enhancementService.encodeVibe,
        preciseReferences: effectivePreciseRefs,
      ).build(sampler: effectiveParams.sampler, isStream: true);
      buildStopwatch.stop();
      if (_enablePipelineTracing) {
        AppLogger.i(
          '[Pipeline:$stageName] NAIImageRequestBuilder.build: ${buildStopwatch.elapsedMilliseconds}ms',
          'PipelineTrace',
        );
      }

      final seed = requestBuildResult.seed;
      final effectivePrompt = requestBuildResult.effectivePrompt;
      final effectiveNegativePrompt =
          requestBuildResult.effectiveNegativePrompt;
      final requestParameters = requestBuildResult.requestParameters;

      // 角色参考 (Precise Reference, V4+ 专属)
      if (effectivePreciseRefs.isNotEmpty) {
        AppLogger.d('=== CHARACTER REFERENCE DEBUG (STREAM) ===', 'ImgGen');
        AppLogger.d(
          'characterReferences count: ${effectivePreciseRefs.length}',
          'ImgGen',
        );
        AppLogger.d('isV4Model: ${effectiveParams.isV4Model}', 'ImgGen');

        final directorReferenceImages =
            requestParameters['director_reference_images'] as List? ?? const [];
        for (int i = 0; i < effectivePreciseRefs.length; i++) {
          final ref = effectivePreciseRefs[i];
          final encodedImageChars = i < directorReferenceImages.length
              ? (directorReferenceImages[i] as String).length
              : 0;
          AppLogger.d(
            'CharRef[$i] image: ${ref.image.length} bytes -> request base64: $encodedImageChars chars, type: ${ref.type}, strength: ${ref.strength}, fidelity: ${ref.fidelity}',
            'ImgGen',
          );
        }
      }

      // 构造请求数据（对齐官网格式）
      final requestData = requestBuildResult.requestData;

      // ========== 详细调试日志 ==========
      AppLogger.d('========== STREAM REQUEST DEBUG ==========', 'ImgGen');
      AppLogger.d('input (请求正面提示词): $effectivePrompt', 'ImgGen');
      AppLogger.d('model: ${effectiveParams.model}', 'ImgGen');
      AppLogger.d('action: ${effectiveParams.action.value}', 'ImgGen');
      AppLogger.d('seed: $seed', 'ImgGen');
      AppLogger.d('steps: ${effectiveParams.steps}', 'ImgGen');
      AppLogger.d('ucPreset: ${effectiveParams.ucPreset}', 'ImgGen');
      AppLogger.d('negative_prompt: $effectiveNegativePrompt', 'ImgGen');
      // 角色参考调试
      if (effectivePreciseRefs.isNotEmpty) {
        AppLogger.d('=== CHARACTER REFERENCE DEBUG ===', 'ImgGen');
        AppLogger.d(
          'characterReferences count: ${effectivePreciseRefs.length}',
          'ImgGen',
        );
        AppLogger.d(
          'director_reference_descriptions: ${jsonEncode(requestParameters['director_reference_descriptions'])}',
          'ImgGen',
        );
        AppLogger.d(
          'director_reference_information_extracted: ${requestParameters['director_reference_information_extracted']}',
          'ImgGen',
        );
        AppLogger.d(
          'director_reference_strength_values: ${requestParameters['director_reference_strength_values']}',
          'ImgGen',
        );
        AppLogger.d(
          'director_reference_secondary_strength_values: ${requestParameters['director_reference_secondary_strength_values']}',
          'ImgGen',
        );
        AppLogger.d(
          'normalize_reference_strength_multiple: ${requestParameters['normalize_reference_strength_multiple']}',
          'ImgGen',
        );
      }
      if (effectiveParams.isV4Model) {
        AppLogger.d(
          'v4_prompt: ${jsonEncode(requestParameters['v4_prompt'])}',
          'ImgGen',
        );
        AppLogger.d(
          'v4_negative_prompt: ${jsonEncode(requestParameters['v4_negative_prompt'])}',
          'ImgGen',
        );
      }
      // 打印完整请求 JSON（隐藏 base64 图像数据）
      final debugRequestData = Map<String, dynamic>.from(requestData);
      final debugParams = Map<String, dynamic>.from(
        debugRequestData['parameters'] as Map<String, dynamic>,
      );
      // 隐藏图像 base64 数据
      if (debugParams.containsKey('director_reference_images')) {
        final images = debugParams['director_reference_images'] as List;
        debugParams['director_reference_images'] = images
            .map((img) => '[BASE64_IMAGE_${(img as String).length}_chars]')
            .toList();
      }
      if (debugParams.containsKey('reference_image_multiple')) {
        final images = debugParams['reference_image_multiple'] as List;
        debugParams['reference_image_multiple'] = images
            .map((img) => '[BASE64_IMAGE_${(img as String).length}_chars]')
            .toList();
      }
      if (debugParams.containsKey('image')) {
        debugParams['image'] =
            '[BASE64_IMAGE_${(debugParams['image'] as String).length}_chars]';
      }
      debugRequestData['parameters'] = debugParams;
      AppLogger.d(
        'FULL REQUEST JSON (images hidden): ${jsonEncode(debugRequestData)}',
        'ImgGen',
      );
      AppLogger.d('==========================================', 'ImgGen');

      // 3. 发送流式请求
      final networkStopwatch = Stopwatch()..start();
      final requestSentStopwatch = Stopwatch();
      if (_enablePipelineTracing) {
        AppLogger.i(
          '[Pipeline:$stageName] Network request sending... (build_elapsed: ${buildStopwatch.elapsedMilliseconds}ms)',
          'PipelineTrace',
        );
      }

      final response = await _dio.post<ResponseBody>(
        _endpointService.imageUrl(ApiConstants.generateImageStreamEndpoint),
        data: requestData,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Accept': 'application/x-msgpack'},
        ),
      );
      networkStopwatch.stop();
      requestSentStopwatch.start(); // 开始计时"等待服务器"
      if (_enablePipelineTracing) {
        AppLogger.i(
          '[Pipeline:$stageName] Request sent, headers received: ${networkStopwatch.elapsedMilliseconds}ms',
          'PipelineTrace',
        );
      }

      // 4. 解析 MessagePack 流
      // NovelAI 流式格式：[4字节长度前缀(big-endian)] + [MessagePack数据]
      final responseStream = response.data!.stream;
      bool firstPreviewLogged = false;
      final firstPreviewStopwatch = Stopwatch()..start();
      final serverLatencyStopwatch = Stopwatch(); // 测量从请求到第一数据的延迟
      final buffer = <int>[];
      int messageCount = 0;
      final latestPreviews = <int, Uint8List>{};
      final completedSamples = <int>{};
      final expectedSamples = effectiveParams.nSamples <= 0
          ? 1
          : effectiveParams.nSamples;
      final int totalSteps = effectiveParams.steps;

      await for (final chunk in responseStream) {
        if (cancelToken.isCancelled) {
          yield ImageStreamChunk.error('Cancelled');
          return;
        }

        // 首次收到数据块时记录服务器延迟
        if (!serverLatencyStopwatch.isRunning) {
          serverLatencyStopwatch.start();
          if (_enablePipelineTracing) {
            AppLogger.i(
              '[Pipeline:$stageName] First data chunk received: ${requestSentStopwatch.elapsedMilliseconds}ms (server latency)',
              'PipelineTrace',
            );
          }
        }

        buffer.addAll(chunk);

        // 尝试解析完整的消息（带长度前缀）
        while (buffer.length >= 4) {
          // 读取 4 字节长度前缀 (big-endian)
          final msgLength =
              (buffer[0] << 24) |
              (buffer[1] << 16) |
              (buffer[2] << 8) |
              buffer[3];

          // 检查是否收到完整消息
          if (buffer.length < 4 + msgLength) {
            // 数据不完整，等待更多数据
            break;
          }

          // 提取 MessagePack 数据
          final msgBytes = Uint8List.fromList(buffer.sublist(4, 4 + msgLength));
          buffer.removeRange(0, 4 + msgLength);

          try {
            final decoded = msgpack.deserialize(msgBytes);
            messageCount++;

            if (decoded is Map) {
              // 转换 key 为字符串（msgpack 可能返回动态类型）
              final Map<String, dynamic> msg = {};
              decoded.forEach((key, value) {
                msg[key.toString()] = value;
              });

              // NovelAI 流式消息格式:
              // {event_type, samp_ix, step_ix, gen_id, sigma, image}
              final eventType = msg['event_type']?.toString();
              final sampleIndex = _optionalInt(msg['samp_ix']) ?? 0;
              final stepIx = _optionalInt(msg['step_ix']);
              final imageData = msg['image'];

              if (eventType == 'error' || msg.containsKey('error')) {
                final errorMessage =
                    msg['message'] ??
                    msg['error'] ??
                    'Stream generation failed';
                AppLogger.e('Stream error: $errorMessage', 'Stream');
                yield ImageStreamChunk.error(errorMessage.toString());
                return;
              }

              // 提取图像数据
              Uint8List? imageBytes;
              if (imageData is Uint8List) {
                imageBytes = imageData;
              } else if (imageData is List<int>) {
                imageBytes = Uint8List.fromList(imageData);
              } else if (imageData is String && imageData.isNotEmpty) {
                try {
                  imageBytes = Uint8List.fromList(base64Decode(imageData));
                } catch (e) {
                  AppLogger.w(
                    'Failed to decode base64 image data: $e',
                    'Stream',
                  );
                }
              }

              if (imageBytes != null && imageBytes.isNotEmpty) {
                if (eventType == 'final') {
                  final compositeStopwatch = Stopwatch()..start();
                  if (_enablePipelineTracing) {
                    AppLogger.i(
                      '[Pipeline:$stageName] Starting composite for final image, total_elapsed: ${pipelineStopwatch.elapsedMilliseconds}ms',
                      'PipelineTrace',
                    );
                  }

                  final compositedImage = await _compositeInpaintImage(
                    imageBytes,
                    params,
                    focusedRequest,
                    requestBuildResult,
                  );
                  compositeStopwatch.stop();

                  completedSamples.add(sampleIndex);
                  if (_enablePipelineTracing) {
                    AppLogger.i(
                      '[Pipeline:$stageName] Composite complete: ${compositeStopwatch.elapsedMilliseconds}ms (sample $sampleIndex)',
                      'PipelineTrace',
                    );
                    AppLogger.i(
                      '[Pipeline:$stageName] ===== SUMMARY ===== prepare:${prepStopwatch.elapsedMilliseconds}ms build:${buildStopwatch.elapsedMilliseconds}ms network:${networkStopwatch.elapsedMilliseconds}ms server_wait:${requestSentStopwatch.elapsedMilliseconds}ms preview_to_final:${firstPreviewStopwatch.elapsedMilliseconds - serverLatencyStopwatch.elapsedMilliseconds}ms composite:${compositeStopwatch.elapsedMilliseconds}ms TOTAL:${pipelineStopwatch.elapsedMilliseconds}ms',
                      'PipelineTrace',
                    );
                  }
                  AppLogger.d(
                    'Stream final: sample $sampleIndex, ${imageBytes.length} bytes',
                    'Stream',
                  );
                  yield ImageStreamChunk.complete(
                    compositedImage.displayImageBytes,
                    sampleIndex: sampleIndex,
                  );
                  continue;
                }

                if (eventType == null ||
                    eventType.isEmpty ||
                    eventType == 'intermediate') {
                  if (!firstPreviewLogged) {
                    firstPreviewLogged = true;
                    serverLatencyStopwatch.stop();
                    if (_enablePipelineTracing) {
                      AppLogger.i(
                        '[Pipeline:$stageName] First preview arrived: ${firstPreviewStopwatch.elapsedMilliseconds}ms (server_latency: ${serverLatencyStopwatch.elapsedMilliseconds}ms)',
                        'PipelineTrace',
                      );
                    }
                  }

                  final focusedPreviewPlacement = _inpaintPreviewPlacement(
                    params,
                    focusedRequest,
                    requestBuildResult,
                  );
                  latestPreviews[sampleIndex] = imageBytes;
                  final currentStep = (stepIx ?? messageCount) + 1;
                  final progress = currentStep / totalSteps;
                  AppLogger.d(
                    'Stream preview: sample $sampleIndex, step $currentStep/$totalSteps, ${imageBytes.length} bytes',
                    'Stream',
                  );
                  yield ImageStreamChunk.progress(
                    progress: progress.clamp(0.0, 0.99),
                    sampleIndex: sampleIndex,
                    currentStep: currentStep,
                    totalSteps: totalSteps,
                    previewImage: imageBytes,
                    focusedPreviewPlacement: focusedPreviewPlacement,
                  );
                } else {
                  AppLogger.d(
                    'Ignoring stream image for event_type=$eventType',
                    'Stream',
                  );
                }
              }
            }
          } catch (e) {
            AppLogger.w('Stream msg parse error: $e', 'Stream');
          }
        }
      }

      // 流结束后检查最终数据
      if (_enablePipelineTracing) {
        AppLogger.i(
          '[Pipeline:$stageName] Stream ended, prepare:${prepStopwatch.elapsedMilliseconds}ms build:${buildStopwatch.elapsedMilliseconds}ms server_wait:${requestSentStopwatch.elapsedMilliseconds}ms total:${pipelineStopwatch.elapsedMilliseconds}ms',
          'PipelineTrace',
        );
      }
      AppLogger.d(
        'Stream ended, buffer remaining: ${buffer.length} bytes, messages: $messageCount, completed_samples: ${completedSamples.length}/$expectedSamples',
        'Stream',
      );

      // 流结束但没有收到完成消息，尝试从 buffer 解析最终结果
      if (buffer.isNotEmpty) {
        try {
          final bytes = Uint8List.fromList(buffer);

          // 检查是否为 ZIP 格式（非流式回退）
          if (bytes.length > 4 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
            // ZIP 文件头 "PK"
            AppLogger.d('Stream fallback: parsing as ZIP', 'Stream');
            final compositeStopwatch = Stopwatch()..start();
            final images = ZipUtils.extractAllImages(bytes);
            if (images.isNotEmpty) {
              final compositedImage = await _compositeInpaintImage(
                images.first,
                params,
                focusedRequest,
                requestBuildResult,
              );
              compositeStopwatch.stop();
              if (_enablePipelineTracing) {
                AppLogger.i(
                  '[Pipeline:$stageName] ZIP fallback composite: ${compositeStopwatch.elapsedMilliseconds}ms TOTAL:${pipelineStopwatch.elapsedMilliseconds}ms',
                  'PipelineTrace',
                );
              }
              yield ImageStreamChunk.complete(
                compositedImage.displayImageBytes,
              );
              return;
            }
          }

          // 尝试作为带长度前缀的 MessagePack 解析
          if (bytes.length >= 4) {
            final msgLength =
                (bytes[0] << 24) |
                (bytes[1] << 16) |
                (bytes[2] << 8) |
                bytes[3];
            if (bytes.length >= 4 + msgLength) {
              final msgBytes = bytes.sublist(4, 4 + msgLength);
              final decoded = msgpack.deserialize(msgBytes);
              if (decoded is Map) {
                final Map<String, dynamic> msg = {};
                decoded.forEach((key, value) {
                  msg[key.toString()] = value;
                });
                if (msg.containsKey('data')) {
                  final data = msg['data'];
                  final compositeStopwatch = Stopwatch()..start();
                  final compositedImage = await _compositeInpaintImage(
                    data is Uint8List
                        ? data
                        : data is List<int>
                        ? Uint8List.fromList(data)
                        : data is String
                        ? Uint8List.fromList(base64Decode(data))
                        : Uint8List(0),
                    params,
                    focusedRequest,
                    requestBuildResult,
                  );
                  compositeStopwatch.stop();
                  if (_enablePipelineTracing) {
                    AppLogger.i(
                      '[Pipeline:$stageName] Fallback msgpack composite: ${compositeStopwatch.elapsedMilliseconds}ms TOTAL:${pipelineStopwatch.elapsedMilliseconds}ms',
                      'PipelineTrace',
                    );
                  }
                  yield ImageStreamChunk.complete(
                    compositedImage.displayImageBytes,
                  );
                  return;
                }
              }
            }
          }

          yield ImageStreamChunk.error('No final image received from stream');
        } catch (e) {
          AppLogger.e('Failed to parse final stream data: $e', 'Stream');
          yield ImageStreamChunk.error('Failed to parse response');
        }
      } else if (completedSamples.length < expectedSamples) {
        AppLogger.w(
          'Stream ended without final image for all samples '
              '(${completedSamples.length}/$expectedSamples); '
              'previews=${latestPreviews.length}',
          'Stream',
        );
        yield ImageStreamChunk.error('No final image received from stream');
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        yield ImageStreamChunk.error('Cancelled');
      } else {
        String errorMsg;
        // 尝试读取流式响应的错误内容
        if (e.response?.data is ResponseBody) {
          try {
            final responseBody = e.response!.data as ResponseBody;
            final chunks = <int>[];
            await for (final chunk in responseBody.stream) {
              chunks.addAll(chunk);
            }
            final text = utf8.decode(chunks, allowMalformed: true);
            AppLogger.e('Stream API error response: $text', 'ImgGen');
            try {
              final json = jsonDecode(text);
              if (json is Map) {
                errorMsg =
                    'API_ERROR_${e.response?.statusCode}|${json['message'] ?? json['error'] ?? text}';
              } else {
                errorMsg = 'API_ERROR_${e.response?.statusCode}|$text';
              }
            } catch (jsonError) {
              AppLogger.w('Failed to parse error JSON: $jsonError', 'ImgGen');
              errorMsg = 'API_ERROR_${e.response?.statusCode}|$text';
            }
          } catch (readError) {
            AppLogger.e('Failed to read error response: $readError', 'ImgGen');
            errorMsg = NAIApiUtils.formatDioError(e);
          }
        } else {
          errorMsg = NAIApiUtils.formatDioError(e);
        }
        AppLogger.e('Stream generation failed: $errorMsg', 'ImgGen');
        yield ImageStreamChunk.error(errorMsg);
      }
    } catch (e) {
      AppLogger.e('Stream generation failed: $e', 'ImgGen');
      yield ImageStreamChunk.error(e.toString());
    } finally {
      if (identical(_currentCancelToken, cancelToken)) {
        _currentCancelToken = null;
      }
    }
  }

  Future<FocusedInpaintRequest?> _prepareFocusedInpaint(
    ImageParams params, {
    required bool enabled,
    required double minimumContextMegaPixels,
    Rect? focusedSelectionRect,
  }) async {
    if (!enabled ||
        params.action != ImageGenerationAction.infill ||
        params.sourceImage == null ||
        params.maskImage == null) {
      return null;
    }

    final request = await FocusedInpaintUtils.prepareRequestAsync(
      sourceImage: params.sourceImage!,
      maskImage: params.maskImage!,
      focusedSelectionRect: focusedSelectionRect,
      minContextMegaPixels: minimumContextMegaPixels,
    );

    if (request != null) {
      AppLogger.d(
        'Focused inpaint prepared: crop=${request.crop.x},${request.crop.y},${request.crop.width}x${request.crop.height}, target=${request.targetWidth}x${request.targetHeight}, minContextArea=${minimumContextMegaPixels.round()}, focusRect=$focusedSelectionRect',
        'ImgGen',
      );
    }

    return request;
  }

  ImageParams _applyFocusedRequest(
    ImageParams params,
    FocusedInpaintRequest? focusedRequest,
  ) {
    if (focusedRequest == null) {
      return params;
    }

    return params.copyWith(
      sourceImage: focusedRequest.requestSourceImage,
      maskImage: focusedRequest.requestMaskImage,
      width: focusedRequest.targetWidth,
      height: focusedRequest.targetHeight,
    );
  }

  FocusedStreamPreviewPlacement? _inpaintPreviewPlacement(
    ImageParams params,
    FocusedInpaintRequest? focusedRequest,
    NAIImageRequestBuildResult requestBuildResult,
  ) {
    if (params.action != ImageGenerationAction.infill || params.isOutpaint) {
      return null;
    }

    final compositeMaskBytes =
        requestBuildResult.inpaintMaskArtifacts?.compositeMaskBytes;
    if (compositeMaskBytes == null) {
      return null;
    }

    if (focusedRequest == null) {
      final normalizedSource = requestBuildResult.normalizedSourceImageBytes;
      if (normalizedSource == null) {
        return null;
      }
      return FocusedStreamPreviewPlacement(
        sourceImage: normalizedSource,
        maskImage: compositeMaskBytes,
        xPercent: 0,
        yPercent: 0,
        widthPercent: 1,
        heightPercent: 1,
      );
    }

    final originalSource = params.sourceImage;
    final sourceWidth = focusedRequest.originalSourceWidth;
    final sourceHeight = focusedRequest.originalSourceHeight;
    if (originalSource == null || sourceWidth <= 0 || sourceHeight <= 0) {
      return null;
    }

    return FocusedStreamPreviewPlacement(
      sourceImage: originalSource,
      maskImage: compositeMaskBytes,
      xPercent: focusedRequest.crop.x / sourceWidth,
      yPercent: focusedRequest.crop.y / sourceHeight,
      widthPercent: focusedRequest.crop.width / sourceWidth,
      heightPercent: focusedRequest.crop.height / sourceHeight,
    );
  }

  Future<List<ImageGenerationArtifact>> _compositeInpaintImages(
    List<Uint8List> images,
    ImageParams params,
    FocusedInpaintRequest? focusedRequest,
    NAIImageRequestBuildResult requestBuildResult,
  ) {
    // Future.wait 保持顺序；并发由 ComputeGate 统一背压。
    return Future.wait(
      images.map(
        (imageBytes) => _compositeInpaintImage(
          imageBytes,
          params,
          focusedRequest,
          requestBuildResult,
        ),
      ),
    );
  }

  /// 收尾贴回合成。重活（mask 构建 + 整图混合 + PNG 编码）在后台
  /// isolate 完成；闭包只捕获原始字节与数值，避免捕获 Freezed 对象
  /// （Windows 上 Isolate.run 与 Freezed 存在序列化兼容性问题）。
  Future<ImageGenerationArtifact> _compositeInpaintImage(
    Uint8List imageBytes,
    ImageParams params,
    FocusedInpaintRequest? focusedRequest,
    NAIImageRequestBuildResult requestBuildResult,
  ) {
    final maskArtifacts = requestBuildResult.inpaintMaskArtifacts;
    if (focusedRequest != null) {
      if (maskArtifacts == null) {
        return Future.value(
          ImageGenerationArtifact(displayImageBytes: imageBytes),
        );
      }
      return focusedRequest.composeGeneratedImageArtifactAsync(
        imageBytes,
        maskArtifacts,
      );
    }
    if (params.isOutpaint) {
      return Future.value(
        ImageGenerationArtifact(displayImageBytes: imageBytes),
      );
    }
    final sourceImage = requestBuildResult.normalizedSourceImageBytes;
    if (params.action != ImageGenerationAction.infill ||
        sourceImage == null ||
        maskArtifacts == null) {
      return Future.value(
        ImageGenerationArtifact(displayImageBytes: imageBytes),
      );
    }

    return ComputeGate().runIsolate(() {
      return InpaintMaskUtils.composeGeneratedImageArtifact(
        normalizedSourceImage: sourceImage,
        compositeMaskImage: maskArtifacts.compositeMaskBytes,
        generatedImage: imageBytes,
      );
    });
  }

  int? _optionalInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }
}

/// NAIImageGenerationApiService Provider
///
/// keepAlive：服务持有进行中请求的 `_currentCancelToken`，
/// cancelGeneration() 必须命中发起请求的同一实例，否则取消落空。
@Riverpod(keepAlive: true)
NAIImageGenerationApiService naiImageGenerationApiService(Ref ref) {
  // 生成请求必须可中断（释放 NAI 并发额度），使用 HTTP/1.1 专用客户端
  final dio = ref.watch(imageGenerationDioClientProvider);
  final enhancementService = ref.watch(naiImageEnhancementApiServiceProvider);
  final endpointService = ref.watch(naiApiEndpointServiceProvider);
  final secureStorage = ref.watch(secureStorageServiceProvider);
  return NAIImageGenerationApiService(
    dio,
    enhancementService,
    endpointService,
    accessTokenProvider: secureStorage.getAccessToken,
  );
}
