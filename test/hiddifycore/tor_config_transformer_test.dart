import 'dart:convert';

// ignore: depend_on_referenced_packages
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/per_app_proxy/model/per_app_proxy_mode.dart';
import 'package:hiddify/hiddifycore/tor_config_transformer.dart';

void main() {
  test('adds Tor sharing inbound and routes TCP through Tor', () {
    final transformed = const TorConfigTransformer().transform(
      content: jsonEncode({
        'inbounds': [
          {
            'type': 'tun',
            'tag': 'tun-in',
            'address': ['172.19.0.1/28'],
          },
        ],
        'outbounds': [
          {'type': 'direct', 'tag': 'direct'},
        ],
        'route': {'rules': <Map<String, Object?>>[]},
      }),
      perAppProxyMode: PerAppProxyMode.include,
      perAppTorPackages: const [],
      perAppActivePackages: const [],
      enableTorSharing: true,
      torSharingPort: 12338,
      torSharingPassword: 'secret',
    );

    final root = jsonDecode(transformed) as Map<String, dynamic>;
    final inbounds = (root['inbounds'] as List).cast<Map<String, dynamic>>();
    final rules = ((root['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();

    expect(
      inbounds,
      contains(
        allOf(
          containsPair('type', 'mixed'),
          containsPair('tag', 'tor-sharing-in'),
          containsPair('listen', '0.0.0.0'),
          containsPair('listen_port', 12338),
          containsPair('users', [
            {'username': 'hiddify', 'password': 'secret'},
          ]),
        ),
      ),
    );
    expect(
      rules,
      contains(
        allOf(
          containsPair('inbound', ['tor-sharing-in']),
          containsPair('network', 'tcp'),
          containsPair('outbound', 'tor-out'),
        ),
      ),
    );
    expect(
      rules,
      contains(
        allOf(
          containsPair('inbound', ['tor-sharing-in']),
          containsPair('network', 'udp'),
          containsPair('action', 'reject'),
        ),
      ),
    );
  });
}
