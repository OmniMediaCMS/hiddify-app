import 'dart:convert';

import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:hiddify/features/tor/tor_control.dart';

class TorConfigTransformer {
  const TorConfigTransformer();

  static const _torSharingInboundTag = 'tor-sharing-in';

  String transform({
    required String content,
    required PerAppProxyMode perAppProxyMode,
    required List<String> perAppTorPackages,
    required List<String> perAppActivePackages,
    required bool enableTorSharing,
    required int torSharingPort,
    required String torSharingPassword,
  }) {
    final root = (jsonDecode(content) as Map).cast<String, dynamic>();
    final outbounds = _list(root, 'outbounds');
    final inbounds = _list(root, 'inbounds');
    _removeOutboundReferences(outbounds, 'tor-out');
    final route = (root['route'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    root['route'] = route;
    final rules = _list(route, 'rules');
    final dns = (root['dns'] as Map?)?.cast<String, dynamic>();
    final dnsServers = dns == null ? null : _list(dns, 'servers');
    final dnsRules = dns == null ? null : _list(dns, 'rules');

    _ensureOutbound(outbounds, {
      'type': 'socks',
      'tag': 'tor-out',
      'server': '127.0.0.1',
      'server_port': TorControl.socksPort,
      'version': '5',
    });

    _removeGeneratedInbounds(inbounds);
    _removeGeneratedRules(rules);
    if (dns != null && dnsServers != null && dnsRules != null) {
      _ensureDnsServer(dns, dnsServers);
      _removeGeneratedDnsRules(dnsRules);
      dnsRules.insertAll(0, _generatedDnsRules(perAppProxyMode, perAppTorPackages, _tunSourceCidrs(inbounds)));
    }
    if (enableTorSharing) {
      _ensureTorSharingInbound(inbounds, torSharingPort, torSharingPassword);
    }
    rules.insertAll(
      0,
      _generatedRules(
        perAppProxyMode,
        perAppTorPackages,
        perAppActivePackages,
        _tunSourceCidrs(inbounds),
        enableTorSharing,
      ),
    );

    return const JsonEncoder.withIndent('  ').convert(root);
  }

  List<Map<String, dynamic>> _generatedRules(
    PerAppProxyMode perAppProxyMode,
    List<String> perAppTorPackages,
    List<String> perAppActivePackages,
    List<String> tunSourceCidrs,
    bool enableTorSharing,
  ) {
    final generated = <Map<String, dynamic>>[];
    if (enableTorSharing) {
      generated
        ..add({
          'inbound': [_torSharingInboundTag],
          'network': 'udp',
          'action': 'reject',
        })
        ..add({
          'inbound': [_torSharingInboundTag],
          'network': 'tcp',
          'outbound': 'tor-out',
        });
    }

    final shouldTorAllProxiedApps = perAppProxyMode != PerAppProxyMode.include;
    if (shouldTorAllProxiedApps) {
      generated
        ..addAll(_tunDnsHijackRules())
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
      final allIncludedAppsUseTor = _sameSet(perAppActivePackages, perAppTorPackages);
      final torMatchRule = <String, dynamic>{
        if (allIncludedAppsUseTor && tunSourceCidrs.isNotEmpty)
          'source_ip_cidr': tunSourceCidrs
        else
          'package_name': perAppTorPackages,
      };
      generated
        ..addAll(_tunDnsHijackRules())
        ..add({
          'inbound': ['tun-in'],
          ...torMatchRule,
          'network': 'udp',
          'action': 'reject',
        })
        ..add({
          'inbound': ['tun-in'],
          ...torMatchRule,
          'network': 'tcp',
          'outbound': 'tor-out',
        });
    }

    return generated;
  }

  List<Map<String, dynamic>> _tunDnsHijackRules() {
    return [
      {
        'inbound': ['tun-in'],
        'network': 'udp',
        'port': 53,
        'action': 'hijack-dns',
      },
      {
        'inbound': ['tun-in'],
        'network': 'tcp',
        'port': 53,
        'action': 'hijack-dns',
      },
    ];
  }

  List<Map<String, dynamic>> _generatedDnsRules(
    PerAppProxyMode perAppProxyMode,
    List<String> perAppTorPackages,
    List<String> tunSourceCidrs,
  ) {
    final shouldTorAllProxiedApps = perAppProxyMode != PerAppProxyMode.include;
    if (shouldTorAllProxiedApps) {
      return [
        {'server': 'dns-tor'},
      ];
    }

    if (perAppTorPackages.isEmpty) return const [];

    return [
      {'server': 'dns-tor'},
    ];
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

  void _ensureTorSharingInbound(List<dynamic> inbounds, int port, String password) {
    final inbound = {'type': 'mixed', 'tag': _torSharingInboundTag, 'listen': '0.0.0.0', 'listen_port': port};
    if (password.isNotEmpty) {
      inbound['users'] = [
        {'username': 'hiddify', 'password': password},
      ];
    }
    inbounds.add(inbound);
  }

  List<String> _tunSourceCidrs(List<dynamic> inbounds) {
    for (final inbound in inbounds) {
      if (inbound is! Map || inbound['tag'] != 'tun-in') continue;
      final address = inbound['address'];
      if (address is List) {
        return address.whereType<String>().where((item) => item.contains('/')).toList();
      }
      if (address is String && address.contains('/')) return [address];
    }
    return const [];
  }

  void _ensureDnsServer(Map<String, dynamic> dns, List<dynamic> servers) {
    servers.removeWhere((item) => item is Map && item['tag'] == 'dns-tor');
    final remoteServer = _remoteDnsServer(dns, servers);
    if (remoteServer == null) return;
    servers.add({...remoteServer, 'tag': 'dns-tor', 'detour': 'tor-out'});
  }

  Map<String, dynamic>? _remoteDnsServer(Map<String, dynamic> dns, List<dynamic> servers) {
    final preferredTags = ['dns-remote-fallback', 'dns-remote', if (dns['final'] is String) dns['final'] as String];
    for (final tag in preferredTags) {
      final server = _serverByTag(servers, tag);
      if (server != null && _isTorSafeDnsServer(server)) return server;
    }
    for (final tag in preferredTags) {
      final server = _serverByTag(servers, tag);
      if (server != null) return server;
    }
    return null;
  }

  Map<String, dynamic>? _serverByTag(List<dynamic> servers, String tag) {
    for (final server in servers) {
      if (server is Map && server['tag'] == tag) return server.cast<String, dynamic>();
    }
    return null;
  }

  bool _isTorSafeDnsServer(Map<String, dynamic> server) {
    final type = server['type'];
    return type == 'https' || type == 'tls' || type == 'quic';
  }

  void _removeOutboundReferences(List<dynamic> outbounds, String tag) {
    for (final outbound in outbounds) {
      if (outbound is! Map) continue;
      final children = outbound['outbounds'];
      if (children is List) {
        children.removeWhere((item) => item == tag);
      }
      if (outbound['default'] == tag) {
        outbound.remove('default');
      }
    }
  }

  void _removeGeneratedRules(List<dynamic> rules) {
    rules.removeWhere((rule) {
      if (rule is! Map) return false;
      final inbound = rule['inbound'];
      final outbound = rule['outbound'];
      final generatedTorSharingRule = inbound is List && inbound.contains(_torSharingInboundTag);
      final generatedTunRule =
          inbound is List &&
          inbound.contains('tun-in') &&
          (outbound == 'tor-out' ||
              (rule['action'] == 'reject' && rule['network'] == 'udp') ||
              (rule['action'] == 'hijack-dns' && (rule['protocol'] == 'dns' || rule['port'] == 53)));
      return (inbound is List && inbound.contains('tor-upstream-in')) ||
          outbound == 'tor-out' ||
          generatedTunRule ||
          generatedTorSharingRule;
    });
  }

  void _removeGeneratedInbounds(List<dynamic> inbounds) {
    inbounds.removeWhere((inbound) => inbound is Map && inbound['tag'] == _torSharingInboundTag);
  }

  void _removeGeneratedDnsRules(List<dynamic> rules) {
    rules.removeWhere((rule) => rule is Map && rule['server'] == 'dns-tor');
  }

  bool _sameSet(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    return left.toSet().containsAll(right);
  }
}
