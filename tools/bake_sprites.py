#!/usr/bin/env python3
"""Bake VN-style sprite layers for GrokAvatar from Models/anime-face.jpg (v4, denser mouths).

Outputs (canvas 1024x1024; crops are positioned via sprite_manifest.json):
  head_{H}.png          opaque full head base (eyes center, painted smile)             7
  eyes_{H}_{E}.png      eye-band crop over the head base (feathered rect edges)   7x17=119
  mouth_{H}_{M}.png     transparent mouth crop (covers smile + draws mouth)       7x16=112
  sprite_manifest.json  {"canvas":1024, "rects": {name: [x,y,w,h]}, ...}
H = left3,left2,left1,center,right1,right2,right3   (7 yaw steps, 12px feature slide per step)
E = center, left1..3 / right1..3 (iris 5/10/15px), up1..3 / down1..3 (3/6/9px),
    blink1 (lid 22%), blink2 (45%), blink3 (70%), closed
M = o0 (painted smile) .. o15 (wide open), 16 openness tiers for smoother lip-sync
Usage: python3 bake_sprites.py <src.jpg> <outdir>
"""
import sys, os
import numpy as np, cv2
from scipy import ndimage as ndi
from PIL import Image, ImageDraw, ImageFilter

SRC = sys.argv[1] if len(sys.argv) > 1 else 'anime-face.jpg'
OUT = sys.argv[2] if len(sys.argv) > 2 else 'out'
os.makedirs(OUT, exist_ok=True)
SS = 4  # supersampling for vector drawing

img = np.array(Image.open(SRC).convert('RGB')).astype(np.float32)
H, W = img.shape[:2]
r, g, b = img[..., 0], img[..., 1], img[..., 2]
lum = (r + g + b) / 3

# ---------------- calibration (from the art) ----------------
IRIS = [  # (cx, cy, rx, ry)  left eye, right eye  (screen left/right)
    (368, 592, 56, 66),
    (667, 587, 55, 66),
]
EYE_BOX = [(270, 505, 440, 665), (595, 500, 765, 660)]
LASH_BOX = [(254, 503, 440, 668), (595, 498, 781, 664)]
MOUTH_C = (518, 750)
SKIN = np.array([255, 234, 215], np.float32)

def feather(mask, rad):
    m = mask.astype(np.float32)
    if rad > 0:
        m = cv2.GaussianBlur(m, (0, 0), rad)
    return np.clip(m, 0, 1)

# ---------------- eye interior (sclera + iris) ----------------
scl = ((g - b) < 10) & (lum > 120) & ((r - b) < 30)
box = np.zeros((H, W), bool)
for x0, y0, x1, y1 in EYE_BOX:
    box[y0:y1, x0:x1] = True
scl &= box
iris_m = np.zeros((H, W), np.uint8)
for cx, cy, rx, ry in IRIS:
    cv2.ellipse(iris_m, (cx, cy), (rx, ry), 0, 0, 360, 1, -1)
