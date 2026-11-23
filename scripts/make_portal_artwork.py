#!/usr/bin/env python3
"""Arcane Portal's icon artwork, derived from Arcane's (Bium23/NxLibrary, MIT, see NOTICE).

    git show f280bb2:Resources/IconArtwork.png > /tmp/arcane-artwork.png
    python3 scripts/make_portal_artwork.py /tmp/arcane-artwork.png Resources/IconArtwork.png
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/make_icons.swift

Needs numpy and Pillow (`python3 -m venv .venv && .venv/bin/pip install numpy pillow`).
The navy stroke turns teal and the plum ink violet; a glowing portal opens behind the crystal.
"""
import sys, math
from PIL import Image, ImageDraw, ImageFilter, ImageChops
import numpy as np
src = Image.open(sys.argv[1]).convert('RGB'); W,H = src.size
a = np.asarray(src).astype(np.float32)/255
# HSV
mx=a.max(2); mn=a.min(2); d=mx-mn+1e-6
r,g,b=a[...,0],a[...,1],a[...,2]
h=np.where(mx==r,((g-b)/d)%6,np.where(mx==g,(b-r)/d+2,(r-g)/d+4))*60
s=np.where(mx>0,d/(mx+1e-6),0); v=mx
yy,xx=np.mgrid[0:H,0:W]; cx,cy=W*0.5,H*0.49
dist=np.hypot(xx-cx,yy-cy)
crystal=(np.abs(xx-cx)<W*0.08)&(np.abs(yy-cy)<H*0.15)
sat=(s>0.18)&~crystal
navy=sat&((h>190)&(h<260))
plum=sat&((h>280)|(h<20))
h2=h.copy()
h2[navy]=185          # navy -> deep teal
h2[plum]=268          # plum -> violet
s2=s.copy(); s2[navy]=np.minimum(1,s[navy]*1.15); s2[plum]=np.minimum(1,s[plum]*1.1)
def hsv2rgb(h,s,v):
    c=v*s; x=c*(1-np.abs((h/60)%2-1)); m=v-c
    z=np.zeros_like(h); i=(h//60).astype(int)%6
    rr=np.choose(i,[c,x,z,z,x,c]); gg=np.choose(i,[x,c,c,x,z,z]); bb=np.choose(i,[z,z,x,c,c,x])
    return np.stack([rr+m,gg+m,bb+m],-1)
out=hsv2rgb(h2,s2,v)
img=Image.fromarray((np.clip(out,0,1)*255).astype(np.uint8))

rx,ry=W*0.165,H*0.225
def layer(): return Image.new('RGBA',(W,H),(0,0,0,0))
# portal interior: deep violet-to-teal gradient, soft edge
inner=layer(); di=ImageDraw.Draw(inner)
for i in range(60,0,-1):
    f=i/60; col=(int(25+95*f**2),int(18+170*f**3),int(70+180*f**2),235)
    di.ellipse([cx-rx*f,cy-ry*f,cx+rx*f,cy+ry*f],fill=col)
inner=inner.filter(ImageFilter.GaussianBlur(8))
# vortex arcs
vort=layer(); dv=ImageDraw.Draw(vort)
for k in range(14):
    f=0.22+0.054*k; off=k*37
    col=(int(150+7*k),int(200+3*k),255,int(70+10*k))
    dv.arc([cx-rx*f,cy-ry*f,cx+rx*f,cy+ry*f],off,off+150,fill=col,width=int(4+k*0.6))
vort=Image.alpha_composite(vort.filter(ImageFilter.GaussianBlur(6)),vort.filter(ImageFilter.GaussianBlur(1.5)))
# rim glow
rim=layer()
for (w,c,bl) in [(120,(70,220,255,150),60),(60,(120,200,255,190),26),(26,(160,120,255,240),9),(10,(240,252,255,255),2)]:
    l=layer(); ImageDraw.Draw(l).ellipse([cx-rx,cy-ry,cx+rx,cy+ry],outline=c,width=w)
    rim=Image.alpha_composite(rim,l.filter(ImageFilter.GaussianBlur(bl)))
base=img.convert('RGBA')
halo=layer(); ImageDraw.Draw(halo).ellipse([cx-rx*1.5,cy-ry*1.4,cx+rx*1.5,cy+ry*1.4],fill=(90,200,255,120))
base=Image.alpha_composite(base,halo.filter(ImageFilter.GaussianBlur(70)))
base=Image.alpha_composite(base,inner)
base=Image.alpha_composite(base,vort)
base=Image.alpha_composite(base,rim)
# the crystal itself, on top, cut out by its colour
sa=(s>0.22)&crystal
m=Image.fromarray((sa*255).astype(np.uint8)).filter(ImageFilter.MaxFilter(5)).filter(ImageFilter.GaussianBlur(1.5))
base.paste(src.convert('RGBA'),(0,0),m)
# crystal glow
cg=layer(); ImageDraw.Draw(cg).ellipse([cx-W*0.07,cy-H*0.1,cx+W*0.07,cy+H*0.1],fill=(200,150,255,90))
base=Image.alpha_composite(base,cg.filter(ImageFilter.GaussianBlur(40)))
base.paste(src.convert('RGBA'),(0,0),m)
base.convert('RGB').save(sys.argv[2])
