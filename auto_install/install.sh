#!/usr/bin/env bash
# PiVPN: Configuración e instalación trivial de OpenVPN o WireGuard
# La configuración y gestión más sencilla de OpenVPN o WireGuard en Raspberry Pi
# https://pivpn.io
# Fuertemente adaptado del proyecto pi-hole.net y...
# https://github.com/StarshipEngineer/OpenVPN-Setup/
export LANG=en_US.UTF-8
# Instala con este comando (desde tu Pi):
export LC_ALL=en_US.UTF-8
# curl -sSfL https://install.pivpn.io | bash
# Asegúrate de tener `curl` instalado

######## VARIABLES #########
pivpnGitUrl="https://github.com/pivpn/pivpn.git"
# Descomenta para usar una rama personalizada para los archivos locales de pivpn
#pivpnGitBranch="custombranchtocheckout"
setupVarsFile="setupVars.conf"
setupConfigDir="/etc/pivpn"
tempsetupVarsFile="/tmp/setupVars.conf"
pivpnFilesDir="/usr/local/src/pivpn"
pivpnScriptDir="/opt/pivpn"
GITBIN="/usr/bin/git"

piholeVersions="/etc/pihole/versions"
dnsmasqConfig="/etc/dnsmasq.d/02-pivpn.conf"

dhcpcdFile="/etc/dhcpcd.conf"
ovpnUserGroup="openvpn:openvpn"

######## Variables de Paquetes ########
PKG_MANAGER="apt-get"
### CORRÍGEME: citar UPDATE_PKG_CACHE y PKG_INSTALL cuelga el script,
### shellcheck SC2086
UPDATE_PKG_CACHE="${PKG_MANAGER} update -y"
PKG_INSTALL="${PKG_MANAGER} --yes --no-install-recommends install"
PKG_COUNT="${PKG_MANAGER} -s -o Debug::NoLocking=true upgrade | grep -c ^Inst || true"
CHECK_PKG_INSTALLED='dpkg-query -s'

# Dependencias requeridas por el script,
# independientemente del protocolo VPN elegido
BASE_DEPS=(git tar curl grep bind9-dnsutils grepcidr whiptail net-tools)
BASE_DEPS+=(bsdmainutils bash-completion)

BASE_DEPS_ALPINE=(git grep bind-tools newt net-tools bash-completion coreutils)
BASE_DEPS_ALPINE+=(openssl util-linux openrc iptables ip6tables coreutils sed)
BASE_DEPS_ALPINE+=(perl libqrencode-tools)

# Dependencias que realmente instaló el script. Por ejemplo si el
# script requiere grep y bind9-dnsutils pero bind9-dnsutils ya está instalado, guardamos
# grep aquí. De esta manera, al desinstalar PiVPN no pediremos eliminar paquetes
# que el usuario haya instalado por otras razones
INSTALLED_PACKAGES=()

######## URLs ########
easyrsaVer="3.2.3"
easyrsaRel="https://github.com/OpenVPN/easy-rsa/releases/download/v${easyrsaVer}/EasyRSA-${easyrsaVer}.tgz"

######## Banderas no documentadas. Shhh ########
runUnattended=false
usePiholeDNS=false
skipSpaceCheck=false
reconfigure=false
showUnsupportedNICs=false

######## Algunas variables que podrían estar vacías
# pero necesitan definirse para comprobaciones
pivpnPERSISTENTKEEPALIVE=""
pivpnDNS2=""

######## Configuración relacionada con IPv6
# el parámetro cli "--noipv6" permite deshabilitar IPv6, lo que también evita la ruta
# IPv6 forzada
# el parámetro cli "--ignoreipv6leak" permite omitir la ruta IPv6 forzada si es
# necesario (no recomendado)

## Forzar IPv6 a través de la VPN incluso si IPv6 no es compatible con el servidor
## Esto evitará una fuga de IPv6 en el lado del cliente, pero podría causar
## problemas en el lado del cliente al acceder a direcciones IPv6.
## Esta opción es inútil si las rutas se configuran manualmente.
## También es irrelevante cuando IPv6 está (forzado) habilitado.
pivpnforceipv6route=1

## Habilitar o deshabilitar IPv6.
## Dejarlo vacío o en "1" desencadenará una comprobación de enlace ascendente IPv6
pivpnenableipv6=""

## Habilitar para omitir la comprobación de conectividad IPv6 y también forzar el tráfico IPv6 del cliente
## a través de wireguard, independientemente de si hay una ruta IPv6 en el servidor.
pivpnforceipv6=0

######## SCRIPT ########

# Encontrar las filas y columnas. Por defecto será 80x24 si no se puede detectar.
screen_size="$(stty size 2> /dev/null || echo 24 80)"
rows="$(echo "${screen_size}" | awk '{print $1}')"
columns="$(echo "${screen_size}" | awk '{print $2}')"

# Dividir por dos para que los diálogos ocupen la mitad de la pantalla.
r=$((rows / 2))
c=$((columns / 2))
# A menos que la pantalla sea pequeña
r=$((r < 20 ? 20 : r))
c=$((c < 70 ? 70 : c))

# Sobrescribir la configuración de localización para que la salida original se mantenga (C).
export LC_ALL=C

main() {
  # Comprobaciones y configuraciones previas a la instalación
  distroCheck
  rootCheck
  flagsCheck "$@"
  unattendedCheck
  checkExistingInstall "$@"
  checkHostname

  # Verificar que haya suficiente espacio en disco para la instalación
  if [[ "${skipSpaceCheck}" == 'true' ]]; then
    echo -n "::: --skip-space-check pasado al script, "
    echo "¡omitiendo verificación de espacio libre en disco!"
  else
    verifyFreeDiskSpace
  fi

  updatePackageCache
  notifyPackageUpdatesAvailable
  preconfigurePackages

  if [[ "${PLAT}" == 'Alpine' ]]; then
    installDependentPackages BASE_DEPS_ALPINE[@]
  else
    installDependentPackages BASE_DEPS[@]
  fi

  welcomeDialogs

  if [[ "${pivpnforceipv6}" -eq 1 ]]; then
    echo "::: Configuración forzada de IPv6, ¡omitiendo comprobación de enlace ascendente IPv6!"
    pivpnenableipv6=1
  else
    if [[ -z "${pivpnenableipv6}" ]] \
      || [[ "${pivpnenableipv6}" -eq 1 ]]; then
      checkipv6uplink
    fi

    if [[ "${pivpnenableipv6}" -eq 0 ]] \
      && [[ "${pivpnforceipv6route}" -eq 1 ]]; then
      askforcedipv6route
    fi
  fi

  chooseInterface

  if checkStaticIpSupported; then
    getStaticIPv4Settings

    if [[ -z "${dhcpReserv}" ]] \
      || [[ "${dhcpReserv}" -ne 1 ]]; then
      setStaticIPv4
    fi
  else
    staticIpNotSupported
  fi

  chooseUser
  cloneOrUpdateRepos

  # Instalar
  if installPiVPN; then
    echo "::: Instalación Completada..."
  else
    exit 1
  fi

  restartServices
  # Preguntar si se habilitarán las actualizaciones desatendidas (unattended-upgrades)
  askUnattendedUpgrades

  if [[ "${UNATTUPG}" -eq 1 ]]; then
    confUnattendedUpgrades
  fi

  writeConfigFiles
  installScripts
  displayFinalMessage
  echo ":::"
}

####### FUNCTIONS ##########

err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

rootCheck() {
  ######## FIRST CHECK ########
  # Debe ser root para instalar
  echo ":::"

  if [[ "${EUID}" -eq 0 ]]; then
    echo "::: Eres root."
  else
    echo "::: se usará sudo para la instalación."

    # Comprobar si realmente está instalado
    # Si no lo está, salir porque la instalación no puede completarse
    if eval "${CHECK_PKG_INSTALLED} sudo" &> /dev/null; then
      export SUDO="sudo"
      export SUDOE="sudo -E"
    else
      err "::: Por favor, instala sudo o ejecuta esto como root."
      exit 1
    fi
  fi
}

flagsCheck() {
  # Comprobar argumentos para las banderas no documentadas
  for ((i = 1; i <= "$#"; i++)); do
    j="$((i + 1))"

    case "${!i}" in
      "--skip-space-check")
        skipSpaceCheck=true
        ;;
      "--unattended")
        runUnattended=true
        unattendedConfig="${!j}"
        ;;
      "--use-pihole")
        usePiholeDNS=true
        ;;
      "--reconfigure")
        reconfigure=true
        ;;
      "--show-unsupported-nics")
        showUnsupportedNICs=true
        ;;
      "--giturl")
        pivpnGitUrl="${!j}"
        ;;
      "--gitbranch")
        pivpnGitBranch="${!j}"
        ;;
      "--noipv6")
        pivpnforceipv6=0
        pivpnenableipv6=0
        pivpnforceipv6route=0
        ;;
      "--ignoreipv6leak")
        pivpnforceipv6route=0
        ;;
    esac
  done
}

unattendedCheck() {
  if [[ "${runUnattended}" == 'true' ]]; then
    echo -n "::: --unattended pasado al script de instalación, "
    echo "no se mostrarán diálogos de whiptail"

    if [[ -z "${unattendedConfig}" ]]; then
      err "::: No se ha pasado ningún archivo de configuración"
      exit 1
    else
      if [[ -r "${unattendedConfig}" ]]; then
        # shellcheck disable=SC1090
        . "${unattendedConfig}"
      else
        err "::: No se puede abrir ${unattendedConfig}"
        exit 1
      fi
    fi
  fi
}

checkExistingInstall() {
  # ver qué configuración ya existe
  if [[ -r "${setupConfigDir}/wireguard/${setupVarsFile}" ]]; then
    setupVars="${setupConfigDir}/wireguard/${setupVarsFile}"
  elif [[ -r "${setupConfigDir}/openvpn/${setupVarsFile}" ]]; then
    setupVars="${setupConfigDir}/openvpn/${setupVarsFile}"
  fi

  # Eliminar archivo temporal existente de variables de configuración si es de otro usuario
  ${SUDO} rm -f "${tempsetupVarsFile}"

  if [[ -r "${setupVars}" ]]; then
    if [[ "${reconfigure}" == 'true' ]]; then
      echo -n "::: --reconfigure pasado al script de instalación, "
      echo "reinstalará PiVPN sobrescribiendo la configuración existente"
      UpdateCmd="Reconfigure"
    elif [[ "${runUnattended}" == 'true' ]]; then
      ### ¿Qué debería hacer el script al pasar --unattended a
      ### una instalación existente?
      UpdateCmd="Reconfigure"
    else
      askAboutExistingInstall "${setupVars}"
    fi
  fi

  if [[ -z "${UpdateCmd}" ]] \
    || [[ "${UpdateCmd}" == "Reconfigure" ]]; then
    :
  elif [[ "${UpdateCmd}" == "Update" ]]; then
    ${SUDO} "${pivpnScriptDir}/update.sh" "$@"
    exit "$?"
  elif [[ "${UpdateCmd}" == "Repair" ]]; then
    # shellcheck disable=SC1090
    . "${setupVars}"
    runUnattended=true
  fi
}

askAboutExistingInstall() {
  opt1a="Actualizar"
  opt1b="Obtener los últimos scripts de PiVPN"

  opt2a="Reparar"
  opt2b="Reinstalar PiVPN usando la configuración existente"

  opt3a="Reconfigurar"
  opt3b="Reinstalar PiVPN con nueva configuración"

  UpdateCmd="$(whiptail \
    --title "¡Instalación existente detectada!" \
    --menu "
Hemos detectado una instalación existente.
${1}

Por favor, elige entre las siguientes opciones \
(Reconfigurar se puede usar para añadir un segundo tipo de VPN):" "${r}" "${c}" 3 \
    "${opt1a}" "${opt1b}" \
    "${opt2a}" "${opt2b}" \
    "${opt3a}" "${opt3b}" \
    3>&2 2>&1 1>&3)" \
    || {
      err "::: Cancelar seleccionado. Saliendo"
      exit 1
    }

  echo "::: Opción ${UpdateCmd} seleccionada."
}

distroCheck() {
  # Comprobar distribución compatible
  # Compatibilidad, funciones para comprobar el Sistema Operativo compatible
  # distroCheck, maybeOSSupport, noOSSupport
  # si el comando lsb_release está en su sistema
  if command -v lsb_release > /dev/null; then
    PLAT="$(lsb_release -si)"
    OSCN="$(lsb_release -sc)"
  else # de lo contrario obtener información de os-release
    . /etc/os-release
    PLAT="$(awk '{print $1}' <<< "${NAME}")"
    VER="${VERSION_ID}"
    declare -A VER_MAP=(
      ["11"]="bullseye"
      ["12"]="bookworm"
      ["13"]="trixie"
      ["20.04"]="focal"
      ["22.04"]="jammy"
      ["24.04"]="noble"
    )
    OSCN="${VER_MAP["${VER}"]}"

    # Soporte para Alpine
    if [[ -z "${OSCN}" ]]; then
      OSCN="${VER}"
    fi
  fi

  case "${PLAT}" in
    Debian | Raspbian | Ubuntu)
      case "${OSCN}" in
        bullseye | bookworm | trixie | focal | jammy | noble)
          :
          ;;
        *)
          maybeOSSupport
          ;;
      esac
      ;;
    Alpine)
      PKG_MANAGER='apk'
      UPDATE_PKG_CACHE="${PKG_MANAGER} update"
      PKG_INSTALL="${PKG_MANAGER} --no-cache add"
      PKG_COUNT="${PKG_MANAGER} list -u | wc -l || true"
      CHECK_PKG_INSTALLED="${PKG_MANAGER} --no-cache info -e"
      ;;
    *)
      noOSSupport
      ;;
  esac

  {
    echo "PLAT=${PLAT}"
    echo "OSCN=${OSCN}"
  } > "${tempsetupVarsFile}"
}

noOSSupport() {
  if [[ "${runUnattended}" == 'true' ]]; then
    err "::: Sistema Operativo no válido detectado"
    err "::: No hemos podido detectar un Sistema Operativo compatible."
    err "::: Actualmente este instalador soporta RaspberryPi OS, Debian y Ubuntu."
    exit 1
  fi

  whiptail \
    --backtitle "SISTEMA OPERATIVO NO VÁLIDO DETECTADO" \
    --title "Sistema Operativo no válido" \
    --msgbox "No hemos podido detectar un Sistema Operativo compatible.
Actualmente este instalador soporta Raspbian, Debian y Ubuntu.
Para más detalles, consulta nuestra documentación en \
https://github.com/pivpn/pivpn/wiki" "${r}" "${c}"
  exit 1
}

maybeOSSupport() {
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: Sistema Operativo no compatible"
    echo -n "::: Estás en un S.O que no hemos probado pero podría funcionar, "
    echo "continuando de todos modos..."
    return
  fi

  if whiptail \
    --backtitle "Sistema Operativo No Probado" \
    --title "Sistema Operativo No Probado" \
    --yesno "Estás en un S.O. que no hemos probado pero podría funcionar.  
Actualmente este instalador soporta Raspbian, Debian y Ubuntu.
Para más detalles sobre los S.O. compatibles consulta nuestra
documentación en https://github.com/pivpn/pivpn/wiki
¿Te gustaría continuar de todos modos?" "${r}" "${c}"; then
    echo "::: No se detectó un Sistema Operativo perfectamente compatible pero,"
    echo -n "::: Continuando la instalación bajo el propio "
    echo "riesgo del usuario..."
  else
    err "::: Saliendo debido a un Sistema Operativo no probado"
    exit 1
  fi
}

