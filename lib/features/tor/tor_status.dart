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

class _TorGeoIpSource {
  const _TorGeoIpSource(this.url);

  final String url;
}

const _torGeoIpSources = [
  _TorGeoIpSource('https://ipwho.is/'),
  _TorGeoIpSource('https://api.ip.sb/geoip/'),
  _TorGeoIpSource('https://ipapi.co/json/'),
  _TorGeoIpSource('https://ipinfo.io/json/'),
];

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
  Object? lastError;
  for (final source in _torGeoIpSources) {
    try {
      return await _probeTorExitInfoSource(source);
    } catch (error) {
      lastError = error;
    }
  }
  throw StateError('unable to retrieve Tor exit info: $lastError');
}

Future<TorExitInfo> _probeTorExitInfoSource(_TorGeoIpSource source) async {
  final uri = Uri.parse(source.url);
  final stopwatch = Stopwatch()..start();
  final response = await _httpGetViaSocks5(uri);
  final latency = stopwatch.elapsed;
  final bodyStart = response.indexOf('\r\n\r\n');
  if (bodyStart < 0) throw const FormatException('missing HTTP body');
  final headers = response.substring(0, bodyStart);
  final statusCode = _httpStatusCode(headers);
  if (statusCode < 200 || statusCode >= 300) {
    throw HttpException('GeoIP source returned HTTP $statusCode', uri: uri);
  }
  final rawBody = response.substring(bodyStart + 4);
  final body = _decodeHttpBody(headers, rawBody);
  final info = TorExitInfo.fromJson(jsonDecode(body) as Map<String, dynamic>, latency);
  if (info.ip.isEmpty && info.countryCode.isEmpty) throw const FormatException('missing GeoIP fields');
  return info;
}

Future<String> _httpGetViaSocks5(Uri uri) async {
  final targetHost = uri.host;
  final targetPort = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
  final path = uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;
  final requestPath = path.isEmpty ? '/' : path;
  final request = 'GET $requestPath HTTP/1.1\r\nHost: $targetHost\r\nConnection: close\r\n\r\n';

  final socket = await Socket.connect('127.0.0.1', 19050, timeout: const Duration(seconds: 8));
  final reader = _SocketReader(socket);
  try {
    socket.add([0x05, 0x01, 0x00]);
    await reader.readExact(2).timeout(const Duration(seconds: 8));

    final hostBytes = ascii.encode(targetHost);
    socket.add([0x05, 0x01, 0x00, 0x03, hostBytes.length, ...hostBytes, targetPort >> 8, targetPort & 0xff]);
    await _readSocks5ConnectReply(reader).timeout(const Duration(seconds: 8));

    if (uri.scheme == 'https') {
      reader.pause();
      final secureSocket = await SecureSocket.secure(socket, host: targetHost).timeout(const Duration(seconds: 8));
      final secureReader = _SocketReader(secureSocket);
      try {
        secureSocket.write(request);
        return utf8.decode(await secureReader.readUntilDone().timeout(const Duration(seconds: 20)));
      } finally {
        await secureReader.cancel();
        await secureSocket.close();
      }
    } else {
      socket.write(request);
      return utf8.decode(await reader.readUntilDone().timeout(const Duration(seconds: 20)));
    }
  } finally {
    await reader.cancel();
    await socket.close();
  }
}

Future<void> _readSocks5ConnectReply(_SocketReader reader) async {
  final header = await reader.readExact(4);
  if (header[1] != 0x00) throw SocketException('SOCKS5 connect failed: ${header[1]}');
  final addressLength = switch (header[3]) {
    0x01 => 4,
    0x03 => (await reader.readExact(1)).first,
    0x04 => 16,
    _ => throw SocketException('SOCKS5 unsupported address type: ${header[3]}'),
  };
  await reader.readExact(addressLength + 2);
}

int _httpStatusCode(String headers) {
  final statusLineEnd = headers.indexOf('\r\n');
  final statusLine = statusLineEnd < 0 ? headers : headers.substring(0, statusLineEnd);
  final parts = statusLine.split(' ');
  if (parts.length < 2) throw FormatException('invalid HTTP status line: $statusLine');
  return int.parse(parts[1]);
}

String _decodeHttpBody(String headers, String body) {
  if (!headers.toLowerCase().contains('transfer-encoding: chunked')) return body;
  final decoded = StringBuffer();
  var cursor = 0;
  while (cursor < body.length) {
    final sizeEnd = body.indexOf('\r\n', cursor);
    if (sizeEnd < 0) throw const FormatException('invalid chunked HTTP body');
    final sizeText = body.substring(cursor, sizeEnd).split(';').first.trim();
    final size = int.parse(sizeText, radix: 16);
    if (size == 0) break;
    final chunkStart = sizeEnd + 2;
    final chunkEnd = chunkStart + size;
    if (chunkEnd > body.length) throw const FormatException('truncated chunked HTTP body');
    decoded.write(body.substring(chunkStart, chunkEnd));
    cursor = chunkEnd + 2;
  }
  return decoded.toString();
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

  void pause() {
    _subscription?.pause();
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
