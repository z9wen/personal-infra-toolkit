#!/usr/bin/env bash

set -euo pipefail

testDirectory=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${testDirectory}/../src/14_relay.sh"

temporaryDirectory=$(mktemp -d /tmp/xray-relay-selectors-test.XXXXXX)
trap 'rm -rf "${temporaryDirectory}"' EXIT

configPath="${temporaryDirectory}/"
relayStateFile="${temporaryDirectory}/relay_config.json"

echoContent() {
    :
}

jq -n '
{
    version:2,
    profiles:[
        {
            id:"oracle",
            name:"oracle",
            source:"manual",
            inboundTags:["VLESSTCP"],
            users:[],
            outboundTag:"relay_profile_oracle",
            outboundFile:"relay_oracle_outbound.json",
            tcp:{mode:"relay",protocol:"hysteria2",label:"Hysteria2 + TLS + QUIC",address:"oracle.example.com",port:"8443",bbrProfile:"standard"},
            udp:{mode:"shared",protocol:"hysteria2",label:"Hysteria2 + TLS + QUIC",address:"oracle.example.com",port:"8443",bbrProfile:"standard"}
        },
        {
            id:"us",
            name:"us",
            source:"subscription",
            inboundTags:["Hysteria2"],
            users:[],
            outboundTag:"relay_profile_us",
            outboundFile:"relay_us_outbound.json",
            subscription:{format:"sing-box-json",url:"https://example.com/subscription.json",selectedTag:"us-home"},
            tcp:{mode:"relay",protocol:"shadowsocks",label:"Shadowsocks (aes-256-gcm)",address:"us-home.example.com",port:"39488",bbrProfile:""},
            udp:{mode:"shared",protocol:"shadowsocks",label:"Shadowsocks (aes-256-gcm)",address:"us-home.example.com",port:"39488",bbrProfile:""}
        }
    ]
}' >"${relayStateFile}"

jq -n '
{
    routing:{
        domainStrategy:"AsIs",
        rules:[
            {type:"field",domain:["geosite:private"],outboundTag:"direct"}
        ]
    }
}' >"${configPath}09_routing.json"

jq -n '{inbounds:[{tag:"VLESSTCP",protocol:"vless",settings:{clients:[
    {id:"ac5e3498-cf56-4e2a-896e-c689221474b6",email:"cn2-VLESS_TCP/TLS_Vision"},
    {id:"1e5cd8b5-d68c-4ff6-84fd-65c31417a84b",email:"vision_us2us-home-VLESS_TCP/TLS_Vision"}
]}}]}' >"${configPath}02_VLESS_TCP_inbounds.json"

jq -n '{inbounds:[{tag:"Hysteria2",protocol:"hysteria",settings:{version:2,clients:[
    {auth:"ac5e3498-cf56-4e2a-896e-c689221474b6",email:"cn2-Hysteria2"}
]},streamSettings:{network:"hysteria",security:"tls"}}]}' >"${configPath}05_hysteria2_inbounds.json"

# 同一 Vision 入站的 UUID 必须分开列出，并可与 Hysteria2 auth 一次多选。
buildRelayTargetChoices
jq -e '
    length == 5 and
    .[1].selector.users == ["cn2-VLESS_TCP/TLS_Vision"] and
    .[2].selector.users == ["vision_us2us-home-VLESS_TCP/TLS_Vision"] and
    .[4].selector.users == ["cn2-Hysteria2"]
' <<<"${relayTargetChoices}" >/dev/null
selectRelayTargets <<<"3,5" >/dev/null
jq -e '
    . == [
        {inboundTags:["VLESSTCP"],users:["vision_us2us-home-VLESS_TCP/TLS_Vision"]},
        {inboundTags:["Hysteria2"],users:["cn2-Hysteria2"]}
    ]
' <<<"${relaySelectedSelectors}" >/dev/null

ensureRelayStateV2

jq -e '
    (.profiles | length) == 2 and
    all(.profiles[]; (.selectors | length) == 1) and
    all(.profiles[]; has("inboundTags") | not) and
    all(.profiles[]; has("users") | not)
