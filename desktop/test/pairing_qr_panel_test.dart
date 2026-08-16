import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:thehack_overlay/net/pairing_payload.dart';
import 'package:thehack_overlay/ui/pairing_qr_panel.dart';

void main() {
  testWidgets('PairingQrPanel は QR と手入力案内を描画する', (tester) async {
    const uri = 'screact://pair?v=1&t=123456&host=192.168.1.23&port=8765';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: PairingQrPanel(uri: uri))),
      ),
    );

    // QR ウィジェットが表示される。
    expect(find.byKey(const ValueKey('pairing-qr')), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    // 読み取り案内と手入力フォールバックの案内が併記される。
    expect(find.textContaining('QRを読み取って'), findsOneWidget);
    expect(find.textContaining('手で入力'), findsOneWidget);
  });

  testWidgets('PairingPayload の生成 URI で QR パネルが例外なく構築できる', (tester) async {
    const payload = PairingPayload(
      pairingToken: '654321',
      lanHost: '10.0.0.5',
      lanPort: 8765,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PairingQrPanel(uri: payload.toUri())),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(QrImageView), findsOneWidget);
  });
}
