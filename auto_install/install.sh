#!/usr/bin/env bash
# PiVPN: Configuración e instalación trivial de OpenVPN o WireGuard
# La configuración y gestión más sencilla de OpenVPN o WireGuard en Raspberry Pi OS, Debian y Ubuntu.
export LANG=es_ES.UTF-8
export LC_ALL=es_ES.UTF-8

# ==============================================================================
#                 CONFIGURACIÓN DE RUTAS Y VARIABLES GLOBALES
# ==============================================================================

pivpnGitUrl="https://github.com/pivpn/pivpn.git"

# Para desarrollo: Descomentar y asignar una rama específica si se desea probar código en pruebas
# pivpnGitBranch="custombranchtocheckout"

# Archivos y directorios clave del ecosistema PiVPN
setupVarsFile="setupVars.conf"
setupConfigDir="/etc/pivpn"
tempsetupVarsFile="/tmp/setupVars.conf"
pivpnFilesDir="/usr/local/src/pivpn"
pivpnScriptDir="/opt/pivpn"
GITBIN="/usr/bin/git"

# Integraciones de terceros (Pi-hole / DNSMasq)
piholeVersions="/etc/pihole/versions"
dnsmasqConfig="/etc/dnsmasq.d/02-pivpn.conf"

# Archivos de red y asignaciones de seguridad de OpenVPN
dhcpcdFile="/etc/dhcpcd.conf"
ovpnUserGroup="openvpn:openvpn"

# ==============================================================================
#            GESTIÓN DE PAQUETES Y ARREGLOS DE DEPENDENCIAS
# ==============================================================================

PKG_MANAGER="apt-get"

# SOLUCIÓN DE ERROR CRÍTICO: El uso de cadenas simples provocaba fallos de parsing en ShellCheck (SC2086) 
# y cuelgues aleatorios en el flujo. Se transforman a arreglos nativos de Bash para una expansión segura.
UPDATE_PKG_CACHE=("${PKG_MANAGER}" "update" "-y")
PKG_INSTALL=("${PKG_MANAGER}" "--yes" "--no-install-recommends" "install")

# Comando de monitorización (mantiene estructura de cadena debido al uso de tuberías/pipes)
PKG_COUNT="${PKG_MANAGER} -s -o Debug::NoLocking=true upgrade | grep -c ^Inst || true"
CHECK_PKG_INSTALLED='dpkg-query -s'

# Dependencias base necesarias para sistemas Debian / Ubuntu (independientes del protocolo)
BASE_DEPS=(
  git 
  tar 
  curl 
  grep 
  bind9-dnsutils 
  grepcidr 
  whiptail 
  net-tools
  bsdmainutils 
  bash-completion
)

# Dependencias base optimizadas exclusivamente para entornos Alpine Linux
BASE_DEPS_ALPINE=(
  git 
  grep 
  bind-tools 
  newt 
  net-tools 
  bash-completion 
  coreutils
  openssl 
  util-linux 
  openrc 
  iptables 
  ip6tables 
  sed
  perl 
  libqrencode-tools
)

# Registro dinámico de paquetes instalados durante esta sesión. 
# Evita purgar utilidades preexistentes del usuario al ejecutar una desinstalación.
INSTALLED_PACKAGES=()

# ==============================================================================
#                         RECURSOS Y COMPONENTES EXTERNOS
# ==============================================================================

easyrsaVer="3.2.3"
easyrsaRel="https://github.com/OpenVPN/easy-rsa/releases/download/v${easyrsaVer}/EasyRSA-${easyrsaVer}.tgz"

# ==============================================================================
#          BANDERAS DE AUTOMATIZACIÓN (MODO DESATENDIDO / ADVANCED)
# ==============================================================================

runUnattended=false
usePiholeDNS=false
skipSpaceCheck=false
reconfigure=false
showUnsupportedNICs=false

# Inicializaciones preventivas de variables globales para mitigar errores 
# de referencia vacía ("unbound variable") durante comprobaciones lógicas estrictas.
pivpnPERSISTENTKEEPALIVE=""
pivpnDNS2=""

# ==============================================================================
#                  POLÍTICAS Y CONFIGURACIONES DE RED IPv6
# ==============================================================================

# Nota técnica: El uso del parámetro CLI "--noipv6" desactiva por completo el protocolo,
# previniendo tanto fugas como enrutamientos forzados innecesarios.
# El uso de "--ignoreipv6leak" mitiga la inyección de rutas (No recomendado en producción).

# 1 = Mitigación activa. Fuerza el tráfico IPv6 a través del túnel VPN para prevenir fugas (leak)
# en el cliente, incluso si el servidor carece de conectividad IPv6 nativa hacia el exterior.
pivpnforceipv6route=1

# Estado dinámico del protocolo. Un valor vacío o "1" iniciará un test de enlace ascendente (uplink).
pivpnenableipv6=""

# 1 = Modo bypass estricto. Omite las pruebas de conectividad de red locales y fuerza la tunelización
# total de paquetes IPv6 del cliente hacia la interfaz de WireGuard de forma incondicional.
pivpnforceipv6=0

# ==============================================================================
#          CÁLCULO DINÁMICO DE RESOLUCIÓN PARA INTERFACES WHIPTAIL
# ==============================================================================

# Captura geométrica de la terminal. Si falla o se ejecuta en entornos no interactivos,
# se asume una matriz segura estandarizada de 24 filas por 80 columnas.
screen_size="$(stty size 2> /dev/null || echo "24 80")"

# OPTIMIZACIÓN DE RENDIMIENTO: Reemplazo de subprocesos 'awk' por el comando interno 'read' de Bash.
# Esto reduce el consumo de CPU y elimina dependencias de binarios externos en la inicialización.
read -r rows columns <<< "${screen_size}"

# Dimensionamiento adaptativo: Los menús interactivos escalarán al 50% del tamaño total disponible.
r=$(( rows / 2 ))
c=$(( columns / 2 ))

# MÁRGENES DE SEGURIDAD INTERFAZ: Forzamos límites mínimos de 20 filas y 70 columnas.
# Esto garantiza la correcta visualización de los contenedores de texto, saltos de línea
# y botones de acción de 'Whiptail', evitando truncamientos de interfaz en pantallas pequeñas.
[[ ${r} -lt 20 ]] && r=20
[[ ${c} -lt 70 ]] && c=70

# ==============================================================================
#               TRAZABILIDAD Y MENSAJES DE INICIALIZACIÓN (LOGS)
# ==============================================================================

echo "::: "
echo "::: [INFO] Inicializando variables del entorno e identificando recursos del sistema..."
echo "::: [INFO] Geometría de pantalla configurada para diálogos: ${r} Filas x ${c} Columnas."

# Mantenemos desactivada la sobrescritura forzada de localización del sistema para permitir
# que los mensajes y diálogos emergentes se rendericen en el idioma nativo configurado (ej: es_ES).
# export LC_ALL=C

main() {
  # Asegura la eliminación automática de configuraciones temporales al salir,
  # ya sea por finalización exitosa, error crítico o cancelación con Ctrl+C.
  trap 'rm -f "${tempsetupVarsFile}"' EXIT

  # ==========================================
  # FASE 1: VALIDACIONES E INICIALIZACIÓN
  # ==========================================

  # Procesa primero los argumentos de entrada (--unattended, --skip-space-check, etc.)
  # para que sus variables asociadas estén disponibles en las comprobaciones posteriores.
  flagsCheck "$@"
  distroCheck
  rootCheck
  unattendedCheck
  checkExistingInstall "$@"
  checkHostname

  # Comprobación de almacenamiento disponible
  if [[ "${skipSpaceCheck}" == 'true' ]]; then
    echo "::: Opción --skip-space-check activa: Omitiendo la validación de espacio libre en disco."
  else
    verifyFreeDiskSpace
  fi

  # ==========================================
  # FASE 2: GESTIÓN DE PAQUETES Y DEPENDENCIAS
  # ==========================================

  updatePackageCache
  notifyPackageUpdatesAvailable
  preconfigurePackages

  # Selección e instalación del conjunto de dependencias según la distribución
  if [[ "${PLAT}" == 'Alpine' ]]; then
    installDependentPackages BASE_DEPS_ALPINE
  else
    installDependentPackages BASE_DEPS
  fi

  # Mostrar diálogos de bienvenida interactivos
  welcomeDialogs

  # ==========================================
  # FASE 3: CONFIGURACIÓN DE RED (IPv4 / IPv6)
  # ==========================================

  # Evaluación y enrutamiento del protocolo IPv6
  if [[ "${pivpnforceipv6}" -eq 1 ]]; then
    echo "::: Forzando IPv6 por parámetro: Omitiendo la comprobación del enlace ascendente."
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

  # Configuración de interfaces y asignación de direccionamiento IP estático
  chooseInterface

  if checkStaticIpSupported; then
    getStaticIPv4Settings

    # Aplica IP estática solo si no se ha confirmado una reserva DHCP previa
    if [[ "${dhcpReserv}" != "1" ]]; then
      setStaticIPv4
    fi
  else
    staticIpNotSupported
  fi

  # Selección del usuario local del sistema que gestionará los perfiles VPN
  chooseUser
  cloneOrUpdateRepos

  # ==========================================
  # FASE 4: INSTALACIÓN Y DESPLIEGUE NÚCLEO
  # ==========================================

  # Ejecución del instalador principal de la VPN
  if installPiVPN; then
    echo "::: Instalación del núcleo completada con éxito."
  else
    echo "::: [ERROR CRÍTICO] Falló la instalación del núcleo de PiVPN. Abortando proceso."
    exit 1
  fi

  # Reinicio de los servicios de red y del software VPN para aplicar los cambios
  restartServices
  
  # ==========================================
  # FASE 5: POST-INSTALACIÓN Y CONFIGURACIÓN
  # ==========================================

  # Gestión del servicio de actualizaciones de seguridad desatendidas
  askUnattendedUpgrades

  if [[ "${UNATTUPG}" == "1" ]]; then
    confUnattendedUpgrades
  fi

  # Escritura de perfiles, variables finales y despliegue de comandos del sistema
  if ! writeConfigFiles; then
    echo "::: [ERROR CRÍTICO] No se pudieron generar los archivos de configuración finales."
    exit 1
  fi

  if ! installScripts; then
    echo "::: [ERROR CRÍTICO] No se pudieron desplegar los scripts de gestión 'pivpn' en el sistema."
    exit 1
  fi

  # Muestra el resumen final de la instalación y opciones de reinicio del servidor
  displayFinalMessage
  echo ":::"
}

