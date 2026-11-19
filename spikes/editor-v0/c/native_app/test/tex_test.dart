import 'dart:io';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('TeX subset coverage (KaTeX-like parser) vs MathJax', () {
    final cases = <String>[r'\frac{a}{b}', r'\sum_{k=1}^{n}k', r'\begin{aligned}a&=b\\c&=d\end{aligned}', r'\text{한글 텍스트}', r'\mathbb{R}', r'\ce{H2O}', r'\cancel{x}', r'\require{cancel}\cancel{x}', r'\color{red}{x}', r'\underbrace{a+b}_{c}', r'\begin{array}{cc}1&2\\3&4\end{array}', r'\dfrac{1}{2}', r'\operatorname{lcm}(a,b)', r'\begin{pmatrix}1&2\\3&4\end{pmatrix}', r'\mathrm{d}x', r'\xrightarrow{f}', r'\newcommand{\R}{\mathbb{R}}\R', r'\bbox[yellow]{x}', r'\unicode{x41}', r'\href{http://a}{b}'];
    final sb = StringBuffer(); var ok = 0;
    for (final c in cases) { final e = Math.tex(c).parseError; if (e == null) ok++; sb.writeln('${e == null ? 'OK  ' : 'FAIL'} $c${e == null ? '' : '  -> ${e.message}'}'); }
    sb.writeln('TOTAL ok=$ok/${cases.length}');
    File('../evidence/native_tex_coverage.txt').writeAsStringSync(sb.toString()); print(sb);
  });
}