checkHostname() {
  # Comprueba la longitud del nombre de host
  host_name="$(hostname -s)"

  if [[ "${#host_name}" -gt 28 ]]; then
    if [[ "${runUnattended}" == 'true' ]]; then
      err "::: Tu nombre de host es demasiado largo."
      err "::: Usa 'hostnamectl set-hostname TUNOMBREDEHOST' para establecer un nuevo nombre de host"
      err "::: Debe tener menos de 28 caracteres de longitud y no usar caracteres especiales"
      exit 1
    fi

    until [[ "${#host_name}" -le 28 ]] \
      && [[ "${host_name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,28}$ ]]; do
      host_name="$(whiptail \
        --title "Nombre de host demasiado largo" \
        --inputbox "Tu nombre de host es demasiado largo.
Introduce un nuevo nombre de host con menos de 28 caracteres
No se permiten caracteres especiales." "${r}" "${c}" \
        3>&1 1>&2 2>&3)"
      ${SUDO} hostnamectl set-hostname "${host_name}"

      if [[ "${#host_name}" -le 28 ]] \
        && [[ "${host_name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,28}$ ]]; then
        echo "::: Nombre de host válido y longitud correcta, procediendo..."
      fi
    done
  else
    echo "::: Longitud del nombre de host correcta"
  fi
}

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

verifyFreeDiskSpace() {
  # Si el usuario instala unattended-upgrades necesitaríamos unos 60MB así que
  # comprobaremos si hay 75MB libres
  echo "::: Verificando el espacio libre en disco..."
  local required_free_kilobytes=76800
  local existing_free_kilobytes
  existing_free_kilobytes="$(df -Pk \
    | grep -m1 '\/$' \
    | awk '{print $4}')"

  # - Espacio libre en disco desconocido, no es un entero
  if [[ ! "${existing_free_kilobytes}" =~ ^([0-9])+$ ]]; then
    echo "::: ¡Espacio libre en disco desconocido!"
    echo -n "::: No pudimos determinar el espacio libre disponible en disco "
    echo "en este sistema."

    if [[ "${runUnattended}" == 'true' ]]; then
      exit 1
    fi

    echo -n "::: Puedes continuar con la instalación, sin embargo, "
    echo "no es recomendable."
    echo -n "::: Si estás seguro de que quieres continuar, "
    echo -n "escribe YES y presiona enter :: "
    read -r response

    case "${response}" in
      [Yy][Ee][Ss])
        :
        ;;
      *)
        err "::: Confirmación no recibida, saliendo..."
        exit 1
        ;;
    esac
  # - Espacio libre en disco insuficiente
  elif [[ "${existing_free_kilobytes}" -lt "${required_free_kilobytes}" ]]; then
    err "::: ¡Espacio en disco insuficiente!"
    err "::: Tu sistema parece tener poco espacio en disco. PiVPN recomienda un mínimo de ${required_free_kilobytes} KiloBytes."
    err "::: Solo tienes ${existing_free_kilobytes} KiloBytes libres."
    err "::: Si esta es una instalación nueva en una Raspberry Pi, es posible que necesites expandir tu disco."
    err "::: Intenta ejecutar 'sudo raspi-config', y elige la opción 'expand file system'"
    err "::: Después de reiniciar, vuelve a ejecutar esta instalación. (curl -sSfL https://install.pivpn.io | bash)"
    err "Espacio libre insuficiente, saliendo..."
    exit 1
  fi
}

updatePackageCache() {
  # actualizar listas de paquetes
  echo ":::"
  echo -e "::: Es necesaria una actualización de la caché de paquetes, ejecutando ${UPDATE_PKG_CACHE} ..."
  # shellcheck disable=SC2086
  ${SUDO} ${UPDATE_PKG_CACHE} &> /dev/null &
  spinner "$!"
  echo " ¡hecho!"
}

notifyPackageUpdatesAvailable() {
  # Informar al usuario si tiene paquetes desactualizados en su sistema y
  # aconsejarle que ejecute una actualización de paquetes lo antes posible.
  echo ":::"
  echo -n "::: Comprobando ${PKG_MANAGER} en busca de paquetes actualizados...."
  updatesToInstall="$(eval "${PKG_COUNT}")"
  echo " ¡hecho!"
  echo ":::"

  if [[ "${updatesToInstall}" -eq 0 ]]; then
    echo "::: ¡Tu sistema está actualizado! Continuando con la instalación de PiVPN..."
  else
    echo "::: ¡Hay ${updatesToInstall} actualizaciones disponibles para tu sistema!"
    echo "::: ¡Te recomendamos que actualices tu Sistema Operativo después de instalar PiVPN! "
    echo ":::"
  fi
}

preconfigurePackages() {
  # Instalar paquetes usados por este script de instalación
  # Si apt es más antiguo que 1.5 necesitamos instalar un paquete adicional para añadir
  # soporte para repositorios https que se usarán más adelante
  if [[ "${PKG_MANAGER}" == 'apt-get' ]] \
    && [[ -f /etc/apt/sources.list ]]; then
    INSTALLED_APT="$(apt-cache policy apt \
      | grep -m1 'Installed: ' \
      | grep -v '(none)' \
      | awk '{print $2}')"

    if dpkg --compare-versions "${INSTALLED_APT}" lt 1.5; then
      BASE_DEPS+=("apt-transport-https")
    fi
  fi

  # Configuramos IP estática solo en Raspberry Pi OS
  if checkStaticIpSupported; then
    if [[ "${OSCN}" == "bullseye" ]]; then
      BASE_DEPS+=(dhcpcd5)
    else
      useNetworkManager=true
    fi
  fi

  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    DPKG_ARCH="$(dpkg --print-architecture)"
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    DPKG_ARCH="$(apk --print-arch)"
  fi

  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    AVAILABLE_OPENVPN="$(apt-cache policy openvpn \
      | grep -m1 'Candidate: ' \
      | grep -v '(none)' \
      | awk '{print $2}')"
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    AVAILABLE_OPENVPN="$(apk search -e openvpn \
      | sed -E -e 's/openvpn\-(.*)/\1/')"
  fi

  OPENVPN_SUPPORT=0
  NEED_OPENVPN_REPO=0

  # Requerimos OpenVPN 2.5 o posterior para soporte ECC y tls-crypt-v2. Si no está
  # en los repositorios pero estamos ejecutando x86 Debian o Ubuntu, añadimos el repositorio oficial
  # que proporciona el paquete actualizado.
  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    if [[ -n "${AVAILABLE_OPENVPN}" ]] \
      && dpkg --compare-versions "${AVAILABLE_OPENVPN}" ge 2.5; then
      OPENVPN_SUPPORT=1
    else
      if [[ "${PLAT}" == "Debian" ]] \
        || [[ "${PLAT}" == "Ubuntu" ]]; then
        if [[ "${DPKG_ARCH}" == "amd64" ]] \
          || [[ "${DPKG_ARCH}" == "i386" ]]; then
          NEED_OPENVPN_REPO=1
          OPENVPN_SUPPORT=1
        else
          OPENVPN_SUPPORT=0
        fi
      else
        OPENVPN_SUPPORT=0
      fi
    fi
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    if [[ -n "${AVAILABLE_OPENVPN}" ]] \
      && [[ "$(apk version -t "${AVAILABLE_OPENVPN}" 2.5)" == '>' ]]; then
      OPENVPN_SUPPORT=1
    else
      OPENVPN_SUPPORT=0
    fi
  fi

  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    AVAILABLE_WIREGUARD="$(apt-cache policy wireguard \
      | grep -m1 'Candidate: ' \
      | grep -v '(none)' \
      | awk '{print $2}')"
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    AVAILABLE_WIREGUARD="$(apk search -e wireguard-tools \
      | sed -E -e 's/wireguard\-tools\-(.*)/\1/')"
  fi

  WIREGUARD_SUPPORT=0

  # Si se encuentra un objeto del núcleo de wireguard y es parte de algún paquete instalado,
  # entonces no se ha compilado mediante DKMS o manualmente (instalar a través de
  # wireguard-dkms no hace que el módulo sea parte del paquete ya que el
  # módulo en sí se compila en el momento de la instalación y no es parte del .deb).
  # Fuente: https://github.com/MichaIng/DietPi/blob/7bf5e1041f3b2972d7827c48215069d1c90eee07/dietpi/dietpi-software#L1807-L1815
  # Adicionalmente, si estamos usando algo como LXC, el núcleo del anfitrión cargará
  # el módulo wireguard por lo que parecerá integrado desde el punto de vista del contenedor.
  WIREGUARD_BUILTIN=0

  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    if dpkg-query -S '/lib/modules/*/wireguard.ko*' &> /dev/null \
      || dpkg-query -S '/usr/lib/modules/*/wireguard.ko*' &> /dev/null \
      || modinfo wireguard 2> /dev/null \
      | grep -q '^filename:[[:blank:]]*(builtin)$' \
      || lsmod | grep -q '^wireguard'; then
      WIREGUARD_BUILTIN=1
    fi
  fi

  # caso 1: Si el módulo está integrado y el paquete está disponible,
  #         solo necesitamos instalar wireguard-tools.
  # caso 2: Si el paquete no está disponible, en Debian y
  #         Raspbian podemos añadirlo mediante el repositorio Bullseye.
  # caso 3: Si el módulo no está integrado, en Raspbian conocemos
  #         el paquete de cabeceras: raspberrypi-kernel-headers
  # caso 4: En Alpine, el núcleo debe ser linux-lts o linux-virt
  #         si queremos cargar el módulo del núcleo
  # caso 5: En un Contenedor Docker Alpine, la responsabilidad de tener
  #         un módulo WireGuard en el sistema anfitrión es del usuario
  # caso 6: En un contenedor Alpine, wireguard-tools está disponible
  # caso 7: En Debian (y Ubuntu), solo podemos asumir de manera fiable el
  #         paquete de cabeceras para amd64: linux-image-amd64
  # caso 8: En Ubuntu, adicionalmente el paquete WireGuard debe estar
  #         disponible, ya que no probamos mezclar repositorios de Ubuntu.
  # caso 9: Ubuntu focal tiene soporte para wireguard

  if [[ "${WIREGUARD_BUILTIN}" -eq 1 && -n "${AVAILABLE_WIREGUARD}" ]] \
    || [[ "${WIREGUARD_BUILTIN}" -eq 1 && ("${PLAT}" == 'Debian' || "${PLAT}" == 'Raspbian') ]] \
    || [[ "${PLAT}" == 'Raspbian' ]] \
    || [[ "${PLAT}" == 'Alpine' && ! -f /.dockerenv && "$(uname -mrs)" =~ ^Linux\ +[0-9\.\-]+\-((lts)|(virt))\ +.*$ ]] \
    || [[ "${PLAT}" == 'Alpine' && -f /.dockerenv ]] \
    || [[ "${PLAT}" == 'Alpine' && -n "${AVAILABLE_WIREGUARD}" ]] \
    || [[ "${PLAT}" == 'Debian' && "${DPKG_ARCH}" == 'amd64' ]] \
    || [[ "${PLAT}" == 'Ubuntu' && "${DPKG_ARCH}" == 'amd64' && -n "${AVAILABLE_WIREGUARD}" ]] \
    || [[ "${PLAT}" == 'Ubuntu' && "${DPKG_ARCH}" == 'arm64' && "${OSCN}" == 'focal' && -n "${AVAILABLE_WIREGUARD}" ]]; then
    WIREGUARD_SUPPORT=1
  fi

  if [[ "${OPENVPN_SUPPORT}" -eq 0 ]] \
    && [[ "${WIREGUARD_SUPPORT}" -eq 0 ]]; then
    err "::: Ni OpenVPN ni WireGuard están disponibles para ser instalados por PiVPN, saliendo..."
    exit 1
  fi

  # si ufw está habilitado, configúralo.
  # ejecutando como root porque a veces el ejecutable no está en el $PATH del usuario
  if ${SUDO} bash -c 'command -v ufw' > /dev/null; then
    if ! ${SUDO} ufw status || ${SUDO} ufw status | grep -q inactive; then
      USING_UFW=0
    else
      USING_UFW=1
    fi
  else
    USING_UFW=0
  fi

  if [[ "${PKG_MANAGER}" == 'apt-get' ]] && [[ "${USING_UFW}" -eq 0 ]]; then
    BASE_DEPS+=(iptables-persistent)
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true \
      | ${SUDO} debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean false \
      | ${SUDO} debconf-set-selections
  fi

  if [[ "${PLAT}" == 'Alpine' ]] \
    && ! command -v grepcidr &> /dev/null; then
    local down_dir
    ## instalar dependencias
    # shellcheck disable=SC2086
    ${SUDO} ${PKG_INSTALL} build-base make curl tar

    if ! down_dir="$(mktemp -d)"; then
      err "::: ¡Fallo al crear el directorio de descarga para grepcidr!"
      exit 1
    fi

    ## descargar binarios
    curl -fLo "${down_dir}/master.tar.gz" \
      https://github.com/pivpn/grepcidr/archive/master.tar.gz
    tar -xzC "${down_dir}" -f "${down_dir}/master.tar.gz"

    (
      cd "${down_dir}/grepcidr-master" || exit

      ## personalizar binarios
      sed -i -E -e 's/^PREFIX\=.*/PREFIX\=\/usr\nCC\=gcc/' Makefile

      ## instalar
      make
      ${SUDO} make install

      if ! command -v grepcidr &> /dev/null; then
        err "::: ¡Fallo al compilar e instalar grepcidr!"
        exit
      fi
    ) || exit 1
  fi

  echo "USING_UFW=${USING_UFW}" >> "${tempsetupVarsFile}"
}

installDependentPackages() {
  # Instalar paquetes pasados a través del arreglo de argumentos
  # Sin spinner - entra en conflicto con set -e
  local FAILED=0
  local APTLOGFILE
  declare -a TO_INSTALL=()
  declare -a argArray1=("${!1}")

  for i in "${argArray1[@]}"; do
    echo -n ":::    Comprobando ${i}..."

    if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
      if dpkg-query -W -f='${Status}' "${i}" 2> /dev/null \
        | grep -q "ok installed"; then
        echo " ¡ya instalado!"
      else
        echo " ¡no instalado!"
        # Añadir este paquete a la lista de paquetes en el arreglo de argumentos que
        # necesitan ser instalados
        TO_INSTALL+=("${i}")
      fi
    elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
      if eval "${SUDO} ${CHECK_PKG_INSTALLED} ${i}" &> /dev/null; then
        echo " ¡ya instalado!"
      else
        echo " ¡no instalado!"
        # Añadir este paquete a la lista de paquetes en el arreglo de argumentos que
        # necesitan ser instalados
        TO_INSTALL+=("${i}")
      fi
    fi
  done

  APTLOGFILE="$(${SUDO} mktemp)"

  # shellcheck disable=SC2086
  ${SUDO} ${PKG_INSTALL} "${TO_INSTALL[@]}"

  for i in "${TO_INSTALL[@]}"; do
    if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
      if dpkg-query -W -f='${Status}' "${i}" 2> /dev/null \
        | grep -q "ok installed"; then
        echo ":::    ¡Paquete ${i} instalado correctamente!"
        # Añadir este paquete a la lista total de paquetes que realmente fueron
        # instalados por el script
        INSTALLED_PACKAGES+=("${i}")
      else
        echo ":::    ¡Fallo al instalar ${i}!"
        ((FAILED++))
      fi
    elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
      if eval "${SUDO} ${CHECK_PKG_INSTALLED} ${i}" &> /dev/null; then
        echo ":::    ¡Paquete ${i} instalado correctamente!"
        # Añadir este paquete a la lista total de paquetes que realmente fueron
        # instalados por el script
        INSTALLED_PACKAGES+=("${i}")
      else
        echo ":::    ¡Fallo al instalar ${i}!"
        ((FAILED++))
      fi
    fi
  done

  if [[ "${FAILED}" -gt 0 ]]; then
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]:" >&2
    ${SUDO} cat "${APTLOGFILE}" >&2
    exit 1
  fi
}

welcomeDialogs() {
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: Instalador Automatizado de PiVPN"
    echo -n "::: Este instalador transformará tu host ${PLAT} en un "
    echo "servidor OpenVPN o WireGuard!"
    echo "::: Iniciando interfaz de red"
    return
  fi

  # Mostrar el diálogo de bienvenida
  whiptail \
    --backtitle "Bienvenido" \
    --title "Instalador Automatizado de PiVPN" \
    --msgbox "¡Este instalador transformará tu Raspberry Pi en un \
servidor OpenVPN o WireGuard!" "${r}" "${c}"

  # Explicar la necesidad de una dirección estática
  whiptail \
    --backtitle "Iniciando interfaz de red" \
    --title "IP Estática Necesaria" \
    --msgbox "PiVPN es un SERVIDOR, por lo que necesita una DIRECCIÓN IP ESTÁTICA \
para funcionar correctamente.

En la siguiente sección, puedes elegir usar la configuración de red actual \
(DHCP) o editarla manualmente." "${r}" "${c}"
}

chooseInterface() {
  # Encontrar interfaces y permitir al usuario elegir una

  # Convertir las interfaces disponibles en un arreglo para que pueda usarse con
  # un diálogo de whiptail
  local interfacesArray=()
  # Número de interfaces disponibles
  local interfaceCount
  # Almacenamiento de variables de Whiptail
  local chooseInterfaceCmd
  # Almacenamiento temporal de opciones de Whiptail
  local chooseInterfaceOptions
  # Variable centinela del bucle
  local firstloop=1

  availableInterfaces="$(ip -o link)"

  if [[ "${showUnsupportedNICs}" == 'true' ]]; then
    # Mostrar cada interfaz de red, podría ser útil para quienes
    # instalan PiVPN dentro de máquinas virtuales o en Raspberry Pis
    # con adaptadores USB
    availableInterfaces="$(echo "${availableInterfaces}" \
      | awk '{print $2}')"
  else
    # Encontrar interfaces de red cuyo estado es UP (ACTIVO)
    availableInterfaces="$(echo "${availableInterfaces}" \
      | awk '/state UP/ {print $2}')"
  fi

  # Omitir interfaces virtuales, loopback y docker
  availableInterfaces="$(echo "${availableInterfaces}" \
    | cut -d ':' -f 1 \
    | cut -d '@' -f 1 \
    | grep -v -w 'lo' \
    | grep -v '^docker')"

  if [[ -z "${availableInterfaces}" ]]; then
    err "::: No se pudo encontrar ninguna interfaz de red activa, saliendo"
    exit 1
  else
    while read -r line; do
      mode="OFF"

      if [[ "${firstloop}" -eq 1 ]]; then
        firstloop=0
        mode="ON"
      fi

      interfacesArray+=("${line}" "available" "${mode}")
      ((interfaceCount++))
    done <<< "${availableInterfaces}"
  fi

  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${IPv4dev}" ]]; then
      if [[ "${interfaceCount}" -eq 1 ]]; then
        IPv4dev="${availableInterfaces}"
        echo -n "::: No se especificó interfaz para IPv4, pero solo ${IPv4dev} "
        echo "está disponible, usándola"
      else
        err "::: No se especificó interfaz para IPv4 y se falló al determinar una"
        exit 1
      fi
    else
      if ip -o link | grep -qw "${IPv4dev}"; then
        echo "::: Usando interfaz: ${IPv4dev} para IPv4"
      else
        err "::: La interfaz ${IPv4dev} para IPv4 no existe"
        exit 1
      fi
    fi

    if [[ "${pivpnenableipv6}" -eq 1 ]]; then
      if [[ -z "${IPv6dev}" ]]; then
        if [[ "${interfaceCount}" -eq 1 ]]; then
          IPv6dev="${availableInterfaces}"
          echo -n "::: No se especificó interfaz para IPv6, pero solo ${IPv6dev} "
          echo "está disponible, usándola"
        else
          err "::: No se especificó interfaz para IPv6 y se falló al determinar una"
          exit 1
        fi
      else
        if ip -o link | grep -qw "${IPv6dev}"; then
          echo "::: Usando interfaz: ${IPv6dev} para IPv6"
        else
          err "::: La interfaz ${IPv6dev} para IPv6 no existe"
          exit 1
        fi
      fi
    fi

    {
      echo "IPv4dev=${IPv4dev}"

      if [[ "${pivpnenableipv6}" -eq 1 ]] \
        && [[ -z "${IPv6dev}" ]]; then
        echo "IPv6dev=${IPv6dev}"
      fi
    } >> "${tempsetupVarsFile}"

    return
  else
    if [[ "${interfaceCount}" -eq 1 ]]; then
      IPv4dev="${availableInterfaces}"

      {
        echo "IPv4dev=${IPv4dev}"

        if [[ "${pivpnenableipv6}" -eq 1 ]]; then
          IPv6dev="${availableInterfaces}"
          echo "IPv6dev=${IPv6dev}"
        fi
      } >> "${tempsetupVarsFile}"

      return
    fi
  fi

  chooseInterfaceCmd=(whiptail
    --separate-output
    --radiolist "Elige una interfaz para IPv4 \
(presiona espacio para seleccionar):" "${r}" "${c}" "${interfaceCount}")

  if chooseInterfaceOptions="$("${chooseInterfaceCmd[@]}" \
    "${interfacesArray[@]}" \
    2>&1 > /dev/tty)"; then
    for desiredInterface in ${chooseInterfaceOptions}; do
      IPv4dev="${desiredInterface}"
      echo "::: Usando interfaz: ${IPv4dev}"
      echo "IPv4dev=${IPv4dev}" >> "${tempsetupVarsFile}"
    done
  else
    err "::: Cancelar seleccionado, saliendo...."
    exit 1
  fi

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    chooseInterfaceCmd=(whiptail
      --separate-output
      --radiolist "Elige una interfaz para IPv6, usualmente la misma usada por \
IPv4 (presiona espacio para seleccionar):" "${r}" "${c}" "${interfaceCount}")

    if chooseInterfaceOptions="$("${chooseInterfaceCmd[@]}" \
      "${interfacesArray[@]}" \
      2>&1 > /dev/tty)"; then
      for desiredInterface in ${chooseInterfaceOptions}; do
        IPv6dev="${desiredInterface}"
        echo "::: Usando interfaz: ${IPv6dev}"
        echo "IPv6dev=${IPv6dev}" >> "${tempsetupVarsFile}"
      done
    else
      err "::: Cancelar seleccionado, saliendo...."
      exit 1
    fi
  fi
}

checkStaticIpSupported() {
  # No es realmente robusto ni correcto, en realidad deberíamos verificar dhcpcd,
  # no la distribución, pero funciona en Raspbian y Debian.
  if [[ "${PLAT}" == "Raspbian" ]]; then
    return 0
  # Si estamos en 'Debian' pero el archivo raspi.list está presente,
  # entonces realmente estamos en Raspberry Pi OS de 64 bits.
  elif [[ "${PLAT}" == "Debian" ]] \
    && [[ -s /etc/apt/sources.list.d/raspi.list || -s /etc/apt/sources.list.d/raspi.sources ]]; then
    return 0
  else
    return 1
  fi
}

staticIpNotSupported() {
  if [[ "${runUnattended}" == 'true' ]]; then
    echo -n "::: Dado que creemos que no estás usando Raspberry Pi OS, "
    echo "no configuraremos una IP estática por ti."
    return
  fi

  # Si estamos en Ubuntu, entonces necesitan haber configurado previamente su red,
  # así que simplemente usa lo que tienes.
  whiptail \
    --backtitle "Información de IP" \
    --title "Información de IP" \
    --msgbox "Dado que creemos que no estás usando Raspberry Pi OS, no \
configuraremos una IP estática por ti.
Si estás en Amazon, de todos modos no puedes configurar una IP estática. Solo \
asegúrate de haber configurado una IP elástica en tu instancia antes de iniciar \
este instalador." "${r}" "${c}"
}

validIP() {
  local ip="${1}"
  local stat=1

  if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    OIFS="${IFS}"
    IFS='.'
    read -r -a ip <<< "${ip}"
    IFS="${OIFS}"

    [[ "${ip[0]}" -le 255 && "${ip[1]}" -le 255 && "${ip[2]}" -le 255 && "${ip[3]}" -le 255 ]]

    stat="$?"
  fi

  return "${stat}"
}

validIPAndNetmask() {
  # shellcheck disable=SC2178
  local ip="${1}"
  local stat=1

  # shellcheck disable=SC2178
  ip="${ip/\//.}"

  # shellcheck disable=SC2128
  if [[ "${ip}" =~ ^([0-9]{1,3}\.){4}[0-9]{1,2}$ ]]; then
    OIFS="${IFS}"
    IFS='.'
    # shellcheck disable=SC2128
    read -r -a ip <<< "${ip}"
    IFS="${OIFS}"

    [[ "${ip[0]}" -le 255 && "${ip[1]}" -le 255 && "${ip[2]}" -le 255 && "${ip[3]}" -le 255 && "${ip[4]}" -le 32 ]]

    stat="$?"
  fi

  return "${stat}"
}

checkipv6uplink() {
  curl \
    --max-time 3 \
    --connect-timeout 3 \
    --silent \
    -6 \
    https://google.com \
    > /dev/null
  curlv6testres="$?"

  if [[ "${curlv6testres}" -ne 0 ]]; then
    echo -n "::: Las conexiones de prueba IPv6 a google.com han fallado. "
    echo -n "Deshabilitando el soporte de IPv6. "
    echo "(La prueba de curl falló con el código: ${curlv6testres})"
    pivpnenableipv6=0
  else
    echo -n "::: Conexiones de prueba IPv6 a google.com exitosas. "
    echo "Habilitando el soporte de IPv6."
    pivpnenableipv6=1
  fi
}

askforcedipv6route() {
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: Habilitar ruta IPv6 forzada sin enlace ascendente IPv6 en el servidor."
    echo "pivpnforceipv6route=${pivpnforceipv6route}" >> "${tempsetupVarsFile}"
    return
  fi

  if whiptail \
    --backtitle "Configuración de privacidad" \
    --title "Filtración de IPv6" \
    --yesno "Aunque este servidor no parece tener una conexión IPv6 \
en funcionamiento o IPv6 se deshabilitó a propósito, todavía se \
recomienda forzar todas las conexiones IPv6 por la VPN.\\n\\nEsto \
evitará que el cliente evite el túnel y filtre su IPv6 a servidores, \
aunque podría causar que el cliente tenga una respuesta lenta al \
navegar por la web en redes IPv6.

¿Quieres forzar el enrutamiento de IPv6 para bloquear la filtración?" "${r}" "${c}"; then
    pivpnforceipv6route=1
  else
    pivpnforceipv6route=0
  fi

  echo "pivpnforceipv6route=${pivpnforceipv6route}" >> "${tempsetupVarsFile}"
}

getStaticIPv4Settings() {
  # Encontrar la IP de la puerta de enlace utilizada para enrutar al mundo exterior
  CurrentIPv4gw="$(ip -o route get 192.0.2.1 \
    | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
    | awk 'NR==2')"

  # Encontrar la dirección IP (y máscara de red) de la interfaz deseada
  CurrentIPv4addr="$(ip -o -f inet address show dev "${IPv4dev}" \
    | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\/[0-9]{1,2}')"

  # Obtener sus servidores DNS actuales
  IPv4dns="$(grep -v "^#" /etc/resolv.conf \
    | grep -w nameserver \
    | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
    | xargs)"

  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${dhcpReserv}" ]] \
      || [[ "${dhcpReserv}" -ne 1 ]]; then
      local MISSING_STATIC_IPV4_SETTINGS=0

      if [[ -z "${IPv4addr}" ]]; then
        echo "::: Falta la dirección IP estática"
        ((MISSING_STATIC_IPV4_SETTINGS++))
      fi

      if [[ -z "${IPv4gw}" ]]; then
        echo "::: Falta la puerta de enlace IP estática"
        ((MISSING_STATIC_IPV4_SETTINGS++))
      fi

      if [[ "${MISSING_STATIC_IPV4_SETTINGS}" -eq 0 ]]; then
        # Si ambas configuraciones no están vacías, verificar si son válidas y proceder
        if validIPAndNetmask "${IPv4addr}"; then
          echo "::: Tu dirección IPv4 estática:    ${IPv4addr}"
        else
          err "::: ${IPv4addr} no es una dirección IP válida"
          exit 1
        fi

        if validIP "${IPv4gw}"; then
          echo "::: Tu puerta de enlace IPv4 estática:    ${IPv4gw}"
        else
          err "::: ${IPv4gw} no es una dirección IP válida"
          exit 1
        fi
      elif [[ "${MISSING_STATIC_IPV4_SETTINGS}" -eq 1 ]]; then
        # Si falta alguna de las configuraciones, considerar que la entrada es inconsistente
        err "::: Configuraciones de IP estática incompletas"
        exit 1
      elif [[ "${MISSING_STATIC_IPV4_SETTINGS}" -eq 2 ]]; then
        # Si faltan ambas configuraciones,
        # asumir que el usuario desea usar las configuraciones actuales
        IPv4addr="${CurrentIPv4addr}"
        IPv4gw="${CurrentIPv4gw}"
        echo "::: Sin configuraciones de IP estática, usando las configuraciones actuales"
        echo "::: Tu dirección IPv4 estática:    ${IPv4addr}"
        echo "::: Tu puerta de enlace IPv4 estática:    ${IPv4gw}"
      fi
    else
      echo "::: Omitiendo la configuración de la dirección IP estática"
    fi

    {
      echo "dhcpReserv=${dhcpReserv}"
      echo "IPv4addr=${IPv4addr}"
      echo "IPv4gw=${IPv4gw}"
    } >> "${tempsetupVarsFile}"
    return
  fi

  local ipSettingsCorrect
  local IPv4AddrValid
  local IPv4gwValid
  # Algunos usuarios reservan direcciones IP en otro servidor DHCP o en sus enrutadores,
  # preguntemos si desean realizar algún cambio en sus interfaces.

  if whiptail \
    --backtitle "Calibrando la interfaz de red" \
    --title "Reserva DHCP" \
    --defaultno \
    --yesno "¿Estás usando una reserva DHCP en tu enrutador/servidor DHCP?
