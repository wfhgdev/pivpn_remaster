#!/usr/bin/env bash
# PiVPN: Script de Desinstalación Automatizada y Limpieza del Sistema
# Remueve de forma controlada interfaces de red, variables criptográficas y demonios

export LANG=es_ES.UTF-8
export LC_ALL=es_ES.UTF-8

# ==============================================================================
#                 CONFIGURACIÓN DE GEOMETRÍA Y CONSTANTES GLOBALES
# ==============================================================================
screen_size="$(stty size 2> /dev/null || echo 24 80)"
rows="$(echo "${screen_size}" | awk '{print $1}')"
columns="$(echo "${screen_size}" | awk '{print $2}')"

# Cálculo dinámico de proporciones para ventanas emergentes TUI (Whiptail)
r=$((rows / 2))
c=$((columns / 2))
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
UPDATE_PKG_CACHE="${PKG_MANAGER} update"

PLAT="$(grep -sEe '^NAME\=' /etc/os-release | sed -E -e "s/NAME\=[\'\"]?([^ ]*).*/\1/")"

# ==============================================================================
#                            FUNCIONES NÚCLEO
# ==============================================================================

err() {
  echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')] ::: [ERROR] $*" >&2
}

# Indicador visual de progreso (Spinner) optimizado a nivel de Kernel
spinner() {
  local pid="${1}"
  local delay=0.25
  local spinstr='|/-\'

  # Programación defensiva: Verificar existencia del proceso de forma atómica
  while kill -0 "${pid}" 2>/dev/null; do
    local temp="${spinstr#?}"
    printf " [%c]  " "${spinstr}"
    spinstr="${temp}${spinstr%"$temp"}"
    sleep "${delay}"
    printf "\b\b\b\b\b\b"
  done
  printf "    \b\b\b\b"
}

removeAll() {
  echo "::: [INFO] Deteniendo y deshabilitando servicios de red activos..."

  if [[ "${PLAT}" == 'Alpine' ]]; then
    if [[ "${VPN}" == "wireguard" ]]; then
      rc-service wg-quick stop &> /dev/null
      rc-update del wg-quick default &> /dev/null
    elif [[ "${VPN}" == "openvpn" ]]; then
      rc-service openvpn stop &> /dev/null
      rc-update del openvpn default &> /dev/null
    fi
  else
    if [[ "${VPN}" == "wireguard" ]]; then
      systemctl stop wg-quick@wg0 &> /dev/null
      systemctl disable wg-quick@wg0 &> /dev/null
    elif [[ "${VPN}" == "openvpn" ]]; then
      systemctl stop openvpn &> /dev/null
      systemctl disable openvpn &> /dev/null
    fi
  fi

  echo "::: [INFO] Revocando políticas y reglas de seguridad del cortafuegos..."

  if [[ "${USING_UFW}" -eq 1 ]]; then
    # shellcheck disable=SC2154
    ufw delete allow "${pivpnPORT}/${pivpnPROTO}" > /dev/null
    # shellcheck disable=SC2154
    ufw route delete allow in on "${pivpnDEV}" from "${pivpnNET}/${subnetClass}" out on "${IPv4dev}" to any > /dev/null
    ufw delete allow in on "${pivpnDEV}" to any port 53 from "${pivpnNET}/${subnetClass}" > /dev/null

    local sed_pattern='/-I POSTROUTING'
    sed_pattern="${sed_pattern} -s ${pivpnNET}\\/${subnetClass}"
    sed_pattern="${sed_pattern} -o ${IPv4dev}"
    sed_pattern="${sed_pattern} -j MASQUERADE"
    sed_pattern="${sed_pattern} -m comment"
    sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule/d"
    sed "${sed_pattern}" -i /etc/ufw/before.rules
    unset sed_pattern

    iptables -t nat -D POSTROUTING -s "${pivpnNET}/${subnetClass}" -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule" &> /dev/null
    ufw reload &> /dev/null
  elif [[ "${USING_UFW}" -eq 0 ]]; then
    if [[ "${INPUT_CHAIN_EDITED}" -eq 1 ]]; then
      iptables -D INPUT -i "${IPv4dev}" -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT -m comment --comment "${VPN}-input-rule" &> /dev/null
    fi

    if [[ "${FORWARD_CHAIN_EDITED}" -eq 1 ]]; then
      iptables -D FORWARD -d "${pivpnNET}/${subnetClass}" -i "${IPv4dev}" -o "${pivpnDEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT -m comment --comment "${VPN}-forward-rule" &> /dev/null
      iptables -D FORWARD -s "${pivpnNET}/${subnetClass}" -i "${pivpnDEV}" -o "${IPv4dev}" -j ACCEPT -m comment --comment "${VPN}-forward-rule" &> /dev/null
    fi

    iptables -t nat -D POSTROUTING -s "${pivpnNET}/${subnetClass}" -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule" &> /dev/null
    
    if command -v iptables-save &> /dev/null; then
      iptables-save > /etc/iptables/rules.v4
    fi
  fi

  # Remoción del reenvío de paquetes IPv4 si no coexisten otras VPNs
  if [[ "${vpnStillExists}" -eq 0 ]]; then
    echo "::: [INFO] Deshabilitando reenvío de paquetes (IP Forwarding) en sysctl..."
    rm -f /etc/sysctl.d/99-pivpn.conf
    sysctl -p &> /dev/null
  fi

  echo "::: [INFO] Iniciando purga selectiva de dependencias binarias..."

  for i in "${INSTALLED_PACKAGES[@]}"; do
    while true; do
      echo -n "::: ¿Desea eliminar el paquete '${i}' de su sistema operativo? [s/N]: "
      read -r yn

      case "${yn}" in
        [SsYy]*)
          if [[ "${PLAT}" == 'Alpine' ]]; then
            if [[ "${i}" == 'openvpn' ]]; then
              deluser openvpn 2> /dev/null
              rm -f /etc/rsyslog.d/30-openvpn.conf /etc/logrotate.d/openvpn
            fi
          else
            if [[ "${i}" == "wireguard-tools" ]]; then
              local tmp_path='/etc/apt/sources.list.d/pivpn-bullseye-repo.list'
              if [[ -f "${tmp_path}" ]]; then
                echo "::: [INFO] Extrayendo repositorio espejo Debian Bullseye..."
                rm -f "${tmp_path}" /etc/apt/preferences.d/pivpn-limit-bullseye
                echo -n "::: [INFO] Sincronizando la base de datos de paquetes..."
                ${UPDATE_PKG_CACHE} &> /dev/null &
                spinner "$!"
                echo " ¡Hecho!"
              fi

              local override_service='/etc/systemd/system/wg-quick@.service.d/override.conf'
              if [[ -f "${override_service}" ]]; then
                rm -f "${override_service}"
              fi
            elif [[ "${i}" == "unattended-upgrades" ]]; then
              rm -rf /var/log/unattended-upgrades /etc/apt/apt.conf.d/*periodic /etc/apt/apt.conf.d/*unattended-upgrades
            elif [[ "${i}" == "openvpn" ]]; then
              if [[ -f /etc/apt/sources.list.d/pivpn-openvpn-repo.list ]]; then
                echo "::: [INFO] Extrayendo repositorio oficial de OpenVPN..."
                rm -f /etc/apt/sources.list.d/pivpn-openvpn-repo.list
                echo -n "::: [INFO] Actualizando la base de datos de paquetes..."
                ${UPDATE_PKG_CACHE} &> /dev/null &
                spinner "$!"
                echo " ¡Hecho!"
              fi
              deluser openvpn 2> /dev/null
              rm -f /etc/rsyslog.d/30-openvpn.conf /etc/logrotate.d/openvpn
            fi
          fi

          printf "::: [INFO] Desinstalando %s..." "${i}"
          ${PKG_REMOVE} "${i}" &> /dev/null &
          spinner "$!"
          printf " ¡Hecho!\\n"
          break
          ;;
        [Nn]* | "")
          printf "::: [INFO] Omitiendo remoción del paquete: %s\\n" "${i}"
          break
          ;;
        *)
          err "Entrada inválida. Por favor, ingrese 's' (Sí) o 'n' (No)."
          ;;
      esac
    done
  done

  # Ejecución de limpieza de paquetes huérfanos en distribuciones no-Alpine
  if [[ "${PLAT}" != 'Alpine' ]]; then
    printf "::: [INFO] Ejecutando depuración de dependencias huérfanas (autoremove)..."
    "${PKG_MANAGER}" -y autoremove &> /dev/null &
    spinner "$!"
    printf " ¡Hecho!\\n"

    printf "::: [INFO] Ejecutando purga de archivos caché redundantes (autoclean)..."
    "${PKG_MANAGER}" -y autoclean &> /dev/null &
    spinner "$!"
    printf " ¡Hecho!\\n"
  fi

  # Acoplamiento del motor DNS de Pi-hole si aplica
  if [[ -f "${dnsmasqConfig}" ]]; then
    echo "::: [INFO] Limpiando configuraciones persistentes de DNSMasq..."
    rm -f "${dnsmasqConfig}"
    if [[ -f "${piholeVersions}" ]]; then
      # shellcheck disable=SC1090
      CORE_VERSION="$(source "$piholeVersions" && echo "${CORE_VERSION}")"
      if [ "$(echo -e 'v6.0.0\n'"${CORE_VERSION}" | sort -V | head -n 1)" = "v6.0.0" ]; then
        pihole reloaddns &> /dev/null
      else
        pihole restartdns reload &> /dev/null
      fi
    fi
  fi

  echo "::: [INFO] Removiendo estructuras de archivos criptográficos y configuraciones..."
  if [[ "${VPN}" == "wireguard" ]]; then
    rm -f /etc/wireguard/wg0.conf
    rm -rf /etc/wireguard/configs /etc/wireguard/keys
    # shellcheck disable=SC2154
    rm -rf "${install_home}/configs"
  elif [[ "${VPN}" == "openvpn" ]]; then
    rm -rf /var/log/*openvpn*
    rm -f /etc/openvpn/server.conf /etc/openvpn/crl.pem
    rm -rf /etc/openvpn/easy-rsa /etc/openvpn/ccd
    # shellcheck disable=SC2154
    rm -rf "${install_home}/ovpns"
  fi

  # Análisis de coexistencia multiprotocolo para prevenir rupturas de entorno
  if [[ "${vpnStillExists}" -eq 0 ]]; then
    echo "::: [INFO] Eliminando por completo directorios raíz y binarios del sistema PiVPN..."
    rm -rf "${setupConfigDir}" "${pivpnFilesDir}"
    rm -f /var/log/*pivpn* /etc/bash_completion.d/pivpn

    [[ -L "${pivpnScriptDir}" || -e "${pivpnScriptDir}" ]] && rm -f "${pivpnScriptDir}"
    [[ -L /usr/local/bin/pivpn || -e /usr/local/bin/pivpn ]] && rm -f /usr/local/bin/pivpn
  else
    local othervpn="openvpn"
    if [[ "${VPN}" == "openvpn" ]]; then othervpn="wireguard"; fi

    echo "::: [INFO] Conservando directorio raíz. La instancia de '${othervpn}' sigue presente."
    rm -f "${setupConfigDir}/${VPN}/${setupVarsFile}"

    # Re-enrutamiento seguro del binario unificado para el protocolo superviviente
    rm -f /usr/local/bin/pivpn /etc/bash_completion.d/pivpn

    ln -sT "${pivpnFilesDir}/scripts/${othervpn}/pivpn.sh" /usr/local/bin/pivpn
    ln -sT "${pivpnFilesDir}/scripts/${othervpn}/bash-completion" /etc/bash_completion.d/pivpn

    # shellcheck disable=SC1091
    [[ -f /etc/bash_completion.d/pivpn ]] && . /etc/bash_completion.d/pivpn
  fi

  echo ":::"
  echo "::: [ÉXITO] El proceso de desinstalación de PiVPN ha concluido."
  echo "::: Puede volver a desplegar la suite ejecutando el instalador en español:"
  echo ":::   curl -L https://raw.githubusercontent.com/wfhgdev/pivpn_spanish/master/auto_install/install.sh | bash"
  echo ":::"
}

askreboot() {
  # Integración homogénea con el asistente interactivo gráfico del despliegue principal
  if whiptail --backtitle "Asistente de Desinstalación - PiVPN" \
              --title "Reinicio del Sistema Recomendado" \
              --yes-button "Sí, reiniciar ahora (Recomendado)" \
              --no-button "No, reiniciar más tarde" \
              --defaultno \
              --yesno "Se aconseja realizar un reinicio completo del servidor tras finalizar la eliminación física de las interfaces virtuales de red.\n\n¿Desea programar y ejecutar el reinicio inmediato del sistema?" \
              "${r}" "${c}"; then

    whiptail --backtitle "Asistente de Desinstalación - PiVPN" \
             --title "Secuencia de Reinicio Activada" \
             --ok-button "Proceder" \
             --msgbox "El sistema procederá a cerrarse y reiniciarse de manera inmediata." \
             "${r}" "${c}"

    printf "\\n::: [INFO] Iniciando secuencia controlada de reinicio del servidor en 3 segundos...\\n"
    sleep 3
    reboot
  else
    echo "::: [INFO] El usuario pospuso el reinicio del sistema. Retornando control a la terminal."
  fi
}

# ==============================================================================
#                         EJECUCIÓN DEL SCRIPT PRINCIPAL
# ==============================================================================

if [[ "${PLAT}" == 'Alpine' ]]; then
  PKG_MANAGER='apk'
  PKG_REMOVE="${PKG_MANAGER} --no-cache --purge del -r"
fi

# Validación de coexistencia multiprotocolo
if [[ -r "${setupConfigDir}/wireguard/${setupVarsFile}" ]] && [[ -r "${setupConfigDir}/openvpn/${setupVarsFile}" ]]; then
  vpnStillExists=1

  if [[ "$#" -ge 1 ]]; then
    VPN="${1,,}"
    if [[ "${VPN}" == "wg" ]]; then VPN="wireguard"; fi
    if [[ "${VPN}" == "ovpn" ]]; then VPN="openvpn"; fi
    echo "::: [INFO] Procesando desinstalación silenciosa del perfil: ${VPN}"
  else
    chooseVPNCmd=(whiptail
      --backtitle "Ecosistema de Gestión PiVPN"
      --title "Selección de Instancia a Desinstalar"
      --yes-button "Confirmar" \
      --no-button "Cancelar" \
      --separate-output
      --radiolist "Se detectaron instalaciones activas tanto de OpenVPN como de WireGuard.\nPor favor, seleccione cuál de las instancias desea remover:\n(Presione [Espacio] para marcar, [Intro] para continuar)"
      "${r}" "${c}" 2)
    
    VPNChooseOptions=(WireGuard "Servidor basado en Kernel de alta velocidad" on
                      OpenVPN "Servidor basado en demonio tradicional" off)

    if VPN="$("${chooseVPNCmd[@]}" "${VPNChooseOptions[@]}" 2>&1 > /dev/tty)"; then
      VPN="${VPN,,}"
      echo "::: [INFO] Iniciando el desmontaje de la instancia: ${VPN}"
    else
      err "Operación cancelada por el usuario en el cuadro de selección. Saliendo..."
      exit 1
    fi
  fi
  setupVars="${setupConfigDir}/${VPN}/${setupVarsFile}"
else
  vpnStillExists=0
  if [[ -r "${setupConfigDir}/wireguard/${setupVarsFile}" ]]; then
    setupVars="${setupConfigDir}/wireguard/${setupVarsFile}"
    VPN="wireguard"
  elif [[ -r "${setupConfigDir}/openvpn/${setupVarsFile}" ]]; then
    setupVars="${setupConfigDir}/openvpn/${setupVarsFile}"
    VPN="openvpn"
  fi
fi

if [[ ! -f "${setupVars}" ]]; then
  err "Falta el archivo indispensable de variables de entorno: ${setupVars}"
  exit 1
fi

# shellcheck disable=SC1090
source "${setupVars}"

echo "::: [ADVERTENCIA] Asegúrese de verificar qué paquetes adicionales pueden ser removidos con seguridad."
echo "::: (En distribuciones como Raspberry Pi OS es completamente seguro purgar todos los elementos)."

while true; do
  echo -n "::: ¿Está seguro de que desea eliminar la configuración de PiVPN de este servidor? [s/N]: "
  read -r yn

  case "${yn}" in
    [SsYy]*)
      removeAll
      askreboot
      break
      ;;
    [Nn]* | "")
      echo "::: [INFO] Operación abortada de forma segura. No se han aplicado cambios al entorno."
      break
      ;;
    *)
      err "Opción no válida. Por favor, responda 's' o 'n'."
      ;;
  esac
done