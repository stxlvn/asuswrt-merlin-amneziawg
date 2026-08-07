#!/bin/sh
# =============================================================
# AmneziaWG addon backend for Asuswrt-Merlin
# Userspace amneziawg-go, per-device policy routing, GeoIP/GeoSite
# =============================================================

AWG_VERSION="1.4.9"
ADDON_DIR="/jffs/addons/amneziawg"
AWG_DIR="/opt/amneziawg"
CONF="$AWG_DIR/awg0.conf"
AWG_GO="$AWG_DIR/amneziawg-go"
AWG_BIN="$AWG_DIR/awg"
IFACE="awg0"
STATUS_FILE="/www/user/awg_status.htm"
SETTINGS="/jffs/addons/custom_settings.txt"
CLIENTS_FILE="$AWG_DIR/clients.list"
GEO_DIR="$AWG_DIR/geo"
IPSET_NAME="awg_dst"
FWMARK="0x100"
DNSMASQ_AWG_CONF="$AWG_DIR/dnsmasq_awg.conf"
DNSMASQ_INCLUDE="/jffs/configs/dnsmasq.conf.add"
DNSMASQ_ACTIVE_CONF="/tmp/etc/dnsmasq.conf"
SCRIPT_NAME="amneziawg"
RT_TABLE=300
AWG_CHAIN="AWG"
LOCKDIR="/tmp/.awg_lock"
ALLOWDOMAINS_BASE="https://raw.githubusercontent.com/itdoginfo/allow-domains/main"
GEOIP_SERVICES="cloudflare cloudfront digitalocean discord google_meet hetzner meta ovh roblox telegram twitter"
GEOSITE_SERVICES="cloudflare cloudfront digitalocean discord google_ai google_meet google_play hdrezka hetzner meta ovh roblox telegram tiktok twitter youtube anime block geoblock hodca news porn ru_inside ru_outside ua_inside"

# Ensure Entware binaries are in PATH (not set when called from httpd/service-event).
export PATH="/opt/bin:/opt/sbin:$PATH"

# ipset needs its Entware-side libipset (v1.4.6 background: PATH alone finds
# the right /opt/sbin/ipset binary, but the dynamic linker resolves *shared
# library* deps via LD_LIBRARY_PATH, not PATH -- without it, ipset silently
# links against the OLDER firmware libipset.so.13 in /usr/lib and fails with
# a version-symbol mismatch). v1.4.6 exported LD_LIBRARY_PATH globally for
# the whole script to fix that, but that broke *other* Entware binaries that
# were relying on the normal (non-overridden) library resolution -- notably
# grep-gnu, which segfaults with /opt/lib forced ahead of its expected
# libraries. Scope the override to just the one binary that actually needs
# it instead of applying it to every subprocess this script runs.
run_ipset(){
    LD_LIBRARY_PATH="/opt/lib:$LD_LIBRARY_PATH" ipset "$@"
}

# --- Helpers ---

log_msg(){
    logger -t "$SCRIPT_NAME" "$1"
}

get_setting(){
    awk -v key="$1" '$1==key{sub(/^[^ ]+ /,"");print;exit}' "$SETTINGS" 2>/dev/null
}

is_running(){
    ip link show "$IFACE" >/dev/null 2>&1
}

get_lan_net(){
    ip -4 route show dev br0 2>/dev/null | awk '$1 ~ /^[0-9]/ && $1 ~ /\// {print $1; exit}'
}

get_router_ip(){
    ip -4 addr show br0 2>/dev/null | awk '/inet /{sub(/\/.*/, "", $2); print $2; exit}'
}

get_endpoint(){
    awk -F'[ =:]+' '/^Endpoint/{print $2}' "$CONF" 2>/dev/null
}

flush_conntrack(){
    if command -v conntrack >/dev/null 2>&1 && conntrack -D --mark "$FWMARK"/"$FWMARK" 2>/dev/null; then
        return 0
    fi
    conntrack -F 2>/dev/null
}

save_and_set_rp_filter(){
    for iface in all awg0 br0; do
        local f="/proc/sys/net/ipv4/conf/$iface/rp_filter"
        [ -f "$f" ] && cat "$f" > "/tmp/.awg_rp_$iface" 2>/dev/null
        echo 2 > "$f" 2>/dev/null
    done
}

restore_rp_filter(){
    for iface in all awg0 br0; do
        local saved="/tmp/.awg_rp_$iface"
        local f="/proc/sys/net/ipv4/conf/$iface/rp_filter"
        if [ -f "$saved" ]; then
            cat "$saved" > "$f" 2>/dev/null
            rm -f "$saved"
        fi
    done
}

# Wait for process to exit. Usage: wait_for_pid_exit <name> <timeout>
wait_for_pid_exit(){
    local pname="$1" max="${2:-10}" i=0
    while [ $i -lt $max ]; do
        pidof "$pname" >/dev/null 2>&1 || return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# Wait for DNS resolver. Usage: wait_for_dns <timeout>
wait_for_dns(){
    local max="${1:-10}" i=0
    while [ $i -lt $max ]; do
        nslookup localhost 127.0.0.1 >/dev/null 2>&1 && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# Wait for network interface IP. Usage: wait_for_iface_ip <iface> <timeout>
wait_for_iface_ip(){
    local iface="$1" max="${2:-10}" i=0
    while [ $i -lt $max ]; do
        ip -4 addr show "$iface" 2>/dev/null | grep -q "inet " && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# Wait for interface to appear. Usage: wait_for_iface <iface> <timeout>
wait_for_iface(){
    local iface="$1" max="${2:-10}" i=0
    while [ $i -lt $max ]; do
        ip link show "$iface" >/dev/null 2>&1 && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

acquire_lock(){
    local tries=0
    while ! mkdir "$LOCKDIR" 2>/dev/null; do
        if [ -f "$LOCKDIR/pid" ]; then
            local old_pid
            old_pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
            if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
                rm -rf "$LOCKDIR"
                continue
            fi
        fi
        tries=$((tries + 1))
        [ $tries -ge 30 ] && { log_msg "ERROR: lock timeout"; return 1; }
        sleep 1
    done
    echo $$ > "$LOCKDIR/pid"
}

release_lock(){
    rm -rf "$LOCKDIR"
}

human_size(){
    local bytes=${1:-0}
    if [ "$bytes" -ge 1073741824 ] 2>/dev/null; then
        echo "$bytes" | awk '{printf "%.1f GiB", $1/1073741824}'
    elif [ "$bytes" -ge 1048576 ] 2>/dev/null; then
        echo "$bytes" | awk '{printf "%.1f MiB", $1/1048576}'
    elif [ "$bytes" -ge 1024 ] 2>/dev/null; then
        echo "$bytes" | awk '{printf "%.1f KiB", $1/1024}'
    else
        echo "${bytes} B"
    fi
}

# Download a single GeoIP service subnet list (IPv4 only)
# Source: github.com/itdoginfo/allow-domains (Subnets/IPv4/<svc>.lst)
download_geoip_service(){
    local svc="$1"
    svc=$(echo "$svc" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    [ -z "$svc" ] && return 1
    local tmp="$GEO_DIR/geoip/.dl_${svc}.tmp"
    local attempt=0 http_code rc
    while [ $attempt -lt 5 ]; do
        attempt=$((attempt + 1))
        http_code=$(curl -s -o "$tmp" -w '%{http_code}' -A "amneziawg-merlin/$AWG_VERSION" \
            --connect-timeout 10 --max-time 30 -L "${ALLOWDOMAINS_BASE}/Subnets/IPv4/${svc}.lst" 2>/dev/null)
        rc=$?
        if [ "$rc" -eq 0 ] && [ "$http_code" = "200" ] && [ -s "$tmp" ]; then
            grep -v ":" "$tmp" > "$GEO_DIR/geoip/${svc}.cidr"
            rm -f "$tmp"
            [ -s "$GEO_DIR/geoip/${svc}.cidr" ] || { rm -f "$GEO_DIR/geoip/${svc}.cidr"; return 1; }
            return 0
        fi
        log_msg "GeoIP $svc attempt $attempt: curl_rc=$rc http_code=${http_code:-none}"
        # A single standalone request for a file that just failed here has
        # always succeeded on retest, with genuine GitHub/Fastly headers --
        # and the failing items aren't consistently first, last, or any
        # particular file across runs. This isn't a cache-warming or
        # rate-limit pattern (fixed/longer delays didn't help) -- it looks
        # like anycast routing occasionally sending a fresh TCP connection
        # to an edge with a stale/missing cache entry for this specific
        # (moderately unpopular) repo. Each new curl process is a fresh
        # connection with its own routing roll, so more independent
        # attempts matters more here than a longer wait between them.
        [ $attempt -lt 5 ] && sleep 2
    done
    rm -f "$tmp"
    return 1
}

# Map a GeoSite list name to its path under itdoginfo/allow-domains. Most
# names are per-service domain lists (Services/<svc>.lst); a few are curated
# domain categories or country bundles that live under their own top-level
# directories but share the same one-domain-per-line RAW format.
geosite_list_path(){
    case "$1" in
        anime|block|geoblock|hodca|news|porn) echo "Categories/$1.lst" ;;
        ru_inside)  echo "Russia/inside-raw.lst" ;;
        ru_outside) echo "Russia/outside-raw.lst" ;;
        ua_inside)  echo "Ukraine/inside-raw.lst" ;;
        *) echo "Services/$1.lst" ;;
    esac
}

