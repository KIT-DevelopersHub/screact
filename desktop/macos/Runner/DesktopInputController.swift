import ApplicationServices
import CoreGraphics
import FlutterMacOS
import Foundation

/// Flutter の InteractionEvent を macOS の実マウスイベント（CGEvent）として
/// 注入する。channel: `yubiboard/desktop_input`。
///
/// - ポインタ移動(pointerMove) → 実カーソル移動
/// - ピンチ(pressDown/pressMove/pressUp) → 左ボタンの down/drag/up（＝実クリック/ドラッグ）
/// - スクロール(scroll) → スクロールホイール
/// - インク描画(draw*) は Flutter 側で除外済み（OSには来ない・オーバーレイ専用）
///
/// CGEvent の投函にはアクセシビリティ権限（AXIsProcessTrusted）が要る。
/// 未許可時は accessibilityTrusted=false を返し、Flutter が権限案内カードを出す。
/// requestAccessibility でシステムのプロンプトを出し、設定一覧に登録させる。
///
/// 座標系: 正規化(0..1) を **メインディスプレイ** のグローバル座標(左上原点・
/// px)へ写す。位置合わせは単一ディスプレイ 1920x1080 前提（InputServer 準拠）。
final class DesktopInputController: NSObject {
  private let channel: FlutterMethodChannel
  private var lastPoint = CGPoint.zero
  private var isDown = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "yubiboard/desktop_input", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(true)
    case "accessibilityTrusted":
      result(AXIsProcessTrusted())
    case "requestAccessibility":
      // プロンプトを出して「システム設定 > プライバシー > アクセシビリティ」の
      // 一覧に登録させる（未登録だと許可の付けようがないため）。
      let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
      result(nil)
    case "applyEvent":
      if let args = call.arguments as? [String: Any] {
        apply(args)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - CGEvent injection

  private func mainDisplaySize() -> CGSize {
    let bounds = CGDisplayBounds(CGMainDisplayID())
    if bounds.width > 0, bounds.height > 0 { return bounds.size }
    return CGSize(width: 1920, height: 1080)
  }

  private func point(_ args: [String: Any]) -> CGPoint {
    let nx = (args["x"] as? Double) ?? 0
    let ny = (args["y"] as? Double) ?? 0
    let size = mainDisplaySize()
    let x = min(max(nx, 0), 1) * size.width
    let y = min(max(ny, 0), 1) * size.height
    return CGPoint(x: x, y: y)
  }

  private func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left) {
    guard let ev = CGEvent(
      mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
    else { return }
    ev.post(tap: .cghidEventTap)
  }

  private func apply(_ args: [String: Any]) {
    guard AXIsProcessTrusted() else { return } // 未許可では黙って無視（案内はFlutter側）
    let kind = (args["kind"] as? String) ?? ""
    switch kind {
    case "pointerMove":
      let p = point(args)
      lastPoint = p
      post(isDown ? .leftMouseDragged : .mouseMoved, p)
    case "pressDown":
      let p = point(args)
      lastPoint = p
      isDown = true
      post(.leftMouseDown, p)
    case "pressMove":
      let p = point(args)
      lastPoint = p
      post(.leftMouseDragged, p)
    case "pressUp":
      let p = point(args)
      lastPoint = p
      if isDown { post(.leftMouseUp, p) }
      isDown = false
    case "click":
      // down/up で既にクリックは成立しているため何もしない（二重発火防止）。
      break
    case "scroll":
      let size = mainDisplaySize()
      let dx = (args["dx"] as? Double) ?? 0
      let dy = (args["dy"] as? Double) ?? 0
      // 正規化移動量 → px（画面の縦横に対する割合をピクセル量に）。
      let py = Int32((-dy * size.height).rounded())
      let px = Int32((-dx * size.width).rounded())
      if let ev = CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: py, wheel2: px, wheel3: 0) {
        ev.post(tap: .cghidEventTap)
      }
    case "release":
      if isDown { post(.leftMouseUp, lastPoint) }
      isDown = false
    default:
      break
    }
  }
}
