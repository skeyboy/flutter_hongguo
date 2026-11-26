#include "flutter_window.h"

#include <flutter/encodable_value.h>
#include <optional>
#include <shellapi.h>
#include <flutter/standard_method_codec.h>
#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 42;
constexpr UINT kOpen = 1001;
constexpr UINT kExit = 1002;
}

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::AddTrayIcon() {
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = GetHandle();
  icon.uID = 1;
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  icon.uCallbackMessage = kTrayMessage;
  icon.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(icon.szTip, L"Hongguo - 单击打开，右键菜单");
  tray_available_ = Shell_NotifyIconW(NIM_ADD, &icon) != FALSE;
  return tray_available_;
}

void FlutterWindow::RestoreWindow() {
  const HWND handle = GetHandle();
  ShowWindow(handle, IsIconic(handle) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(handle);
  // The tray click is delivered while Explorer keeps the foreground, and a
  // background process may not take it: the window would be shown behind
  // everything, which reads as a click that did nothing.
  if (GetForegroundWindow() != handle) SwitchToThisWindow(handle, TRUE);
}

void FlutterWindow::RegisterWindowChannel() {
  if (!flutter_controller_ || window_channel_) {
    return;
  }
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "hongguo/windows-window", &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "hide") {
          ShowWindow(GetHandle(), SW_HIDE);
          result->Success(flutter::EncodableValue(true));
        } else if (call.method_name() == "quit") {
          // The tray menu quits without asking; so does Dart's explicit exit.
          DestroyWindow(GetHandle());
          result->Success(flutter::EncodableValue(true));
        } else {
          result->NotImplemented();
        }
      });
  // From here on the native close button asks Dart (closeRequested) instead of
  // deciding between tray-hide and destroy on its own.
  forward_close_ = true;
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  RegisterWindowChannel();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  AddTrayIcon();

  return true;
}

void FlutterWindow::OnDestroy() {
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = GetHandle();
  icon.uID = 1;
  Shell_NotifyIconW(NIM_DELETE, &icon);
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Handle close before plugins so the native close button retains the engine.
  // Once the Dart channel is live the close decision (ask dialog / tray /
  // exit) belongs to Dart; before that we keep the tray-hide fallback.
  if (message == WM_CLOSE) {
    if (forward_close_ && window_channel_) {
      window_channel_->InvokeMethod(
          "closeRequested",
          std::make_unique<flutter::EncodableValue>(
              flutter::EncodableValue(tray_available_ != FALSE)));
      return 0;
    }
    if (tray_available_ || AddTrayIcon()) {
      ShowWindow(hwnd, SW_HIDE);
      return 0;
    }
  }
  if (taskbar_created_ != 0 && message == taskbar_created_) {
    if (!AddTrayIcon()) RestoreWindow();
    return 0;
  }
  if (message == kTrayMessage) {
    // WM_LBUTTONDBLCLK arrives as an up-click and then a double-click, so the
    // single up-click alone already wakes the window from one press.
    if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) RestoreWindow();
    if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
      HMENU menu = CreatePopupMenu();
      if (!menu) { RestoreWindow(); return 0; }
      AppendMenuW(menu, MF_STRING, kOpen, L"打开红果");
      AppendMenuW(menu, MF_STRING, kExit, L"退出");
      POINT point{};
      GetCursorPos(&point);
      SetForegroundWindow(hwnd);
      const UINT command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON,
          point.x, point.y, 0, hwnd, nullptr);
      DestroyMenu(menu);
      PostMessage(hwnd, WM_NULL, 0, 0);
      if (command == kOpen) RestoreWindow();
      if (command == kExit) DestroyWindow(hwnd);
    }
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