####### FUNCTIONS ##########

# Genera un flujo de salida formateado hacia el canal de errores estándar (stderr)
# incluyendo una marca de tiempo estandarizada ISO 8601.
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [ERROR]: $*" >&2
}

rootCheck() {
  echo ":::"
  
  # Validación de UID: El identificador 0 corresponde exclusivamente a 'root'
  if [[ "${EUID}" -eq 0 ]]; then
    echo "::: [INFO] Privilegios nativos de administrador (root) confirmados."
    # Asegura la limpieza de variables de prefijo en entornos root puros
    export SUDO=""
    export SUDOE=""
  else
    # Corrección de redacción: El script no eleva privilegios por sí mismo en este punto,
    # prepara las variables de entorno para la ejecución delegada posterior.
    echo "::: [INFO] Usuario estándar detectado. Configurando entorno seguro mediante 'sudo'..."

    # Verifica mediante el gestor nativo de la distribución si 'sudo' se encuentra operativo
    if eval "${CHECK_PKG_INSTALLED} sudo" &> /dev/null; then
      export SUDO="sudo"
      export SUDOE="sudo -E"
      echo "::: [INFO] Herramienta 'sudo' validada. Se aplicará como prefijo en tareas del sistema."
    else
      err "Entorno restrictivo. El instalador requiere binarios de elevación. Por favor, instala 'sudo' o ejecuta el script como root."
      exit 1
    fi
  fi
}

flagsCheck() {
  echo ":::"
  echo "::: [INFO] Iniciando el análisis de argumentos y directivas de ejecución por CLI..."

  # SOLUCIÓN DE BUG CRÍTICO: El bucle clásico 'for ((i...))' con expansión indirecta '${!j}'
  # procesaba los argumentos de las banderas (ej. la ruta de --unattended) como si fueran
  # banderas independientes en la siguiente iteración. 
  # Se migra a un control de flujo 'while' nativo basado en desplazamientos ('shift').
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skip-space-check)
        skipSpaceCheck=true
        echo "::: [PARAM] Directiva activa: Omitiendo la comprobación de almacenamiento local."
        shift
        ;;
      --unattended)
        runUnattended=true
        # Validación preventiva: Asegura que exista un argumento posterior y que no sea otra bandera
        if [[ -n "$2" && "$2" != -* ]]; then
          unattendedConfig="$2"
          echo "::: [PARAM] Modo desatendido activo. Cargando configuración desde: ${unattendedConfig}"
          shift 2
        else
          err "La bandera '--unattended' requiere una ruta válida a un archivo de configuración."
          exit 1
        fi
        ;;
      --use-pihole)
        usePiholeDNS=true
        echo "::: [PARAM] Integración activa: Forzando uso del servidor DNS Pi-hole local."
        shift
        ;;
      --reconfigure)
        reconfigure=true
        echo "::: [PARAM] Solicitud activa: Iniciando el asistente en modo reconfiguración total."
        shift
        ;;
      --show-unsupported-nics)
        showUnsupportedNICs=true
        echo "::: [PARAM] Modo avanzado: Permitiendo visualización de interfaces de red no homologadas."
        shift
        ;;
      --giturl)
        if [[ -n "$2" && "$2" != -* ]]; then
          pivpnGitUrl="$2"
          echo "::: [PARAM] Despliegue modificado: Repositorio origen reasignado a: ${pivpnGitUrl}"
          shift 2
        else
          err "La bandera '--giturl' requiere una URL válida a un repositorio de Git."
          exit 1
        fi
        ;;
      --gitbranch)
        if [[ -n "$2" && "$2" != -* ]]; then
          pivpnGitBranch="$2"
          echo "::: [PARAM] Despliegue modificado: Cambiando a la rama de desarrollo: ${pivpnGitBranch}"
          shift 2
        else
          err "La bandera '--gitbranch' requiere especificar el nombre de una rama válida."
          exit 1
        fi
        ;;
      --noipv6)
        pivpnforceipv6=0
        pivpnenableipv6=0
        pivpnforceipv6route=0
        echo "::: [PARAM] Directiva estricta: Desactivación completa del direccionamiento IPv6."
        shift
        ;;
      --ignoreipv6leak)
        pivpnforceipv6route=0
        echo "::: [PARAM] Advertencia: Se ignorará la inyección de rutas para mitigar fugas IPv6."
        shift
        ;;
      *)
        # Captura e informa al administrador sobre argumentos huérfanos o inválidos pasados al script
        echo "::: [ADVERTENCIA] Parámetro desconocido detectado e ignorado en el flujo: $1"
        shift
        ;;
    esac
  done

  echo "::: [INFO] Finalizado el análisis de argumentos. Estado del entorno consolidado."
}

# ==============================================================================
#                 COMPROBACIONES DE MODO DE EJECUCIÓN Y ENTORNO
# ==============================================================================

unattendedCheck() {
  # Cláusula de guarda: Si no se solicita instalación desatendida, salir de inmediato
  [[ "${runUnattended}" != 'true' ]] && return

  echo "::: [INFO] Modo desatendido activo (--unattended). Se omitirán las interfaces gráficas (whiptail)."

  # Validación de presencia del argumento de configuración
  if [[ -z "${unattendedConfig}" ]]; then
    err "Operación abortada: No se especificó la ruta del archivo de configuración para el modo desatendido."
    exit 1
  fi

  # Validación de existencia y permisos de lectura del archivo de configuración
  if [[ ! -r "${unattendedConfig}" ]]; then
    err "Error de lectura: El archivo de configuración desatendida '${unattendedConfig}' no existe o no es accesible."
    exit 1
  fi

  echo "::: [INFO] Importando directivas de aprovisionamiento desde: ${unattendedConfig}"
  # shellcheck disable=SC1090
  . "${unattendedConfig}"
}