Estas son tus configuraciones de red actuales:

			Dirección IP:    ${CurrentIPv4addr}
			Puerta de enlace:       ${CurrentIPv4gw}

Sí: Seguir usando la reserva DHCP
No: Configurar una dirección IP estática
¿No sabes qué es una reserva DHCP? Responde No." "${r}" "${c}"; then
    dhcpReserv=1

    {
      echo "dhcpReserv=${dhcpReserv}"
      # En realidad no necesitamos guardarlas ya que no configuraremos una IP estática
      # pero podrían ser útiles para la depuración
      echo "IPv4addr=${CurrentIPv4addr}"
      echo "IPv4gw=${CurrentIPv4gw}"
    } >> "${tempsetupVarsFile}"
  else
    # Preguntar si el usuario desea usar las configuraciones de DHCP como su IP estática
    if whiptail \
      --backtitle "Calibrando la interfaz de red" \
      --title "Dirección IP estática" \
      --yesno "¿Deseas usar tus configuraciones de red actuales como una dirección \
estática?

				Dirección IP:    ${CurrentIPv4addr}
				Puerta de enlace:       ${CurrentIPv4gw}" "${r}" "${c}"; then
      IPv4addr="${CurrentIPv4addr}"
      IPv4gw="${CurrentIPv4gw}"

      {
        echo "IPv4addr=${IPv4addr}"
        echo "IPv4gw=${IPv4gw}"
      } >> "${tempsetupVarsFile}"

      # Si eligen sí, informarle al usuario que la dirección IP no estará
      # disponible a través de DHCP y podría causar un conflicto.
      whiptail \
        --backtitle "Información de IP" \
        --title "Nota: Conflicto de IP" \
        --msgbox "Es posible que tu enrutador intente asignar esta IP a \
otro dispositivo, lo que causaría un conflicto. Pero en la mayoría de los casos el \
enrutador es lo suficientemente inteligente como para no hacerlo.
Si te preocupa, puedes establecer la dirección manualmente, o modificar el \
rango de reserva DHCP para que no incluya la IP que deseas.
También es posible usar una reserva DHCP, pero si vas a hacer \
eso, lo mejor sería configurar una dirección estática directamente." "${r}" "${c}"
      # Nada más que hacer ya que las variables ya se establecieron arriba
    else
      # De lo contrario, debemos pedirle al usuario que introduzca las configuraciones deseadas.
      # Comenzar por obtener la dirección IPv4
      # (completándola previamente con la información recopilada de DHCP)
      # Iniciar un bucle para permitir al usuario introducir su información con la posibilidad
      # de volver atrás y editarla si es necesario
      until [[ "${ipSettingsCorrect}" == 'true' ]]; do
        until [[ "${IPv4AddrValid}" == 'true' ]]; do
          # Solicitar la dirección IPv4
          if IPv4addr="$(whiptail \
            --backtitle "Calibrando la interfaz de red" \
            --title "Dirección IPv4" \
            --inputbox "Introduce la dirección \
IPv4 deseada" "${r}" "${c}" "${CurrentIPv4addr}" \
            3>&1 1>&2 2>&3)"; then
            if validIPAndNetmask "${IPv4addr}"; then
              echo "::: Tu dirección IPv4 estática:    ${IPv4addr}"
              IPv4AddrValid=true
            else
              whiptail \
                --backtitle "Calibrando la interfaz de red" \
                --title "Dirección IPv4" \
                --msgbox "Has introducido una dirección IP no válida: ${IPv4addr}

Por favor, introduce una dirección IP en notación CIDR, ejemplo: 192.168.23.211/24

Si no estás seguro, simplemente mantén la opción predeterminada." "${r}" "${c}"
              echo "::: Dirección IPv4 no válida:    ${IPv4addr}"
              IPv4AddrValid=false
            fi
          else
            # Cancelando la ventana de configuración de IPv4
            err "::: Cancelación seleccionada. Saliendo..."
            exit 1
          fi
        done

        until [[ "${IPv4gwValid}" == 'true' ]]; do
          # Solicitar la puerta de enlace
          if IPv4gw="$(whiptail \
            --backtitle "Calibrando la interfaz de red" \
            --title "Puerta de enlace IPv4 (enrutador)" \
            --inputbox "Introduce la puerta de enlace predeterminada IPv4 \
deseada" "${r}" "${c}" "${CurrentIPv4gw}" \
            3>&1 1>&2 2>&3)"; then
            if validIP "${IPv4gw}"; then
              echo "::: Tu puerta de enlace IPv4 estática:    ${IPv4gw}"
              IPv4gwValid=true
            else
              whiptail \
                --backtitle "Calibrando la interfaz de red" \
                --title "Puerta de enlace IPv4 (enrutador)" \
                --msgbox "Has introducido una IP de puerta de enlace no válida: ${IPv4gw}

Por favor, introduce la dirección IP de tu puerta de enlace (enrutador), ejemplo: 192.168.23.1

Si no estás seguro, simplemente mantén la opción predeterminada." "${r}" "${c}"
              echo "::: Puerta de enlace IPv4 no válida:    ${IPv4gw}"
              IPv4gwValid=false
            fi
          else
            # Cancelando la ventana de configuración de la puerta de enlace
            err "::: Cancelación seleccionada. Saliendo..."
            exit 1
          fi
        done

        # Dar al usuario la oportunidad de revisar sus configuraciones antes de continuar
        if whiptail \
          --backtitle "Calibrando la interfaz de red" \
          --title "Dirección IP estática" \
          --yesno "¿Son correctas estas configuraciones?

						Dirección IP:    ${IPv4addr}
						Puerta de enlace:       ${IPv4gw}" "${r}" "${c}"; then
          # Si las configuraciones son correctas, entonces necesitamos establecer la pivpnIP
          echo "IPv4addr=${IPv4addr}" >> "${tempsetupVarsFile}"
          echo "IPv4gw=${IPv4gw}" >> "${tempsetupVarsFile}"
          # Una vez hecho esto, el bucle termina y continuamos
          ipSettingsCorrect=true
        else
          # Si las configuraciones son incorrectas, el bucle continúa
          ipSettingsCorrect=false
          IPv4AddrValid=false
          IPv4gwValid=false
        fi
      done
      # Fin de la declaración if para DHCP vs. estática
    fi
    # Fin de la declaración if para la Reserva DHCP
  fi
}

setDHCPCD() {
  if [[ -f /etc/dhcpcd.conf ]]; then
    if grep -q "${IPv4addr}" "${dhcpcdFile}"; then
      echo "::: IP estática ya configurada."
    else
      writeDHCPCDConf
      ${SUDO} ip addr replace dev "${IPv4dev}" "${IPv4addr}"
      echo ":::"
      echo -n "::: Estableciendo la IP a ${IPv4addr}.  "
      echo "Es posible que debas reiniciar una vez completada la instalación."
      echo ":::"
    fi
  else
    err "::: Crítico: ¡No se pudo localizar el archivo de configuración para establecer la dirección IPv4 estática!"
    exit 1
  fi
}

writeDHCPCDConf() {
  # Añadir estas líneas a dhcpcd.conf para habilitar una IP estática
  {
    echo "interface ${IPv4dev}"
    echo "static ip_address=${IPv4addr}"
    echo "static routers=${IPv4gw}"
    echo "static domain_name_servers=${IPv4dns}"
  } | ${SUDO} tee -a "${dhcpcdFile}" > /dev/null

}

setNetworkManager() {
  connectionUUID=$(nmcli -t con show --active \
    | awk -v ref="${IPv4dev}" -F: 'match($0, ref){print $2}')

  ${SUDO} nmcli con mod "${connectionUUID}" \
    ipv4.addresses "${IPv4addr}" \
    ipv4.gateway "${IPv4gw}" \
    ipv4.dns "${IPv4dns}" \
    ipv4.method "manual"
}

setStaticIPv4() {
  # Intenta establecer la dirección IPv4
  if [[ -v useNetworkManager ]]; then
    echo "::: Usando Network manager"
    setNetworkManager
    echo "useNetworkManager=${useNetworkManager}" >> "${tempsetupVarsFile}"
  else
    echo "::: Usando DHCPCD"
    setDHCPCD
  fi
}

chooseUser() {
  # Elegir el usuario para los archivos ovpn
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${install_user}" ]]; then
      if [[ "$(awk -F ':' \
        'BEGIN {count=0} $3>=1000 && $3<=60000 { count++ } END{ print count }' \
        /etc/passwd)" -eq 1 ]]; then
        install_user="$(awk -F ':' \
          '$3>=1000 && $3<=60000 {print $1}' \
          /etc/passwd)"
        echo -n "::: No se especificó ningún usuario, pero solo ${install_user} está disponible, "
        echo "usándolo"
      else
        err "::: No se especificó ningún usuario"
        exit 1
      fi
    else
      if awk -F':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd \
        | grep -qw "${install_user}"; then
        echo "::: ${install_user} contendrá los archivos de configuración de tus clientes VPN."
      else
        echo "::: El usuario ${install_user} no existe, creando..."

        if [[ "${PLAT}" == 'Alpine' ]]; then
          ${SUDO} adduser -s /bin/bash "${install_user}"
          ${SUDO} addgroup "${install_user}" wheel
        else
          ${SUDO} useradd -ms /bin/bash "${install_user}"
        fi

        echo -n "::: Usuario creado sin contraseña, "
        echo "por favor ejecuta 'sudo passwd ${install_user}' para crear una"
      fi
    fi

    install_home="$(grep -m1 "^${install_user}:" /etc/passwd \
      | cut -d ':' -f 6)"
    install_home="${install_home%/}"

    {
      echo "install_user=${install_user}"
      echo "install_home=${install_home}"
    } >> "${tempsetupVarsFile}"
    return
  fi

  # Explicar el usuario local
  whiptail \
    --msgbox \
    --backtitle "Analizando la lista de usuarios" \
    --title "Usuarios locales" \
    "Elige un usuario local que contendrá tus configuraciones ovpn." \
    "${r}" \
    "${c}"
  # Primero, verifiquemos si hay un usuario disponible.
  numUsers="$(awk -F ':' \
    'BEGIN {count=0} $3>=1000 && $3<=60000 { count++ } END{ print count }' \
    /etc/passwd)"

  if [[ "${numUsers}" -eq 0 ]]; then
    # No tenemos un usuario, vamos a pedir añadir uno.
    if userToAdd="$(whiptail \
      --title "Elegir un usuario" \
      --inputbox \
      "No se encontró ninguna cuenta de usuario que no sea root. Escribe un nombre de usuario." \
      "${r}" \
      "${c}" \
      3>&1 1>&2 2>&3)"; then
      # See https://askubuntu.com/a/667842/459815
      PASSWORD="$(whiptail \
        --title "diálogo de contraseña" \
        --passwordbox \
        "Por favor, introduce la contraseña del nuevo usuario" \
        "${r}" \
        "${c}" \
        3>&1 1>&2 2>&3)"
      CRYPT="$(perl \
        -e 'printf("%s\n", crypt($ARGV[0], "password"))' "${PASSWORD}")"

      if [[ "${PLAT}" == 'Alpine' ]]; then
        if ${SUDO} adduser -Ds /bin/bash "${userToAdd}"; then
          ${SUDO} addgroup "${userToAdd}" wheel

          ${SUDO} chpasswd <<< "${userToAdd}:${PASSWORD}"
          ${SUDO} passwd -u "${userToAdd}"

          echo "Exitoso"
          ((numUsers += 1))
        else
          exit 1
        fi
      else
        if ${SUDO} useradd -mp "${CRYPT}" -s /bin/bash "${userToAdd}"; then
          echo "Exitoso"
          ((numUsers += 1))
        else
          exit 1
        fi
      fi
    else
      exit 1
    fi
  fi

  availableUsers="$(awk -F':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd)"
  local userArray=()
  local firstloop=1

  while read -r line; do
    mode="OFF"

    if [[ "${firstloop}" -eq 1 ]]; then
      firstloop=0
      mode="ON"
    fi

    userArray+=("${line}" "" "${mode}")
  done <<< "${availableUsers}"

  chooseUserCmd=(whiptail
    --title "Elegir un usuario"
    --separate-output
    --radiolist
    "Elige (presiona espacio para seleccionar):"
    "${r}"
    "${c}"
    "${numUsers}")

  if chooseUserOptions=$("${chooseUserCmd[@]}" \
    "${userArray[@]}" \
    2>&1 > /dev/tty); then
    for desiredUser in ${chooseUserOptions}; do
      install_user=${desiredUser}
      echo "::: Usando el usuario: ${install_user}"
      install_home=$(grep -m1 "^${install_user}:" /etc/passwd \
        | cut -d ':' -f 6)
      install_home=${install_home%/} # eliminar la posible barra diagonal final

      {
        echo "install_user=${install_user}"
        echo "install_home=${install_home}"
      } >> "${tempsetupVarsFile}"
    done
  else
    err "::: Cancelar seleccionado, saliendo...."
    exit 1
  fi
}

