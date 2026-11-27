#!/usr/bin/env python3
"""Generate Resources/images/BalanceBar.icon (Icon Composer document) from the traced BalanceBar artwork.

All coordinates are in the ORIGINAL 1024px icon artwork, where the squircle spans x 96..928.
Icon Composer's canvas is the squircle itself, so everything is scaled by K around the centre.
Run: python3 -I scripts/make-liquid-glass-icon.py Resources/images/BalanceBar.icon
Check with ictool from Icon Composer.app/Contents/Executables:
  ictool Resources/images/BalanceBar.icon --export-image --output-file /tmp/bb.png \
         --platform macOS --rendition Default --width 512 --height 512 --scale 2
"""
import json
import math
import sys
from pathlib import Path

K = 1024 / 832
W = 64                                   # ray width
TEAL, ORANGE, YELLOW = '#35ADB3', '#F97B1C', '#FC9F0B'
DOT = '#30D158'                          # system green
GRADIENT = 'url(#g)'                     # teal -> yellow, bottom ray only
BACKGROUND = 'srgb:1.00000,1.00000,1.00000,1.00000'   # white; the system adds a subtle top-to-bottom gradient

# Every ray starts at CENTER (the green dot) and runs straight out to its tip.
CENTER = (514, 519)
# (name, tip, colour) -- listed BACK to FRONT, as in the original artwork
RAYS = [
    ('teal-upper-left', (307, 337), TEAL),
    ('teal-top', (430, 262), TEAL),
    ('yellow-upper-right', (707, 322), YELLOW),
    ('yellow-right', (777, 447), YELLOW),
    ('orange-top', (584, 261), ORANGE),
    ('orange-left', (257, 484), ORANGE),
    ('orange-lower-left', (318, 662), ORANGE),
    ('teal-lower-left', (383, 742), TEAL),
    ('gradient-bottom', (576, 770), GRADIENT),
    ('orange-bottom', (478, 769), ORANGE),
    ('yellow-lower-right', (737, 664), YELLOW),
    ('orange-lower-right', (694, 715), ORANGE),
    ('orange-right', (783, 555), ORANGE),
]
PILL = dict(cx=514.5, cy=517, w=385, h=126, fill='#262626')
# SF Pro Semibold 84pt outlines, already positioned (centres x=405 / x=634, y=518)
PERCENT = "M385.5 518.4Q381.4 518.4 378.5 516.5Q375.5 514.7 373.9 511.2Q372.4 507.8 372.4 503.1L372.4 503.1Q372.4 498.4 373.9 495.0Q375.5 491.6 378.5 489.7Q381.4 487.8 385.5 487.8Q389.5 487.8 392.5 489.7Q395.4 491.6 397.0 495.0Q398.5 498.4 398.5 503.1L398.5 503.1Q398.5 507.8 397.0 511.2Q395.4 514.7 392.5 516.5Q389.5 518.4 385.5 518.4ZM385.5 512.3Q388.1 512.3 389.6 509.9Q391.0 507.5 391.0 503.1L391.0 503.1Q391.0 498.7 389.6 496.3Q388.1 494.0 385.5 494.0Q382.8 494.0 381.3 496.3Q379.9 498.7 379.9 503.1L379.9 503.1Q379.9 507.5 381.3 509.9Q382.8 512.3 385.5 512.3ZM390.3 547.5L382.1 547.5L419.7 488.4L427.9 488.4ZM424.5 548.1Q420.4 548.1 417.5 546.2Q414.5 544.4 413.0 540.9Q411.4 537.5 411.4 532.8L411.4 532.8Q411.4 528.1 413.0 524.7Q414.5 521.3 417.5 519.4Q420.4 517.5 424.5 517.5Q428.5 517.5 431.5 519.4Q434.4 521.3 436.0 524.7Q437.5 528.1 437.5 532.8L437.5 532.8Q437.5 537.5 436.0 540.9Q434.4 544.4 431.5 546.2Q428.5 548.1 424.5 548.1ZM424.5 541.9Q427.1 541.9 428.6 539.6Q430.0 537.2 430.0 532.8L430.0 532.8Q430.0 528.4 428.6 526.0Q427.1 523.7 424.5 523.7Q421.8 523.7 420.4 526.0Q418.9 528.4 418.9 532.8L418.9 532.8Q418.9 537.2 420.4 539.6Q421.8 541.9 424.5 541.9Z"
DOLLAR = "M634.1 546.7Q628.1 546.7 623.3 544.8Q618.5 542.9 615.6 539.3Q612.7 535.6 612.3 530.6L612.3 530.0L621.8 530.0L621.9 530.5Q622.3 532.8 623.7 534.6Q625.1 536.4 627.7 537.5Q630.3 538.5 634.4 538.5Q638.4 538.5 640.9 537.5Q643.4 536.5 644.6 534.7Q645.8 533.0 645.8 530.8L645.8 530.7Q645.8 528.7 644.9 527.3Q644.1 525.9 642.0 524.8Q640.0 523.7 636.2 522.8L629.6 521.4Q624.3 520.2 620.7 518.1Q617.0 516.0 615.2 512.9Q613.4 509.9 613.4 505.6L613.4 505.6Q613.4 500.6 616.0 496.9Q618.7 493.3 623.3 491.2Q628.0 489.2 634.0 489.2Q639.9 489.2 644.5 491.1Q649.1 493.1 651.8 496.6Q654.5 500.2 654.9 505.1L654.9 505.8L645.4 505.8L645.3 505.4Q645.0 502.9 643.5 501.1Q642.0 499.3 639.6 498.3Q637.2 497.4 634.0 497.4Q630.4 497.4 628.1 498.4Q625.7 499.5 624.4 501.2Q623.2 502.9 623.2 504.9L623.2 504.9Q623.2 506.7 624.1 508.1Q625.0 509.6 626.9 510.7Q628.9 511.8 632.1 512.5L638.8 514.0Q644.4 515.2 648.1 517.2Q651.9 519.2 653.8 522.3Q655.6 525.4 655.6 529.8L655.6 529.9Q655.6 535.3 652.8 539.0Q649.9 542.8 645.1 544.7Q640.2 546.7 634.1 546.7ZM631.9 553.5L631.9 482.4L636.3 482.4L636.3 553.5Z"
DOT_RADIUS = 20

