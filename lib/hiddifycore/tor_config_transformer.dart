import 'dart:convert';

import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:hiddify/features/tor/tor_control.dart';

class TorConfigTransformer {
  const TorConfigTransformer();

  String transform({
    required String content,
    required PerAppProxyMode perAppProxyMode,
    required List<String> perAppTorPackages,
  }) {
    final root = (jsonDecode(content) as Map).cast<String, dynamic>();
    final outbounds = _list(root, 'outbounds');
    final route = (root['route'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    root['route'] = route;
    final rules = _list(route, 'rules');

    _ensureOutbound(outbounds, {
      'type': 'socks',
      'tag': 'tor-out',
      'server': '127.0.0.1',
      'server_port': TorControl.socksPort,
      'version': '5',
    });

    _removeGeneratedRules(rules);
    rules.insertAll(0, _generatedRules(perAppProxyMode, perAppTorPackages));

    return const JsonEncoder.withIndent('  ').convert(root);
  }

  List<Map<String, dynamic>> _generatedRules(PerAppProxyMode perAppProxyMode, List<String> perAppTorPackages) {
    final generated = <Map<String, dynamic>>[];

    final shouldTorAllProxiedApps = perAppProxyMode != PerAppProxyMode.include;
    if (shouldTorAllProxiedApps) {
      generated
        ..add({
          'inbound': ['tun-in'],
          'network': 'udp',
          'action': 'reject',
        })
        ..add({
          'inbound': ['tun-in'],
          'network': 'tcp',
          'outbound': 'tor-out',
        });
      return generated;
    }

    if (perAppTorPackages.isNotEmpty) {
      generated
        ..add({
          'inbound': ['tun-in'],
          'package_name': perAppTorPackages,
          'network': 'udp',
          'action': 'reject',
        })
        ..add({
          'inbound': ['tun-in'],
          'package_name': perAppTorPackages,
          'network': 'tcp',
          'outbound': 'tor-out',
        });
    }

    return generated;
  }

  List<dynamic> _list(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is List) return value;
    final list = <dynamic>[];
    map[key] = list;
    return list;
  }

  void _ensureOutbound(List<dynamic> outbounds, Map<String, dynamic> outbound) {
    outbounds.removeWhere((item) => item is Map && item['tag'] == outbound['tag']);
    outbounds.add(outbound);
  }

  void _removeGeneratedRules(List<dynamic> rules) {
    rules.removeWhere((rule) {
      if (rule is! Map) return false;
      final inbound = rule['inbound'];
      final outbound = rule['outbound'];
      return (inbound is List && inbound.contains('tor-upstream-in')) || outbound == 'tor-out';
    });
  }
}
