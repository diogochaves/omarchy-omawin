"""Builds the cover (preview.png, 1600x900) and the GitHub social preview
(docs/social-preview.png, 1280x640) from one shot of the stopped card.

The shot: an omabox at 3840x2160, scale 3, Tokyo Night, stock bar, with the
card open on a stopped VM whose cache gives it a shape, a key and a last run:

    omabox up --plugin . --theme tokyo-night --stock-bar --size 3840x2160,scale=3
    H=$(omabox path --home)
    echo 'o.bind("SUPER + ALT + W", "Windows VM", "omarchy-shell chaves.omawin primary")' \\
      >> $H/.config/hypr/bindings.lua
    LS=$(date -d 'today 11:40' +%s)    # lastSeen is milliseconds
    printf '{"cores": 4, "ram": "8G", "disk": "64G", "started": %s, "lastSeen": %s000}\\n' \\
      $((LS - 5400)) $LS > $H/.local/state/omawin/state.json
    omabox restart-shell
    omabox run -- omarchy-shell chaves.omawin open
    omabox run -- omarchy-shell chaves.omawin mock "stopped installed=1 docker=active pid= frozen= cores= ram= web=000 cid= started= disk=64G login=chaves" no ""
    omabox shot --no-pointer -o stopped.png

Then: python3 docs/cover/compose.py stopped.png (from the repo root).
"""
import sys
from PIL import Image, ImageDraw, ImageFont

FONT = '/usr/share/fonts/TTF/JetBrainsMonoNerdFont-'
WHITE = (255, 255, 255)
FG = (192, 202, 245)    # Tokyo Night foreground
DIM = (154, 165, 206)
BG = (26, 27, 38)       # Tokyo Night background, the bar's


def font(weight, size):
    return ImageFont.truetype(FONT + weight + '.ttf', size)


def fade_left(im, end, strength):
    # The theme's background over the wallpaper, solid at the left edge and
    # gone at `end`, so the words read on it.
    w, h = im.size
    mask = Image.new('L', (w, h), 0)
    draw = ImageDraw.Draw(mask)
    for x in range(min(end, w)):
        draw.line([(x, 0), (x, h)], fill=int(255 * strength * (1 - x / end) ** 1.6))
    return Image.composite(Image.new('RGB', (w, h), BG), im, mask)


def compose(shot, W, H, scale):
    # The bar's right end and the card, anchored at the top-right corner,
    # the card scaled to `scale` of its 3x size; the name at the left.
    k = W / 1280
    crop_w, crop_h = int(W / (scale * k)), int(H / (scale * k))
    im = shot.crop((3840 - crop_w, 0, 3840, crop_h)).resize((W, H), Image.LANCZOS)
    im = fade_left(im, int(W * 0.42), 0.94)
    draw = ImageDraw.Draw(im)
    x = int(56 * k)
    draw.text((x, int(H * 0.30)), 'Omawin', font=font('Bold', int(84 * k)), fill=WHITE)
    draw.text((x, int(H * 0.30) + int(108 * k)), 'Windows,\nfrom the bar.',
              font=font('Regular', int(34 * k)), fill=FG, spacing=int(6 * k))
    draw.text((x, H - int(56 * k)), "for Omarchy's Windows 11 VM",
              font=font('Regular', int(17 * k)), fill=DIM)
    return im


shot = Image.open(sys.argv[1]).convert('RGB')
assert shot.size == (3840, 2160), 'the shot must be 3840x2160 (scale 3)'
# The clock is the time of the shot: blank the bar between the workspaces
# and the tray, so no crop cuts it in half.
ImageDraw.Draw(shot).rectangle((1400, 0, 3300, 77), fill=BG)
compose(shot, 1280, 640, 0.66).save('docs/social-preview.png', optimize=True)
compose(shot, 1600, 900, 0.70).save('preview.png', optimize=True)
print('wrote docs/social-preview.png and preview.png')
