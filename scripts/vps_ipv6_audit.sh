#!/usr/bin/env bash
# ==============================================================================
# VPS IPv6 & WireGuard Ground-Truth Diagnostic Script
# ==============================================================================
# Este script de sólo lectura audita la configuración real de red y WireGuard
# sin alterar ningún archivo del sistema.
# Enmascara automáticamente claves privadas y genera un archivo de resultados.
# ==============================================================================

set -u

OUTPUT_FILE="${1:-/tmp/vps_diagnostic.txt}"

echo "============================================================"
echo "Iniciando auditoría de red e IPv6 en el VPS..."
echo "Los resultados se guardarán en: ${OUTPUT_FILE}"
echo "============================================================"

{
  print_header() {
    echo ""
    echo "=============================================================================="
    echo ">>> $1"
    echo "=============================================================================="
  }

  print_header "1. SISTEMA OPERATIVO Y KERNEL"
  if [ -f /etc/os-release ]; then
    cat /etc/os-release | grep -E '^(NAME|VERSION|ID|VERSION_ID)='
  fi
  echo "Kernel: $(uname -r)"
  echo "Arquitectura: $(uname -m)"

  print_header "2. INTERFACES DE RED (ESTADO FÍSICO / VIRTUAL)"
  ip -br link

  print_header "3. DIRECCIONES IP ASIGNADAS (IPv4 e IPv6)"
  echo "--- IPv4 ---"
  ip -4 -o addr show | awk '{print $2, $3, $4}'
  echo "--- IPv6 ---"
  ip -6 -o addr show | awk '{print $2, $3, $4, $6}'

  print_header "4. TABLAS DE ENRUTAMIENTO (GATEWAYS)"
  echo "--- Rutas IPv4 ---"
  ip -4 route show
  echo "--- Rutas IPv6 ---"
  ip -6 route show

  print_header "5. PRUEBAS DE CONECTIVIDAD IPv6 DESDE EL VPS"
  echo -n "Prueba 1 (Ping a Cloudflare DNS 2606:4700:4700::1111): "
  if ping6 -c 2 -W 2 2606:4700:4700::1111 > /dev/null 2>&1; then
    echo "EXITOSA"
  else
    echo "FALLIDA"
  fi

  echo -n "Prueba 2 (Ping a Google DNS 2001:4860:4860::8888): "
  if ping6 -c 2 -W 2 2001:4860:4860::8888 > /dev/null 2>&1; then
    echo "EXITOSA"
  else
    echo "FALLIDA"
  fi

  echo -n "Prueba 3 (Curl IPv6 api64.ipify.org - salida pública): "
  CURL_IPV6=$(curl -6 -m 4 -s https://api64.ipify.org 2>/dev/null || echo "TIMEOUT/ERROR")
  echo "${CURL_IPV6}"

  echo "Ruta exacta usada hacia 2606:4700:4700::1111:"
  ip -6 route get 2606:4700:4700::1111 2>/dev/null || echo "No hay ruta a 2606:4700:4700::1111"

  print_header "6. PARÁMETROS SYSCTL (FORWARDING Y ACCEPT_RA)"
  sysctl net.ipv4.ip_forward 2>/dev/null || true
  sysctl net.ipv6.conf.all.forwarding 2>/dev/null || true
  sysctl net.ipv6.conf.default.forwarding 2>/dev/null || true
  sysctl -a 2>/dev/null | grep -E 'net\.ipv6\.conf\..*\.accept_ra' || true

  print_header "7. ESTADO DE FIREWALL (UFW / IPTABLES / IP6TABLES / NFTABLES)"
  if command -v ufw >/dev/null 2>&1; then
    echo "--- UFW Status ---"
    ufw status verbose 2>/dev/null || true
  fi

  echo "--- iptables (IPv4 NAT) ---"
  if command -v iptables >/dev/null 2>&1; then
    iptables -t nat -S 2>/dev/null || true
    echo "--- iptables (IPv4 FORWARD) ---"
    iptables -S FORWARD 2>/dev/null || true
  fi

  echo "--- ip6tables (IPv6 NAT) ---"
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t nat -S 2>/dev/null || true
    echo "--- ip6tables (IPv6 FORWARD) ---"
    ip6tables -S FORWARD 2>/dev/null || true
  fi

  echo "--- nftables ruleset (primeras 30 líneas) ---"
  if command -v nft >/dev/null 2>&1; then
    nft list ruleset 2>/dev/null | head -n 30 || echo "Sin reglas nftables activas o no disponible"
  fi

  print_header "8. CONFIGURACIÓN ACTUAL DE PIVPN (setupVars.conf)"
  SETUPVARS="/etc/pivpn/wireguard/setupVars.conf"
  if [ -f "${SETUPVARS}" ]; then
    cat "${SETUPVARS}"
  else
    echo "No se encontró ${SETUPVARS}"
  fi

  print_header "9. CONFIGURACIÓN SERVIDOR WIREGUARD (wg0.conf - CLAVES ENMASCARADAS)"
  WGCONF="/etc/wireguard/wg0.conf"
  if [ -f "${WGCONF}" ]; then
    sed -E 's/(PrivateKey|PresharedKey)\s*=\s*.*/\1 = [ENMASCARADO]/' "${WGCONF}"
  else
    echo "No se encontró ${WGCONF}"
  fi

  print_header "10. ESTADO DE WIREGUARD EN EJECUCIÓN (wg show - CLAVES ENMASCARADAS)"
  if command -v wg >/dev/null 2>&1; then
    wg show 2>/dev/null | sed -E 's/(private key|preshared key):\s*.*/\1: [ENMASCARADO]/' || echo "WireGuard wg0 no está activo o requiere root"
  else
    echo "Comando wg no instalado"
  fi

  print_header "11. CLIENTES REGISTRADOS EN PIVPN"
  CLIENTS_FILE="/etc/wireguard/configs/clients.txt"
  if [ -f "${CLIENTS_FILE}" ]; then
    cat "${CLIENTS_FILE}"
  else
    echo "No se encontró ${CLIENTS_FILE}"
  fi

  print_header "12. RESOLUCIÓN DNS DEL SISTEMA"
  if [ -f /etc/resolv.conf ]; then
    cat /etc/resolv.conf | grep -E '^(nameserver|search)'
  fi

  print_header "FIN DE LA AUDITORÍA"
} > "${OUTPUT_FILE}" 2>&1

chmod 644 "${OUTPUT_FILE}"

echo "============================================================"
echo "Auditoría finalizada con éxito."
echo "Archivo generado: ${OUTPUT_FILE}"
echo "Tamaño: $(wc -l < "${OUTPUT_FILE}") líneas"
echo "============================================================"
