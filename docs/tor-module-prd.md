# Tor Module PRD

## Background

Hiddify's Tor capability is an experimental Android module. It does not replace the existing proxy selection, proxy latency testing, or main connection status. Instead, after Hiddify core is connected, it adds a Tor path for selected traffic.

The current implementation must preserve two product semantics:

- Existing Hiddify connection status, proxy selection, and proxy latency still mean: local device -> selected Hiddify proxy outbound -> target network.
- Tor status, Tor exit information, and Tor latency mean: local device -> selected Hiddify proxy outbound -> Tor network -> target network.

Tor failures must not pollute the main connection status, and they must not rewrite ordinary proxy-node latency as Tor-path latency.

## Current Scope

Implemented scope:

1. Android Tor enable switch.
2. Android Tor bridge modes: Direct, obfs4, Snowflake, and meek.
3. Custom bridge multiline input. When enabled and non-empty, custom bridges take priority.
4. Independent Tor status card showing bootstrap phase, bootstrap percentage, and failure summary.
5. After Tor is connected, Tor SOCKS is used to probe the exit IP, city/country, and Tor-path latency.
6. When Tor is enabled, the sing-box raw config is rewritten to add the `tor-out` outbound and DNS detour.
7. In per-app include mode, selected proxied apps can be individually marked with `Use Tor`.

Scope not fully implemented or still requiring validation:

1. Tor on non-Android platforms.
2. Independent Tor retry without triggering a full core reconnect.
3. Package-scoped DNS split. Current DNS rules are broad priority rules when Tor is active.
4. Strict bridge-line pre-validation before starting Tor.
5. A Tor latency test entry and log naming that are fully separated from proxy latency testing.

## Non-Goals

1. Do not replace Hiddify's existing proxy selection UI.
2. Do not redefine existing proxy latency as Tor latency.
3. Do not require Tor for ordinary Hiddify connections.
4. Do not route Hiddify core control traffic through Tor.
5. Do not route proxy-node connection traffic through Tor. Tor bootstrap upstream must use the current Hiddify proxy path.

## User Settings

Location:

```text
Settings -> General
```

Android settings:

```text
Enable Tor: boolean
Tor bridge mode:
- Direct
- obfs4
- Snowflake
- meek

Use custom Tor bridges: boolean
Custom Tor bridges: multi-line string
```

Default values:

```text
tor_enabled = false
tor_bridge_mode = obfs4
tor_custom_bridges_enabled = false
tor_custom_bridges = ""
```

Behavior:

- When `Enable Tor` is off, native Tor is not started, the Tor status card is not shown, and the current config is not rewritten as a Tor raw config.
- When `Use custom Tor bridges` is on and the bridge text is non-empty, `TorProcessManager` uses those custom bridges.
- When custom bridges are empty or disabled, the implementation first reads `assets/tor/builtin-bridges.json`. If reading fails or the selected mode has no built-in bridges, it falls back to code-defined bridge lines.
- Custom bridge text must be split on all common newline styles: `\n`, `\r\n`, and `\r`. This prevents CR-only multiline text from being written into `torrc` as one invalid bridge line.

## UI State

### Home UI

When Tor is disabled:

```text
Main connection status: existing Hiddify status
Proxy latency: existing Hiddify proxy latency
Tor card: hidden
```

When Tor is enabled:

```text
Main connection status: existing Hiddify core/proxy status
Proxy latency: local -> selected proxy -> target
Tor card: independent Tor status
```

Current Tor card status mapping:

```text
Native status Disabled -> UI disabled
Native status Starting -> UI starting
Native status Bootstrapping -> UI connecting
Native status Ready -> UI connected
Native status Failed -> UI failed
Native status Stopping -> UI stopping
```

Tor card content:

```text
Tor icon
phase text
bootstrap percentage while starting/connecting
Tor bootstrap summary or error when not connected
exit country and city after connected
Tor path latency after connected
```

### Tor Exit Geo and Latency Detection

Tor exit geo detection and Tor latency detection must happen in Dart. They must not reuse ordinary proxy-node URL test results, and they must not write their result back into proxy latency.

The implementation should follow the existing `ProxyRepository.getCurrentIpInfo()` multi-provider GeoIP fallback logic, using this order:

```text
1. https://ipwho.is/
2. https://api.ip.sb/geoip/
3. https://ipapi.co/json/
4. https://ipinfo.io/json/
```

Ordinary proxy exit detection uses `proxyOnly: true`, meaning the request must go through the current proxy exit instead of direct. Tor exit detection must keep the same "must not go direct" constraint, while forcing the request through the Tor SOCKS path:

```text
Dart GeoIP request -> 127.0.0.1:19050 SOCKS5 -> native Tor -> Tor network -> GeoIP service
```

