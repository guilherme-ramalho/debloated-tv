#!/usr/bin/env python3
"""App Store screenshots v2: 8 frames per language, drawn as HTML and rendered by headless Chrome at 1206x2622 (6.3").

    python3 scripts/store-art.py [lang …]       every language in scripts/store-art.json when none is given

Design (decided Nov 2026 on the "Purio TV store page preview" canvas): frames 1-3 are one panorama (cluttered stock
TV → Purio Home → the remote), then Photos & videos, the four looks on the TV, typing with the iPhone keyboard, Siri,
and "free". Accent teal. Text per language in scripts/store-art.json; headlines shrink to fit their frame.

Inputs:
  ios/build/store-shots-auto/6.3/<lang>/{01-remote,04-type,05-actions,09-show-video}.png   from store-shots-auto.sh
  ios/build/store-shots-auto/assets/   not in git:
    tv-home.jpg   Purio Home (Cinema look) on the TCL, 1920x1080
    calm.png glass.png gallery.png   the looks on the TV emulator (Purio Home 18 via its ThemeProvider), 1920x1080
    family.jpg    Pexels photo 6624373 by Keira Burton (Pexels license: free commercial use, no attribution)
  Emulator wallpapers (Pexels license): 1252890 (Calm), 417074 (Glass), 3408744 (Gallery).

Output: ios/build/store-shots-auto/art/<lang>/NN-<name>.jpg (no alpha: App Store Connect refuses it).
Needs Google Chrome and Pillow; the fonts (Inter, Instrument Serif) load from Google Fonts.
"""
import json
import os
import subprocess
import sys
import tempfile

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOTS = os.path.join(ROOT, 'ios/build/store-shots-auto/6.3')
ASSETS = os.path.join(ROOT, 'ios/build/store-shots-auto/assets')
OUT = os.path.join(ROOT, 'ios/build/store-shots-auto/art')
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
TEXT = json.load(open(os.path.join(ROOT, 'scripts/store-art.json'), encoding='utf-8'))
NAMES = ['01-before', '02-after', '03-remote', '04-photos-videos', '05-looks', '06-type', '07-siri', '08-free']
ACCENT, NAVY, LIGHT, DULL = '#2FD0DE', '#0B1328', '#EEF2F6', '#262A31'
SCALE = 4.02  # 300 css px per frame → 1206 px
W, H = 1206, 2622


def url(path):
    return 'file://' + path


def cross():
    return ('<svg width="18" height="18" viewBox="0 0 18 18"><circle cx="9" cy="9" r="9" fill="#E53935"/>'
            '<path d="M6 6l6 6M12 6l-6 6" stroke="#fff" stroke-width="2" stroke-linecap="round"/></svg>')


def tick():
    return ('<svg width="18" height="18" viewBox="0 0 18 18"><circle cx="9" cy="9" r="9" fill="#0B1328"/>'
            '<path d="M5 9.3l2.6 2.6L13 6.5" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round" '
            'stroke-linejoin="round"/></svg>')


def title(t, color, key_color=None, extra=''):
    kc = f' style="color:{key_color}"' if key_color else ''
    return (f'<div class="title" style="color:{color}"><div class="hd fit">{t[0]}</div>'
            f'<div class="key fit"{kc}>{t[1]}</div>{extra}</div>')


