#!/usr/bin/env bash
# ==============================================================================
# PiVPN: Gestión de Regla NAT66 con nftables nativo
# ==============================================================================
# Este script permite aplicar, verificar o revertir la regla de NAT66 (Masquerade)
# en nftables para salida IPv6 en WireGuard.
# ==============================================================================

set -euo pipefail

WAN_IF="${1:-eth0}"
WG_NETV6="${2:-fd11:5ee:bad:c0de::/64}"

usage() {
  echo "Uso: $0 [interfaz_wan] [subred_ipv6]"
  echo "Ejemplo: $0 eth0 fd11:5ee:bad:c0de::/64"
  echo ""
  echo "Acciones:"
  echo "  --status   Verifica si la regla existe en nftables"
  echo "  --apply    Aplica la regla en nftables"
  echo "  --remove   Elimina la regla en nftables"
}

check_rule() {
  if nft list table ip6 nat 2>/dev/null | grep -q "fd11:5ee:bad:c0de::/64.*masquerade"; then
    echo ":: [OK] Regla NAT66 activa en tabla 'ip6 nat':"
    nft list table ip6 nat | grep -E "masquerade"
    return 0
  elif nft list table inet pivpn 2>/dev/null | grep -q "masquerade"; then
    echo ":: [OK] Regla NAT66 activa en tabla 'inet pivpn':"
    nft list table inet pivpn | grep -E "masquerade"
    return 0
  else
    echo ":: [INFO] No se encontró regla NAT66 específica para WireGuard en nftables."
    return 1
  fi
}

apply_rule() {
  echo "::: Aplicando regla NAT66 en nftables (interfaz: ${WAN_IF}, subred: ${WG_NETV6})..."
  
  # Si ya existe la tabla ip6 nat (como en Debian con iptables-nft/Docker)
  if nft list tables | grep -qw "table ip6 nat"; then
    # Verificar si la regla ya está insertada
    if ! nft list table ip6 nat | grep -q "${WG_NETV6}.*masquerade"; then
      nft add rule ip6 nat POSTROUTING oifname "${WAN_IF}" ip6 saddr "${WG_NETV6}" masquerade
      echo ":: [OK] Regla agregada a la cadena POSTROUTING de la tabla 'ip6 nat'."
    else
      echo ":: [OK] La regla ya estaba presente en 'ip6 nat'."
    fi
  else
    # Crear una tabla inet dedicada para PiVPN sin interferir con otras
    nft add table inet pivpn
    nft add chain inet pivpn postrouting '{ type nat hook postrouting priority 100; policy accept; }'
    nft add rule inet pivpn postrouting oifname "${WAN_IF}" ip6 saddr "${WG_NETV6}" masquerade
    echo ":: [OK] Creada tabla 'inet pivpn' con regla postrouting masquerade."
  fi
}

remove_rule() {
  echo "::: Retirando regla NAT66 de nftables..."
  if nft list table inet pivpn >/dev/null 2>&1; then
    nft delete table inet pivpn
    echo ":: [OK] Eliminada tabla 'inet pivpn'."
  fi
}

ACTION="${1:---apply}"

case "${ACTION}" in
  --status)
    check_rule
    ;;
  --remove)
    remove_rule
    ;;
  --apply)
    apply_rule
    ;;
  -h|--help)
    usage
    ;;
  *)
    apply_rule
    ;;
esac
