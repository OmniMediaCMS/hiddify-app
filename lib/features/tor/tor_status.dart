import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

enum TorConnectionPhase { disabled, starting, connecting, connected, failed, stopping }

class TorConnectionStatus {
  const TorConnectionStatus({required this.phase, required this.bootstrapPercent, required this.summary});

  const TorConnectionStatus.disabled()
    : phase = TorConnectionPhase.disabled,
      bootstrapPercent = 0,
      summary = 'Disabled';

  final TorConnectionPhase phase;
  final int bootstrapPercent;
  final String summary;

  bool get isConnected => phase == TorConnectionPhase.connected;
  bool get isPending => phase == TorConnectionPhase.starting || phase == TorConnectionPhase.connecting;

  static TorConnectionStatus fromEvent(Object? event) {
    final map = event is Map ? event : const <Object?, Object?>{};
    final status = '${map['status'] ?? 'Disabled'}'.toLowerCase();
    final phase = switch (status) {
      'starting' => TorConnectionPhase.starting,
      'bootstrapping' => TorConnectionPhase.connecting,
      'ready' => TorConnectionPhase.connected,
      'failed' => TorConnectionPhase.failed,
      'stopping' => TorConnectionPhase.stopping,
      _ => TorConnectionPhase.disabled,
    };
    final percentValue = map['bootstrapPercent'];
    final percent = switch (percentValue) {
      int value => value,
      double value => value.round(),
      String value => int.tryParse(value) ?? 0,
      _ => 0,
    };
    return TorConnectionStatus(
      phase: phase,
      bootstrapPercent: percent.clamp(0, 100),
      summary: '${map['summary'] ?? ''}',
    );
  }
}

class TorExitInfo {
  const TorExitInfo({required this.ip, required this.countryCode, required this.city, required this.latency});

  final String ip;
  final String countryCode;
  final String city;
  final Duration latency;

  static TorExitInfo fromJson(Map<String, dynamic> json, Duration latency) {
    return TorExitInfo(
      ip: json['ip'] as String? ?? '',
      countryCode: json['country_code'] as String? ?? json['country'] as String? ?? '',
      city: json['city'] as String? ?? '',
      latency: latency,
    );
  }
}

final torStatusProvider = StreamProvider<TorConnectionStatus>((ref) async* {
  final enabled = ref.watch(Preferences.torEnabled);
  if (!PlatformUtils.isAndroid || !enabled) {
    yield const TorConnectionStatus.disabled();
    return;
  }

  const channel = EventChannel('com.hiddify.app/tor.status', JSONMethodCodec());
  try {
    yield* channel.receiveBroadcastStream().map(TorConnectionStatus.fromEvent);
  } catch (_) {
    yield const TorConnectionStatus.disabled();
  }
});

final torExitInfoProvider = StreamProvider.autoDispose<TorExitInfo?>((ref) async* {
  final status = ref.watch(torStatusProvider).valueOrNull;
  if (!PlatformUtils.isAndroid || status?.isConnected != true) {
    yield null;
    return;
  }

  while (true) {
    try {
      yield await _probeTorExitInfo();
    } catch (_) {
      yield null;
    }
    await Future<void>.delayed(const Duration(seconds: 30));
  }
});

Future<TorExitInfo> _probeTorExitInfo() async {
  final started = DateTime.now();
  final response = await _httpGetViaSocks5(
    socksHost: '127.0.0.1',
    socksPort: 19050,
    targetHost: 'ipwho.is',
    targetPort: 80,
    request: 'GET / HTTP/1.1\r\nHost: ipwho.is\r\nConnection: close\r\n\r\n',
  );
  final latency = DateTime.now().difference(started);
  final bodyStart = response.indexOf('\r\n\r\n');
  if (bodyStart < 0) throw const FormatException('missing HTTP body');
  final body = response.substring(bodyStart + 4);
  return TorExitInfo.fromJson(jsonDecode(body) as Map<String, dynamic>, latency);
}

Future<String> _httpGetViaSocks5({
  required String socksHost,
  required int socksPort,
  required String targetHost,
  required int targetPort,
  required String request,
}) async {
  final socket = await Socket.connect(socksHost, socksPort, timeout: const Duration(seconds: 8));
  final reader = _SocketReader(socket);
  try {
    socket.add([0x05, 0x01, 0x00]);
    await reader.readExact(2).timeout(const Duration(seconds: 8));

    final hostBytes = ascii.encode(targetHost);
    socket.add([0x05, 0x01, 0x00, 0x03, hostBytes.length, ...hostBytes, targetPort >> 8, targetPort & 0xff]);
    final reply = await reader.readExact(10).timeout(const Duration(seconds: 8));
    if (reply[1] != 0x00) throw SocketException('SOCKS5 connect failed: ${reply[1]}');

    socket.write(request);
    return utf8.decode(await reader.readUntilDone().timeout(const Duration(seconds: 20)));
  } finally {
    await reader.cancel();
    await socket.close();
  }
}

class _SocketReader {
  _SocketReader(Socket socket) {
    _subscription = socket.listen(
      (chunk) {
        _buffer.addAll(chunk);
        _notify();
      },
      onError: (Object error) {
        _error = error;
        _notify();
      },
      onDone: () {
        _done = true;
        _notify();
      },
      cancelOnError: true,
    );
  }

  final _buffer = Queue<int>();
  StreamSubscription<List<int>>? _subscription;
  Completer<void>? _waiter;
  Object? _error;
  bool _done = false;

  Future<List<int>> readExact(int length) async {
    while (_buffer.length < length) {
      if (_error != null) throw _error!;
      if (_done) throw const SocketException('socket closed');
      await _wait();
    }
    return List<int>.generate(length, (_) => _buffer.removeFirst());
  }

  Future<List<int>> readUntilDone() async {
    while (!_done && _error == null) {
      await _wait();
    }
    if (_error != null) throw _error!;
    return _buffer.toList();
  }

  Future<void> cancel() async {
    await _subscription?.cancel();
  }

  Future<void> _wait() {
    _waiter ??= Completer<void>();
    return _waiter!.future;
  }

  void _notify() {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
    _waiter = null;
  }
}
