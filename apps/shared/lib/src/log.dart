import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Where log lines go: logcat / the console by default, a list in tests.
typedef LogSink = void Function(String line);

/// Structured JSON logs (CLAUDE.md): every line carries table_id, device_id and session_id, null when unknown,
/// in the same shape as the backend's and media-server's.
class JsonLog {
  JsonLog(
    this.service, {
    Map<String, Object?> context = const {},
    LogSink? sink,
  }) : _context = {
         'table_id': null,
         'device_id': null,
         'session_id': null,
         ...context,
       },
       _sink = sink ?? debugPrint;

  final String service;
  final Map<String, Object?> _context;
  final LogSink _sink;

  /// The same log with more context, e.g. once the table and the session are known.
  JsonLog withContext(Map<String, Object?> context) =>
      JsonLog(service, context: {..._context, ...context}, sink: _sink);

  void debug(String message, [Map<String, Object?> fields = const {}]) =>
      _write('debug', message, fields);
  void info(String message, [Map<String, Object?> fields = const {}]) =>
      _write('info', message, fields);
  void warn(String message, [Map<String, Object?> fields = const {}]) =>
      _write('warn', message, fields);
  void error(String message, [Map<String, Object?> fields = const {}]) =>
      _write('error', message, fields);

  void _write(String level, String message, Map<String, Object?> fields) {
    _sink(
      jsonEncode({
        'ts': DateTime.now().toUtc().toIso8601String(),
        'level': level,
        'service': service,
        ..._context,
        ...fields,
        'message': message,
      }, toEncodable: (Object? value) => value.toString()),
    );
  }
}
