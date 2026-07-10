import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/hiddifycore/core_interface/core_interface_mobile.dart';
import 'package:hiddify/utils/platform_utils.dart';

class TorControl {
  const TorControl();

  static const socksPort = 19050;
  static const controlPort = 19051;
  static const defaultUpstreamSocksPort = 12334;

  static const _channel = MethodChannel('com.hiddify.app/method');

  Future<void> start({
    required TorBridgeMode bridgeMode,
    required String customBridges,
    required bool customBridgesEnabled,
    int upstreamSocksPort = defaultUpstreamSocksPort,
  }) async {
    if (!PlatformUtils.isAndroid) return;
    final bridges = customBridgesEnabled
        ? customBridges.split(RegExp(r'\r?\n')).map((line) => line.trim()).where((line) => line.isNotEmpty).toList()
        : const <String>[];
    await _channel.invokeMethod('startTor', {
      'socksPort': socksPort,
      'controlPort': controlPort,
      'upstreamSocksPort': upstreamSocksPort,
      'bridgeMode': bridgeMode.name,
      'customBridges': bridges,
    });
  }

  Future<void> stop() async {
    if (!PlatformUtils.isAndroid) return;
    await _channel.invokeMethod('stopTor');
  }

  Future<bool> waitUntilUpstreamReady({int upstreamSocksPort = defaultUpstreamSocksPort}) {
    return waitUntilPort(upstreamSocksPort, true, null, maxTry: 25);
  }

  Future<bool> isTorSocksReady() async {
    try {
      final socket = await Socket.connect('127.0.0.1', socksPort, timeout: const Duration(milliseconds: 500));
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }
}
