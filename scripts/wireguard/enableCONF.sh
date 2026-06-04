#!/bin/bash

### Constantes
setupVars="/etc/pivpn/wireguard/setupVars.conf"

# shellcheck disable=SC1090
source "${setupVars}"

### Funciones
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

helpFunc() {
  echo "::: Habilita perfiles de configuración de clientes"
  echo ":::"
  echo -n "::: Uso: pivpn <-on|on> [-h|--help] [-v] "
  echo "[<cliente-1> ... [<cliente-2>] ...]"
  echo ":::"
  echo "::: Comandos:"
  echo ":::  [ninguno]            Modo interactivo"
  echo ":::  <cliente>            Cliente"
  echo ":::  -y,--yes             Habilitar cliente(s) sin confirmación"
  echo ":::  -v                   Mostrar solo clientes deshabilitados"
  echo ":::  -h,--help            Mostrar este diálogo de ayuda"
}

### Script
if [[ ! -f "${setupVars}" ]]; then
  err "::: ¡Falta el archivo de variables de configuración!"
  exit 1
fi

# Analizar argumentos de entrada
while [[ "$#" -gt 0 ]]; do
  _key="${1}"

  case "${_key}" in
    -h | --help)
      helpFunc
      exit 0
      ;;
    -y | --yes)
      CONFIRM=true
      ;;
    -v)
      DISPLAY_DISABLED=true
      ;;
    *)
      CLIENTS_TO_CHANGE+=("${1}")
      ;;
  esac

  shift
done

cd /etc/wireguard || exit

if [[ ! -s configs/clients.txt ]]; then
  err "::: No hay clientes para modificar"
  exit 1
fi

if [[ "${DISPLAY_DISABLED}" ]]; then
  grep '\[disabled\] ### begin' wg0.conf | sed 's/#//g; s/begin//'
  exit 1
fi

mapfile -t LIST < <(awk '{print $1}' configs/clients.txt)

if [[ "${#CLIENTS_TO_CHANGE[@]}" -eq 0 ]]; then
  echo -e "::\e[4m  Lista de clientes  \e[0m::"
  len="${#LIST[@]}"
  COUNTER=1

  while [[ "${COUNTER}" -le "${len}" ]]; do
    printf "%0${#len}s) %s\r\n" "${COUNTER}" "${LIST[(($COUNTER - 1))]}"
    ((COUNTER++))
  done

  echo -n "Por favor, introduce el Índice/Nombre del Cliente a habilitar "
  echo -n "de la lista anterior: "
  read -r CLIENTS_TO_CHANGE

  if [[ -z "${CLIENTS_TO_CHANGE}" ]]; then
    err "::: ¡No puedes dejar esto en blanco!"
    exit 1
  fi
fi

CHANGED_COUNT=0

for CLIENT_NAME in "${CLIENTS_TO_CHANGE[@]}"; do
  re='^[0-9]+$'

  if [[ "${CLIENT_NAME}" =~ $re ]]; then
    CLIENT_NAME="${LIST[$((CLIENT_NAME - 1))]}"
  fi

  if ! grep -q "^${CLIENT_NAME} " configs/clients.txt; then
    echo -e "::: \e[1m${CLIENT_NAME}\e[0m no existe"
  else
    if [[ -n "${CONFIRM}" ]]; then
      REPLY="y"
    else
      read -r -p "¿Confirmas que quieres habilitar ${CLIENT_NAME}? [Y/n] "
    fi

    if [[ "${REPLY}" =~ ^[Yy]$ ]] || [[ -z "${REPLY}" ]]; then
      # Habilitar la sección del peer en la configuración del servidor
      echo "${CLIENT_NAME}"

      sed_pattern="/### begin ${CLIENT_NAME} ###/,"
      sed_pattern="${sed_pattern}/### end ${CLIENT_NAME} ###/ s/#\[disabled\] //"
      sed -e "${sed_pattern}" -i wg0.conf
      unset sed_pattern

      echo "::: Configuración del servidor actualizada"
      ((CHANGED_COUNT++))
      echo "::: Se habilitó correctamente ${CLIENT_NAME}"
    fi
  fi
done

# Reiniciar WireGuard solo si realmente se habilitaron algunos clientes
if [[ "${CHANGED_COUNT}" -gt 0 ]]; then
  if [[ "${PLAT}" == 'Alpine' ]]; then
    if rc-service wg-quick restart; then
      echo "::: WireGuard recargado"
    else
      err "::: Error al recargar WireGuard"
    fi
  else
    if systemctl reload wg-quick@wg0; then
      echo "::: WireGuard recargado"
    else
      err "::: Error al recargar WireGuard"
    fi
  fi
fi
