#ifndef RUNNER_OVERLAY_MODE_CONTROLLER_H_
#define RUNNER_OVERLAY_MODE_CONTROLLER_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// スライド（画面共有中のPowerPoint等）の上にインクを重ねる「オーバーレイモード」
// の Windows 実装。macOS の OverlayModeController と同じ MethodChannel 契約
// (yubiboard/overlay_window: isAvailable / enterOverlay / exitOverlay、
//  ネイティブ→Dart: overlayEntered / overlayExited) を提供する。
//
// 窓を borderless・最前面(topmost)・クリック透過(WS_EX_TRANSPARENT)・背景透過に
// してモニタ全面へ広げる。クリック透過中は窓を直接触れないため、脱出経路として
// グローバルホットキー Ctrl+Shift+O (RegisterHotKey・権限不要) を用意する。
class OverlayModeController {
 public:
  OverlayModeController(HWND window, flutter::BinaryMessenger* messenger);
  ~OverlayModeController();

  bool is_overlay() const { return is_overlay_; }
  bool is_available() const { return hot_key_registered_; }
  void EnterOverlay();
  void ExitOverlay(bool notify_flutter);
  void ToggleOverlay();

  // FlutterWindow::MessageHandler から WM_HOTKEY を中継する。
  // このコントローラのホットキーなら true を返す。
  bool HandleHotKey(WPARAM wparam);

 private:
  // Flutter Windows embedder は既定で不透明背景を描くため、合成側
  // (SetWindowCompositionAttribute) から背景を透過させる。
  void SetTransparentBackground(bool enabled);

  HWND window_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool is_overlay_ = false;
  bool hot_key_registered_ = false;
  LONG saved_style_ = 0;
  LONG saved_ex_style_ = 0;
  WINDOWPLACEMENT saved_placement_ = {sizeof(WINDOWPLACEMENT)};
};

#endif  // RUNNER_OVERLAY_MODE_CONTROLLER_H_
