// Smoke test: the app boots in fake mode with no servers configured.
import 'package:flutter_test/flutter_test.dart';
import 'package:yinghui/main.dart';

void main() {
  testWidgets('YingHui boots to the Home tab', (tester) async {
    await tester.pumpWidget(const YingHuiApp());
    await tester.pumpAndSettle();
    expect(find.text('影汇'), findsWidgets);
    expect(find.text('Home'), findsWidgets);
    expect(find.text('Music'), findsWidgets);
    expect(find.text('Downloads'), findsWidgets);
  });
}
