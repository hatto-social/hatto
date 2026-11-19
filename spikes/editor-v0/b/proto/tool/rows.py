#!/usr/bin/env python3
# print y-runs of distinct colours along a pixel column, to compare layout of two screenshots: rows.py img x
import sys
from PIL import Image
im=Image.open(sys.argv[1]).convert('RGB'); x=int(sys.argv[2]); prev=None; start=0
for y in range(im.height):
    p=im.getpixel((x,y))
    if p!=prev:
        if prev is not None and (y-start)>=1: print(f"{start}-{y-1} ({y-start}px) #%02x%02x%02x"%prev)
        prev=p; start=y
print(f"{start}-{im.height-1} #%02x%02x%02x"%prev)
