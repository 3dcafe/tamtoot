# Project file templates

Solution → **+** → **New file…** creates a saved file inside the selected workspace. **New folder…** creates a directory; **Add folder to workspace…** attaches an existing root. Choose an existing destination using its relative path. The file opens in the editor after creation. Existing files and directories are not overwritten.

The selected launch project suggests C# or Dart; an active file provides a fallback language hint. Users can choose any installed language, an empty file, a template, and an editable extension. A separate name field avoids accidentally appending extensions twice.

Language packages can declare optional `fileTemplates` in `language.json`:

```json
"fileTemplates": {
  "class": {
    "name": "Class",
    "extension": ".cs",
    "body": "public class {{name}}\n{\n}\n"
  }
}
```

The first template is suggested by default. `{{name}}` expands to the filename stem. C# and Dart templates require a simple valid identifier; choose Empty file for other filenames. Template bodies are text, with no scripts or commands executed. Packages without templates still offer an empty file with their first registered extension.
