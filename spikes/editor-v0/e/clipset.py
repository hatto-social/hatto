#!/usr/bin/env python3
"""Own the X11 CLIPBOARD with multiple typed targets. usage: clipset.py <case> ; blocks until killed.
cases: file (uri-list + gnome-copied-files), text, filetext (file + text/plain), png, png_html (browser-like image copy), truncated, random, huge120, hugedims"""
import sys, gi
gi.require_version('Gtk', '3.0'); gi.require_version('Gdk', '3.0')
from gi.repository import Gtk, Gdk, GLib
case = sys.argv[1]; fx = '/workspace/editor-spikes/e/fixtures/'
def rd(p): return open(fx + p, 'rb').read()
T = {}
if case in ('file', 'filetext'):
    uri = 'file://' + fx + 'red.png'
    T['text/uri-list'] = (uri + '\r\n').encode(); T['x-special/gnome-copied-files'] = ('copy\n' + uri).encode()
if case in ('text', 'filetext'):
    T['text/plain'] = '/some/path/not/a/file.png'.encode(); T['UTF8_STRING'] = T['text/plain']
if case == 'png': T['image/png'] = rd('red.png')
if case == 'png_html':
    T['image/png'] = rd('red.png'); T['text/html'] = b'<meta charset="utf-8"><img src="https://example.com/a.png" alt="x">'
if case == 'truncated': T['image/png'] = rd('truncated.png')
if case == 'random': T['image/png'] = rd('random.png')
if case == 'huge120': T['image/png'] = rd('huge_120mb.bin')
if case == 'hugedims': T['image/png'] = rd('huge_dims.png')
targets = [Gtk.TargetEntry.new(k, 0, i) for i, k in enumerate(T)]
keys = list(T)
def get(cb, sel, info, data): sel.set(Gdk.Atom.intern(keys[info], False), 8, T[keys[info]])
clip = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
clip.set_with_data(targets, get, lambda c, d: None, None)
print('clipboard set:', case, keys, flush=True)
Gtk.main()