# Download a single GeoSite list into the cache.
# Source: github.com/itdoginfo/allow-domains (see geosite_list_path for layout)
download_geosite_service(){
    local svc="$1"
    svc=$(echo "$svc" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
    [ -z "$svc" ] && return 1
    mkdir -p "$GEO_DIR/services"
    local list_path
    list_path=$(geosite_list_path "$svc")
    local tmp="$GEO_DIR/services/.dl_${svc}.tmp"
    local attempt=0 http_code rc
    while [ $attempt -lt 5 ]; do
        attempt=$((attempt + 1))
        http_code=$(curl -s -o "$tmp" -w '%{http_code}' -A "amneziawg-merlin/$AWG_VERSION" \
            --connect-timeout 10 --max-time 30 -L "${ALLOWDOMAINS_BASE}/${list_path}" 2>/dev/null)
        rc=$?
        if [ "$rc" -eq 0 ] && [ "$http_code" = "200" ] && [ -s "$tmp" ]; then
            mv "$tmp" "$GEO_DIR/services/${svc}.txt"
            return 0
        fi
        log_msg "GeoSite $svc attempt $attempt: curl_rc=$rc http_code=${http_code:-none}"
        # See matching comment in download_geoip_service: failures aren't
        # tied to a particular file or position in the batch, and a
        # standalone retest always succeeds -- more independent attempts
        # matters more here than a longer wait between them.
        [ $attempt -lt 5 ] && sleep 2
    done
    rm -f "$tmp"
    return 1
}

# Download all geo databases (called at install and update)
download_all_geo(){
    # Guard against overlapping runs: the web UI's "Update Now" used to
    # reload on a fixed 60s timer with no visual feedback, so a user could
    # click it again mid-download thinking the first click didn't register
    # -- each run then independently reapplies the firewall on completion,
    # which looks like AmneziaWG spontaneously restarting even though the
    # tunnel interface/daemon itself is never touched. v1.4.4 disables the
    # button and polls for real completion instead, but guard here too in
    # case of a resubmitted form or a second tab.
    local geo_lock="/tmp/.awg_geo_update_running"
    if [ -f "$geo_lock" ]; then
        local lock_pid
        lock_pid=$(cat "$geo_lock" 2>/dev/null)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
            log_msg "Geo update already in progress (pid $lock_pid), skipping duplicate run"
            return 1
        fi
    fi
    echo $$ > "$geo_lock"
    trap 'rm -f "$geo_lock"' EXIT

    mkdir -p "$GEO_DIR/geoip" "$GEO_DIR/domains"
    log_msg "Downloading all geo databases..."

    # Download all GeoIP service CIDR lists
    local count=0 total=0 ok=0
    for svc in $GEOIP_SERVICES; do
        total=$((total + 1))
    done
    for svc in $GEOIP_SERVICES; do
        count=$((count + 1))
        log_msg "GeoIP: downloading $svc ($count/$total)..."
        if download_geoip_service "$svc"; then
            ok=$((ok + 1))
        else
            log_msg "WARNING: GeoIP $svc failed"
        fi
        update_status
        # Pace requests to raw.githubusercontent.com. A single standalone
        # curl to a "failed" file always succeeds -- the file is fine, and
        # it's not a block -- so this isn't a per-file problem. It only
        # shows up as an occasional real 404 inside this tight back-to-back
        # loop across ~36 files, which looks like Fastly's anycast routing
        # being inconsistent under rapid repeated requests to the same host.
        sleep 2
    done
    log_msg "GeoIP: $ok/$total service lists downloaded"

    # Download all GeoSite service domain lists (cached individually)
    log_msg "Downloading domain lists (allow-domains)..."
    update_status
    local gs_count=0 gs_total=0 gs_ok=0
    for svc in $GEOSITE_SERVICES; do
        gs_total=$((gs_total + 1))
    done
    for svc in $GEOSITE_SERVICES; do
        gs_count=$((gs_count + 1))
        log_msg "GeoSite: downloading $svc ($gs_count/$gs_total)..."
        if download_geosite_service "$svc"; then
            gs_ok=$((gs_ok + 1))
        else
            log_msg "WARNING: GeoSite $svc failed"
        fi
        update_status
        sleep 2
    done
    echo "$GEOSITE_SERVICES" | tr ' ' '\n' | sort > "$GEO_DIR/domain_categories.txt"
    cp "$GEO_DIR/domain_categories.txt" /www/user/domain_categories.htm 2>/dev/null
    log_msg "GeoSite: $gs_ok/$gs_total service lists downloaded"

    # Save timestamp
    date +%s > "$GEO_DIR/.last_update"
    update_status
    log_msg "Geo databases updated"
}

# Mount AmneziaWG tab into Merlin menu
mount_menu_tree(){
    local page="$1"
    # Unmount first so the copy below always comes from the real underlying
    # file, not a stale /tmp/menuTree.js left over from a previous session
    # (/tmp survives across addon updates, only cleared on reboot) or
    # whatever another addon's own bind mount currently has in place. Across
    # many install/uninstall/update cycles, sed-patching on top of an
    # already-patched copy can silently corrupt or drop the anchor line
    # below, at which point the insert just does nothing -- no error, the
    # tab just quietly stops appearing.
    umount /www/require/modules/menuTree.js 2>/dev/null
    cp /www/require/modules/menuTree.js /tmp/menuTree.js
    sed -i '/AmneziaWG/d' /tmp/menuTree.js
    if grep -q 'url: "Advanced_VPN_OpenVPN.asp"' /tmp/menuTree.js; then
        sed -i "/url: \"Advanced_VPN_OpenVPN.asp\"/a {url: \"$page\", tabName: \"AmneziaWG\"}," /tmp/menuTree.js
    else
        log_msg "WARNING: menuTree.js anchor not found, AmneziaWG menu tab may not appear"
    fi
    mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js
}

# Bulk-load CIDR file into ipset using restore (much faster than individual adds)
ipset_load_file(){
    local file="$1"
    local setname="$2"
    [ ! -f "$file" ] && return
    awk -v s="$setname" '
        /^[0-9]/ && !/^#/ {
            gsub(/[[:space:]\r]/, "")
            if ($0 != "") print "add " s " " $0 " timeout 0"
        }
    ' "$file" | run_ipset restore -! 2>/dev/null
}

# --- Unified firewall setup ---

setup_dns_interception(){
    local router_ip
    router_ip=$(get_router_ip)
    [ -z "$router_ip" ] && router_ip="192.168.1.1"
    iptables -w 5 -t nat -I PREROUTING -i br0 -p udp --dport 53 -j DNAT --to "$router_ip"
    iptables -w 5 -t nat -I PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to "$router_ip"
    iptables -w 5 -I FORWARD -i br0 -p tcp --dport 853 -j REJECT
    local doh_ip
    for doh_ip in 8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 9.9.9.9 149.112.112.112; do
        iptables -w 5 -I FORWARD -i br0 -d "$doh_ip" -p tcp --dport 443 -j REJECT
        iptables -w 5 -I FORWARD -i br0 -d "$doh_ip" -p udp --dport 443 -j REJECT
    done
    log_msg "DNS interception enabled"
}

setup_ipv6_block(){
    local ipv6_svc
    ipv6_svc=$(nvram get ipv6_service 2>/dev/null)
    [ "$ipv6_svc" = "disabled" ] || [ -z "$ipv6_svc" ] && return 0
    ip6tables -w 5 -I FORWARD -i br0 -o "$IFACE" -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null
    ip6tables -w 5 -I FORWARD -i "$IFACE" -o br0 -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null
    log_msg "IPv6 leak protection enabled"
}

cleanup_ipv6_block(){
    ip6tables -w 5 -D FORWARD -i br0 -o "$IFACE" -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null
    ip6tables -w 5 -D FORWARD -i "$IFACE" -o br0 -j REJECT --reject-with icmp6-adm-prohibited 2>/dev/null
}

# QUIC (HTTP/3, UDP/443) does its own MTU discovery independent of TCPMSS
# clamping (TCP-only). Through a WireGuard-family tunnel the effective path
# MTU is smaller than the LAN's 1500, and if the resulting ICMP
# "Fragmentation Needed" never makes it back to the client (common -- ICMP
# is dropped/filtered in plenty of places along the way), QUIC just
# blackholes: no error, packets silently dropped, video stalls/never loads.
# YouTube and other Google properties push QUIC hard, so this is the single
# most common "YouTube doesn't work over VPN" cause. Reject outbound UDP/443
# through the tunnel so the browser falls back to plain TCP/TLS instead of
# retrying into the blackhole.
setup_quic_block(){
    iptables -w 5 -I FORWARD -o "$IFACE" -p udp --dport 443 -j REJECT
    log_msg "QUIC (UDP/443) blocked over tunnel to force TCP fallback"
}

cleanup_quic_block(){
    iptables -w 5 -D FORWARD -o "$IFACE" -p udp --dport 443 -j REJECT 2>/dev/null
}

