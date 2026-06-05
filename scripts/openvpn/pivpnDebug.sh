#!/bin/bash
# Este script se ejecuta como root

### Constantes
setupVars="/etc/pivpn/openvpn/setupVars.conf"

# shellcheck disable=SC1090
source "${setupVars}"

### Funciones
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

### Script
if [[ ! -f "${setupVars}" ]]; then
  err "::: ¡Falta el archivo de variables de configuración!"
  exit 1
fi

echo -e "::::\t\t\e[4mDepuración de PiVPN\e[0m\t\t ::::"
printf "=============================================\n"
echo -e "::::\t\t\e[4mÚltimo commit\e[0m\t\t ::::"
echo -n "Rama: "

git --git-dir /usr/local/src/pivpn/.git rev-parse --abbrev-ref HEAD
git \
  --git-dir /usr/local/src/pivpn/.git log -n 1 \
  --format='Commit: %H%nAutor: %an%nFecha: %ad%nResumen: %s'

printf "=============================================\n"
echo -e "::::\t    \e[4mConfiguración de instalación\e[0m    \t ::::"

# shellcheck disable=SC2154
sed "s/${pivpnHOST}/REDACTADO/" < "${setupVars}"

printf "=============================================\n"
echo -e "::::  \e[4mConfiguración del servidor mostrada a continuación\e[0m   ::::"

cat /etc/openvpn/server.conf

printf "=============================================\n"
echo -e "::::  \e[4mArchivo de plantilla de cliente mostrado a continuación\e[0m   ::::"

sed "s/${pivpnHOST}/REDACTADO/" < /etc/openvpn/easy-rsa/pki/Default.txt

printf "=============================================\n"
echo -e ":::: \t\e[4mLista recursiva de archivos en\e[0m\t ::::\n"
echo -e "::: \e[4m/etc/openvpn/easy-rsa/pki mostrada a continuación\e[0m :::"

ls -LR /etc/openvpn/easy-rsa/pki/ -Ireqs -Icerts_by_serial

printf "=============================================\n"
echo -e "::::\t\t\e[4mAutocomprobación\e[0m\t\t ::::"

/opt/pivpn/self_check.sh "${VPN}"

printf "=============================================\n"
echo -e ":::: ¿Tienes problemas para conectarte? Echa un vistazo a las Preguntas Frecuentes:"
echo -e ":::: \e[1mhttps://docs.pivpn.io/faq\e[0m"
printf "=============================================\n"

if [[ "${PLAT}" != 'Alpine' ]]; then
  echo -e "::::      \e[4mFragmento del registro del servidor\e[0m      ::::"
  if [ -f /var/log/openvpn.log ]; then
    OVPNLOG="$(tail -n 20 /var/log/openvpn.log)"
  else
    OVPNLOG="$(journalctl -t ovpn-server -n 20)"
  fi

  # Expresión regular tomada de https://superuser.com/a/202835,
  # coincidirá con IPs inválidas como 123.456.789.012 pero está bien
  # ya que el registro solo contiene las válidas.
  declare -a IPS_TO_HIDE=("$(echo "${OVPNLOG}" \
    | grepcidr -v 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16 \
    | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
    | uniq)")

  for IP in "${IPS_TO_HIDE[@]}"; do
    OVPNLOG="${OVPNLOG//"$IP"/REDACTADO}"
  done

  echo "${OVPNLOG}"
  printf "=============================================\n"
fi

echo -e "::::\t\t\e[4mDepuración completada\e[0m\t\t ::::"
