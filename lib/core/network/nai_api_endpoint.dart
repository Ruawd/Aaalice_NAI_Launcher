import '../constants/api_constants.dart';

/// Request/response dialect exposed by a configured image provider.
enum NaiApiProviderType {
  /// A server that mirrors NovelAI's endpoint layout and ZIP/MessagePack
  /// responses.
  novelAiCompatible,

  /// Sugar Cloud's NovelAI-compatible adapter.
  ///
  /// `/novelai` accepts the complete NovelAI generation payload (including
  /// img2img, inpaint and reference parameters). Its response can be JSON or
  /// a task-event stream and normally points at the generated image instead
  /// of returning NovelAI's ZIP directly.
  shatangyun,
}

/// NAI-compatible API endpoint configuration.
///
/// Official NovelAI uses separate main and image API hosts. Third-party
/// compatible sites often expose both sets of endpoints under one base URL, so
/// [fromInput] falls back to [mainBaseUrl] when [imageBaseUrl] is omitted.
class NaiApiEndpointConfig {
  final String mainBaseUrl;
  final String imageBaseUrl;
  final bool supportsSubscriptionApi;
  final bool supportsStreamingApi;
  final NaiApiProviderType providerType;

  const NaiApiEndpointConfig({
    required this.mainBaseUrl,
    required this.imageBaseUrl,
    this.supportsSubscriptionApi = true,
    this.supportsStreamingApi = true,
    this.providerType = NaiApiProviderType.novelAiCompatible,
  });

  static const official = NaiApiEndpointConfig(
    mainBaseUrl: ApiConstants.baseUrl,
    imageBaseUrl: ApiConstants.imageBaseUrl,
  );

  factory NaiApiEndpointConfig.fromInput({
    required String mainBaseUrl,
    String? imageBaseUrl,
    bool supportsSubscriptionApi = true,
    bool supportsStreamingApi = true,
    NaiApiProviderType providerType = NaiApiProviderType.novelAiCompatible,
  }) {
    var normalizedMain = _normalizeBaseUrl(mainBaseUrl);
    final normalizedImage = imageBaseUrl == null || imageBaseUrl.trim().isEmpty
        ? normalizedMain
        : _normalizeBaseUrl(imageBaseUrl);

    if (providerType == NaiApiProviderType.shatangyun) {
      final configuredEndpoint =
          !_looksLikeShatangyunUrl(normalizedMain) &&
              _looksLikeShatangyunUrl(normalizedImage)
          ? normalizedImage
          : normalizedMain;
      normalizedMain = _normalizeShatangyunEndpoint(configuredEndpoint);
      return NaiApiEndpointConfig(
        mainBaseUrl: normalizedMain,
        imageBaseUrl: normalizedMain,
        supportsSubscriptionApi: false,
        supportsStreamingApi: false,
        providerType: providerType,
      );
    }

    return NaiApiEndpointConfig(
      mainBaseUrl: normalizedMain,
      imageBaseUrl: normalizedImage,
      supportsSubscriptionApi: supportsSubscriptionApi,
      supportsStreamingApi: supportsStreamingApi,
      providerType: providerType,
    );
  }

  factory NaiApiEndpointConfig.fromJson(Map<String, dynamic> json) {
    final mainBaseUrl = json['mainBaseUrl'] as String? ?? ApiConstants.baseUrl;
    final imageBaseUrl =
        json['imageBaseUrl'] as String? ?? ApiConstants.imageBaseUrl;
    final providerType =
        _providerTypeFromJson(json['providerType']) ??
        inferProviderType(mainBaseUrl, imageBaseUrl: imageBaseUrl);

    return NaiApiEndpointConfig.fromInput(
      mainBaseUrl: mainBaseUrl,
      imageBaseUrl: imageBaseUrl,
      supportsSubscriptionApi: json['supportsSubscriptionApi'] as bool? ?? true,
      supportsStreamingApi: json['supportsStreamingApi'] as bool? ?? true,
      providerType: providerType,
    );
  }

  Map<String, dynamic> toJson() => {
    'mainBaseUrl': mainBaseUrl,
    'imageBaseUrl': imageBaseUrl,
    'supportsSubscriptionApi': supportsSubscriptionApi,
    'supportsStreamingApi': supportsStreamingApi,
    'providerType': providerType.name,
  };

  bool get isOfficial =>
      mainBaseUrl == ApiConstants.baseUrl &&
      imageBaseUrl == ApiConstants.imageBaseUrl &&
      supportsSubscriptionApi &&
      supportsStreamingApi &&
      providerType == NaiApiProviderType.novelAiCompatible;

  bool get isThirdParty => !isOfficial;

  bool get isShatangyun => providerType == NaiApiProviderType.shatangyun;

  /// Full image generation endpoint for providers that do not expose a base
  /// URL plus NovelAI paths.
  String get imageGenerationUrl =>
      isShatangyun ? mainBaseUrl : imageUrl(ApiConstants.generateImageEndpoint);

  /// Sugar Cloud's browser task endpoint.
  ///
  /// The full `/novelai` adapter is preferred for normal requests. Raw Vibe
  /// images are the one provider-specific case that must use `/generate`,
  /// because Sugar Cloud performs their Vibe encoding inside that task flow.
  String get shatangyunTaskGenerationUrl {
    if (!isShatangyun) return imageGenerationUrl;
    final uri = Uri.parse(mainBaseUrl);
    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    if (path.toLowerCase().endsWith('/novelai')) {
      path = '${path.substring(0, path.length - '/novelai'.length)}/generate';
    } else if (!path.toLowerCase().endsWith('/generate')) {
      path = '$path/generate';
    }
    return uri.replace(path: path).toString();
  }

