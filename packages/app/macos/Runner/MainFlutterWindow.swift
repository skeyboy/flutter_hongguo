import Cocoa
import FlutterMacOS
import AVKit

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    self.title = Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String ?? "Hongguo"
    RegisterGeneratedPlugins(registry: flutterViewController)
    HongguoMacPictureInPicture.register(with: flutterViewController.registrar(forPlugin: "HongguoMacPictureInPicture"))

    super.awakeFromNib()
  }
}

// Hand over only the already-decrypted local MP4; never stream credentials.
private final class HongguoMacPictureInPicture: NSObject, FlutterPlugin, AVPictureInPictureControllerDelegate {
  private let channel: FlutterMethodChannel
  private var player: AVPlayer?
  private var layer: AVPlayerLayer?
  private var surface: NSView?
  private var pip: AVPictureInPictureController?
  private var observation: NSKeyValueObservation?
  private var periodic: Any?
  private var ending: NSObjectProtocol?
  private var pending: FlutterResult?
  private weak var owner: NSWindow?
  private var playbackRate: Float = 1

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "hongguo/platform-playback", binaryMessenger: registrar.messenger)
    let plugin = HongguoMacPictureInPicture(channel)
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }
  init(_ channel: FlutterMethodChannel) { self.channel = channel; super.init() }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "available" {
      result(AVPictureInPictureController.isPictureInPictureSupported()); return
    }
    if call.method == "enter" {
      guard AVPictureInPictureController.isPictureInPictureSupported(), pip == nil,
            let data = call.arguments as? [String: Any], let source = data["source"] as? String,
            let url = URL(string: source), url.isFileURL,
            let window = NSApp.windows.first(where: { $0.contentViewController is FlutterViewController }),
            let content = window.contentView else {
        result(FlutterError(code: "pip_unavailable", message: "System Picture in Picture is unavailable", details: nil)); return
      }
      owner = window
      let next = AVPlayer(url: url)
      let view = NSView(frame: content.bounds)
      view.autoresizingMask = [.width, .height]
      view.wantsLayer = true
      view.layer?.backgroundColor = NSColor.black.cgColor
      let display = AVPlayerLayer(player: next)
      display.frame = view.bounds; display.videoGravity = .resizeAspect
      view.layer?.addSublayer(display); content.addSubview(view)
      next.volume = (data["volume"] as? NSNumber)?.floatValue ?? 1
      playbackRate = (data["rate"] as? NSNumber)?.floatValue ?? 1
      guard let controller = AVPictureInPictureController(playerLayer: display) else {
        view.removeFromSuperview(); result(false); return
      }
      player = next; surface = view; layer = display; pip = controller; pending = result
      controller.delegate = self
      let milliseconds = (data["position"] as? NSNumber)?.int64Value ?? 0
      next.seek(to: CMTime(value: milliseconds, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
      if data["playing"] as? Bool == true { next.playImmediately(atRate: playbackRate) }
      observation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { controller, _ in
        if controller.isPictureInPicturePossible { DispatchQueue.main.async { controller.startPictureInPicture() } }
      }
      periodic = next.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
        self?.sendProgress()
      }
      ending = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: next.currentItem, queue: .main) { [weak self] _ in
        self?.pip?.stopPictureInPicture()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
        if self?.pending != nil && self?.player === next { self?.fail("画中画暂未就绪，请重试") }
      }
    } else if call.method == "dispose" {
      pending?(FlutterError(code: "pip_closed", message: "Player closed", details: nil)); pending = nil
      pip?.delegate = nil; pip?.stopPictureInPicture(); clean(); result(nil)
    } else if call.method == "exit" {
      if pip?.isPictureInPictureActive == true { pip?.stopPictureInPicture() }
      else { restore() }
      result(nil)
    } else if call.method == "control" {
      let data = call.arguments as? [String: Any]
      switch data?["action"] as? String {
      case "play": player?.playImmediately(atRate: playbackRate)
      case "pause": player?.pause()
      case "seek": player?.seek(to: CMTime(value: (data?["position"] as? NSNumber)?.int64Value ?? 0, timescale: 1000))
      default: break
      }
      sendProgress(); result(nil)
    } else { result(FlutterMethodNotImplemented) }
  }
  private func sendProgress() {
    let seconds = player?.currentTime().seconds ?? 0
    channel.invokeMethod("progress", arguments: ["position": seconds.isFinite ? Int(seconds * 1000) : 0,
      "playing": (player?.rate ?? 0) > 0])
  }
  private func clean() {
    observation?.invalidate(); observation = nil
    if let token = periodic { player?.removeTimeObserver(token) }; periodic = nil
    if let token = ending { NotificationCenter.default.removeObserver(token) }; ending = nil
    player?.pause(); player = nil; pip = nil; layer?.removeFromSuperlayer(); layer = nil
    surface?.removeFromSuperview(); surface = nil
  }
  private func restore() {
    let seconds = player?.currentTime().seconds ?? 0
    let playing = (player?.rate ?? 0) > 0
    let duration = player?.currentItem?.duration.seconds ?? 0
    let ended = duration.isFinite && duration > 0 && seconds >= duration - 0.25
    clean()
    channel.invokeMethod("restore", arguments: ["position": seconds.isFinite ? Int(seconds * 1000) : 0,
      "playing": playing, "ended": ended])
  }
  private func fail(_ message: String) {
    let result = pending; pending = nil; clean()
    result?(FlutterError(code: "pip_unavailable", message: message, details: nil))
  }
  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    observation?.invalidate(); observation = nil
    surface?.isHidden = true
    let result = pending; pending = nil; result?(true)
  }
  func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    fail("系统无法启动画中画")
  }
  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) { if controller === pip { restore() } }
  func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    owner?.deminiaturize(nil)
    owner?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    completionHandler(true)
  }
}
