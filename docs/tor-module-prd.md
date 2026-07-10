# Tor Module PRD

## Background

Hiddify currently presents proxy connection state, proxy latency, and experimental Tor state in a way that can be confused when Tor is enabled. Tor must be treated as an independent module layered on top of the user's selected proxy path.

The key product rule is:

- Existing Hiddify proxy state and latency must continue to mean: local device -> currently selected proxy node -> target network.
- Tor state and Tor latency must mean: local device -> currently selected proxy node -> Tor -> target network.
- Tor failures must not change, override, or pollute the existing Hiddify proxy connection state or proxy latency.

## Goals

1. Add a Tor enable switch under General settings.
2. Add built-in Tor bridge mode selection: Direct, obfs4, Snowflake, meek.
3. Allow users to add known custom bridge lines.
4. Show Tor connection progress as a dedicated UI state, without using a progress bar.
5. After Tor connects, show Tor exit city and Tor path latency.
6. Preserve the existing proxy connection status and proxy latency semantics.
7. Use an Orbot-like architecture for Tor process, bridge, bootstrap, and status management.

## Non-Goals

1. Do not replace Hiddify's existing proxy selection UI.
2. Do not redefine existing proxy latency as Tor latency.
3. Do not make Tor required for normal Hiddify proxy usage.
4. Do not route Hiddify core control traffic or proxy-node connection traffic through Tor.

## User Settings

Location:

```text
Settings -> General -> Tor
```

Settings:

```text
Enable Tor: boolean
Tor bridge mode:
- Direct
- obfs4
- Snowflake
- meek

Custom bridges:
- Multi-line text input
- Supports pasting multiple bridge lines
- Supports enabling/disabling custom bridges
- Custom bridges take priority over built-in bridges
```

Validation:

- If Direct is selected, no bridge line is required.
- If obfs4, Snowflake, or meek requires transport assets or bridge parameters that are unavailable, show a configuration error before starting Tor.
- Invalid custom bridge lines should be reported without silently dropping all bridge configuration.

## Home UI

When Tor is disabled:

```text
Main connection status: existing Hiddify status
Proxy latency: existing Hiddify proxy latency
Tor card: disabled or hidden according to final design
```

When Tor is enabled:

```text
Main connection status: existing Hiddify core/proxy status
Proxy latency: local -> selected proxy -> target
Tor card: independent Tor status
```

Tor connection progress must be shown as phase text, not a progress bar.

Example states:

```text
Tor starting
Tor connecting transport
Tor building circuit
Tor connected
Tor failed
```

Tor card required elements:

```text
Tor icon
Tor connection phase
Tor bootstrap percentage while connecting
Tor path latency after connected
Tor exit city after connected
```

Example connecting card:

```text
Tor connecting
Bootstrap: 45%
conn_done_pt: Connected to pluggable transport
```

Example connected card:

```text
Tor connected
Exit: Tokyo, Japan
Latency: 820 ms
```

Tor latency means:

```text
local -> currently selected proxy node -> Tor -> target network
```

Proxy latency still means:

```text
local -> currently selected proxy node -> target network
```

## State Model

The product must keep these states separate.

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

Required UI behavior:

```text
Core connected + Tor connecting
=> main status: connected
=> proxy latency: proxy latency only
=> Tor card: Tor connecting

Core connected + Tor failed
=> main status: connected
=> proxy latency: proxy latency only
=> Tor card: Tor failed

Proxy timeout + Tor connected
=> main status: connected if core is connected
=> proxy latency: timeout
=> Tor card: Tor connected if Tor path works
```

Forbidden UI behavior:

```text
Tor failure -> main status becomes connecting
Tor timeout -> proxy latency becomes timeout
Tor bootstrap pending -> all proxy nodes show timeout
```

## Traffic Semantics

Normal proxy path:

```text
local -> selected proxy node -> target network
```

Tor upstream bootstrap path:

```text
Tor process -> local Tor upstream SOCKS -> selected proxy node -> Tor bridge
```

Tor-enabled application path:

```text
app traffic -> Hiddify VPN/core -> Tor SOCKS -> Tor network -> target network
```

Tor latency test path:

```text
local -> selected proxy node -> Tor -> target network
```

Proxy latency test path:

```text
local -> selected proxy node -> target network
```

## Per-App Proxy Behavior

Hiddify must support two internal outbound chains:

