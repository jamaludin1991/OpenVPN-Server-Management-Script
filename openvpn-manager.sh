#!/bin/bash
# OpenVPN Server Management Script
# Oleh: Jamaludin1991

EASY_RSA_DIR="/etc/openvpn/easy-rsa"
SERVER_NAME="ovpn.yourdomain.com"
PUBLIC_IP="yourpublicip"
SERVER_IP="yourlocalip"
VPN_NET="10.8.0.0 255.255.255.0"
CLIENT_DIR="/etc/openvpn/clients"
CRON_JOB_PATH="/etc/cron.d/openvpn_auto_renew"

declare -a ROUTES=(
  "192.168.0.0 255.255.255.0"
)

install_openvpn() {
  # Update sistem
  apt update && apt upgrade -y
  
  # Install dependensi
  apt install -y openvpn easy-rsa iptables-persistent curl
  
  # Setup Easy-RSA
  make-cadir $EASY_RSA_DIR
  cd $EASY_RSA_DIR
  
  # Konfigurasi PKI
  cat > vars <<EOF
set_var EASYRSA_REQ_COUNTRY "ID"
set_var EASYRSA_REQ_PROVINCE "youtprovince"
set_var EASYRSA_REQ_CITY "yourcity"
set_var EASYRSA_REQ_ORG "yourorg"
set_var EASYRSA_REQ_EMAIL "youremail"
set_var EASYRSA_REQ_OU "OpenVPN"
set_var EASYRSA_ALGO "ec"
set_var EASYRSA_DIGEST "sha512"
set_var EASYRSA_KEY_SIZE 4096
set_var EASYRSA_CA_EXPIRE 3650
set_var EASYRSA_CERT_EXPIRE 1080
EOF

  # Inisialisasi PKI
  ./easyrsa init-pki
  ./easyrsa build-ca nopass
  ./easyrsa gen-dh
  
  # Generate server certificate
  ./easyrsa build-server-full server nopass
  
  # Generate CRL
  ./easyrsa gen-crl

  # Buat direktori OpenVPN
  mkdir -p /etc/openvpn/server
  cp pki/ca.crt /etc/openvpn/server/
  cp pki/issued/server.crt /etc/openvpn/server/
  cp pki/private/server.key /etc/openvpn/server/
  cp pki/dh.pem /etc/openvpn/server/
  cp pki/crl.pem /etc/openvpn/server/

  # Konfigurasi server OpenVPN
  cat > /etc/openvpn/server/server.conf <<EOF
port 1194
proto udp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
topology subnet
server 10.8.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
keepalive 10 120
cipher AES-256-GCM
auth SHA512
tls-version-min 1.2
tls-crypt tls-crypt.key
crl-verify crl.pem
persist-key
persist-tun
status /var/log/openvpn-status.log
verb 3
explicit-exit-notify 1
EOF

  # Tambahkan rute
  for route in "${ROUTES[@]}"; do
    echo "push \"route $route\"" >> /etc/openvpn/server/server.conf
  done

  # Generate TLS Crypt key
  openvpn --genkey secret /etc/openvpn/server/tls-crypt.key

  # Enable IP forwarding
  sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
  sysctl -p

  # Konfigurasi firewall
  iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j MASQUERADE
  iptables-save > /etc/iptables/rules.v4

  # Buat direktori client
  mkdir -p $CLIENT_DIR

  # Enable dan start service
  systemctl enable --now openvpn-server@server.service

  # Setup auto renewal
  cat > $CRON_JOB_PATH <<EOF
0 0 * * * root /usr/bin/bash $0 renew_cert
EOF

  echo "Installasi selesai!"
}