GRAD_DEFS = ('<defs><linearGradient id="g" gradientUnits="userSpaceOnUse" x1="556" y1="650" x2="572" y2="740">'
             f'<stop offset="0" stop-color="{TEAL}"/><stop offset="1" stop-color="{YELLOW}"/></linearGradient></defs>')

def svg(body, defs=''):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">' + defs +
            f'<g transform="translate(512 512) scale({K:.5f}) translate(-512 -512)">{body}</g></svg>')

def capsule(start, tip, colour):
    # filled path, NOT a stroked <line>: CoreSVG clips stroke caps to the geometry bounds
    (sx, sy), (tx, ty), r = start, tip, W / 2
    dx, dy = tx - sx, ty - sy
    length = math.hypot(dx, dy)
    nx, ny = -dy / length, dx / length

    def point(x, y):
        return f'{x:.2f} {y:.2f}'

    d = (f'M{point(sx+nx*r, sy+ny*r)}L{point(tx+nx*r, ty+ny*r)}A{r} {r} 0 0 0 {point(tx-nx*r, ty-ny*r)}'
         f'L{point(sx-nx*r, sy-ny*r)}A{r} {r} 0 0 0 {point(sx+nx*r, sy+ny*r)}Z')
    return f'<path d="{d}" fill="{colour}"/>'

def main(doc):
    assets = doc / 'Assets'
    assets.mkdir(parents=True, exist_ok=True)
    layers = []
    for i, (name, tip, colour) in enumerate(RAYS, 1):
        fn = f'ray-{i:02d}-{name}.svg'
        (assets / fn).write_text(
            svg(capsule(CENTER, tip, colour), GRAD_DEFS if colour == GRADIENT else '') + '\n',
            encoding='utf-8',
        )
        layers.append({'name': name, 'image-name': fn, 'glass': True})
    p = PILL
    (assets / 'pill.svg').write_text(svg(
        f'<rect x="{p["cx"]-p["w"]/2}" y="{p["cy"]-p["h"]/2}" width="{p["w"]}" height="{p["h"]}" rx="{p["h"]/2}" fill="{p["fill"]}"/>') + '\n', encoding='utf-8')
    cx, cy = CENTER
    (assets / 'glyphs.svg').write_text(svg(
        f'<path d="{PERCENT}" fill="#FFFFFF"/><path d="{DOLLAR}" fill="#FFFFFF"/>'
        f'<circle cx="{cx}" cy="{cy}" r="{DOT_RADIUS}" fill="{DOT}"/>') + '\n', encoding='utf-8')
    icon = {
        'fill': {'automatic-gradient': BACKGROUND},
        # groups[0] is the FRONT-most group; inside a group, layers[0] is the front-most layer
        'groups': [
            {'name': 'Glyphs', 'layers': [{'name': 'glyphs', 'image-name': 'glyphs.svg', 'glass': False}],
             'shadow': {'kind': 'none', 'opacity': 0.5}, 'translucency': {'enabled': False, 'value': 0.5}, 'specular': False},
            {'name': 'Pill', 'layers': [{'name': 'pill', 'image-name': 'pill.svg', 'glass': True}],
             'shadow': {'kind': 'neutral', 'opacity': 0.5}, 'translucency': {'enabled': True, 'value': 0.15}, 'specular': True},
            {'name': 'Rays', 'layers': list(reversed(layers)),
             'shadow': {'kind': 'neutral', 'opacity': 0.5}, 'translucency': {'enabled': False, 'value': 0.5}, 'specular': True},
        ],
        'supported-platforms': {'squares': 'shared'},
    }
    (doc / 'icon.json').write_text(json.dumps(icon, indent=2) + '\n', encoding='utf-8')

if __name__ == '__main__':
    main(Path(sys.argv[1] if len(sys.argv) > 1 else 'Resources/images/BalanceBar.icon'))