cleanup_firewall(){
    # Unhook from PREROUTING, flush and delete custom chain
    iptables -w 5 -t mangle -D PREROUTING -j "$AWG_CHAIN" 2>/dev/null
    iptables -w 5 -t mangle -F "$AWG_CHAIN" 2>/dev/null
    iptables -w 5 -t mangle -X "$AWG_CHAIN" 2>/dev/null

    # Remove all ip rules for our table/fwmark
    local _i=0; while [ $_i -lt 100 ] && ip rule del lookup $RT_TABLE 2>/dev/null; do _i=$((_i+1)); done
    _i=0; while [ $_i -lt 100 ] && ip rule del fwmark "$FWMARK" 2>/dev/null; do _i=$((_i+1)); done

    # Remove DNS interception rules
    local router_ip
    router_ip=$(get_router_ip)
    [ -z "$router_ip" ] && router_ip="192.168.1.1"
    iptables -w 5 -t nat -D PREROUTING -i br0 -p udp --dport 53 -j DNAT --to "$router_ip" 2>/dev/null
    iptables -w 5 -t nat -D PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to "$router_ip" 2>/dev/null
    iptables -w 5 -D FORWARD -i br0 -p tcp --dport 853 -j REJECT 2>/dev/null
    local doh_ip
    for doh_ip in 8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 9.9.9.9 149.112.112.112; do
        iptables -w 5 -D FORWARD -i br0 -d "$doh_ip" -p tcp --dport 443 -j REJECT 2>/dev/null
        iptables -w 5 -D FORWARD -i br0 -d "$doh_ip" -p udp --dport 443 -j REJECT 2>/dev/null
    done

    # Destroy ipset
    run_ipset flush "$IPSET_NAME" 2>/dev/null
    run_ipset destroy "$IPSET_NAME" 2>/dev/null

    # Remove dnsmasq config
    rm -f "$DNSMASQ_AWG_CONF"
    [ -f "$DNSMASQ_INCLUDE" ] && sed -i "\|${DNSMASQ_AWG_CONF}|d" "$DNSMASQ_INCLUDE"

    # Remove cron
    cru d awg_geo_update 2>/dev/null
    cru d awg_watchdog 2>/dev/null

    cleanup_ipv6_block
    cleanup_quic_block

    log_msg "Firewall rules cleaned"
}

# Pre-resolve domains from the generated dnsmasq config to populate the ipset
# immediately, instead of waiting for real client traffic to trigger it.
pre_resolve_domains(){
    [ -f "$DNSMASQ_AWG_CONF" ] || return 0
    log_msg "Pre-resolving domains to populate ipset..."
    local bg_count=0
    awk -F/ '/^ipset=/{for(i=2;i<NF;i++)print $i}' "$DNSMASQ_AWG_CONF" | while read -r domain; do
        [ -z "$domain" ] && continue
        nslookup "$domain" 127.0.0.1 >/dev/null 2>&1 &
        bg_count=$((bg_count + 1))
        [ $bg_count -ge 10 ] && { wait; bg_count=0; }
    done
    wait
    log_msg "Pre-resolution finished"
}

# Merlin's own services (opkg hooks, network/wan events, etc.) can trigger a
# concurrent "service restart_dnsmasq" via nvram rc_service; if ours lands in
# the middle of that it's silently dropped and our conf-file include never
# takes effect. Wait for rc_service to go idle, restart, then confirm our
# include actually made it into the active config before pre-resolving.
# Ported from advocdiaboly/asuswrt-merlin-amneziawg@8e95d3c (Dmitry Fomin).
restart_dnsmasq_when_idle(){
    local i=0
    while [ -n "$(nvram get rc_service 2>/dev/null)" ]; do
        [ $i -eq 0 ] && log_msg "Deferring dnsmasq restart until rc_service is idle..."
        [ $i -ge 30 ] && { log_msg "WARNING: rc_service stayed busy, restarting dnsmasq anyway"; break; }
        sleep 1
        i=$((i + 1))
    done

    service restart_dnsmasq >/dev/null 2>&1
    wait_for_dns 10

    i=0
    while [ $i -lt 10 ]; do
        grep -qF "conf-file=$DNSMASQ_AWG_CONF" "$DNSMASQ_ACTIVE_CONF" 2>/dev/null && break
        sleep 1
        i=$((i + 1))
    done
    if ! grep -qF "conf-file=$DNSMASQ_AWG_CONF" "$DNSMASQ_ACTIVE_CONF" 2>/dev/null; then
        log_msg "WARNING: dnsmasq restart did not apply AmneziaWG domain rules, retrying once"
        service restart_dnsmasq >/dev/null 2>&1
        wait_for_dns 10
    fi

    pre_resolve_domains
}

