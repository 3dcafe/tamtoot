#ifndef TAMTOOT_TLS_ROOTS_H_
#define TAMTOOT_TLS_ROOTS_H_

#include <windows.h>
#include <wincrypt.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <memory>
#include <vector>

inline std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateTlsRoots(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "dev.tamtoot/tls_roots", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() != "readRoots") {
      result->NotImplemented();
      return;
    }
    // The current-user ROOT store includes the inherited local-machine roots.
    // Never import the intermediate or personal certificate stores as roots.
    HCERTSTORE store = CertOpenSystemStoreW(0, L"ROOT");
    if (!store) {
      result->Error("tls_roots", "Cannot open Windows trusted root certificates");
      return;
    }
    flutter::EncodableList roots;
    PCCERT_CONTEXT certificate = nullptr;
    while ((certificate = CertEnumCertificatesInStore(store, certificate)) != nullptr) {
      roots.emplace_back(std::vector<uint8_t>(
          certificate->pbCertEncoded,
          certificate->pbCertEncoded + certificate->cbCertEncoded));
    }
    const DWORD error = GetLastError();
    CertCloseStore(store, 0);
    if (error != static_cast<DWORD>(CRYPT_E_NOT_FOUND)) {
      result->Error("tls_roots", "Cannot enumerate Windows trusted root certificates");
      return;
    }
    result->Success(flutter::EncodableValue(roots));
  });
  return channel;
}
#endif
