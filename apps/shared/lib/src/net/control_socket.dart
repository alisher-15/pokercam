import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../wire.dart';
import 'ids.dart';

/// `signaling.error` in reply to a request (contracts/ws/signaling/signaling.error.json).
class SignalingException implements Exception {
  const SignalingException(this.code, [this.message = '']);

  /// unauthorized, forbidden, room_full, license_blocked, not_found, bad_request, internal.
  final String code;
  final String message;

  @override
  String toString() =>
      'SignalingException($code${message.isEmpty ? '' : ': $message'})';
}

/// The socket closed while a request waited for its reply.
class SocketClosedException implements Exception {
  const SocketClosedException(this.code);

  final int? code;

  @override
  String toString() => 'SocketClosedException($code)';
}

/// One WebSocket to media-server (SPEC 5.3): signaling requests with their replies, and the control
/// messages of the table's room. Every message is the envelope `{type, id, ts, table_id, payload}`.
class ControlSocket {
  ControlSocket._(this._ws, this.tableId) {
    _subscription = _ws.listen(
      _receive,
      onDone: _closed,
      onError: (Object _) => _closed(),
      cancelOnError: true,
    );
  }

  /// Close code media-server sends a camera another camera of the same table replaced (stage 3).
  static const replacedByAnotherCamera = 4001;

  final WebSocket _ws;
  final String tableId;
  late final StreamSubscription<dynamic> _subscription;
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  final _done = Completer<void>();

  /// Opens the socket. A dead connection (network gone) is noticed by pings within about [ping] × 2; null
  /// sends none (widget tests, whose fake clock would keep dart:io's ping timer pending).
  static Future<ControlSocket> connect(
    String url,
    String tableId, {
    Duration timeout = const Duration(seconds: 10),
    Duration? ping = const Duration(seconds: 5),
  }) async {
    final ws = await WebSocket.connect(url).timeout(timeout);
    ws.pingInterval = ping;
    return ControlSocket._(ws, tableId);
  }

  /// Messages that are not replies to this side's requests: control messages, `signaling.new_producer`, …
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// Completes when the socket is closed, by either side or by a lost connection.
  Future<void> get done => _done.future;

  bool get isOpen => !_done.isCompleted;

  /// The close code, e.g. [replacedByAnotherCamera]; null for a lost connection.
  int? get closeCode => _ws.closeCode;

  /// Sends a message and returns its id (what a reply's `request_id` points to).
  String send(String type, Map<String, dynamic> payload) {
    final id = newUuid();
    if (isOpen) {
      _ws.add(
        encodeWire({
          'type': type,
          'id': id,
          'ts': DateTime.now().millisecondsSinceEpoch,
          'table_id': tableId,
          'payload': payload,
        }),
      );
    }
    return id;
  }

  /// Sends a request and returns the payload of its reply; `signaling.error` throws [SignalingException].
  Future<Map<String, dynamic>> request(
    String type,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 10),
  }) {
    if (!isOpen) return Future.error(SocketClosedException(closeCode));
    final reply = Completer<Map<String, dynamic>>();
    final id = send(type, payload);
    _pending[id] = reply;
    return reply.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('no reply to $type', timeout);
      },
    );
  }

  void _receive(dynamic data) {
    if (data is! String) return;
    final Object? json;
    try {
      json = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (json is! Map<String, dynamic>) return;
    final payload = json['payload'];
    final requestId = payload is Map<String, dynamic>
        ? payload['request_id']
        : null;
    final waiting = requestId is String ? _pending.remove(requestId) : null;
    if (waiting != null) {
      if (json['type'] == 'signaling.error') {
        waiting.completeError(
          SignalingException(
            '${payload['code']}',
            '${payload['message'] ?? ''}',
          ),
        );
      } else {
        waiting.complete(payload as Map<String, dynamic>);
      }
      return;
    }
    _messages.add(json);
  }

  void _closed() {
    if (_done.isCompleted) return;
    for (final waiting in _pending.values) {
      waiting.completeError(SocketClosedException(closeCode));
    }
    _pending.clear();
    _done.complete();
    unawaited(_messages.close());
  }

  Future<void> close([int code = WebSocketStatus.normalClosure]) async {
    await _ws.close(code);
    await _subscription.cancel();
    _closed();
  }
}
