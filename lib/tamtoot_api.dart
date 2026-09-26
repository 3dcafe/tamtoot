/// Public extension contract. Breaking changes increment ideApiVersion.
/// See docs/extension-api.md for lifecycle, permissions and version semantics.
library;

export 'core/commands/commands.dart' show CommandDescriptor, CommandRegistry;
export 'core/extensions/plugin_api.dart';
export 'core/filesystem/filesystem.dart' show FileSystemProvider, FileEntry;
export 'core/settings/settings.dart' show SettingsService;
export 'core/themes/ide_theme.dart' show IdeTheme;
export 'editor/buffer/text_buffer.dart';
export 'editor/document/editor_controller.dart'
    show EditorController, EditorSelection, Decoration, FoldingRegion;
export 'languages/language_registry.dart';

const int ideApiVersion = 1;