isRepo() {
  # Si el directorio no tiene una carpeta .git no es un repositorio
  echo -n ":::    Verificando si ${1} es un repositorio..."
  cd "${1}" &> /dev/null || {
    echo " ¡no encontrado!"
    return 1
  }
  ${SUDO} ${GITBIN} status &> /dev/null && echo " ¡OK!"
  #shellcheck disable=SC2317
  return 0 || echo " ¡no encontrado!"
  #shellcheck disable=SC2317
  return 1
}

updateRepo() {
  if [[ "${UpdateCmd}" == "Repair" ]]; then
    echo -n "::: Reparando una instalación existente, "
    echo "no se descargarán/actualizarán los repositorios locales"
  else
    # Obtener las últimas confirmaciones (commits)
    echo -n ":::     Actualizando el repositorio en ${1} desde ${2} ..."

    ### CORRÍGEME: Nunca llames a rm -rf con una variable simple. ¡Nunca más como SU!
    #${SUDO} rm -rf "${1}"
    if [[ -n "${1}" ]]; then
      ${SUDO} rm -rf "$(dirname "${1}")/pivpn"
    fi

    # Regresar a /usr/local/src de lo contrario git se quejará cuando el
    # directorio de trabajo actual acabe de ser eliminado (/usr/local/src/pivpn).
    cd /usr/local/src \
      && ${SUDO} ${GITBIN} clone -q \
        --depth 1 \
        --no-single-branch \
        "${2}" \
        "${1}" \
        > /dev/null &
    spinner $!
    cd "${1}" || exit 1
    echo " ¡hecho!"

    if [[ -n "${pivpnGitBranch}" ]]; then
      echo ":::     Cambiando a la rama '${pivpnGitBranch}' de ${2} en ${1}..."
      ${SUDOE} ${GITBIN} checkout -q "${pivpnGitBranch}"
      echo ":::     ¡Cambio a la rama personalizada hecho!"
    elif [[ -z "${TESTING+x}" ]]; then
      :
    else
      echo ":::     Cambiando a la rama 'test' de ${2} en ${1}..."
      ${SUDOE} ${GITBIN} checkout -q test
      echo ":::     ¡Cambio a la rama 'test' hecho!"
    fi
  fi
}

makeRepo() {
  # Eliminar la interfaz que no es un repositorio y clonar la interfaz
  echo -n ":::    Clonando ${2} en ${1} ..."

  ### CORRÍGEME: Nunca llames a rm -rf con una variable simple. ¡Nunca más como SU!
  #${SUDO} rm -rf "${1}"
  if [[ -n "${1}" ]]; then
    ${SUDO} rm -rf "$(dirname "${1}")/pivpn"
  fi

  # Regresar a /usr/local/src de lo contrario git se quejará cuando el
  # directorio de trabajo actual acabe de ser eliminado (/usr/local/src/pivpn).
  cd /usr/local/src \
    && ${SUDO} ${GITBIN} clone -q \
      --depth 1 \
      --no-single-branch \
      "${2}" \
      "${1}" \
      > /dev/null &
  spinner $!
  cd "${1}" || exit 1
  echo " ¡hecho!"

  if [[ -n "${pivpnGitBranch}" ]]; then
    echo ":::     Cambiando a la rama '${pivpnGitBranch}' de ${2} en ${1}..."
    ${SUDOE} ${GITBIN} checkout -q "${pivpnGitBranch}"
    echo ":::     ¡Cambio a la rama personalizada hecho!"
  elif [[ -z "${TESTING+x}" ]]; then
    :
  else
    echo ":::     Cambiando a la rama 'test' de ${2} en ${1}..."
    ${SUDOE} ${GITBIN} checkout -q test
    echo ":::     ¡Cambio a la rama 'test' hecho!"
  fi
}

getGitFiles() {
  # Configurar repositorios git para archivos base
  echo ":::"
  echo "::: Verificando si existen archivos base..."

  if isRepo "${1}"; then
    updateRepo "${1}" "${2}"
  else
    makeRepo "${1}" "${2}"
  fi
}

cloneOrUpdateRepos() {
  # Clonar/Actualizar los repositorios
  # /usr/local siempre debería existir, aunque no estoy seguro de la subcarpeta src
  ${SUDO} mkdir -p /usr/local/src

  # Obtener archivos de Git
  getGitFiles "${pivpnFilesDir}" "${pivpnGitUrl}" \
    || {
      err "!!! No se pudo clonar ${pivpnGitUrl} en ${pivpnFilesDir}, no se puede continuar."
      exit 1
    }
}

installPiVPN() {
  ${SUDO} mkdir -p /etc/pivpn/
  askWhichVPN
  setVPNDefaultVars

  if [[ "${VPN}" == 'openvpn' ]]; then
    setOpenVPNDefaultVars
    askAboutCustomizing
    installOpenVPN
    askCustomProto
  elif [[ "${VPN}" == 'wireguard' ]]; then
    setWireguardDefaultVars
    installWireGuard
  fi

  askCustomPort
  askClientDNS

  if [[ "${VPN}" == 'openvpn' ]]; then
    askCustomDomain
  fi

  askPublicIPOrDNS

  if [[ "${VPN}" == 'openvpn' ]]; then
    askEncryption
    confOpenVPN
    confOVPN
  elif [[ "${VPN}" == 'wireguard' ]]; then
    confWireGuard
  fi

  confNetwork

  if [[ "${VPN}" == 'openvpn' ]]; then
    if [[ "${PLAT}" == 'Alpine' ]]; then
      confLogging
    fi
  elif [[ "${VPN}" == 'wireguard' ]]; then
    writeWireguardTempVarsFile
  fi

  writeVPNTempVarsFile
}

decIPv4ToDot() {
  local a b c d
  a=$((($1 & 4278190080) >> 24))
  b=$((($1 & 16711680) >> 16))
  c=$((($1 & 65280) >> 8))
  d=$(($1 & 255))
  printf "%s.%s.%s.%s\n" $a $b $c $d
}

dotIPv4ToDec() {
  local original_ifs=$IFS
  IFS='.'
  read -r -a array_ip <<< "$1"
  IFS=$original_ifs
  printf "%s\n" $((array_ip[0] * 16777216 + array_ip[1] * 65536 + array_ip[2] * 256 + array_ip[3]))
}

dotIPv4FirstDec() {
  local decimal_ip decimal_mask
  decimal_ip=$(dotIPv4ToDec "$1")
  decimal_mask=$((2 ** 32 - 1 ^ (2 ** (32 - $2) - 1)))
  printf "%s\n" "$((decimal_ip & decimal_mask))"
}

dotIPv4LastDec() {
  local decimal_ip decimal_mask_inv
  decimal_ip=$(dotIPv4ToDec "$1")
  decimal_mask_inv=$((2 ** (32 - $2) - 1))
  printf "%s\n" "$((decimal_ip | decimal_mask_inv))"
}

decIPv4ToHex() {
  local hex
  hex="$(printf "%08x\n" "$1")"
  quartet_hi=${hex:0:4}
  quartet_lo=${hex:4:4}
  # Elimina los ceros a la izquierda de los cuartetos, puramente por razones estéticas
  # Fuente: https://stackoverflow.com/a/19861690
  leading_zeros_hi="${quartet_hi%%[!0]*}"
  leading_zeros_lo="${quartet_lo%%[!0]*}"
  printf "%s:%s\n" "${quartet_hi#"${leading_zeros_hi}"}" "${quartet_lo#"${leading_zeros_lo}"}"
}

cidrToMask() {
  # Fuente: https://stackoverflow.com/a/20767392
  set -- $((5 - (${1} / 8))) \
    255 255 255 255 \
    $(((255 << (8 - (${1} % 8))) & 255)) \
    0 0 0
  shift "${1}"
  echo "${1-0}.${2-0}.${3-0}.${4-0}"
}

setVPNDefaultVars() {
  # Permitir un subnetClass personalizado a través del archivo desatendido setupVARs.
  # Usar el valor predeterminado si no se proporciona.
  if [[ -z "${subnetClass}" ]]; then
    subnetClass="24"
  fi

  if [[ -z "${subnetClassv6}" ]]; then
    subnetClassv6="64"
  fi
}

generateRandomSubnet() {
  # Fuente: https://community.openvpn.net/openvpn/wiki/AvoidRoutingConflicts
  declare -a excluded_subnets_dec=(
    167772160 167772415   # 10.0.0.0/24
    167772416 167772671   # 10.0.1.0/24
    167837952 167838207   # 10.1.1.0/24
    167840256 167840511   # 10.1.10.0/24
    167903232 167903487   # 10.2.0.0/24
    168296448 168296703   # 10.8.0.0/24
    168427776 168428031   # 10.10.1.0/24
    173693440 173693695   # 10.90.90.0/24
    174326016 174326271   # 10.100.1.0/24
    184549120 184549375   # 10.255.255.0/24
    3232235520 3232235775 # 192.168.0.0/24
    3232235776 3232236031 # 192.168.1.0/24
  )

  # Añadir rangos numéricos al arreglo anterior
  readarray -t currently_used_subnets <<< "$(ip route show \
    | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\/[0-9]{1,2}')"

  local used used_ip used_mask
  for used in "${currently_used_subnets[@]}"; do
    used_ip="${used%/*}"
    used_mask="${used##*/}"

    excluded_subnets_dec+=("$(dotIPv4FirstDec "$used_ip" "$used_mask")")
    excluded_subnets_dec+=("$(dotIPv4LastDec "$used_ip" "$used_mask")")
  done

  # Nota: la longitud del arreglo excluded_subnets_count es el doble del número de subnets
  local excluded_subnets_count="${#excluded_subnets_dec[@]}"

  local source_subnet="$1"
  local source_ip="${source_subnet%/*}"
  # shellcheck disable=SC2155
  local source_ip_dec="$(dotIPv4ToDec "$source_ip")"
  local source_netmask="${source_subnet##*/}"
  local source_netmask_dec="$((2 ** 32 - 1 ^ (2 ** (32 - source_netmask) - 1)))"

  local target_netmask="$2"

  local first_ip_target_subnet_dec="$((source_ip_dec & source_netmask_dec))"
  local total_ips_target_subnet="$((2 ** (32 - target_netmask)))"

  # Elegir una subred aleatoria haría que se verificaran las mismas subredes varias
  # veces si el número de subredes fuera pequeño, por lo que en su lugar se escanea
  # una permutación aleatoria para verificar cada subred solo una vez.
  local subnets_count="$((2 ** (target_netmask - source_netmask)))"
  readarray -t random_perm <<< "$(shuf -i 0-"$((subnets_count - 1))")"
  # random_perm=( 3221 9 8 431 7 [...] )

  # Debido a las limitaciones de rendimiento de bash, no es práctico verificar todas las subredes.
  # Teniendo en cuenta que el script de instalación no debería colgarse demasiado tiempo incluso
  # en una Pi Zero, evitamos hacer más de unas 5000 iteraciones.
  local max_tries="$subnets_count"
  if [ $((subnets_count * excluded_subnets_count)) -ge 5000 ]; then
    max_tries="$((5000 / (excluded_subnets_count / 2)))"
  fi

  local first_ip_subnet_dec last_ip_subnet_dec
  local first_ip_excluded_subnet_dec last_ip_excluded_subnet_dec
  local overlap
  for ((i = 0; i < max_tries; i++)); do

    first_ip_subnet_dec="$((first_ip_target_subnet_dec + total_ips_target_subnet * random_perm[i]))"
    last_ip_subnet_dec="$((first_ip_subnet_dec + total_ips_target_subnet - 1))"

    overlap=false

    for ((j = 0; j < excluded_subnets_count; j += 2)); do

      first_ip_excluded_subnet_dec="${excluded_subnets_dec[$j]}"
      last_ip_excluded_subnet_dec="${excluded_subnets_dec[$j + 1]}"

      #                              |-------------subnet2------------|
      #           |----------subnet1-----------|                      |
      #           |                  |         |                      |
      # first_ip_excluded_subnet_dec | last_ip_excluded_subnet_dec    |
      #                              |                                |
      #                   first_ip_subnet_dec                last_ip_subnet_dec
      if ((last_ip_excluded_subnet_dec >= first_ip_subnet_dec)) \
        && ((first_ip_excluded_subnet_dec <= last_ip_subnet_dec)); then
        overlap=true
        break
      fi

    done

    if ! "$overlap"; then
      decIPv4ToDot "$first_ip_subnet_dec"
      break
    fi
  done
}

setOpenVPNDefaultVars() {
  pivpnDEV="tun0"

  # Permitir un NET personalizado a través del archivo desatendido setupVARs.
  # Usar el valor predeterminado si no se proporciona.
  if [[ -z "${pivpnNET}" ]]; then
    echo "::: Generando subred aleatoria en la red 10.0.0.0/8..."
    pivpnNET="$(generateRandomSubnet "10.0.0.0/8" "$subnetClass")"
  fi

  if [[ -z "${pivpnNET}" ]]; then
    echo "::: La red 10.0.0.0/8 no está disponible, probando con 172.16.0.0/12 a continuación..."
    pivpnNET="$(generateRandomSubnet "172.16.0.0/12" "$subnetClass")"
  fi

  if [[ -z "${pivpnNET}" ]]; then
    echo "::: La red 172.16.0.0/12 no está disponible, probando con 192.168.0.0/16 a continuación..."
    pivpnNET="$(generateRandomSubnet "192.168.0.0/16" "$subnetClass")"
  fi

  if [[ -z "${pivpnNET}" ]]; then
    # Esto no debería ocurrir en la práctica
    echo "::: No se pudo generar una subred aleatoria para PiVPN. Parece que todas las redes privadas están en uso."
    exit 1
  fi

  pivpnNETdec="$(dotIPv4ToDec "${pivpnNET}")"

  vpnGwdec="$((pivpnNETdec + 1))"
  vpnGw="$(decIPv4ToDot "${vpnGwdec}")"
  vpnGwhex="$(decIPv4ToHex "${vpnGwdec}")"

  if [[ "${pivpnenableipv6}" -eq 1 ]] \
    && [[ -z "${pivpnNETv6}" ]]; then
    pivpnNETv6="fd11:5ee:bad:c0de::"
  fi

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    vpnGwv6="${pivpnNETv6}${vpnGwhex}"
  fi
}

setWireguardDefaultVars() {
  # Dado que WireGuard solo usa UDP, nunca se llama a askCustomProto(),
  # por lo que establecemos el protocolo aquí.
  pivpnPROTO="udp"
  pivpnDEV="wg0"

  # Permitir un NET personalizado a través del archivo desatendido setupVARs.
  # Usar el valor predeterminado si no se proporciona.
  if [[ -z "${pivpnNET}" ]]; then
    echo "::: Generando subred aleatoria en la red 10.0.0.0/8..."
    pivpnNET="$(generateRandomSubnet "10.0.0.0/8" "$subnetClass")"
  fi

  if [[ -z "${pivpnNET}" ]]; then
    echo "::: La red 10.0.0.0/8 no está disponible, probando con 172.16.0.0/12 a continuación..."
    pivpnNET="$(generateRandomSubnet "172.16.0.0/12" "$subnetClass")"
  fi

  if [[ -z "${pivpnNET}" ]]; then
    echo "::: La red 172.16.0.0/12 no está disponible, probando con 192.168.0.0/16 a continuación..."
    pivpnNET="$(generateRandomSubnet "192.168.0.0/16" "$subnetClass")"
  fi

  if [[ -z "${pivpnNET}" ]]; then
    # Esto no debería ocurrir en la práctica
    echo "::: No se pudo generar una subred aleatoria para PiVPN. Parece que todas las redes privadas están en uso."
    exit 1
  fi

  pivpnNETdec="$(dotIPv4ToDec "${pivpnNET}")"

  vpnGwdec="$((pivpnNETdec + 1))"
  vpnGw="$(decIPv4ToDot "${vpnGwdec}")"
  vpnGwhex="$(decIPv4ToHex "${vpnGwdec}")"

  if [[ "${pivpnenableipv6}" -eq 1 ]] \
    && [[ -z "${pivpnNETv6}" ]]; then
    pivpnNETv6="fd11:5ee:bad:c0de::"
  fi

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    vpnGwv6="${pivpnNETv6}${vpnGwhex}"
  fi

  # Permitir IPs permitidas personalizadas a través del archivo desatendido setupVARs.
  # Usar el valor predeterminado si no se proporciona.
  if [[ -z "${ALLOWED_IPS}" ]]; then
    ALLOWED_IPS="0.0.0.0/0"

    # Reenviar todo el tráfico a través de PiVPN (es decir, túnel completo), puede ser modificado por
    # el usuario después de la instalación.
    if [[ "${pivpnenableipv6}" -eq 1 ]] \
      || [[ "${pivpnforceipv6route}" -eq 1 ]]; then
      ALLOWED_IPS="${ALLOWED_IPS}, ::0/0"
    fi
  fi

  # La MTU predeterminada debería estar bien para la mayoría de los usuarios, pero permitimos establecer una
  # MTU personalizada a través del archivo desatendido setupVARs. Usar el valor predeterminado si no se proporciona.
  if [[ -z "${pivpnMTU}" ]]; then
    # Usando la MTU predeterminada de Wireguard
    pivpnMTU="1420"
  fi

  CUSTOMIZE=0
}

writeVPNTempVarsFile() {
  {
    echo "pivpnDEV=${pivpnDEV}"
    echo "pivpnNET=${pivpnNET}"
    echo "subnetClass=${subnetClass}"
    echo "pivpnenableipv6=${pivpnenableipv6}"

    if [[ "${pivpnenableipv6}" -eq 1 ]]; then
      echo "pivpnNETv6=\"${pivpnNETv6}\""
      echo "subnetClassv6=${subnetClassv6}"
    fi

    echo "ALLOWED_IPS=\"${ALLOWED_IPS}\""
  } >> "${tempsetupVarsFile}"
}

writeWireguardTempVarsFile() {
  {
    echo "pivpnPROTO=${pivpnPROTO}"
    echo "pivpnMTU=${pivpnMTU}"

    # Escribir PERSISTENTKEEPALIVE si se proporciona a través del archivo desatendido
    # También se puede añadir manualmente a /etc/pivpn/wireguard/setupVars.conf
    # post instalación para ser utilizado en la generación del perfil del cliente
    if [[ -n "${pivpnPERSISTENTKEEPALIVE}" ]]; then
      echo "pivpnPERSISTENTKEEPALIVE=${pivpnPERSISTENTKEEPALIVE}"
    fi
  } >> "${tempsetupVarsFile}"
}

