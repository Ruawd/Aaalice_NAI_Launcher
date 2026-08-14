import Flutter
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    PhotoLibraryChannel.register(with: engineBridge.pluginRegistry)
  }
}

private enum PhotoLibraryChannel {
  private static let channelName = "com.nailauncher/photo_library"
  private static var channel: FlutterMethodChannel?

  static func register(with registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "NAIPhotoLibraryChannel") else {
      return
    }
    let methodChannel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    methodChannel.setMethodCallHandler { call, result in
      handle(call, result: result)
    }
    channel = methodChannel
  }

  private static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "hasAccess":
      result(hasAddAccess)
    case "requestAccess":
      requestAddAccess(result: result)
    case "saveImage":
      saveImage(call: call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static var hasAddAccess: Bool {
    if #available(iOS 14, *) {
      let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
      return status == .authorized || status == .limited
    }
    return PHPhotoLibrary.authorizationStatus() == .authorized
  }

  private static func requestAddAccess(result: @escaping FlutterResult) {
    if hasAddAccess {
      result(true)
      return
    }

    if #available(iOS 14, *) {
      PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
        DispatchQueue.main.async {
          result(hasAddAccess)
        }
      }
    } else {
      PHPhotoLibrary.requestAuthorization { _ in
        DispatchQueue.main.async {
          result(hasAddAccess)
        }
      }
    }
  }

  private static func saveImage(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard hasAddAccess else {
      result(flutterError(code: "ACCESS_DENIED", message: "Photos add access is denied."))
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let typedData = arguments["bytes"] as? FlutterStandardTypedData,
      !typedData.data.isEmpty,
      let fileExtension = imageFileExtension(for: typedData.data)
    else {
      result(
        flutterError(
          code: "NOT_SUPPORTED_FORMAT",
          message: "The supplied image format is not supported by Photos."
        )
      )
      return
    }

    let requestedName = (arguments["name"] as? String)?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let assetName: String
    if let requestedName = requestedName, !requestedName.isEmpty {
      assetName = requestedName
    } else {
      assetName = "nai_\(Int(Date().timeIntervalSince1970 * 1000))"
    }
    let imageData = typedData.data

    PHPhotoLibrary.shared().performChanges({
      let request = PHAssetCreationRequest.forAsset()
      let options = PHAssetResourceCreationOptions()
      options.originalFilename = "\(assetName).\(fileExtension)"
      request.addResource(with: .photo, data: imageData, options: options)
    }) { success, error in
      DispatchQueue.main.async {
        if success {
          result(true)
        } else {
          result(photoLibraryError(error))
        }
      }
    }
  }

  private static func imageFileExtension(for data: Data) -> String? {
    let bytes = [UInt8](data.prefix(16))
    if bytes.count >= 8
      && Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    {
      return "png"
    }
    if bytes.count >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
      return "jpg"
    }
    if bytes.count >= 6 {
      let signature = String(bytes: bytes[0..<6], encoding: .ascii)
      if signature == "GIF87a" || signature == "GIF89a" {
        return "gif"
      }
    }
    if bytes.count >= 12 {
      let riff = String(bytes: bytes[0..<4], encoding: .ascii)
      let webp = String(bytes: bytes[8..<12], encoding: .ascii)
      if riff == "RIFF" && webp == "WEBP" {
        return "webp"
      }
      let boxType = String(bytes: bytes[4..<12], encoding: .ascii) ?? ""
      if boxType.hasPrefix("ftypheic") || boxType.hasPrefix("ftypheix")
        || boxType.hasPrefix("ftyphevc") || boxType.hasPrefix("ftyphevx")
        || boxType.hasPrefix("ftypmif1") || boxType.hasPrefix("ftypmsf1")
      {
        return "heic"
      }
    }
    return nil
  }

  private static func photoLibraryError(_ error: Error?) -> FlutterError {
    guard let error = error else {
      return flutterError(code: "UNEXPECTED", message: "Photos did not save the image.")
    }
    let nsError = error as NSError

    // PHPhotosError values are stable across supported iOS releases.
    switch nsError.code {
    case 3305:
      return flutterError(code: "NOT_ENOUGH_SPACE", message: nsError.localizedDescription)
    case 3302, 3306:
      return flutterError(code: "NOT_SUPPORTED_FORMAT", message: nsError.localizedDescription)
    case 3310, 3311:
      return flutterError(code: "ACCESS_DENIED", message: nsError.localizedDescription)
    default:
      return flutterError(code: "UNEXPECTED", message: nsError.localizedDescription)
    }
  }

  private static func flutterError(code: String, message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }
}
