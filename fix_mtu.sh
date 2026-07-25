#!/bin/bash
# Чинит совместимость с VPN: ограничивает размер TCP-сегментов (MSS-clamping),
# чтобы TLS-рукопожатие не рвалось через туннели с меньшим MTU.
set -e
export DEBIAN_FRONTEND=noninteractive

MSS=1360
# добавить правило, если его ещё нет
if ! iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS 2>/dev/null; then
  iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss $MSS
fi

# сохранить, чтобы пережило перезагрузку
apt-get install -y iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
mkdir -p /etc/iptables
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true

echo "=== MSS-clamping ($MSS) установлен ==="
iptables -t mangle -L POSTROUTING -n | grep -i tcpmss || echo "(правило не показалось — проверь вручную)"
