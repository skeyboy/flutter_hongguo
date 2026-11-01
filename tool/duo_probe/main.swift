// iPhone Duo 折叠感知探针：在 iOS 27.1 模拟器/真机上读取一手 API 读数并按行打印 JSON。
// 每 250ms 采一次样，用于同时观测「换姿势后各读数的生效时序」。
// 用法见同目录 build_and_run.sh。
import UIKit

func rectInfo(_ r: CGRect) -> [String: Any] {
  ["x": r.origin.x, "y": r.origin.y, "w": r.size.width, "h": r.size.height]
}

func edgeInfo(_ e: UIEdgeInsets) -> [String: Any] {
  ["t": e.top, "l": e.left, "b": e.bottom, "r": e.right]
}

func emit(_ payload: [String: Any]) {
  guard JSONSerialization.isValidJSONObject(payload),
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
  else { return }
  let line = "DUOPROBE " + String(data: data, encoding: .utf8)!
  // GUI 进程的 stdout 不会被 simctl --stdout 接到，写进沙盒文件才是可靠证据面。
  let url = ProbePaths.samplesURL
  if let fh = try? FileHandle(forWritingTo: url) {
    fh.seekToEndOfFile()
    fh.write((line + "\n").data(using: .utf8)!)
    try? fh.close()
  }
  print(line)
  NSLog("%@", line)
  fflush(stdout)
}

enum ProbePaths {
  static let samplesURL: URL = {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = dir.appendingPathComponent("samples.jsonl")
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: Data("# header\n".utf8))
    }
    return url
  }()
}

func sizeClassName(_ c: UIUserInterfaceSizeClass) -> String {
  switch c {
  case .unspecified: return "unspecified"
  case .compact: return "compact"
  case .regular: return "regular"
  @unknown default: return "other-\(c.rawValue)"
  }
}

final class ProbeView: UIView {
  var hingeStatus = "no-update"
  var hingeAngle: CGFloat = -1
  var hingeUpdates = 0

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil, hingeUpdates == 0 else { return }
    let interaction = UIHingeInteraction { [weak self] _, update in
      guard let self else { return }
      self.hingeUpdates += 1
      guard let hinge = update.hinge else {
        self.hingeStatus = "hinge-nil(非 Duo 层级)"
        self.hingeAngle = -1
        return
      }
      self.hingeStatus = ProbeView.statusName(hinge.status)
      self.hingeAngle = hinge.angle
    }
    addInteraction(interaction)
  }

  static func statusName(_ s: UIHinge.Status) -> String {
    switch s {
    case .unknown: return "unknown"
    case .closed: return "closed"
    case .partiallyOpen: return "partiallyOpen"
    case .fullyOpen: return "fullyOpen"
    @unknown default: return "other-\(s.rawValue)"
    }
  }
}

final class ProbeVC: UIViewController {
  override func loadView() {
    view = ProbeView()
    view.backgroundColor = .systemBackground
  }

  func regions(_ kind: __UIViewReservedRegionKind, includeInactive: Bool) -> [__UIViewReservedRegion] {
    includeInactive
      ? view.__reservedRegions(of: kind, options: [.includeInactive])
      : view.__reservedRegions(of: kind)
  }

  func sample(seq: Int) {
    let probe = view as! ProbeView
    let div = regions(__UIViewReservedRegionKind.division(), includeInactive: false)
    let divAll = regions(__UIViewReservedRegionKind.division(), includeInactive: true)
    let occ = regions(__UIViewReservedRegionKind.occlusion(), includeInactive: false)
    let occAll = regions(__UIViewReservedRegionKind.occlusion(), includeInactive: true)

    func name(_ r: __UIViewReservedRegion) -> String {
      if r.kind == __UIViewReservedRegionKind.division() { return "division" }
      if r.kind == __UIViewReservedRegionKind.occlusion() { return "occlusion" }
      return "other"
    }
    func pack(_ rs: [__UIViewReservedRegion]) -> [[String: Any]] {
      rs.map { r in
        [
          "kind": name(r),
          "id": String(describing: r.identifier),
          "frame": rectInfo(r.frame),
          "margins": edgeInfo(r.margins),
          "active": r.isActive,
        ]
      }
    }

    emit([
      "seq": seq,
      "t": CFAbsoluteTimeGetCurrent(),
      "screen": [
        "bounds": rectInfo(UIScreen.main.bounds),
        "scale": UIScreen.main.scale,
        "nativeScale": UIScreen.main.nativeScale,
        "screensCount": UIScreen.screens.count,
      ],
      "viewBounds": rectInfo(probe.bounds),
      "traits": [
        "hSizeClass": sizeClassName(probe.traitCollection.horizontalSizeClass),
        "vSizeClass": sizeClassName(probe.traitCollection.verticalSizeClass),
        "hRaw": probe.traitCollection.horizontalSizeClass.rawValue,
        "vRaw": probe.traitCollection.verticalSizeClass.rawValue,
      ],
      "safeArea": edgeInfo(probe.safeAreaInsets),
      "windowScene": view.window?.windowScene.map { scene in
        [
          "screenBounds": rectInfo(scene.screen.bounds),
          "screenScale": scene.screen.scale,
          "screenNativeScale": scene.screen.nativeScale,
          "orientation": scene.effectiveGeometry.interfaceOrientation.rawValue,
          "geomCoordSpace": rectInfo(scene.effectiveGeometry.coordinateSpace.bounds),
          "interactivelyResizing": scene.effectiveGeometry.isInteractivelyResizing,
        ]
      } ?? "nil",
      "hinge": ["status": probe.hingeStatus, "angle": probe.hingeAngle,
                "updates": probe.hingeUpdates],
      "divisionActive": pack(div),
      "divisionAll": pack(divAll),
      "occlusionActive": pack(occ),
      "occlusionAll": pack(occAll),
    ])
  }
}

