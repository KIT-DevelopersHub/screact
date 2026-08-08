import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thehack_overlay/main.dart';

void main() {
  testWidgets('app boots and shows control surface', (tester) async {
    await tester.pumpWidget(const YubiBoardApp());
    await tester.pump();
    expect(find.text('Screact'), findsOneWidget);
    expect(find.text('サーバ開始'), findsOneWidget);
    // 開発者向け要素は折りたたみ配下に移動したため、展開してから確認する。
    // SelectableText 内部にも Scrollable があるため、パネルの ListView を明示する
    await tester.scrollUntilVisible(find.text('開発者向け設定'), 100,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('開発者向け設定'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('モックの手を流す'), 100,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('モックの手を流す'), findsOneWidget);
  });
}
