import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/main.dart';

void main() {
  testWidgets('app boots and shows control surface', (tester) async {
    await tester.pumpWidget(const YubiBoardApp());
    await tester.pump();
    expect(find.text('接続'), findsOneWidget);
    expect(find.text('モックの手を流す'), findsOneWidget);
  });
}
