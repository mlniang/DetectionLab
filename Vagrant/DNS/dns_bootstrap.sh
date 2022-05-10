#! /usr/bin/env bash

# This is the script that is used to provision the logger host

# Override existing DNS Settings using netplan, but don't do it for Terraform AWS builds
if ! curl -s 169.254.169.254 --connect-timeout 2 >/dev/null; then
  echo -e "    eth1:\n      dhcp4: true\n      nameservers:\n        addresses: [1.1.1.1,1.0.0.1]" >>/etc/netplan/01-netcfg.yaml
  netplan apply
fi

rm /etc/resolv.conf
echo -e 'nameserver 1.1.1.1\nnameserver 1.0.0.1' > /etc/resolv.conf && chattr +i /etc/resolv.conf

# Source variables from dns_variables.sh
# shellcheck disable=SC1091
source /vagrant/DNS/dns_variables.sh 2>/dev/null || source /home/vagrant/DNS/dns_variables.sh 2>/dev/null || echo "Unable to locate dns_variables.sh"

if [ -z "$POWERADMIN_VERSION" ]; then
  echo "Note: You have not entered a PowerAdmin version in dns_variables.sh, so defaulting to v2.2.2"
  export POWERADMIN_VERSION="2.2.2"
fi

export DEBIAN_FRONTEND=noninteractive
echo "apt-fast apt-fast/maxdownloads string 10" | debconf-set-selections
echo "apt-fast apt-fast/dlflag boolean true" | debconf-set-selections

if ! grep 'mirrors.ubuntu.com/mirrors.txt' /etc/apt/sources.list; then
  sed -i "2ideb mirror://mirrors.ubuntu.com/mirrors.txt focal main restricted universe multiverse\ndeb mirror://mirrors.ubuntu.com/mirrors.txt focal-updates main restricted universe multiverse\ndeb mirror://mirrors.ubuntu.com/mirrors.txt focal-backports main restricted universe multiverse\ndeb mirror://mirrors.ubuntu.com/mirrors.txt focal-security main restricted universe multiverse" /etc/apt/sources.list
fi

apt_install_prerequisites() {
  echo "[$(date +%H:%M:%S)]: Adding apt-get repositories..."
  # Add repository for apt-fast
  add-apt-repository -y -n ppa:apt-fast/stable 
  # Add repository for PowerDNS
  echo 'deb [arch=amd64] http://repo.powerdns.com/ubuntu focal-auth-master main' > /etc/apt/sources.list.d/pdns.list
  echo -e 'Package: pdns-*\nPin: origin repo.powerdns.com\nPin-Priority: 600' > /etc/apt/preferences.d/pdns
  curl https://repo.powerdns.com/CBC8B383-pub.asc | sudo apt-key add -
  # Install prerequisites and useful tools
  echo "[$(date +%H:%M:%S)]: Running apt-get clean..."
  apt-get clean
  echo "[$(date +%H:%M:%S)]: Running apt-get update..."
  apt-get -qq update
  echo "[$(date +%H:%M:%S)]: Installing apt-fast..."
  apt-get -qq install -y apt-fast
  echo "[$(date +%H:%M:%S)]: Using apt-fast to install packages..."
  apt-fast install -y sqlite3 unzip apache2 php7.4 libapache2-mod-php7.4
}

modify_motd() {
  echo "[$(date +%H:%M:%S)]: Updating the MOTD..."
  # Force color terminal
  sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/g' /root/.bashrc
  sed -i 's/#force_color_prompt=yes/force_color_prompt=yes/g' /home/vagrant/.bashrc
  # Remove some stock Ubuntu MOTD content
  chmod -x /etc/update-motd.d/10-help-text
  # Copy the DetectionLab MOTD
  cp /vagrant/resources/logger/20-detectionlab /etc/update-motd.d/
  chmod +x /etc/update-motd.d/20-detectionlab
}

test_prerequisites() {
  for package in sqlite3 unzip apache2 php libapache2-mod-php; do
    echo "[$(date +%H:%M:%S)]: [TEST] Validating that $package is correctly installed..."
    # Loop through each package using dpkg
    if ! dpkg -S $package >/dev/null; then
      # If which returns a non-zero return code, try to re-install the package
      echo "[-] $package was not found. Attempting to reinstall."
      apt-get -qq update && apt-get install -y $package
      if ! which $package >/dev/null; then
        # If the reinstall fails, give up
        echo "[X] Unable to install $package even after a retry. Exiting."
        exit 1
      fi
    else
      echo "[+] $package was successfully installed!"
    fi
  done
}