askWhichVPN() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ "${WIREGUARD_SUPPORT}" -eq 1 ]]; then
      if [[ -z "${VPN}" ]]; then
        echo ":: No se especificó ningún protocolo VPN, usando WireGuard"
        VPN="wireguard"
      else
        VPN="${VPN,,}"

        if [[ "${VPN}" == "wireguard" ]]; then
          echo "::: WireGuard se instalará"
        elif [[ "${VPN}" == "openvpn" ]]; then
          echo "::: OpenVPN se instalará"
        else
          err ":: ${VPN} no es un protocolo VPN compatible, por favor especifica 'wireguard' o 'openvpn'"
          exit 1
        fi
      fi
    else
      if [[ -z "${VPN}" ]]; then
        echo ":: No se especificó ningún protocolo VPN, usando OpenVPN"
        VPN="openvpn"
      else
        VPN="${VPN,,}"

        if [[ "${VPN}" == "openvpn" ]]; then
          echo "::: OpenVPN se instalará"
        else
          err ":: ${VPN} no es un protocolo VPN compatible en ${DPKG_ARCH} ${PLAT}, solo 'openvpn' lo es"
          exit 1
        fi
      fi
    fi
  else
    if [[ "${WIREGUARD_SUPPORT}" -eq 1 ]] \
      && [[ "${OPENVPN_SUPPORT}" -eq 1 ]]; then
      chooseVPNCmd=(whiptail
        --backtitle "Configurar PiVPN"
        --title "Modo de instalación"
        --separate-output
        --radiolist "WireGuard es un nuevo tipo de VPN que proporciona \
velocidad de conexión casi instantánea, alto rendimiento y criptografía moderna.

Es la opción recomendada especialmente si utilizas dispositivos móviles donde \
WireGuard es más suave con la batería que OpenVPN.

OpenVPN todavía está disponible si necesitas el tradicional, flexible y confiable \
protocolo VPN o si necesitas funciones como TCP y dominio de búsqueda personalizado.

Elige una VPN (presiona espacio para seleccionar):" "${r}" "${c}" 2)
      VPNChooseOptions=(WireGuard "" on
        OpenVPN "" off)

      if VPN="$("${chooseVPNCmd[@]}" \
        "${VPNChooseOptions[@]}" \
        2>&1 > /dev/tty)"; then
        echo "::: Usando VPN: ${VPN}"
        VPN="${VPN,,}"
      else
        err "::: Cancelar seleccionado, saliendo...."
        exit 1
      fi
    elif [[ "${OPENVPN_SUPPORT}" -eq 1 ]] \
      && [[ "${WIREGUARD_SUPPORT}" -eq 0 ]]; then
      echo "::: Usando VPN: OpenVPN"
      VPN="openvpn"
    elif [[ "${OPENVPN_SUPPORT}" -eq 0 ]] \
      && [[ "${WIREGUARD_SUPPORT}" -eq 1 ]]; then
      echo "::: Usando VPN: WireGuard"
      VPN="wireguard"
    fi
  fi

  echo "VPN=${VPN}" >> "${tempsetupVarsFile}"
}

askAboutCustomizing() {
  if [[ "${runUnattended}" == 'false' ]]; then
    if whiptail \
      --backtitle "Configurar PiVPN" \
      --title "Modo de instalación" \
      --defaultno \
      --yesno "PiVPN utiliza las siguientes configuraciones que creemos que son buenas \
por defecto para la mayoría de los usuarios. Sin embargo, para mantener la flexibilidad, si \
necesitas personalizarlas, elige Sí.

* Protocolo UDP o TCP: UDP
* Dominio de búsqueda personalizado para el campo DNS: Ninguno
* Características modernas o mejor compatibilidad: Características modernas \
(certificado de 256 bits + cifrado TLS adicional)" "${r}" "${c}"; then
      CUSTOMIZE=1
    else
      CUSTOMIZE=0
    fi
  fi
}

installOpenVPN() {
  local PIVPN_DEPS gpg_path
  gpg_path="${pivpnFilesDir}/files/etc/apt/repo-public.gpg"
  echo "::: Instalando OpenVPN desde el paquete de Debian... "

  if [[ "${NEED_OPENVPN_REPO}" -eq 1 ]]; then
    # gnupg es usado por apt-key para importar la clave GPG de openvpn en el
    # llavero de APT
    PIVPN_DEPS=(gnupg)
    installDependentPackages PIVPN_DEPS[@]

    # Clave GPG pública del repositorio de OpenVPN
    # (huella digital 0x30EBF4E73CCE63EEE124DD278E6DA8B4E158C569)
    echo "::: Añadiendo clave del repositorio..."

    if ! ${SUDO} apt-key add "${gpg_path}"; then
      err "::: No se puede importar la clave GPG de OpenVPN"
      exit 1
    fi

    echo "::: Añadiendo repositorio de OpenVPN... "
    echo "deb https://build.openvpn.net/debian/openvpn/stable ${OSCN} main" \
      | ${SUDO} tee /etc/apt/sources.list.d/pivpn-openvpn-repo.list > /dev/null

    echo "::: Actualizando la caché de paquetes..."
    updatePackageCache
  fi

  PIVPN_DEPS=(openvpn)

  installDependentPackages PIVPN_DEPS[@]
}

installWireGuard() {
  local PIVPN_DEPS

  echo -n "::: Instalando WireGuard"
  PIVPN_DEPS=(wireguard-tools)

  if [[ "${PLAT}" == "Raspbian" ]]; then
    echo " desde el paquete Raspbian..."

    # qrencode se usa para generar qrcodes desde el archivo de config,
    # para uso con clientes móviles
    PIVPN_DEPS+=(qrencode)
  elif [[ "${PLAT}" == "Debian" ]]; then
    echo " desde el paquete Debian..."

    PIVPN_DEPS+=(qrencode)

    if [[ "${WIREGUARD_BUILTIN}" -eq 0 ]]; then
      # Instalar explícitamente el módulo si no está integrado
      PIVPN_DEPS+=(linux-headers-amd64 wireguard-dkms)
    fi
  elif [[ "${PLAT}" == "Ubuntu" ]]; then
    echo "..."

    PIVPN_DEPS+=(qrencode)

    if [[ "${WIREGUARD_BUILTIN}" -eq 0 ]]; then
      PIVPN_DEPS+=(linux-headers-generic wireguard-dkms)
    fi
  elif [[ "${PLAT}" == 'Alpine' ]]; then
    echo "..."

    PIVPN_DEPS+=(libqrencode)
  fi

  if [[ "${PLAT}" == "Raspbian" || "${PLAT}" == "Debian" ]] \
    && [[ -z "${AVAILABLE_WIREGUARD}" ]]; then
    if [[ "${PLAT}" == "Debian" ]]; then
      echo "::: Añadiendo repositorio Debian Bullseye... "
      echo "deb https://deb.debian.org/debian/ bullseye main" \
        | ${SUDO} tee /etc/apt/sources.list.d/pivpn-bullseye-repo.list > /dev/null
    else
      echo "::: Añadiendo repositorio Raspbian Bullseye... "
      echo "deb http://raspbian.raspberrypi.org/raspbian/ bullseye main" \
        | ${SUDO} tee /etc/apt/sources.list.d/pivpn-bullseye-repo.list > /dev/null
    fi

    {
      printf 'Package: *\n'
      printf 'Pin: release n=bullseye\n'
      printf 'Pin-Priority: -1\n\n'
      printf 'Package: wireguard wireguard-dkms wireguard-tools\n'
      printf 'Pin: release n=bullseye\n'
      printf 'Pin-Priority: 100\n'
    } | ${SUDO} tee /etc/apt/preferences.d/pivpn-limit-bullseye > /dev/null

    echo "::: Actualizando la caché de paquetes..."
    updatePackageCache
  fi

  installDependentPackages PIVPN_DEPS[@]
}

askCustomProto() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${pivpnPROTO}" ]]; then
      echo "::: No se especificó un protocolo TCP/IP, usando el protocolo udp predeterminado"
      pivpnPROTO="udp"
    else
      pivpnPROTO="${pivpnPROTO,,}"

      if [[ "${pivpnPROTO}" == "udp" ]] \
        || [[ "${pivpnPROTO}" == "tcp" ]]; then
        echo "::: Usando el protocolo ${pivpnPROTO}"
      else
        err ":: ${pivpnPROTO} no es un protocolo TCP/IP compatible, especifica 'udp' o 'tcp'"
        exit 1
      fi
    fi

    echo "pivpnPROTO=${pivpnPROTO}" >> "${tempsetupVarsFile}"
    return
  fi

  if [[ "${CUSTOMIZE}" -eq 0 ]]; then
    if [[ "${VPN}" == "openvpn" ]]; then
      pivpnPROTO="udp"
      echo "pivpnPROTO=${pivpnPROTO}" >> "${tempsetupVarsFile}"
      return
    fi
  fi

  # Establecer los protocolos disponibles en un arreglo para que pueda ser usado
  # con un diálogo de whiptail
  if pivpnPROTO="$(whiptail \
    --title "Protocolo" \
    --radiolist "Elige un protocolo (presiona espacio para seleccionar). \
Por favor, elige TCP solo si sabes por qué necesitas TCP." "${r}" "${c}" 2 \
    "UDP" "" ON \
    "TCP" "" OFF \
    3>&1 1>&2 2>&3)"; then
    # Convertir la opción a minúsculas (UDP->udp)
    pivpnPROTO="${pivpnPROTO,,}"
    echo "::: Usando protocolo: ${pivpnPROTO}"
    echo "pivpnPROTO=${pivpnPROTO}" >> "${tempsetupVarsFile}"
  else
    err "::: Cancelar seleccionado, saliendo...."
    exit 1
  fi
}

askCustomPort() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${pivpnPORT}" ]]; then
      if [[ "${VPN}" == "wireguard" ]]; then
        echo "::: No se especificó un puerto, usando el puerto predeterminado 51820"
        pivpnPORT=51820
      elif [[ "${VPN}" == "openvpn" ]]; then
        if [[ "${pivpnPROTO}" == "udp" ]]; then
          echo "::: No se especificó un puerto, usando el puerto predeterminado 1194"
          pivpnPORT=1194
        elif [[ "${pivpnPROTO}" == "tcp" ]]; then
          echo "::: No se especificó un puerto, usando el puerto predeterminado 443"
          pivpnPORT=443
        fi
      fi
    else
      if [[ "${pivpnPORT}" =~ ^[0-9]+$ ]] \
        && [[ "${pivpnPORT}" -ge 1 ]] \
        && [[ "${pivpnPORT}" -le 65535 ]]; then
        echo "::: Usando puerto ${pivpnPORT}"
      else
        err "::: ${pivpnPORT} no es un puerto válido, usa un puerto en el rango [1,65535] (inclusive)"
        exit 1
      fi
    fi

    echo "pivpnPORT=${pivpnPORT}" >> "${tempsetupVarsFile}"
    return
  fi

  until [[ "${PORTNumCorrect}" == 'true' ]]; do
    portInvalid="Invalid"

    if [[ "${VPN}" == "wireguard" ]]; then
      DEFAULT_PORT=51820
    elif [[ "${VPN}" == "openvpn" ]]; then
      if [[ "${pivpnPROTO}" == "udp" ]]; then
        DEFAULT_PORT=1194
      else
        DEFAULT_PORT=443
      fi
    fi

    if pivpnPORT="$(whiptail \
      --title "Puerto predeterminado de ${VPN}" \
      --inputbox "Puedes modificar el puerto predeterminado de ${VPN}.
Introduce un nuevo valor o presiona 'Enter' para mantener \
el predeterminado" "${r}" "${c}" "${DEFAULT_PORT}" \
      3>&1 1>&2 2>&3)"; then
      if [[ "${pivpnPORT}" =~ ^[0-9]+$ ]] \
        && [[ "${pivpnPORT}" -ge 1 ]] \
        && [[ "${pivpnPORT}" -le 65535 ]]; then
        :
      else
        pivpnPORT="${portInvalid}"
      fi
    else
      err "::: Cancelar seleccionado, saliendo...."
      exit 1
    fi

    if [[ "${pivpnPORT}" == "${portInvalid}" ]]; then
      whiptail \
        --backtitle "Puerto inválido" \
        --title "Puerto inválido" \
        --msgbox "Has introducido un número de puerto inválido.
    Por favor, introduce un número entre 1 - 65535.
    Si no estás seguro, simplemente mantén el predeterminado." "${r}" "${c}"
      PORTNumCorrect=false
    else
      if whiptail \
        --backtitle "Especificar puerto personalizado" \
        --title "Confirmar número de puerto personalizado" \
        --yesno "¿Son correctas estas configuraciones?
    PUERTO: ${pivpnPORT}" "${r}" "${c}"; then
        PORTNumCorrect=true
      else
        # Si las configuraciones son incorrectas, el bucle continúa
        PORTNumCorrect=false
      fi
    fi
  done

  # escribir el puerto
  echo "pivpnPORT=${pivpnPORT}" >> "${tempsetupVarsFile}"
}

setupPiholeDNS() {
  # Añadir un archivo hosts personalizado para clientes VPN para que aparezcan
  # como 'nombre.pivpn' en el panel de Pi-hole además de resolverse
  # por sus nombres.
  echo "addn-hosts=/etc/pivpn/hosts.${VPN}" \
    | ${SUDO} tee "${dnsmasqConfig}" > /dev/null

  # Luego crear un archivo hosts vacío o limpiarlo si existe.
  ${SUDO} bash -c "> /etc/pivpn/hosts.${VPN}"

  # shellcheck disable=SC1090
  CORE_VERSION="$(source "$piholeVersions" && echo "${CORE_VERSION}")"
  if [ "$(echo -e 'v6.0.0\n'"${CORE_VERSION}" | sort -V | head -n 1)" = "v6.0.0" ]; then
    # Ejecutando Pi-hole v6 o posterior
    ${SUDO} pihole-FTL --config dns.listeningMode LOCAL
    ${SUDO} pihole-FTL --config misc.etc_dnsmasq_d true
  else
    # Configurar Pi-hole a "Escuchar en todas las interfaces" permite
    # que dnsmasq escuche en la interfaz VPN mientras permite
    # consultas solo de hosts cuya dirección esté en la LAN y
    # subredes VPN.
    ${SUDO} pihole -a -i local
  fi

  # Usar la IP de VPN de la Raspberry Pi como servidor DNS.
  pivpnDNS1="${vpnGw}"

  {
    echo "pivpnDNS1=${pivpnDNS1}"
    echo "pivpnDNS2=${pivpnDNS2}"
  } >> "${tempsetupVarsFile}"

  # Permitir solicitudes DNS entrantes a través de UFW.
  if [[ "${USING_UFW}" -eq 1 ]]; then
    ${SUDO} ufw insert 1 allow in \
      on "${pivpnDEV}" to any port 53 \
      from "${pivpnNET}/${subnetClass}" > /dev/null
  else
    ${SUDO} iptables -I INPUT -i "${pivpnDEV}" \
      -p udp --dport 53 -j ACCEPT -m comment --comment "pihole-DNS-rule"
  fi
}

askClientDNS() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ "${usePiholeDNS}" == 'true' ]] \
      && command -v pihole > /dev/null; then
      setupPiholeDNS
      return
    elif [[ -z "${pivpnDNS1}" ]] \
      && [[ -n "${pivpnDNS2}" ]]; then
      pivpnDNS1="${pivpnDNS2}"
      unset pivpnDNS2
    elif [[ -z "${pivpnDNS1}" ]] \
      && [[ -z "${pivpnDNS2}" ]]; then
      pivpnDNS1="9.9.9.9"
      pivpnDNS2="149.112.112.112"
      echo -n "::: Ningún proveedor DNS especificado, "
      echo "usando DNS Quad9 (${pivpnDNS1} ${pivpnDNS2})"
    fi

    local INVALID_DNS_SETTINGS=0

    if ! validIP "${pivpnDNS1}"; then
      INVALID_DNS_SETTINGS=1
      echo "::: DNS inválido ${pivpnDNS1}"
    fi

    if [[ -n "${pivpnDNS2}" ]] \
      && ! validIP "${pivpnDNS2}"; then
      INVALID_DNS_SETTINGS=1
      echo "::: DNS inválido ${pivpnDNS2}"
    fi

    if [[ "${INVALID_DNS_SETTINGS}" -eq 0 ]]; then
      echo "::: Usando DNS ${pivpnDNS1} ${pivpnDNS2}"
    else
      exit 1
    fi

    {
      echo "pivpnDNS1=${pivpnDNS1}"
      echo "pivpnDNS2=${pivpnDNS2}"
    } >> "${tempsetupVarsFile}"
    return
  fi

  # Detectar y ofrecer el uso de Pi-hole
  if command -v pihole > /dev/null; then
    if [[ "${usePiholeDNS}" == 'true' ]] \
      || whiptail \
        --backtitle "Configurar PiVPN" \
        --title "Pi-hole" \
        --yesno "Hemos detectado una instalación de Pi-hole, \
¿quieres usarlo como servidor DNS para la VPN, para que \
obtengas bloqueo de anuncios sobre la marcha?" "${r}" "${c}"; then
      setupPiholeDNS
      return
    fi
  fi

  DNSChoseCmd=(whiptail
    --backtitle "Configurar PiVPN"
    --title "Proveedor de DNS"
    --separate-output
    --radiolist "Selecciona el Proveedor DNS para tus Clientes VPN \
(presiona espacio para seleccionar).
Para usar el tuyo propio, selecciona Custom.

En caso de que tengas un resolutor local en ejecución, p. ej. unbound, selecciona \
\"PiVPN-is-local-DNS\" y asegúrate de que esté escuchando en \
\"${vpnGw}\", permitiendo solicitudes de \
\"${pivpnNET}/${subnetClass}\"." "${r}" "${c}" 6)
  DNSChooseOptions=(Quad9 "" on
    OpenDNS "" off
    Level3 "" off
    DNS.WATCH "" off
    Norton "" off
    FamilyShield "" off
    CloudFlare "" off
    Google "" off
    PiVPN-is-local-DNS "" off
    Custom "" off)

  if DNSchoices="$("${DNSChoseCmd[@]}" \
    "${DNSChooseOptions[@]}" \
    2>&1 > /dev/tty)"; then
    if [[ "${DNSchoices}" != "Custom" ]]; then
      echo "::: Usando servidores ${DNSchoices}."
      declare -A DNS_MAP=(["Quad9"]="9.9.9.9 149.112.112.112"
        ["OpenDNS"]="208.67.222.222 208.67.220.220"
        ["Level3"]="209.244.0.3 209.244.0.4"
        ["DNS.WATCH"]="84.200.69.80 84.200.70.40"
        ["Norton"]="199.85.126.10 199.85.127.10"
        ["FamilyShield"]="208.67.222.123 208.67.220.123"
        ["CloudFlare"]="1.1.1.1 1.0.0.1"
        ["Google"]="8.8.8.8 8.8.4.4"
        ["PiVPN-is-local-DNS"]="${vpnGw}")
      pivpnDNS1=$(awk '{print $1}' <<< "${DNS_MAP["${DNSchoices}"]}")
      pivpnDNS2=$(awk '{print $2}' <<< "${DNS_MAP["${DNSchoices}"]}")
    else
      until [[ "${DNSSettingsCorrect}" == 'true' ]]; do
        strInvalid="Invalid"

        if pivpnDNS="$(whiptail \
          --backtitle "Especificar Proveedor(es) DNS de subida" \
          --inputbox "Introduce tu(s) proveedor(es) DNS de subida, \
separados por coma.

Por ejemplo '1.1.1.1, 9.9.9.9'" "${r}" "${c}" "" \
          3>&1 1>&2 2>&3)"; then
          pivpnDNS1="$(echo "${pivpnDNS}" \
            | sed 's/[, \t]\+/,/g' \
            | awk -F, '{print$1}')"
          pivpnDNS2="$(echo "${pivpnDNS}" \
            | sed 's/[, \t]\+/,/g' \
            | awk -F, '{print$2}')"

          if ! validIP "${pivpnDNS1}" \
            || [[ ! "${pivpnDNS1}" ]]; then
            pivpnDNS1="${strInvalid}"
          fi

          if ! validIP "${pivpnDNS2}" \
            && [[ "${pivpnDNS2}" ]]; then
            pivpnDNS2="${strInvalid}"
          fi
        else
          err "::: Cancelar seleccionado, saliendo...."
          exit 1
        fi

        if [[ "${pivpnDNS1}" == "${strInvalid}" ]] \
          || [[ "${pivpnDNS2}" == "${strInvalid}" ]]; then
          whiptail \
            --backtitle "IP Inválida" \
            --title "IP Inválida" \
            --msgbox "Una o ambas direcciones IP eran inválidas. \
Por favor, inténtalo de nuevo.
    Servidor DNS 1: ${pivpnDNS1}
    Servidor DNS 2: ${pivpnDNS2}" "${r}" "${c}"

          if [[ "${pivpnDNS1}" == "${strInvalid}" ]]; then
            pivpnDNS1=""
          fi

          if [[ "${pivpnDNS2}" == "${strInvalid}" ]]; then
            pivpnDNS2=""
          fi

          DNSSettingsCorrect=false
        else
          if whiptail \
            --backtitle "Especificar Proveedor(es) DNS de subida" \
            --title "Proveedor(es) DNS de subida" \
            --yesno "¿Son correctas estas configuraciones?
    Servidor DNS 1: ${pivpnDNS1}
    Servidor DNS 2: ${pivpnDNS2}" "${r}" "${c}"; then
            DNSSettingsCorrect=true
          else
            # Si las configuraciones son incorrectas, el bucle continúa
            DNSSettingsCorrect=false
          fi
        fi
      done
    fi

  else
    err "::: Cancelación seleccionada. Saliendo..."
    exit 1
  fi

  {
    echo "pivpnDNS1=${pivpnDNS1}"
    echo "pivpnDNS2=${pivpnDNS2}"
  } >> "${tempsetupVarsFile}"
}

