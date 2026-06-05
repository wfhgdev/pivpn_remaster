#!/bin/bash
# PiVPN: Script de Desinstalación

### Constantes
# Encuentra las filas y columnas. Por defecto será 80x24 si no se puede detectar.
screen_size="$(stty size 2> /dev/null || echo 24 80)"
rows="$(echo "${screen_size}" | awk '{print $1}')"
columns="$(echo "${screen_size}" | awk '{print $2}')"

# Dividir por dos para que los cuadros de diálogo ocupen la mitad de la pantalla, lo que se ve bien.
r=$((rows / 2))
c=$((columns / 2))
# A menos que la pantalla sea minúscula
r=$((r < 20 ? 20 : r))
c=$((c < 70 ? 70 : c))

PKG_MANAGER="apt-get"
PKG_REMOVE="${PKG_MANAGER} -y remove --purge"
piholeVersions="/etc/pihole/versions"
dnsmasqConfig="/etc/dnsmasq.d/02-pivpn.conf"
setupVarsFile="setupVars.conf"
setupConfigDir="/etc/pivpn"
pivpnFilesDir="/usr/local/src/pivpn"
pivpnScriptDir="/opt/pivpn"
PLAT="$(grep -sEe '^NAME\=' /etc/os-release \
  | sed -E -e "s/NAME\=[\'\"]?([^ ]*).*/\1/")"
UPDATE_PKG_CACHE="${PKG_MANAGER} update"

### Funciones
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

### FIXME: introducir biblioteca global
spinner() {
  local pid="${1}"
  local delay=0.50
  local spinstr='/-\|'

  while ps a | awk '{print $1}' | grep -q "${pid}"; do
    local temp="${spinstr#?}"
    printf " [%c]  " "${spinstr}"
    local spinstr="${temp}${spinstr%"$temp"}"
    sleep "${delay}"
    printf "\\b\\b\\b\\b\\b\\b"
  done

  printf "    \\b\\b\\b\\b"
}

removeAll() {
  # Deteniendo y deshabilitando servicios
  echo "::: Deteniendo y deshabilitando servicios..."

  if [[ "${PLAT}" == 'Alpine' ]]; then
    if [[ "${VPN}" == "wireguard" ]]; then
      rc-service wg-quick stop
      rc-update del wg-quick default &> /dev/null
    elif [[ "${VPN}" == "openvpn" ]]; then
      rc-service openvpn stop
      rc-update del openvpn default &> /dev/null
    fi
  else
    if [[ "${VPN}" == "wireguard" ]]; then
      systemctl stop wg-quick@wg0
      systemctl disable wg-quick@wg0 &> /dev/null
    elif [[ "${VPN}" == "openvpn" ]]; then
      systemctl stop openvpn
      systemctl disable openvpn &> /dev/null
    fi
  fi

  # Eliminando reglas del cortafuegos.
  echo "::: Eliminando reglas del cortafuegos..."

  if [[ "${USING_UFW}" -eq 1 ]]; then
    ### Ignorando SC2154, valor obtenido del archivo setupVars
    # shellcheck disable=SC2154
    ufw delete allow "${pivpnPORT}/${pivpnPROTO}" > /dev/null
    ### Ignorando SC2154, valor obtenido del archivo setupVars
    # shellcheck disable=SC2154
    ufw route delete allow in on "${pivpnDEV}" \
      from "${pivpnNET}/${subnetClass}" out on "${IPv4dev}" to any > /dev/null
    ufw delete allow in on "${pivpnDEV}" to any port 53 \
      from "${pivpnNET}/${subnetClass}" > /dev/null

    sed_pattern='/-I POSTROUTING'
    sed_pattern="${sed_pattern} -s ${pivpnNET}\\/${subnetClass}"
    sed_pattern="${sed_pattern} -o ${IPv4dev}"
    sed_pattern="${sed_pattern} -j MASQUERADE"
    sed_pattern="${sed_pattern} -m comment"
    sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule/d"
    sed "${sed_pattern}" -i /etc/ufw/before.rules
    unset sed_pattern

    iptables \
      -t nat \
      -D POSTROUTING \
      -s "${pivpnNET}/${subnetClass}" \
      -o "${IPv4dev}" \
      -j MASQUERADE \
      -m comment \
      --comment "${VPN}-nat-rule"

    ufw reload &> /dev/null
  elif [[ "${USING_UFW}" -eq 0 ]]; then
    if [[ "${INPUT_CHAIN_EDITED}" -eq 1 ]]; then
      iptables \
        -D INPUT \
        -i "${IPv4dev}" \
        -p "${pivpnPROTO}" \
        --dport "${pivpnPORT}" \
        -j ACCEPT \
        -m comment \
        --comment "${VPN}-input-rule"
    fi

    if [[ "${FORWARD_CHAIN_EDITED}" -eq 1 ]]; then
      iptables \
        -D FORWARD \
        -d "${pivpnNET}/${subnetClass}" \
        -i "${IPv4dev}" \
        -o "${pivpnDEV}" \
        -m conntrack \
        --ctstate RELATED,ESTABLISHED \
        -j ACCEPT \
        -m comment \
        --comment "${VPN}-forward-rule"

      iptables \
        -D FORWARD \
        -s "${pivpnNET}/${subnetClass}" \
        -i "${pivpnDEV}" \
        -o "${IPv4dev}" \
        -j ACCEPT \
        -m comment \
        --comment "${VPN}-forward-rule"
    fi

    iptables \
      -t nat \
      -D POSTROUTING \
      -s "${pivpnNET}/${subnetClass}" \
      -o "${IPv4dev}" \
      -j MASQUERADE \
      -m comment \
      --comment "${VPN}-nat-rule"

    iptables-save > /etc/iptables/rules.v4
  fi

  # Deshabilitar el reenvío IPv4
  if [[ "${vpnStillExists}" -eq 0 ]]; then
    rm -f /etc/sysctl.d/99-pivpn.conf
    sysctl -p
  fi

  # Purgar dependencias
  echo "::: Purgando dependencias..."

  for i in "${INSTALLED_PACKAGES[@]}"; do
    while true; do
      read -rp "::: ¿Deseas eliminar ${i} de tu sistema? [y/n]: " yn

      case "${yn}" in
        [Yy]*)
          if [[ "${PLAT}" == 'Alpine' ]]; then
            if [[ "${i}" == 'openvpn' ]]; then
              deluser openvpn
              rm -f /etc/rsyslog.d/30-openvpn.conf /etc/logrotate.d/openvpn
            fi
          else
            if [[ "${i}" == "wireguard-tools" ]]; then
              # El repositorio bullseye puede no existir si wireguard estaba disponible en
              # el momento de la instalación.
              tmp_path='/etc/apt/sources.list.d/pivpn-bullseye-repo.list'

              if [[ -f "${tmp_path}" ]]; then
                echo "::: Eliminando el repositorio de Debian Bullseye..."

                rm -f "${tmp_path}"
                rm -f /etc/apt/preferences.d/pivpn-limit-bullseye

                echo "::: Actualizando la caché de paquetes..."

                ${UPDATE_PKG_CACHE} &> /dev/null &
                spinner "$!"
              fi

              tmp_path='/etc/systemd/system/wg-quick@.service.d/override.conf'

              if [[ -f "${tmp_path}" ]]; then
                rm -f "${tmp_path}"
              fi

              unset tmp_path
            elif [[ "${i}" == "unattended-upgrades" ]]; then
              rm -rf /var/log/unattended-upgrades /etc/apt/apt.conf.d/*periodic
              rm -rf /etc/apt/apt.conf.d/*unattended-upgrades
            elif [[ "${i}" == "openvpn" ]]; then
              if [[ -f /etc/apt/sources.list.d/pivpn-openvpn-repo.list ]]; then
                echo "::: Eliminando el repositorio de software de OpenVPN..."

                rm -f /etc/apt/sources.list.d/pivpn-openvpn-repo.list

                echo "::: Actualizando la caché de paquetes..."

                ${UPDATE_PKG_CACHE} &> /dev/null &
                spinner "$!"
              fi

              deluser openvpn
              rm -f /etc/rsyslog.d/30-openvpn.conf /etc/logrotate.d/openvpn
            fi
          fi

          printf ":::\\tEliminando %s..." "${i}"

          ${PKG_REMOVE} "${i}" &> /dev/null &
          spinner "$!"

          printf "¡hecho!\\n"
          break
          ;;
        [Nn]*)
          printf ":::\\tOmitiendo %s\\n" "${i}"
          break
          ;;
        *)
          err "::: ¡Debes responder sí o no!"
          ;;
      esac
    done
  done

  if [[ "${PLAT}" != 'Alpine' ]]; then
    # Encargarse de cualquier limpieza de paquetes adicional
    printf "::: Auto eliminando las dependencias restantes..."

    "${PKG_MANAGER}" -y autoremove &> /dev/null &
    spinner "$!"

    printf "¡hecho!\\n"
    printf "::: Auto limpiando las dependencias restantes..."

    "${PKG_MANAGER}" -y autoclean &> /dev/null &
    spinner "$!"

    printf "¡hecho!\\n"
  fi

  if [[ -f "${dnsmasqConfig}" ]]; then
    rm -f "${dnsmasqConfig}"
    # shellcheck disable=SC1090
    CORE_VERSION="$(source "$piholeVersions" && echo "${CORE_VERSION}")"
    if [ "$(echo -e 'v6.0.0\n'"${CORE_VERSION}" | sort -V | head -n 1)" = "v6.0.0" ]; then
      # Ejecutando Pi-hole v6 o posterior
      pihole reloaddns
    else
      pihole restartdns reload
    fi
  fi

  echo ":::"
  echo "::: Eliminando los archivos de configuración de la VPN..."

  if [[ "${VPN}" == "wireguard" ]]; then
    rm -f /etc/wireguard/wg0.conf
    rm -rf /etc/wireguard/configs
    rm -rf /etc/wireguard/keys
    ### Ignorando SC2154, valor obtenido del archivo setupVars
    # shellcheck disable=SC2154
    rm -rf "${install_home}/configs"
  elif [[ "${VPN}" == "openvpn" ]]; then
    rm -rf /var/log/*openvpn*
    rm -f /etc/openvpn/server.conf
    rm -f /etc/openvpn/crl.pem
    rm -rf /etc/openvpn/easy-rsa
    rm -rf /etc/openvpn/ccd
    rm -rf "${install_home}/ovpns"
  fi

  if [[ "${vpnStillExists}" -eq 0 ]]; then
    echo ":::"
    echo "::: Eliminando los archivos de sistema de pivpn..."

    rm -rf "${setupConfigDir}"
    rm -rf "${pivpnFilesDir}"
    rm -f /var/log/*pivpn*
    rm -f /etc/bash_completion.d/pivpn

    unlink "${pivpnScriptDir}"
    unlink /usr/local/bin/pivpn
  else
    if [[ "${VPN}" == 'wireguard' ]]; then
      othervpn='openvpn'
    else
      othervpn='wireguard'
    fi

    echo ":::"
    echo "::: Otra VPN ${othervpn} todavía está presente, por lo que no se"
    echo "::: eliminan los archivos de sistema de pivpn"
    rm -f "${setupConfigDir}/${VPN}/${setupVarsFile}"

    # Restaurar el script único de pivpn y el autocompletado de bash para la VPN restante
    ${SUDO} unlink /usr/local/bin/pivpn

    ${SUDO} ln \
      -sT "${pivpnFilesDir}/scripts/${othervpn}/pivpn.sh" \
      /usr/local/bin/pivpn

    ${SUDO} ln \
      -sT "${pivpnFilesDir}/scripts/${othervpn}/bash-completion" \
      /etc/bash_completion.d/pivpn

    # shellcheck disable=SC1091
    . /etc/bash_completion.d/pivpn
  fi

  echo ":::"
  printf "::: Se terminó de eliminar PiVPN de tu sistema.\\n"
  printf "::: Reinstala simplemente ejecutando\\n:::\\n:::\\t"
  printf "curl -L https://install.pivpn.io | "
  printf "bash\\n:::\\n::: ¡en cualquier momento!\\n:::\\n"
}

askreboot() {
  printf "\\e[1mSe recomienda encarecidamente\\e[0m reiniciar "
  printf "después de la desinstalación.\\n"

  read -p "¿Te gustaría reiniciar ahora? [y/N]: " -n 1 -r

  echo

  if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
    printf "\\nReiniciando el sistema...\\n"
    sleep 3
    reboot
  fi
}

### Script
if [[ "${PLAT}" == 'Alpine' ]]; then
  PKG_MANAGER='apk'
  PKG_REMOVE="${PKG_MANAGER} --no-cache --purge del -r"
fi

if [[ -r "${setupConfigDir}/wireguard/${setupVarsFile}" ]] \
  && [[ -r "${setupConfigDir}/openvpn/${setupVarsFile}" ]]; then
  vpnStillExists=1

  # Se han instalado dos protocolos, comprobar si el script ha pasado
  # un argumento, de lo contrario preguntar al usuario cuál quiere eliminar
  if [[ "$#" -ge 1 ]]; then
    VPN="${1}"
    echo "::: Desinstalando VPN: ${VPN}"
  else
    chooseVPNCmd=(whiptail
      --backtitle "Configuración de PiVPN"
      --title "Desinstalar"
      --separate-output
      --radiolist "Tanto OpenVPN como WireGuard están instalados, \
elige una VPN para desinstalar (presiona espacio para seleccionar):"
      "${r}" "${c}" 2)
    VPNChooseOptions=(WireGuard "" on
      OpenVPN "" off)

    if VPN="$("${chooseVPNCmd[@]}" "${VPNChooseOptions[@]}" 2>&1 \
      > /dev/tty)"; then
      echo "::: Desinstalando VPN: ${VPN}"
      VPN="${VPN,,}"
    else
      err "::: Cancelar seleccionado, saliendo...."
      exit 1
    fi
  fi

  setupVars="${setupConfigDir}/${VPN}/${setupVarsFile}"
else
  vpnStillExists=0

  if [[ -r "${setupConfigDir}/wireguard/${setupVarsFile}" ]]; then
    setupVars="${setupConfigDir}/wireguard/${setupVarsFile}"
  elif [[ -r "${setupConfigDir}/openvpn/${setupVarsFile}" ]]; then
    setupVars="${setupConfigDir}/openvpn/${setupVarsFile}"
  fi
fi

if [[ ! -f "${setupVars}" ]]; then
  err "::: ¡Falta el archivo de variables de configuración!"
  exit 1
fi

# shellcheck disable=SC1090
source "${setupVars}"

echo -n "::: Preparando para eliminar paquetes, asegúrate de que cada uno se pueda eliminar de forma segura "
echo "dependiendo de tu sistema operativo."
echo "::: (ES SEGURO ELIMINAR TODOS EN RASPBIAN)"

while true; do
  echo -n "::: ¿Deseas eliminar completamente la configuración de PiVPN y "
  echo -n "los paquetes instalados de tu sistema? "
  echo -n "(Se te preguntará por cada paquete) [y/n]: "
  read -r yn

  case "${yn}" in
    [Yy]*)
      removeAll
      askreboot
      break
      ;;
    [Nn]*)
      err "::: No se eliminará nada, saliendo..."
      break
      ;;
  esac
done