fix_eth1_static_ip() {
  USING_KVM=$(sudo lsmod | grep kvm)
  if [ -n "$USING_KVM" ]; then
    echo "[*] Using KVM, no need to fix DHCP for eth1 iface"
    return 0
  fi
  if [ -f /sys/class/net/eth2/address ]; then
    if [ "$(cat /sys/class/net/eth2/address)" == "00:50:56:a3:b1:c4" ]; then
      echo "[*] Using ESXi, no need to change anything"
      return 0
    fi
  fi
  # There's a fun issue where dhclient keeps messing with eth1 despite the fact
  # that eth1 has a static IP set. We workaround this by setting a static DHCP lease.
  if ! grep 'interface "eth1"' /etc/dhcp/dhclient.conf; then
    echo -e 'interface "eth1" {
      send host-name = gethostname();
      send dhcp-requested-address 192.168.56.101;
    }' >>/etc/dhcp/dhclient.conf
    netplan apply
  fi

  # Fix eth1 if the IP isn't set correctly
  ETH1_IP=$(ip -4 addr show eth1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
  if [ "$ETH1_IP" != "192.168.56.101" ]; then
    echo "Incorrect IP Address settings detected. Attempting to fix."
    ip link set dev eth1 down
    ip addr flush dev eth1
    ip link set dev eth1 up
    ETH1_IP=$(ip -4 addr show eth1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [ "$ETH1_IP" == "192.168.56.101" ]; then
      echo "[$(date +%H:%M:%S)]: The static IP has been fixed and set to 192.168.56.101"
    else
      echo "[$(date +%H:%M:%S)]: Failed to fix the broken static IP for eth1. Exiting because this will cause problems with other VMs."
      exit 1
    fi
  fi

  # Make sure we do have a DNS resolution
  while true; do
    if [ "$(dig +short @1.1.1.1 github.com)" ]; then break; fi
    sleep 1
  done
}

install_powerdns() {
  echo "[$(date +%H:%M:%S)]: Disabling systemd-resolved..."
  systemctl disable --now systemd-resolved
  echo "[$(date +%H:%M:%S)]: Installing PowerDNS..."
  apt-fast install -y pdns-server pdns-backend-bind pdns-backend-remote pdns-backend-sqlite3
  sed -i 's/^launch=/launch=gsqlite3\ngsqlite3-database=\/var\/lib\/powerdns\/pdns.sqlite3/' /etc/powerdns/pdns.conf
  sqlite3 /var/lib/powerdns/pdns.sqlite3 < /usr/share/doc/pdns-backend-sqlite3/schema.sqlite3.sql
  chown -R pdns:pdns /var/lib/powerdns
  chmod g+w /var/lib/powerdns/pdns.sqlite3*
  usermod -aG pdns www-data
  a2enmod rewrite
  systemctl restart apache2
  systemctl restart pdns
}

install_poweradmin() {
  echo "[$(date +%H:%M:%S)]: Installing poweradmin..."
  apt-fast install -y php-intl php-sqlite3
  if [ -d /var/www/html ] ; then
    rm -rf /var/www/html
  else
    mkdir -p /var/www
  fi
  cd /var/www
  wget "https://github.com/poweradmin/poweradmin/archive/refs/tags/v$POWERADMIN_VERSION.zip"
  unzip "v$POWERADMIN_VERSION.zip"
  rm "v$POWERADMIN_VERSION.zip"
  mv "poweradmin-$POWERADMIN_VERSION" html
  chown -R www-data:www-data /var/www/html/
  systemctl restart apache2
  echo "[$(date +%H:%M:%S)]: Configuring poweradmin..."
  curl -s -XPOST -d 'user=&pass=&type=sqlite&host=&dbport=&name=%2Fvar%2Flib%2Fpowerdns%2Fpdns.sqlite3&charset=&collation=&pa_pass=password&step=4&language=en_EN&submit=Go+to+step+4' http://localhost/install/ > /dev/null
  curl -s -XPOST -d 'dns_hostmaster=hostmaster.dns&dns_ns1=ns1.dns&dns_ns2=ns2.dns&db_user=&db_pass=&db_host=&db_port=5432&db_name=%2Fvar%2Flib%2Fpowerdns%2Fpdns.sqlite3&db_type=sqlite&db_charset=&pa_pass=password&step=5&language=en_EN&submit=Go+to+step+5' http://localhost/install/ > /dev/null
  cat << 'EOF' > /var/www/html/inc/config.inc.php
<?php
$db_file = '/var/lib/powerdns/pdns.sqlite3';
$db_user = '';
$db_pass = '';
$db_type = 'sqlite';

$session_key = 'OvUp1GuW07oyFlXNXA(GtRFCDjgJGk1iPO9yHYU1iheW$4';

$iface_lang = 'en_EN';

$dns_hostmaster = 'hostmaster.dns';
$dns_ns1 = 'ns1.dns';
$dns_ns2 = 'ns2.dns';
EOF
  cp /var/www/html/install/htaccess.dist /var/www/html/.htaccess
  rm -rf /var/www/html/install
  chown -R www-data:www-data /var/www/html/
  systemctl restart apache2
}

postinstall_tasks() {
  # Include Splunk and Zeek in the PATH
  echo export PATH="$PATH:/opt/splunk/bin:/opt/zeek/bin" >>~/.bashrc
  echo "export SPLUNK_HOME=/opt/splunk" >>~/.bashrc
  # Ping DetectionLab server for usage statistics
  curl -s -A "DetectionLab-logger" "https:/ping.detectionlab.network/logger" || echo "Unable to connect to ping.detectionlab.network"
}

main() {
  apt_install_prerequisites
  modify_motd
  test_prerequisites
  fix_eth1_static_ip
  install_powerdns
  install_poweradmin
  #postinstall_tasks
}

# Allow custom modes via CLI args
if [ -n "$1" ]; then
  eval "$1"
else
  main
fi
exit 0
