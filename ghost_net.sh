#!/usr/bin/env bash
# ghost-net.sh — Automação de anonimato no Kali Linux (versão com menu interativo)
# Requisitos: openvpn, tor, macchanger, iptables, curl, nmcli (NetworkManager), lsof, torsocks
# Uso direto: apenas rode e escolha no menu — sudo ./ghost-net.sh

set -euo pipefail

# ===== CONFIG PADRÃO =====
IFACE=""
VPN_CONFIG=""
DO_MAC=1
TOR_ONLY=0
VPN_ONLY=0
AGGRESSIVE=0
DNS_LIST="1.1.1.1"
STATE_DIR="/var/run/ghost-net"
LOG="/var/log/ghost-net.log"

mkdir -p "$STATE_DIR"

log(){ echo "[$(date +'%F %T')] $*" | tee -a "$LOG"; }
fail(){ log "ERRO: $*"; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || fail "Execute como root (sudo)."; }

# ===== HELPERS =====
usage_quick(){ cat <<'EOF'
Opções rápidas (não necessárias no modo menu):
  --iface IFACE         Interface para MAC spoof (ex: wlan0)
  --vpn-config FILE     Caminho do .ovpn (OpenVPN)
  --aggressive-clean    Limpeza mais forte
  --tor-only            Somente Tor (sem VPN)
  --vpn-only            Somente VPN (sem Tor)
  --no-mac              Não alterar MAC
  --dns 1.1.1.1,9.9.9.9 DNS enquanto killswitch está ativo (padrão: 1.1.1.1)
  start|stop|status     Modo não interativo
EOF
}

iface_up(){ ip link show "$1" >/dev/null 2>&1; }
cur_mac(){ cat "/sys/class/net/$1/address"; }
orig_mac_file(){ echo "$STATE_DIR/origmac_$1"; }
iptables_backup(){ iptables-save >"$STATE_DIR/iptables.save" || true; ip6tables-save >"$STATE_DIR/ip6tables.save" || true; }
iptables_restore(){ [[ -f "$STATE_DIR/iptables.save" ]] && iptables-restore <"$STATE_DIR/iptables.save" || true; [[ -f "$STATE_DIR/ip6tables.save" ]] && ip6tables-restore <"$STATE_DIR/ip6tables.save" || true; }

disable_ipv6(){ sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null; sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null; }

