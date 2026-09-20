#!/usr/bin/env python3
"""Renders public/og.png (1200x630): the app icon, the name and the tagline on the
site's graphite background, in Inter. Run from web/: python3 scripts/og-image.py
(needs Pillow: pip install pillow)."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

WEB = Path(__file__).resolve().parent.parent
FONTS = WEB.parent / "app/NeuralSheet/Resources/Fonts"
W, H = 1200, 630
BG, TEXT, MUTED = (0x13, 0x14, 0x17), (0xF2, 0xF4, 0xF7), (0x9B, 0xA1, 0xAB)

card = Image.new("RGBA", (W, H), BG + (255,))
icon = Image.open(WEB / "src/assets/icon.png").convert("RGBA")
icon = icon.crop((100, 100, 924, 924)).resize((200, 200), Image.LANCZOS)
card.alpha_composite(icon, (96, 118))

draw = ImageDraw.Draw(card)
name = ImageFont.truetype(str(FONTS / "Inter-SemiBold.ttf"), 76)
lead = ImageFont.truetype(str(FONTS / "Inter-Regular.ttf"), 34)
small = ImageFont.truetype(str(FONTS / "Inter-Medium.ttf"), 26)
draw.text((340, 130), "NeuralSheet", font=name, fill=TEXT)
draw.text((340, 232), "Audio-to-MIDI transcription", font=lead, fill=TEXT)
draw.text((340, 278), "as a native macOS app.", font=lead, fill=TEXT)
draw.text((96, 470), "Free  ·  Open source  ·  Runs entirely on your Mac", font=small, fill=MUTED)
draw.text((96, 512), "neural-sheet.quassum.com", font=small, fill=MUTED)

card.convert("RGB").save(WEB / "public/og.png", optimize=True)
print("wrote", WEB / "public/og.png", card.size)
