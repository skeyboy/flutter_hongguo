#!/usr/bin/env python3
"""Render the editable Hongguo mark and all platform icons. Requires Pillow."""
from pathlib import Path
import json
from PIL import Image, ImageDraw, ImageFilter
ROOT=Path(__file__).resolve().parents[1]
APP=ROOT/'packages/app'
OUT=ROOT/'design/app-icon'
OUT.mkdir(parents=True,exist_ok=True)
BG='#A61938'; WHITE='#FFF3E3'; GOLD='#FFC56D'
# Coordinates are in a 1024-square canvas; the whole mark fits the adaptive safe circle.
FRUIT=[('M',508,358),('C',434,302,321,334,291,430),('C',247,569,335,723,452,733),('C',480,736,496,723,516,723),('C',536,723,555,737,584,731),('C',699,708,777,541,727,422),('C',690,334,587,308,508,358),('Z',)]
LEAF=[('M',500,306),('C',502,234,561,192,652,211),('C',647,287,577,324,500,306),('Z',)]
PLAY=[('M',469,437),('C',469,424,482,418,493,425),('L',603,495),('C',615,503,615,518,603,526),('L',493,597),('C',482,604,469,597,469,584),('Z',)]
def svgpath(commands):return ' '.join(c[0]+' '.join(str(v) for v in c[1:]) for c in commands)
def points(commands):
 result=[]; pos=None; first=None
 for c in commands:
  if c[0]=='M':pos=(c[1],c[2]);first=pos;result.append(pos)
  elif c[0]=='L':pos=(c[1],c[2]);result.append(pos)
  elif c[0]=='C':
   a=pos;b=(c[1],c[2]);d=(c[3],c[4]);e=(c[5],c[6])
   for i in range(1,65):
    t=i/64;u=1-t
    result.append((u*u*u*a[0]+3*u*u*t*b[0]+3*u*t*t*d[0]+t*t*t*e[0],u*u*u*a[1]+3*u*u*t*b[1]+3*u*t*t*d[1]+t*t*t*e[1]))
   pos=e
  elif c[0]=='Z':result.append(first)
 return result
scale=3;N=1024*scale

def mark(background=True,mono=False):
 im=Image.new('RGBA',(N,N), BG if background else (0,0,0,0));draw=ImageDraw.Draw(im)
 for commands,color in [(FRUIT,'white' if mono else WHITE),(LEAF,'white' if mono else GOLD),(PLAY,(0,0,0,0) if mono else BG)]:
  draw.polygon([(round(x*scale),round(y*scale)) for x,y in points(commands)],fill=color)
 return im
master=mark();master.resize((1024,1024),Image.Resampling.LANCZOS).convert('RGB').save(OUT/'hongguo-icon-1024.png')
svg='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">\n'
svg+=f'<rect width="1024" height="1024" fill="{BG}"/>\n'
for commands,color in [(FRUIT,WHITE),(LEAF,GOLD),(PLAY,BG)]:svg+=f'<path d="{svgpath(commands)}" fill="{color}"/>\n'
(OUT/'hongguo-icon.svg').write_text(svg+'</svg>\n')
# Desktop silhouettes get transparent margins; iOS and maskable assets stay opaque.
mask=Image.new('L',(N,N));ImageDraw.Draw(mask).rounded_rectangle((80*scale,80*scale,944*scale,944*scale),radius=194*scale,fill=255)
desktop=master.copy();desktop.putalpha(mask)
def save(im,path,n,opaque=False):
 path.parent.mkdir(parents=True,exist_ok=True)
 result=im.resize((n,n),Image.Resampling.LANCZOS)
 if opaque:result=result.convert('RGB')
 result.save(path)
for platform in ['ios','macos']:
 directory=APP/platform/'Runner/Assets.xcassets/AppIcon.appiconset'
 for entry in json.loads((directory/'Contents.json').read_text())['images']:
  if 'filename' not in entry:continue
  n=round(float(entry['size'].split('x')[0])*float(entry['scale'].rstrip('x')))
  save(master if platform=='ios' else desktop,directory/entry['filename'],n,platform=='ios')
res=APP/'android/app/src/main/res'
for density,n in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
 save(master,res/f'mipmap-{density}/ic_launcher.png',n,True)
# Adaptive foreground shares precisely the same geometry as the master.
foreground=mark(False)
for density,n in [('mdpi',108),('hdpi',162),('xhdpi',216),('xxhdpi',324),('xxxhdpi',432)]:save(foreground,res/f'mipmap-{density}/ic_launcher_foreground.png',n)
for version,extra in [('v26',''),('v33','\n    <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>')]:
 directory=res/f'mipmap-anydpi-{version}';directory.mkdir(exist_ok=True)
 (directory/'ic_launcher.xml').write_text(f'''<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/hongguo_icon_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>{extra}
</adaptive-icon>\n''')
(res/'values/icon_colors.xml').write_text(f'<resources><color name="hongguo_icon_background">{BG}</color></resources>\n')
# Android VectorDrawable is native, resolution independent, and retains a real cutout.
mono=svgpath(FRUIT)+' '+svgpath(LEAF)+' '+svgpath(PLAY)
(res/'drawable/ic_launcher_monochrome.xml').write_text(f'''<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="1024" android:viewportHeight="1024">
    <path android:fillColor="#FFFFFFFF" android:fillType="evenOdd" android:pathData="{mono}"/>
</vector>\n''')
save(desktop,OUT/'hongguo-desktop-1024.png',1024)
desktop.resize((256,256),Image.Resampling.LANCZOS).save(APP/'windows/runner/resources/app_icon.ico',sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
for n in [192,512]:
 save(master,APP/f'web/icons/Icon-{n}.png',n,True)
 save(master,APP/f'web/icons/Icon-maskable-{n}.png',n,True)
save(master,APP/'web/favicon.png',32,True)
for n in [16,32,48,64,128,256,512]:save(desktop,APP/f'linux/icons/hicolor/{n}x{n}/apps/com.example.hongguo_app.png',n)
# Native GResource embeds the icon so window/task-switcher use works before installation.
save(desktop,APP/'linux/runner/resources/hongguo.png',256)
# A review sheet is a deliverable, not an application dependency.
sheet=Image.new('RGB',(1320,680),'#F3EEE8');d=ImageDraw.Draw(sheet)
for x,im in [(40,master),(475,desktop)]:
 tile=im.resize((400,400),Image.Resampling.LANCZOS);sheet.paste(tile,(x,95),tile)
d.text((45,45),'HONGGUO / FRUIT IN MOTION',fill=BG,stroke_width=0)
d.text((45,525),'iOS / Android / Web',fill=BG);d.text((480,525),'macOS / Windows / Linux',fill=BG)
for n,y in [(128,95),(64,260),(32,365),(16,440)]:
 tile=desktop.resize((n,n),Image.Resampling.LANCZOS);sheet.paste(tile,(1000,y),tile);d.text((1160,y+4),f'{n}px',fill=BG)
d.text((45,610),'Berry red #A61938   /   Cream #FFF3E3   /   Apricot #FFC56D',fill=BG)
sheet.save(OUT/'icon-preview.png')
print('Generated SVG master, 1024 PNGs, preview, and platform icon assets.')
if __name__=='__main__':pass