checkExistingInstall() {
  # Definición explícita de variable local para proteger el espacio de nombres global
  local setupVars=""
  
  echo "::: [INFO] Analizando el sistema en busca de instancias previas de PiVPN..."

  # Identificación de rutas y perfiles de configuración según el protocolo implementado
  if [[ -r "${setupConfigDir}/wireguard/${setupVarsFile}" ]]; then
    setupVars="${setupConfigDir}/wireguard/${setupVarsFile}"
    echo "::: [INFO] Alerta: Se detectó un entorno preexistente de WireGuard."
  elif [[ -r "${setupConfigDir}/openvpn/${setupVarsFile}" ]]; then
    setupVars="${setupConfigDir}/openvpn/${setupVarsFile}"
    echo "::: [INFO] Alerta: Se detectó un entorno preexistente de OpenVPN."
  fi

  # Saneamiento del entorno: Eliminación segura de residuos temporales de sesiones previas
  if [[ -f "${tempsetupVarsFile}" ]]; then
    echo "::: [INFO] Removiendo archivo de variables temporal obsoleto..."
    ${SUDO} rm -f "${tempsetupVarsFile}"
  fi

  # Evaluación del flujo de toma de decisiones ante sistemas existentes
  if [[ -n "${setupVars}" ]]; then
    if [[ "${reconfigure}" == 'true' ]]; then
      echo "::: [PARAM] Directiva --reconfigure detectada: Se sobrescribirá por completo el despliegue actual."
      UpdateCmd="Reconfigure"
    elif [[ "${runUnattended}" == 'true' ]]; then
      echo "::: [PARAM] Colisión detectada en modo desatendido: Forzando reconfiguración automatizada."
      UpdateCmd="Reconfigure"
    else
      # Invoca el cuadro de diálogo gráfico interactivo (puede devolver valores en español)
      askAboutExistingInstall "${setupVars}"
    fi
  fi

  # ==============================================================================
  #            PROCESAMIENTO Y ENRUTAMIENTO DE LA ESTRATEGIA DE CONTROL
  # ==============================================================================
# Soportamos tanto los flags internos (inglés) como las respuestas de la interfaz (español)
  case "${UpdateCmd}" in
    Update|[Aa]ctualizar)
      echo "::: [INFO] Delegando el ciclo de vida al script oficial de actualización de PiVPN..."
      ${SUDO} "${pivpnScriptDir}/update.sh" "$@"
      exit "$?"
      ;;
      
    Repair|[Rr]eparar)
      echo "::: [INFO] Modo reparación activo. Restaurando variables de entorno históricas..."
      # shellcheck disable=SC1090
      . "${setupVars}"
      runUnattended=true
      ;;
      
    Reconfigure|[Rr]econfigurar|"")
      # Flujo normal o de sobreescritura: Informamos trazabilidad y permitimos continuar al main()
      if [[ -n "${setupVars}" ]]; then
        echo "::: [INFO] Preparando los módulos para la reescritura total de la VPN."
      else
        echo "::: [INFO] No se encontraron trazas de software previo. Procediendo con instalación limpia."
      fi
      ;;
      
    *)
      err "Estado de control inconsistente: La directiva de actualización '${UpdateCmd}' no está homologada."
      exit 1
      ;;
  esac
}

askAboutExistingInstall() {
  # TRAZABILIDAD: Registro previo para monitorizar la apertura de componentes interactivos en primer plano
  echo "::: [INFO] Iniciando cuadro de diálogo interactivo para resolver colisión de instalación..."

  # ÁMBITO SEGURO: Declaración local de etiquetas del menú con terminología técnica homologada
  local opt1a="Actualizar"
  local opt1b="Actualizar scripts y componentes internos de PiVPN"

  local opt2a="Reparar"
  local opt2b="Corrige archivos corruptos manteniendo configuración"

  local opt3a="Reconfigurar"
  local opt3b="Reinstalar desde cero o modificar protocolo VPN"

  # INTERFAZ DE USUARIO: Menú adaptativo estructurado con información detallada del entorno detectado
UpdateCmd="$(whiptail \
    --backtitle "Asistente de Configuración PiVPN" \
    --title "¡Instalación Existente Detectada!" \
    --ok-button "Seleccionar" \
    --cancel-button "Cancelar" \
    --menu "El asistente ha detectado un entorno de PiVPN ya operativo en este sistema.

Archivo de variables localizado:
• ${1}

Por favor, selecciona la acción que deseas realizar para continuar:" "${r}" "${c}" 3 \
    "${opt1a}" "${opt1b}" \
    "${opt2a}" "${opt2b}" \
    "${opt3a}" "${opt3b}" \
    3>&2 2>&1 1>&3)" \
    || {
      echo ":::"
      err "Instalación cancelada por el usuario en el menú de selección de entorno existente."
      exit 1
    }

  # TRAZABILIDAD: Confirmación del estado consolidado para guiar los bloques de enrutamiento subsiguientes
  echo "::: [INFO] Acción seleccionada con éxito: '${UpdateCmd}'."
}

distroCheck() {
  # TRAZABILIDAD: Registro de entrada para auditoría y diagnóstico de compatibilidad del sistema
  echo "::: [INFO] Iniciando análisis de compatibilidad de la distribución de Linux..."

  # ==============================================================================
  # DETERMINACIÓN DE PLATAFORMA Y NOMBRE CLAVE (CODENAME)
  # ==============================================================================
  if command -v lsb_release > /dev/null; then
    echo "::: [INFO] Componente 'lsb_release' detectado. Extrayendo metadatos del entorno..."
    PLAT="$(lsb_release -si)"
    OSCN="$(lsb_release -sc)"
    
    # NORMALIZACIÓN: Uniformar el identificador de Raspberry Pi OS para mantener consistencia con el script
    if [[ "${PLAT}" == "RaspberryPiOS" ]]; then
      PLAT="Raspberry"
    fi
  else
    echo "::: [INFO] 'lsb_release' no disponible. Consultando archivo de sistema '/etc/os-release'..."
    # shellcheck disable=SC1091
    . /etc/os-release
    
    # Clasificación de entornos específicos basados en arquitecturas ARM / Raspberry
    if [[ "${ID}" == "raspbian" || "${ID}" == "raspberrypi" || "${ID_LIKE}" == *"raspbian"* ]]; then
      PLAT="Raspberry"
    else
      # OPTIMIZACIÓN: Reemplazo de subproceso externo 'awk' por expansión de parámetros interna de Bash.
      # Elimina la bifurcación de CPU extrayendo de forma segura la primera palabra del campo NAME.
      PLAT="${NAME%% *}"
    fi
    
    VER="${VERSION_ID}"
    
    # ÁMBITO SEGURO: Declaración local del mapa asociativo de versiones para prevenir polución global
    local -A VER_MAP=(
      ["11"]="bullseye"
      ["12"]="bookworm"
      ["13"]="trixie"
      ["20.04"]="focal"
      ["22.04"]="jammy"
      ["24.04"]="noble"
      ["26.04"]="resolute"
    )
    OSCN="${VER_MAP["${VER}"]}"

    # SOPORTE INTEGRADO: Si la distribución carece de codename textual (ej. Alpine), se adopta su versión numérica
    if [[ -z "${OSCN}" ]]; then
      OSCN="${VER}"
    fi
  fi

  echo "::: [INFO] Resultados del análisis de entorno: Plataforma='${PLAT}' | Nombre Clave='${OSCN}'."

  # ==============================================================================
  # VALIDACIÓN Y CONFIGURACIÓN DINÁMICA DE ENTORNO SEGÚN DISTRIBUCIÓN
  # ==============================================================================
  case "${PLAT}" in
    Debian | Raspbian | Raspberry | Ubuntu)
      case "${OSCN}" in
        bullseye | bookworm | trixie | focal | jammy | noble | resolute)
          echo "::: [INFO] Validación exitosa: Entorno homologado y totalmente compatible."
          ;;
        *)
          echo "::: [ADVERTENCIA] Nombre clave '${OSCN}' no verificado oficialmente. Evaluando soporte secundario..."
          maybeOSSupport
          ;;
      esac
      ;;
      
    Alpine)
      echo "::: [INFO] Arquitectura Alpine Linux identificada. Reconfigurando subsistema de paquetes a 'apk'..."
      PKG_MANAGER='apk'
      UPDATE_PKG_CACHE="${PKG_MANAGER} update"
      PKG_INSTALL="${PKG_MANAGER} --no-cache add"
      PKG_COUNT="${PKG_MANAGER} list -u | wc -l || true"
      CHECK_PKG_INSTALLED="${PKG_MANAGER} --no-cache info -e"
      ;;
      
    *)
      echo "::: [ERROR CRÍTICO] Distribución '${PLAT}' no compatible o fuera de los parámetros de soporte."
      noOSSupport
      ;;
  esac

  # PERSISTENCIA: Volcado seguro de las variables validadas para su posterior consumo por los submódulos
  echo "::: [INFO] Almacenando variables de entorno consolidadas en el perfil temporal..."
  {
    echo "PLAT=${PLAT}"
    echo "OSCN=${OSCN}"
  } > "${tempsetupVarsFile}"
}

noOSSupport() {
  if [[ "${runUnattended}" == 'true' ]]; then
    err "::: Sistema Operativo no válido detectado"
    err "::: No hemos podido detectar un Sistema Operativo compatible."
    err "::: Actualmente este instalador soporta Raspberry Pi OS, Debian y Ubuntu."
    exit 1
  fi

  whiptail \
  --backtitle "Error de Compatibilidad de Sistema Operativo" \
  --title "Sistema Operativo No Soportado" --ok-button "Salir" \
  --msgbox "El asistente no ha podido detectar una distribución Linux compatible con este instalador de forma nativa.

Para garantizar la estabilidad, este script solo está diseñado para:
• Raspberry Pi OS (32 y 64 bits)
• Debian Linux
• Ubuntu Server

Si crees que se trata de un error o deseas revisar los requisitos técnicos, por favor consulta la documentación en:
https://github.com/wfhgdev/pivpn_spanish" "${r}" "${c}"
  exit 1
}

