#!/bin/bash
#shellcheck disable=SC2317
### Actualiza los scripts de pivpn (No PiVPN)
# Por Realizar: Eliminar esta sección cuando la funcionalidad de actualización se vuelva a habilitar
###
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

err "::: La funcionalidad de actualización de los scripts de PiVPN está temporalmente deshabilitada"
err "::: Para mantener la VPN (y el sistema) actualizados, usa:"
err "        apt update; apt upgrade"
exit 0
### FIN DE LA SECCIÓN ###

### Constantes
pivpnrepo="https://github.com/Masterwilledu/pivpn_spanish.git"
pivpnlocalpath="/etc/.pivpn"
pivpnscripts="/opt/pivpn/"
bashcompletiondir="/etc/bash_completion.d/"

# Encuentra las filas y columnas. Por defecto será 80x24 si no se pueden detectar.
screen_size="$(stty size 2> /dev/null || echo 24 80)"
rows="$(echo "${screen_size}" | awk '{print $1}')"
columns="$(echo "${screen_size}" | awk '{print $2}')"

# Divide por dos para que los cuadros de diálogo ocupen la mitad de la pantalla, lo cual se ve bien.
r=$((rows / 2))
c=$((columns / 2))
# A menos que la pantalla sea minúscula
r=$((r < 20 ? 20 : r))
c=$((c < 70 ? 70 : c))

chooseVPNCmd=(whiptail
  --backtitle "Configuración de PiVPN"
  --title "Modo de instalación"
  --separate-output
  --radiolist "Elige una VPN para actualizar (presiona espacio para seleccionar):"
  "${r}" "${c}" 2)
VPNChooseOptions=(WireGuard "" on
  OpenVPN "" off)

if VPN="$("${chooseVPNCmd[@]}" "${VPNChooseOptions[@]}" 2>&1 > /dev/tty)"; then
  echo "::: Usando VPN: ${VPN}"
  VPN="${VPN,,}"
else
  err "::: Cancelar seleccionado, saliendo...."
  exit 1
fi

setupVars="/etc/pivpn/${VPN}/setupVars.conf"

# shellcheck disable=SC1090
source "${setupVars}"

### Funciones
# TODO: Descomentar esta función cuando la funcionalidad de actualización
# se vuelva a habilitar
#err() {
#  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
#}

scriptusage() {
  echo "::: Actualiza los scripts de PiVPN"
  echo ":::"
  echo "::: Uso: pivpn <-up|update> [-t|--test]"
  echo ":::"
  echo "::: Comandos:"
  echo ":::  [ninguno]           Actualiza desde la rama master"
  echo ":::  -t, test            Actualiza desde la rama test"
  echo ":::  -h, help            Muestra este diálogo de uso"
}

updatepivpnscripts() {
  local branch
  branch="${1}"
  ## No sabemos qué tipo de cambios han hecho los usuarios.
  ## Vamos a eliminar primero el directorio /etc/.pivpn y luego a clonarlo de nuevo
  echo -n "Procediendo a actualizar los scripts de PiVPN"

  if [[ -z "${branch}" ]]; then
    echo " desde la rama ${branch}"
  else
    echo
  fi

  if [[ -d "${pivpnlocalpath}" ]] \
    && [[ -n "${pivpnlocalpath}" ]]; then
    rm -rf "${pivpnlocalpath}/../.pivpn"
  fi

  cloneandupdate "${branch}"
  echo -n "Los scripts de PiVPN se han actualizado"

  if [[ -z "${branch}" ]]; then
    echo " desde la rama ${branch}"
  else
    echo
  fi
}

## Clonar y copiar los scripts de pivpn a /opt/pivpn
cloneandupdate() {
  local branch
  branch="${1}"
  git clone "${pivpnrepo}" "${pivpnlocalpath}"

  if [[ -z "${branch}" ]]; then
    git -C "${pivpnlocalpath}" checkout "${branch}"
    git -C "${pivpnlocalpath}" pull origin "${branch}"
  fi

  cp "${pivpnlocalpath}"/scripts/*.sh "${pivpnscripts}"
  cp "${pivpnlocalpath}"/scripts/"${VPN}"/*.sh "${pivpnscripts}"
  cp "${pivpnlocalpath}"/scripts/"${VPN}"/bash-completion "${bashcompletiondir}"

  if [[ -z "${branch}" ]]; then
    git -C "${pivpnlocalpath}" checkout master
  fi
}

## SCRIPT
if [[ ! -f "${setupVars}" ]]; then
  err "::: ¡Falta el archivo de variables de configuración!"
  exit 1
fi

if [[ "$#" -eq 0 ]]; then
  updatepivpnscripts
else
  while true; do
    case "${1}" in
      -t | test)
        updatepivpnscripts 'test'
        exit 0
        ;;
      -h | help)
        scriptusage
        exit 0
        ;;
      *)
        updatepivpnscripts
        exit 0
        ;;
    esac
  done
fi