setup_firewall(){
    cleanup_firewall

    # Re-add right after cleanup_firewall (which just removed them) so every
    # caller of setup_firewall -- do_start, awgsaveconf, awgupdategeo,
    # firewall_restart -- gets these consistently, instead of relying on
    # each call site to remember to re-add them afterward.
    setup_ipv6_block
    setup_quic_block

    local default_policy=$(get_setting awg_default_policy)
    [ -z "$default_policy" ] && default_policy="direct"
    local has_geo=false

    # --- Create ipset ---
    local ipset_err
    ipset_err=$(run_ipset create "$IPSET_NAME" hash:net family inet hashsize 4096 maxelem 131072 timeout 86400 2>&1)
    if ! run_ipset list "$IPSET_NAME" >/dev/null 2>&1; then
        log_msg "ERROR: ipset $IPSET_NAME creation failed, geo routing disabled: ${ipset_err:-no output}"
        case "$ipset_err" in
            *LIBIPSET_*|*"version \`"*)
                log_msg "HINT: ipset/libipset version mismatch -- try: opkg install --force-reinstall ipset libipset"
                ;;
        esac
        has_geo=false
    fi

    # --- Load GeoIP subnets into ipset (bulk) ---
    local ip_count=0
    for f in "$GEO_DIR"/geoip/*.cidr; do
        [ ! -f "$f" ] && continue
        ipset_load_file "$f" "$IPSET_NAME"
        ip_count=$((ip_count + $(wc -l < "$f")))
    done

    # Check ipset fill level
    local ipset_entries
    ipset_entries=$(run_ipset list "$IPSET_NAME" -t 2>/dev/null | awk '/Number of entries/{print $NF}')
    [ -n "$ipset_entries" ] && [ "$ipset_entries" -ge 131072 ] 2>/dev/null && \
        log_msg "WARNING: ipset $IPSET_NAME full ($ipset_entries/131072), some geo routes may be missing"

    # --- Select GeoSite domain lists from the cache (allow-domains) ---
    local geosite_services=$(get_setting awg_geosite_services)
    if [ -n "$geosite_services" ]; then
        mkdir -p "$GEO_DIR/domains"
        rm -f "$GEO_DIR/domains/geosite_"*.txt
        for svc in $(echo "$geosite_services" | tr ',' ' '); do
            svc=$(echo "$svc" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
            [ -z "$svc" ] && continue
            if [ -f "$GEO_DIR/services/${svc}.txt" ]; then
                cp "$GEO_DIR/services/${svc}.txt" "$GEO_DIR/domains/geosite_${svc}.txt"
            else
                log_msg "WARNING: GeoSite list '$svc' not cached, click Update Now"
            fi
        done
    fi

    # --- Save custom domains/IPs ---
    local custom_domains=$(get_setting awg_geo_custom_domains)
    if [ -n "$custom_domains" ]; then
        mkdir -p "$GEO_DIR/domains"
        echo "$custom_domains" | tr ',' '\n' > "$GEO_DIR/domains/custom.txt"
    fi
    local custom_ips=$(get_setting awg_geo_custom_ips)
    if [ -n "$custom_ips" ]; then
        mkdir -p "$GEO_DIR/geoip"
        echo "$custom_ips" | tr ',' '\n' | while read -r cidr; do
            cidr=$(echo "$cidr" | tr -d ' \r')
            [ -n "$cidr" ] && run_ipset add "$IPSET_NAME" "$cidr" timeout 0 2>/dev/null
        done
    fi

    # --- Build dnsmasq config for domain-based routing ---
    local domain_count=0
    echo "# AmneziaWG domain routing - auto-generated" > "$DNSMASQ_AWG_CONF"
    for f in "$GEO_DIR"/domains/*.txt "$GEO_DIR"/domains/*.lst; do
        [ ! -f "$f" ] && continue
        local chunk_line="ipset=/"
        local chunk_count=0
        while read -r domain; do
            domain=$(echo "$domain" | tr -d ' \r')
            [ -z "$domain" ] && continue
            echo "$domain" | grep -q '^#' && continue
            domain=$(echo "$domain" | sed 's/^\.//;s/:@[^ ]*$//')
            echo "$domain" | grep -q '[^a-zA-Z0-9._-]' && continue
            chunk_line="${chunk_line}${domain}/"
            chunk_count=$((chunk_count + 1))
            domain_count=$((domain_count + 1))
            if [ $chunk_count -ge 20 ]; then
                echo "${chunk_line}${IPSET_NAME}" >> "$DNSMASQ_AWG_CONF"
                chunk_line="ipset=/"
                chunk_count=0
            fi
        done < "$f"
        [ $chunk_count -gt 0 ] && echo "${chunk_line}${IPSET_NAME}" >> "$DNSMASQ_AWG_CONF"
    done

    # Add conf-file include to dnsmasq (idempotent)
    if [ $domain_count -gt 0 ]; then
        if ! grep -qF "conf-file=$DNSMASQ_AWG_CONF" "$DNSMASQ_INCLUDE" 2>/dev/null; then
            echo "conf-file=$DNSMASQ_AWG_CONF" >> "$DNSMASQ_INCLUDE"
        fi
    fi

    # --- Create custom chain in mangle table ---
    iptables -w 5 -t mangle -N "$AWG_CHAIN" 2>/dev/null || iptables -w 5 -t mangle -F "$AWG_CHAIN"

    # --- Exclusion rules (evaluated first) ---
    local lan_net
    lan_net=$(get_lan_net)
    local endpoint
    endpoint=$(get_endpoint)

    iptables -w 5 -t mangle -A "$AWG_CHAIN" -m addrtype --dst-type LOCAL -j RETURN
    [ -n "$lan_net" ] && iptables -w 5 -t mangle -A "$AWG_CHAIN" -d "$lan_net" -j RETURN
    iptables -w 5 -t mangle -A "$AWG_CHAIN" -p udp -m multiport --dports 67,68,123 -j RETURN
    iptables -w 5 -t mangle -A "$AWG_CHAIN" -d 224.0.0.0/4 -j RETURN
    [ -n "$endpoint" ] && iptables -w 5 -t mangle -A "$AWG_CHAIN" -d "$endpoint" -j RETURN

    # --- Per-device rules (two passes for correct ordering) ---
    save_clients
    if [ -f "$CLIENTS_FILE" ] && [ -s "$CLIENTS_FILE" ]; then

        # Pass 1: "direct" exclusions (RETURN rules must come before MARK rules)
        while IFS=',' read -r dev_id name policy mac || [ -n "$dev_id" ]; do
            dev_id=$(echo "$dev_id" | tr -d ' ')
            policy=$(echo "$policy" | tr -d ' ')
            mac=$(echo "$mac" | tr -d ' ')
            [ -z "$dev_id" ] && continue
            [ "$policy" != "direct" ] && continue

            if [ "$default_policy" != "direct" ]; then
                if [ -n "$mac" ]; then
                    iptables -w 5 -t mangle -A "$AWG_CHAIN" -m mac --mac-source "$mac" -j RETURN
                else
                    ip rule add from "$dev_id" lookup main prio 97
                fi
                log_msg "Route: $dev_id ($name) -> Direct (excluded)"
            else
                log_msg "Route: $dev_id ($name) -> Direct"
            fi
        done < "$CLIENTS_FILE"

        # Pass 2: vpn_all and vpn_geo rules
        while IFS=',' read -r dev_id name policy mac || [ -n "$dev_id" ]; do
            dev_id=$(echo "$dev_id" | tr -d ' ')
            policy=$(echo "$policy" | tr -d ' ')
            mac=$(echo "$mac" | tr -d ' ')
            [ -z "$dev_id" ] && continue

            case "$policy" in
                vpn_all)
                    if [ -n "$mac" ]; then
                        iptables -w 5 -t mangle -A "$AWG_CHAIN" -m mac --mac-source "$mac" -j MARK --set-mark "$FWMARK"
                    else
                        ip rule add from "$dev_id" lookup $RT_TABLE prio 99
                    fi
                    log_msg "Route: $dev_id ($name) -> VPN (all)"
                    ;;
                vpn_geo)
                    if run_ipset list "$IPSET_NAME" >/dev/null 2>&1; then
                        if [ -n "$mac" ]; then
                            iptables -w 5 -t mangle -A "$AWG_CHAIN" -m mac --mac-source "$mac" \
                                -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$FWMARK"
                        else
                            iptables -w 5 -t mangle -A "$AWG_CHAIN" -s "$dev_id" \
                                -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$FWMARK"
                        fi
                        has_geo=true
                        log_msg "Route: $dev_id ($name) -> VPN (geo)"
                    else
                        log_msg "WARNING: ipset missing, skipping geo for $dev_id ($name)"
                    fi
                    ;;
            esac
        done < "$CLIENTS_FILE"
    fi

    # --- Default policy (last rules in chain) ---
    case "$default_policy" in
        vpn_all)
            iptables -w 5 -t mangle -A "$AWG_CHAIN" -j MARK --set-mark "$FWMARK"
            log_msg "Default: all -> VPN"
            ;;
        vpn_geo)
            if run_ipset list "$IPSET_NAME" >/dev/null 2>&1; then
                iptables -w 5 -t mangle -A "$AWG_CHAIN" \
                    -m set --match-set "$IPSET_NAME" dst -j MARK --set-mark "$FWMARK"
                has_geo=true
                log_msg "Default: geo -> VPN"
            else
                log_msg "WARNING: ipset missing, geo default policy not applied"
            fi
            ;;
        direct|*)
            log_msg "Default: direct"
            ;;
    esac

    # --- Hook chain into PREROUTING ---
    iptables -w 5 -t mangle -C PREROUTING -j "$AWG_CHAIN" 2>/dev/null || \
        iptables -w 5 -t mangle -A PREROUTING -j "$AWG_CHAIN"

    # --- Single fwmark rule for all marked traffic ---
    ip rule add fwmark "$FWMARK" lookup $RT_TABLE prio 98

    # --- Force DNS through dnsmasq whenever VPN is active ---
    if [ "$default_policy" != "direct" ] || [ "$has_geo" = true ]; then
        setup_dns_interception
    fi

    # --- Restart dnsmasq if geo active (deferred until Merlin's rc_service is idle) ---
    if [ $domain_count -gt 0 ] || [ "$has_geo" = true ]; then
        restart_dnsmasq_when_idle &
    fi

    # --- Always flush conntrack so devices reconnect through VPN ---
    flush_conntrack

    # --- Setup cron ---
    if [ "$(get_setting awg_geo_autoupdate)" = "1" ]; then
        cru a awg_geo_update "0 4 * * * '$ADDON_DIR/amneziawg.sh' update_geo"
    fi

    log_msg "Firewall configured: $ip_count IPs, $domain_count domains"
}

save_clients(){
    local clients=$(get_setting awg_clients)
    if [ -n "$clients" ]; then
        echo "$clients" | tr ';' '\n' > "$CLIENTS_FILE"
    else
        > "$CLIENTS_FILE"
    fi
}

# Check if geo databases exist locally
geo_available(){
    [ -d "$GEO_DIR/geoip" ] && [ -n "$(ls "$GEO_DIR/geoip/"*.cidr 2>/dev/null)" ]
}

update_geo_if_needed(){
    if ! geo_available; then
        log_msg "WARNING: Geo databases not downloaded. Use Update Now in web UI."
    fi
}

# Force re-download all geo databases
update_geo_lists(){
    download_all_geo
}

# --- Validation helpers ---

validate_wgkey(){
    echo "$1" | grep -qE '^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$' && return 0
    log_msg "ERROR: Invalid WireGuard key"
    return 1
}

validate_endpoint(){
    local host port
    port="${1##*:}"
    host="${1%:*}"
    echo "$port" | grep -qE '^[0-9]+$' || { log_msg "ERROR: Invalid endpoint port: $1"; return 1; }
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] 2>/dev/null || { log_msg "ERROR: Endpoint port out of range: $port"; return 1; }
    [ -n "$host" ] || { log_msg "ERROR: Empty endpoint host"; return 1; }
    return 0
}

validate_port(){
    echo "$1" | grep -qE '^[0-9]+$' || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ] 2>/dev/null || return 1
    return 0
}

# Ported from advocdiaboly/asuswrt-merlin-amneziawg@1e3ea05 (Dmitry Fomin):
# reject values above UINT32_MAX so a malformed setting can't produce a
# config value amneziawg-go/awg would silently truncate or misparse.
validate_uint(){
    echo "$1" | grep -qE '^[0-9]+$' || return 1
    [ "$1" -le 4294967295 ] 2>/dev/null || return 1
    return 0
}

# Accepts a single uint or a "min-max" range (start <= end). Used for H1-H4
# and the AmneziaWG 3.0 timing/padding fields, which all share this syntax.
# Ported from upstream r0otx@f7cd46a (PR #8, ayuckhulk/ranges-support-for-h1-h4);
# UINT32_MAX bound ported from advocdiaboly/asuswrt-merlin-amneziawg@1e3ea05 (Dmitry Fomin).
validate_range(){
    echo "$1" | grep -qE '^[0-9]+(-[0-9]+)?$' || return 1
    case "$1" in
        *-*)
            local start=${1%-*} end=${1#*-}
            [ "$start" -le "$end" ] || return 1
            [ "$end" -le 4294967295 ] 2>/dev/null || return 1
            ;;
        *)
            [ "$1" -le 4294967295 ] 2>/dev/null || return 1
            ;;
    esac
    return 0
}

validate_header(){
    validate_range "$1"
}

validate_ip(){
    echo "$1" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || return 1
    return 0
}

# --- Generate awg0.conf ---

generate_config(){
    mkdir -p "$AWG_DIR"

    local privkey=$(get_setting awg_privatekey)
    local listenport=$(get_setting awg_listenport)
    local jc=$(get_setting awg_jc)
    local jmin=$(get_setting awg_jmin)
    local jmax=$(get_setting awg_jmax)
    local s1=$(get_setting awg_s1)
    local s2=$(get_setting awg_s2)
    local s3=$(get_setting awg_s3)
    local s4=$(get_setting awg_s4)
    local h1=$(get_setting awg_h1)
    local h2=$(get_setting awg_h2)
    local h3=$(get_setting awg_h3)
    local h4=$(get_setting awg_h4)

    # --- AmneziaWG 3.0 (header protection) ---
    local header_protection_key=$(get_setting awg_header_protection_key)
    local content_padding=$(get_setting awg_content_padding)
    local rekey_after=$(get_setting awg_rekey_after)
    local rekey_timeout=$(get_setting awg_rekey_timeout)
    local reject_after=$(get_setting awg_reject_after)
    local keepalive_timeout=$(get_setting awg_keepalive_timeout)
    local max_handshake_attempts=$(get_setting awg_max_handshake_attempts)

    # I1-I5 from base64-encoded setting
    local i1="" i2="" i3="" i4="" i5=""
    local initdata=$(get_setting awg_initdata)
    if [ -n "$initdata" ]; then
        # custom_settings.txt round-trips through Merlin's own nvram-backed
        # storage, which has been observed to introduce stray characters
        # (embedded spaces/newlines) into otherwise-valid base64 -- strict
        # decoders (GNU base64 without --ignore-garbage) then refuse the
        # whole string. Strip anything outside the base64 alphabet up front
        # so a decode failure means the decoder is genuinely missing, not
        # that one stray byte poisoned an otherwise-fine string.
        local clean_initdata
        clean_initdata=$(echo "$initdata" | tr -dc 'A-Za-z0-9+/=')
        if [ "$clean_initdata" != "$initdata" ]; then
            log_msg "initdata contained non-base64 characters, stripped before decoding (len ${#initdata} -> ${#clean_initdata})"
        fi
        # `coreutils-base64`'s real binary is /opt/libexec/base64-coreutils;
        # opkg is supposed to symlink it onto PATH as /opt/bin/base64 via its
        # "Alternatives" control field, but older/lighter opkg builds (e.g.
        # a plain opkg-cl without alternatives support) silently ignore that
        # field, so the package installs "successfully" while `base64` never
        # actually becomes runnable. Repair the symlink ourselves if we can,
        # and try the libexec binary directly regardless.
        if [ -x /opt/libexec/base64-coreutils ] && [ ! -e /opt/bin/base64 ]; then
            ln -sf /opt/libexec/base64-coreutils /opt/bin/base64 2>/dev/null && \
                log_msg "Repaired missing /opt/bin/base64 -> /opt/libexec/base64-coreutils symlink"
        fi
        local decoded=""
        for _b64 in base64 /opt/libexec/base64-coreutils; do
            command -v "$_b64" >/dev/null 2>&1 || [ -x "$_b64" ] || continue
            decoded=$(echo "$clean_initdata" | "$_b64" -d -i 2>/dev/null)
            [ -z "$decoded" ] && decoded=$(echo "$clean_initdata" | "$_b64" -d 2>/dev/null)
            [ -n "$decoded" ] && break
        done
        # Ported from advocdiaboly/asuswrt-merlin-amneziawg@fbf595e (Dmitry Fomin):
        # fall back to openssl if base64 isn't on PATH (varies across Merlin/Entware builds).
        if [ -z "$decoded" ] && command -v openssl >/dev/null 2>&1; then
            decoded=$(echo "$clean_initdata" | openssl enc -base64 -d -A 2>/dev/null)
        fi
        # Neither a standalone `base64` nor `openssl` is guaranteed to be
        # installed (Entware packages, both optional). busybox itself is
        # always present since it *is* the userspace on this firmware, and
        # its multi-call binary frequently has the base64 applet built in
        # even when it isn't symlinked onto PATH as a separate command.
        if [ -z "$decoded" ] && command -v busybox >/dev/null 2>&1; then
            decoded=$(echo "$clean_initdata" | busybox base64 -d 2>/dev/null)
        fi
        # Self-heal once per boot if nothing above worked (e.g. neither
        # coreutils-base64 nor openssl-util is installed at all yet). This
        # attempt is logged, unlike postinst's old attempt (removed in
        # v1.3.6) -- whose stdout only ever reached the interactive opkg
        # session, never the persistent log.
        if [ -z "$decoded" ] && [ -f /tmp/.awg_base64_install_tried ]; then
            log_msg "base64 decoder still unavailable (auto-install already attempted this boot -- reboot or run 'opkg install openssl-util' manually to retry)"
        elif [ -z "$decoded" ]; then
            # `opkg` itself may be a shell function/alias defined only in an
            # interactive login profile (not inherited by this non-
            # interactive script) rather than a real PATH entry -- also try
            # opkg-cl and known absolute Entware locations before giving up.
            local opkg_bin=""
            for _c in opkg opkg-cl; do
                command -v "$_c" >/dev/null 2>&1 && { opkg_bin="$_c"; break; }
            done
            if [ -z "$opkg_bin" ]; then
                for _p in /opt/bin/opkg /opt/bin/opkg-cl /opt/sbin/opkg /opt/sbin/opkg-cl; do
                    [ -x "$_p" ] && { opkg_bin="$_p"; break; }
                done
            fi
            if [ -n "$opkg_bin" ]; then
                touch /tmp/.awg_base64_install_tried
                # openssl-util installs a plain /opt/bin/openssl with no
                # Alternatives indirection, so prefer it over
                # coreutils-base64 -- more likely to actually end up runnable.
                log_msg "No base64 decoder available, attempting: $opkg_bin install openssl-util"
                if "$opkg_bin" install openssl-util >/dev/null 2>&1 || "$opkg_bin" install coreutils-base64 >/dev/null 2>&1; then
                    log_msg "decoder package installed, retrying I1-I5 decode"
                    [ -x /opt/libexec/base64-coreutils ] && [ ! -e /opt/bin/base64 ] && \
                        ln -sf /opt/libexec/base64-coreutils /opt/bin/base64 2>/dev/null
                    command -v openssl >/dev/null 2>&1 && decoded=$(echo "$clean_initdata" | openssl enc -base64 -d -A 2>/dev/null)
                    for _b64 in base64 /opt/libexec/base64-coreutils; do
                        [ -n "$decoded" ] && break
                        command -v "$_b64" >/dev/null 2>&1 || [ -x "$_b64" ] || continue
                        decoded=$(echo "$clean_initdata" | "$_b64" -d -i 2>/dev/null)
                        [ -z "$decoded" ] && decoded=$(echo "$clean_initdata" | "$_b64" -d 2>/dev/null)
                    done
                else
                    log_msg "ERROR: $opkg_bin install openssl-util/coreutils-base64 failed -- check internet/opkg feed"
                fi
            else
                log_msg "ERROR: opkg/opkg-cl not found (PATH=$PATH), cannot auto-install a base64 decoder"
            fi
        fi
        if [ -n "$decoded" ]; then
            i1=$(echo "$decoded" | awk '/^I1 /{sub(/^[^=]+=[ ]?/,"");print;exit}')
            i2=$(echo "$decoded" | awk '/^I2 /{sub(/^[^=]+=[ ]?/,"");print;exit}')
            i3=$(echo "$decoded" | awk '/^I3 /{sub(/^[^=]+=[ ]?/,"");print;exit}')
            i4=$(echo "$decoded" | awk '/^I4 /{sub(/^[^=]+=[ ]?/,"");print;exit}')
            i5=$(echo "$decoded" | awk '/^I5 /{sub(/^[^=]+=[ ]?/,"");print;exit}')
        else
            log_msg "ERROR: Failed to decode I1-I5 initdata (tried base64, /opt/libexec/base64-coreutils, openssl, busybox base64 -- len=${#initdata} clean_len=${#clean_initdata} prefix='$(echo "$clean_initdata" | cut -c1-12)...')"
        fi
    fi

    local peer_pubkey=$(get_setting awg_peer_pubkey)
    local peer_psk=$(get_setting awg_peer_psk)
    local peer_endpoint=$(get_setting awg_peer_endpoint)
    local peer_allowedips=$(get_setting awg_peer_allowedips | sed 's/,[[:space:]]*$//;s/,/, /g')
    local peer_keepalive=$(get_setting awg_peer_keepalive)

    if [ -z "$privkey" ] || [ -z "$peer_pubkey" ] || [ -z "$peer_endpoint" ]; then
        log_msg "ERROR: Missing required config"
        return 1
    fi
    validate_wgkey "$privkey" || return 1
    validate_wgkey "$peer_pubkey" || return 1
    [ -n "$peer_psk" ] && { validate_wgkey "$peer_psk" || return 1; }
    validate_endpoint "$peer_endpoint" || return 1
    [ -n "$listenport" ] && { validate_port "$listenport" || { log_msg "ERROR: Invalid listen port: $listenport"; return 1; }; }
    [ -n "$jc" ] && { validate_uint "$jc" || { log_msg "ERROR: Invalid Jc: $jc"; return 1; }; }
    [ -n "$jmin" ] && { validate_uint "$jmin" || { log_msg "ERROR: Invalid Jmin: $jmin"; return 1; }; }
    [ -n "$jmax" ] && { validate_uint "$jmax" || { log_msg "ERROR: Invalid Jmax: $jmax"; return 1; }; }
    [ -n "$s1" ] && { validate_uint "$s1" || { log_msg "ERROR: Invalid S1: $s1"; return 1; }; }
    [ -n "$s2" ] && { validate_uint "$s2" || { log_msg "ERROR: Invalid S2: $s2"; return 1; }; }
    [ -n "$s3" ] && { validate_uint "$s3" || { log_msg "ERROR: Invalid S3: $s3"; return 1; }; }
    [ -n "$s4" ] && { validate_uint "$s4" || { log_msg "ERROR: Invalid S4: $s4"; return 1; }; }
    [ -n "$h1" ] && { validate_header "$h1" || { log_msg "ERROR: Invalid H1: $h1"; return 1; }; }
    [ -n "$h2" ] && { validate_header "$h2" || { log_msg "ERROR: Invalid H2: $h2"; return 1; }; }
    [ -n "$h3" ] && { validate_header "$h3" || { log_msg "ERROR: Invalid H3: $h3"; return 1; }; }
    [ -n "$h4" ] && { validate_header "$h4" || { log_msg "ERROR: Invalid H4: $h4"; return 1; }; }
    [ -n "$header_protection_key" ] && { validate_wgkey "$header_protection_key" || return 1; }
    [ -n "$content_padding" ] && { validate_range "$content_padding" || { log_msg "ERROR: Invalid ContentPaddingAddition: $content_padding"; return 1; }; }
    [ -n "$rekey_after" ] && { validate_range "$rekey_after" || { log_msg "ERROR: Invalid RekeyAfterTime: $rekey_after"; return 1; }; }
    [ -n "$rekey_timeout" ] && { validate_range "$rekey_timeout" || { log_msg "ERROR: Invalid RekeyTimeout: $rekey_timeout"; return 1; }; }
    [ -n "$reject_after" ] && { validate_range "$reject_after" || { log_msg "ERROR: Invalid RejectAfterTime: $reject_after"; return 1; }; }
    [ -n "$keepalive_timeout" ] && { validate_range "$keepalive_timeout" || { log_msg "ERROR: Invalid KeepaliveTimeout: $keepalive_timeout"; return 1; }; }
    [ -n "$max_handshake_attempts" ] && { validate_range "$max_handshake_attempts" || { log_msg "ERROR: Invalid MaxHandshakeAttempts: $max_handshake_attempts"; return 1; }; }

    {
        echo "[Interface]"
        echo "PrivateKey = $privkey"
        [ -n "$listenport" ] && echo "ListenPort = $listenport"
        [ -n "$jc" ] && echo "Jc = $jc"
        [ -n "$jmin" ] && echo "Jmin = $jmin"
        [ -n "$jmax" ] && echo "Jmax = $jmax"
        [ -n "$s1" ] && echo "S1 = $s1"
        [ -n "$s2" ] && echo "S2 = $s2"
        [ -n "$s3" ] && echo "S3 = $s3"
        [ -n "$s4" ] && echo "S4 = $s4"
        [ -n "$h1" ] && echo "H1 = $h1"
        [ -n "$h2" ] && echo "H2 = $h2"
        [ -n "$h3" ] && echo "H3 = $h3"
        [ -n "$h4" ] && echo "H4 = $h4"
        [ -n "$i1" ] && echo "I1 = $i1"
        [ -n "$i2" ] && echo "I2 = $i2"
        [ -n "$i3" ] && echo "I3 = $i3"
        [ -n "$i4" ] && echo "I4 = $i4"
        [ -n "$i5" ] && echo "I5 = $i5"
        [ -n "$header_protection_key" ] && echo "HeaderProtectionKey = $header_protection_key"
        [ -n "$content_padding" ] && echo "ContentPaddingAddition = $content_padding"
        [ -n "$rekey_after" ] && echo "RekeyAfterTime = $rekey_after"
        [ -n "$rekey_timeout" ] && echo "RekeyTimeout = $rekey_timeout"
        [ -n "$reject_after" ] && echo "RejectAfterTime = $reject_after"
        [ -n "$keepalive_timeout" ] && echo "KeepaliveTimeout = $keepalive_timeout"
        [ -n "$max_handshake_attempts" ] && echo "MaxHandshakeAttempts = $max_handshake_attempts"
        echo ""
        echo "[Peer]"
        echo "PublicKey = $peer_pubkey"
        [ -n "$peer_psk" ] && echo "PresharedKey = $peer_psk"
        [ -n "$peer_endpoint" ] && echo "Endpoint = $peer_endpoint"
        echo "AllowedIPs = ${peer_allowedips:-0.0.0.0/0}"
        [ -n "$peer_keepalive" ] && echo "PersistentKeepalive = $peer_keepalive"
    } > "$CONF"

    chmod 600 "$CONF"

    local address=$(get_setting awg_address)
    [ -n "$address" ] && echo "$address" > "$AWG_DIR/awg0.addr"
    local dns=$(get_setting awg_dns)
    [ -n "$dns" ] && echo "$dns" > "$AWG_DIR/awg0.dns"

    log_msg "Config saved"
    return 0
}

# --- Start ---

do_start(){
    # Skip if update in progress (opkg triggers S99amneziawg start)
    [ -f /tmp/.awg_no_autostart ] && { log_msg "Start blocked: update in progress"; return 0; }

    if is_running; then
        log_msg "Already running"
        update_status
        return 0
    fi

    # Wait for network to be ready (br0 up with IP), important on boot
    if ! ip -4 addr show br0 2>/dev/null | grep -q "inet "; then
        log_msg "Waiting for network (br0)..."
        wait_for_iface_ip br0 30
        if ! ip -4 addr show br0 2>/dev/null | grep -q "inet "; then
            log_msg "ERROR: Network not ready (br0 has no IP after 30s)"
            return 1
        fi
    fi

    acquire_lock || { log_msg "Cannot acquire lock, aborting start"; update_status; return 1; }

    generate_config || { update_status; release_lock; return 1; }
    [ ! -f "$CONF" ] && { log_msg "ERROR: No config"; update_status; release_lock; return 1; }
    [ ! -f "$AWG_GO" ] && { log_msg "ERROR: amneziawg-go not found"; update_status; release_lock; return 1; }

    # Ensure TUN device exists
    modprobe tun 2>/dev/null
    mkdir -p /dev/net
    [ ! -c /dev/net/tun ] && mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun

    # Start userspace daemon
    mkdir -p /var/run/amneziawg
    # Bound Go heap growth on low-RAM routers (256-512MB models in the support list).
    # Ported from advocdiaboly/asuswrt-merlin-amneziawg@ea58f06 (Dmitry Fomin).
    GOMEMLIMIT=320MiB GOGC=20 "$AWG_GO" "$IFACE" > /tmp/awg_daemon.log 2>&1 &
    if ! wait_for_iface "$IFACE" 10; then
        log_msg "ERROR: amneziawg-go failed to create interface"
        [ -f /tmp/awg_daemon.log ] && log_msg "Daemon output: $(cat /tmp/awg_daemon.log)"
        update_status; release_lock; return 1
    fi
    log_msg "Userspace daemon started"

    # Configure interface
    local setconf_err
    setconf_err=$("$AWG_BIN" setconf "$IFACE" "$CONF" 2>&1)
    if [ $? -ne 0 ]; then
        log_msg "ERROR: setconf failed: ${setconf_err:-no output}"
        ip link del "$IFACE" 2>/dev/null; update_status; release_lock; return 1
    fi

    [ -f "$AWG_DIR/awg0.addr" ] && ip addr add "$(cat "$AWG_DIR/awg0.addr")" dev "$IFACE"
    ip link set "$IFACE" mtu 1280
    ip link set "$IFACE" up

    # Routing table
    local lan_net gw endpoint
    lan_net=$(get_lan_net)
    gw=$(ip route | awk '/^default/{print $3; exit}')
    endpoint=$(get_endpoint)
    [ -n "$endpoint" ] && [ -n "$gw" ] && ip route add "$endpoint" via "$gw" 2>/dev/null
    ip route add 0.0.0.0/1 dev "$IFACE" table $RT_TABLE 2>/dev/null
    ip route add 128.0.0.0/1 dev "$IFACE" table $RT_TABLE 2>/dev/null
    [ -n "$lan_net" ] && ip route add "$lan_net" dev br0 table $RT_TABLE 2>/dev/null

    save_and_set_rp_filter

    # Base iptables
    iptables -w 5 -I INPUT -i "$IFACE" -j ACCEPT
    iptables -w 5 -I FORWARD -i "$IFACE" -j ACCEPT
    iptables -w 5 -I FORWARD -o "$IFACE" -j ACCEPT
    iptables -w 5 -t mangle -A FORWARD -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -w 5 -t mangle -A FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    if [ -n "$lan_net" ]; then
        iptables -w 5 -t nat -I POSTROUTING -s "$lan_net" -o "$IFACE" -j MASQUERADE
    else
        iptables -w 5 -t nat -I POSTROUTING -o "$IFACE" -j MASQUERADE
    fi

    setup_firewall

    # Route for router-originated traffic (after setup_firewall which cleans ip rules)
    local awg_addr
    awg_addr=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{sub(/\/.*/, "", $2); print $2; exit}')
    [ -n "$awg_addr" ] && ip rule add from "$awg_addr" lookup $RT_TABLE prio 100

    # Watchdog
    cru a awg_watchdog "*/5 * * * * '$ADDON_DIR/amneziawg.sh' watchdog"

    log_msg "Started, verifying tunnel connectivity..."
    update_status
    release_lock

    # Health check: verify tunnel passes traffic, rollback if not
    local hc_ok=false
    local hc_try=0
    while [ $hc_try -lt 30 ]; do
        if ping -c 1 -W 2 -I "$IFACE" 8.8.8.8 >/dev/null 2>&1; then
            hc_ok=true
            break
        fi
        hc_try=$((hc_try + 1))
        sleep 2
    done
    if [ "$hc_ok" = true ]; then
        log_msg "Tunnel verified: traffic passing"
        update_status
    else
        log_msg "ERROR: Tunnel not passing traffic after 60s, rolling back to prevent lockout"
        do_stop 2>/dev/null
        log_msg "VPN stopped automatically. Check server config and endpoint reachability."
        update_status
    fi
}

