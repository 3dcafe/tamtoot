#ifndef TAMTOOT_SSH_SECRETS_H_
#define TAMTOOT_SSH_SECRETS_H_
#include <windows.h>
#include <wincred.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <memory>
#include <regex>
#include <string>
#include <vector>

inline std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateSshSecrets(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "dev.tamtoot/ssh_secrets", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "available") {
      result->Success(flutter::EncodableValue(true)); return;
    }
    auto args = call.arguments() ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    if (!args) { result->Error("invalid_reference", "Invalid secret reference"); return; }
    auto entry = args->find(flutter::EncodableValue("id"));
    auto id = entry == args->end() ? nullptr : std::get_if<std::string>(&entry->second);
    if (!id || !std::regex_match(*id, std::regex("^[a-f0-9]{32}$"))) {
      result->Error("invalid_reference", "Invalid secret reference"); return;
    }
    std::wstring target = L"dev.tamtoot.ssh/" + std::wstring(id->begin(), id->end());
    BOOL ok = FALSE;
    if (call.method_name() == "write") {
      auto value_entry = args->find(flutter::EncodableValue("value"));
      auto value = value_entry == args->end() ? nullptr : std::get_if<std::vector<uint8_t>>(&value_entry->second);
      if (!value || value->empty() || value->size() > CRED_MAX_CREDENTIAL_BLOB_SIZE) {
        result->Error("secret_size", "Secret exceeds Windows Credential Manager size limit"); return;
      }
      CREDENTIALW credential{};
      credential.Type = CRED_TYPE_GENERIC;
      credential.TargetName = target.data();
      credential.CredentialBlobSize = static_cast<DWORD>(value->size());
      credential.CredentialBlob = const_cast<LPBYTE>(value->data());
      credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
      ok = CredWriteW(&credential, 0);
    } else if (call.method_name() == "read") {
      PCREDENTIALW credential = nullptr;
      ok = CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &credential);
      if (ok) {
        std::vector<uint8_t> value(credential->CredentialBlob,
            credential->CredentialBlob + credential->CredentialBlobSize);
        result->Success(flutter::EncodableValue(value));
        SecureZeroMemory(value.data(), value.size());
        SecureZeroMemory(credential->CredentialBlob, credential->CredentialBlobSize);
        CredFree(credential); return;
      }
    } else if (call.method_name() == "delete") {
      ok = CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0);
    } else { result->NotImplemented(); return; }
    if (ok || (call.method_name() != "write" && GetLastError() == ERROR_NOT_FOUND)) result->Success();
    else result->Error("secure_storage", "Windows Credential Manager operation failed");
  });
  return channel;
}
#endif
