import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// UDP 自動発見が使えない環境向けの QR フォールバック表示。
///
/// `screact://pair?...`（[PairingPayload] が生成）を QR にして見せ、スマホの
/// カメラで読み取らせて接続情報（host/port/token）を渡す。認証は `hello` の
/// `pairingToken` 1 本のままで、QR は「接続情報の運び方」を足すだけ
/// （接続/認証 確定仕様 v1 の 4 章準拠）。
///
/// ネットワーク・実端末に依存しない純粋な表示ウィジェットとして切り出し、
/// ウィジェットテストで表示を検証できるようにしている。
class PairingQrPanel extends StatelessWidget {
  /// QR にエンコードする `screact://pair?...` URI。
  final String uri;

  /// QR コード画像の一辺（px）。
  final double size;

  const PairingQrPanel({super.key, required this.uri, this.size = 220});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'スマホのカメラでこのQRを読み取ってください',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: Color(0xFF686666),
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFB8B8B8), width: 1.5),
          ),
          child: QrImageView(
            key: const ValueKey('pairing-qr'),
            data: uri,
            version: QrVersions.auto,
            size: size,
            gapless: true,
            backgroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          '読み取れないときは、下の値を手で入力してください',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Color(0xFF9A9A9A),
          ),
        ),
      ],
    );
  }
}
