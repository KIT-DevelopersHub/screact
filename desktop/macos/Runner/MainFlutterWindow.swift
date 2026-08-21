import Carbon.HIToolbox
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var overlayMode: OverlayModeController?
  private var desktopInput: DesktopInputController?
  private var bonjour: BonjourAdvertiser?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    overlayMode = OverlayModeController(window: self, flutterViewController: flutterViewController)
    // OSクリック/ドラッグ/スクロールの実注入（CGEvent）。channel: desktop_input。
    desktopInput = DesktopInputController(
      messenger: flutterViewController.engine.binaryMessenger)
    // iOS 自動接続用の Bonjour(_screact._tcp) 広告。channel: yubiboard/bonjour。
    bonjour = BonjourAdvertiser(messenger: flutterViewController.engine.binaryMessenger)

    // 起動処理の最後に製品名タイトルとデモ向け初期サイズを確定させる
    // （起動中に FlutterAppDelegate がタイトルを実行ファイル名で上書きし、
    //   FlutterViewController 差し替えで xib の初期サイズも失われるため）。
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.title = "Screact"
      self.setContentSize(NSSize(width: 1160, height: 740))
      self.center()
    }

    super.awakeFromNib()
  }
}

/// スライド（画面共有中のPowerPoint等）の上にインクを重ねる「オーバーレイモード」。
/// 窓を 透過・borderless・最前面(.screenSaver)・クリック透過 にして全画面へ広げる。
/// クリック透過中は窓を直接触れないため、脱出経路を2つ用意する:
///   1. メニューバーアイコン（オーバーレイ中のみ表示）
///   2. グローバルホットキー Cmd+Shift+O（Carbon RegisterEventHotKey・権限不要）
final class OverlayModeController: NSObject {
  private weak var window: NSWindow?
  private weak var flutterViewController: FlutterViewController?
  private let channel: FlutterMethodChannel

  private var savedFrame: NSRect?
  private var savedStyleMask: NSWindow.StyleMask = []
  private var savedLevel: NSWindow.Level = .normal
  private var savedCollectionBehavior: NSWindow.CollectionBehavior = []
  private var savedIsOpaque = true
  private var savedBackgroundColor: NSColor?
  private var savedHasShadow = true
  private var savedIgnoresMouseEvents = false
  private var savedFlutterBackgroundColor: NSColor?
  private var statusItem: NSStatusItem?
  private var hotKeyRef: EventHotKeyRef?
  private var eventHandlerRef: EventHandlerRef?
  private(set) var isOverlay = false

  init(window: NSWindow, flutterViewController: FlutterViewController) {
    self.window = window
    self.flutterViewController = flutterViewController
    self.channel = FlutterMethodChannel(
      name: "yubiboard/overlay_window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    registerHotKey()
  }

  deinit {
    if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(true)
    case "enterOverlay":
      result(enterOverlay())
    case "exitOverlay":
      exitOverlay(notifyFlutter: false)
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Overlay window state

  @discardableResult
  func enterOverlay() -> Bool {
    guard let window else { return false }
    guard !isOverlay else { return true }
    // ネイティブフルスクリーン中の styleMask 変更は AppKit が NSException を
    // 投げてクラッシュする（実クラッシュの根本原因）。ここで拒否して false を
    // 返し、Flutter側はウィンドウ内表示へフォールバックする。
    if window.styleMask.contains(.fullScreen) { return false }
    isOverlay = true
    savedFrame = window.frame
    savedStyleMask = window.styleMask
    savedLevel = window.level
    savedCollectionBehavior = window.collectionBehavior
    savedIsOpaque = window.isOpaque
    savedBackgroundColor = window.backgroundColor
    savedHasShadow = window.hasShadow
    savedIgnoresMouseEvents = window.ignoresMouseEvents
    savedFlutterBackgroundColor = flutterViewController?.backgroundColor

    window.styleMask = [.borderless]
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    // 全Space・他アプリのフルスクリーンより手前に居続ける。
    // level は screenSaver より上の CGShieldingWindowLevel 級（最大級）。
    window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
    window.ignoresMouseEvents = true
    // canJoinAllSpaces: 全デスクトップに出る / fullScreenAuxiliary: 他アプリの
    // フルスクリーン上にも重ねる / stationary: Space切替アニメで動かさない /
    // ignoresCycle: Cmd+` のウィンドウ循環に含めない。
    window.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    flutterViewController?.backgroundColor = .clear
    if let screen = window.screen ?? NSScreen.main {
      window.setFrame(screen.frame, display: true)
    }
    window.orderFrontRegardless()
    installStatusItem()
    return true
  }

  func exitOverlay(notifyFlutter: Bool) {
    guard let window, isOverlay else { return }
    isOverlay = false
    removeStatusItem()

    window.styleMask = savedStyleMask
    window.isOpaque = savedIsOpaque
    window.backgroundColor = savedBackgroundColor
    window.hasShadow = savedHasShadow
    window.level = savedLevel
    window.ignoresMouseEvents = savedIgnoresMouseEvents
    window.collectionBehavior = savedCollectionBehavior
    flutterViewController?.backgroundColor = savedFlutterBackgroundColor
    if let f = savedFrame { window.setFrame(f, display: true) }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    if notifyFlutter { channel.invokeMethod("overlayExited", arguments: nil) }
  }

  func toggleOverlay() {
    if isOverlay {
      exitOverlay(notifyFlutter: true)
    } else if enterOverlay() {
      channel.invokeMethod("overlayEntered", arguments: nil)
    }
  }

  // MARK: - Escape route 1: menu bar icon

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      // deployment target 10.14 のため SF Symbol は使わずテキストで表示
      button.title = "✏"
      button.toolTip = "Screact オーバーレイ中（クリックで解除メニュー）"
    }
    let menu = NSMenu()
    let exit = NSMenuItem(
      title: "オーバーレイ解除", action: #selector(exitFromMenu), keyEquivalent: "o")
    exit.keyEquivalentModifierMask = [.command, .shift]
    exit.target = self
    menu.addItem(exit)
    item.menu = menu
    statusItem = item
  }

  private func removeStatusItem() {
    if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    statusItem = nil
  }

  @objc private func exitFromMenu() {
    exitOverlay(notifyFlutter: true)
  }

  // MARK: - Escape route 2: global hotkey Cmd+Shift+O (no permission needed)

  private func registerHotKey() {
    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(
      GetEventDispatcherTarget(),
      { _, _, userData -> OSStatus in
        guard let userData else { return noErr }
        let controller = Unmanaged<OverlayModeController>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async { controller.toggleOverlay() }
        return noErr
      },
      1, &eventType, selfPtr, &eventHandlerRef)
    let hotKeyID = EventHotKeyID(signature: OSType(0x5942_5244), id: 1)  // 'YBRD'
    RegisterEventHotKey(
      UInt32(kVK_ANSI_O), UInt32(cmdKey | shiftKey), hotKeyID,
      GetEventDispatcherTarget(), 0, &hotKeyRef)
  }
}