def clutter(a):
    tiles = ''.join(f'<i style="background:{c}"></i>' for c in
                    ['#F4511E', '#00897B', '#EC407A', '#7CB342', '#1E88E5', '#FDD835'])
    small = ''.join(f'<i style="background:{c}"></i>' for c in
                    ['#5E35B1', '#43A047', '#FB8C00', '#E53935', '#039BE5', '#8E24AA', '#C0CA33', '#6D4C41'])
    tabs = ''.join(f'<span{" class=on" if i == 0 else ""}>{t}</span>' for i, t in enumerate(a['tabs']))
    return f'''
<div class="screen clutter">
  <div class="nav">{tabs}<b></b><span class="offer">{a['offer']}</span><u></u><u></u></div>
  <div class="hero"><span class="spons">{a['sponsored']}</span><div class="sale">{a['sale']}</div>
    <div class="btns"><span class="w">{a['trailer']}</span><span class="g">{a['subscribe']}</span></div>
    <i class="p1"></i><i class="p2"></i></div>
  <div class="lbl">{a['row1']}</div><div class="tiles">{tiles}</div>
  <div class="lbl">{a['row2']}</div><div class="tiles small">{small}</div>
  <div class="popup"><div class="t">{a['adTag']}</div><div class="m">{a['popup']}</div><span>{a['start']}</span></div>
</div>'''