# --- Stop ---

do_stop(){
    acquire_lock || { log_msg "Cannot acquire lock, aborting stop"; return 1; }

    iptables -w 5 -D INPUT -i "$IFACE" -j ACCEPT 2>/dev/null
    iptables -w 5 -D FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null
    iptables -w 5 -D FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null
    cleanup_ipv6_block
    cleanup_quic_block
    iptables -w 5 -t mangle -D FORWARD -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    iptables -w 5 -t mangle -D FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
    local lan_net
    lan_net=$(get_lan_net)
    [ -n "$lan_net" ] && iptables -w 5 -t nat -D POSTROUTING -s "$lan_net" -o "$IFACE" -j MASQUERADE 2>/dev/null
    iptables -w 5 -t nat -D POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null

    cleanup_firewall

    ip route flush table $RT_TABLE 2>/dev/null
    local endpoint
    endpoint=$(get_endpoint)
    [ -n "$endpoint" ] && ip route del "$endpoint" 2>/dev/null

    restore_rp_filter

    # Stop daemon
    ip link set "$IFACE" down 2>/dev/null
    ip link del "$IFACE" 2>/dev/null
    local awg_pid
    awg_pid=$(pidof amneziawg-go 2>/dev/null)
    if [ -n "$awg_pid" ]; then
        kill "$awg_pid" 2>/dev/null
        wait_for_pid_exit amneziawg-go 5
        # Force kill if still alive (crashed/stuck process)
        pidof amneziawg-go >/dev/null 2>&1 && kill -9 "$(pidof amneziawg-go)" 2>/dev/null
    fi
    rm -f /var/run/amneziawg/"$IFACE".sock

    service restart_dnsmasq >/dev/null 2>&1 &
    wait_for_dns 10

    log_msg "Stopped"
    update_status
    release_lock
}