maybeOSSupport() {
  # TRAZABILIDAD: Registro inicial para dejar constancia en auditorías del proceso de evaluación del sistema
  echo "::: [INFO] Evaluando compatibilidad para sistema operativo no verificado oficialmente..."

  # MODO DESATENDIDO: Forzar continuación automatizada si se ha declarado la bandera 'runUnattended'
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: [ADVERTENCIA] Entorno operativo alternativo detectado en modo desatendido."
    echo "::: [INFO] Omitiendo confirmación visual; continuando instalación en la distribución derivada..."
    return
  fi

  # INTERFAZ DE USUARIO: Cuadro de diálogo interactivo para validar la continuidad en entornos derivados
  if whiptail \
    --backtitle "Verificación de Compatibilidad" \
    --title "Distribución Alternativa Detectada" --yes-button "Continuar" --no-button "Salir" \
    --yesno "El asistente ha detectado que estás utilizando una distribución alternativa o derivada.

Nativamente, este instalador está optimizado para:
• Raspberry Pi OS
• Debian Linux
• Ubuntu Server

Al estar basado en una de estas distribuciones principales, el script suele ejecutarse y configurar la VPN de manera exitosa. Te sugerimos avanzar y supervisar el proceso.

Puedes reportar cualquier incidencia o tu experiencia de uso en:
https://github.com/wfhgdev/pivpn_spanish

¿Deseas continuar con la instalación en este sistema?" "${r}" "${c}"; then
    
    # TRAZABILIDAD: Registro de confirmación afirmativa del administrador
    echo "::: [INFO] Consentimiento otorgado. Continuando con el despliegue en distribución derivada..."
  else
    # ERROR CONTROLADO: Cierre limpio del script delegando el formateo a la función nativa err()
    err "Instalación abortada por el usuario al rechazar el entorno de distribución alternativa."
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
        --title "Ajuste del Nombre de Host" --ok-button "Guardar" --cancel-button "Cancelar" \
        --inputbox "El nombre actual de este equipo excede el límite permitido para configurar la VPN. Por favor, introduce uno nuevo:

Requisitos:
• Máximo 28 caracteres de longitud.
• Solo letras, números y guiones (sin espacios ni caracteres especiales)." "${r}" "${c}" \
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
  echo -e "::: Actualizando la caché de repositorios locales (${UPDATE_PKG_CACHE})..."
  # shellcheck disable=SC2086
  ${SUDO} ${UPDATE_PKG_CACHE} &> /dev/null &
  spinner "$!"
  echo " ¡hecho!"
}

notifyPackageUpdatesAvailable() {
  # Informar al usuario si tiene paquetes desactualizados en su sistema y
  # aconsejarle que ejecute una actualización de paquetes lo antes posible.
  echo ":::"
  echo -n "::: Verificando actualizaciones disponibles mediante ${PKG_MANAGER}..."
  updatesToInstall="$(eval "${PKG_COUNT}")"
  echo " ¡hecho!"
  echo ":::"

  if [[ "${updatesToInstall}" -eq 0 ]]; then
    echo "::: El sistema está al día. Continuando con el despliegue..."
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
  #         Raspberry Pi OS podemos añadirlo mediante el repositorio Bullseye.
  # caso 3: Si el módulo no está integrado, en Raspberry Pi OS conocemos
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

  # CAMBIO: Añadido "Raspberry" a las comprobaciones de soporte de WireGuard para evitar que aborte la instalación en sistemas arm64 modernos
  if [[ "${WIREGUARD_BUILTIN}" -eq 1 && -n "${AVAILABLE_WIREGUARD}" ]] \
    || [[ "${WIREGUARD_BUILTIN}" -eq 1 && ("${PLAT}" == 'Debian' || "${PLAT}" == 'Raspbian' || "${PLAT}" == 'Raspberry') ]] \
    || [[ "${PLAT}" == 'Raspbian' || "${PLAT}" == 'Raspberry' ]] \
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
    echo -n ":::    Dependencia: ${i}..."

    if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
      if dpkg-query -W -f='${Status}' "${i}" 2> /dev/null \
        | grep -q "ok installed"; then
        echo " [Detectada]"
      else
        echo " [No detectada - Marcada para instalar]"
        # Añadir este paquete a la lista de paquetes en el arreglo de argumentos que
        # necesitan ser instalados
        TO_INSTALL+=("${i}")
      fi
    elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
      if eval "${SUDO} ${CHECK_PKG_INSTALLED} ${i}" &> /dev/null; then
        echo " [Detectada]"
      else
        echo " [No detectada - Marcada para instalar]"
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
        echo ":::    -> ${i} instalado con éxito."
        # Añadir este paquete a la lista total de paquetes que realmente fueron
        # instalados por el script
        INSTALLED_PACKAGES+=("${i}")
      else
        echo ":::    ¡Fallo al instalar ${i}!"
        ((FAILED++))
      fi
    elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
      if eval "${SUDO} ${CHECK_PKG_INSTALLED} ${i}" &> /dev/null; then
        echo ":::    -> ${i} instalado con éxito."
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

  # CAMBIO: Se ha reestructurado el mensaje de bienvenida para que sea más directo, estético y use un tono profesional de bienvenida al asistente en español ()
  whiptail \
    --backtitle "Asistente de Instalación PiVPN" \
    --title "Bienvenido a PiVPN en Español" --ok-button "Comenzar" \
    --msgbox "Este asistente interactivo simplificará la instalación y gestión de tu servidor VPN (WireGuard o OpenVPN).

PiVPN automatiza las configuraciones complejas de red y seguridad, permitiéndote desplegar un servidor seguro en cuestión de minutos, ideal tanto para Raspberry Pi como para servidores locales o virtuales basados en Debian y Ubuntu." "${r}" "${c}"

  # CAMBIO: Se ha pulido la explicación sobre la IP estática. Ahora aclara que la IP del servidor no debe cambiar para evitar que los clientes externos pierdan la conexión, y presenta las opciones de red de manera más clara ()
  whiptail \
    --backtitle "Configuración de Red Local" \
    --title "Requisito: Dirección IP Fija (Estática)" --ok-button "Aceptar" \
    --msgbox "Para que tus dispositivos puedan conectarse de forma remota, este servidor necesita una dirección IP local fija que no cambie con el tiempo.

A continuación, evaluaremos tu conexión de red actual. Podrás elegir mantener los parámetros que ya tienes asignados por DHCP o editarlos manualmente si lo consideras necesario." "${r}" "${c}"
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
(presiona tecla espacio para seleccionar):" "${r}" "${c}" "${interfaceCount}")

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
IPv4 (presiona tecla espacio para seleccionar):" "${r}" "${c}" "${interfaceCount}")

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
  # CAMBIO: Añadida compatibilidad con el nuevo PLAT="Raspberry" unificado ()
  if [[ "${PLAT}" == "Raspbian" || "${PLAT}" == "Raspberry" ]]; then
    return 0
  elif [[ "${PLAT}" == "Debian" ]] \
    && [[ -s /etc/apt/sources.list.d/raspi.list || -s /etc/apt/sources.list.d/raspi.sources ]]; then
    return 0
  else
    return 1
  fi
}