Tor latency is measured from the start of the Tor GeoIP request until the first valid GeoIP response is received. Its semantic meaning is:

```text
local -> Hiddify proxy -> Tor network -> GeoIP service
```

Geo display fields:

```text
country: required when the provider returns it
city: required when the provider returns it
ip: optional, useful for debug/details
```

UI display requirements:

- When country and city are both available, display `Country, City` or an equivalent localized format.
- When only country is available, display the country without an empty city placeholder.
- When only city is available, display the city without an empty country placeholder.
- When all GeoIP providers fail, show geo as unavailable. Tor connected status must not become failed because of GeoIP failure.
- When GeoIP requests time out or fail, show Tor latency as unavailable and do not pollute ordinary proxy latency.

## State Model

The product layer must keep these states independent:

```text
CoreConnectionStatus
- disconnected
- connecting
- connected
- disconnecting

ProxyHealthStatus
- unknown
- testing
- available
- timeout
- failed

TorStatus
- disabled
- starting
- connecting
- connected
- failed
- stopping
```

Required behavior:

```text
Core connected + Tor connecting
=> main status: connected
=> proxy latency: proxy latency only
=> Tor card: Connecting N%

Core connected + Tor failed
=> main status: connected
=> proxy latency: proxy latency only
=> Tor card: Failed + Tor summary

Proxy timeout + Tor connected
=> main status follows core status
=> proxy latency shows proxy timeout
=> Tor card may still show connected if the Tor path is working
```

Forbidden behavior:

```text
Tor failure -> main status becomes connecting
Tor timeout -> proxy latency becomes timeout
Tor bootstrap pending -> all proxy nodes show timeout
```

## Current Ports

Fixed Tor ports:

```text
Tor SOCKS: 127.0.0.1:19050
Tor Control: 127.0.0.1:19051
Tor DNSPort: 127.0.0.1:19053
```

Tor bootstrap upstream:

```text
127.0.0.1:<ConfigOptions.mixedPort>
default mixed-port = 12334
```

Note: the old fixed `127.0.0.1:19052` / `tor-upstream-in` design is no longer the current source design. The current startup logic reads the Hiddify mixed inbound port and uses it as Tor's upstream SOCKS port.

## Startup Sequence

When Tor is enabled, Android startup sequence:

```text
1. HiddifyCoreService.start/restart is called
2. stop any existing Tor process
3. start normal Hiddify background core with the selected profile
4. read generated current-config.json
5. transform config with TorConfigTransformer
6. write temp/hiddify-tor-config.json
7. restart background core with enableRawConfig=true
8. wait for 127.0.0.1:<mixed-port> to become reachable
9. start native Tor with upstreamSocksPort=<mixed-port>
10. publish Tor status through com.hiddify.app/tor.status
```

Stop sequence:

```text
1. stop native Tor
2. stop Hiddify background core
3. stop native Tor again in the finally path
4. publish core stopped and Tor disabled
```

## Traffic Paths

### Tor Disabled

The ordinary proxy path keeps its existing meaning:

```text
App traffic -> Android VPN/TUN -> Hiddify core -> selected proxy outbound -> target
```

DNS is handled by the original Hiddify/sing-box config.

### Tor Bootstrap Path After Tor Is Enabled

Direct bridge mode:

```text
Tor process -> Socks5Proxy 127.0.0.1:<mixed-port> -> Hiddify core -> selected proxy outbound -> Tor entry/guard
```

obfs4 / meek bridge mode:

```text
Tor process -> ClientTransportPlugin local socks5 -> IPtProxy transport
IPtProxy transport -> socks5://127.0.0.1:<mixed-port> -> Hiddify core -> selected proxy outbound -> bridge
```

Snowflake mode:

```text
Tor process -> ClientTransportPlugin local socks5 -> IPtProxy Snowflake transport
IPtProxy Snowflake transport -> socks5://127.0.0.1:<mixed-port> -> Hiddify core -> selected proxy outbound -> Snowflake rendezvous/bridge
```

Snowflake must use the same upstream SOCKS behavior as obfs4 and meek. The transport is configured with `socks5://127.0.0.1:<mixed-port>` so Snowflake rendezvous traffic follows the currently selected Hiddify proxy path.

### Application TCP Path After Tor Is Enabled

`TorConfigTransformer` appends this outbound:

```json
{
  "type": "socks",
  "tag": "tor-out",
  "server": "127.0.0.1",
  "server_port": 19050,
  "version": "5"
}
```

Proxy-all style mode, where `perAppProxyMode != include`:

```text
Proxied app TCP -> tun-in -> generated route rule -> tor-out
tor-out -> 127.0.0.1:19050 -> native Tor -> Tor network -> target
```

Per-app include mode with apps marked `Use Tor`:

```text
Selected Tor app TCP -> tun-in -> generated package/source rule -> tor-out
tor-out -> 127.0.0.1:19050 -> native Tor -> Tor network -> target
```

Per-app include mode where an app is not marked `Use Tor`:

```text
App TCP -> original Hiddify route rules -> selected proxy/direct behavior
```

### UDP Behavior

Tor does not carry ordinary UDP. Current generated rules:

```text
DNS UDP/TCP port 53 -> hijack-dns
other matched UDP -> reject
matched TCP -> tor-out
```

Proxy-all style mode:

```text
All tun-in UDP except DNS -> reject
```

Per-app include mode:

```text
Only matched Tor app UDP except DNS -> reject
```

## DNS Path

`TorConfigTransformer` only runs DNS handling when the original config has a `dns` object. If `dns.servers` or `dns.rules` is missing, it is initialized as an empty list.

### dns-tor Server Generation

Generation logic:

```text
1. Select a remote DNS server from the original DNS servers.
2. Preferred tags:
   - dns-remote-fallback
   - dns-remote
   - dns.final
3. Prefer servers whose type is https/tls/quic.
4. If no encrypted DNS server is found, fall back to any server with the preferred tags.
5. Clone that server, change tag to dns-tor, and add detour: tor-out.
```

Target structure:

```json
{
  "tag": "dns-tor",
  "...": "copied from remote dns server",
  "detour": "tor-out"
}
```

### DNS Route Rules

When Tor traffic is enabled, TUN DNS hijack rules are inserted:

```json
{
  "inbound": ["tun-in"],
  "network": "udp",
  "port": 53,
  "action": "hijack-dns"
}
```

```json
{
  "inbound": ["tun-in"],
  "network": "tcp",
  "port": 53,
  "action": "hijack-dns"
}
```

### DNS Request Path

Hijacked DNS requests enter the sing-box DNS module and hit the generated DNS rule:

```json
{
  "server": "dns-tor"
}
```

Actual path:

```text
App DNS query -> Android VPN/TUN -> sing-box hijack-dns
sing-box DNS -> dns-tor -> detour tor-out
tor-out -> 127.0.0.1:19050 -> native Tor -> Tor network -> remote DNS server
```

Current limitations:

- The `dns-tor` rule does not include a `package_name` condition.
- In per-app include mode, if at least one app is marked `Use Tor`, the generated DNS rule is still a broad priority rule.
- Therefore, proxied apps not marked `Use Tor` may still resolve domains through the Tor DNS path, while their TCP follows the original route through the ordinary proxy path.
- If the original config has no DNS server that can be cloned, `dns-tor` is not generated. In that case Tor DNS is unavailable and the UI/logs must expose it as a configuration issue.

## Per-App Proxy Behavior

There are two internal chains:

```text
Proxy chain:
app -> tun-in -> original Hiddify route -> selected proxy/direct -> target

Tor chain:
app -> tun-in -> tor-out -> native Tor SOCKS -> Tor network -> target
```

Proxy-all style mode:

```text
Tor disabled:
proxied apps -> Proxy chain

Tor enabled:
proxied TCP -> Tor chain
proxied UDP except DNS -> reject
DNS -> dns-tor when DNS server generation succeeds
```

Per-app include mode:

```text
App selected for proxy + Use Tor off:
TCP -> Proxy chain

App selected for proxy + Use Tor on:
TCP -> Tor chain
UDP except DNS -> reject

App not selected for proxy:
direct/system behavior according to existing per-app proxy mode
```

UI rules:

```text
mode != include:
do not show per-app Use Tor choice

mode == include + Tor disabled:
do not show per-app Use Tor choice

mode == include + Tor enabled + app not proxied:
do not show per-app Use Tor choice

mode == include + Tor enabled + app proxied:
show Use Tor FilterChip
```

Toggling `Use Tor` for an app currently updates `PkgFlag.torProxy` in the database, syncs active package preferences, and triggers reconnect when the Android service is running.

## TorProcessManager Design

Responsibilities:

```text
Generate torrc
Start/stop native Tor binary
Start/reuse IPtProxy transport when bridge mode requires it
Manage tor data directory and pt-state directory
Read Tor stdout logs
Parse Bootstrapped N% lines
Publish status through LiveData/EventChannel
```

Native assets:

```text
Tor binary: <nativeLibraryDir>/libtor.so
IPtProxy transport jar: assets/iptproxy/classes.jar copied into codeCacheDir/iptproxy/classes.jar
Transport native libs loaded via DexClassLoader nativeLibraryDir
```

Key `torrc` fields:

```text
SocksPort 127.0.0.1:19050
ControlPort 127.0.0.1:19051
DNSPort 127.0.0.1:19053
CookieAuthentication 1
DataDirectory <app files>/tor/data
ClientOnly 1
AvoidDiskWrites 1
Log notice stdout
```