# --- Status JSON for web UI ---

update_status(){
    local running=false
    local pub_key=""
    local listen_port=""
    local iface_addr=""
    local peers_json="[]"
    local log_text=""

    if is_running; then
        running=true
        iface_addr=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
        listen_port=$("$AWG_BIN" show "$IFACE" listen-port 2>/dev/null)
        pub_key=$("$AWG_BIN" show "$IFACE" public-key 2>/dev/null)

        local dump=$("$AWG_BIN" show "$IFACE" dump 2>/dev/null | tail -n +2)
        if [ -n "$dump" ]; then
            local p_items=""
            while IFS='	' read -r pkey psk endpoint aips handshake rx tx keepalive; do
                local hs_text="never"
                if [ "$handshake" != "0" ] && [ -n "$handshake" ]; then
                    local ago=$(( $(date +%s) - handshake ))
                    if [ $ago -lt 60 ]; then hs_text="${ago}s ago"
                    elif [ $ago -lt 3600 ]; then hs_text="$(( ago / 60 ))m ago"
                    else hs_text="$(( ago / 3600 ))h ago"; fi
                fi
                local rx_h=$(human_size "${rx:-0}")
                local tx_h=$(human_size "${tx:-0}")
                local item="{\"endpoint\":\"${endpoint}\",\"allowed_ips\":\"${aips}\",\"transfer_rx\":\"${rx_h}\",\"transfer_tx\":\"${tx_h}\",\"latest_handshake\":\"${hs_text}\"}"
                [ -n "$p_items" ] && p_items="${p_items},${item}" || p_items="$item"
            done <<EOF
$dump
EOF
            peers_json="[${p_items}]"
        fi
    fi

    log_text=$(grep "amneziawg" /tmp/syslog.log 2>/dev/null | tail -20 | sed 's/"/\\"/g' | tr '\n' '|' | sed 's/|/\\n/g')

    local default_policy=$(get_setting awg_default_policy)
    [ -z "$default_policy" ] && default_policy="direct"
    local clients_data=$(get_setting awg_clients | sed 's/"/\\"/g')
    local active_rules=$(ip rule show 2>/dev/null | grep -c "lookup $RT_TABLE\|fwmark $FWMARK")

    local ipset_count=0
    run_ipset list "$IPSET_NAME" -t 2>/dev/null | grep -q "Number of entries" && \
        ipset_count=$(run_ipset list "$IPSET_NAME" -t 2>/dev/null | awk '/Number of entries/{print $NF}')

    local geo_domains=0
    [ -f "$DNSMASQ_AWG_CONF" ] && geo_domains=$(grep -c "^ipset=" "$DNSMASQ_AWG_CONF" 2>/dev/null)
    [ -z "$geo_domains" ] && geo_domains=0

    local geo_downloaded=false
    geo_available && geo_downloaded=true

    cat > "$STATUS_FILE" << STATUSEOF
{"running":${running},"version":"${AWG_VERSION}","public_key":"${pub_key}","listen_port":"${listen_port}","interface_addr":"${iface_addr}","peers":${peers_json},"default_policy":"${default_policy}","clients":"${clients_data}","active_rules":${active_rules},"ipset_count":${ipset_count},"geo_domains":${geo_domains},"geo_downloaded":${geo_downloaded},"log":"${log_text}"}
STATUSEOF
}

