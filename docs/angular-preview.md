# Angular website preview

TamToot detects Angular projects from `angular.json`. Start the project's development server yourself, for example with its existing npm script or Angular CLI. TamToot probes the configured serve port, including the default serve configuration; otherwise it uses `4200`. An HTTP response containing HTML establishes page availability, not the identity of the project serving it.

Choose **Pin preview** below the editor. The site appears alongside the code and supports normal navigation and interaction. Edit the address and press Enter or the reload button to load it. Angular's own live-reload connection remains responsible for refreshing changes after saves.

Drag the visible divider between the editor and website to resize the preview. Double-click the divider for an approximately equal split. On narrow screens the panes stack vertically. Close the preview using its **×** button.

## Platform requirements

| Platform | Browser engine | Requirements |
| --- | --- | --- |
| macOS | System WebKit | Included with macOS. |
| iOS | System WebKit | Included with iOS; allow local-network access when connecting to a computer. |
| Android | System WebView | A functioning Android System WebView provider. |
| Windows | Microsoft WebView2 | WebView2 Runtime on the user's machine. The native SDK is downloaded from Microsoft's NuGet package during configuration of a Windows build. |
| Linux | WebKitGTK 4.1 | Install `webkit2gtk-4.1` development libraries before building, plus the matching runtime libraries on the target machine. On Debian/Ubuntu the development package is typically `libwebkit2gtk-4.1-dev`. Builds without this library retain the app but report that preview is unavailable. |

The platform adapters live in TamToot's own runners; no Flutter WebView package is installed. System browser engines are still required. Without WebView2 Runtime, Windows preview initialization reports an error in the panel; it does not deliberately prevent the rest of TamToot from starting. This missing-runtime path has not yet been exercised on Windows.

## Previewing from a phone or tablet

`localhost` points to the device displaying the preview. For a server running on your computer, use its reachable network address, such as `http://192.168.1.20:4200`. Configure the development server to listen on an appropriate network interface and allow that port through the computer's firewall. Expose the development server only to a network you intend to use.

## Verification status

The native adapters have been added for macOS, Windows, Linux, Android and iOS. A macOS preview was shown during development. Current Dart analysis, Swift syntax and plist checks pass; full native builds and interaction checks across all five platforms remain outstanding.
