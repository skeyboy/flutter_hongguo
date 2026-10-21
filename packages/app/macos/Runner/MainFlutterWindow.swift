import Cocoa
import FlutterMacOS
import AVKit

class MainFlutterWindow: NSWindow {
  private var normalChrome: (NSWindow.TitleVisibility, Bool, Bool, [Bool])?
  private var immersive = false

  // Retain the same Flutter engine, routes, downloads and player when closing.
  override func performClose(_ sender: Any?) { orderOut(sender) }

  func setImmersive(_ value: Bool) {
    guard value != immersive else { return }
    let frame = self.frame
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
    if value {
      normalChrome = (titleVisibility, titlebarAppearsTransparent,
                      styleMask.contains(.fullSizeContentView),
                      buttons.map { standardWindowButton($0)?.isHidden ?? false })
      titleVisibility = .hidden
      titlebarAppearsTransparent = true
      styleMask.insert(.fullSizeContentView)
      buttons.forEach { standardWindowButton($0)?.isHidden = true }
    } else if let original = normalChrome {
      titleVisibility = original.0
      titlebarAppearsTransparent = original.1
      if !original.2 { styleMask.remove(.fullSizeContentView) }
      for (i, type) in buttons.enumerated() { standardWindowButton(type)?.isHidden = original.3[i] }
      normalChrome = nil
    }
    immersive = value
    setFrame(frame, display: true)
  }

  private func registerWindowChannel(_ controller: FlutterViewController) {
    let channel = FlutterMethodChannel(name: "hongguo/macos-window", binaryMessenger: controller.engine.binaryMessenger)
    (NSApp.delegate as? AppDelegate)?.windowChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      let app = NSApp.delegate as? AppDelegate
      switch call.method {
      case "configure": app?.settingsAvailable = call.arguments as? Bool ?? false; result(nil)
      case "immersive": self.setImmersive(call.arguments as? Bool ?? false); result(nil)
      case "show": app?.showWindow(nil); result(nil)
      case "hide": self.performClose(nil); result(nil)
      case "minimize": self.miniaturize(nil); result(nil)
      case "drag":
        if let event = self.currentEvent { self.performDrag(with: event) }
        result(nil)
      case "state":
        result(["visible": self.isVisible, "miniaturized": self.isMiniaturized,
                "immersive": self.immersive, "titleHidden": self.titleVisibility == .hidden,
                "fullSizeContent": self.styleMask.contains(.fullSizeContentView),
                "closeHidden": self.standardWindowButton(.closeButton)?.isHidden ?? false,
                "statusItem": app?.hasStatusItem ?? false,
                "statusClickRestores": app?.statusClickRestoresWindow ?? true,
                "menu": app?.statusMenu().items.map { $0.title } ?? [],
                "contentHeight": self.contentView?.bounds.height ?? 0, "frameHeight": self.frame.height])
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    self.title = Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String ?? "Hongguo"
    RegisterGeneratedPlugins(registry: flutterViewController)
    registerWindowChannel(flutterViewController)
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
  private var completionReported = false
  private var source = ""

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
      self.source = source
      completionReported = false
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
      observeEnding(next.currentItem)
      DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
        if self?.pending != nil && self?.player === next { self?.fail("画中画暂未就绪，请重试") }
      }
    } else if call.method == "replace" {
      guard let player = player, pip?.isPictureInPictureActive == true,
            let data = call.arguments as? [String: Any], let source = data["source"] as? String,
            let url = URL(string: source), url.isFileURL else { result(false); return }
      self.source = source; completionReported = false
      playbackRate = (data["rate"] as? NSNumber)?.floatValue ?? playbackRate
      player.volume = (data["volume"] as? NSNumber)?.floatValue ?? player.volume
      let item = AVPlayerItem(url: url)
      observeEnding(item)
      player.replaceCurrentItem(with: item)
      let milliseconds = (data["position"] as? NSNumber)?.int64Value ?? 0
      player.seek(to: CMTime(value: milliseconds, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
      if data["playing"] as? Bool == true { player.playImmediately(atRate: playbackRate) }
      sendProgress(); result(true)
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
  private func observeEnding(_ item: AVPlayerItem?) {
    if let token = ending { NotificationCenter.default.removeObserver(token) }
    ending = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] note in
      guard let self = self, let finished = note.object as? AVPlayerItem,
            finished === self.player?.currentItem, !self.completionReported else { return }
      self.completionReported = true
      self.sendProgress()
      self.channel.invokeMethod("completed", arguments: ["source": self.source])
    }
  }
  private func sendProgress() {
    let seconds = player?.currentTime().seconds ?? 0
    channel.invokeMethod("progress", arguments: ["position": seconds.isFinite ? Int(seconds * 1000) : 0,
      "playing": (player?.rate ?? 0) > 0, "source": source])
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
    let unreportedEnd = ended && !completionReported
    let restoredSource = source
    clean()
    channel.invokeMethod("restore", arguments: ["position": seconds.isFinite ? Int(seconds * 1000) : 0,
      "playing": playing, "ended": unreportedEnd, "source": restoredSource])
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