staticIpNotSupported() {
  # Mensaje de advertencia para usuarios que no usan una Raspberry Pi
  # ya que la configuración automática local de IP estática solo está diseñada para ese entorno.
  if [[ "${AUTOMATED_INSTALL}" -eq 1 ]]; then
    echo "::: El instalador no gestionará la configuración de red automática"
    echo "::: en este sistema operativo."
    return
  fi

  # CAMBIO: Se ha reescrito el texto del cuadro de diálogo para adaptarlo a sistemas modernos (Ubuntu/Debian genéricos) y recomendar prácticas estándar como la reserva DHCP en el router
  whiptail \
    --backtitle "Configuración de Dirección IP" \
    --title "Aviso de IP Estática" --ok-button "Entendido" \
    --msgbox "Este instalador solo puede configurar IPs estáticas de forma automática en entornos basados en Raspberry Pi OS.

• Si estás en un servidor en la nube (AWS, Oracle, Google Cloud, etc.), tu proveedor ya gestiona la IP interna y no necesitas hacer nada aquí.
• Si estás en un servidor local (Ubuntu Server, Debian, Proxmox), te recomendamos encarecidamente asignar una IP fija a esta máquina mediante una 'Reserva DHCP' en la configuración de tu enrutador.

Si prefieres hacerlo manualmente en el sistema operativo, asegúrate de configurar Netplan o /etc/network/interfaces antes de poner el servidor en producción." "${r}" "${c}"
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

  # CAMBIO: Se ha reestructurado por completo el texto explicativo del cuadro de diálogo para aclarar el concepto de 'Fuga de IPv6' (IPv6 Leak) y los pros/contras de su activación en clientes modernos
  if whiptail \
    --backtitle "Configuración de Privacidad y Seguridad" \
    --title "Prevención de Fugas IPv6 (IPv6 Leak)" --yes-button "Sí" --no-button "No" \
    --yesno "Este servidor no dispone de una conexión IPv6 activa. Sin embargo, los dispositivos que se conecten a tu VPN (móviles, portátiles) podrían estar en redes que sí usen IPv6 de forma nativa.

Si dejas esto desactivado, el tráfico de tus clientes podría 'fugarse' fuera del túnel seguro de la VPN y exponer su IP real al navegar por ciertas páginas web.

Para evitar esto, se recomienda forzar una ruta IPv6 dentro de la VPN. Esto bloqueará las fugas de datos y mejorará la privacidad, aunque en algunas redes muy específicas podría ralentizar ligeramente la resolución de páginas web en el cliente.

¿Deseas activar la protección para forzar el enrutamiento IPv6?" "${r}" "${c}"; then
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
    --backtitle "Configuración de la Interfaz de Red" \
    --title "Método de Asignación de IP" --yes-button "Mantener DHCP (Recomendado)" --no-button "Configurar Manualmente" \
    --defaultno \
    --yesno "Para asegurar la estabilidad de la VPN, el servidor necesita que su IP no cambie. El asistente ha detectado los siguientes parámetros actuales:

    • Dirección IP:       ${CurrentIPv4addr}
    • Puerta de enlace:   ${CurrentIPv4gw}

¿Tienes esta IP ya reservada de forma fija en la configuración de tu router (Reserva DHCP)? 

• Elige 'Mantener DHCP' si ya la has reservado en tu router o si no estás seguro (es la opción más segura).
• Elige 'Configurar Manual' si prefieres forzar una IP estática fija escribiéndola en este sistema." "${r}" "${c}"; then
    dhcpReserv=1

    {
      echo "dhcpReserv=${dhcpReserv}"
      # En realidad no necesitamos guardarlas ya que no configuraremos una IP estática
      # pero podrían ser útiles para la depuración
      echo "IPv4addr=${CurrentIPv4addr}"
      echo "IPv4gw=${CurrentIPv4gw}"
    } >> "${tempsetupVarsFile}"
  else
    # Preguntar si el usuario desea usar las configuraciones de DHCP como su IP local estática
    if whiptail \
      --backtitle "Configuración de la Interfaz de Red" \
      --title "Confirmación de IP Estática" --yes-button "Confirmar y Usar" --no-button "Modificar IP" \
      --yesno "Has elegido configurar una IP estática de forma manual. 

¿Deseas adoptar los parámetros de red actuales como tu IP fija definitiva o prefieres modificarlos?

    • Dirección IP:       ${CurrentIPv4addr}
    • Puerta de enlace:   ${CurrentIPv4gw}" "${r}" "${c}"; then
      IPv4addr="${CurrentIPv4addr}"
      IPv4gw="${CurrentIPv4gw}"

      {
        echo "IPv4addr=${IPv4addr}"
        echo "IPv4gw=${IPv4gw}"
      } >> "${tempsetupVarsFile}"

# CAMBIO: Se ha reescrito por completo el texto del cuadro de diálogo sobre conflictos de IP para corregir la imprecisión técnica. Ahora explica claramente el riesgo y promueve de forma asertiva el uso de reservas DHCP en el enrutador como la mejor práctica
whiptail \
  --backtitle "Configuración de Red Local" \
  --title "Aviso: Riesgo de Conflicto de IP" --ok-button "Entendido" \
  --msgbox "Al asignar una IP fija de forma local, existe la posibilidad de que tu enrutador intente asignar esta misma dirección a otro dispositivo en el futuro, lo que provocaría un conflicto de red y desconectaría tu VPN.

Para evitarlo por completo, tienes dos opciones recomendadas:

1. Configurar una 'Reserva DHCP' en la interfaz de tu enrutador para asociar de forma permanente esta IP a la dirección MAC de tu servidor (la opción más limpia y recomendada).
2. Modificar el rango de asignación DHCP de tu router para asegurarte de que esta IP quede fuera del alcance automático de los demás dispositivos.

Si ya has tomado alguna de estas medidas en tu enrutador, puedes continuar sin preocuparte." "${r}" "${c}"
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
            --backtitle "Configuración Manual de la Interfaz de Red" \
            --title "Asignar Dirección IPv4" --ok-button "Guardar" --cancel-button "Cancelar" \
            --inputbox "Introduce la dirección IPv4 local que deseas asignar de forma fija al servidor." "${r}" "${c}" "${CurrentIPv4addr}" \
            3>&1 1>&2 2>&3)"; then
            if validIPAndNetmask "${IPv4addr}"; then
              echo "::: Tu dirección IPv4 estática:    ${IPv4addr}"
              IPv4AddrValid=true
            else
              # CAMBIO: Se mejoró el mensaje de error de IP/Máscara para explicar de forma más clara la importancia del formato CIDR (Gemini)
          whiptail \
            --backtitle "Configuración Manual de la Interfaz de Red" \
            --title "Error: Formato IPv4 No Válido" --ok-button "Corregir" \
            --msgbox "La dirección IP introducida no es válida: ${IPv4addr}

Recuerda que debes incluir la máscara de red utilizando la notación CIDR.

Ejemplo correcto: 192.168.1.150/24
(Donde '/24' equivale a la máscara 255.255.255.0)" "${r}" "${c}"
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
          # CAMBIO: Se pulió el texto de entrada para la puerta de enlace, aclarando que corresponde a la IP local del router (Gemini)
      if IPv4gw="$(whiptail \
        --backtitle "Configuración Manual de la Interfaz de Red" \
        --title "Puerta de Enlace (Router)" --ok-button "Guardar" --cancel-button "Cancelar" \
        --inputbox "Introduce la dirección IP de tu puerta de enlace predeterminada (la IP local de tu router)." "${r}" "${c}" "${CurrentIPv4gw}" \
            3>&1 1>&2 2>&3)"; then
            if validIP "${IPv4gw}"; then
              echo "::: Tu puerta de enlace IPv4 estática:    ${IPv4gw}"
              IPv4gwValid=true
            else
              # CAMBIO: Se optimizó el mensaje de error para dar una guía clara con un ejemplo típico de red doméstica (Gemini)
              whiptail \
                --backtitle "Configuración Manual de la Interfaz de Red" \
                --title "Error: Puerta de Enlace No Válida" --ok-button "Corregir" \
                --msgbox "La dirección IP de la puerta de enlace no es válida: ${IPv4gw}

Por favor, introduce una dirección IP estándar sin máscara de red.

Ejemplo típico: 192.168.1.1" "${r}" "${c}"
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
        # CAMBIO: Se transformó el cuadro de verificación final para que sea una confirmación formal y limpia de los datos recolectados (Gemini)
        if whiptail \
          --backtitle "Configuración Manual de la Interfaz de Red" \
          --title "Revisión de Parámetros Fijos" --yes-button "Confirmar y Aplicar" --no-button "Modificar Datos" \
          --yesno "¿Son correctos los datos de red que has configurado para el servidor?

					• Dirección IPv4 (CIDR):  ${IPv4addr}
					• Puerta de enlace:       ${IPv4gw}" "${r}" "${c}"; then
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

  # Explicar el usuario local en el S.O.
  whiptail \
    --msgbox \
    --backtitle "Gestión de Usuarios del Sistema" \
    --title "Perfil de Almacenamiento VPN" --ok-button "Entendido" \
    --msgbox "El instalador necesita asociar los perfiles de los clientes VPN (archivos .ovpn o .conf) a un usuario del sistema que no sea 'root'.

A continuación, selecciona de la lista el usuario local que administrará estas configuraciones." "${r}" "${c}"
  # Primero, verifiquemos si hay un usuario disponible.
  numUsers="$(awk -F ':' \
    'BEGIN {count=0} $3>=1000 && $3<=60000 { count++ } END{ print count }' \
    /etc/passwd)"

  if [[ "${numUsers}" -eq 0 ]]; then
    # No tenemos un usuario, vamos a pedir añadir uno.
    if userToAdd="$(whiptail \
      --title "Elegir un usuario local del S.O." --ok-button "Aceptar" --cancel-button "Cancelar" \
      --inputbox \
      "No se encontró ninguna cuenta de usuario que no sea root. Escribe un nombre de usuario." \
      "${r}" \
      "${c}" \
      3>&1 1>&2 2>&3)"; then
      # See https://askubuntu.com/a/667842/459815
      PASSWORD="$(whiptail \
        --backtitle "Gestión de Usuarios del Sistema" \
        --title "Credenciales del Nuevo Usuario" \
        --passwordbox \
        "Asigna una contraseña segura para la nueva cuenta de usuario:" \
        "${r}" "${c}" 3>&1 1>&2 2>&3)"
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
    --backtitle "Gestión de Usuarios del Sistema" \
    --title "Selección de Usuario Local" --ok-button "Seleccionar" --cancel-button "Cancelar" \
    --separate-output
    --radiolist \
    "Selecciona la cuenta que custodiará los certificados VPN (presiona la tecla espacio para marcar):" \
    "${r}" "${c}" "${numUsers}")

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
    echo "::: Asignando subred privada aleatoria dentro del rango 10.0.0.0/8..."
    pivpnNET="$(generateRandomSubnet "10.0.0.0/8" "$subnetClass")"
  fi

  if [[ -z "${pivpnNET}" ]]; then
    echo "::: El rango 10.0.0.0/8 está saturado o en uso. Intentando con 172.16.0.0/12..."
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
        --backtitle "Configuración Inicial del Servidor"
        --title "Selección de Protocolo VPN"
        --separate-output
        --radiolist "Selecciona el motor VPN que deseas instalar en tu sistema:

• WireGuard (Recomendado): Criptografía de última generación, máxima velocidad, conexión casi instantánea y excelente ahorro de batería en móviles.
• OpenVPN: El estándar tradicional. Muy flexible, altamente compatible y recomendado si necesitas usar TCP para evadir bloqueos de red estrictos.

(Presiona la barra espaciadora para marcar tu opción):" "${r}" "${c}" 2)
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
    # CAMBIO: Se ha reestructurado el texto y la lógica de los botones para que el flujo sea más intuitivo (Sí = Confirmar lo recomendado, No = Personalizar). También se ha mejorado el formato de la lista para una lectura limpia en la terminal ()
    if whiptail \
      --backtitle "Configuración del Servidor PiVPN" \
      --title "Modo de Instalación y Parámetros" --yes-button "Aceptar y Continuar" --no-button "Personalizar" \
      --yesno "Para la mayoría de los entornos, PiVPN aplica un perfil de configuración optimizado por defecto. Se compone de los siguientes parámetros técnicos:

• Protocolo de Red: UDP (Más rápido y eficiente)
• Dominio de Búsqueda DNS: Ninguno (Por defecto)
• Nivel de Seguridad: Perfil Moderno (Certificado de 256 bits + Cifrado TLS Avanzado)

¿Deseas aplicar estos valores recomendados directamente o prefieres personalizar los detalles de la instalación?" "${r}" "${c}"; then
      # El usuario eligió "Aceptar y Continuar" -> NO quiere personalizar de forma manual
      CUSTOMIZE=0
    else
      # El usuario eligió "Personalizar" -> SÍ quiere cambiar los parámetros manuales
      CUSTOMIZE=1
    fi
  fi
}

