import 'package:flutter_test/flutter_test.dart';
import 'package:hatto_mobile/main.dart';

void main() {
  testWidgets('home page offers to open a collection', (tester) async {
    await tester.pumpWidget(const HattoApp());
    expect(find.text('Open collection'), findsOneWidget);
    expect(find.text('Collection is not open yet.'), findsOneWidget);
  });
}