# --- Install/Mount/Uninstall ---

do_install_page(){
    source /usr/sbin/helper.sh
    nvram get rc_support | grep -q am_addons || { log_msg "ERROR: Addons not supported"; return 1; }

    mkdir -p "$ADDON_DIR"
    [ "$(readlink -f "$0")" != "$(readlink -f "$ADDON_DIR/amneziawg.sh")" ] && cp "$0" "$ADDON_DIR/amneziawg.sh"
    chmod +x "$ADDON_DIR/amneziawg.sh"

    [ -f "/tmp/amneziawg_page.asp" ] && cp /tmp/amneziawg_page.asp "$ADDON_DIR/amneziawg_page.asp"

    # Clean old page slots before requesting a new one
    for f in /www/user/user*.asp; do
        grep -q "AmneziaWG" "$f" 2>/dev/null && rm -f "$f"
    done

    am_get_webui_page "$ADDON_DIR/amneziawg_page.asp"
    [ "$am_webui_page" = "none" ] && { log_msg "ERROR: No page slot"; return 1; }

    cp "$ADDON_DIR/amneziawg_page.asp" "/www/user/$am_webui_page"
    mount_menu_tree "$am_webui_page"

    echo '{"running":false,"peers":[],"log":"Installed."}' > "$STATUS_FILE"

    [ ! -f /jffs/scripts/service-event ] && echo "#!/bin/sh" > /jffs/scripts/service-event && chmod +x /jffs/scripts/service-event
    if ! grep -q "amneziawg" /jffs/scripts/service-event; then
        echo 'echo "$2" | grep -q "^awg" && /jffs/addons/amneziawg/amneziawg.sh "service_event" "$1" "$2"' >> /jffs/scripts/service-event
    fi

    # WAN event hook
    [ ! -f /jffs/scripts/wan-event ] && echo "#!/bin/sh" > /jffs/scripts/wan-event && chmod +x /jffs/scripts/wan-event
    if ! grep -q "amneziawg" /jffs/scripts/wan-event; then
        echo '/jffs/addons/amneziawg/amneziawg.sh wan_event "$1" "$2"  # AmneziaWG' >> /jffs/scripts/wan-event
    fi

    # Firewall restart hook
    [ ! -f /jffs/scripts/firewall-start ] && echo "#!/bin/sh" > /jffs/scripts/firewall-start && chmod +x /jffs/scripts/firewall-start
    if ! grep -q "amneziawg" /jffs/scripts/firewall-start; then
        echo '/jffs/addons/amneziawg/amneziawg.sh firewall_restart  # AmneziaWG' >> /jffs/scripts/firewall-start
    fi

    [ ! -f /jffs/scripts/services-start ] && echo "#!/bin/sh" > /jffs/scripts/services-start && chmod +x /jffs/scripts/services-start
    grep -q "amneziawg" /jffs/scripts/services-start || echo "/jffs/addons/amneziawg/amneziawg.sh mount_ui &" >> /jffs/scripts/services-start

    [ -f "$GEO_DIR/domain_categories.txt" ] && cp "$GEO_DIR/domain_categories.txt" /www/user/domain_categories.htm 2>/dev/null

    log_msg "Page installed: $am_webui_page"
    echo "Installed. Access: VPN > AmneziaWG"
}

do_mount_ui(){
    source /usr/sbin/helper.sh
    # Clean old slots
    for f in /www/user/user*.asp; do
        grep -q "AmneziaWG" "$f" 2>/dev/null && rm -f "$f"
    done
    am_get_webui_page "$ADDON_DIR/amneziawg_page.asp"
    if [ "$am_webui_page" != "none" ]; then
        cp "$ADDON_DIR/amneziawg_page.asp" "/www/user/$am_webui_page"
        mount_menu_tree "$am_webui_page"
    fi

    [ -f "$GEO_DIR/domain_categories.txt" ] && cp "$GEO_DIR/domain_categories.txt" /www/user/domain_categories.htm 2>/dev/null
    update_status

    if [ "$(get_setting awg_autostart)" = "1" ]; then
        sleep 10
        do_start
    fi
}

