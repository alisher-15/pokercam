// Stage 1 spike (SPEC 12): not production code, so its texts are not localized.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'camera2.dart';
import 'loopback.dart';
import 'self_test.dart';

void main() => runApp(
  const MaterialApp(home: SpikeScreen(), debugShowCheckedModeBanner: false),
);

class SpikeScreen extends StatefulWidget {
  const SpikeScreen({super.key});

  @override
  State<SpikeScreen> createState() => _SpikeScreenState();
}

class _SpikeScreenState extends State<SpikeScreen> {
  final camera = Camera2();
  final localView = RTCVideoRenderer();
  final remoteView = RTCVideoRenderer();
  LoopbackSession? session;
  Map<String, dynamic>? caps;
  Map<String, dynamic> cameraState = {};
  Map<String, dynamic> stats = {};
  final controls = <String, ({String mode, double? value, String? preset})>{};
  final log = <String>[];
  String? report;
  bool busy = false;
  Timer? poll;
  Timer? debounce;

  @override
  void initState() {
    super.initState();
    localView.initialize();
    remoteView.initialize();
  }

  @override
  void dispose() {
    poll?.cancel();
    debounce?.cancel();
    session?.dispose();
    localView.dispose();
    remoteView.dispose();
    super.dispose();
  }

  Future<void> start() async {
    setState(() => busy = true);
    try {
      final s = await LoopbackSession.start();
      localView.srcObject = s.local;
      remoteView.srcObject = s.remote;
      final c = await camera.capabilities(s.videoTrack.id!);
      setState(() {
        session = s;
        caps = c;
      });
      poll = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => refresh(),
      );
    } catch (e) {
      addLog('Не удалось включить камеру: $e');
    } finally {
      setState(() => busy = false);
    }
  }

  Future<void> refresh() async {
    final s = session;
    if (s == null) return;
    final st = await camera.state();
    final sts = await s.stats();
    if (mounted) {
      setState(() {
        cameraState = (st['result'] as Map<String, dynamic>?) ?? {};
        stats = sts;
      });
    }
  }

  void addLog(String line) => setState(() => log.insert(0, line));

  void change(
    String param,
    ({String mode, double? value, String? preset}) control,
  ) {
    setState(() => controls[param] = control);
    debounce?.cancel();
    // SPEC 8.4: send at most every 100 ms while a slider moves.
    debounce = Timer(const Duration(milliseconds: 100), () async {
      try {
        await camera.set(
          session!.videoTrack.id!,
          param,
          control.mode,
          value: control.value,
          preset: control.preset,
        );
      } on PlatformException catch (e) {
        addLog('$param: ${e.message}');
      }
    });
  }

  Future<void> selfTest() async {
    setState(() {
      busy = true;
      report = null;
    });
    try {
      final result = await runSelfTest(session!, camera, log: addLog);
      controls.clear();
      setState(
        () => report = const JsonEncoder.withIndent('  ').convert(result),
      );
      addLog(
        result['passed'] == true ? 'Автотест пройден' : 'Автотест НЕ пройден',
      );
    } catch (e) {
      addLog('Автотест упал: $e');
    } finally {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final params = (caps?['params'] as Map<String, dynamic>?) ?? {};
    return Scaffold(
      appBar: AppBar(title: const Text('Camera2 + WebRTC: этап 1')),
      body: session == null
          ? Center(
              child: busy
                  ? const CircularProgressIndicator()
                  : FilledButton(
                      onPressed: start,
                      child: const Text('Включить камеру'),
                    ),
            )
          : ListView(
              padding: const EdgeInsets.all(8),
              children: [
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Stack(
                    children: [
                      RTCVideoView(localView),
                      Positioned(
                        right: 4,
                        bottom: 4,
                        width: 120,
                        height: 68,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white),
                          ),
                          child: RTCVideoView(remoteView),
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  'Отправка: ${stats['sent_size']} ${stats['sent_fps']} fps ${stats['codec']} (${stats['encoder']}) · '
                  'приём: ${stats['received_size']} ${stats['received_fps']} fps · '
                  '${caps?['hardware_level']} ${caps?['capabilities']}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Row(
                  children: [
                    FilledButton(
                      onPressed: busy ? null : selfTest,
                      child: const Text('Автотест'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () async {
                              await camera.reset(session!.videoTrack.id!);
                              setState(controls.clear);
                            },
                      child: const Text('Всё авто'),
                    ),
                    const SizedBox(width: 8),
                    if (report != null)
                      OutlinedButton(
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: report!)),
                        child: const Text('Копировать отчёт'),
                      ),
                  ],
                ),
                for (final param in params.keys)
                  _paramRow(param, params[param] as Map<String, dynamic>),
                for (final line in log.take(20))
                  Text(line, style: Theme.of(context).textTheme.bodySmall),
                if (report != null)
                  SelectableText(
                    report!,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _paramRow(String param, Map<String, dynamic> cap) {
    if (cap['supported'] != true) {
      return ListTile(dense: true, title: Text('$param: не поддерживается'));
    }
    final modes = (cap['modes'] as List).cast<String>();
    final presets = (cap['presets'] as List).cast<String>();
    final lo = (cap['min'] as num).toDouble();
    final hi = (cap['max'] as num).toDouble();
    final control =
        controls[param] ?? (mode: modes.first, value: null, preset: null);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$param · камера сообщает: ${cameraState[param] ?? '—'}'),
            Wrap(
              spacing: 4,
              children: [
                for (final mode in modes)
                  ChoiceChip(
                    label: Text(mode),
                    selected: control.mode == mode,
                    onSelected: (_) => change(param, (
                      mode: mode,
                      value: mode == 'manual'
                          ? (control.value ?? (lo + hi) / 2)
                          : null,
                      preset: mode == 'preset'
                          ? (control.preset ?? presets.first)
                          : null,
                    )),
                  ),
                if (control.mode == 'preset')
                  for (final preset in presets)
                    ChoiceChip(
                      label: Text(preset),
                      selected: control.preset == preset,
                      onSelected: (_) => change(param, (
                        mode: 'preset',
                        value: null,
                        preset: preset,
                      )),
                    ),
              ],
            ),
            if (control.mode == 'manual')
              Slider(
                min: lo,
                max: hi,
                value: (control.value ?? (lo + hi) / 2).clamp(lo, hi),
                label: (control.value ?? 0).toStringAsFixed(2),
                onChanged: (v) =>
                    change(param, (mode: 'manual', value: v, preset: null)),
              ),
          ],
        ),
      ),
    );
  }
}
