package com.hiddify.hiddify.tor

data class TorConfig(
    val socksPort: Int,
    val controlPort: Int,
    val dnsPort: Int,
    val upstreamSocksPort: Int,
    val bridgeMode: String,
    val customBridges: List<String>,
)