Direct or transport-free modes:

```text
Socks5Proxy 127.0.0.1:<mixed-port>
```

Bridge modes:

```text
UseBridges 1
ClientTransportPlugin <transport-name> socks5 <local-transport-address>
Bridge <bridge-line>
```

Transport mode mapping:

```text
obfs4 -> IPtProxy Obfs4 -> Tor transport name obfs4 -> uses upstream proxy
snowflake -> IPtProxy Snowflake -> Tor transport name snowflake -> uses upstream proxy
meek -> IPtProxy MeekLite -> Tor transport name meek_lite -> uses upstream proxy
direct -> no transport
```

Pre-start checks:

```text
1. 127.0.0.1:<mixed-port> must be reachable
2. libtor.so must exist
3. required transport must return a non-empty localAddress
```

Lifecycle requirements:

```text
1. Stop any existing IPtProxy runtime before a new Tor start.
2. Stop the active IPtProxy runtime when Tor is stopped.
3. Do not reuse stale transport local addresses across bridge-mode changes.
```

## Routing Invariants

Must be preserved:

```text
Hiddify core control traffic must not go through Tor.
Proxy-node connection traffic must not go through Tor.
Proxy latency tests must not go through Tor.
Tor bootstrap traffic should go through the selected Hiddify proxy path.
Tor-enabled app TCP traffic goes through native Tor.
Tor-enabled app non-DNS UDP is rejected.
DNS for Tor-enabled traffic should go through dns-tor -> tor-out.
```

Current behavior requiring explicit validation:

```text
Snowflake transport uses the Hiddify mixed port as upstream SOCKS.
per-app include mode currently uses a broad dns-tor DNS rule, not package-scoped DNS.
```

## Error Handling

Tor errors are shown only in the Tor card or Tor logs.

Examples:

```text
Tor upstream SOCKS 127.0.0.1:<mixed-port> is not ready
Tor binary not found
Transport native library failed
<transport> transport did not provide a local address
Tor process exited
Tor log reader failed
Tor [err] log line
Bridge line did not parse
```

Proxy errors remain in the existing proxy/core UI.

Examples:

```text
Selected proxy timeout
Selector unavailable
Node connection failed
VPN permission denied
```

## Acceptance Criteria

1. When Tor is disabled, Hiddify behavior is unchanged.
2. When Tor is enabled, core first starts normally, then the raw config is rewritten and core restarts with `enableRawConfig=true`.
3. After Tor is enabled, generated config contains a `tor-out` SOCKS outbound on `127.0.0.1:19050`.
4. Tor upstream uses `ConfigOptions.mixedPort`, defaulting to `127.0.0.1:12334`, and no longer depends on fixed `19052`.
5. Direct, obfs4, Snowflake, and meek Tor bootstrap upstream traffic goes through the current Hiddify mixed port.
6. When Tor is stuck at 2%, main status can still remain connected.
7. When Tor is stuck or failed, proxy latency is not replaced with Tor timeout.
8. Proxy page node tests test proxy nodes, not the Tor path.
9. After Tor is connected, GeoIP fallback detection runs through Tor SOCKS and displays exit country/city.
10. Tor GeoIP fallback uses `ipwho.is`, `api.ip.sb`, `ipapi.co`, and `ipinfo.io` in order. A single provider failure must not immediately fail the whole detection.
11. Tor path latency is measured from the Tor GeoIP request path. Failure shows unavailable and does not affect ordinary proxy latency.
12. After switching the selected proxy node, the Hiddify route behind the mixed port should update, and Tor bootstrap upstream should follow the new proxy selection.
13. When custom bridges are enabled and non-empty, they take priority over built-in bridges.
14. Custom bridge parsing accepts CRLF, LF, and CR-only multiline input, and writes one `Bridge` line per bridge in `torrc`.
15. In proxy-all style mode, matched TCP traffic uses `tor-out` when Tor is enabled, while non-DNS UDP is rejected.
16. In per-app include mode, only apps marked `Use Tor` send TCP traffic through `tor-out`.
17. In per-app include mode, if any app is marked `Use Tor`, current DNS rules prioritize `dns-tor`. This behavior must be recorded in testing; finer-grained DNS split can be designed later if required.

## Open Questions

1. Does per-app include mode need package-scoped DNS rules so non-Tor apps do not resolve through Tor?
2. Should Tor retry be independent from a full reconnect?
3. Should Tor GeoIP requests use dedicated timeout and retry settings, or reuse the existing `ProxyRepository` HTTP client defaults?
4. Should bridge lines be validated before connection starts, with a specific error pointing to the invalid line?
5. If `dns-tor` generation fails, should the UI block startup or allow startup with a DNS configuration error?