```text
Proxy chain:
local -> selected proxy node -> target network

Tor chain:
local -> selected proxy node -> Tor network -> target network
```

When per-app proxy mode is set to proxy all applications:

```text
Tor disabled:
all proxied apps -> Proxy chain

Tor enabled:
all proxied apps -> Tor chain
```

When per-app proxy mode is set to only proxy selected applications, the Tor routing option is available only after the user marks an application as proxied.

Per selected app:

```text
App enabled for proxy: boolean
Use Tor for this app: boolean
```

Routing rules:

```text
App enabled + Use Tor off:
app -> Proxy chain

App enabled + Use Tor on:
app -> Tor chain

App not enabled:
app -> direct/system behavior according to existing per-app proxy mode
```

UI rules:

```text
App not marked for proxy:
do not show or enable the Use Tor option

App marked for proxy + Tor disabled globally:
show Use Tor as disabled/inactive, or hide it according to final UI design

App marked for proxy + Tor enabled globally:
allow the user to choose whether this app uses the Tor chain
```

If Tor is disabled globally, the per-app "Use Tor" option should be disabled or visually inactive, and selected apps should use the Proxy chain.

If Tor is enabled but not connected:

```text
Apps with Use Tor on -> wait/fail according to Tor chain state
Apps with Use Tor off -> continue using Proxy chain
```

This means one application's Tor failure must not break another application's normal proxy route.

## Technical Design

Follow an Orbot-like model:

```text
TorProcessManager
- Generate torrc
- Start Tor
- Stop Tor
- Manage Tor data directory
- Manage bridge transport assets
- Read bootstrap logs/control status
- Publish TorStatus events
```

Suggested local ports:

```text
Tor SOCKS: 127.0.0.1:19050
Tor Control: 127.0.0.1:19051
Tor upstream SOCKS: 127.0.0.1:19052
```

The Tor upstream SOCKS must route through the currently selected Hiddify proxy node or proxy group. It must not route through Tor.

Required routing invariants:

```text
Hiddify core control traffic must not go through Tor.
Proxy-node connection traffic must not go through Tor.
Proxy latency tests must not go through Tor.
Tor bootstrap traffic must go through the selected proxy node.
Tor-enabled app traffic may go through Tor.
```

## Bridge Modes

Direct:

```text
Use Tor without bridges.
```

obfs4:

```text
Use bundled obfs4 transport and built-in/custom obfs4 bridge lines.
```

Snowflake:

```text
Use bundled Snowflake client transport.
```

meek:

```text
Use bundled meek transport and built-in/custom meek configuration.
```

Custom bridge priority:

```text
custom bridges enabled -> use custom bridges first
custom bridges disabled or empty -> use built-in bridges for selected mode
```

## Error Handling

Tor errors must be shown in the Tor card only.

Examples:

```text
Bridge connection failed
Transport binary missing
Tor bootstrap timeout
Tor process exited
Control port unavailable
```

Proxy errors must remain in the proxy UI.

Examples:

```text
Selected proxy timeout
Selector unavailable
Node connection failed
```

## Acceptance Criteria

1. With Tor disabled, Hiddify behaves exactly as before.
2. Enabling Tor adds a separate Tor status UI.
3. When Tor is stuck at 2%, the main status can still show connected if Hiddify core is connected.
4. When Tor is stuck at 2%, proxy latency must not be replaced by Tor timeout.
5. Proxy page node tests must test proxy nodes, not the Tor path.
6. Tor connected state shows exit city and Tor path latency.
7. Switching the selected proxy node changes the Tor upstream path.
8. Custom bridges override built-in bridges when enabled.
9. Tor can be retried independently without forcing a full proxy reconnect.
10. Logs clearly distinguish proxy URL tests from Tor URL tests.
11. In proxy-all-apps mode, enabling Tor routes proxied app traffic through the Tor chain; disabling Tor routes proxied app traffic through the Proxy chain.
12. In proxy-selected-apps mode, each selected app has a "Use Tor" option, and Tor failure only affects apps with "Use Tor" enabled.

## Open Questions

1. Should the Tor card be hidden or shown as disabled when Tor is off?
2. Should Tor retry automatically after bootstrap failure?
3. Should users be able to choose a separate proxy node for Tor upstream, or must it always follow the current selected proxy?
4. Should Tor latency target use the same URL as proxy latency or a dedicated Tor-safe endpoint?
5. How should custom bridge validation report partially invalid bridge lists?
