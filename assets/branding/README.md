# Tamtoot icon

Original geometric blue T (`#42A5FF`) on a navy background (`#101D35`).
`icon.svg` is the editable vector mark; `icon.png` is the full-size preview.

Regenerate platform assets from the geometry in `tool/generate_icons.py`:

```sh
python3 -m pip install Pillow
python3 tool/generate_icons.py
```

Pillow is a development tool, not an application dependency. The script writes
Android, iOS, macOS, Windows and web icon sizes. iOS and web maskable icons have
opaque backgrounds; the T fits inside the maskable safe zone.