' "${relayStateFile}" >/dev/null

visionToUsSelector='{"inboundTags":["VLESSTCP"],"users":["vision_jp2us-VLESS_TCP/TLS_Vision"]}'

# 多个 selector 应原子地追加到同一上游。
multiSelectors='[{"inboundTags":["VLESSTCP"],"users":["vision_jp2us-VLESS_TCP/TLS_Vision"]},{"inboundTags":["Hysteria2"],"users":["cn2-Hysteria2"]}]'
multiState=$(buildRelayStateWithSelectors "us" "${multiSelectors}")
jq -e '
    (first(.profiles[] | select(.id == "us")).selectors | any(.users == ["vision_jp2us-VLESS_TCP/TLS_Vision"])) and
    (first(.profiles[] | select(.id == "us")).selectors | any(.users == ["cn2-Hysteria2"]))
' <<<"${multiState}" >/dev/null

# 新增规则时可以直接选择已经配置好的 us 上游。
selectRelayDestination <<<"2" >/dev/null
[[ "${relayUseExistingProfile}" == "true" ]]
[[ "${relaySelectedDestinationId}" == "us" ]]

# oracle 的整个 Vision 入站是兜底，不应阻止更精确的账号规则绑定到 us。
relayTargetsAvailable "${visionToUsSelector}" "us" </dev/null

updatedState=$(buildRelayStateWithSelector "us" "${visionToUsSelector}")
writeRelayState "${updatedState}"

jq -e '
    (.profiles | length) == 2 and
    (first(.profiles[] | select(.id == "oracle")).selectors ==
        [{inboundTags:["VLESSTCP"],users:[]}]) and
    (first(.profiles[] | select(.id == "us")).selectors ==
        [
            {inboundTags:["Hysteria2"],users:[]},
            {inboundTags:["VLESSTCP"],users:["vision_jp2us-VLESS_TCP/TLS_Vision"]}
        ]) and
    (first(.profiles[] | select(.id == "us")).subscription.selectedTag == "us-home")
' "${relayStateFile}" >/dev/null

showRelayConfig >/dev/null
rebuildRelayRouting

# 精确账号规则必须排在 oracle 的整个 Vision 入站规则之前。
jq -e '
    .routing.rules[0] == {
        type:"field",
        inboundTag:["VLESSTCP"],
        network:"tcp",
        outboundTag:"relay_profile_us",
        user:["vision_jp2us-VLESS_TCP/TLS_Vision"]
    } and
    .routing.rules[1] == {
        type:"field",
        inboundTag:["VLESSTCP"],
        network:"udp",
        outboundTag:"relay_profile_us",
        user:["vision_jp2us-VLESS_TCP/TLS_Vision"]
    } and
    .routing.rules[2].inboundTag == ["VLESSTCP"] and
    .routing.rules[2].outboundTag == "relay_profile_oracle" and
    (.routing.rules[2] | has("user") | not) and
    .routing.rules[4].inboundTag == ["Hysteria2"] and
    .routing.rules[4].outboundTag == "relay_profile_us" and
    .routing.rules[6].outboundTag == "direct"
' "${configPath}09_routing.json" >/dev/null

# 把整个 Vision 入站改派给 us 时，应移除 oracle 以及多余的账号特例。
wholeVisionSelector='{"inboundTags":["VLESSTCP"],"users":[]}'
updatedState=$(buildRelayStateWithSelector "us" "${wholeVisionSelector}")
writeRelayState "${updatedState}"

jq -e '
    (.profiles | length) == 1 and
    .profiles[0].id == "us" and
    (.profiles[0].selectors | length) == 2 and
    (.profiles[0].selectors | any(.inboundTags == ["Hysteria2"] and .users == [])) and
    (.profiles[0].selectors | any(.inboundTags == ["VLESSTCP"] and .users == []))
' "${relayStateFile}" >/dev/null

echo "relay selector tests passed"
