#include "overlay_mode_controller.h"

#include <flutter/standard_method_codec.h>

namespace {

constexpr int kHotKeyId = 0x5942;  // 'YB'

// SetWindowCompositionAttribute は非公開APIだが、Flutterの透過窓では定石の手法
// (flutter_acrylic 等と同じ)。ACCENT_ENABLE_TRANSPARENTGRADIENT + アルファ0で
// Flutterが透明に描いた画素がそのまま背後へ抜ける。
enum AccentState {
  ACCENT_DISABLED = 0,
  ACCENT_ENABLE_TRANSPARENTGRADIENT = 2,
};

struct AccentPolicy {
  int state;
  int flags;
  int gradient_color;  // AABBGGRR
  int animation_id;
};

struct WindowCompositionAttribData {
  int attrib;
  void* data;
  size_t size;
};

constexpr int kWcaAccentPolicy = 19;

using SetWindowCompositionAttributeFn =
    BOOL(WINAPI*)(HWND, WindowCompositionAttribData*);

SetWindowCompositionAttributeFn GetSetWindowCompositionAttribute() {
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (!user32) return nullptr;
  return reinterpret_cast<SetWindowCompositionAttributeFn>(
      GetProcAddress(user32, "SetWindowCompositionAttribute"));
}

}  // namespace

OverlayModeController::OverlayModeController(HWND window,
                                             flutter::BinaryMessenger* messenger)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "yubiboard/overlay_window",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "isAvailable") {
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "enterOverlay") {
          EnterOverlay();
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "exitOverlay") {
          ExitOverlay(/*notify_flutter=*/false);
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });
  // 脱出経路: Ctrl+Shift+O（クリック透過中でも届くグローバルホットキー）。
  RegisterHotKey(window_, kHotKeyId, MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT,
                 'O');
}

OverlayModeController::~OverlayModeController() {
  if (window_) UnregisterHotKey(window_, kHotKeyId);
}

void OverlayModeController::EnterOverlay() {
  if (!window_ || is_overlay_) return;
  is_overlay_ = true;

  saved_style_ = GetWindowLong(window_, GWL_STYLE);
  saved_ex_style_ = GetWindowLong(window_, GWL_EXSTYLE);
  GetWindowPlacement(window_, &saved_placement_);

  // borderless + クリック透過 + 最前面 + タスクバー非表示。
  SetWindowLong(window_, GWL_STYLE,
                (saved_style_ & ~(WS_CAPTION | WS_THICKFRAME | WS_MINIMIZEBOX |
                                  WS_MAXIMIZEBOX | WS_SYSMENU)) |
                    WS_POPUP);
  SetWindowLong(window_, GWL_EXSTYLE,
                saved_ex_style_ | WS_EX_LAYERED | WS_EX_TRANSPARENT |
                    WS_EX_TOPMOST | WS_EX_TOOLWINDOW);
  SetLayeredWindowAttributes(window_, 0, 255, LWA_ALPHA);
  SetTransparentBackground(true);

  // 現在のモニタ全面へ。
  HMONITOR monitor = MonitorFromWindow(window_, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info = {sizeof(MONITORINFO)};
  GetMonitorInfo(monitor, &info);
  const RECT& rc = info.rcMonitor;
  SetWindowPos(window_, HWND_TOPMOST, rc.left, rc.top, rc.right - rc.left,
               rc.bottom - rc.top, SWP_FRAMECHANGED | SWP_SHOWWINDOW);
}

void OverlayModeController::ExitOverlay(bool notify_flutter) {
  if (!window_ || !is_overlay_) return;
  is_overlay_ = false;

  SetTransparentBackground(false);
  SetWindowLong(window_, GWL_STYLE, saved_style_);
  SetWindowLong(window_, GWL_EXSTYLE, saved_ex_style_);
  SetWindowPlacement(window_, &saved_placement_);
  SetWindowPos(window_, HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
  SetForegroundWindow(window_);

  if (notify_flutter && channel_) {
    channel_->InvokeMethod("overlayExited", nullptr);
  }
}

void OverlayModeController::ToggleOverlay() {
  if (is_overlay_) {
    ExitOverlay(/*notify_flutter=*/true);
  } else {
    EnterOverlay();
    if (channel_) channel_->InvokeMethod("overlayEntered", nullptr);
  }
}

bool OverlayModeController::HandleHotKey(WPARAM wparam) {
  if (static_cast<int>(wparam) != kHotKeyId) return false;
  ToggleOverlay();
  return true;
}

void OverlayModeController::SetTransparentBackground(bool enabled) {
  auto set_attribute = GetSetWindowCompositionAttribute();
  if (!set_attribute) return;  // 旧OS: 背景は不透明のまま（劣化動作）
  AccentPolicy policy = {};
  policy.state = enabled ? ACCENT_ENABLE_TRANSPARENTGRADIENT : ACCENT_DISABLED;
  policy.gradient_color = 0;  // 完全透過
  WindowCompositionAttribData data = {};
  data.attrib = kWcaAccentPolicy;
  data.data = &policy;
  data.size = sizeof(policy);
  set_attribute(window_, &data);
}