M = (scl | (iris_m > 0)).astype(np.uint8)
M = cv2.morphologyEx(M, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
M = cv2.morphologyEx(M, cv2.MORPH_CLOSE, np.ones((7, 7), np.uint8))
M = ndi.binary_fill_holes(M)
lab, n = ndi.label(M)
sizes = ndi.sum(M, lab, range(1, n + 1))
interior = np.isin(lab, 1 + np.argsort(sizes)[-2:])
iris_m = (iris_m > 0) & interior

def sclera_layer():
    """Synthesised empty sclera: per-row median of visible sclera pixels per eye."""
    out = img.copy()
    for (x0, y0, x1, y1) in EYE_BOX:
        sub_int = interior[y0:y1, x0:x1]
        sub_iris = iris_m[y0:y1, x0:x1]
        visible = sub_int & ~sub_iris
        rows = []
        for yy in range(y1 - y0):
            px = img[y0 + yy, x0:x1][visible[yy]]
            rows.append(np.median(px, 0) if len(px) >= 3 else None)
        # fill missing rows from nearest valid
        valid = [i for i, v in enumerate(rows) if v is not None]
        for i in range(len(rows)):
            if rows[i] is None:
                j = min(valid, key=lambda k: abs(k - i))
                rows[i] = rows[j]
        col = np.array(rows, np.float32)
        col = ndi.uniform_filter1d(col, 5, axis=0)
        # top shadow under the lash: darken first rows of each column
        top = np.where(sub_int.any(0), sub_int.argmax(0), 0)
        yy = np.arange(y1 - y0)[:, None]
        d = (yy - top[None, :]).astype(np.float32)
        shade = np.clip(1 - d / 22.0, 0, 1)[..., None] * 0.13
        fill = col[:, None, :] * (1 - shade)
        out[y0:y1, x0:x1] = fill
    return out

SCLERA = sclera_layer()
int_soft = feather(interior, 0.8)

def eyes_look(dx, dy):
    """Move the painted iris (with its highlights) inside the eye opening."""
    base = img.copy()
    # 1) clear original iris area to sclera (inside interior only)
    clear = feather(cv2.dilate(iris_m.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0, 0.8) * int_soft
    base = base * (1 - clear[..., None]) + SCLERA * clear[..., None]
    # 2) paste shifted iris, clipped to interior
    T = np.float32([[1, 0, dx], [0, 1, dy]])
    shifted = cv2.warpAffine(img, T, (W, H), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT)
    im_sh = cv2.warpAffine(feather(iris_m, 0.7), T, (W, H), flags=cv2.INTER_LINEAR)
    a = (im_sh * int_soft)[..., None]
    base = base * (1 - a) + shifted * a
    return base

# ---------------- closed eyes ----------------
def lash_mask():
    dark = (lum < 175)
    bx = np.zeros((H, W), bool)
    for x0, y0, x1, y1 in LASH_BOX:
        bx[y0:y1, x0:x1] = True
    cand = (dark & bx) | interior
    lab, n = ndi.label(cand)
    ids = np.unique(lab[interior])
    ids = ids[ids > 0]
    m = np.isin(lab, ids)
    m = cv2.dilate(m.astype(np.uint8), np.ones((9, 9), np.uint8)) > 0
    m &= bx
    return m

def bezier(p0, p1, p2, n=80):
    t = np.linspace(0, 1, n)[:, None]
    return (1 - t) ** 2 * np.array(p0) + 2 * (1 - t) * t * np.array(p1) + t ** 2 * np.array(p2)

def tapered_stroke(draw, pts, w0, wmid, w1, fill):
    pts = np.asarray(pts, np.float64)
    n = len(pts)
    t = np.linspace(0, 1, n)
    widths = np.where(t < 0.5, w0 + (wmid - w0) * (t / 0.5), wmid + (w1 - wmid) * ((t - 0.5) / 0.5))
    d = np.gradient(pts, axis=0)
    nrm = np.stack([-d[:, 1], d[:, 0]], 1)
    nrm /= np.linalg.norm(nrm, axis=1, keepdims=True) + 1e-9
    left = pts + nrm * widths[:, None] / 2
    right = pts - nrm * widths[:, None] / 2
    poly = [tuple(p * SS) for p in left] + [tuple(p * SS) for p in right[::-1]]
    draw.polygon(poly, fill=fill)
    for p, w in ((pts[0], widths[0]), (pts[-1], widths[-1])):
        rr = w / 2 * SS
        draw.ellipse([p[0] * SS - rr, p[1] * SS - rr, p[0] * SS + rr, p[1] * SS + rr], fill=fill)

def rgba_layer_draw(fn):
    lay = Image.new('RGBA', (W * SS, H * SS), (0, 0, 0, 0))
    fn(ImageDraw.Draw(lay))
    lay = lay.resize((W, H), Image.LANCZOS)
    return np.array(lay).astype(np.float32) / 255.0

def over(base, layer):
    a = layer[..., 3:4]
    return base * (1 - a) + layer[..., :3] * 255.0 * a

LASH_COL = (74, 42, 36, 255)

def eyes_closed():
    m = lash_mask()
    soft = feather(m, 2.5)
    # skin fill: take per-pixel skin from a heavily blurred version of non-eye skin
    soft = feather(cv2.dilate(m.astype(np.uint8), np.ones((7, 7), np.uint8)) > 0, 3.5)
    bxm = np.zeros((H, W), bool)
    for x0, y0, x1, y1 in LASH_BOX:
        bxm[y0:y1, x0:x1] = True
    soft *= feather(cv2.erode(bxm.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0, 1.5)
    skin_fill = np.broadcast_to(SKIN, img.shape).astype(np.float32).copy()
    # soft eyelid shading so the closed lid reads as a lid (and hides any seam)
    lid = np.zeros((H, W), np.float32)
    cv2.ellipse(lid, (352, 600), (78, 34), 0, 180, 360, 1.0, -1)
    cv2.ellipse(lid, (684, 598), (78, 34), 0, 180, 360, 1.0, -1)
    lid = cv2.GaussianBlur(lid, (0, 0), 12) * 0.55
    LID = np.array([250, 218, 202], np.float32)
    skin_fill = skin_fill * (1 - lid[..., None]) + LID * lid[..., None]
    base = img * (1 - soft[..., None]) + skin_fill * soft[..., None]

    def draw(d):
        # left eye (screen-left): outer corner on the left
        L = bezier((272, 600), (350, 650), (428, 606))
        tapered_stroke(d, L, 8, 10, 3, LASH_COL)
        tapered_stroke(d, bezier((276, 602), (266, 595), (258, 584), 20), 6, 4, 1.5, LASH_COL)  # wing
        tapered_stroke(d, bezier((292, 618), (282, 622), (276, 630), 20), 4, 3, 1.2, LASH_COL)
        # right eye: outer corner on the right
        R = bezier((607, 604), (686, 648), (762, 598))
        tapered_stroke(d, R, 3, 10, 8, LASH_COL)
        tapered_stroke(d, bezier((758, 600), (768, 593), (776, 583), 20), 6, 4, 1.5, LASH_COL)
        tapered_stroke(d, bezier((742, 616), (752, 620), (758, 628), 20), 4, 3, 1.2, LASH_COL)
    return over(base, rgba_layer_draw(draw))

def eyes_half(frac=0.45):
    """Half-closed lids: upper lash slides down over the eye, skin fills above it."""
    m = lash_mask()
    out = img.copy()
    yy = np.arange(H)[:, None]
    for (x0, y0, x1, y1), (cx, cy, rx, ry) in zip(LASH_BOX, IRIS):
        sub = np.zeros((H, W), bool); sub[y0:y1, x0:x1] = True
        mi = interior & sub
        cols_int = mi.any(0)
        top_int = np.where(cols_int, mi.argmax(0), 0)
        ys_i = np.where(mi.any(1))[0]
        eh = ys_i.max() - ys_i.min()
        dy = int(round(frac * eh))
        dark = (lum < 175) & m & sub & (yy < cy)
        cols_dark = dark.any(0)
        low_dark = np.where(cols_dark, H - 1 - dark[::-1].argmax(0), 0)
        t = np.where(cols_int, top_int, np.where(cols_dark, low_dark, 0)).astype(np.int64)
        valid = cols_int | cols_dark
        upper = dark & (yy <= t[None, :] + 2) & valid[None, :]
        # per-column lid travel: full over the eye opening, eased off along the outer lash wing
        dyc = np.where(cols_int, float(dy), 0.45 * dy).astype(np.float32)
        dyc = ndi.gaussian_filter1d(dyc, 12)
        C = m & sub & valid[None, :] & (yy < (t[None, :] + dyc[None, :] + 1))
        Cs = feather(cv2.dilate(C.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0, 2.0)
        Cs *= feather(cv2.erode(sub.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0, 1.5)
        lidcol = SKIN * 0.75 + np.array([250, 218, 202], np.float32) * 0.25
        out = out * (1 - Cs[..., None]) + lidcol * Cs[..., None]
        # slide the painted upper lash down
        A = np.clip((205 - lum) / 110.0, 0, 1) * feather(upper, 0.6)
        gx, gy = np.meshgrid(np.arange(W, dtype=np.float32), np.arange(H, dtype=np.float32))
        my = gy - dyc[None, :]
        A_s = cv2.remap(A.astype(np.float32), gx, my, cv2.INTER_LINEAR, borderValue=0)
        img_s = cv2.remap(img, gx, my, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
        out = out * (1 - A_s[..., None]) + img_s * A_s[..., None]
        # soft shadow cast by the lid on the visible eye
        sh = np.zeros((H, W), np.float32)
        band = mi & (yy >= t[None, :] + dyc[None, :]) & (yy < t[None, :] + dyc[None, :] + 10)
        sh[band] = 0.14
        sh = cv2.GaussianBlur(sh, (0, 0), 2) * mi
        out = out * (1 - sh[..., None])
    return out

# ---------------- mouths ----------------
smile = (lum < 215) & False
mb = np.zeros((H, W), bool); mb[734:768, 462:576] = True
smile = (lum < 215) & mb
smile_d = cv2.dilate(smile.astype(np.uint8), np.ones((5, 5), np.uint8))
mouthless = cv2.inpaint(np.clip(img, 0, 255).astype(np.uint8), smile_d, 7, cv2.INPAINT_TELEA).astype(np.float32)
mouthless = img * (1 - feather(smile_d > 0, 1.2)[..., None]) + mouthless * feather(smile_d > 0, 1.2)[..., None]

LINE = (96, 48, 44, 255)
CAV = (128, 38, 52, 255)
CAV_D = (96, 26, 40, 255)
TONGUE = (232, 120, 128, 255)
TEETH = (255, 252, 250, 255)

def mouth_shape(width, top_sag, depth, corner_up=3):
    cx, cy = MOUTH_C
    x0, x1 = cx - width / 2, cx + width / 2
    yc = cy - 4 - corner_up
    top = bezier((x0, yc), (cx, yc + top_sag * 2), (x1, yc), 60)
    bot = bezier((x1, yc), (cx, yc + depth * 2), (x0, yc), 60)
    return top, bot, np.vstack([top, bot[1:]])

def draw_open_mouth(width, top_sag, depth, tongue=0.0, teeth=0.0, line_w=3.2):
    top, bot, poly = mouth_shape(width, top_sag, depth)
    def draw(d):
        P = [tuple(p * SS) for p in poly]
        d.polygon(P, fill=CAV)
    cav = rgba_layer_draw(draw)
    # interior shading / tongue / teeth clipped to cavity
    clip = cav[..., 3:4]
    def inner(d):
        cx, cy = MOUTH_C
        ymax = poly[:, 1].max(); ymin = poly[:, 1].min()
        # darker throat near top
        d.ellipse([ (cx - width * 0.32) * SS, (ymin - 2) * SS, (cx + width * 0.32) * SS, (ymin + (ymax - ymin) * 0.55) * SS], fill=CAV_D)
        if tongue > 0:
            tw = width * 0.62 * (0.6 + 0.4 * tongue)
            th = (ymax - ymin) * 0.55 * tongue
            d.ellipse([(cx - tw / 2) * SS, (ymax - th) * SS, (cx + tw / 2) * SS, (ymax + th * 0.9) * SS], fill=TONGUE)
        if teeth > 0:
            tw = width * 0.72
            d.rounded_rectangle([(cx - tw / 2) * SS, (ymin - 3) * SS, (cx + tw / 2) * SS, (ymin + 3 + 5 * teeth) * SS], radius=3 * SS, fill=TEETH)
    inn = rgba_layer_draw(inner)
    inn[..., 3:4] *= clip
    def outline(d):
        tapered_stroke(d, top, line_w * 0.7, line_w * 1.15, line_w * 0.7, LINE)
        tapered_stroke(d, bot, line_w * 0.6, line_w * 0.75, line_w * 0.6, (LINE[0], LINE[1], LINE[2], 200))
    ol = rgba_layer_draw(outline)
    return cav, inn, ol

MOUTH_OPEN_TIERS = 15  # o1..o15 (plus o0 closed = 16 total)

def open_mouth_params(i):
    """Smooth openness curve for tier i in 1..MOUTH_OPEN_TIERS (matches old o1..o7 envelope)."""
    t = i / float(MOUTH_OPEN_TIERS)  # 1/15 .. 1.0
    # Slight ease-in on depth so early tiers stay subtle (quiet speech).
    te = t ** 1.08
    width = 32.0 + 40.0 * t
    top_sag = 2.2 - 1.2 * t
    depth = 4.0 + 41.0 * te
    tongue = 0.0 if t < 0.38 else 0.8 * ((t - 0.38) / 0.62)
    teeth = 0.0 if t < 0.58 else 1.0 * ((t - 0.58) / 0.42)
    line_w = 2.55 + 0.85 * t
    return dict(width=width, top_sag=top_sag, depth=depth, tongue=tongue, teeth=teeth, line_w=line_w)

def mouth_layer(kind):
    """Return full-canvas RGBA float layer (0..1) for the given mouth (center head)."""
    cx, cy = MOUTH_C
    if kind == 'o0':
        comp = img.copy()
        ext = (cx - 64, cy - 22, cx + 64, cy + 22)
    else:
        i = int(kind[1:])
        if i < 1 or i > MOUTH_OPEN_TIERS:
            raise KeyError(kind)
        params = open_mouth_params(i)
        cav, inn, ol = draw_open_mouth(**params)
        comp = over(over(over(mouthless.copy(), cav), inn), ol)
        ext = (cx - 66, cy - 24, cx + 66, cy + 24 + params['depth'])
    # cv2.ellipse needs int center/axes (depth is float on denser tiers)
    ext = tuple(int(round(v)) for v in ext)
    patch = np.zeros((H, W), np.uint8)
    ex = ((ext[0] + ext[2]) // 2, (ext[1] + ext[3]) // 2)
    cv2.ellipse(patch, ex, ((ext[2] - ext[0]) // 2, (ext[3] - ext[1]) // 2), 0, 0, 360, 1, -1)
    alpha = feather(patch, 5)
    alpha = np.maximum(alpha, feather(smile_d > 0, 1.5))  # guarantee painted smile is covered
    lay = np.concatenate([comp / 255.0, alpha[..., None]], 2)
    return lay

# ---------------- head yaw warp (fake 3D) ----------------
FACE_C = (512, 610)
def head_maps(s):
    """s in [-1,1]: -1 head turned fully to screen-left, +1 fully to screen-right."""
    yy, xx = np.mgrid[0:H, 0:W].astype(np.float32)
    if s == 0:
        return xx, yy
    D = 36.0 * s           # feature slide (px)
    sx, sy = 250.0, 300.0
    gx = np.exp(-((xx - FACE_C[0]) ** 2) / (2 * sx ** 2) - ((yy - FACE_C[1]) ** 2) / (2 * sy ** 2))
    src_x = xx - D * gx
    # perspective: the side we see more of (opposite turn direction) slightly taller
    nx = (xx - 512) / 512.0
    scale = 1.0 - 0.035 * s * nx
    src_y = FACE_C[1] + (yy - FACE_C[1]) / scale
    # tiny vertical bob so the turn reads
    src_y += 2.0 * gx
    return src_x.astype(np.float32), src_y.astype(np.float32)

def warp(arr, maps):
    mx, my = maps
    return cv2.remap(arr.astype(np.float32), mx, my, cv2.INTER_CUBIC, borderMode=cv2.BORDER_REPLICATE)

import json

def save_rgb(arr, name):
    Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)).save(os.path.join(OUT, name), optimize=True)

def save_rgba_arr(lay, name):
    lay = np.clip(lay, 0, 1).copy()
    lay[lay[..., 3] <= 0.003] = 0
    Image.fromarray((lay * 255 + 0.5).astype(np.uint8), 'RGBA').save(os.path.join(OUT, name), optimize=True)

def bbox(mask, pad):
    ys, xs = np.where(mask)
    x0, y0 = max(0, xs.min() - pad), max(0, ys.min() - pad)
    x1, y1 = min(W, xs.max() + 1 + pad), min(H, ys.max() + 1 + pad)
    return int(x0), int(y0), int(x1), int(y1)

EYES = {'center': lambda: img.copy()}
for n, px in ((1, 5), (2, 10), (3, 15)):
    EYES[f'left{n}'] = (lambda p: (lambda: eyes_look(-p, 0)))(px)
    EYES[f'right{n}'] = (lambda p: (lambda: eyes_look(p, 0)))(px)
for n, px in ((1, 3), (2, 6), (3, 9)):
    EYES[f'up{n}'] = (lambda p: (lambda: eyes_look(0, -p)))(px)
    EYES[f'down{n}'] = (lambda p: (lambda: eyes_look(0, p)))(px)
for n, fr in ((1, 0.22), (2, 0.45), (3, 0.70)):
    EYES[f'blink{n}'] = (lambda f: (lambda: eyes_half(f)))(fr)
EYES['closed'] = eyes_closed
MOUTHS = [f'o{i}' for i in range(MOUTH_OPEN_TIERS + 1)]
HEADS = {'left3': -1.0, 'left2': -2 / 3, 'left1': -1 / 3, 'center': 0.0,
         'right1': 1 / 3, 'right2': 2 / 3, 'right3': 1.0}

if __name__ == '__main__':
    eye_imgs = {k: f() for k, f in EYES.items()}
    mouth_lays = {k: mouth_layer(k) for k in MOUTHS}
    files, rects = [], {}
    for hname, s in HEADS.items():
        maps = head_maps(s)
        base = warp(eye_imgs['center'], maps)
        save_rgb(base, f'head_{hname}.png'); files.append(f'head_{hname}.png')
        rects[f'head_{hname}'] = [0, 0, W, H]
        warped = {e: warp(im, maps) for e, im in eye_imgs.items()}
        diff = np.zeros((H, W), bool)
        for e, wim in warped.items():
            diff |= np.abs(wim - base).sum(2) > 3
        x0, y0, x1, y1 = bbox(diff, 10)
        fa = np.zeros((y1 - y0, x1 - x0), np.float32)
        fa[6:-6, 6:-6] = 1
        fa = cv2.GaussianBlur(fa, (0, 0), 2.5)
        for e, wim in warped.items():
            crop = np.concatenate([wim[y0:y1, x0:x1] / 255.0, fa[..., None]], 2)
            fn = f'eyes_{hname}_{e}.png'
            save_rgba_arr(crop, fn); files.append(fn)
            rects[fn[:-4]] = [x0, y0, x1 - x0, y1 - y0]
        wl = {m: warp(l, maps) for m, l in mouth_lays.items()}
        am = np.zeros((H, W), bool)
        for l in wl.values():
            am |= l[..., 3] > 0.003
        mx0, my0, mx1, my1 = bbox(am, 2)
        for mname, l in wl.items():
            fn = f'mouth_{hname}_{mname}.png'
            save_rgba_arr(l[my0:my1, mx0:mx1], fn); files.append(fn)
            rects[fn[:-4]] = [mx0, my0, mx1 - mx0, my1 - my0]
    manifest = dict(canvas=W, version=4, heads=list(HEADS), eyes=list(EYES), mouths=MOUTHS, rects=rects)
    json.dump(manifest, open(os.path.join(OUT, 'sprite_manifest.json'), 'w'), indent=1)
    print('\n'.join(files))
    print(len(files), 'png files')