do_uninstall(){
    do_stop

    [ -f /jffs/scripts/service-event ] && sed -i '/amneziawg/d' /jffs/scripts/service-event
    [ -f /jffs/scripts/services-start ] && sed -i '/amneziawg/d' /jffs/scripts/services-start
    [ -f /jffs/scripts/wan-event ] && sed -i '/amneziawg/d' /jffs/scripts/wan-event
    [ -f /jffs/scripts/firewall-start ] && sed -i '/amneziawg/d' /jffs/scripts/firewall-start

    local page=$(ls /www/user/ 2>/dev/null | while read f; do grep -l "AmneziaWG" "/www/user/$f" 2>/dev/null; done | head -1)
    [ -n "$page" ] && rm -f "$page"
    rm -f "$STATUS_FILE" /www/user/domain_categories.htm

    rm -rf "$ADDON_DIR"

    # Same reasoning as mount_menu_tree(): unmount first to work from the
    # real underlying file, not a possibly-stale /tmp copy.
    umount /www/require/modules/menuTree.js 2>/dev/null
    if [ -f /www/require/modules/menuTree.js ]; then
        cp /www/require/modules/menuTree.js /tmp/menuTree.js
        sed -i '/AmneziaWG/d' /tmp/menuTree.js
        mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js
    fi

    log_msg "Uninstalled"
}

# --- Watchdog (called by cron every 5 min) ---

do_watchdog(){
    # Skip if lock held (another operation in progress)
    [ -d "$LOCKDIR" ] && return 0

    local reason=""
    if ! ip link show "$IFACE" >/dev/null 2>&1; then
        reason="interface $IFACE missing"
    elif ! pidof amneziawg-go >/dev/null 2>&1; then
        reason="amneziawg-go process dead"
    elif ! ping -c 1 -W 5 -I "$IFACE" 8.8.8.8 >/dev/null 2>&1; then
        reason="tunnel not passing traffic"
    fi

    if [ -n "$reason" ]; then
        log_msg "WATCHDOG: $reason, restarting"
        do_stop 2>/dev/null
        wait_for_pid_exit amneziawg-go 10
        do_start
    fi
}

# --- Update check ---

check_update(){
    local repo="stxlvn/asuswrt-merlin-amneziawg"
    local latest
    latest=$(curl -sfL --connect-timeout 10 --max-time 15 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"v//;s/".*//')
    if [ -z "$latest" ]; then
        echo "{\"current\":\"$AWG_VERSION\",\"latest\":\"\",\"update\":false,\"error\":\"Cannot reach GitHub\"}"
        return
    fi
    local update=false
    [ "$latest" != "$AWG_VERSION" ] && update=true
    echo "{\"current\":\"$AWG_VERSION\",\"latest\":\"$latest\",\"update\":$update}"
}

do_update(){
    log_msg "Updating AmneziaWG..."
    local repo="stxlvn/asuswrt-merlin-amneziawg"
    local pkg_arch
    pkg_arch=$(opkg print-architecture 2>/dev/null | awk '$1=="arch" && $2!="all" {print $2}' | head -1)
    if [ -z "$pkg_arch" ]; then
        local arch=$(uname -m)
        case "$arch" in
            aarch64) pkg_arch="aarch64-3.10" ;;
            armv7l)  pkg_arch="armv7-2.6" ;;
            *) log_msg "ERROR: Unsupported arch: $arch"; return 1 ;;
        esac
    fi

    local release_json
    release_json=$(curl -sfL --connect-timeout 10 --max-time 15 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null)
    local ipk_url
    ipk_url=$(echo "$release_json" | grep '"browser_download_url"' | grep "$pkg_arch" | grep '.ipk"' | head -1 | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"//;s/".*//')
    if [ -z "$ipk_url" ]; then
        local base_arch=$(echo "$pkg_arch" | sed 's/-.*//')
        ipk_url=$(echo "$release_json" | grep '"browser_download_url"' | grep "${base_arch}" | grep '.ipk"' | head -1 | sed 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"//;s/".*//')
    fi
    if [ -z "$ipk_url" ]; then
        log_msg "ERROR: No package found for $pkg_arch"
        return 1
    fi

    local tmp="/tmp/amneziawg_update.ipk"
    if ! curl -sfL --connect-timeout 10 --max-time 120 "$ipk_url" -o "$tmp"; then
        log_msg "ERROR: Download failed"
        return 1
    fi

    do_stop 2>/dev/null
    wait_for_pid_exit amneziawg-go 10
    # Block auto-start during opkg install (S99amneziawg is triggered by opkg)
    touch /tmp/.awg_no_autostart
    opkg install "$tmp" || opkg install --force-architecture "$tmp"
    rm -f "$tmp"
    # Stop VPN if opkg's init script started it
    do_stop 2>/dev/null
    wait_for_pid_exit amneziawg-go 10
    rm -f /tmp/.awg_no_autostart
    # Install page from new version
    /jffs/addons/amneziawg/amneziawg.sh install_page
    log_msg "Update complete. Start VPN from UI."
    update_status
}

do_wan_event(){
    local wan_if="$1" wan_state="$2"
    [ "$wan_state" != "connected" ] && return 0
    if is_running; then
        log_msg "WAN event: $wan_state on $wan_if, updating endpoint route"
        local gw endpoint
        gw=$(ip route | awk '/^default/{print $3; exit}')
        endpoint=$(get_endpoint)
        if [ -n "$endpoint" ] && [ -n "$gw" ]; then
            ip route del "$endpoint" 2>/dev/null
            ip route add "$endpoint" via "$gw" 2>/dev/null
            log_msg "Endpoint route updated: $endpoint via $gw"
        fi
    fi
}

do_firewall_restart(){
    if is_running; then
        log_msg "Firewall restart detected, re-applying rules"
        # Clean base rules first to prevent duplicates
        iptables -w 5 -D INPUT -i "$IFACE" -j ACCEPT 2>/dev/null
        iptables -w 5 -D FORWARD -i "$IFACE" -j ACCEPT 2>/dev/null
        iptables -w 5 -D FORWARD -o "$IFACE" -j ACCEPT 2>/dev/null
        iptables -w 5 -t mangle -D FORWARD -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
        iptables -w 5 -t mangle -D FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
        local lan_net_old
        lan_net_old=$(get_lan_net)
        [ -n "$lan_net_old" ] && iptables -w 5 -t nat -D POSTROUTING -s "$lan_net_old" -o "$IFACE" -j MASQUERADE 2>/dev/null
        iptables -w 5 -t nat -D POSTROUTING -o "$IFACE" -j MASQUERADE 2>/dev/null
        cleanup_ipv6_block
        cleanup_quic_block
        iptables -w 5 -I INPUT -i "$IFACE" -j ACCEPT
        iptables -w 5 -I FORWARD -i "$IFACE" -j ACCEPT
        iptables -w 5 -I FORWARD -o "$IFACE" -j ACCEPT
        iptables -w 5 -t mangle -A FORWARD -o "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        iptables -w 5 -t mangle -A FORWARD -i "$IFACE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        local lan_net
        lan_net=$(get_lan_net)
        if [ -n "$lan_net" ]; then
            iptables -w 5 -t nat -I POSTROUTING -s "$lan_net" -o "$IFACE" -j MASQUERADE
        else
            iptables -w 5 -t nat -I POSTROUTING -o "$IFACE" -j MASQUERADE
        fi
        # setup_firewall re-adds ipv6/QUIC blocks itself right after its own
        # cleanup_firewall call -- don't also call setup_ipv6_block here,
        # that would insert a duplicate rule every time firewall-start fires.
        setup_firewall
        local awg_addr
        awg_addr=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{sub(/\/.*/, "", $2); print $2; exit}')
        [ -n "$awg_addr" ] && ip rule add from "$awg_addr" lookup $RT_TABLE prio 100
    fi
}

# --- Service event dispatcher ---

do_service_event(){
    local event="$2"
    case "$event" in
        awgstart)       do_start ;;
        awgstop)        do_stop ;;
        awgrestart)     do_stop; wait_for_pid_exit amneziawg-go 10; do_start ;;
        awgsaveconf)
            local _wt=0; while [ $_wt -lt 5 ] && [ -z "$(get_setting awg_privatekey)" ]; do sleep 1; _wt=$((_wt+1)); done
            generate_config
            # Geo settings are intentionally never auto-cleared here: an update
            # wipes /opt/amneziawg (including the downloaded geo cache) via
            # prerm, so geo_available() is briefly false on every single
            # update even though the user's GeoIP/GeoSite selection is still
            # valid. setup_firewall already warns per-list and skips whatever
            # isn't cached without breaking anything else.
            update_geo_if_needed
            is_running && setup_firewall
            update_status
            ;;
        awgupdategeo)
            update_geo_lists
            is_running && setup_firewall
            update_status
            ;;
        awgcheckupdate)
            check_update > /www/user/awg_update.htm
            ;;
        awgdoupdate)
            do_update
            update_status
            ;;
    esac
}

# --- Main ---

case "$1" in
    start)          do_start ;;
    stop)           do_stop ;;
    restart)        do_stop; wait_for_pid_exit amneziawg-go 10; do_start ;;
    status)         update_status ;;
    update_geo)     update_geo_lists; is_running && setup_firewall; update_status ;;
    check_update)   check_update ;;
    update)         do_update ;;
    watchdog)       do_watchdog ;;
    install_page)   do_install_page ;;
    mount_ui)       do_mount_ui ;;
    uninstall)      do_uninstall ;;
    service_event)  do_service_event "$2" "$3" ;;
    wan_event)      do_wan_event "$2" "$3" ;;
    firewall_restart) do_firewall_restart ;;
    download_geo)   download_all_geo ;;
    *)              echo "Usage: $0 {start|stop|restart|status|update_geo|download_geo|install_page|uninstall}" ;;
esac
