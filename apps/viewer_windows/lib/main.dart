import 'package:flutter/material.dart';
import 'package:shared/shared.dart';

import 'src/app.dart';
import 'src/store.dart';
import 'src/subscriber.dart';

/// `viewer_windows.exe [--table <id>]`: a window for one table (SPEC 8); without it, the tables list.
void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  final log = JsonLog('viewer');
  final table = args.indexOf('--table');
  runApp(
    ViewerApp(
      services: Services(
        store: SecureConnectionStore(),
        log: log,
        subscriber: () => MediasoupSubscriber(log),
      ),
      initialTable: table >= 0 && table + 1 < args.length
          ? args[table + 1]
          : null,
    ),
  );
}
