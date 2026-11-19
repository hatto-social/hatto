// Spike c: Flutter-native card renderer (no webview). rslib HTML + CSS subset + MathJax-subset via flutter_math_fork.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

final _math = RegExp(r'\\\((.+?)\\\)|\\\[(.+?)\\\]', dotAll: true);

String preprocess(String html) => html.replaceAllMapped(_math, (m) {
      final block = m.group(2) != null;
      final tex = (m.group(1) ?? m.group(2))!.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;');
      return '<span data-tex="$tex" data-block="$block"></span>';
    });

Widget nativeCard(String html, {double width = 600}) => SizedBox(
      width: width,
      child: DefaultTextStyle(
        style: const TextStyle(fontFamily: 'NanumGothic', fontSize: 20, height: 1.5, color: Colors.black),
        textAlign: TextAlign.center,
        child: HtmlWidget(
          '<div style="text-align:center">${preprocess(html)}</div>',
          textStyle: const TextStyle(fontFamily: 'NanumGothic', fontSize: 20, height: 1.5, color: Colors.black),
          customStylesBuilder: (e) {
            final c = e.classes;
            if (c.contains('cloze')) return {'font-weight': 'bold', 'color': 'blue'};
            if (e.localName == 'hr') return {'margin': '8px 0'};
            return null;
          },
          customWidgetBuilder: (e) {
            if (e.localName == 'img') {
              final src = e.attributes['src'] ?? ''; final wd = double.tryParse(e.attributes['width'] ?? '');
              return InlineCustomWidget(child: Image.file(File(src.replaceFirst('file://', '')), width: wd, errorBuilder: (_, __, ___) => const Text('[img?]')));
            }
            final tex = e.attributes['data-tex'];
            if (tex == null) return null;
            final block = e.attributes['data-block'] == 'true';
            final w = Math.tex(tex, textStyle: const TextStyle(fontSize: 22), onErrorFallback: (err) => Text('\\($tex\\)'));
            return block ? Center(child: w) : InlineCustomWidget(child: w);
          },
          // [sound:...] stays literal text here; AV tags are extracted before rendering in the real flow
        ),
      ),
    );