add_client() {
  if [ -z "$1" ]; then
    echo "Usage: $0 addclient <client-name>"
    exit 1
  fi

  CLIENT_NAME=$1
  cd $EASY_RSA_DIR
  
  ./easyrsa gen-req $CLIENT_NAME nopass
  ./easyrsa sign-req client $CLIENT_NAME

  mkdir -p $CLIENT_DIR/$CLIENT_NAME
  cp pki/issued/$CLIENT_NAME.crt $CLIENT_DIR/$CLIENT_NAME/
  cp pki/private/$CLIENT_NAME.key $CLIENT_DIR/$CLIENT_NAME/

  cat > $CLIENT_DIR/$CLIENT_NAME/$CLIENT_NAME.ovpn <<EOF
client
dev tun
proto udp
remote $PUBLIC_IP 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher AES-256-GCM
auth SHA512
verb 3
<ca>
$(cat /etc/openvpn/server/ca.crt)
</ca>
<cert>
$(cat $CLIENT_DIR/$CLIENT_NAME/$CLIENT_NAME.crt)
</cert>
<key>
$(cat $CLIENT_DIR/$CLIENT_NAME/$CLIENT_NAME.key)
</key>
<tls-crypt>
$(cat /etc/openvpn/server/tls-crypt.key)
</tls-crypt>
EOF

  echo "Client $CLIENT_NAME berhasil dibuat!"
  echo "Config file: $CLIENT_DIR/$CLIENT_NAME/$CLIENT_NAME.ovpn"
}

remove_client() {
  if [ -z "$1" ]; then
    echo "Usage: $0 removeclient <client-name>"
    exit 1
  fi

  CLIENT_NAME=$1
  cd $EASY_RSA_DIR
  
  ./easyrsa revoke $CLIENT_NAME
  ./easyrsa gen-crl
  cp pki/crl.pem /etc/openvpn/server/
  
  rm -rf $CLIENT_DIR/$CLIENT_NAME
  systemctl restart openvpn-server@server.service
  
  echo "Client $CLIENT_NAME berhasil dihapus!"
}

list_clients() {
  echo "Daftar Client Terdaftar:"
  ls -1 $CLIENT_DIR
}

renew_cert() {
  cd $EASY_RSA_DIR
  ./easyrsa renew-crl
  cp pki/crl.pem /etc/openvpn/server/
  
  # Auto renew server cert 30 hari sebelum expired
  SERVER_CERT_EXPIRE=$(openssl x509 -in /etc/openvpn/server/server.crt -noout -enddate | cut -d= -f2)
  SERVER_CERT_EPOCH=$(date -d "$SERVER_CERT_EXPIRE" +%s)
  CURRENT_EPOCH=$(date +%s)
  DAYS_LEFT=$(( (SERVER_CERT_EPOCH - CURRENT_EPOCH) / 86400 ))
  
  if [ $DAYS_LEFT -lt 30 ]; then
    ./easyrsa renew server nopass
    systemctl restart openvpn-server@server.service
    echo "Sertifikat server diperbarui"
  fi
}

uninstall_openvpn() {
  systemctl stop openvpn-server@server.service
  apt purge -y openvpn easy-rsa iptables-persistent
  rm -rf /etc/openvpn
  rm -rf $EASY_RSA_DIR
  rm -f $CRON_JOB_PATH
  iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -j MASQUERADE
  iptables-save > /etc/iptables/rules.v4
  sed -i 's/net.ipv4.ip_forward=1/#net.ipv4.ip_forward=1/' /etc/sysctl.conf
  sysctl -p
  echo "OpenVPN berhasil diuninstall"
}

case "$1" in
  install)
    install_openvpn
    ;;
  addclient)
    add_client "$2"
    ;;
  removeclient)
    remove_client "$2"
    ;;
  listclients)
    list_clients
    ;;
  renew_cert)
    renew_cert
    ;;
  uninstall)
    uninstall_openvpn
    ;;
  *)
    echo "Verifikasi Script OpenVPN Management"
    echo "Penggunaan: $0 [install|addclient|removeclient|listclients|renew_cert|uninstall]"
    exit 1
    ;;
esac