set_dns_resolv(){ local file="/etc/resolv.conf"; if chattr -i "$file" 2>/dev/null; then :; fi; printf "# ghost-net resolv
" > "$file"; for d in ${DNS_LIST//,/ } ; do echo "nameserver $d" >> "$file"; done; chattr +i "$file" 2>/dev/null || true; }

unset_dns_resolv(){ local file="/etc/resolv.conf"; chattr -i "$file" 2>/dev/null || true; rm -f "$file"; systemctl restart systemd-resolved 2>/dev/null || true; }

wait_for_dev(){ local dev="$1"; for i in {1..30}; do ip link show "$dev" >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
wait_for_port(){ local port="$1"; for i in {1..30}; do ss -lnt | grep -q ":$port" && return 0; sleep 1; done; return 1; }

detect_tun(){ ip -br link | awk '$1 ~ /^tun[0-9]+/ {print $1}' | head -n1; }

# ===== LIMPEZA =====
clean_traces(){
  log "Limpando caches e temporários do usuário atual..."
  local UHOME UUSER
  UUSER=${SUDO_USER:-root}
  UHOME=$(getent passwd "$UUSER" | cut -d: -f6)
  [[ -d "$UHOME" ]] || UHOME="/root"

  rm -rf "$UHOME/.cache"/* 2>/dev/null || true
  rm -rf "$UHOME/.mozilla/firefox"/*/cache* 2>/dev/null || true
  rm -rf "$UHOME/.cache/google-chrome" "$UHOME/.config/google-chrome" 2>/dev/null || true
  rm -f  "$UHOME/.bash_history" "$UHOME/.zsh_history" 2>/dev/null || true
  find /tmp -mindepth 1 -maxdepth 1 -mtime +0 -exec rm -rf {} + 2>/dev/null || true
  apt-get clean >/dev/null 2>&1 || true
  rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true

  if (( AGGRESSIVE )); then
    log "Limpeza agressiva habilitada (journalctl vacuum, truncar logs)."
    journalctl --rotate >/dev/null 2>&1 || true
    journalctl --vacuum-time=1s >/dev/null 2>&1 || true
    find /var/log -type f -name "*.log" -exec truncate -s 0 {} + 2>/dev/null || true
  fi
}

# ===== MAC SPOOF =====
mac_spoof(){
  local ifc="$1"
  iface_up "$ifc" || fail "Interface $ifc não existe."
  local orig
  orig=$(cur_mac "$ifc")
  echo "$orig" > "$(orig_mac_file "$ifc")"
  log "MAC original de $ifc: $orig"
  nmcli dev set "$ifc" managed no >/dev/null 2>&1 || true
  ip link set "$ifc" down
  macchanger -r "$ifc" | tee -a "$LOG"
  ip link set "$ifc" up
  nmcli dev set "$ifc" managed yes >/dev/null 2>&1 || true
  # Randomização nas próximas conexões
  local cname
  cname=$(nmcli -g NAME,DEVICE connection show | awk -F: -v i="$ifc" '$2==i{print $1; exit}')
  [[ -n "$cname" ]] && nmcli connection modify "$cname" 802-11-wireless.cloned-mac-address random >/dev/null 2>&1 || true
}

mac_restore(){
  local ifc="$1"; local f="$(orig_mac_file "$ifc")"
  [[ -f "$f" ]] || { log "Sem MAC original salvo para $ifc"; return 0; }
  local orig; orig=$(cat "$f")
  nmcli dev set "$ifc" managed no >/dev/null 2>&1 || true
  ip link set "$ifc" down
  macchanger -p "$ifc" >/dev/null 2>&1 || ip link set "$ifc" address "$orig" || true
  ip link set "$ifc" up
  nmcli dev set "$ifc" managed yes >/dev/null 2>&1 || true
  rm -f "$f"
  log "MAC de $ifc restaurado para $orig"
}

# ===== FIREWALL (killswitch) =====
fw_apply_vpn_killswitch(){
  local TUN_IFC="$1"
  [[ -n "$TUN_IFC" ]] || fail "Interface tun não detectada."
  log "Aplicando killswitch VPN (permitindo apenas $TUN_IFC e loopback)..."
  iptables_backup
  iptables -F
  iptables -P OUTPUT DROP
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  # Loopback
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  # Estabelecidas
  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  # VPN
  iptables -A OUTPUT -o "$TUN_IFC" -j ACCEPT
  iptables -A INPUT  -i "$TUN_IFC" -j ACCEPT
  # DNS explícito (apenas antes da VPN ficar padrão)
  for d in ${DNS_LIST//,/ } ; do iptables -A OUTPUT -p udp --dport 53 -d "$d" -j ACCEPT; done
  disable_ipv6
  set_dns_resolv
}

fw_apply_tor_only(){
  log "Aplicando firewall para forçar uso de Tor (9050/9040 locais)..."
  iptables_backup
  iptables -F
  iptables -P OUTPUT DROP
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  # Loopback
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  # Estabelecidas
  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  # Tor local
  iptables -A OUTPUT -p tcp --dport 9050 -d 127.0.0.1 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 9040 -d 127.0.0.1 -j ACCEPT
  disable_ipv6
}

# ===== VPN / TOR =====
start_vpn(){
  [[ -n "$VPN_CONFIG" ]] || fail "--vpn-config é obrigatório quando VPN está habilitada."
  command -v openvpn >/dev/null || fail "openvpn não instalado."
  log "Iniciando OpenVPN com $VPN_CONFIG ..."
  pkill -f "openvpn --config" 2>/dev/null || true
  openvpn --config "$VPN_CONFIG" --daemon --writepid "$STATE_DIR/openvpn.pid" --log-append "$LOG"
  # Espera tunX subir
  local t
  for i in {1..30}; do t=$(detect_tun); [[ -n "$t" ]] && break; sleep 1; done
  [[ -n "$t" ]] || fail "Nenhuma interface tunX detectada. Verifique o .ovpn."
  echo "$t" > "$STATE_DIR/tun_ifc"
  log "VPN ativa ($t detectada)."
}

stop_vpn(){
  if [[ -f "$STATE_DIR/openvpn.pid" ]]; then
    kill "$(cat "$STATE_DIR/openvpn.pid")" 2>/dev/null || true
    rm -f "$STATE_DIR/openvpn.pid"
  fi
  pkill -f "openvpn --config" 2>/dev/null || true
  rm -f "$STATE_DIR/tun_ifc"
  log "VPN parada."
}

start_tor(){
  command -v tor >/dev/null || fail "tor não instalado."
  log "Iniciando serviço Tor..."
  systemctl start tor || service tor start || tor &
  wait_for_port 9050 || fail "Porta 9050 do Tor não abriu."
  log "Tor ativo (SOCKS5 em 127.0.0.1:9050)."
}

stop_tor(){
  systemctl stop tor 2>/dev/null || pkill -f "^tor" 2>/dev/null || true
  log "Tor parado."
}

# ===== TESTES =====
check_ip(){
  log "IP público (direto/via VPN):"
  if command -v curl >/dev/null; then
    curl -sS --max-time 10 https://ifconfig.me || true; echo
  fi
  if command -v torsocks >/dev/null; then
    log "IP via Tor (torsocks):"
    torsocks curl -sS --max-time 20 https://ifconfig.me || true; echo
  fi
}

# ===== START/STOP/STATUS =====
start_all(){
  need_root
  clean_traces

  if (( DO_MAC )); then
    [[ -n "$IFACE" ]] || fail "Informe uma interface com --iface ou pelo menu."
    mac_spoof "$IFACE"
  else
    log "MAC spoofing desabilitado por opção."
  fi

  if (( TOR_ONLY )); then
    fw_apply_tor_only
    start_tor
  else
    start_vpn
    local TUN_IFC
    TUN_IFC=$(cat "$STATE_DIR/tun_ifc")
    fw_apply_vpn_killswitch "$TUN_IFC"
    if (( ! VPN_ONLY )); then
      start_tor
    fi
  fi
  check_ip
  log "Ambiente de anonimato inicializado."
}

stop_all(){
  need_root
  stop_tor || true
  stop_vpn || true
  iptables_restore || true
  unset_dns_resolv || true
  if (( DO_MAC )) && [[ -n "$IFACE" ]]; then mac_restore "$IFACE"; fi
  log "Ambiente revertido."
}

status_all(){
  echo "=== ghost-net status ==="
  local t; t=$(detect_tun || true)
  echo "tunX:"; [[ -n "$t" ]] && ip -br addr show "$t" || echo "(não encontrado)"
  echo "tor (9050):"; ss -lnt 2>/dev/null | awk '/:9050/ {print}' || echo "(não escutando)"
  if [[ -n "$IFACE" ]]; then
    echo "iface $IFACE mac: $(cur_mac "$IFACE")"
  else
    echo "iface: (não informada)"
  fi
  echo "iptables policy:"; iptables -S | sed 's/^/- /'
}

# ===== MODO NÃO-INTERATIVO (parâmetros) =====
ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    start|stop|status) ACTION="$1"; shift;;
    --iface) IFACE="${2:-}"; shift 2;;
    --vpn-config) VPN_CONFIG="${2:-}"; shift 2;;
    --aggressive-clean) AGGRESSIVE=1; shift;;
    --tor-only) TOR_ONLY=1; shift;;
    --vpn-only) VPN_ONLY=1; shift;;
    --no-mac) DO_MAC=0; shift;;
    --dns) DNS_LIST="${2:-1.1.1.1}"; shift 2;;
    --help|-h) usage_quick; exit 0;;
    *) echo "Opção desconhecida: $1"; usage_quick; exit 1;;
  esac
