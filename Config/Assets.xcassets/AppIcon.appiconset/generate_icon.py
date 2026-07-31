from pathlib import Path

from PIL import Image, ImageDraw

root = Path(__file__).parent
logical_size = 16

# Pixel-art palette: graphite tile with mint/teal download bars and violet upload bar.
background = (18, 22, 30)
frame = (43, 51, 64)
download = (37, 210, 173)
teal = (71, 221, 190)
upload = (139, 124, 255)

image = Image.new("RGB", (logical_size, logical_size), background)
draw = ImageDraw.Draw(image)

# Stepped inner tile. Integer rectangles keep every edge crisp at 16px.
draw.rectangle((2, 1, 13, 1), fill=frame)
draw.rectangle((1, 2, 14, 13), fill=frame)
draw.rectangle((2, 14, 13, 14), fill=frame)
draw.rectangle((2, 2, 13, 13), fill=background)

# Usage histogram: low download, medium transfer, high upload.
draw.rectangle((3, 10, 5, 12), fill=download)
draw.rectangle((7, 7, 9, 12), fill=teal)
draw.rectangle((11, 4, 13, 12), fill=upload)
draw.rectangle((3, 13, 13, 13), fill=frame)

items = [
    (16, "AppIcon-16.png"),
    (32, "AppIcon-16@2x.png"),
    (32, "AppIcon-32.png"),
    (64, "AppIcon-32@2x.png"),
    (128, "AppIcon-128.png"),
    (256, "AppIcon-128@2x.png"),
    (256, "AppIcon-256.png"),
    (512, "AppIcon-256@2x.png"),
    (512, "AppIcon-512.png"),
    (1024, "AppIcon-512@2x.png"),
]
expected = {filename for _, filename in items}

for pixels, filename in items:
    output = image.resize((pixels, pixels), Image.Resampling.NEAREST)
    output_path = root / filename
    output.save(output_path, optimize=True)

    with Image.open(output_path) as generated:
        assert generated.size == (pixels, pixels), (filename, generated.size)
        assert generated.mode == "RGB", (filename, generated.mode)

actual = {path.name for path in root.glob("AppIcon-*.png") if path.name != "AppIcon-1024.png"}
assert actual == expected, (sorted(actual), sorted(expected))
print(f"Generated {len(items)} pixel-art AppIcon assets")
