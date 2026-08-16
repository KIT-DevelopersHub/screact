#ifndef RUNNER_DESKTOP_INPUT_CONTROLLER_H_
#define RUNNER_DESKTOP_INPUT_CONTROLLER_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Flutter の InteractionEvent を Windows の実マウス入力（SendInput / user32.dll）
// として注入する。macOS の DesktopInputController(CGEvent) と同じ MethodChannel
// 契約 (yubiboard/desktop_input) を提供し、プラットフォーム分岐は Dart 側の
// DesktopBridge.forPlatform() 1 箇所に閉じる。
//
//   - pointerMove          → 実カーソル移動（押下中は Windows が自動でドラッグ）
//   - pressDown/Move/Up    → 左ボタン down/drag/up（＝実クリック/ドラッグ）
//   - scroll               → ホイール（縦 MOUSEEVENTF_WHEEL / 横 HWHEEL）
//   - click                → down/up で成立済みのため no-op（二重発火防止）
//   - release              → 押下中なら左ボタン up（トラッキング喪失時の安全解除）
//   - draw*                → Dart 側で除外済み（OS には来ない・オーバーレイ専用）
//
// 座標系: 正規化(0..1) を **プライマリモニタ** の絶対座標(0..65535)へ写す
// （macOS 実装の mainDisplay 準拠・InputServer の単一ディスプレイ前提に合わせる）。
//
// Windows では SendInput に特別な権限が不要のため accessibilityTrusted は常に
// true を返す（macOS の AXIsProcessTrusted 相当のゲートは無い）。ただし UIPI に
// より、より高い整合性レベルで動く窓へは注入できない点は OS 仕様として残る。
class DesktopInputController {
 public:
  explicit DesktopInputController(flutter::BinaryMessenger* messenger);
  ~DesktopInputController();

  DesktopInputController(const DesktopInputController&) = delete;
  DesktopInputController& operator=(const DesktopInputController&) = delete;

 private:
  void HandleApplyEvent(const flutter::EncodableMap& args);
  // 正規化座標へ実カーソルを移動（絶対座標）。
  void MoveCursorAbsolute(double nx, double ny);
  // 左ボタンの down / up を 1 イベント送出。
  void SendMouseButton(DWORD flags);
  // 正規化移動量をホイール量へ写して送出。
  void SendWheel(double dx, double dy);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  // 左ボタン押下中か（pressUp/release で確実に up させ、押しっぱなしを防ぐ）。
  bool is_down_ = false;
};

#endif  // RUNNER_DESKTOP_INPUT_CONTROLLER_H_
