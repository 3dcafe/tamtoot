"""Render Tamtoot's geometric vector mark. Requires Pillow (build tool only)."""
from pathlib import Path
import json
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
BRAND = ROOT / 'assets/branding'
BG = '#101D35'
BLUE = '#42A5FF'
# Central T stays inside the safe circle for adaptive / maskable icons.
POINTS = [(280, 280), (744, 280), (744, 392), (576, 392),
          (576, 744), (448, 744), (448, 392), (280, 392)]


def render(size, rounded=False):
    scale = 4
    side = size * scale
    image = Image.new('RGBA', (side, side), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((0, 0, side-1, side-1),
                           radius=side * .215 if rounded else 0, fill=BG)
    draw.polygon([(round(x * side / 1024), round(y * side / 1024))
                  for x, y in POINTS], fill=BLUE)
    return image.resize((size, size), Image.Resampling.LANCZOS)


def save(path, size, rounded=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    image = render(size, rounded)
    if not rounded:
        image = image.convert('RGB')
    image.save(path)


def main():
    BRAND.mkdir(parents=True, exist_ok=True)
    points = ' '.join(f'{x},{y}' for x,y in POINTS)
    (BRAND / 'icon.svg').write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">\n'
        '<title>Tamtoot</title>\n'
        f'<rect width="1024" height="1024" rx="220" fill="{BG}"/>\n'
        f'<polygon points="{points}" fill="{BLUE}"/>\n</svg>\n')
    save(BRAND / 'icon.png', 1024, True)
    for platform in ('ios', 'macos'):
        folder = ROOT / platform / 'Runner/Assets.xcassets/AppIcon.appiconset'
        for entry in json.loads((folder / 'Contents.json').read_text())['images']:
            size = round(float(entry['size'].split('x')[0]) *
                         float(entry['scale'].rstrip('x')))
            save(folder / entry['filename'], size, platform == 'macos')
    for density, size in [('mdpi',48), ('hdpi',72), ('xhdpi',96),
                          ('xxhdpi',144), ('xxxhdpi',192)]:
        save(ROOT / f'android/app/src/main/res/mipmap-{density}/ic_launcher.png', size, True)
    for size in (192, 512):
        save(ROOT / f'web/icons/Icon-{size}.png', size, True)
        save(ROOT / f'web/icons/Icon-maskable-{size}.png', size)
    save(ROOT / 'web/favicon.png', 32, True)
    render(256, True).save(ROOT / 'windows/runner/resources/app_icon.ico',
                          sizes=[(n,n) for n in (16,24,32,48,64,128,256)])


if __name__ == '__main__':
    main()
