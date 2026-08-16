#include "desktop_input_controller.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cmath>
#include <string>
#include <variant>

namespace {

// 正規化移動量(0..1)→ホイール量の変換ゲイン。macOS は画面高さ(px)へ写して
// pixel スクロールしているが、Windows のホイールは WHEEL_DELTA(120) 単位のため
// notch 換算する。実機での感度は要微調整（未検証の暫定値）。
constexpr double kScrollGain = 6.0;

double GetDouble(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return 0.0;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i = std::get_if<int32_t>(&it->second)) {
    return static_cast<double>(*i);
  }
  if (const auto* i64 = std::get_if<int64_t>(&it->second)) {
    return static_cast<double>(*i64);
  }
  return 0.0;
}

std::string GetString(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return std::string();
  if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
  return std::string();
}

}  // namespace

DesktopInputController::DesktopInputController(
    flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "yubiboard/desktop_input",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const std::string& method = call.method_name();
        if (method == "isAvailable") {
          result->Success(flutter::EncodableValue(true));
        } else if (method == "accessibilityTrusted") {
          // Windows は SendInput に特別な権限が不要（常に true）。
          result->Success(flutter::EncodableValue(true));
        } else if (method == "requestAccessibility") {
          // 権限プロンプトは不要。互換のため成功を返す no-op。
          result->Success();
        } else if (method == "setOverlayVisible") {
          // オーバーレイ窓の表示制御は yubiboard/overlay_window 側の
          // OverlayModeController が担当。ここは互換 no-op として成功させ、
          // MissingPlugin 扱いで入力 backend が無効化されないようにする。
          result->Success();
        } else if (method == "applyEvent") {
          if (const auto* args =
                  std::get_if<flutter::EncodableMap>(call.arguments())) {
            HandleApplyEvent(*args);
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
}

DesktopInputController::~DesktopInputController() {
  // 破棄時に押しっぱなしのままにしない（安全解除）。
  if (is_down_) SendMouseButton(MOUSEEVENTF_LEFTUP);
}

void DesktopInputController::HandleApplyEvent(
    const flutter::EncodableMap& args) {
  const std::string kind = GetString(args, "kind");
  const double x = GetDouble(args, "x");
  const double y = GetDouble(args, "y");

  if (kind == "pointerMove") {
    // 押下中は Windows が自動でドラッグイベントを生成するため移動のみ。
    MoveCursorAbsolute(x, y);
  } else if (kind == "pressDown") {
    MoveCursorAbsolute(x, y);
    SendMouseButton(MOUSEEVENTF_LEFTDOWN);
    is_down_ = true;
  } else if (kind == "pressMove") {
    MoveCursorAbsolute(x, y);
  } else if (kind == "pressUp") {
    MoveCursorAbsolute(x, y);
    if (is_down_) SendMouseButton(MOUSEEVENTF_LEFTUP);
    is_down_ = false;
  } else if (kind == "click") {
    // down/up で既にクリックは成立済みのため何もしない（二重発火防止）。
  } else if (kind == "scroll") {
    SendWheel(GetDouble(args, "dx"), GetDouble(args, "dy"));
  } else if (kind == "release") {
    if (is_down_) SendMouseButton(MOUSEEVENTF_LEFTUP);
    is_down_ = false;
  }
  // draw* は Dart 側(DesktopBridge)で除外済みのため OS には来ない。
}

void DesktopInputController::MoveCursorAbsolute(double nx, double ny) {
  nx = std::min(std::max(nx, 0.0), 1.0);
  ny = std::min(std::max(ny, 0.0), 1.0);
  INPUT input = {};
  input.type = INPUT_MOUSE;
  input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE;
  // MOUSEEVENTF_ABSOLUTE は 0..65535 をプライマリモニタ全域へ写す
  // （VIRTUALDESK を付けない＝macOS の mainDisplay 準拠）。
  input.mi.dx = static_cast<LONG>(std::lround(nx * 65535.0));
  input.mi.dy = static_cast<LONG>(std::lround(ny * 65535.0));
  SendInput(1, &input, sizeof(INPUT));
}

void DesktopInputController::SendMouseButton(DWORD flags) {
  INPUT input = {};
  input.type = INPUT_MOUSE;
  input.mi.dwFlags = flags;
  SendInput(1, &input, sizeof(INPUT));
}

void DesktopInputController::SendWheel(double dx, double dy) {
  // 符号は macOS 実装に合わせる（下方向の指移動＝コンテンツを下へ送る）。
  const LONG vertical =
      static_cast<LONG>(std::lround(-dy * WHEEL_DELTA * kScrollGain));
  const LONG horizontal =
      static_cast<LONG>(std::lround(dx * WHEEL_DELTA * kScrollGain));
  if (vertical != 0) {
    INPUT input = {};
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = MOUSEEVENTF_WHEEL;
    // mouseData は符号付きホイール量（負値は DWORD へそのまま入れる）。
    input.mi.mouseData = static_cast<DWORD>(vertical);
    SendInput(1, &input, sizeof(INPUT));
  }
  if (horizontal != 0) {
    INPUT input = {};
    input.type = INPUT_MOUSE;
    input.mi.dwFlags = MOUSEEVENTF_HWHEEL;
    input.mi.mouseData = static_cast<DWORD>(horizontal);
    SendInput(1, &input, sizeof(INPUT));
  }
}
