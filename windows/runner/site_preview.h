#ifndef RUNNER_SITE_PREVIEW_H_
#define RUNNER_SITE_PREVIEW_H_
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <map>
#include <memory>

class SitePreview {
 public:
  SitePreview(flutter::BinaryMessenger* messenger, HWND parent);
  ~SitePreview();
 private:
  struct View;
  HWND parent_;
  std::map<int, std::shared_ptr<View>> views_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