installOpenVPN() {
  local PIVPN_DEPS gpg_path gpg_path="${pivpnFilesDir}/files/etc/apt/repo-public.gpg"
  echo "::: Instalando OpenVPN desde el paquete de Debian... "

  if [[ "${NEED_OPENVPN_REPO}" -eq 1 ]]; then
    # gnupg es usado por apt-key para importar la clave GPG de openvpn en el
    # llavero de APT
    PIVPN_DEPS=(gnupg)
    installDependentPackages PIVPN_DEPS[@]

    # Clave GPG pública del repositorio de OpenVPN
    # (huella digital 0x30EBF4E73CCE63EEE124DD278E6DA8B4E158C569)
    echo "::: Añadiendo clave del repositorio..."
    
    # CAMBIO: Definición de una ruta de llavero moderna y segura. Se prioriza /usr/share/keyrings en sistemas modernos, cayendo en /etc/apt/trusted.gpg.d si no existe para máxima compatibilidad con distribuciones antiguas ()
    local keyring_dir="/usr/share/keyrings"
    if [[ ! -d "${keyring_dir}" ]]; then
      keyring_dir="/etc/apt/trusted.gpg.d"
    fi
    local keyring_path="${keyring_dir}/openvpn-repo-keyring.gpg"

    # CAMBIO: Reemplazo del comando obsoleto apt-key add. Ahora se analiza si la clave está en formato ASCII armadura o binario y se escribe en el archivo de destino de forma segura usando gpg --dearmor si es necesario ()
    if gpg --valid-extension "${gpg_path}" &>/dev/null || file "${gpg_path}" | grep -q "gpg public public keyring" || ! grep -q "BEGIN PGP PUBLIC KEY BLOCK" "${gpg_path}"; then
      ${SUDO} cp "${gpg_path}" "${keyring_path}"
    else
      ${SUDO} gpg --dearmor < "${gpg_path}" | ${SUDO} tee "${keyring_path}" > /dev/null
    fi

    # CAMBIO: Verificación de control para asegurar que el archivo del llavero se haya creado correctamente antes de proceder con la instalación ()
    if [[ ! -f "${keyring_path}" ]]; then
      err "::: No se puede importar la clave GPG de OpenVPN"
      exit 1
    fi

    echo "::: Añadiendo repositorio de OpenVPN... "
    # CAMBIO: Modificación de la línea del repositorio para incluir el parámetro [signed-by=...] vinculando directamente la clave GPG específica al repositorio de OpenVPN, eliminando la vulnerabilidad global de apt-key ()
    echo "deb [signed-by=${keyring_path}] https://build.openvpn.net/debian/openvpn/stable ${OSCN} main" \
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
    --backtitle "Configuración de Red" \
    --title "Selección de Protocolo VPN" --ok-button "Aceptar" --cancel-button "Cancelar" \
    --radiolist "Selecciona el protocolo de transporte para tu VPN. 

• UDP (Recomendado): Ofrece la mayor velocidad y rendimiento. Es el estándar ideal para la mayoría de los usuarios.
• TCP: Recomendado únicamente si necesitas atravesar redes corporativas o cortafuegos muy restrictivos que bloquean UDP.

(Usa la barra espaciadora para seleccionar tu opción):" "${r}" "${c}" 2 \
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
        --title "Puerto inválido" --ok-button "Aceptar" \
        --msgbox "Has introducido un número de puerto inválido.
    Por favor, introduce un número entre 1 - 65535.
    Si no estás seguro, simplemente mantén el predeterminado." "${r}" "${c}"
      PORTNumCorrect=false
    else
      if whiptail \
        --backtitle "Especificar puerto personalizado" \
        --title "Confirmar número de puerto personalizado" --yes-button "Sí" --no-button "No" \
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
        --backtitle "Configurador PiVPN" \
        --title "Integración con Pi-hole" \
        --yes-button "Sí, configurar" \
        --no-button "No, gracias" \
        --yesno "Se ha detectado una instalación activa de Pi-hole. \
¿Deseas configurarlo como servidor DNS de tu VPN para disfrutar \
de bloqueo de anuncios en todos tus dispositivos?" "${r}" "${c}"; then
      setupPiholeDNS
      return
    fi
  fi

  DNSChoseCmd=(whiptail
    ---backtitle "Configurador PiVPN" \
    --title "Selección de Proveedor DNS" --ok-button "Seleccionar" --cancel-button "Cancelar" \
    --separate-output \
    --radiolist "Elige el proveedor DNS que usarán tus clientes VPN. \
(Usa la barra espaciadora para marcar tu opción).

Si deseas ingresar IPs personalizadas, selecciona 'Custom'.

NOTA PARA RESOLUTORES LOCALES:
Si ejecutas un Servidor DNS local (Pi-hole, AdGuard Home, Unbound, etc.), \
selecciona 'PiVPN-is-local-DNS'. Asegúrate de que escuche en la \
IP \"${vpnGw}\" y acepte peticiones desde \"${pivpnNET}/${subnetClass}\"." "${r}" "${c}" 6)
  DNSChooseOptions=(Google "" on
    CloudFlare "" off
    OpenDNS "" off
    Quad9 "" off
    AdGuard "" off
    FamilyShield "" off
    PiVPN-is-local-DNS "" off
    Custom "" off)

  if DNSchoices="$("${DNSChoseCmd[@]}" \
    "${DNSChooseOptions[@]}" \
    2>&1 > /dev/tty)"; then
    if [[ "${DNSchoices}" != "Custom" ]]; then
      echo "::: Usando servidores ${DNSchoices}."
      declare -A DNS_MAP=(["Google"]="8.8.8.8 8.8.4.4"
      ["CloudFlare"]="1.1.1.1 1.0.0.1"
      ["OpenDNS"]="208.67.222.222 208.67.220.220"
      ["Quad9"]="9.9.9.9 149.112.112.112"
      ["AdGuard"]="94.140.14.14 94.140.15.15"
      ["FamilyShield"]="208.67.222.123 208.67.220.123"
      ["PiVPN-is-local-DNS"]="${vpnGw}")
      pivpnDNS1=$(awk '{print $1}' <<< "${DNS_MAP["${DNSchoices}"]}")
      pivpnDNS2=$(awk '{print $2}' <<< "${DNS_MAP["${DNSchoices}"]}")
    else
      until [[ "${DNSSettingsCorrect}" == 'true' ]]; do
        strInvalid="Invalid"

        if pivpnDNS="$(whiptail \
          --backtitle "Configurador PiVPN" \
        --title "Servidores DNS Personalizados" --ok-button "Aceptar" cancel-button "Cancelar" \
        --inputbox "Introduce las direcciones IP de tus servidores DNS de subida, \
separadas por una coma.

Ejemplo: '1.1.1.1, 9.9.9.9'" "${r}" "${c}" "" \
          3>&1 1>&2 2>&3)"; then
          # Procesamiento de las IPs introducidas para extraer el primer y segundo servidor DNS, eliminando espacios y tabulaciones alrededor de las comas
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
            --backtitle "Configurador PiVPN" \
            --title "Error: IP Inválida" --ok-button "Reintentar" \
            --msgbox "Una o ambas direcciones IP introducidas no son válidas. \
Por favor, comprueba los datos e inténtalo de nuevo.

Datos detectados:
  • Servidor DNS 1: ${pivpnDNS1:-(Vacío)}
  • Servidor DNS 2: ${pivpnDNS2:-(Vacío)}" "${r}" "${c}"

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
            --title "Proveedor(es) DNS de subida" --yes-button "Sí" --no-button "No" \
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
    --backtitle "Configurador PiVPN" \
    --title "Dominio de Búsqueda Personalizado" --yes-button "Sí, añadir" --no-button "Omitir" \
    --defaultno \
    --yesno "¿Deseas configurar un sufijo de dominio de búsqueda personalizado?

[AVISO] Esta opción se recomienda solo para usuarios avanzados o entornos corporativos que dispongan de una infraestructura de dominio propia." "${r}" "${c}"; then
    until [[ "${DomainSettingsCorrect}" == 'true' ]]; do
      if pivpnSEARCHDOMAIN="$(whiptail \
        --backtitle "Configurador PiVPN" \
        --title "Dominio Personalizado" --ok-button "Continuar" --cancel-button "Cancelar" \
        --inputbox "Introduce tu sufijo de dominio personalizado.

Ejemplo: midominio.com" "${r}" "${c}" \
        --title "Dominio Personalizado" \
        3>&1 1>&2 2>&3)"; then
        if validDomain "${pivpnSEARCHDOMAIN}"; then
          if whiptail \
            ---backtitle "Configurador PiVPN" \
        --title "Confirmar Configuración" --yes-button "Confirmar" --no-button "Modificar" \
        --yesno "¿Es correcto el dominio introducido?

  • Dominio de búsqueda: ${pivpnSEARCHDOMAIN}" "${r}" "${c}"; then
            DomainSettingsCorrect=true
          else
            # Si las configuraciones son incorrectas, el bucle continúa
            DomainSettingsCorrect=false
          fi
        else
          whiptail \
            --backtitle "Configurador PiVPN" \
            --title "Error: Dominio Inválido" --ok-button "Reintentar" \
            --msgbox "El dominio introducido no tiene un formato válido. \
Por favor, comprueba la sintaxis e inténtalo de nuevo.

Texto detectado:
  • Dominio: ${pivpnSEARCHDOMAIN:-(Vacío)}" "${r}" "${c}"
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
  # 1. Obtención optimizada de la IP pública con Timeouts
  if ! IPv4pub="$(dig +short +time=3 +tries=1 myip.opendns.com @208.67.222.222 2>/dev/null)" \
    || ! validIP "${IPv4pub}"; then
    err "dig falló o devolvió una IP inválida. Probando con curl..."

    if ! IPv4pub="$(curl -sSf --connect-timeout 4 https://checkip.amazonaws.com 2>/dev/null)" \
      || ! validIP "${IPv4pub}"; then
      err "No se pudo determinar tu IP pública. Verifica tu conexión a Internet o DNS."
      exit 1
    fi
  fi

  # 2. Modo de instalación desatendida (Unattended)
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${pivpnHOST}" ]]; then
      echo "::: No se especificó HOST, usando IP pública detectada: ${IPv4pub}"
      pivpnHOST="${IPv4pub}"
    else
      if validIP "${pivpnHOST}"; then
        echo "::: Usando IP pública configurada: ${pivpnHOST}"
      elif validDomain "${pivpnHOST}"; then
        echo "::: Usando nombre de dominio configurado: ${pivpnHOST}"
      else
        err "::: '${pivpnHOST}' no es una IP o nombre de dominio válido."
        exit 1
      fi
    fi

    echo "pivpnHOST=${pivpnHOST}" >> "${tempsetupVarsFile}"
    return
  fi

  # 3. Modo Interactivo (Inicialización explícita de variables)
  local publicDNSCorrect=false
  local publicDNSValid=false

  if METH="$(whiptail \
    --backtitle "Configurador PiVPN" \
    --title "Método de Conexión" --ok-button "Seleccionar" --cancel-button "Salir" \
    --radiolist "¿Qué método usarán los clientes para conectarse a tu servidor VPN? \
(Usa la barra espaciadora para marcar tu opción)." "${r}" "${c}" 2 \
    "${IPv4pub}" "Usar esta dirección IP pública detectada" "ON" \
    "DNS Entry" "Usar un nombre de dominio (DDNS / DNS público)" "OFF" \
    3>&1 1>&2 2>&3)"; then

    if [[ "${METH}" == "${IPv4pub}" ]]; then
      pivpnHOST="${IPv4pub}"
    else
      # Bucle principal de validación del dominio personalizado
      until [[ "${publicDNSCorrect}" == 'true' ]]; do
        # Reinicio explícito del estado del bucle interno para evitar saltos lógicos
        publicDNSValid=false
        
        until [[ "${publicDNSValid}" == 'true' ]]; do
          if PUBLICDNS="$(whiptail \
            --backtitle "Configurador PiVPN" \
            --title "Configuración de Dominio" --ok-button "Continuar" --cancel-button "Cancelar" \
            --inputbox "Introduce el nombre de dominio público o DDNS para este servidor.

Ejemplo: midominio.com" "${r}" "${c}" \
            3>&1 1>&2 2>&3)"; then
            
            if validDomain "${PUBLICDNS}"; then
              publicDNSValid=true
              pivpnHOST="${PUBLICDNS}"
            else
              whiptail \
                --backtitle "Configurador PiVPN" \
                --title "Error: Dominio Inválido" --ok-button "Reintentar" \
                --msgbox "El nombre DNS introducido no tiene un formato válido. \
Por favor, comprueba la sintaxis e inténtalo de nuevo.

Texto detectado:
  • Nombre DNS: ${PUBLICDNS:-(Vacío)}" "${r}" "${c}"
              publicDNSValid=false
            fi
          else
            err "::: Cancelación seleccionada por el usuario. Saliendo..."
            exit 1
          fi
        done

        # Pantalla de confirmación final
        if whiptail \
          --backtitle "Configurador PiVPN" \
          --title "Confirmar Nombre DNS" --yes-button "Confirmar" --no-button "Modificar" \
          --yesno "¿Es correcto el dominio para tus clientes?

  • DNS Público: ${PUBLICDNS}" "${r}" "${c}"; then
          publicDNSCorrect=true
        else
          publicDNSCorrect=false
          # Al poner esto en false, obligamos a que el bucle 'until' interno vuelva a ejecutarse
          publicDNSValid=false 
        fi
      done
    fi
  else
    err "::: Cancelación seleccionada por el usuario. Saliendo..."
    exit 1
  fi

  # Guardar la variable final en el archivo de configuración
  echo "pivpnHOST=${pivpnHOST}" >> "${tempsetupVarsFile}"
}