# Llama a esta función para usar una expresión regular y verificar
# si la entrada del usuario es un dominio personalizado válido
validDomain() {
  local domain="${1}"
  local perl_regexp='(?=^.{4,253}$)'
  perl_regexp="${perl_regexp}(^(?:[a-zA-Z0-9](?:(?:[a-zA-Z0-9\-]){0,61}"
  perl_regexp="${perl_regexp}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$)"
  grep -qP "${perl_regexp}" <<< "${domain}"
}

# Este procedimiento permite al usuario especificar un
# dominio de búsqueda personalizado si tiene uno.
askCustomDomain() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -n "${pivpnSEARCHDOMAIN}" ]]; then
      if validDomain "${pivpnSEARCHDOMAIN}"; then
        echo "::: Usando dominio personalizado ${pivpnSEARCHDOMAIN}"
      else
        err "::: El dominio personalizado ${pivpnSEARCHDOMAIN} no es válido"
        exit 1
      fi
    else
      echo "::: Omitiendo dominio personalizado"
    fi

    echo "pivpnSEARCHDOMAIN=${pivpnSEARCHDOMAIN}" >> "${tempsetupVarsFile}"
    return
  fi

  if [[ "${CUSTOMIZE}" -eq 0 ]]; then
    if [[ "${VPN}" == "openvpn" ]]; then
      echo "pivpnSEARCHDOMAIN=${pivpnSEARCHDOMAIN}" >> "${tempsetupVarsFile}"
      return
    fi
  fi

  DomainSettingsCorrect=false

  if whiptail \
    --backtitle "Dominio de búsqueda personalizado" \
    --title "Dominio de búsqueda personalizado" \
    --defaultno \
    --yesno "¿Te gustaría añadir un dominio de búsqueda personalizado?
(Esto es solo para usuarios avanzados que tienen su propio dominio)
" "${r}" "${c}"; then
    until [[ "${DomainSettingsCorrect}" == 'true' ]]; do
      if pivpnSEARCHDOMAIN="$(whiptail \
        --inputbox "Introduce el Dominio Personalizado
Formato: midominio.com" "${r}" "${c}" \
        --title "Dominio Personalizado" \
        3>&1 1>&2 2>&3)"; then
        if validDomain "${pivpnSEARCHDOMAIN}"; then
          if whiptail \
            --backtitle "Dominio de búsqueda personalizado" \
            --title "Dominio de búsqueda personalizado" \
            --yesno "¿Son correctas estas configuraciones?
    Dominio de búsqueda personalizado: ${pivpnSEARCHDOMAIN}" "${r}" "${c}"; then
            DomainSettingsCorrect=true
          else
            # Si las configuraciones son incorrectas, el bucle continúa
            DomainSettingsCorrect=false
          fi
        else
          whiptail \
            --backtitle "Dominio Inválido" \
            --title "Dominio Inválido" \
            --msgbox "El dominio es inválido. Por favor, inténtalo de nuevo.
    DOMINIO:  ${pivpnSEARCHDOMAIN}
" "${r}" "${c}"
          DomainSettingsCorrect=false
        fi
      else
        err "::: Cancelación seleccionada. Saliendo..."
        exit 1
      fi
    done
  fi

  echo "pivpnSEARCHDOMAIN=${pivpnSEARCHDOMAIN}" >> "${tempsetupVarsFile}"
}

askPublicIPOrDNS() {
  if ! IPv4pub="$(dig +short myip.opendns.com @208.67.222.222)" \
    || ! validIP "${IPv4pub}"; then
    err "dig falló, ahora probando con curl checkip.amazonaws.com"

    if ! IPv4pub="$(curl -sSf https://checkip.amazonaws.com)" \
      || ! validIP "${IPv4pub}"; then
      err "checkip.amazonaws.com falló, verifica tu conexión a internet/DNS"
      exit 1
    fi
  fi

  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${pivpnHOST}" ]]; then
      echo "::: Sin IP o nombre de dominio, usando IP pública ${IPv4pub}"
      pivpnHOST="${IPv4pub}"
    else
      if validIP "${pivpnHOST}"; then
        echo "::: Usando IP pública ${pivpnHOST}"
      elif validDomain "${pivpnHOST}"; then
        echo "::: Usando nombre de dominio ${pivpnHOST}"
      else
        err "::: ${pivpnHOST} no es una IP o nombre de dominio válido"
        exit 1
      fi
    fi

    echo "pivpnHOST=${pivpnHOST}" >> "${tempsetupVarsFile}"
    return
  fi

  local publicDNSCorrect
  local publicDNSValid

  if METH="$(whiptail \
    --title "IP Pública o DNS" \
    --radiolist \
    "¿Los clientes usarán una IP Pública o Nombre DNS para conectarse a tu servidor \
(presiona espacio para seleccionar)?" "${r}" "${c}" 2 \
    "${IPv4pub}" "Usar esta IP pública" "ON" \
    "DNS Entry" "Usar un DNS público" "OFF" \
    3>&1 1>&2 2>&3)"; then
    if [[ "${METH}" == "${IPv4pub}" ]]; then
      pivpnHOST="${IPv4pub}"
    else
      until [[ "${publicDNSCorrect}" == 'true' ]]; do
        until [[ "${publicDNSValid}" == 'true' ]]; do
          if PUBLICDNS="$(whiptail \
            --title "Configuración de PiVPN" \
            --inputbox "¿Cuál es el nombre \
DNS público de este Servidor?" "${r}" "${c}" \
            3>&1 1>&2 2>&3)"; then
            if validDomain "${PUBLICDNS}"; then
              publicDNSValid=true
              pivpnHOST="${PUBLICDNS}"
            else
              whiptail \
                --backtitle "Configuración de PiVPN" \
                --title "Nombre DNS inválido" \
                --msgbox "Este nombre DNS es inválido. Por favor inténtalo de nuevo.
    Nombre DNS: ${PUBLICDNS}
" "${r}" "${c}"
              publicDNSValid=false
            fi
          else
            err "::: Cancelación seleccionada. Saliendo..."
            exit 1
          fi
        done

        if whiptail \
          --backtitle "Configuración de PiVPN" \
          --title "Confirmar Nombre DNS" \
          --yesno "¿Es correcto esto?
Nombre DNS Público: ${PUBLICDNS}" "${r}" "${c}"; then
          publicDNSCorrect=true
        else
          publicDNSCorrect=false
          publicDNSValid=false
        fi
      done
    fi
  else
    err "::: Cancelación seleccionada. Saliendo..."
    exit 1
  fi

  echo "pivpnHOST=${pivpnHOST}" >> "${tempsetupVarsFile}"
}

askEncryption() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${TWO_POINT_FIVE}" ]] \
      || [[ "${TWO_POINT_FIVE}" -eq 1 ]]; then
      TWO_POINT_FIVE=1
      echo "::: Usando funciones de OpenVPN 2.5"

      if [[ -z "${pivpnENCRYPT}" ]]; then
        pivpnENCRYPT=256
      fi

      if [[ "${pivpnENCRYPT}" -eq 256 ]] \
        || [[ "${pivpnENCRYPT}" -eq 384 ]] \
        || [[ "${pivpnENCRYPT}" -eq 521 ]]; then
        echo "::: Usando un certificado de ${pivpnENCRYPT} bits"
      else
        err "::: ${pivpnENCRYPT} no es un tamaño de certificado válido, usa 256, 384 o 521"
        exit 1
      fi
    else
      TWO_POINT_FIVE=0
      echo "::: Usando configuración tradicional de OpenVPN"

      if [[ -z "${pivpnENCRYPT}" ]]; then
        pivpnENCRYPT=2048
      fi

      if [[ "${pivpnENCRYPT}" -eq 2048 ]] \
        || [[ "${pivpnENCRYPT}" -eq 3072 ]] \
        || [[ "${pivpnENCRYPT}" -eq 4096 ]]; then
        echo "::: Usando un certificado de ${pivpnENCRYPT} bits"
      else
        err "::: ${pivpnENCRYPT} no es un tamaño de certificado válido, usa 2048, 3072 o 4096"
        exit 1
      fi

      if [[ -z "${USE_PREDEFINED_DH_PARAM}" ]]; then
        USE_PREDEFINED_DH_PARAM=1
      fi

      if [[ "${USE_PREDEFINED_DH_PARAM}" -eq 1 ]]; then
        echo "::: Se usarán parámetros DH predefinidos"
      else
        echo "::: Los parámetros DH se generarán localmente"
      fi
    fi

    {
      echo "TWO_POINT_FIVE=${TWO_POINT_FIVE}"
      echo "pivpnENCRYPT=${pivpnENCRYPT}"
      echo "USE_PREDEFINED_DH_PARAM=${USE_PREDEFINED_DH_PARAM}"
    } >> "${tempsetupVarsFile}"
    return
  fi

  if [[ "${CUSTOMIZE}" -eq 0 ]]; then
    if [[ "${VPN}" == "openvpn" ]]; then
      TWO_POINT_FIVE=1
      pivpnENCRYPT=256

      {
        echo "TWO_POINT_FIVE=${TWO_POINT_FIVE}"
        echo "pivpnENCRYPT=${pivpnENCRYPT}"
        echo "USE_PREDEFINED_DH_PARAM=${USE_PREDEFINED_DH_PARAM}"
      } >> "${tempsetupVarsFile}"
      return
    fi
  fi

  if whiptail \
    --backtitle "Configurar OpenVPN" \
    --title "Modo de instalación" \
    --yesno "OpenVPN 2.5 puede aprovechar las Curvas Elípticas \
para ofrecer mayor velocidad de conexión y seguridad mejorada sobre \
RSA, manteniendo certificados más pequeños.

Además, la directiva 'tls-crypt-v2' cifra los certificados \
que se utilizan durante la autenticación, aumentando la privacidad.

Si tus clientes ejecutan OpenVPN 2.5 o posterior puedes habilitar \
estas funciones, de lo contrario elige 'No' para mejor \
compatibilidad." \
    "${r}" \
    "${c}"; then
    TWO_POINT_FIVE=1
    pivpnENCRYPT="$(whiptail \
      --backtitle "Configurar OpenVPN" \
      --title "Tamaño del certificado ECDSA" \
      --radiolist "Elige el tamaño deseado de tu certificado \
(presiona espacio para seleccionar):
Este es un certificado que se generará en tu sistema. \
Cuanto más grande sea el certificado, más tiempo tomará. \
Para la mayoría de las aplicaciones, se recomienda usar 256 bits. \
Puedes aumentar el número de bits si te importa, sin embargo, considera \
que 256 bits ya son tan seguros como RSA de 3072 bits." "${r}" "${c}" 3 \
      "256" "Usar un certificado de 256 bits (nivel recomendado)" ON \
      "384" "Usar un certificado de 384 bits" OFF \
      "521" "Usar un certificado de 521 bits (nivel paranoico)" OFF \
      3>&1 1>&2 2>&3)"
  else
    TWO_POINT_FIVE=0
    pivpnENCRYPT="$(whiptail \
      --backtitle "Configurar OpenVPN" \
      --title "Tamaño del certificado RSA" \
      --radiolist "Elige el tamaño deseado de tu certificado \
(presiona espacio para seleccionar):
Este es un certificado que se generará en tu sistema. \
Cuanto más grande sea el certificado, más tiempo tomará. \
Para la mayoría de las aplicaciones, se recomienda usar 2048 bits. \
Si estás paranoico acerca de ... las cosas... \
entonces toma una taza de café y elige 4096 bits." "${r}" "${c}" 3 \
      "2048" "Usar un certificado de 2048 bits (nivel recomendado)" ON \
      "3072" "Usar un certificado de 3072 bits " OFF \
      "4096" "Usar un certificado de 4096 bits (nivel paranoico)" OFF \
      3>&1 1>&2 2>&3)"
  fi

  exitstatus="$?"

  if [[ "${exitstatus}" != 0 ]]; then
    err "::: Cancelación seleccionada. Saliendo..."
    exit 1
  fi

  if [[ "${pivpnENCRYPT}" -ge 2048 ]] \
    && whiptail \
      --backtitle "Configurar OpenVPN" \
      --title "Generar Parámetros Diffie-Hellman" \
      --yesno "Generar parámetros DH puede tomar muchas horas en una Raspberry Pi. \
Puedes usar en su lugar parámetros DH predefinidos recomendados por la \
Fuerza de Trabajo de Ingeniería de Internet (IETF).
Puedes encontrar más información sobre ellos aquí: \
https://wiki.mozilla.org/Security/Archive/Server_Side_TLS_4.0#\
Pre-defined_DHE_groups
Si deseas parámetros únicos, elige 'No' y se generarán nuevos parámetros \
Diffie-Hellman en tu dispositivo." "${r}" "${c}"; then
    USE_PREDEFINED_DH_PARAM=1
  else
    USE_PREDEFINED_DH_PARAM=0
  fi

  {
    echo "TWO_POINT_FIVE=${TWO_POINT_FIVE}"
    echo "pivpnENCRYPT=${pivpnENCRYPT}"
    echo "USE_PREDEFINED_DH_PARAM=${USE_PREDEFINED_DH_PARAM}"
  } >> "${tempsetupVarsFile}"
}

