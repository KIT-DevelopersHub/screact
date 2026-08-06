import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/main.dart';

void main() {
  testWidgets('app boots and shows control surface', (tester) async {
    await tester.pumpWidget(const YubiBoardApp());
    await tester.pump();
    expect(find.text('接続'), findsOneWidget);
    // パネルが長くなってもモック起動ボタンに到達できる（スクロールして確認）
    // SelectableText 内部にも Scrollable があるため、パネルの ListView を明示する
    await tester.scrollUntilVisible(find.text('モックの手を流す'), 100,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('モックの手を流す'), findsOneWidget);
  });
}
