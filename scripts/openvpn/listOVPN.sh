#!/bin/bash
# PiVPN: script de lista de clientes
# Script actualizado para incluir fechas de vencimiento y
# Secuencia de escape de limpieza -- psgoundar

INDEX="/etc/openvpn/easy-rsa/pki/index.txt"
EASYRSA="/etc/openvpn/easy-rsa/easyrsa"

err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

if [[ ! -f "${INDEX}" ]]; then
  err "¡No se encontró el archivo: ${INDEX}!"
  exit 1
fi

if [[ ! -f "${EASYRSA}" ]]; then
  err "¡No se encontró el archivo: ${EASYRSA}!"
  exit 1
fi

"${EASYRSA}" update-db >> /dev/null 2>&1

printf ": NOTE : The first entry is your server, "
printf "which should always be valid!\n"
printf "\\n"
printf "\\e[1m::: Certificate Status List :::\\e[0m\\n"

{
  printf "\\e[4mStatus\\e[0m  \t  \\e[4mName\\e[0m\\e[0m  \t  "
  printf "\\e[4mExpiration\\e[0m\\n"

  while read -r line || [[ -n "${line}" ]]; do
    STATUS="$(echo "${line}" | awk '{print $1}')"
    NAME="$(echo "${line}" | awk -FCN= '{print $2}')"
    EXPD="$(echo "${line}" \
      | awk '{if (length($2) == 15) print $2; else print "20"$2}' \
      | cut -b 1-8 \
      | date +"%b %d %Y" -f -)"

    if [[ "${STATUS}" == "V" ]]; then
      printf "Válido"
    elif [[ "${STATUS}" == "R" ]]; then
      printf "Revocado"
    elif [[ "${STATUS}" == "E" ]]; then
      printf "Expirado"
    else
      printf "Desconocido"
    fi

    printf "  \t  %s  \t  %s\\n" "$(echo -e "${NAME}")" "${EXPD}"
  done < "${INDEX}"

  printf "\\n"
} | column -t -s $'\t'