  String mainUrl(String endpoint) => _appendEndpoint(mainBaseUrl, endpoint);

  String imageUrl(String endpoint) => _appendEndpoint(imageBaseUrl, endpoint);

  /// Official user endpoints are served by the image API host.
  ///
  /// This includes `/user/login`, `/user/information`, `/user/data`, and
  /// `/user/subscription`. NAI-compatible third-party sites keep using
  /// [mainBaseUrl] because their endpoint layout is provider-specific.
  String userUrl(String endpoint) {
    return isOfficial ? imageUrl(endpoint) : mainUrl(endpoint);
  }

  /// Conservative local subscription state for generation-only gateways.
  ///
  /// Some NAI-compatible providers only implement image endpoints. They can
  /// still be used without fabricating an Opus entitlement or a positive
  /// Anlas balance in the client.
  Map<String, dynamic> get compatibilitySubscriptionInfo => {
    'tier': 0,
    'active': true,
    'trainingStepsLeft': {
      'fixedTrainingStepsLeft': 0,
      'purchasedTrainingSteps': 0,
    },
    'perks': {'imageGeneration': true, 'unlimitedImageGeneration': false},
  };

  static String _appendEndpoint(String baseUrl, String endpoint) {
    final normalizedEndpoint = endpoint.startsWith('/')
        ? endpoint
        : '/$endpoint';
    return '$baseUrl$normalizedEndpoint';
  }

  /// Detect legacy beta records where Sugar Cloud was saved before provider
  /// dialects were persisted. This makes existing accounts work after upgrade
  /// without requiring the user to remove and add them again.
  static NaiApiProviderType inferProviderType(
    String mainBaseUrl, {
    String? imageBaseUrl,
  }) {
    if (_looksLikeShatangyunUrl(mainBaseUrl) ||
        (imageBaseUrl != null && _looksLikeShatangyunUrl(imageBaseUrl))) {
      return NaiApiProviderType.shatangyun;
    }
    return NaiApiProviderType.novelAiCompatible;
  }

  static bool _looksLikeShatangyunUrl(String value) {
    final uri = Uri.tryParse(_withDefaultScheme(value.trim()));
    if (uri == null || uri.host.toLowerCase() != 'std.loliyc.com') {
      return false;
    }
    final path = uri.path.replaceAll(RegExp(r'/+$'), '').toLowerCase();
    return path.endsWith('/novelai') ||
        path.endsWith('/api/generate') ||
        path.endsWith('/generate');
  }

  static NaiApiProviderType? _providerTypeFromJson(Object? value) {
    final name = value?.toString();
    if (name == null || name.isEmpty) return null;
    for (final type in NaiApiProviderType.values) {
      if (type.name == name) return type;
    }
    return null;
  }

  static String _normalizeShatangyunEndpoint(String value) {
    final uri = Uri.parse(value);
    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    final lowerPath = path.toLowerCase();
    if (lowerPath.endsWith('/api/generate')) {
      path =
          '${path.substring(0, path.length - '/api/generate'.length)}/novelai';
    } else if (lowerPath.endsWith('/generate')) {
      path = '${path.substring(0, path.length - '/generate'.length)}/novelai';
    } else if (!lowerPath.endsWith('/novelai')) {
      path = '$path/novelai';
    }
    return uri.replace(path: path).toString();
  }

  static String _normalizeBaseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('API 地址不能为空');
    }

    final withScheme = _withDefaultScheme(trimmed);
    final uri = Uri.tryParse(withScheme);
    if (uri == null || !uri.hasAuthority) {
      throw ArgumentError('API 地址无效');
    }

    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ArgumentError('仅支持 http 或 https API 地址');
    }

    if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) {
      throw ArgumentError('API 地址不能包含查询参数、片段或用户信息');
    }

    final path = uri.path.replaceAll(RegExp(r'/+$'), '');
    return uri.replace(path: path.isEmpty ? '' : path).toString();
  }

  static String _withDefaultScheme(String value) {
    if (value.contains('://')) {
      return value;
    }

    final hostPart = value.split('/').first.toLowerCase();
    final isLocalHost =
        hostPart == 'localhost' ||
        hostPart.startsWith('localhost:') ||
        hostPart == '127.0.0.1' ||
        hostPart.startsWith('127.0.0.1:') ||
        hostPart == '[::1]' ||
        hostPart.startsWith('[::1]:');

    return '${isLocalHost ? 'http' : 'https'}://$value';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NaiApiEndpointConfig &&
          runtimeType == other.runtimeType &&
          mainBaseUrl == other.mainBaseUrl &&
          imageBaseUrl == other.imageBaseUrl &&
          supportsSubscriptionApi == other.supportsSubscriptionApi &&
          supportsStreamingApi == other.supportsStreamingApi &&
          providerType == other.providerType;

  @override
  int get hashCode => Object.hash(
    mainBaseUrl,
    imageBaseUrl,
    supportsSubscriptionApi,
    supportsStreamingApi,
    providerType,
  );

  @override
  String toString() {
    return 'NaiApiEndpointConfig(mainBaseUrl: $mainBaseUrl, '
        'imageBaseUrl: $imageBaseUrl, '
        'supportsSubscriptionApi: $supportsSubscriptionApi, '
        'supportsStreamingApi: $supportsStreamingApi, '
        'providerType: ${providerType.name})';
  }
}
