# Accessibility statement

Tamtoot aims to make editing code and using project tools accessible to people
with disabilities, including people who use a keyboard, a screen reader,
magnification, or alternative input devices. Accessibility is part of product
quality. We welcome feedback from people who encounter barriers and invite them
to help evaluate proposed fixes, if they wish.

This statement covers the Tamtoot application and this repository's documentation.
It describes the current implementation; features can differ between releases.

## Goals and current status

We use [WCAG 2.2 Level AA](https://www.w3.org/TR/WCAG22/) as a reference for
improving our interfaces and documentation, applying relevant principles to the
native application as well as the web version. Our priorities are keyboard
operation, meaningful screen reader information, visible focus, readable text,
adequate contrast, and alternatives to gestures and dragging.

Tamtoot has not undergone a comprehensive accessibility audit. We do not claim
WCAG conformance or complete compatibility with assistive technologies.
Automated functional tests do not establish screen reader accessibility.

## Environments

Tamtoot has application targets for Windows, macOS, Linux, Android, iOS, and web.
Availability of packaged releases and platform-specific features varies; see the
[README](README.md) for setup and release information.

Assistive technology compatibility has not been systematically verified on any
of these targets. In particular, we have not established compatibility with
NVDA or Narrator on Windows, VoiceOver on macOS or iOS, Orca on Linux, or TalkBack
on Android. The web target is also unverified with browser/screen reader
combinations. Please do not interpret a supported build target as a guarantee
of accessibility.

## Features that may help

- Common editing actions have keyboard shortcuts, including save, undo, find,
  and the command palette. Keybindings can be changed in **Tools → Settings**.
- **View → Command palette**, or **Ctrl+Shift+P** / **Command+Shift+P**, provides a
  searchable list of commands.
- **Tools → Settings** provides light and dark themes, editor font selection,
  and an editor font size setting from 8 to 40.
- Files can be opened using **File → Open file**, as an alternative to dropping
  files onto the application.
- HTTP requests can be moved using the **Move** action or their **Folder** field
  and **Save**, as alternatives to drag and drop.
- The Output panel contains selectable text that can be copied for inspection
  in another tool.

These features are useful starting points. They do not guarantee that every
workflow is accessible without a pointer.

## Known limitations and alternatives

- **Code editor:** the custom-drawn editor has a basic accessibility label, but
  does not yet provide a complete accessible representation of document text,
  selection, cursor position, folding, and completion suggestions. Screen reader
  editing may be limited or unusable. If this blocks your work, edit the same
  file with an editor compatible with your assistive technology and reopen it
  in Tamtoot. Avoid making conflicting unsaved edits in both applications.
- **SSH terminal:** terminal output is custom-drawn and does not yet expose a
  complete screen reader representation or reliably announce remote output.
  The copy action can export the selection or screen, but is not a complete
  alternative to accessible interactive use. Consider a compatible external SSH
  client when this prevents you from working.
- **Navigation and focus:** keyboard access, focus visibility, focus restoration,
  and announcements of status or errors have not been verified across all
  dialogs, panels, previews, and platform combinations. Panel resizing currently
  relies on dragging; **View → Restore default layout** can restore the default layout.
- **Text, contrast, and motion:** custom surfaces and compact controls may not
  fully follow system text scaling, high contrast, or reduced motion settings.
  Light/dark themes and editor font settings may help, but contrast ratios and
  large-text layouts have not been comprehensively audited.
- **Previews and external content:** accessibility of embedded websites,
  rendered documents, images, and third-party tools depends partly on their
  content and implementation. Equivalent descriptions or accessible interaction
  may not be available.

## Report an accessibility barrier

Use the [accessibility report template](https://github.com/3dcafe/tamtoot/issues/new?template=accessibility_report.md).
If the template is difficult to use, a
[plain issue](https://github.com/3dcafe/tamtoot/issues/new) with
“Accessibility” in its title is equally welcome. Reports may be written in
English or Russian.

Describe what you were trying to do and what prevented you from doing it.
When available, include:

- Tamtoot version or commit, operating system, and browser for the web target.
- Assistive technology or input method and its version.
- Steps to reproduce, expected behavior, and actual behavior.
- Whether the barrier blocks the task and whether a workaround exists.

Partial reports are welcome. Screenshots, recordings, logs, and personal
medical information are not required. Public issues are visible to everyone;
remove credentials, server addresses, and other sensitive information from
attachments. For security-related problems, follow the
[security reporting policy](SECURITY.md).

We aim to prioritize barriers that prevent core tasks, investigate reports,
and share workarounds or progress when available. As a volunteer project,
Tamtoot cannot guarantee a response or resolution deadline. Maintainers may ask
for clarification; participation in follow-up testing is optional.

## Contribution and assessment

For interface changes, contributors should check keyboard operation and focus,
control labels, contrast, text scaling, motion, and alternatives to pointer
gestures. Check relevant flows with a platform screen reader when possible,
and document what was tested and what remains unverified in the pull request.
Prefer standard accessible controls over custom interaction where practical.

For documentation, use meaningful headings and link text, text alternatives for
informative images, and captions or transcripts for instructional media. Do not
communicate essential information through color alone.

Current tests cover selected functional behaviors such as keyboard commands,
input, and layout. A dedicated accessibility audit and comprehensive assistive
technology test matrix remain to be done. We aim to update this statement as
verified support and known limitations change.

This statement follows the
[Open Source Guides accessibility recommendations](https://opensource.guide/accessibility-best-practices-for-your-project/)
and [W3C guidance on accessibility statements](https://www.w3.org/WAI/planning/statements/).

Last reviewed: **15 October 2026**.
