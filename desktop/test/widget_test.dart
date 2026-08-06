import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/main.dart';

void main() {
  testWidgets('app boots and shows control surface', (tester) async {
    await tester.pumpWidget(const YubiBoardApp());
    await tester.pump();
    expect(find.text('接続'), findsOneWidget);
    // パネルが長くなってもモック起動ボタンに到達できる（スクロールして確認）
    await tester.scrollUntilVisible(find.text('モックの手を流す'), 100);
    expect(find.text('モックの手を流す'), findsOneWidget);
  });
}