confOpenVPN() {
  local sed_pattern file_pattern

  # Obtener el nombre de host existente
  host_name="$(hostname -s)"
  # Generar un UUID aleatorio para este servidor para que podamos usar
  # verify-x509-name más adelante que sea único para esta
  # instalación.
  NEW_UUID="$(< /proc/sys/kernel/random/uuid)"
  # Crear un nombre de servidor único usando el nombre de host y UUID
  SERVER_NAME="${host_name}_${NEW_UUID}"

  # Hacer copia de seguridad de la carpeta openvpn
  OPENVPN_BACKUP="openvpn_$(date +%Y-%m-%d-%H%M%S).tar.gz"
  echo "::: Haciendo copia de seguridad de la carpeta openvpn en /etc/${OPENVPN_BACKUP}"
  CURRENT_UMASK="$(umask)"
  umask 0077
  ${SUDO} tar -czf "/etc/${OPENVPN_BACKUP}" /etc/openvpn &> /dev/null
  umask "${CURRENT_UMASK}"

  if [[ -f /etc/openvpn/server.conf ]]; then
    ${SUDO} rm /etc/openvpn/server.conf
  fi

  if [[ -d /etc/openvpn/ccd ]]; then
    ${SUDO} rm -rf /etc/openvpn/ccd
  fi

  # Crear carpeta para almacenar directivas específicas del cliente usadas para empujar IPs estáticas
  ${SUDO} mkdir /etc/openvpn/ccd

  # Si easy-rsa existe, eliminarlo
  if [[ -d /etc/openvpn/easy-rsa/ ]]; then
    ${SUDO} rm -rf /etc/openvpn/easy-rsa/
  fi

  # Obtener easy-rsa
  curl -sSfL "${easyrsaRel}" \
    | ${SUDO} tar -xz --one-top-level=/etc/openvpn/easy-rsa --strip-components 1

  if [[ ! -s /etc/openvpn/easy-rsa/easyrsa ]]; then
    err "${0}: ERR: Fallo al descargar EasyRSA."
    exit 1
  fi

  # arreglar propiedad
  ${SUDO} chown -R root:root /etc/openvpn/easy-rsa
  ${SUDO} mkdir /etc/openvpn/easy-rsa/pki
  ${SUDO} chmod 700 /etc/openvpn/easy-rsa/pki

  cd /etc/openvpn/easy-rsa || exit 1

  if [[ "${TWO_POINT_FIVE}" -eq 1 ]]; then
    pivpnCERT="ec"
    pivpnTLSVERS="1.3"
    pivpnTLSPROT="tls-crypt-v2"
  else
    pivpnCERT="rsa"
    pivpnTLSVERS="1.2"
    pivpnTLSPROT="tls-auth"
  fi

  # Eliminar cualquier clave anterior
  ${SUDOE} ./easyrsa --batch init-pki

  # Copiar archivo de variables de plantilla
  ${SUDOE} cp vars.example pki/vars

  # Establecer certificado de curva elíptica o certificados rsa tradicionales
  ${SUDOE} sed -i \
    "s/#set_var EASYRSA_ALGO.*/set_var EASYRSA_ALGO ${pivpnCERT}/" \
    pki/vars

  # Establecer expiración para la CRL a 10 años
  ${SUDOE} sed -i \
    's/#set_var EASYRSA_CRL_DAYS.*/set_var EASYRSA_CRL_DAYS 3650/' \
    pki/vars

  if [[ "${pivpnENCRYPT}" -ge 2048 ]]; then
    # Establecer tamaño de clave personalizado si es diferente al predeterminado
    sed_pattern="s/#set_var EASYRSA_KEY_SIZE.*/"
    sed_pattern="${sed_pattern} set_var EASYRSA_KEY_SIZE ${pivpnENCRYPT}/"
    ${SUDOE} sed -i "${sed_pattern}" pki/vars
  else
    # Si es menor a 2048, entonces debe ser 521 o inferior,
    # lo que significa que se seleccionó un certificado de curva elíptica.
    # Establecemos la curva en este caso.
    declare -A ECDSA_MAP=(["256"]="prime256v1"
      ["384"]="secp384r1"
      ["521"]="secp521r1")

    sed_pattern="s/#set_var EASYRSA_CURVE.*/"
    sed_pattern="${sed_pattern} set_var EASYRSA_CURVE"
    sed_pattern="${sed_pattern} ${ECDSA_MAP["${pivpnENCRYPT}"]}/"
    ${SUDOE} sed -i "${sed_pattern}" pki/vars
  fi

  # Construir la autoridad de certificación
  printf "::: Construyendo CA...\\n"
  ${SUDOE} ./easyrsa --batch build-ca nopass
  printf "\\n::: CA Completada.\\n"

  if [[ "${pivpnCERT}" == "rsa" ]] \
    && [[ "${USE_PREDEFINED_DH_PARAM}" -ne 1 ]]; then
    if [[ "${runUnattended}" == 'true' ]]; then
      echo "::: La clave del servidor, los parámetros Diffie-Hellman, \
y la clave HMAC se generarán ahora."
    else
      whiptail \
        --msgbox \
        --backtitle "Configurar OpenVPN" \
        --title "Información del Servidor" \
        "La clave del servidor, los parámetros Diffie-Hellman, \
y la clave HMAC se generarán ahora." \
        "${r}" \
        "${c}"
    fi
  elif [[ "${pivpnCERT}" == "ec" ]] \
    || [[ "${pivpnCERT}" == "rsa" && "${USE_PREDEFINED_DH_PARAM}" -eq 1 ]]; then
    if [[ "${runUnattended}" == 'true' ]]; then
      echo "::: La clave del servidor y la clave HMAC se generarán ahora."
    else
      whiptail \
        --msgbox \
        --backtitle "Configurar OpenVPN" \
        --title "Información del Servidor" \
        "La clave del servidor y la clave HMAC se generarán ahora." \
        "${r}" \
        "${c}"
    fi
  fi

  # Construir el servidor
  EASYRSA_CERT_EXPIRE=3650 ${SUDOE} \
    ./easyrsa --batch build-server-full "${SERVER_NAME}" nopass

  if [[ "${pivpnCERT}" == "rsa" ]]; then
    if [[ "${USE_PREDEFINED_DH_PARAM}" -eq 1 ]]; then
      file_pattern="${pivpnFilesDir}/files/etc/openvpn"
      file_pattern="${file_pattern}/easy-rsa/pki/ffdhe${pivpnENCRYPT}.pem"
      # Usar parámetros Diffie-Hellman del RFC 7919 (FFDHE)
      ${SUDOE} install -m 644 "${file_pattern}" \
        "pki/dh${pivpnENCRYPT}.pem"
    else
      # Generar intercambio de claves Diffie-Hellman
      ${SUDOE} ./easyrsa gen-dh
      ${SUDOE} mv pki/dh.pem "pki/dh${pivpnENCRYPT}".pem
    fi
  fi

  # Generar clave HMAC estática para defenderse contra DDoS
  if [[ "${TWO_POINT_FIVE}" -eq 1 ]]; then
    ${SUDOE} mkdir -p "/etc/openvpn/easy-rsa/pki/tc-v2"
    ${SUDOE} openvpn --genkey tls-crypt-v2-server pki/tc-v2/server.key
  else
    ${SUDOE} openvpn --genkey tls-auth pki/ta.key
  fi

  # Generar una Lista de Revocación de Certificados vacía
  ${SUDOE} ./easyrsa gen-crl
  ${SUDOE} cp pki/crl.pem /etc/openvpn/crl.pem

  if ! getent passwd "${ovpnUserGroup%:*}"; then
    if [[ "${PLAT}" == 'Alpine' ]]; then
      ${SUDOE} adduser -SD \
        -h /var/lib/openvpn/ \
        -s /sbin/nologin \
        "${ovpnUserGroup%:*}"
    else
      ${SUDOE} useradd \
        --system \
        --home /var/lib/openvpn/ \
        --shell /usr/sbin/nologin \
        "${ovpnUserGroup%:*}"
    fi
  fi

  ${SUDOE} chown "${ovpnUserGroup}" /etc/openvpn/crl.pem

  # Escribir el archivo de configuración para el servidor usando el archivo template.txt
  ${SUDO} install -m 644 \
    "${pivpnFilesDir}/files/etc/openvpn/server_config.txt" \
    /etc/openvpn/server.conf

  # Aplicar configuraciones DNS del cliente
  ${SUDOE} sed -i \
    "0,/\(dhcp-option DNS \)/ s/\(dhcp-option DNS \).*/\1${pivpnDNS1}\"/" \
    /etc/openvpn/server.conf

  if [[ -z "${pivpnDNS2}" ]]; then
    ${SUDOE} sed -i '/\(dhcp-option DNS \)/{n;N;d}' /etc/openvpn/server.conf
  else
    ${SUDOE} sed -i \
      "0,/\(dhcp-option DNS \)/! s/\(dhcp-option DNS \).*/\1${pivpnDNS2}\"/" \
      /etc/openvpn/server.conf
  fi

  # Establecer el tamaño de la clave de encriptación del usuario
  ${SUDO} sed -i \
    "s#\\(dh /etc/openvpn/easy-rsa/pki/dh\\).*#\\1${pivpnENCRYPT}.pem#" \
    /etc/openvpn/server.conf

  if [[ "${pivpnTLSPROT}" == "tls-crypt-v2" ]]; then
    # Si habilitaron 2.5 usar tls-crypt-v2 en lugar de tls-auth para cifrar el canal de control
    ta_path="/etc/openvpn/easy-rsa/pki/ta.key"
    tc_v2_path="/etc/openvpn/easy-rsa/pki/tc-v2/server.key"
    tc_v2_cmd_path="/opt/pivpn/openvpn/TLSCryptV2Verify.sh"
    sed_pattern='s|tls-auth '"${ta_path}"' 0|tls-crypt-v2 '"${tc_v2_path}"'\ntls-crypt-v2-verify '"${tc_v2_cmd_path}"'\nscript-security 2|'
    ${SUDO} sed -i "${sed_pattern}" /etc/openvpn/server.conf
  fi

  if [[ "${pivpnCERT}" == "ec" ]]; then
    # Si habilitaron 2.5 deshabilitar parámetros dh y especificar la
    # curva coincidente del certificado ECDSA
    sed_pattern="s/\(dh \/etc\/openvpn\/easy-rsa\/pki\/dh\).*/dh"
    sed_pattern="${sed_pattern} none\necdh-curve"
    sed_pattern="${sed_pattern} ${ECDSA_MAP["${pivpnENCRYPT}"]}/"
    ${SUDO} sed -i \
      "${sed_pattern}" \
      /etc/openvpn/server.conf
  elif [[ "${pivpnCERT}" == "rsa" ]]; then
    # De lo contrario, establecer el tamaño de la clave de encriptación del usuario
    ${SUDO} sed -i \
      "s#\\(dh /etc/openvpn/easy-rsa/pki/dh\\).*#\\1${pivpnENCRYPT}.pem#" \
      /etc/openvpn/server.conf
  fi

  # Aumentar la versión mínima de TLS para limitar las suites de cifrado, reduciendo la superficie de ataque
  if [[ "${pivpnTLSVERS}" == "1.3" ]]; then
    ${SUDO} sed -i "s|tls-version-min 1.2|tls-version-min 1.3|" "/etc/openvpn/server.conf"
    ${SUDO} sed -i "s|tls-version-min 1.2|tls-version-min 1.3|" "${pivpnFilesDir}/files/etc/openvpn/easy-rsa/pki/Default.txt"
  fi

  # si modificaron la red VPN, poner el valor en server.conf
  if [[ "${pivpnNET}" != "10.8.0.0" ]]; then
    ${SUDO} sed -i "s/10.8.0.0/${pivpnNET}/g" /etc/openvpn/server.conf
  fi

  # si modificaron la clase de subred VPN, poner el valor en server.conf
  if [[ "$(cidrToMask "${subnetClass}")" != "255.255.255.0" ]]; then
    ${SUDO} sed -i \
      "s/255.255.255.0/$(cidrToMask "${subnetClass}")/g" \
      /etc/openvpn/server.conf
  fi

  # si modificaron el puerto, poner el valor en server.conf
  if [[ "${pivpnPORT}" -ne 1194 ]]; then
    ${SUDO} sed -i "s/1194/${pivpnPORT}/g" /etc/openvpn/server.conf
  fi

  # si modificaron el protocolo, poner el valor en server.conf
  if [[ "${pivpnPROTO}" != "udp" ]]; then
    ${SUDO} sed -i "s/proto udp/proto tcp/g" /etc/openvpn/server.conf
  fi

  if [[ -n "${pivpnSEARCHDOMAIN}" ]]; then
    sed_pattern="0,/\\(.*dhcp-option.*\\)/"
    sed_pattern="${sed_pattern}s//push \"dhcp-option "
    sed_pattern="${sed_pattern}DOMAIN ${pivpnSEARCHDOMAIN}\" \\n&/"
    ${SUDO} sed -i \
      "${sed_pattern}" \
      /etc/openvpn/server.conf
  fi

  # escribir los certificados del servidor en el archivo conf
  ${SUDO} sed -i \
    "s#\\(key /etc/openvpn/easy-rsa/pki/private/\\).*#\\1${SERVER_NAME}.key#" \
    /etc/openvpn/server.conf
  ${SUDO} sed -i \
    "s#\\(cert /etc/openvpn/easy-rsa/pki/issued/\\).*#\\1${SERVER_NAME}.crt#" \
    /etc/openvpn/server.conf

  # En Alpine Linux, el archivo de configuración predeterminado para OpenVPN es
  # "/etc/openvpn/openvpn.conf".
  # Para evitar fallos a través de OpenRC, creamos un enlace simbólico a este archivo.
  if [[ "${PLAT}" == 'Alpine' ]]; then
    ${SUDO} ln -sfT \
      /etc/openvpn/server.conf \
      /etc/openvpn/openvpn.conf \
      > /dev/null
  fi
}

confOVPN() {
  ${SUDO} install -m 644 \
    "${pivpnFilesDir}/files/etc/openvpn/easy-rsa/pki/Default.txt" \
    /etc/openvpn/easy-rsa/pki/Default.txt

  ${SUDO} sed -i \
    "s/IPv4pub/${pivpnHOST}/" \
    /etc/openvpn/easy-rsa/pki/Default.txt

  # si modificaron el puerto, poner el valor en Default.txt para que lo usen los clientes
  if [[ "${pivpnPORT}" -ne 1194 ]]; then
    ${SUDO} sed -i \
      "s/1194/${pivpnPORT}/g" \
      /etc/openvpn/easy-rsa/pki/Default.txt
  fi

  # si modificaron el protocolo, poner el valor en Default.txt para que lo usen los clientes
  if [[ "${pivpnPROTO}" != "udp" ]]; then
    ${SUDO} sed -i \
      "s/proto udp/proto tcp/g" \
      /etc/openvpn/easy-rsa/pki/Default.txt
  fi

  # verificar el nombre del servidor para fortalecer la seguridad
  ${SUDO} sed -i \
    "s/SRVRNAME/${SERVER_NAME}/" \
    /etc/openvpn/easy-rsa/pki/Default.txt

  if [[ "${pivpnTLSPROT}" == "tls-crypt-v2" ]]; then
    # Si habilitaron 2.5, eliminar las opciones de key-direction ya que no son necesarias
    ${SUDO} sed -i \
      "/key-direction 1/d" \
      /etc/openvpn/easy-rsa/pki/Default.txt
  fi
}

confWireGuard() {
  # El tipo de trabajo de recarga aún no está disponible en wireguard-tools incluido con
  # Ubuntu 20.04
  if [[ "${PLAT}" == 'Alpine' ]]; then
    echo '::: Añadiendo unidad wg-quick'
    ${SUDO} install -m 0755 \
      "${pivpnFilesDir}/files/etc/init.d/wg-quick" \
      /etc/init.d/wg-quick
  else
    if ! grep -q 'ExecReload' /lib/systemd/system/wg-quick@.service; then
      local wireguard_service_path
      wireguard_service_path="${pivpnFilesDir}/files/etc/systemd/system"
      wireguard_service_path="${wireguard_service_path}/wg-quick@.service.d"
      wireguard_service_path="${wireguard_service_path}/override.conf"
      echo "::: Añadiendo tipo de trabajo de recarga adicional para la unidad wg-quick"
      ${SUDO} install -Dm 644 \
        "${wireguard_service_path}" \
        /etc/systemd/system/wg-quick@.service.d/override.conf
      ${SUDO} systemctl daemon-reload
    fi
  fi

  if [[ -d /etc/wireguard ]]; then
    if [[ -n "$(${SUDO} ls -A /etc/wireguard)" ]]; then
      # Hacer copia de seguridad de la carpeta wireguard
      WIREGUARD_BACKUP="wireguard_$(date +%Y-%m-%d-%H%M%S).tar.gz"
      echo "::: Haciendo copia de seguridad de la carpeta wireguard en /etc/${WIREGUARD_BACKUP}"
      CURRENT_UMASK="$(umask)"
      umask 0077
      ${SUDO} tar -czf "/etc/${WIREGUARD_BACKUP}" /etc/wireguard &> /dev/null
      umask "${CURRENT_UMASK}"
    fi

    if [[ -f /etc/wireguard/wg0.conf ]]; then
      ${SUDO} rm /etc/wireguard/wg0.conf
    fi
  else
    # Si se compiló desde el código fuente, la carpeta wireguard no se crea
    ${SUDO} mkdir /etc/wireguard
  fi

  # Asegurar que solo root pueda entrar a la carpeta wireguard
  ${SUDO} chown root:root /etc/wireguard
  ${SUDO} chmod 700 /etc/wireguard

  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: Se generarán ahora las claves del servidor."
  else
    whiptail \
      --title "Información del Servidor" \
      --msgbox "Se generarán ahora las claves del servidor." \
      "${r}" \
      "${c}"
  fi

  # Eliminar las carpetas de configuraciones y claves para hacer espacio para un nuevo servidor al
  # usar 'Reparar' o 'Reconfigurar' sobre una instalación existente
  ${SUDO} rm -rf /etc/wireguard/configs
  ${SUDO} rm -rf /etc/wireguard/keys

  ${SUDO} mkdir -p /etc/wireguard/configs
  ${SUDO} touch /etc/wireguard/configs/clients.txt
  ${SUDO} mkdir -p /etc/wireguard/keys

  # Generar clave privada y derivar la clave pública de ella
  wg genkey \
    | ${SUDO} tee /etc/wireguard/keys/server_priv &> /dev/null
  ${SUDO} cat /etc/wireguard/keys/server_priv \
    | wg pubkey \
    | ${SUDO} tee /etc/wireguard/keys/server_pub &> /dev/null

  echo "::: Se han generado las claves del servidor."

  {
    echo '[Interface]'
    echo "PrivateKey = $(${SUDO} cat /etc/wireguard/keys/server_priv)"
    echo -n "Address = ${vpnGw}/${subnetClass}"

    if [[ "${pivpnenableipv6}" -eq 1 ]]; then
      echo ",${vpnGwv6}/${subnetClassv6}"
    else
      echo
    fi

    echo "MTU = ${pivpnMTU}"
    echo "ListenPort = ${pivpnPORT}"
  } | ${SUDO} tee /etc/wireguard/wg0.conf &> /dev/null

  echo "::: Configuración del servidor generada."
}