done

if [[ -n "${ACTION:-}" ]]; then
  case "$ACTION" in
    start) start_all;;
    stop)  stop_all;;
    status) status_all;;
  esac
  exit 0
fi

# ===== MENU INTERATIVO =====
need_root

prompt_iface(){
  if [[ -n "$IFACE" ]]; then return; fi
  echo "Interfaces disponíveis:"; ip -br link | awk '{print NR ")", $1, $3}'
  read -rp "Informe a interface para MAC spoof (ex: wlan0): " IFACE
  [[ -n "$IFACE" ]] || fail "Interface não informada."
}

prompt_vpn(){
  if (( TOR_ONLY )); then return; fi
  if [[ -z "$VPN_CONFIG" ]]; then
    read -rp "Caminho do arquivo .ovpn (ou deixe vazio para cancelar VPN): " VPN_CONFIG || true
    if [[ -z "$VPN_CONFIG" ]]; then VPN_ONLY=0; TOR_ONLY=1; log "Sem .ovpn — alternando para modo Tor-only."; fi
  fi
}

press_enter(){ read -rp $'Pressione ENTER para continuar...
' _; }

while true; do
  clear
  cat <<'MENU'
==============================
  G H O S T - N E T   M E N U
==============================
[1] Anonimato total (VPN + Tor + MAC + Killswitch)
[2] Limpeza de rastros (simples) 
[3] Limpeza agressiva (inclui journals/logs)
[4] Somente Tor (forçado via firewall)
[5] Somente VPN (com killswitch)
[6] Status do ambiente
[7] Reverter tudo (parar Tor/VPN, restaurar MAC, iptables)
[0] Sair
MENU
  read -rp "Escolha: " choice
  case "$choice" in
    1)
      DO_MAC=1; TOR_ONLY=0; VPN_ONLY=0; AGGRESSIVE=0
      prompt_iface; prompt_vpn
      start_all; status_all; press_enter;;
    2)
      AGGRESSIVE=0; clean_traces; log "Limpeza simples concluída."; status_all; press_enter;;
    3)
      AGGRESSIVE=1; clean_traces; log "Limpeza agressiva concluída."; status_all; press_enter;;
    4)
      DO_MAC=1; TOR_ONLY=1; VPN_ONLY=0; AGGRESSIVE=0
      prompt_iface
      fw_apply_tor_only; start_tor; check_ip; status_all; press_enter;;
    5)
      DO_MAC=1; TOR_ONLY=0; VPN_ONLY=1; AGGRESSIVE=0
      prompt_iface; prompt_vpn
      start_all; status_all; press_enter;;
    6)
      status_all; press_enter;;
    7)
      stop_all; status_all; press_enter;;
    0)
      echo "Saindo..."; exit 0;;
    *) echo "Opção inválida"; sleep 1;;
  esac
done
