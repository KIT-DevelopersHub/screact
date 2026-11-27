import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'input_transport.dart';

/// `ws://<PCのIP>:<port>/ws/v1/input` で待ち受ける WebSocket の通信路。
/// listen・upgrade・送受信・close だけを受け持ち、セッション処理は
/// [InputTransportHandler] へ渡す。
class WebSocketInputTransport implements InputTransport {
  static const String path = '/ws/v1/input';

  final int port;

  /// 接続診断ログ（null なら無効）。
  final void Function(String)? onLog;

  HttpServer? _http;

  WebSocketInputTransport({required this.port, this.onLog});

  void _log(String m) => onLog?.call(m);

  /// バインド済みポート（port=0 指定時のテスト用）。未起動なら null。
  int? get boundPort => _http?.port;

  /// ログ表示用の待受先。
  String get endpoint => 'ws://0.0.0.0:${_http?.port ?? port}$path';

  @override
  Future<void> start(InputTransportHandler handler) async {
    final http = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _http = http;
    http.listen((req) async {
      final from = _remoteOf(req);
      try {
        if (req.uri.path == path &&
            WebSocketTransformer.isUpgradeRequest(req)) {
          _log('http request from $from path=${req.uri.path} (WS upgrade要求)');
          // 圧縮拡張は必ずオフにする。Dart既定の permessage-deflate 応答
          // （client_max_window_bits付き）を Android の OkHttp が拒否し、
          // closeCode=1010 で即切断される（実機で確認した接続不可の根本原因）。
          final ws = await WebSocketTransformer.upgrade(
            req,
            compression: CompressionOptions.compressionOff,
          );
          _log('ws upgraded ($from) — WebSocket確立');
          _attach(handler, ws, from);
        } else {
          _log(
            'http request from $from path=${req.uri.path} '
            '(upgrade無し→404: パス誤りか疎通確認)',
          );
          req.response.statusCode = HttpStatus.notFound;
          await req.response.close();
        }
      } catch (e) {
        _log('upgrade失敗 ($from): $e');
      }
    }, onError: (Object e) => _log('listenエラー: $e'));
  }

  static String _remoteOf(HttpRequest req) {
    final info = req.connectionInfo;
    return info == null
        ? '(不明)'
        : '${info.remoteAddress.address}:${info.remotePort}';
  }

  void _attach(InputTransportHandler handler, WebSocket ws, String from) {
    final connection = _WebSocketConnection(ws, from);
    // 受信の購読は受け入れ判定より先に張る（購読の通知は非同期なので、
    // 判定前に届くことはない）。拒否した接続は受信を読み捨てるだけにする。
    var accepted = false;
    ws.listen(
      (data) {
        if (!accepted) return;
        if (data is String) {
          handler.onText(connection, data);
        } else {
          handler.onBinary(
            connection,
            data is Uint8List ? data : Uint8List.fromList(data as List<int>),
          );
        }
      },
      onDone: () {
        if (!accepted) return;
        _log(
          '切断 ($from) closeCode=${ws.closeCode ?? "-"} '
          'reason=${ws.closeReason ?? "-"}',
        );
        handler.onClosed(connection);
      },
      onError: (Object e) {
        if (!accepted) return;
        _log('ソケットエラー ($from): $e');
        handler.onClosed(connection);
      },
      cancelOnError: true,
    );
    accepted = handler.onOpened(connection);
  }

  @override
  Future<void> stop() async {
    final http = _http;
    _http = null;
    await http?.close(force: true);
  }
}

class _WebSocketConnection implements TransportConnection {
  final WebSocket _ws;

  @override
  final String label;

  _WebSocketConnection(this._ws, this.label);

  @override
  void send(String message) => _ws.add(message);

  @override
  Future<void> close([int? code, String? reason]) => _ws.close(code, reason);
}