askEncryption() {
  # Inicializamos por defecto para evitar variables vacías en el volcado final
  USE_PREDEFINED_DH_PARAM=0

  # ==========================================
  # 1. MODO DESATENDIDO (UNATTENDED)
  # ==========================================
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${TWO_POINT_FIVE}" ]] || [[ "${TWO_POINT_FIVE}" -eq 1 ]]; then
      TWO_POINT_FIVE=1
      echo "::: Usando funciones modernas de OpenVPN 2.5 (ECDSA)"

      if [[ -z "${pivpnENCRYPT}" ]]; then
        pivpnENCRYPT=256
      fi

      if [[ "${pivpnENCRYPT}" -eq 256 ]] \
        || [[ "${pivpnENCRYPT}" -eq 384 ]] \
        || [[ "${pivpnENCRYPT}" -eq 521 ]]; then
        echo "::: Usando un certificado de ${pivpnENCRYPT} bits"
      else
        err "::: ${pivpnENCRYPT} no es un tamaño de certificado ECDSA válido. Usa 256, 384 o 521."
        exit 1
      fi
    else
      TWO_POINT_FIVE=0
      echo "::: Usando configuración tradicional de OpenVPN (RSA)"

      if [[ -z "${pivpnENCRYPT}" ]]; then
        pivpnENCRYPT=2048
      fi

      if [[ "${pivpnENCRYPT}" -eq 2048 ]] \
        || [[ "${pivpnENCRYPT}" -eq 3072 ]] \
        || [[ "${pivpnENCRYPT}" -eq 4096 ]]; then
        echo "::: Usando un certificado de ${pivpnENCRYPT} bits"
      else
        err "::: ${pivpnENCRYPT} no es un tamaño de certificado RSA válido. Usa 2048, 3072 o 4096."
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

  # ==========================================
  # 2. MODO INTERACTIVO POR DEFECTO (SIN PERSONALIZAR)
  # ==========================================
  if [[ "${CUSTOMIZE}" -eq 0 ]]; then
    if [[ "${VPN}" == "openvpn" ]]; then
      TWO_POINT_FIVE=1
      pivpnENCRYPT=256
      USE_PREDEFINED_DH_PARAM=0 # Aseguramos valor por defecto limpio

      {
        echo "TWO_POINT_FIVE=${TWO_POINT_FIVE}"
        echo "pivpnENCRYPT=${pivpnENCRYPT}"
        echo "USE_PREDEFINED_DH_PARAM=${USE_PREDEFINED_DH_PARAM}"
      } >> "${tempsetupVarsFile}"
      return
    fi
  fi

  # ==========================================
  # 3. MODO INTERACTIVO PERSONALIZADO (CUSTOM)
  # ==========================================
  
  # Pantalla 1: Selección del tipo de cifrado (ECDSA vs RSA)
  whiptail \
    --backtitle "Configurador PiVPN" \
    --title "Motor de Cifrado (Curvas Elípticas vs RSA)" --yes-button "Moderno (ECDSA)" --no-button "Tradicional (RSA)" \
    --yesno "OpenVPN 2.5 permite utilizar criptografía de Curvas Elípticas (ECDSA).

• Nivel Moderno: Ofrece mayor velocidad, seguridad superior y certificados más ligeros. Además, cifra el canal de control (tls-crypt-v2) para maximizar la privacidad.
• Nivel Tradicional: Utiliza RSA. Garantiza compatibilidad total con clientes OpenVPN antiguos a costa de un rendimiento ligeramente menor.

Si tus dispositivos cliente son recientes, te recomendamos el perfil Moderno." "${r}" "${c}"
  
  crypto_choice="$?"

  # Manejo estricto de cancelación global o Esc en la primera pantalla
  if [[ "${crypto_choice}" -eq 255 ]]; then
    err "::: Instalación cancelada por el usuario. Saliendo..."
    exit 1
  fi

  if [[ "${crypto_choice}" -eq 0 ]]; then
    # --- PERFIL MODERNO (ECDSA) ---
    TWO_POINT_FIVE=1
    USE_PREDEFINED_DH_PARAM=0 # ECDSA no requiere Diffie-Hellman
    
    pivpnENCRYPT="$(whiptail \
      --backtitle "Configurador PiVPN" \
      --title "Tamaño del Certificado ECDSA" \
      --ok-button "Seleccionar" \
      --cancel-button "Cancelar" \
      --radiolist "Elige la longitud de clave para tu certificado ECDSA \
(Usa la barra espaciadora para marcar tu opción):

Nota: Una clave de 256 bits equivale en seguridad a una clave RSA de 3072 bits, \
siendo drásticamente más rápida." "${r}" "${c}" 3 \
      "256" "Certificado de 256 bits (Recomendado por rendimiento)" ON \
      "384" "Certificado de 384 bits (Seguridad avanzada)" OFF \
      "521" "Certificado de 521 bits (Máxima seguridad militar)" OFF \
      3>&1 1>&2 2>&3)"
  else
    # --- PERFIL TRADICIONAL (RSA) ---
    TWO_POINT_FIVE=0
    
    pivpnENCRYPT="$(whiptail \
      --backtitle "Configurador PiVPN" \
      --title "Tamaño del Certificado RSA" --ok-button "Seleccionar" --cancel-button "Cancelar" \
      --radiolist "Elige la longitud de clave para tu certificado RSA \
(Usa la barra espaciadora para marcar tu opción):

A mayor tamaño de clave, mayor seguridad, pero aumentará el tiempo \
de procesamiento durante la instalación." "${r}" "${c}" 3 \
      "2048" "Certificado de 2048 bits (Estándar recomendado)" ON \
      "3072" "Certificado de 3072 bits (Seguridad reforzada)" OFF \
      "4096" "Certificado de 4096 bits (Alta seguridad / Procesamiento lento)" OFF \
      3>&1 1>&2 2>&3)"
  fi

  # Validamos si el usuario canceló en cualquiera de las sublistas de radio
  if [[ $? -ne 0 ]] || [[ -z "${pivpnENCRYPT}" ]]; then
    err "::: Operación cancelada. Saliendo..."
    exit 1
  fi

  # --- CONFIGURACIÓN DIFFIE-HELLMAN (Solo aplica para RSA) ---
  if [[ "${pivpnENCRYPT}" -ge 2048 ]]; then
    if whiptail \
      --backtitle "Configurador PiVPN" \
      --title "Parámetros Diffie-Hellman" \
      --yes-button "Sí, predefinidos" \
      --no-button "No, generar nuevos" \
      --yesno "La generación local de parámetros DH puede demorar varias horas en entornos como Raspberry Pi.

¿Deseas utilizar los parámetros DH predefinidos y validados por la IETF (Recomendado)?

Si prefieres generar parámetros Diffie-Hellman únicos en este hardware, selecciona 'No'." "${r}" "${c}"; then
      USE_PREDEFINED_DH_PARAM=1
    else
      USE_PREDEFINED_DH_PARAM=0
    fi
  fi

  # Volcado limpio de variables de entorno al archivo temporal
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
  echo "::: Generando respaldo de la configuración anterior en /etc/${OPENVPN_BACKUP}..."
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
        --title "Información del Servidor" --ok-button "Aceptar" \
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
  --backtitle "Configuración de Seguridad" \
  --title "Generación de Llaves Criptográficas" --ok-button "Continuar" \
  "El instalador procederá a generar las llaves de cifrado del servidor y la firma de seguridad HMAC. 

Este proceso es automático y garantiza que tu conexión VPN sea privada y segura. Por favor, espera un momento mientras se completan las operaciones criptográficas." "${r}" "${c}"
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
      echo "::: Generando respaldo de la configuración anterior en /etc/${WIREGUARD_BACKUP}..."
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
      --title "Información del Servidor" --ok-button "Aceptar" \
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
  --backtitle "Mantenimiento y Seguridad" \
  --title "Actualizaciones de Seguridad Automáticas" --ok-button "Entendido" \
  "Para proteger tu servidor frente a vulnerabilidades, el asistente configurará el servicio 'unattended-upgrades'.

Esta herramienta permite que el sistema instale automáticamente parches de seguridad críticos de forma diaria. 

Nota importante: 
• Este proceso solo aplica actualizaciones de seguridad y nunca forzará un reinicio del sistema.
• Te recomendamos reiniciar el servidor periódicamente para asegurar que todos los parches aplicados se carguen correctamente." "${r}" "${c}"

  if whiptail \
    --backtitle "Mantenimiento y Seguridad" \
  --title "Actualizaciones de Seguridad Automáticas" \
  --yes-button "Habilitar (Recomendado)" --no-button "Omitir" \
  --yesno "Mantener el servidor protegido es fundamental. Al habilitar esta opción, el sistema instalará diariamente, de forma desatendida y segura, los parches de seguridad críticos para tu sistema operativo.

Esta función no requiere intervención humana y ayuda a prevenir vulnerabilidades.

¿Deseas activar las actualizaciones automáticas de seguridad?" \
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
    echo -n "::: Si encuentras alguna dificultad, por favor consulta la documentación "
    echo "o abre un reporte detallado en nuestro repositorio."
    echo "::: (https://github.com/wfhgdev/pivpn_spanish)"
    echo
    echo "::: Gracias por utilizar este instalador en español."
    echo "::: Se recomienda encarecidamente reiniciar después de la instalación."
    return
  fi

  # Mensaje de finalización para el usuario
  whiptail \
    --backtitle "Finalizando Instalación" \
    --title "¡Configuración Exitosa!" --ok-button "Finalizar" \
    --msgbox "¡Enhorabuena! Tu servidor VPN ya está operativo.

Comandos útiles para empezar:
• pivpn add : Crea nuevos perfiles de usuario.
• pivpn help : Consulta todos los comandos disponibles.

¿Encontraste algún problema? 
Por favor, revisa nuestra documentación oficial antes de reportar un error. Esto nos ayuda a ofrecerte un mejor soporte y a mantener la comunidad organizada.

Gracias por confiar en PiVPN Spanish." "${r}" "${c}"

  if whiptail \
    --title "Reiniciar" \
    --defaultno --yes-button "Sí" --no-button "No" \
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
