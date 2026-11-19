#!/usr/bin/env python3
# x-runs of distinct colours along a pixel row: cols.py img y [min_run]
import sys
from PIL import Image
im=Image.open(sys.argv[1]).convert('RGB'); y=int(sys.argv[2]); mr=int(sys.argv[3]) if len(sys.argv)>3 else 1; prev=None; start=0
for x in range(im.width):
    p=im.getpixel((x,y))
    if p!=prev:
        if prev is not None and (x-start)>=mr: print(f"{start}-{x-1} ({x-start}px) #%02x%02x%02x"%prev)
        prev=p; start=x