def page(lang):
    t = TEXT[lang]
    r = lambda n: url(os.path.join(SHOTS, lang, n + '.png'))
    s = lambda n: url(os.path.join(ASSETS, n))
    icon = url(os.path.join(ROOT, 'ios/Assets.xcassets/AppIcon.appiconset/AppIcon.png'))
    keys = ''.join('<div class="krow">' + ''.join(f'<i{" class=hi" if ch == "f" else ""}>{ch}</i>' for ch in row) + '</div>'
                   for row in ['qwertyuiop', 'asdfghjkl-', 'zxcvbnm,.⌫'])
    looks = t['looks']
    smalls = ''.join(f'<div class="mini"><div class="tv"><img src="{s(f)}"></div><div class="cap">{n}</div></div>'
                     for f, n in zip(['calm.png', 'glass.png', 'gallery.png'], looks[1:]))
    return f'''<!doctype html><html lang="{lang}"><head><meta charset="utf-8">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800;900&family=Instrument+Serif:ital@1&display=block">
<style>
html,body{{margin:0;background:#fff}}
body{{width:2400px;height:652px;position:relative;overflow:hidden;font-family:'Inter',sans-serif;-webkit-font-smoothing:antialiased}}
.f{{position:absolute;top:0;width:300px;height:652px;overflow:hidden}}
.abs{{position:absolute}}
.title{{position:absolute;left:24px;top:44px;width:256px}}
.hd{{font-size:28px;font-weight:800;line-height:1.05;letter-spacing:-0.02em;white-space:nowrap}}
.key{{font-family:'Instrument Serif',serif;font-style:italic;font-size:56px;line-height:0.92;margin-top:4px;white-space:nowrap}}
.body{{font-size:14px;font-weight:600;line-height:1.35;margin-top:12px;opacity:.9}}
.phone{{position:absolute;border-radius:32px;background:#05070C;padding:5px;box-sizing:border-box;box-shadow:0 26px 50px rgba(0,0,0,.45)}}
.phone img{{display:block;width:100%;border-radius:27px}}
.tvb{{position:absolute;background:#05070C;border-radius:9px;padding:6px;box-sizing:border-box;box-shadow:0 24px 50px rgba(5,10,25,.45)}}
.tvb img{{display:block;width:100%;height:auto;border-radius:4px}}
.pop{{position:absolute;background-repeat:no-repeat;box-shadow:0 18px 40px rgba(5,10,25,.45)}}
.list{{position:absolute;top:452px;width:256px;display:flex;flex-direction:column;gap:12px}}
.row{{display:flex;align-items:center;gap:8px;font-size:15px;font-weight:700;line-height:1.2}}
.row svg{{flex:none}}
.screen{{height:197px;border-radius:4px;overflow:hidden;box-sizing:border-box;position:relative}}
.clutter{{background:#10131C;padding:7px 8px;display:flex;flex-direction:column;gap:6px}}
.clutter .nav{{display:flex;align-items:center;gap:9px;font-size:7px;font-weight:600;color:#9AA3B5}}
.clutter .nav .on{{color:#fff;border-bottom:1px solid #fff}}
.clutter .nav b{{flex:1}}
.clutter .nav u{{width:9px;height:9px;border-radius:50%;background:#3A4256}}
.clutter .offer{{background:#E53935;color:#fff;padding:1px 4px;border-radius:6px;font-weight:800}}
.clutter .hero{{position:relative;height:78px;border-radius:4px;background:linear-gradient(100deg,#6A1B9A 0%,#D81B60 55%,#FF7043 100%);padding:8px;box-sizing:border-box}}
.clutter .spons{{font-size:6px;font-weight:800;color:#1A1A1A;background:#FFD54F;padding:1px 4px;border-radius:2px}}
.clutter .sale{{font-size:15px;font-weight:900;color:#fff;line-height:1;margin-top:5px;letter-spacing:-0.02em;position:relative;z-index:1}}
.clutter .btns{{display:flex;gap:4px;margin-top:6px;position:relative;z-index:1}}
.clutter .btns span{{font-size:6px;font-weight:800;padding:2px 5px;border-radius:3px}}
.clutter .btns .w{{background:#fff;color:#111}}
.clutter .btns .g{{background:rgba(255,255,255,.25);color:#fff}}
.clutter .p1{{position:absolute;right:12px;top:10px;width:54px;height:58px;border-radius:4px;background:#FFB300;transform:rotate(6deg)}}
.clutter .p2{{position:absolute;right:44px;top:18px;width:40px;height:50px;border-radius:4px;background:#00BCD4;transform:rotate(-8deg)}}
.clutter .lbl{{font-size:6px;font-weight:700;color:#C9CFDB}}
.clutter .tiles{{display:flex;gap:4px}}
.clutter .tiles i{{flex:1;height:28px;border-radius:3px}}
.clutter .tiles.small{{gap:3px}}
.clutter .tiles.small i{{height:16px}}
.clutter .popup{{position:absolute;right:8px;top:24px;width:112px;background:#fff;border-radius:5px;padding:6px;box-sizing:border-box;box-shadow:0 6px 14px rgba(0,0,0,.5)}}
.clutter .popup .t{{font-size:5px;font-weight:800;color:#E53935}}
.clutter .popup .m{{font-size:7px;font-weight:800;color:#111;line-height:1.15;margin-top:2px}}
.clutter .popup span{{font-size:6px;font-weight:800;color:#fff;background:#1E88E5;border-radius:3px;padding:2px 4px;margin-top:4px;display:inline-block}}
.mini{{width:88px;display:flex;flex-direction:column;gap:6px;align-items:center}}
.mini .tv{{width:88px;background:#05070C;border-radius:5px;padding:3px;box-sizing:border-box;box-shadow:0 10px 22px rgba(5,10,25,.3)}}
.mini img{{display:block;width:100%;border-radius:2px}}
.cap{{font-size:12px;font-weight:700;color:{NAVY}}}
.search{{height:152px;border-radius:3px;background:#0E1422;padding:12px 14px;box-sizing:border-box;display:flex;flex-direction:column;gap:10px;position:relative}}
.field{{height:24px;border-radius:12px;background:#1E2638;display:flex;align-items:center;gap:6px;padding:0 10px;font-size:11px;font-weight:600;color:#fff}}
.caret{{width:1.5px;height:12px;background:{ACCENT}}}
.kb{{display:flex;flex-direction:column;gap:3px;opacity:.45}}
.krow{{display:flex;gap:3px}}
.krow i{{width:19px;height:15px;border-radius:2px;background:#2A3347;color:#8A94AA;font-size:7px;font-weight:600;font-style:normal;display:flex;align-items:center;justify-content:center}}
.krow i.hi{{outline:1.5px solid #fff}}
.chip{{position:absolute;right:12px;bottom:12px;font-size:9px;font-weight:800;color:#fff;background:#E53935;padding:3px 7px;border-radius:8px}}
.bubble{{position:absolute;left:24px;top:204px;max-width:252px;display:flex;align-items:center;gap:8px;padding:11px 16px;border-radius:20px 20px 20px 6px;background:{NAVY};color:#fff;font-size:16px;font-weight:700;box-sizing:border-box;box-shadow:0 12px 26px rgba(11,19,40,.25)}}
.bubble svg{{flex:none}}
</style></head><body>

<div class="f" style="left:0;background:{DULL}"></div>
<div class="f" style="left:300px;background:{ACCENT}"></div>
<div class="f" style="left:600px;background:{LIGHT}"></div>
<div class="tvb" style="left:-22px;top:214px;width:330px">{clutter(t['ad'])}</div>
<div class="tvb" style="left:316px;top:222px;width:340px"><img src="{s('tv-home.jpg')}"></div>
<div class="list" style="left:24px;color:#fff">{''.join(f'<div class="row">{cross()}{x}</div>' for x in t['f1list'])}</div>
<div class="list" style="left:324px;color:{NAVY}">{''.join(f'<div class="row">{tick()}{x}</div>' for x in t['f2list'])}
  <div style="font-size:13px;font-weight:600;opacity:.8;margin-top:10px">{t['f2note']}</div></div>
<div class="phone" style="left:630px;top:196px;width:244px;transform:rotate(4deg);box-shadow:0 26px 50px rgba(11,19,40,.35)"><img src="{r('01-remote')}"></div>
<div style="position:absolute;left:0;top:0">{title(t['f1'], '#fff', '#FFD54F')}</div>
<div style="position:absolute;left:300px;top:0">{title(t['f2'], NAVY)}</div>
<div style="position:absolute;left:600px;top:0">{title(t['f3'], NAVY)}</div>

<div class="f" style="left:900px;background:{NAVY}">
  <div class="tvb" style="left:10px;top:290px;width:280px;padding:5px;transform:rotate(-2deg)">
    <div style="position:relative;height:152px;border-radius:3px;overflow:hidden">
      <img src="{s('family.jpg')}" style="width:100%;height:100%;object-fit:cover;object-position:50% 40%;border-radius:0">
      <div class="abs" style="left:0;right:0;bottom:0;height:34px;background:linear-gradient(rgba(0,0,0,0),rgba(0,0,0,.55))"></div>
      <div class="abs" style="left:10px;right:10px;bottom:9px;display:flex;align-items:center;gap:6px">
        <svg width="10" height="10" viewBox="0 0 10 10"><path d="M2 1l7 4-7 4z" fill="#fff"/></svg>
        <div style="flex:1;height:3px;border-radius:2px;background:rgba(255,255,255,.45)"><div style="width:58%;height:3px;border-radius:2px;background:#fff"></div></div>
        <div style="font-size:8px;font-weight:700;color:#fff">0:12</div></div></div></div>
  <div class="phone" style="left:124px;top:440px;width:168px;border-radius:26px;transform:rotate(6deg)"><img src="{r('09-show-video')}" style="border-radius:21px"></div>
  {title(t['f4'], '#fff', ACCENT, f'<div class="body">{t["f4body"]}</div>')}
</div>

<div class="f" style="left:1200px;background:{LIGHT}">
  <div class="tvb" style="left:10px;top:206px;width:280px;padding:5px"><img src="{s('tv-home.jpg')}"></div>
  <div class="abs" style="left:10px;top:372px;display:flex;align-items:center;gap:6px;font-size:13px;font-weight:800;color:{NAVY}">
    <svg width="16" height="16" viewBox="0 0 18 18"><circle cx="9" cy="9" r="9" fill="#0B1328"/><path d="M5 9.3l2.6 2.6L13 6.5" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>{looks[0]}</div>
  <div class="abs" style="left:10px;top:408px;width:280px;display:flex;gap:8px">{smalls}</div>
  <div class="abs" style="left:24px;top:530px;width:256px;font-size:15px;font-weight:700;line-height:1.3;color:{NAVY}">{t['f5note']}</div>
  {title(t['f5'], NAVY)}
</div>

<div class="f" style="left:1500px;background:{NAVY}">
  <div class="tvb" style="left:10px;top:214px;width:280px;padding:5px"><div class="search">
    <div class="field"><svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="#8A94AA" stroke-width="3" stroke-linecap="round"><circle cx="10.5" cy="10.5" r="6.5"/><path d="M15.5 15.5 21 21"/></svg><span>the quiet coast</span><span class="caret"></span></div>
    <div class="kb">{keys}</div><div class="chip">{t['f6chip']}</div></div></div>
  <div class="pop" style="left:10px;top:418px;width:280px;height:162.5px;background-image:url('{r('04-type')}');background-size:280px auto;background-position:0 -404px;border-radius:18px;transform:rotate(-2deg)"></div>
  {title(t['f6'], '#fff', ACCENT)}
</div>

<div class="f" style="left:1800px;background:{LIGHT}">
  <div class="bubble"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2.2" stroke-linecap="round"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg><span>{t['f7bubble']}</span></div>
  <div class="pop" style="left:20px;top:268px;width:260px;height:112px;background-image:url('{r('05-actions')}');background-size:287.7px auto;background-position:-14.3px -109.7px;border-radius:14px"></div>
  <svg class="abs" style="left:138px;top:402px" width="24" height="18" viewBox="0 0 24 18"><path d="M4 4l8 8 8-8" stroke="#0B1328" stroke-width="3" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>
  <div class="tvb" style="left:10px;top:426px;width:280px;padding:5px"><img src="{s('tv-home.jpg')}"></div>
  {title(t['f7'], NAVY)}
</div>

<div class="f" style="left:2100px;background:{ACCENT}">
  <img src="{icon}" class="abs" style="left:24px;top:410px;width:120px;height:120px;border-radius:28px;transform:rotate(-6deg);box-shadow:0 20px 40px rgba(5,10,25,.35)">
  <div class="abs" style="left:160px;top:438px;width:130px;font-size:16px;font-weight:800;line-height:1.25;color:{NAVY}">{t['f8tv']}</div>
  <div class="title" style="color:{NAVY}"><div class="hd fit">{t['f8'][0]}</div>
    <div class="key fit" style="font-size:150px;line-height:.82;margin-top:2px">{t['f8'][1]}</div>
    <div style="font-size:18px;font-weight:700;line-height:1.25;margin-top:18px">{t['f8note']}</div></div>
</div>

<script>
document.fonts.ready.then(() => {{
  for (const el of document.querySelectorAll('.fit')) {{
    let size = parseFloat(getComputedStyle(el).fontSize);
    while (el.scrollWidth > el.clientWidth + 0.5 && size > 16) {{ size -= 1; el.style.fontSize = size + 'px'; }}
  }}
  document.body.setAttribute('data-ready', '1');
}});
</script>
</body></html>'''


def render(lang):
    os.makedirs(os.path.join(OUT, lang), exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        html = os.path.join(tmp, 'page.html')
        png = os.path.join(tmp, 'page.png')
        open(html, 'w', encoding='utf-8').write(page(lang))
        subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars', '--allow-file-access-from-files',
                        f'--force-device-scale-factor={SCALE}', '--window-size=2400,653', '--virtual-time-budget=15000',
                        f'--screenshot={png}', url(html)], check=True, capture_output=True)
        full = Image.open(png).convert('RGB')
        for i, name in enumerate(NAMES):
            full.crop((i * W, 0, (i + 1) * W, H)).save(os.path.join(OUT, lang, name + '.jpg'), quality=92)
    print(lang, full.size)


if __name__ == '__main__':
    for lang in sys.argv[1:] or [k for k in TEXT if not k.startswith('_')]:
        render(lang)
