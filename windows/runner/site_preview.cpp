#include "site_preview.h"
#include <WebView2.h>
#include <wrl.h>
#include <shlobj.h>
#include <cmath>
#include <string>
#include "utils.h"

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;

struct SitePreview::View {
  bool active = true;
  ComPtr<ICoreWebView2Controller> controller;
  ComPtr<ICoreWebView2> browser;
  RECT bounds{};
  bool has_bounds = false;
  bool visible = false;
  ~View() { if (controller) controller->Close(); }
};

static double Number(const Map& args, const char* key) {
  const auto it = args.find(Value(key));
  if (it == args.end()) return 0;
  if (const auto* value = std::get_if<double>(&it->second)) return *value;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  return 0;
}

static std::wstring Wide(const std::string& value) {
  const int count = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
  if (count <= 0) return {};
  std::wstring result(count, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, result.data(), count);
  result.resize(count - 1);
  return result;
}

SitePreview::SitePreview(flutter::BinaryMessenger* messenger, HWND parent) : parent_(parent) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "dev.tamtoot/site_preview", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call,
      std::unique_ptr<flutter::MethodResult<Value>> result) {
    const auto* args = call.arguments() ? std::get_if<Map>(call.arguments()) : nullptr;
    if (!args) { result->Error("arguments", "Expected preview arguments"); return; }
    const int id = static_cast<int>(Number(*args, "id"));
    if (call.method_name() == "create") {
      const auto value = args->find(Value("url"));
      const auto* url = value == args->end() ? nullptr : std::get_if<std::string>(&value->second);
      if (!url || (url->rfind("http://", 0) != 0 && url->rfind("https://", 0) != 0)) {
        result->Error("url", "Expected an HTTP or HTTPS URL"); return;
      }
      const std::wstring target = Wide(*url);
      const auto old = views_.find(id);
      if (old != views_.end()) {
        old->second->active = false;
        if (old->second->controller) old->second->controller->Close();
      }
      auto state = std::make_shared<View>();
      views_[id] = state;
      auto reply = std::shared_ptr<flutter::MethodResult<Value>>(std::move(result));
      PWSTR local = nullptr;
      if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local))) {
        reply->Error("storage", "Cannot locate private browser storage"); return;
      }
      const std::wstring folder = std::wstring(local) + L"\\TamToot\\Preview";
      CoTaskMemFree(local);
      SHCreateDirectoryExW(nullptr, folder.c_str(), nullptr);
      const HWND parent = parent_;
      HRESULT started = CreateCoreWebView2EnvironmentWithOptions(nullptr, folder.c_str(), nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [state, parent, reply, target](HRESULT error, ICoreWebView2Environment* environment) -> HRESULT {
            if (!state->active) { reply->Error("closed", "Preview closed"); return S_OK; }
            if (FAILED(error) || !environment) {
              reply->Error("runtime", "Install Microsoft Edge WebView2 Runtime"); return S_OK;
            }
            HRESULT startedController = environment->CreateCoreWebView2Controller(parent,
              Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                [state, reply, target](HRESULT error, ICoreWebView2Controller* controller) -> HRESULT {
                  if (!state->active) {
                    if (controller) controller->Close();
                    reply->Error("closed", "Preview closed"); return S_OK;
                  }
                  if (FAILED(error) || !controller) {
                    reply->Error("controller", "Could not create browser view"); return S_OK;
                  }
                  state->controller = controller;
                  controller->get_CoreWebView2(&state->browser);
                  controller->put_IsVisible(FALSE);
                  if (!state->browser) { reply->Error("browser", "Browser unavailable"); return S_OK; }
                  state->browser->Navigate(target.c_str());
                  reply->Success();
                  return S_OK;
                }).Get());
            if (FAILED(startedController)) reply->Error("controller", "Could not start browser view");
            return S_OK;
          }).Get());
      if (FAILED(started)) reply->Error("runtime", "Could not initialize WebView2");
      return;
    }
    const auto found = views_.find(id);
    if (call.method_name() == "dispose") {
      if (found != views_.end()) {
        found->second->active = false;
        if (found->second->controller) found->second->controller->Close();
        views_.erase(found);
      }
      result->Success(); return;
    }
    if (call.method_name() == "bounds") {
      if (found != views_.end() && found->second->controller) {
        double scale = Number(*args, "scale");
        if (scale <= 0) scale = 1;
        const LONG x = static_cast<LONG>(std::lround(Number(*args, "x") * scale));
        const LONG y = static_cast<LONG>(std::lround(Number(*args, "y") * scale));
        RECT rect{x, y,
          x + static_cast<LONG>(std::lround(Number(*args, "width") * scale)),
          y + static_cast<LONG>(std::lround(Number(*args, "height") * scale))};
        auto& state = *found->second;
        if (!state.has_bounds || !EqualRect(&state.bounds, &rect)) {
          if (SUCCEEDED(state.controller->put_Bounds(rect))) {
            state.bounds = rect;
            state.has_bounds = true;
          }
        }
        const auto visible = args->find(Value("visible"));
        const bool* show = visible == args->end() ? nullptr : std::get_if<bool>(&visible->second);
        const bool desired_visibility = show && *show;
        if (state.visible != desired_visibility &&
            SUCCEEDED(state.controller->put_IsVisible(desired_visibility))) {
          state.visible = desired_visibility;
        }
      }
      result->Success(); return;
    }
    result->NotImplemented();
  });
}

SitePreview::~SitePreview() {
  channel_->SetMethodCallHandler(nullptr);
  for (auto& item : views_) {
    item.second->active = false;
    if (item.second->controller) item.second->controller->Close();
  }
}