@objc(ProbeSceneDelegate)
final class ProbeSceneDelegate: NSObject, UIWindowSceneDelegate {
  var window: UIWindow?
  var timer: Timer?
  var seq = 0

  // iOS 26+：scene 跨屏移动时必触发。用它验证「换屏」有没有事件源，
  // 而不是只靠 250ms 轮询发现。
  // 坑：scene 创建时也会回调一次，且此时 previous 为 nil。参数若按 nonnull 桥接，
  // 进函数体之前就会 EXC_BAD_ACCESS（实测崩溃在 swift_getObjectType）。
  @objc(windowScene:didUpdateEffectiveGeometry:)
  func windowScene(_ windowScene: UIWindowScene,
                   didUpdateEffectiveGeometry previousEffectiveGeometry: UIWindowScene.Geometry?) {
    let from: Any = previousEffectiveGeometry.map { rectInfo($0.coordinateSpace.bounds) } ?? "nil"
    emit(["marker": "didUpdateEffectiveGeometry",
          "from": from,
          "to": rectInfo(windowScene.effectiveGeometry.coordinateSpace.bounds),
          "screenBounds": rectInfo(windowScene.screen.bounds),
          "screenScale": windowScene.screen.scale,
          "t": CFAbsoluteTimeGetCurrent()])
    if window != nil {
      (window?.rootViewController as? ProbeVC)?.sample(seq: -2)
    }
  }

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
             options connectionOptions: UIScene.ConnectionOptions) {
    guard let windowScene = scene as? UIWindowScene else { return }
    let w = UIWindow(windowScene: windowScene)
    let vc = ProbeVC()
    w.rootViewController = vc
    w.makeKeyAndVisible()
    window = w
    emit(["marker": "scene-connected", "screenBounds": rectInfo(windowScene.screen.bounds),
          "screenScale": windowScene.screen.scale, "t": CFAbsoluteTimeGetCurrent()])
    // 下一轮 runloop 立即打一帧，用于区分「场景代理没跑」与「定时器没跑」。
    DispatchQueue.main.async { [weak vc] in
      vc?.sample(seq: -1)
    }

    let label = UILabel()
    label.numberOfLines = 0
    label.textColor = .green
    label.backgroundColor = .black.withAlphaComponent(0.55)
    label.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
    label.translatesAutoresizingMaskIntoConstraints = false
    w.addSubview(label)
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: w.safeAreaLayoutGuide.topAnchor, constant: 4),
      label.leadingAnchor.constraint(equalTo: w.leadingAnchor, constant: 4),
      label.trailingAnchor.constraint(equalTo: w.trailingAnchor, constant: -4),
    ])

    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      guard let self, let vc = self.window?.rootViewController as? ProbeVC else { return }
      vc.sample(seq: self.seq)
      let p = vc.view as! ProbeView
      label.text = String(
        format: "seq %d  %.0fx%.0f  scale %.0f\nH=%@ V=%@\nsafe t%.0f l%.0f b%.0f r%.0f\nhinge %@ (upd %d)\ndiv act=%d all=%d | occ act=%d all=%d",
        self.seq, vc.view.bounds.width, vc.view.bounds.height,
        self.window?.windowScene?.screen.scale ?? 0,
        sizeClassName(vc.view.traitCollection.horizontalSizeClass),
        sizeClassName(vc.view.traitCollection.verticalSizeClass),
        vc.view.safeAreaInsets.top, vc.view.safeAreaInsets.left,
        vc.view.safeAreaInsets.bottom, vc.view.safeAreaInsets.right,
        p.hingeStatus, p.hingeUpdates,
        vc.regions(__UIViewReservedRegionKind.division(), includeInactive: false).count,
        vc.regions(__UIViewReservedRegionKind.division(), includeInactive: true).count,
        vc.regions(__UIViewReservedRegionKind.occlusion(), includeInactive: false).count,
        vc.regions(__UIViewReservedRegionKind.occlusion(), includeInactive: true).count)
      self.seq += 1
      if self.seq > 400 { self.timer?.invalidate() }
    }
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   configurationForConnecting connectingSceneSession: UISceneSession,
                   options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    let c = UISceneConfiguration(name: "Probe", sessionRole: connectingSceneSession.role)
    c.delegateClass = ProbeSceneDelegate.self
    return c
  }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
