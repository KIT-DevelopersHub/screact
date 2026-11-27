/// 入力端末との通信路（transport）の抽象。
///
/// セッション処理（hello 認証・sessionId・frameId・最新フレーム優先・猶予
/// タイマー・計測・dispatch）は [InputTransportHandler] を実装する側
/// （InputSession）が持ち、通信路はメッセージ単位の受信・送信・切断通知だけを
/// 受け持つ。WebSocket 以外の経路（BLE など）を足すときも、ここを実装すれば
/// ジェスチャー・位置合わせ処理を二重実装せずに済む。
library;

import 'dart:typed_data';

/// 1 本の接続。メッセージ単位で送れて、閉じられるもの。
abstract class TransportConnection {
  /// 接続診断ログ用の接続元表示（例: `192.168.0.2:51234`）。
  String get label;

  /// テキストメッセージ（protocol v1 の JSON）を 1 件送る。
  void send(String message);

  /// 接続を閉じる。[code]・[reason] は経路が対応していれば相手へ伝える。
  ///
  /// 閉じ終えた後の切断通知（[InputTransportHandler.onClosed]）は、
  /// 呼び出し元が既に接続を切り離していても届きうる。受け手は接続の
  /// 同一性で無視できるようにしておく。
  Future<void> close([int? code, String? reason]);
}

/// 通信路から届く接続の出来事を受け取る側。
///
/// 通信路は、1 本の接続について次の順で呼ぶ:
/// [onOpened] → 0 回以上の [onText]/[onBinary] → [onClosed]（多くても 1 回）。
/// [onOpened] が false を返した接続については、以後どれも呼ばない。
abstract class InputTransportHandler {
  /// 新しい接続が確立した。受け入れるなら true。
  /// false の場合、受け手は拒否の通知と [TransportConnection.close] を済ませている。
  bool onOpened(TransportConnection connection);

  /// テキストメッセージを 1 件受信した。
  void onText(TransportConnection connection, String message);

  /// バイナリメッセージを 1 件受信した（将来のバイナリ形式の受け口）。
  void onBinary(TransportConnection connection, Uint8List message);

  /// 接続が切れた（相手からの切断・エラー・こちらからの close の完了）。
  void onClosed(TransportConnection connection);
}

/// 接続を待ち受けて [InputTransportHandler] へ渡す通信路。
abstract class InputTransport {
  /// 待受を始める。以後の接続の出来事は [handler] へ渡す。
  Future<void> start(InputTransportHandler handler);

  /// 待受をやめる。確立済みの接続は閉じない（受け手が閉じる）。
  Future<void> stop();
}
