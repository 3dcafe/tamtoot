cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "site_preview.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "shell32.lib" "advapi32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "crypt32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Microsoft's native SDK only; no Flutter WebView package is used.
include(FetchContent)
FetchContent_Declare(tamtoot_webview2
  URL https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/1.0.2792.45
  DOWNLOAD_NAME webview2.zip
)
FetchContent_GetProperties(tamtoot_webview2)
if(NOT tamtoot_webview2_POPULATED)
  FetchContent_Populate(tamtoot_webview2)
endif()
if(CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64")
  set(TAMTOOT_WEBVIEW_ARCH arm64)
elseif(CMAKE_SIZEOF_VOID_P EQUAL 8)
  set(TAMTOOT_WEBVIEW_ARCH x64)
else()
  set(TAMTOOT_WEBVIEW_ARCH x86)
endif()
target_include_directories(${BINARY_NAME} PRIVATE "${tamtoot_webview2_SOURCE_DIR}/build/native/include")
target_link_libraries(${BINARY_NAME} PRIVATE
  "${tamtoot_webview2_SOURCE_DIR}/build/native/${TAMTOOT_WEBVIEW_ARCH}/WebView2LoaderStatic.lib"
  ole32.lib shlwapi.lib version.lib
)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Own portable SSH primitives; only OS random APIs and the standard runtime.
add_library(tamtoot_ssh_crypto SHARED "${CMAKE_CURRENT_SOURCE_DIR}/../../native/ssh/ssh_crypto.cpp")
target_compile_features(tamtoot_ssh_crypto PRIVATE cxx_std_17)
add_dependencies(${BINARY_NAME} tamtoot_ssh_crypto)
target_link_libraries(tamtoot_ssh_crypto PRIVATE bcrypt.lib)
