#!/bin/bash

### Constantes
encoding="ansiutf8"

### Funciones
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

helpFunc() {
  echo "::: Muestra el código QR de un cliente para su uso con la aplicación móvil"
  echo ":::"
  echo -n "::: Uso: pivpn <-qr|qrcode> [-h|--help] [Opciones] "
  echo "[<cliente-1> ... [<cliente-2>] ...]"
  echo ":::"
  echo "::: Opciones:"
  echo ":::  -a256|ansi256        Muestra el código QR en caracteres ansi256"
  echo "::: Comandos:"
  echo ":::  [ninguno]            Modo interactivo"
  echo ":::  <cliente>            Cliente(s) a mostrar"
  echo ":::  -h,--help            Muestra este diálogo de ayuda"
}

### Script
# Analizar los argumentos de entrada

while [[ "$#" -gt 0 ]]; do
  _key="${1}"

  case "${_key}" in
    -h | --help)
      helpFunc
      exit 0
      ;;
    -a256 | --ansi256)
      encoding="ansi256"
      ;;
    *)
      CLIENTS_TO_SHOW+=("${1}")
      ;;
  esac

  shift
done

cd /etc/wireguard/configs || exit

if [[ ! -s clients.txt ]]; then
  err "::: No hay clientes para mostrar"
  exit 1
fi

mapfile -t LIST < <(awk '{print $1}' clients.txt)

if [[ "${#CLIENTS_TO_SHOW[@]}" -eq 0 ]]; then
  echo -e "::\e[4m  Lista de clientes  \e[0m::"
  len="${#LIST[@]}"
  COUNTER=1

  while [[ "${COUNTER}" -le "${len}" ]]; do
    printf "%0${#len}s) %s\r\n" "${COUNTER}" "${LIST[(($COUNTER - 1))]}"
    ((COUNTER++))
  done

  echo -n "Por favor, introduce el índice/nombre del cliente a mostrar: "
  read -r CLIENTS_TO_SHOW

  if [[ -z "${CLIENTS_TO_SHOW}" ]]; then
    err "::: ¡No puedes dejar esto en blanco!"
    exit 1
  fi
fi

for CLIENT_NAME in "${CLIENTS_TO_SHOW[@]}"; do
  re='^[0-9]+$'

  if [[ "${CLIENT_NAME:0:1}" == "-" ]]; then
    err "${CLIENT_NAME} no es un nombre de cliente u opción válida"
    exit 1
  elif [[ "${CLIENT_NAME}" =~ $re ]]; then
    CLIENT_NAME="${LIST[$((CLIENT_NAME - 1))]}"
  fi

  if grep -qw "${CLIENT_NAME}" clients.txt; then
    echo -e "::: Mostrando al cliente \e[1m${CLIENT_NAME}\e[0m a continuación"
    echo "====================================================================="

    qrencode -t "${encoding}" < "${CLIENT_NAME}.conf"

    echo "====================================================================="
  elif [[ -f "${CLIENT_NAME}" ]]; then
    echo -e "::: Mostrando al cliente \e[1m${CLIENT_NAME}\e[0m a continuación"
    echo "====================================================================="

    qrencode -t "${encoding}" < "${CLIENT_NAME}"

    echo "====================================================================="
  else
    echo -e "::: \e[1m${CLIENT_NAME}\e[0m no existe"
  fi
done