confNetwork() {
  # Habilitar el reenvío de tráfico de internet
  echo 'net.ipv4.ip_forward=1' \
    | ${SUDO} tee /etc/sysctl.d/99-pivpn.conf > /dev/null

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    {
      echo "net.ipv6.conf.all.forwarding=1"
      echo "net.ipv6.conf.${IPv6dev}.accept_ra=2"
    } | ${SUDO} tee -a /etc/sysctl.d/99-pivpn.conf > /dev/null
  fi

  ${SUDO} sysctl -p /etc/sysctl.d/99-pivpn.conf > /dev/null

  if [[ "${PLAT}" == 'Alpine' ]]; then
	${SUDO} rc-update add sysctl
  fi

  if [[ "${USING_UFW}" -eq 1 ]]; then
    echo "::: Se detectó que UFW está habilitado."
    echo "::: Añadiendo reglas de UFW..."

    ### Salvaguarda básica: si el archivo está vacío, algo raro ha estado
    ### pasando.
    ### Nota: no hay salvaguarda contra contenido incompleto como resultado de fallos
    ### previos.
    if [[ -s /etc/ufw/before.rules ]]; then
      ${SUDO} cp -f /etc/ufw/before.rules /etc/ufw/before.rules.pre-pivpn
    else
      err "${0}: ERR: Lo siento, no tocaré el archivo vacío \"/etc/ufw/before.rules\"."
      exit 1
    fi

    if [[ -s /etc/ufw/before6.rules ]]; then
      ${SUDO} cp -f /etc/ufw/before6.rules /etc/ufw/before6.rules.pre-pivpn
    else
      err "${0}: ERR: Lo siento, no tocaré el archivo vacío \"/etc/ufw/before6.rules\"."
      exit 1
    fi

    ### Si ya hay una sección "*nat", solo añadimos nuestro POSTROUTING MASQUERADE
    if ${SUDO} grep -q "*nat" /etc/ufw/before.rules; then
      local sed_pattern

      ### Solo añadir la regla NAT IPv4 si no está ya ahí
      if ! ${SUDO} grep -q "${VPN}-nat-rule" /etc/ufw/before.rules; then
        sed_pattern="/^*nat/{n;"
        sed_pattern="${sed_pattern}s/\(:POSTROUTING ACCEPT .*\)/"
        sed_pattern="${sed_pattern}\1\n-I POSTROUTING"
        sed_pattern="${sed_pattern} -s ${pivpnNET}\/${subnetClass}"
        sed_pattern="${sed_pattern} -o ${IPv4dev}"
        sed_pattern="${sed_pattern} -j MASQUERADE"
        sed_pattern="${sed_pattern} -m comment"
        sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule/"
        sed_pattern="${sed_pattern}}"
        ${SUDO} sed "${sed_pattern}" -i /etc/ufw/before.rules
      fi
    else
      sed_pattern="/delete these required/i"
      sed_pattern="${sed_pattern} *nat\n:POSTROUTING ACCEPT [0:0]\n"
      sed_pattern="${sed_pattern}-I POSTROUTING"
      sed_pattern="${sed_pattern} -s ${pivpnNET}\/${subnetClass}"
      sed_pattern="${sed_pattern} -o ${IPv4dev}"
      sed_pattern="${sed_pattern} -j MASQUERADE"
      sed_pattern="${sed_pattern} -m comment"
      sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule\n"
      sed_pattern="${sed_pattern}COMMIT\n"
      ${SUDO} sed "${sed_pattern}" -i /etc/ufw/before.rules
    fi

    if [[ "${pivpnenableipv6}" -eq 1 ]]; then
      local sed_pattern

      if ${SUDO} grep -q "*nat" /etc/ufw/before6.rules; then
        ### Solo añadir la regla NAT IPv6 si no está ya ahí
        if ! ${SUDO} grep -q "${VPN}-nat-rule" /etc/ufw/before6.rules; then
          sed_pattern="/^*nat/{n;"
          sed_pattern="${sed_pattern}s/\(:POSTROUTING ACCEPT .*\)/"
          sed_pattern="${sed_pattern}\1\n-I POSTROUTING"
          sed_pattern="${sed_pattern} -s ${pivpnNETv6}\/${subnetClassv6}"
          sed_pattern="${sed_pattern} -o ${IPv6dev}"
          sed_pattern="${sed_pattern} -j MASQUERADE"
          sed_pattern="${sed_pattern} -m comment"
          sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule/"
          sed_pattern="${sed_pattern}}"
          ${SUDO} sed "${sed_pattern}" -i /etc/ufw/before6.rules
        fi
      else
        sed_pattern="/delete these required/i"
        sed_pattern="${sed_pattern} *nat\n:POSTROUTING ACCEPT [0:0]\n"
        sed_pattern="${sed_pattern}-I POSTROUTING"
        sed_pattern="${sed_pattern} -s ${pivpnNETv6}\/${subnetClassv6}"
        sed_pattern="${sed_pattern} -o ${IPv6dev}"
        sed_pattern="${sed_pattern} -j MASQUERADE"
        sed_pattern="${sed_pattern} -m comment"
        sed_pattern="${sed_pattern} --comment ${VPN}-nat-rule\n"
        sed_pattern="${sed_pattern}COMMIT\n"
        ${SUDO} sed "${sed_pattern}" -i /etc/ufw/before6.rules
      fi
    fi

    # Comprueba si hay reglas UFW existentes e
    # inserta reglas al principio de la cadena
    # (en caso de que haya otras reglas que puedan descartar el tráfico)
    if ${SUDO} ufw status numbered | grep -E "\[.[0-9]{1}\]" > /dev/null; then
      ${SUDO} ufw insert 1 \
        allow "${pivpnPORT}/${pivpnPROTO}" \
        comment "allow-${VPN}" > /dev/null

      ${SUDO} ufw route insert 1 \
        allow in on "${pivpnDEV}" \
        from "${pivpnNET}/${subnetClass}" \
        out on "${IPv4dev}" to any > /dev/null

      if [[ "${pivpnenableipv6}" -eq 1 ]]; then
        ${SUDO} ufw route \
          allow in on "${pivpnDEV}" \
          from "${pivpnNETv6}/${subnetClassv6}" \
          out on "${IPv6dev}" to any > /dev/null
      fi
    fi

    ${SUDO} ufw reload > /dev/null
    echo "::: Configuración de UFW completada."
    return
  fi

  # Ahora algunas comprobaciones para detectar qué reglas necesitamos añadir.
  # En un sistema recién instalado, todas las políticas deberían ser ACCEPT,
  # por lo que la única regla requerida sería la de MASQUERADE.

  if ! ${SUDO} iptables -t nat -S \
    | grep -q "${VPN}-nat-rule"; then
    ${SUDO} iptables \
      -t nat \
      -I POSTROUTING \
      -s "${pivpnNET}/${subnetClass}" \
      -o "${IPv4dev}" \
      -j MASQUERADE \
      -m comment \
      --comment "${VPN}-nat-rule"
  fi

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    if ! ${SUDO} ip6tables -t nat -S \
      | grep -q "${VPN}-nat-rule"; then
      ${SUDO} ip6tables \
        -t nat \
        -I POSTROUTING \
        -s "${pivpnNETv6}/${subnetClassv6}" \
        -o "${IPv6dev}" \
        -j MASQUERADE \
        -m comment \
        --comment "${VPN}-nat-rule"
    fi
  fi

  # Cuenta cuántas reglas hay en la cadena INPUT y FORWARD.
  # Al analizar la entrada de iptables -S, '^-P' omite las políticas
  # y 'ufw-' omite las cadenas ufw (en caso de que se encontrara ufw
  # instalado pero no habilitado).

  # Grep devuelve un código de salida distinto de 0 donde no hay coincidencias,
  # sin embargo, eso haría que el script saliera,
  # por estas razones usamos '|| true' para forzar el código de salida 0
  INPUT_RULES_COUNT="$(${SUDO} iptables -S INPUT \
    | grep -vcE '(^-P|ufw-)')"
  FORWARD_RULES_COUNT="$(${SUDO} iptables -S FORWARD \
    | grep -vcE '(^-P|ufw-)')"
  INPUT_POLICY="$(${SUDO} iptables -S INPUT \
    | grep '^-P' \
    | awk '{print $3}')"
  FORWARD_POLICY="$(${SUDO} iptables -S FORWARD \
    | grep '^-P' \
    | awk '{print $3}')"

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    INPUT_RULES_COUNTv6="$(${SUDO} ip6tables -S INPUT \
      | grep -vcE '(^-P|ufw-)')"
    FORWARD_RULES_COUNTv6="$(${SUDO} ip6tables -S FORWARD \
      | grep -vcE '(^-P|ufw-)')"
    INPUT_POLICYv6="$(${SUDO} ip6tables -S INPUT \
      | grep '^-P' \
      | awk '{print $3}')"
    FORWARD_POLICYv6="$(${SUDO} ip6tables -S FORWARD \
      | grep '^-P' \
      | awk '{print $3}')"
  fi

  # Si el recuento de reglas no es cero, asumimos que necesitamos permitir explícitamente el tráfico.
  # Misma conclusión si no hay reglas y la política no es ACCEPT.
  # Ten en cuenta que las reglas se añaden a la parte superior de la cadena (usando -I).

  if [[ "${INPUT_RULES_COUNT}" -ne 0 ]] \
    || [[ "${INPUT_POLICY}" != "ACCEPT" ]]; then
    if ! ${SUDO} iptables -S \
      | grep -q "${VPN}-input-rule"; then
      ${SUDO} iptables \
        -I INPUT 1 \
        -i "${IPv4dev}" \
        -p "${pivpnPROTO}" \
        --dport "${pivpnPORT}" \
        -j ACCEPT \
        -m comment \
        --comment "${VPN}-input-rule"
    fi

    INPUT_CHAIN_EDITED=1
  else
    INPUT_CHAIN_EDITED=0
  fi

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    if [[ "${INPUT_RULES_COUNTv6}" -ne 0 ]] \
      || [[ "${INPUT_POLICYv6}" != "ACCEPT" ]]; then
      if ! ${SUDO} ip6tables -S \
        | grep -q "${VPN}-input-rule"; then
        ${SUDO} ip6tables \
          -I INPUT 1 \
          -i "${IPv6dev}" \
          -p "${pivpnPROTO}" \
          --dport "${pivpnPORT}" \
          -j ACCEPT \
          -m comment \
          --comment "${VPN}-input-rule"
      fi

      INPUT_CHAIN_EDITEDv6=1
    else
      INPUT_CHAIN_EDITEDv6=0
    fi
  fi

  if [[ "${FORWARD_RULES_COUNT}" -ne 0 ]] \
    || [[ "${FORWARD_POLICY}" != "ACCEPT" ]]; then
    if ! ${SUDO} iptables -S \
      | grep -q "${VPN}-forward-rule"; then
      ${SUDO} iptables \
        -I FORWARD 1 \
        -d "${pivpnNET}/${subnetClass}" \
        -i "${IPv4dev}" \
        -o "${pivpnDEV}" \
        -m conntrack \
        --ctstate RELATED,ESTABLISHED \
        -j ACCEPT \
        -m comment \
        --comment "${VPN}-forward-rule"
      ${SUDO} iptables \
        -I FORWARD 2 \
        -s "${pivpnNET}/${subnetClass}" \
        -i "${pivpnDEV}" \
        -o "${IPv4dev}" \
        -j ACCEPT \
        -m comment \
        --comment "${VPN}-forward-rule"
    fi

    FORWARD_CHAIN_EDITED=1
  else
    FORWARD_CHAIN_EDITED=0
  fi

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    if [[ "${FORWARD_RULES_COUNTv6}" -ne 0 ]] \
      || [[ "${FORWARD_POLICYv6}" != "ACCEPT" ]]; then
      if ! ${SUDO} ip6tables -S \
        | grep -q "${VPN}-forward-rule"; then
        ${SUDO} ip6tables \
          -I FORWARD 1 \
          -d "${pivpnNETv6}/${subnetClassv6}" \
          -i "${IPv6dev}" \
          -o "${pivpnDEV}" \
          -m conntrack \
          --ctstate RELATED,ESTABLISHED \
          -j ACCEPT \
          -m comment \
          --comment "${VPN}-forward-rule"
        ${SUDO} ip6tables \
          -I FORWARD 2 \
          -s "${pivpnNETv6}/${subnetClassv6}" \
          -i "${pivpnDEV}" \
          -o "${IPv6dev}" \
          -j ACCEPT \
          -m comment \
          --comment "${VPN}-forward-rule"
      fi

      FORWARD_CHAIN_EDITEDv6=1
    else
      FORWARD_CHAIN_EDITEDv6=0
    fi
  fi

  case "${PLAT}" in
    Debian | Raspbian | Ubuntu)
      ${SUDO} iptables-save \
        | ${SUDO} tee /etc/iptables/rules.v4 > /dev/null
      ${SUDO} ip6tables-save \
        | ${SUDO} tee /etc/iptables/rules.v6 > /dev/null
      ;;
	Alpine)
	  ${SUDO} rc-service iptables save
	  ${SUDO} rc-service ip6tables save
	  ${SUDO} rc-update add iptables
	  ${SUDO} rc-update add ip6tables
	  ;;
  esac

  {
    echo "INPUT_CHAIN_EDITED=${INPUT_CHAIN_EDITED}"
    echo "FORWARD_CHAIN_EDITED=${FORWARD_CHAIN_EDITED}"
    echo "INPUT_CHAIN_EDITEDv6=${INPUT_CHAIN_EDITEDv6}"
    echo "FORWARD_CHAIN_EDITEDv6=${FORWARD_CHAIN_EDITEDv6}"
  } >> "${tempsetupVarsFile}"
}

confLogging() {
  # Pre-crear directorios de configuración de rsyslog/logrotate si faltan,
  # para asegurar que los registros se manejen como se espera cuando estos se
  # instalen en un momento posterior
  ${SUDO} mkdir -p /etc/{rsyslog,logrotate}.d

  echo "if \$programname == 'openvpn' then /var/log/openvpn.log
if \$programname == 'openvpn' then stop" | ${SUDO} tee /etc/rsyslog.d/30-openvpn.conf > /dev/null

  echo "/var/log/openvpn.log
{
    rotate 4
    weekly
    missingok
    notifempty
    compress
    delaycompress
    sharedscripts
    postrotate
        invoke-rc.d rsyslog rotate >/dev/null 2>&1 || true
    endscript
}" | ${SUDO} tee /etc/logrotate.d/openvpn > /dev/null

  # Reiniciar el servicio de registro
  ${SUDO} rc-service -is rsyslog restart
  ${SUDO} rc-service -iN rsyslog start
}

restartServices() {
  # Iniciar servicios
  echo "::: Reiniciando servicios..."

  case "${PLAT}" in
    Debian | Raspbian | Ubuntu)
      if [[ "${VPN}" == "openvpn" ]]; then
        ${SUDO} systemctl enable openvpn.service &> /dev/null
        ${SUDO} systemctl restart openvpn.service
      elif [[ "${VPN}" == "wireguard" ]]; then
        ${SUDO} systemctl enable wg-quick@wg0.service &> /dev/null
        ${SUDO} systemctl restart wg-quick@wg0.service
      fi

      ;;
    Alpine)
      if [[ "${VPN}" == 'openvpn' ]]; then
        ${SUDO} rc-update add openvpn default &> /dev/null
        ${SUDO} rc-service -s openvpn restart
        ${SUDO} rc-service -N openvpn start
      elif [[ "${VPN}" == 'wireguard' ]]; then
        ${SUDO} rc-update add wg-quick default &> /dev/null
        ${SUDO} rc-service -s wg-quick restart
        ${SUDO} rc-service -N wg-quick start
      fi

      ;;
  esac
}

askUnattendedUpgrades() {
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${UNATTUPG}" ]]; then
      UNATTUPG=1
      echo "::: Sin preferencia sobre actualizaciones desatendidas, asumiendo que sí"
    else
      if [[ "${UNATTUPG}" -eq 1 ]]; then
        echo "::: Habilitando actualizaciones desatendidas"
      else
        echo "::: Omitiendo actualizaciones desatendidas"
      fi
    fi

    echo "UNATTUPG=${UNATTUPG}" >> "${tempsetupVarsFile}"
    return
  fi

  whiptail \
    --msgbox \
    --backtitle "Actualizaciones de Seguridad" \
    --title "Actualizaciones Desatendidas" \
    "Dado que este servidor tendrá al menos un puerto abierto a internet, \
se recomienda que habilites las actualizaciones desatendidas (unattended-upgrades).
Esta función verificará diariamente solo las actualizaciones de paquetes de seguridad y las \
aplicará cuando sea necesario.
NO reiniciará automáticamente el servidor, por lo que para aplicar completamente algunas actualizaciones \
deberás reiniciar periódicamente." \
    "${r}" \
    "${c}"

  if whiptail \
    --backtitle "Actualizaciones de Seguridad" \
    --title "Actualizaciones Desatendidas" \
    --yesno \
    "¿Deseas habilitar las actualizaciones desatendidas \
de parches de seguridad en este servidor?" \
    "${r}" \
    "${c}"; then
    UNATTUPG=1
  else
    UNATTUPG=0
  fi

  echo "UNATTUPG=${UNATTUPG}" >> "${tempsetupVarsFile}"
}

confUnattendedUpgrades() {
  local PIVPN_DEPS periodic_file

  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    PIVPN_DEPS=(unattended-upgrades)
    installDependentPackages PIVPN_DEPS[@]
    aptConfDir="/etc/apt/apt.conf.d"

    # El paquete unattended-upgrades de Raspbian descarga la configuración de Debian,
    # así que copiamos la configuración adecuada
    # https://github.com/mvo5/unattended-upgrades/blob/master/data/50unattended-upgrades.Raspbian
    # Añadir las configuraciones restantes para todas las demás distribuciones
    if [[ "${PLAT}" == "Raspbian" ]]; then
      ${SUDO} install -m 644 \
        "${pivpnFilesDir}/files${aptConfDir}/50unattended-upgrades.Raspbian" \
        "${aptConfDir}/50unattended-upgrades"
    fi

    if [[ "${PLAT}" == "Ubuntu" ]]; then
      periodic_file="${aptConfDir}/10periodic"
    else
      periodic_file="${aptConfDir}/02periodic"
    fi

    # 50unattended-upgrades en Ubuntu ya debería tener solo la seguridad habilitada
    # por lo que solo necesitamos configurar el archivo 10periodic
    {
      echo "APT::Periodic::Update-Package-Lists \"1\";"
      echo "APT::Periodic::Download-Upgradeable-Packages \"1\";"
      echo "APT::Periodic::Unattended-Upgrade \"1\";"

      if [[ "${PLAT}" == "Ubuntu" ]]; then
        echo "APT::Periodic::AutocleanInterval \"5\";"
      else
        echo "APT::Periodic::Enable \"1\";"
        echo "APT::Periodic::AutocleanInterval \"7\";"
        echo "APT::Periodic::Verbose \"0\";"
      fi
    } | ${SUDO} tee "${periodic_file}" > /dev/null

    # Habilitar actualizaciones automáticas a través del repositorio bullseye
    # al instalar desde el paquete debian
    if [[ "${VPN}" == "wireguard" ]]; then
      if [[ -f /etc/apt/sources.list.d/pivpn-bullseye-repo.list ]]; then
        if ! grep -q "\"o=${PLAT},n=bullseye\";" \
          "${aptConfDir}/50unattended-upgrades"; then
          local sed_pattern
          sed_pattern=" {/a\"o=${PLAT},n=bullseye\";"
          sed_pattern="${sed_pattern} {/a\"o=${PLAT},n=bullseye\";"
          ${SUDO} sed -i "${sed_pattern}" "${aptConfDir}/50unattended-upgrades"
        fi
      fi
    fi
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    local down_dir
    ## instalar dependencias
    # shellcheck disable=SC2086
    ${SUDO} ${PKG_INSTALL} unzip asciidoctor

    if ! down_dir="$(mktemp -d)"; then
      err "::: ¡Fallo al crear el directorio de descarga para apk-autoupdate!"
      exit 1
    fi

    ## descargar binarios
    curl -fLo "${down_dir}/master.zip" \
      https://github.com/jirutka/apk-autoupdate/archive/refs/heads/master.zip
    unzip -qd "${down_dir}" "${down_dir}/master.zip"

    (
      cd "${down_dir}/apk-autoupdate-master" || exi

      ## personalizar binarios
      sed -i -E -e 's/^(prefix\s*:=).*/\1 \/usr/' Makefile

      ## instalar
      ${SUDO} make install

      if ! command -v apk-autoupdate &> /dev/null; then
        err "::: ¡Fallo al compilar e instalar apk-autoupdate!"
        exit
      fi
    ) || exit 1

    ${SUDO} install -m 0755 \
      "${pivpnFilesDir}/files/etc/apk/personal_autoupdate.conf" \
      /etc/apk/personal_autoupdate.conf
    ${SUDO} apk-autoupdate /etc/apk/personal_autoupdate.conf
  fi
}

writeConfigFiles() {
  # Guardar la configuración de instalación en la ubicación final
  echo "INSTALLED_PACKAGES=(${INSTALLED_PACKAGES[*]})" >> "${tempsetupVarsFile}"
  echo "::: Archivos de configuración copiados a ${setupConfigDir}/${VPN}/${setupVarsFile}"
  ${SUDO} mkdir -p "${setupConfigDir}/${VPN}/"
  ${SUDO} cp "${tempsetupVarsFile}" "${setupConfigDir}/${VPN}/${setupVarsFile}"
}

installScripts() {
  # Asegurar que /opt exista (problema #607)
  ${SUDO} mkdir -p /opt

  if [[ "${VPN}" == 'wireguard' ]]; then
    othervpn='openvpn'
  else
    othervpn='wireguard'
  fi

  # Crear enlaces simbólicos de los scripts desde /usr/local/src/pivpn a sus diversas ubicaciones
  echo -e "::: Instalando scripts en ${pivpnScriptDir}..."

  # si el archivo del otro protocolo existe, se ha instalado
  if [[ -r "${setupConfigDir}/${othervpn}/${setupVarsFile}" ]]; then
    # Ambos están instalados, sin autocompletado de bash, desvincular si ya está ahí
    ${SUDO} unlink /etc/bash_completion.d/pivpn

    # Desvincular el script pivpn específico del protocolo y enlazar simbólicamente el script
    # común a la ubicación en su lugar
    ${SUDO} unlink /usr/local/bin/pivpn
    ${SUDO} ln -sfT "${pivpnFilesDir}/scripts/pivpn" /usr/local/bin/pivpn
  else
    # Comprobar si el directorio de scripts bash_completion existe y crearlo si no
    ${SUDO} mkdir -p /etc/bash_completion.d

    # Solo hay un protocolo instalado, enlazar simbólicamente el autocompletado de bash, el script pivpn
    # y el directorio de scripts
    ${SUDO} ln -sfT \
      "${pivpnFilesDir}/scripts/${VPN}/bash-completion" \
      /etc/bash_completion.d/pivpn
    ${SUDO} ln -sfT \
      "${pivpnFilesDir}/scripts/${VPN}/pivpn.sh" \
      /usr/local/bin/pivpn
    ${SUDO} ln -sf "${pivpnFilesDir}/scripts/" "${pivpnScriptDir}"
    # shellcheck disable=SC1091
    . /etc/bash_completion.d/pivpn
  fi

  echo " hecho."
}

displayFinalMessage() {
  # Asegurar que las escrituras en caché lleguen al almacenamiento persistente
  echo "::: Vaciando escrituras en el disco..."

  sync

  echo "::: hecho."

  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: ¡Instalación Completada!"
    echo "::: Ahora ejecuta 'pivpn add' para crear los perfiles de los clientes."
    echo "::: ¡Ejecuta 'pivpn help' para ver qué más puedes hacer!"
    echo
    echo -n "::: Si te encuentras con algún problema, por favor lee toda nuestra documentación "
    echo "cuidadosamente."
    echo "::: Todas las publicaciones o informes de errores incompletos serán ignorados o eliminados."
    echo
    echo "::: Gracias por usar PiVPN."
    echo "::: Se recomienda encarecidamente reiniciar después de la instalación."
    return
  fi

  # Mensaje de finalización para el usuario
  whiptail \
    --backtitle "Haz que así sea." \
    --title "¡Instalación Completada!" \
    --msgbox "Ahora ejecuta 'pivpn add' para crear los perfiles de los clientes.
¡Ejecuta 'pivpn help' para ver qué más puedes hacer!

Si te encuentras con algún problema, por favor lee toda nuestra documentación cuidadosamente.
Todas las publicaciones o informes de errores incompletos serán ignorados o eliminados.

Gracias por usar PiVPN." "${r}" "${c}"

  if whiptail \
    --title "Reiniciar" \
    --defaultno \
    --yesno "Se recomienda encarecidamente reiniciar después de la instalación. \
¿Te gustaría reiniciar ahora?" "${r}" "${c}"; then
    whiptail \
      --title "Reiniciando" \
      --msgbox "El sistema se reiniciará ahora." "${r}" "${c}"
    printf "\\nReiniciando el sistema...\\n"
    ${SUDO} sleep 3

    ${SUDO} reboot
  fi
}

main "$@"
