#!/bin/bash

### Constants
PLAT="$(grep -sEe '^NAME=' /etc/os-release \
  | sed -E -e "s/NAME=[\'\"]?([^ ]*).*/\1/")"

# dual protocol, VPN type supplied as $1
VPN="${1}"
setupVars="/etc/pivpn/${VPN}/setupVars.conf"
ERR=0

### Functions
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

### Script
if [[ ! -f "${setupVars}" ]]; then
  err "::: Missing setup vars file!"
  exit 1
fi

# SC1090 disabled as setupVars file differs from system to system
# shellcheck disable=SC1090
source "${setupVars}"

if [[ "${VPN}" == "wireguard" ]]; then
  VPN_PRETTY_NAME="WireGuard"
  VPN_SERVICE="wg-quick@wg0"

  if [[ "${PLAT}" == 'Alpine' ]]; then
    VPN_SERVICE='wg-quick'
  fi
elif [[ "${VPN}" == "openvpn" ]]; then
  VPN_SERVICE="openvpn"
  VPN_PRETTY_NAME="OpenVPN"
fi

if [[ "$(< /proc/sys/net/ipv4/ip_forward)" -eq 1 ]]; then
  echo ":: [OK] IP forwarding is enabled"
else
  ERR=1
  read -r \
    -p ":: [ERR] IP forwarding is not enabled, attempt fix now? [Y/n] " \
    REPLY

  if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
    sed -i '/net.ipv4.ip_forward=1/s/^#//g' /etc/sysctl.d/99-pivpn.conf
    sysctl -p
    echo "Done"
  fi
fi

if [[ "${pivpnenableipv6-0}" -eq 1 ]]; then
  if [[ -f /proc/sys/net/ipv6/conf/all/forwarding ]] && [[ "$(< /proc/sys/net/ipv6/conf/all/forwarding)" -eq 1 ]]; then
    echo ":: [OK] IPv6 forwarding is enabled"
  else
    ERR=1
    read -r \
      -p ":: [ERR] IPv6 forwarding is not enabled, attempt fix now? [Y/n] " \
      REPLY

    if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
      echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-pivpn.conf
      echo "net.ipv6.conf.default.forwarding=1" >> /etc/sysctl.d/99-pivpn.conf
      sysctl -p /etc/sysctl.d/99-pivpn.conf
      echo "Done"
    fi
  fi
fi

if [[ "${USING_UFW}" -eq 0 ]]; then
  # Disabled SC Warnings for SC2154, values
  # for variables are sourced from setupVars
  # shellcheck disable=SC2154
  if iptables \
    -t nat \
    -C POSTROUTING \
    -s "${pivpnNET}/${subnetClass}" \
    -o "${IPv4dev}" \
    -j MASQUERADE \
    -m comment \
    --comment "${VPN}-nat-rule" &> /dev/null; then
    echo ":: [OK] Iptables MASQUERADE rule set"
  else
    ERR=1
    echo -n ":: [ERR] Iptables MASQUERADE rule is not set, "
    echo -n "attempt fix now? [Y/n] "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
      iptables \
        -t nat \
        -I POSTROUTING \
        -s "${pivpnNET}/${subnetClass}" \
        -o "${IPv4dev}" \
        -j MASQUERADE \
        -m comment \
        --comment "${VPN}-nat-rule"

      iptables-save > /etc/iptables/rules.v4
      echo "Done"
    fi
  fi

  if [[ "${INPUT_CHAIN_EDITED}" -eq 1 ]]; then
    # Disabled SC Warnings for SC2154, values
    # for variables are sourced from setupVars
    # shellcheck disable=SC2154
    if iptables \
      -C INPUT \
      -i "${IPv4dev}" \
      -p "${pivpnPROTO}" \
      --dport "${pivpnPORT}" \
      -j ACCEPT \
      -m comment \
      --comment "${VPN}-input-rule" &> /dev/null; then
      echo ":: [OK] Iptables INPUT rule set"
    else
      ERR=1
      read -r \
        -p ":: [ERR] Iptables INPUT rule is not set, attempt fix now? [Y/n] " \
        REPLY

      if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
        iptables \
          -I INPUT 1 \
          -i "${IPv4dev}" \
          -p "${pivpnPROTO}" \
          --dport "${pivpnPORT}" \
          -j ACCEPT \
          -m comment \
          --comment "${VPN}-input-rule"

        iptables-save > /etc/iptables/rules.v4
        echo "Done"
      fi
    fi
  fi

  if [[ "${FORWARD_CHAIN_EDITED}" -eq 1 ]]; then
    # Disabled SC Warnings for SC2154, values
    # for variables are sourced from setupVars
    # shellcheck disable=SC2154
    if iptables \
      -C FORWARD \
      -s "${pivpnNET}/${subnetClass}" \
      -i "${pivpnDEV}" \
      -o "${IPv4dev}" \
      -j ACCEPT \
      -m comment \
      --comment "${VPN}-forward-rule" &> /dev/null; then
      echo ":: [OK] Iptables FORWARD rule set"
    else
      ERR=1
      echo -n ":: [ERR] Iptables FORWARD rule is not set, "
      echo -n "attempt fix now? [Y/n] "
      read -r REPLY

      if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
        iptables \
          -I FORWARD 1 \
          -d "${pivpnNET}/${subnetClass}" \
          -i "${IPv4dev}" \
          -o "${pivpnDEV}" \
          -m conntrack \
          --ctstate RELATED,ESTABLISHED \
          -j ACCEPT \
          -m comment \
          --comment "${VPN}-forward-rule"

        iptables \
          -I FORWARD 2 \
          -s "${pivpnNET}/${subnetClass}" \
          -i "${pivpnDEV}" \
          -o "${IPv4dev}" \
          -j ACCEPT \
          -m comment \
          --comment "${VPN}-forward-rule"

        iptables-save > /etc/iptables/rules.v4
        echo "Done"
      fi
    fi
  fi
else
  if LANG="en_US.UTF-8" ufw status | grep -qw 'active'; then
    echo ":: [OK] Ufw is enabled"
  else
    ERR=1
    echo -n ":: [ERR] Ufw is not enabled, "
    echo -n "try to enable now? [Y/n] "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
      ufw enable
    fi
  fi

  if iptables \
    -t nat \
    -C POSTROUTING \
    -s "${pivpnNET}/${subnetClass}" \
    -o "${IPv4dev}" \
    -j MASQUERADE \
    -m comment \
    --comment "${VPN}-nat-rule" &> /dev/null; then
    echo ":: [OK] Iptables MASQUERADE rule set"
  else
    ERR=1
    echo -n ":: [ERR] Iptables MASQUERADE rule is not set, "
    echo -n "attempt fix now? [Y/n] "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
      sed_pattern='/delete these required/i'
      sed_pattern="${sed_pattern} *nat\n:POSTROUTING ACCEPT [0:0]\n"
      sed_pattern="${sed_pattern} -I POSTROUTING"
      sed_pattern="${sed_pattern} -s ${pivpnNET}/${subnetClass}"
      sed_pattern="${sed_pattern} -o ${IPv4dev}"
      sed_pattern="${sed_pattern} -j MASQUERADE"
      sed_pattern="${sed_pattern} -m comment"
      sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule\n"
      sed_pattern="${sed_pattern}COMMIT\n"

      sed "${sed_pattern}" -i /etc/ufw/before.rules
      ufw reload
      echo "Done"
      unset sed_pattern
    fi
  fi

  if [[ "${pivpnenableipv6-0}" -eq 1 ]]; then
    if grep -q "fd11:5ee:bad:c0de::/64.*MASQUERADE\|${pivpnNETv6-fd11:5ee:bad:c0de::}.*MASQUERADE" /etc/ufw/before6.rules 2>/dev/null \
      || ip6tables -t nat -C POSTROUTING -s "${pivpnNETv6}/${subnetClassv6}" -o "${IPv6dev}" -j MASQUERADE &> /dev/null \
      || (command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -q "${pivpnNETv6}.*masquerade"); then
      echo ":: [OK] Ufw IPv6 MASQUERADE rule set"
    else
      ERR=1
      echo -n ":: [ERR] Ufw IPv6 MASQUERADE rule is not set, attempt fix now? [Y/n] "
      read -r REPLY

      if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
        sed -i '1i # NAT IPv6 para WireGuard\n*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s '"${pivpnNETv6}"'/'"${subnetClassv6}"' -o '"${IPv6dev}"' -j MASQUERADE\nCOMMIT\n' /etc/ufw/before6.rules
        ufw reload
        echo "Done"
      fi
    fi
  fi

  if iptables \
    -C ufw-user-input \
    -p "${pivpnPROTO}" \
    --dport "${pivpnPORT}" \
    -j ACCEPT &> /dev/null; then
    echo ":: [OK] Ufw input rule set"
  else
    ERR=1
    read -r \
      -p ":: [ERR] Ufw input rule is not set, attempt fix now? [Y/n] " \
      REPLY

    if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
      ufw insert 1 allow "${pivpnPORT}"/"${pivpnPROTO}"
      ufw reload
      echo "Done"
    fi
  fi

  if iptables \
    -C ufw-user-forward \
    -i "${pivpnDEV}" \
    -o "${IPv4dev}" \
    -s "${pivpnNET}/${subnetClass}" \
    -j ACCEPT &> /dev/null; then
    echo ":: [OK] Ufw forwarding rule set"
  else
    ERR=1
    read -r \
      -p ":: [ERR] Ufw forwarding rule is not set, attempt fix now? [Y/n] " \
      REPLY

    if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
      ufw route insert 1 allow in on "${pivpnDEV}" \
        from "${pivpnNET}/${subnetClass}" out on "${IPv4dev}" to any
      ufw reload
      echo "Done"
    fi
  fi
fi

if [[ "${PLAT}" == 'Alpine' ]]; then
  if [[ "$(rc-service "${VPN_SERVICE}" status \
    | sed -E -e 's/.*status\: (.*)/\1/')" == 'started' ]]; then
    echo ":: [OK] ${VPN_PRETTY_NAME} is running"
  else
    ERR=1
    echo -n ":: [ERR] ${VPN_PRETTY_NAME} is not running, "
    echo -n "try to start now? [Y/n] "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
      rc-service -s "${VPN_SERVICE}" restart
      rc-service -N "${VPN_SERVICE}" start
      echo "Done"
    fi
  fi

  if rc-update show default \
    | grep -sEe "\s*${VPN_SERVICE} .*" &> /dev/null; then
    echo -n ":: [OK] ${VPN_PRETTY_NAME} is enabled "
    echo "(it will automatically start on reboot)"
  else
    ERR=1
    echo -n ":: [ERR] ${VPN_PRETTY_NAME} is not enabled, "
    echo -n "try to enable now? [Y/n] "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
      rc-update add "${VPN_SERVICE}" default
      echo "Done"
    fi
  fi
else
  if systemctl is-active -q "${VPN_SERVICE}"; then
    echo ":: [OK] ${VPN_PRETTY_NAME} is running"
  else
    ERR=1
    echo -n ":: [ERR] ${VPN_PRETTY_NAME} is not running, "
    echo -n "try to start now? [Y/n] "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
      systemctl start "${VPN_SERVICE}"
      echo "Done"
    fi
  fi

  if systemctl is-enabled -q "${VPN_SERVICE}"; then
    echo ":: [OK] ${VPN_PRETTY_NAME} is enabled "
    echo "(it will automatically start on reboot)"
  else
    ERR=1
    echo -n ":: [ERR] ${VPN_PRETTY_NAME} is not enabled, "
    echo -n "try to enable now? [Y/n] "
    read -r REPLY

    if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
      systemctl enable "${VPN_SERVICE}"
      echo "Done"
    fi
  fi
fi

# grep -w (whole word) is used so port 11940 won't match when looking for 1194
if netstat -antu | grep -wqE "${pivpnPROTO}.*${pivpnPORT}"; then
  echo -n ":: [OK] ${VPN_PRETTY_NAME} is listening "
  echo "on port ${pivpnPORT}/${pivpnPROTO}"
else
  ERR=1
  echo -n ":: [ERR] ${VPN_PRETTY_NAME} is not listening, "
  echo -n "try to restart now? [Y/n] "
  read -r REPLY

  if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
    if [[ "${PLAT}" == 'Alpine' ]]; then
      rc-service -s "${VPN_SERVICE}" restart
      rc-service -N "${VPN_SERVICE}" start
    else
      systemctl restart "${VPN_SERVICE}"
    fi

    echo "Done"
  fi
fi

if [[ "${ERR}" -eq 1 ]]; then
  echo -e "[INFO] Run \e[1mpivpn -d\e[0m again to see if we detect issues"
fi
