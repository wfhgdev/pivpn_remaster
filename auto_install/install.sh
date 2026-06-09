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
  # TRAZABILIDAD: Auditoría inicial del estado del parámetro de red de la máquina
  echo "::: [INFO] Verificando la conformidad del nombre de host (hostname)..."
  local host_name
  host_name="$(hostname -s)"

  # Validación de longitud o caracteres no admitidos en el estándar RFC 1123
  if [[ "${#host_name}" -gt 28 ]] || [[ ! "${host_name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]]; then
    if [[ "${runUnattended}" == 'true' ]]; then
      err "El nombre de host actual ('${host_name}') no cumple los requisitos de red o excede los 28 caracteres."
      err "Por favor, soluciónalo ejecutando manualmente: sudo hostnamectl set-hostname NOMBRE"
      exit 1
    fi

    local proposed_host="${host_name}"
    local exit_status

    # BUCLE DE VALIDACIÓN INTERACTIVA: Garantiza un formato limpio antes de aplicarlo al sistema
    while [[ "${#proposed_host}" -gt 28 ]] || [[ ! "${proposed_host}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,27}$ ]]; do
      proposed_host="$(whiptail \
        --backtitle "Asistente de Configuración PiVPN" \
        --title "Ajuste del Nombre de Host" --ok-button "Guardar" cancel-button "Cancelar" \
        --inputbox "El nombre actual de este equipo (${host_name}) excede el límite permitido o contiene caracteres no válidos para configurar la VPN. Por favor, introduce uno nuevo:

Requisitos:
• Máximo 28 caracteres de longitud.
• Solo letras, números y guiones (sin espacios ni caracteres especiales)." "${r}" "${c}" \
        3>&1 1>&2 2>&3)"
      
      exit_status=$?

      # SEGURIDAD: Si el usuario cancela el diálogo, salimos limpiamente en lugar de romper el hostname
      if [[ ${exit_status} -ne 0 ]]; then
        echo ":::"
        err "Instalación abortada por el usuario durante la reconfiguración del nombre de host."
        exit 1
      fi

      # Limpieza básica: Eliminar espacios en blanco accidentales que introduzca el usuario
      proposed_host="${proposed_host// /}"
    done

    # APLICACIÓN DE CAMBIOS: Persistencia del nuevo parámetro en el sistema operativo
    echo "::: [INFO] Aplicando el nuevo nombre de host validado: '${proposed_host}'..."
    if ${SUDO} hostnamectl set-hostname "${proposed_host}"; then
      echo "::: [INFO] Nombre de host actualizado con éxito a '${proposed_host}'."
    else
      err "Error crítico al intentar actualizar el nombre de host mediante 'hostnamectl'."
      exit 1
    fi
  else
    echo "::: [INFO] Nombre de host verificado correctamente ('${host_name}')."
  fi
}

spinner() {
  # ÁMBITO SEGURO: Aislamiento estricto de variables del indicador de carga
  local pid="${1}"
  local delay=0.50
  local spinstr='/-\|'
  local temp

  # OPTIMIZACIÓN: Uso de 'kill -0' en sustitución de la tubería pesada 'ps | awk | grep'.
  # Valida de forma nativa la existencia del PID sin bifurcar procesos (forks) en alta frecuencia.
  while kill -0 "${pid}" 2>/dev/null; do
    temp="${spinstr#?}"
    printf " [%c]  " "${spinstr}"
    spinstr="${temp}${spinstr%"${temp}"}"
    sleep "${delay}"
    printf "\b\b\b\b\b\b"
  done

  # LIMPIEZA: Remoción estética de los caracteres residuales del indicador en la consola
  printf "    \b\b\b\b"
}

verifyFreeDiskSpace() {
  # TRAZABILIDAD: Registro inicial para auditar el estado físico del almacenamiento del sistema
  echo "::: [INFO] Verificando el espacio libre en disco en el directorio raíz..."
  local required_free_kilobytes=76800
  local existing_free_kilobytes
  
  # OPTIMIZACIÓN: Se consulta directamente el volumen raíz '/' con 'df -P' para evitar 
  # la concatenación ineficiente y propensa a fallos de 'df | grep | awk'.
  existing_free_kilobytes="$(df -P / 2>/dev/null | awk 'NR==2 {print $4}')"

  # COMPROBACIÓN 1: El espacio libre en disco es desconocido o el formato no es un entero válido
  if [[ ! "${existing_free_kilobytes}" =~ ^[0-9]+$ ]]; then
    echo "::: [ADVERTENCIA] No se pudo determinar con precisión el espacio libre disponible en el almacenamiento."

    if [[ "${runUnattended}" == 'true' ]]; then
      err "Espacio libre en disco indeterminado. Abortando instalación automática en modo desatendido por seguridad."
      exit 1
    fi

    echo "::: [ADVERTENCIA] Continuar sin verificar el espacio libre puede corromper paquetes o interrumpir el despliegue."
    echo "::: Si estás seguro de que el sistema cuenta con almacenamiento libre suficiente, escribe 'YES'."
    echo -n "::: ¿Deseas forzar la continuidad de la instalación? (YES/no): "
    read -r response

    case "${response}" in
      [Yy][Ee][Ss])
        echo "::: [ADVERTENCIA] Omisión de validación de almacenamiento forzada por el administrador."
        ;;
      *)
        err "Confirmación explícita no recibida. Abortando el instalador por razones de seguridad."
        exit 1
        ;;
    esac

  # COMPROBACIÓN 2: El espacio libre disponible es inferior al umbral mínimo de contingencia (75 MB)
  elif [[ "${existing_free_kilobytes}" -lt "${required_free_kilobytes}" ]]; then
    # Conversión matemática interna nativa para enriquecer el output de diagnóstico en consola
    local req_mb=$((required_free_kilobytes / 1024))
    local ext_mb=$((existing_free_kilobytes / 1024))

    err "Espacio en disco insuficiente para garantizar una instalación estable."
    echo "::: [DETALLES] Umbral mínimo requerido: ${required_free_kilobytes} KB (~${req_mb} MB)"
    echo "::: [DETALLES] Almacenamiento disponible: ${existing_free_kilobytes} KB (~${ext_mb} MB)"
    echo "::: [AYUDA] Si estás utilizando un entorno nuevo sobre Raspberry Pi OS, expande tu partición:"
    echo ":::         Ejecuta 'sudo raspi-config' -> 'Advanced Options' -> 'Expand Filesystem'"
    echo ":::         Reinicia el dispositivo y vuelve a lanzar este asistente de instalación."
    exit 1
  fi

  # TRAZABILIDAD: Verificación exitosa del componente de almacenamiento antes de proceder a la descarga
  echo "::: [INFO] Espacio libre en disco verificado con éxito. Capacidad suficiente garantizada."
}

updatePackageCache() {
  # TRAZABILIDAD: Registro inicial homogeneizado con el sistema de trazas global
  echo "::: [INFO] Sincronizando e indexando la caché de repositorios locales..."
  
  local cache_pid
  
  # ROBUSTEZ: Detección dinámica del tipo de variable (Arreglo vs. Cadena)
  # Previene que en Debian/Ubuntu solo se ejecute el primer elemento de la matriz (apt-get)
  if [[ "$(declare -p UPDATE_PKG_CACHE 2>/dev/null)" =~ "declare -a" ]]; then
    # shellcheck disable=SC2086
    ${SUDO} "${UPDATE_PKG_CACHE[@]}" > /dev/null 2>&1 &
  else
    # shellcheck disable=SC2086
    ${SUDO} ${UPDATE_PKG_CACHE} > /dev/null 2>&1 &
  fi
  cache_pid=$!
  
  # Delegación del control visual al indicador de carga síncrono
  spinner "${cache_pid}"
  
  # ROBUSTEZ: Captura y evaluación del código de estado real del proceso en segundo plano
  wait "${cache_pid}"
  if [[ $? -eq 0 ]]; then
    echo "::: [ÉXITO] Caché de paquetes locales actualizada correctamente."
  else
    # No interrumpimos el flujo crítico, pero dejamos constancia clara del incidente en consola y logs
    echo "::: [ADVERTENCIA] No se pudo actualizar la caché de repositorios de forma óptima."
    echo ":::               El asistente continuará intentando resolver las dependencias de todos modos."
  fi
}

notifyPackageUpdatesAvailable() {
  # TRAZABILIDAD: Auditoría visual estructurada del estado de actualización del sistema operativo anfitrión
  echo "::: [INFO] Consultando la disponibilidad de actualizaciones de software pendientes..."
  
  local updatesToInstall
  # Redirección segura de stderr para evitar rupturas visuales si el gestor está bloqueado temporalmente
  updatesToInstall="$(eval "${PKG_COUNT}" 2>/dev/null)"
  
  # SANITIZACIÓN: Validar mediante expresión regular si la salida es un entero matemático puro
  if [[ ! "${updatesToInstall}" =~ ^[0-9]+$ ]]; then
    echo "::: [ADVERTENCIA] No se pudo determinar con precisión el volumen de actualizaciones pendientes."
    return
  fi

  # EVALUACIÓN DE ENTORNO: Enrutamiento de mensajes formateados según la densidad de parches requeridos
  if [[ "${updatesToInstall}" -eq 0 ]]; then
    echo "::: [INFO] El sistema operativo base se encuentra totalmente al día. Continuando..."
  else
    echo "::: [ADVERTENCIA] Se han detectado ${updatesToInstall} actualizaciones de paquetes disponibles en este sistema."
    echo "::: [RECOMENDACIÓN] Para preservar la seguridad y estabilidad de la red, se aconseja encarecidamente"
    echo ":::                 aplicar los parches pendientes del sistema operativo una vez concluido este despliegue."
  fi
}

preconfigurePackages() {
  # TRAZABILIDAD: Registro de inicio unificado para la fase de preconfiguración
  echo "::: [INFO] Iniciando la validación del entorno de empaquetado y dependencias..."
  
  local INSTALLED_APT DPKG_ARCH AVAILABLE_OPENVPN AVAILABLE_WIREGUARD down_dir

  # COMPROBACIÓN: Soporte HTTPS para gestores de paquetes antiguos (Apt < 1.5)
  if [[ "${PKG_MANAGER}" == 'apt-get' ]] && [[ -f /etc/apt/sources.list ]]; then
    # Inmunidad a localización: extrae la versión directamente de la base de datos de dpkg
    INSTALLED_APT="$(dpkg-query -W -f='${Version}' apt 2>/dev/null)"

    if [[ -n "${INSTALLED_APT}" ]] && dpkg --compare-versions "${INSTALLED_APT}" lt 1.5; then
      echo "::: [INFO] Versión de apt antigua detectada. Añadiendo soporte para repositorios HTTPS..."
      BASE_DEPS+=("apt-transport-https")
    fi
  fi

  # CONFIGURACIÓN: Evaluación de soporte de asignación de direccionamiento estático
  if checkStaticIpSupported; then
    echo "::: [INFO] Validando la suite de gestión de redes del sistema anfitrión..."
    if [[ "${OSCN}" == "bullseye" ]]; then
      BASE_DEPS+=(dhcpcd5)
    else
      useNetworkManager=true
    fi
  fi

  # ARQUITECTURA: Identificación de la firma de compilación binaria del sistema
  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    DPKG_ARCH="$(dpkg --print-architecture)"
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    DPKG_ARCH="$(apk --print-arch)"
  fi

  # DETECCIÓN OPENVPN: Consulta optimizada de candidatos de instalación en repositorios
  echo "::: [INFO] Comprobando disponibilidad de paquetes oficiales para OpenVPN..."
  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    AVAILABLE_OPENVPN="$(apt-cache policy openvpn 2>/dev/null | awk '/Candidate:/ && !/\(none\)/ {print $2}')"
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    AVAILABLE_OPENVPN="$(apk search -e openvpn 2>/dev/null | sed -E -e 's/openvpn\-(.*)/\1/')"
  fi

  OPENVPN_SUPPORT=0
  NEED_OPENVPN_REPO=0

  # LÓGICA DE COMPATIBILIDAD: Requerimiento mínimo de OpenVPN 2.5 (Soporte ECC / tls-crypt-v2)
  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    if [[ -n "${AVAILABLE_OPENVPN}" ]] && dpkg --compare-versions "${AVAILABLE_OPENVPN}" ge 2.5; then
      OPENVPN_SUPPORT=1
    else
      # Inyección de repositorio oficial de OpenVPN para arquitecturas x86 compatibles
      if [[ "${PLAT}" == "Debian" ]] || [[ "${PLAT}" == "Ubuntu" ]]; then
        if [[ "${DPKG_ARCH}" == "amd64" ]] || [[ "${DPKG_ARCH}" == "i386" ]]; then
          echo "::: [INFO] Habilitando repositorio externo oficial de OpenVPN para obtener rama 2.5+..."
          NEED_OPENVPN_REPO=1
          OPENVPN_SUPPORT=1
        fi
      fi
    fi
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    if [[ -n "${AVAILABLE_OPENVPN}" ]] && [[ "$(apk version -t "${AVAILABLE_OPENVPN}" 2.5)" == '>' ]]; then
      OPENVPN_SUPPORT=1
    fi
  fi

  # DETECCIÓN WIREGUARD: Consulta de candidatos disponibles en los repositorios locales
  echo "::: [INFO] Comprobando disponibilidad de paquetes oficiales para WireGuard..."
  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    AVAILABLE_WIREGUARD="$(apt-cache policy wireguard 2>/dev/null | awk '/Candidate:/ && !/\(none\)/ {print $2}')"
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    AVAILABLE_WIREGUARD="$(apk search -e wireguard-tools 2>/dev/null | sed -E -e 's/wireguard\-tools\-(.*)/\1/')"
  fi

  WIREGUARD_SUPPORT=0
  WIREGUARD_BUILTIN=0

  # NÚCLEO: Verificación de la presencia del módulo de WireGuard integrado en el kernel (LXC/Anfitrión)
  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    if dpkg-query -S '/lib/modules/*/wireguard.ko*' &> /dev/null \
      || dpkg-query -S '/usr/lib/modules/*/wireguard.ko*' &> /dev/null \
      || modinfo wireguard 2> /dev/null | grep -q '^filename:[[:blank:]]*(builtin)$' \
      || lsmod | grep -q '^wireguard'; then
      WIREGUARD_BUILTIN=1
      echo "::: [INFO] Módulo WireGuard integrado o cargado en el kernel detectado."
    fi
  fi

  # EVALUACIÓN MATRIZ WIREGUARD: Validación extendida multi-distribución (Incluye soporte arm64 moderno)
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

  # SEGURIDAD CRÍTICA: Abortar si ningún motor VPN es viable en este entorno operativo
  if [[ "${OPENVPN_SUPPORT}" -eq 0 ]] && [[ "${WIREGUARD_SUPPORT}" -eq 0 ]]; then
    err "Ni OpenVPN ni WireGuard se encuentran disponibles para su instalación en este sistema."
    exit 1
  fi

  # CORTAFUEGOS: Evaluación de persistencia e integración con el framework UFW
  echo "::: [INFO] Evaluando la presencia y el estado del cortafuegos (UFW)..."
  if ${SUDO} bash -c 'command -v ufw' > /dev/null; then
    if ! ${SUDO} ufw status || ${SUDO} ufw status | grep -q inactive; then
      USING_UFW=0
    else
      USING_UFW=1
      echo "::: [INFO] FireWall UFW activo detectado. La configuración de reglas se adaptará de forma automática."
    fi
  else
    USING_UFW=0
  fi

  # DEBCONF: Automatización desatendida para confirmaciones del paquete iptables-persistent
  if [[ "${PKG_MANAGER}" == 'apt-get' ]] && [[ "${USING_UFW}" -eq 0 ]]; then
    echo "::: [INFO] Inyectando directivas de automatización desatendida para iptables-persistent..."
    BASE_DEPS+=(iptables-persistent)
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | ${SUDO} debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean false | ${SUDO} debconf-set-selections
  fi

  # COMPILACIÓN ESPECÍFICA (Alpine Linux): Despliegue e instalación manual de grepcidr
  if [[ "${PLAT}" == 'Alpine' ]] && ! command -v grepcidr &> /dev/null; then
    echo "::: [INFO] Compilando grepcidr desde el origen para compatibilidad con el entorno Alpine..."
    
    # shellcheck disable=SC2086
    ${SUDO} ${PKG_INSTALL} build-base make curl tar

    if ! down_dir="$(mktemp -d)"; then
      err "Fallo crítico al inicializar el directorio temporal de compilación para grepcidr."
      exit 1
    fi

    # Descarga e infraestructura de construcción en subproceso aislado
    if curl -fLo "${down_dir}/master.tar.gz" "https://github.com/pivpn/grepcidr/archive/master.tar.gz"; then
      tar -xzC "${down_dir}" -f "${down_dir}/master.tar.gz"
      (
        cd "${down_dir}/grepcidr-master" || exit 1
        
        # Ajuste de rutas estándar en el Makefile de compilación
        sed -i -E -e 's/^PREFIX\=.*/PREFIX\=\/usr\nCC\=gcc/' Makefile
        
        make && ${SUDO} make install

        if ! command -v grepcidr &> /dev/null; then
          err "El proceso de compilación nativa finalizó pero 'grepcidr' no responde en el PATH."
          exit 1
        fi
      ) || exit 1
    else
      err "Fallo al descargar el archivo de código fuente comprimido de grepcidr."
      exit 1
    fi
  fi

  # PERSISTENCIA: Almacenamiento del estado del cortafuegos en variables temporales de instalación
  echo "USING_UFW=${USING_UFW}" >> "${tempsetupVarsFile}"
  echo "::: [ÉXITO] Análisis del entorno y preconfiguración de paquetes completada."
}

installDependentPackages() {
  # ==============================================================================
  #       INSTALACIÓN CONTROLADA DE DEPENDENCIAS DEL SISTEMA (SIN SPINNER)
  # ==============================================================================
  # Nota técnica: Se prescinde del indicador de carga (spinner) en este bloque debido
  # a conflictos de concurrencia y flujo con la directiva estricta 'set -e'.
  
  local FAILED=0
  local APTLOGFILE
  local is_installed
  local i
  declare -a TO_INSTALL=()
  declare -a argArray1=("${!1}")

  echo ":::"
  echo "::: [INFO] Iniciando el análisis y validación de las dependencias requeridas..."

  # ------------------------------------------------------------------------------
  # FASE 1: EVALUACIÓN DE PAQUETES PREEXISTENTES
  # ------------------------------------------------------------------------------
  for i in "${argArray1[@]}"; do
    is_installed=false

    if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
      if dpkg-query -W -f='${Status}' "${i}" 2> /dev/null | grep -q "ok installed"; then
        is_installed=true
      fi
    elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
      if eval "${SUDO} ${CHECK_PKG_INSTALLED} ${i}" &> /dev/null; then
        is_installed=true
      fi
    fi

    if ${is_installed}; then
      echo "::: [INFO] Dependencia: ${i} -> [✓ DETECTADA] (Ya se encuentra instalada)."
    else
      echo "::: [INFO] Dependencia: ${i} -> [✗ NO DETECTADA] (Marcada para instalación)."
      TO_INSTALL+=("${i}")
    fi
  done

  # Cláusula de guarda: Si todas las dependencias están resueltas, finalizar limpiamente
  if [[ "${#TO_INSTALL[@]}" -eq 0 ]]; then
    echo "::: [ÉXITO] Todas las dependencias ya están totalmente satisfechas. No se requieren cambios."
    return 0
  fi

  # ------------------------------------------------------------------------------
  # FASE 2: PROCESO DE INSTALACIÓN Y CAPTURA DE LOGS
  # ------------------------------------------------------------------------------
  echo ":::"
  echo "::: [INFO] Procediendo a instalar las dependencias faltantes: ${TO_INSTALL[*]}"
  
  # Creación segura del archivo temporal para el registro de trazas
  APTLOGFILE="$(${SUDO} mktemp)"
  
  # SOLUCIÓN DE BUG CRÍTICO: Se separa la ejecución por gestor de paquetes. 
  # Para 'apt-get', PKG_INSTALL es un arreglo nativo y expandirlo como cadena simple 
  # omitía los parámetros esenciales (--yes --no-install-recommends install).
  # Además, se redirige el flujo (stdout/stderr) para que el archivo de log no quede vacío.
  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    ${SUDO} "${PKG_INSTALL[@]}" "${TO_INSTALL[@]}" > "${APTLOGFILE}" 2>&1
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    # shellcheck disable=SC2086
    ${SUDO} ${PKG_INSTALL} "${TO_INSTALL[@]}" > "${APTLOGFILE}" 2>&1
  fi

  # ------------------------------------------------------------------------------
  # FASE 3: VERIFICACIÓN POST-INSTALACIÓN Y AUDITORÍA
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Verificando el resultado de las operaciones..."
  for i in "${TO_INSTALL[@]}"; do
    is_installed=false

    if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
      if dpkg-query -W -f='${Status}' "${i}" 2> /dev/null | grep -q "ok installed"; then
        is_installed=true
      fi
    elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
      if eval "${SUDO} ${CHECK_PKG_INSTALLED} ${i}" &> /dev/null; then
        is_installed=true
      fi
    fi

    if ${is_installed}; then
      echo "::: [ÉXITO] -> El paquete '${i}' se ha instalado correctamente."
      # Registro dinámico en la lista global para evitar purgar utilidades del usuario al desinstalar
      INSTALLED_PACKAGES+=("${i}")
    else
      echo "::: [ERROR] -> ¡Fallo crítico al intentar instalar el paquete '${i}'!" >&2
      ((FAILED++))
    fi
  done

  # ------------------------------------------------------------------------------
  # FASE 4: CONTROL DE ERRORES Y LIMPIEZA DE RESIDUOS (GARBAGE COLLECTION)
  # ------------------------------------------------------------------------------
  if [[ "${FAILED}" -gt 0 ]]; then
    echo ":::" >&2
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] [ERROR CRÍTICO]: Falló la instalación de dependencias del sistema." >&2
    echo "::: [DETALLE DEL LOG DEL GESTOR DE PAQUETES]:" >&2
    ${SUDO} cat "${APTLOGFILE}" >&2
    
    # Saneamiento preventivo de archivos temporales propiedad de root antes de abortar
    ${SUDO} rm -f "${APTLOGFILE}"
    exit 1
  fi

  # Saneamiento del entorno en caso de éxito
  ${SUDO} rm -f "${APTLOGFILE}"
  echo "::: [ÉXITO] Despliegue y validación de dependencias finalizado sin incidencias."
}

welcomeDialogs() {
  # ------------------------------------------------------------------------------
  # CASO 1: ENTRADA EN MODO DESATENDIDO / AUTOMATIZADO
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: [INFO] Modo desatendido activo. Iniciando el instalador automatizado de PiVPN..."
    echo "::: [INFO] Transformando el entorno local '${PLAT}' en un servidor VPN seguro..."
    echo "::: [INFO] Inicializando la evaluación de interfaces de red..."
    return
  fi

  # ------------------------------------------------------------------------------
  # CASO 2: ENTRADA EN MODO INTERACTIVO (INTERFAZ WHIPTAIL)
  # ------------------------------------------------------------------------------
  # TRAZABILIDAD: Registro de auditoría previo al lanzamiento de la interfaz gráfica
  echo "::: [INFO] Abriendo el cuadro de diálogo de bienvenida en la terminal..."

  # DIÁLOGO: Presentación formal del asistente interactivo traducido al español
  whiptail \
    --backtitle "Asistente de Instalación PiVPN" \
    --title "Bienvenido a PiVPN en Español" --ok-button "Comenzar" \
    --msgbox "Este asistente interactivo simplificará la instalación y gestión de tu servidor VPN (WireGuard o OpenVPN).

PiVPN automatiza las configuraciones complejas de red y seguridad, permitiéndote desplegar un servidor seguro en cuestión de minutos, ideal tanto para Raspberry Pi como para servidores locales o virtuales basados en Debian y Ubuntu." "${r}" "${c}"

  # TRAZABILIDAD: Confirmación de paso a la sección de requisitos de red
  echo "::: [INFO] El usuario ha iniciado el asistente interactivo. Evaluando prerrequisitos..."

  # DIÁLOGO: Explicación de la importancia de la persistencia de direccionamiento IP
  whiptail \
    --backtitle "Configuración de Red Local" \
    --title "Requisito: Dirección IP Fija (Estática)" --ok-button "Aceptar" \
    --msgbox "Para que tus dispositivos puedan conectarse de forma remota, este servidor necesita una dirección IP local fija que no cambie con el tiempo.

A continuación, evaluaremos tu conexión de red actual. Podrás elegir mantener los parámetros que ya tienes asignados por DHCP o editarlos manualmente si lo consideras necesario." "${r}" "${c}"

  # TRAZABILIDAD: Confirmación final para dar paso al análisis de adaptadores físicos
  echo "::: [INFO] Explicación de IP estática aceptada por el usuario. Pasando al módulo de red."
}


chooseInterface() {
  # ==============================================================================
  #       DETECCIÓN Y ASIGNACIÓN DE INTERFACES DE RED (IPv4 / IPv6)
  # ==============================================================================
  
  local interfacesArray=()
  local interfaceCount=0
  local chooseInterfaceCmd
  local chooseInterfaceOptions
  local firstloop=1
  local availableInterfaces
  local line
  local mode
  local desiredInterface

  echo "::: [INFO] Iniciando el análisis de los adaptadores de red instalados..."

  # OPTIMIZACIÓN: Se unifica la extracción, filtrado y formateo usando un único 
  # proceso 'awk'. Esto elimina la sobrecarga de múltiples forks de 'cut' y 'grep'.
  if [[ "${showUnsupportedNICs}" == 'true' ]]; then
    # Evalúa todas las interfaces del sistema excepto bucles locales y docker
    availableInterfaces="$(ip -o link | awk '{ sub(/:$/, "", $2); split($2, a, "@"); if (a[1] != "lo" && a[1] !~ /^docker/) print a[1] }')"
  else
    # Filtra únicamente los adaptadores cuyo estado operativo actual sea 'UP'
    availableInterfaces="$(ip -o link | awk '/state UP/ { sub(/:$/, "", $2); split($2, a, "@"); if (a[1] != "lo" && a[1] !~ /^docker/) print a[1] }')"
  fi

  # VALIDACIÓN: Detener el proceso si no se localiza infraestructura de red apta
  if [[ -z "${availableInterfaces}" ]]; then
    err "No se detectó ninguna interfaz de red activa o compatible en este entorno."
    exit 1
  fi

  # Construcción del vector de opciones estructurado para la interfaz de Whiptail
  while read -r line; do
    [[ -z "${line}" ]] && continue
    mode="OFF"

    if [[ "${firstloop}" -eq 1 ]]; then
      firstloop=0
      mode="ON"  # Preselecciona la primera interfaz de la lista de forma activa
    fi

    interfacesArray+=("${line}" "Disponible" "${mode}")
    ((interfaceCount++))
  done <<< "${availableInterfaces}"

  # ------------------------------------------------------------------------------
  # FLUJO A: GESTIÓN EN MODO DESATENDIDO / AUTOMATIZADO
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: [INFO] Modo desatendido detectado. Procesando reglas de auto-asignación..."

    # Evaluación y validación del adaptador para IPv4
    if [[ -z "${IPv4dev}" ]]; then
      if [[ "${interfaceCount}" -eq 1 ]]; then
        IPv4dev="${availableInterfaces}"
        echo "::: [INFO] Interfaz IPv4 omitida en la configuración. Asignando la única disponible: ${IPv4dev}"
      else
        err "No se especificó la interfaz IPv4 y existen múltiples adaptadores en el sistema."
        exit 1
      fi
    else
      if ip -o link | grep -qw "${IPv4dev}"; then
        echo "::: [INFO] Interfaz IPv4 validada correctamente: ${IPv4dev}"
      else
        err "La interfaz IPv4 preconfigurada (${IPv4dev}) no existe o no está disponible."
        exit 1
      fi
    fi

    # Evaluación y validación del adaptador para IPv6 (Si está habilitado)
    if [[ "${pivpnenableipv6}" -eq 1 ]]; then
      if [[ -z "${IPv6dev}" ]]; then
        if [[ "${interfaceCount}" -eq 1 ]]; then
          IPv6dev="${availableInterfaces}"
          echo "::: [INFO] Interfaz IPv6 omitida en la configuración. Asignando la única disponible: ${IPv6dev}"
        else
          err "No se especificó la interfaz IPv6 y existen múltiples adaptadores en el sistema."
          exit 1
        fi
      else
        if ip -o link | grep -qw "${IPv6dev}"; then
          echo "::: [INFO] Interfaz IPv6 validada correctamente: ${IPv6dev}"
        else
          err "La interfaz IPv6 preconfigurada (${IPv6dev}) no existe o no está disponible."
          exit 1
        fi
      fi
    fi

    # Persistencia de variables en el entorno temporal de instalación
    {
      echo "IPv4dev=${IPv4dev}"
      if [[ "${pivpnenableipv6}" -eq 1 ]] && [[ -n "${IPv6dev}" ]]; then
        echo "IPv6dev=${IPv6dev}"
      fi
    } >> "${tempsetupVarsFile}"

    echo "::: [ÉXITO] Mapeo automático de adaptadores completado."
    return
  fi

  # ------------------------------------------------------------------------------
  # FLUJO B: CLÁUSULA DE INTERFAZ ÚNICA (AHORRO DE DIÁLOGOS INTERACTIVOS)
  # ------------------------------------------------------------------------------
  if [[ "${interfaceCount}" -eq 1 ]]; then
    IPv4dev="${availableInterfaces}"
    echo "::: [INFO] Solo se localizó un adaptador activo (${IPv4dev}). Omitiendo selección manual."

    {
      echo "IPv4dev=${IPv4dev}"
      if [[ "${pivpnenableipv6}" -eq 1 ]]; then
        IPv6dev="${availableInterfaces}"
        echo "IPv6dev=${IPv6dev}"
      fi
    } >> "${tempsetupVarsFile}"
    return
  fi

  # ------------------------------------------------------------------------------
  # FLUJO C: ASISTENTE INTERACTIVO (SELECCIÓN MULTI-INTERFAZ)
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Abriendo el cuadro de diálogo para la selección manual de interfaces..."

  # INTERFAZ INTERACTIVA: Selección del dispositivo de red para IPv4
  chooseInterfaceCmd=(whiptail
    --separate-output
    --backtitle "Configuración de Interfaces de Red"
    --title "Selección de Interfaz IPv4"
    --ok-button "Aceptar"
    --cancel-button "Cancelar"
    --radiolist "Por favor, elija el adaptador de red principal que utilizará el servidor para el tráfico IPv4\n(Presione ESPACIO para marcar su opción y ENTER para continuar):" 
    "${r}" "${c}" "${interfaceCount}")

  if chooseInterfaceOptions="$("${chooseInterfaceCmd[@]}" "${interfacesArray[@]}" 2>&1 > /dev/tty)"; then
    for desiredInterface in ${chooseInterfaceOptions}; do
      IPv4dev="${desiredInterface}"
      echo "::: [INFO] Interfaz IPv4 seleccionada por el usuario: ${IPv4dev}"
      echo "IPv4dev=${IPv4dev}" >> "${tempsetupVarsFile}"
    done
  else
    err "El usuario canceló la selección de la interfaz de red. Cancelando la instalación."
    exit 1
  fi

  # INTERFAZ INTERACTIVA: Selección opcional del dispositivo de red para IPv6
  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    chooseInterfaceCmd=(whiptail
      --separate-output
      --backtitle "Configuración de Interfaces de Red"
      --title "Selección de Interfaz IPv6"
      --ok-button "Aceptar"
      --cancel-button "Cancelar"
      --radiolist "Elija el adaptador de red para el tráfico IPv6\n(Por norma general, se recomienda seleccionar el mismo dispositivo usado para IPv4):" 
      "${r}" "${c}" "${interfaceCount}")

    if chooseInterfaceOptions="$("${chooseInterfaceCmd[@]}" "${interfacesArray[@]}" 2>&1 > /dev/tty)"; then
      for desiredInterface in ${chooseInterfaceOptions}; do
        IPv6dev="${desiredInterface}"
        echo "::: [INFO] Interfaz IPv6 seleccionada por el usuario: ${IPv6dev}"
        echo "IPv6dev=${IPv6dev}" >> "${tempsetupVarsFile}"
      done
    else
      err "El usuario canceló la asignación de interfaz para IPv6. Cancelando la instalación."
      exit 1
    fi
  fi

  echo "::: [ÉXITO] Enrutamiento de adaptadores configurado y guardado correctamente."
}

checkStaticIpSupported() {
  # ==============================================================================
  #     VERIFICACIÓN DE COMPATIBILIDAD DE CONFIGURACIÓN AUTOMÁTICA DE IP
  # ==============================================================================
  # Evalúa si el sistema operativo anfitrión cuenta con soporte nativo automatizado
  # dentro del script para modificar directamente los archivos locales de red.

  echo "::: [INFO] Evaluando compatibilidad de red para el entorno de la plataforma: '${PLAT}'..."

  if [[ "${PLAT}" == "Raspbian" || "${PLAT}" == "Raspberry" ]]; then
    echo "::: [INFO] Entorno Raspberry Pi OS compatible detectado de forma directa."
    return 0
  elif [[ "${PLAT}" == "Debian" ]] \
    && [[ -s /etc/apt/sources.list.d/raspi.list || -s /etc/apt/sources.list.d/raspi.sources ]]; then
    echo "::: [INFO] Sistema operativo Debian con repositorios de entorno Raspberry detectado."
    return 0
  else
    echo "::: [AVISO] La plataforma actual '${PLAT}' no admite asignación automatizada de IP estática local."
    return 1
  fi
}

staticIpNotSupported() {
  # ==============================================================================
  #     MANEJO DE EXCEPCIÓN: ENTIDAD DE RED NO COMPATIBLE LOCALMENTE
  # ==============================================================================
  
  # Gestión de salida limpia en caso de ejecuciones automatizadas de fondo
  if [[ "${AUTOMATED_INSTALL}" -eq 1 || "${runUnattended}" == 'true' ]]; then
    echo "::: [AVISO] El instalador omitirá la gestión automática de direccionamiento de red."
    echo "::: [AVISO] Razón: El sistema operativo anfitrión requiere aprovisionamiento externo de IP."
    return
  fi

  # TRAZABILIDAD: Despliegue de advertencia interactiva
  echo "::: [INFO] Lanzando advertencia en pantalla sobre la gestión independiente de IP estática..."

  # DIÁLOGO INTERACTIVO WHIPTAIL (Botones adaptados al español)
  whiptail \
    --backtitle "Asistente de Configuración de Red - PiVPN" \
    --title "Aviso Importante: Dirección IP Estática" \
    --ok-button "Entendido y Continuar" \
    --msgbox "Este instalador automático solo gestiona la IP estática de forma local en sistemas basados en Raspberry Pi OS.

Buenas prácticas recomendadas según tu entorno:
• Servidores en la Nube (AWS, Oracle, Proxmox remotos): Tu proveedor asigna la IP interna mediante su propia infraestructura de red. No modifiques la configuración local.
• Servidores Locales (Ubuntu Server, Debian o Máquinas Virtuales): Se recomienda fijar la IP configurando una 'Reserva DHCP' vinculada a la MAC en tu router o gateway.

Si prefieres forzar una IP fija en este sistema operativo más adelante, recuerda editar Netplan (/etc/netplan/) o /etc/network/interfaces antes de pasar el servidor a producción." "${r}" "${c}"

  echo "::: [INFO] Confirmación de aviso de red registrada por el usuario."
}

validIP() {
  # ==============================================================================
  #                      VALIDACIÓN ESTÁNDAR DE DIRECCIÓN IPv4
  # ==============================================================================
  # Optimización: Se utiliza BASH_REMATCH para capturar los octetos directamente.
  # Esto elimina la manipulación de la variable interna IFS y acelera la comprobación.
  
  local ip_str="${1}"
  local -a octets

  # Expresión regular estricta para formato de 4 octetos delimitados por puntos
  if [[ "${ip_str}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    # Extraer los bloques capturados por la expresión regular
    octets=("${BASH_REMATCH[@]:1:4}")

    # Evaluación aritmética de rangos válidos de red (0 a 255 por octeto)
    if (( octets[0] <= 255 && octets[1] <= 255 && octets[2] <= 255 && octets[3] <= 255 )); then
      return 0
    fi
  fi

  return 1
}

validIPAndNetmask() {
  # ==============================================================================
  #               VALIDACIÓN DE DIRECCIÓN IPv4 BAJO NOTACIÓN CIDR
  # ==============================================================================
  # Solución de Bugs de Diseño: Se segmentan las variables en tipos string y array
  # independientes, resolviendo de forma limpia las alertas ShellCheck SC2178 y SC2128.

  local cidr_str="${1}"
  # Normalizar la cadena sustituyendo la barra oblicua '/' por un punto '.' para unificar la regex
  local normalized="${cidr_str/\//.}"
  local -a parts

  # Expresión regular para validar 4 octetos tradicionales + 1 prefijo de subred CIDR
  if [[ "${normalized}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,2})$ ]]; then
    parts=("${BASH_REMATCH[@]:1:5}")

    # Validación matemática: Octetos <= 255 y máscara de subred IPv4 <= 32 bits
    if (( parts[0] <= 255 && parts[1] <= 255 && parts[2] <= 255 && parts[3] <= 255 && parts[4] <= 32 )); then
      return 0
    fi
  fi

  return 1
}

checkipv6uplink() {
  # ==============================================================================
  #         COMPROBACIÓN DE ENLACE ASCENDENTE IPv6 (UPLINK TEST)
  # ==============================================================================
  # Realiza una petición controlada para determinar si la red local cuenta con
  # conectividad IPv6 real hacia el exterior antes de habilitar su configuración.

  local curlv6testres

  echo "::: [INFO] Comprobando la conectividad de red externa para IPv6..."

  # Ejecución de sondeo IPv6 hacia un dominio de alta disponibilidad con tiempos límite estrictos
  curl \
    --max-time 3 \
    --connect-timeout 3 \
    --silent \
    -6 \
    https://google.com \
    > /dev/null 2>&1
  curlv6testres="$?"

  if [[ "${curlv6testres}" -ne 0 ]]; then
    echo "::: [AVISO] La prueba de enlace ascendente IPv6 ha fallado (Código de error curl: ${curlv6testres})."
    echo "::: [AVISO] Deshabilitando el soporte de direccionamiento IPv6 para este despliegue."
    pivpnenableipv6=0
  else
    echo "::: [ÉXITO] Conexión de prueba IPv6 realizada correctamente. El host cuenta con salida IPv6 activa."
    echo "::: [INFO] Habilitando el soporte de IPv6 en la configuración base del servidor."
    pivpnenableipv6=1
  fi
}

askforcedipv6route() {
  # ==============================================================================
  #         CONFIGURACIÓN DE ENRUTAMIENTO FORZADO IPv6 (PREVENCIÓN DE FUGAS)
  # ==============================================================================
  # Previene el "IPv6 Leak" en entornos donde el servidor carece de IPv6 pero los
  # clientes operan en redes dual-stack (móviles/hogar) que sí lo utilizan.

  # ------------------------------------------------------------------------------
  # CASO 1: ENTRADA EN MODO DESATENDIDO / AUTOMATIZADO
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: [INFO] Modo desatendido activo. Aplicando directiva de enrutamiento IPv6 forzado..."
    echo "::: [INFO] Estado de ruta IPv6 forzada asignado (pivpnforceipv6route): ${pivpnforceipv6route}"
    echo "pivpnforceipv6route=${pivpnforceipv6route}" >> "${tempsetupVarsFile}"
    return
  fi

  # ------------------------------------------------------------------------------
  # CASO 2: ASISTENTE INTERACTIVO (INTERFAZ WHIPTAIL)
  # ------------------------------------------------------------------------------
  # TRAZABILIDAD: Registro de auditoría previo al despliegue del cuadro de diálogo
  echo "::: [INFO] Abriendo cuadro de diálogo interactivo: Mitigación de fugas IPv6..."

  if whiptail \
    --backtitle "Configuración de Privacidad y Seguridad - PiVPN" \
    --title "Prevención de Fugas IPv6 (IPv6 Leak)" \
    --yes-button "Sí, activar protección" \
    --no-button "No, omitir protección" \
    --yesno "Este servidor no dispone de una conexión IPv6 activa hacia internet. Sin embargo, los dispositivos remotos que se conecten a tu VPN (móviles, portátiles) podrían estar navegando desde redes locales externas que sí utilicen IPv6 de forma nativa.\n\nSi dejas esta opción desactivada, el tráfico IPv6 de tus clientes podría 'fugarse' fuera del túnel cifrado y seguro de la VPN, exponiendo su IP pública real al navegar por ciertos sitios web.\n\nPara mitigar este riesgo, se recomienda forzar una ruta IPv6 ficticia dentro del túnel. Esto bloqueará eficazmente las fugas de datos y blindará la privacidad de la conexión, aunque en redes móviles muy específicas podría generar una leve latencia al resolver dominios.\n\n¿Deseas activar la protección para forzar el enrutamiento IPv6?" \
    "${r}" "${c}"; then
    
    pivpnforceipv6route=1
    echo "::: [INFO] El usuario ha activado la mitigación contra fugas de IPv6 (Ruta forzada activa)."
  else
    pivpnforceipv6route=0
    echo "::: [AVISO] El usuario ha decidido no forzar el enrutamiento IPv6. Riesgo de fuga potencial activo."
  fi

  # Persistencia del parámetro y cierre de trazabilidad del módulo
  echo "pivpnforceipv6route=${pivpnforceipv6route}" >> "${tempsetupVarsFile}"
  echo "::: [ÉXITO] Parámetro de enrutamiento IPv6 salvado en el archivo de variables temporales."
}

getStaticIPv4Settings() {
  # ==============================================================================
  #       RECOPILACIÓN Y CONFIGURACIÓN DE PARÁMETROS RED IPv4 ESTÁTICA
  # ==============================================================================
  
  echo "::: [INFO] Analizando la topología de red local y resolviendo pasarelas..."

  # OPTIMIZACIÓN: Extracción de la Puerta de Enlace (Gateway) activa de forma eficiente
  CurrentIPv4gw="$(ip route get 192.0.2.1 2>/dev/null | grep -oE 'via [0-9]{1,3}(\.[0-9]{1,3}){3}' | awk '{print $2}')"
  if [[ -z "${CurrentIPv4gw}" ]]; then
    # Fallback secundario si la ruta directa no expone el tag 'via'
    CurrentIPv4gw="$(ip route show default 2>/dev/null | awk '/default via/ {print $3; exit}')"
  fi

  # OPTIMIZACIÓN: Extracción de la Dirección IP actual con su máscara en formato CIDR
  CurrentIPv4addr="$(ip -o -f inet address show dev "${IPv4dev}" 2>/dev/null | awk '/inet / {print $4; exit}')"

  # OPTIMIZACIÓN: Extracción limpia de servidores DNS activos excluyendo comentarios
  IPv4dns="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | xargs)"

  # Registrar traza con los datos obtenidos en la fase de descubrimiento
  echo "::: [INFO] Datos DHCP descubiertos -> IP: ${CurrentIPv4addr} | GW: ${CurrentIPv4gw} | DNS: ${IPv4dns}"

  # ------------------------------------------------------------------------------
  # FLUJO A: GESTIÓN EN MODO DESATENDIDO / AUTOMATIZADO
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: [INFO] Modo desatendido activo. Validando variables de red preconfiguradas..."
    
    if [[ -z "${dhcpReserv}" ]] || [[ "${dhcpReserv}" -ne 1 ]]; then
      local MISSING_STATIC_IPV4_SETTINGS=0

      if [[ -z "${IPv4addr}" ]]; then
        echo "::: [AVISO] Configuración incompleta: Falta definir la dirección 'IPv4addr'"
        ((MISSING_STATIC_IPV4_SETTINGS++))
      fi

      if [[ -z "${IPv4gw}" ]]; then
        echo "::: [AVISO] Configuración incompleta: Falta definir la puerta de enlace 'IPv4gw'"
        ((MISSING_STATIC_IPV4_SETTINGS++))
      fi

      if [[ "${MISSING_STATIC_IPV4_SETTINGS}" -eq 0 ]]; then
        # Ambas variables existen; procedemos a validar su integridad formal
        if validIPAndNetmask "${IPv4addr}"; then
          echo "::: [INFO] IPv4 estática configurada: ${IPv4addr}"
        else
          err "La dirección IPv4 desatendida (${IPv4addr}) no es válida o carece de máscara CIDR."
          exit 1
        fi

        if validIP "${IPv4gw}"; then
          echo "::: [INFO] Puerta de enlace configurada: ${IPv4gw}"
        else
          err "La puerta de enlace IPv4 desatendida (${IPv4gw}) no es una dirección IP válida."
          exit 1
        fi

      elif [[ "${MISSING_STATIC_IPV4_SETTINGS}" -eq 1 ]]; then
        err "Inconsistencia en modo desatendido: Solo se proporcionó uno de los parámetros requeridos de IP/GW."
        exit 1

      elif [[ "${MISSING_STATIC_IPV4_SETTINGS}" -eq 2 ]]; then
        # Si no se definieron parámetros, se heredan de forma segura los asignados por el DHCP actual
        IPv4addr="${CurrentIPv4addr}"
        IPv4gw="${CurrentIPv4gw}"
        echo "::: [INFO] Sin parámetros explícitos asignados. Adoptando configuración DHCP por defecto."
        echo "::: [INFO] IPv4 estática asignada: ${IPv4addr}"
        echo "::: [INFO] Puerta de enlace asignada: ${IPv4gw}"
      fi
    else
      echo "::: [INFO] Reserva DHCP activa declarada. Omitiendo reconfiguración local de IP estática."
    fi

    # Volcado y persistencia de variables en el archivo temporal de instalación
    {
      echo "dhcpReserv=${dhcpReserv}"
      echo "IPv4addr=${IPv4addr}"
      echo "IPv4gw=${IPv4gw}"
    } >> "${tempsetupVarsFile}"
    return
  fi

  # ------------------------------------------------------------------------------
  # FLUJO B: ASISTENTE INTERACTIVO (GRAFICO - WHIPTAIL)
  # ------------------------------------------------------------------------------
  local ipSettingsCorrect=false
  local IPv4AddrValid=false
  local IPv4gwValid=false

  echo "::: [INFO] Lanzando consulta interactiva sobre el método de asignación de direccionamiento..."

  # INTERFAZ INTERACTIVA: Selección del Tipo de Direccionamiento (DHCP permanente vs Local)
  if whiptail \
    --backtitle "Asistente de Configuración de Red - PiVPN" \
    --title "Método de Asignación de IP" \
    --yes-button "Mantener DHCP (Recomendado)" \
    --no-button "Configurar Manualmente" \
    --defaultno \
    --yesno "Para garantizar la accesibilidad permanente a tu VPN, este servidor requiere una dirección IP fija.\n\nEl asistente ha detectado los siguientes parámetros activos en tu interfaz:\n  • Dirección IP:       ${CurrentIPv4addr}\n  • Puerta de enlace:   ${CurrentIPv4gw}\n\n¿Tienes esta IP ya configurada como una 'Reserva Estática' o 'Reserva DHCP' en tu enrutador?\n\n• Elige 'Mantener DHCP' si ya has vinculado la MAC de este equipo a una IP fija en tu router (Es la opción más limpia y segura).\n• Elige 'Configurar Manualmente' si prefieres forzar una IP fija de forma estática directamente en este sistema operativo." \
    "${r}" "${c}"; then
    
    # El usuario confirma que el Router se encarga de mantener la IP fija
    dhcpReserv=1
    echo "::: [INFO] El usuario optó por mantener DHCP (Se asume existencia de Reserva DHCP externa)."

    {
      echo "dhcpReserv=${dhcpReserv}"
      echo "IPv4addr=${CurrentIPv4addr}"
      echo "IPv4gw=${CurrentIPv4gw}"
    } >> "${tempsetupVarsFile}"
  else
    # El usuario desea forzar los archivos locales e independizarse del DHCP automático
    dhcpReserv=0
    echo "::: [INFO] El usuario ha optado por la reconfiguración manual / estática local."

    # INTERFAZ INTERACTIVA: Clonación de parámetros DHCP actuales como base estática
    if whiptail \
      --backtitle "Asistente de Configuración de Red - PiVPN" \
      --title "Confirmación de IP Estática" \
      --yes-button "Confirmar y Usar" \
      --no-button "Modificar Parámetros" \
      --yesno "Has elegido configurar una dirección IP estática local.\n\n¿Deseas clonar y fijar de forma definitiva los parámetros actuales del sistema o prefieres modificarlos manualmente?\n\n  • Dirección IP sugerida:   ${CurrentIPv4addr}\n  • Puerta de enlace:        ${CurrentIPv4gw}" \
      "${r}" "${c}"; then
      
      IPv4addr="${CurrentIPv4addr}"
      IPv4gw="${CurrentIPv4gw}"
      echo "::: [INFO] El usuario confirmó el uso de los parámetros de red actuales como IP fija local."

      {
        echo "IPv4addr=${IPv4addr}"
        echo "IPv4gw=${IPv4gw}"
      } >> "${tempsetupVarsFile}"

      # INTERFAZ INTERACTIVA: Alerta preventiva de riesgos por colisión / solapamiento de direccionamiento
      whiptail \
        --backtitle "Asistente de Configuración de Red - PiVPN" \
        --title "Aviso Crítico: Riesgo de Conflicto de IP" \
        --ok-button "Entendido y Mitigado" \
        --msgbox "¡Atención! Al fijar una dirección IP directamente de forma local sin avisar al router, existe la posibilidad de que el servidor DHCP de tu red asigne esta misma IP a otro dispositivo (móvil, TV, pc) en el futuro.\n\nEsto causaría un conflicto de red colapsando el acceso a tu servidor VPN.\n\nPara prevenirlo de forma permanente, asegúrate de cumplir una de estas medidas:\n1. Accede a tu router y crea una 'Reserva DHCP' para la dirección MAC de este servidor usando esta misma IP.\n2. Modifica el rango dinámico del DHCP de tu router para que tu IP estática quede excluida de las asignaciones automáticas." \
        "${r}" "${c}"
      
      echo "::: [INFO] Alerta de conflicto de direccionamiento IP leída y aceptada."
    else
      # ----------------------------------------------------------------------------
      # BUCLE DE ENTRADA MANUAL COMPLETA (IP -> GATEWAY -> VALIDACIÓN -> CONFIRMACIÓN)
      # ----------------------------------------------------------------------------
      echo "::: [INFO] Iniciando el bucle de captura manual de datos de red..."
      
      until [[ "${ipSettingsCorrect}" == 'true' ]]; do
        
        # Sub-bucle 1: Solicitar y validar Dirección IP + Máscara (Formato CIDR requerido)
        until [[ "${IPv4AddrValid}" == 'true' ]]; do
          if IPv4addr="$(whiptail \
            --backtitle "Configuración Manual de Red - PiVPN" \
            --title "Asignar Dirección IPv4 (CIDR)" \
            --ok-button "Guardar" \
            --cancel-button "Cancelar Asistente" \
            --inputbox "Introduce la dirección IPv4 local que deseas fijar de manera estática a este servidor.\n\nEs OBLIGATORIO incluir la máscara de subred en notación CIDR.\n\nEjemplo válido de red doméstica: 192.168.1.150/24\n(Donde '/24' equivale a la máscara tradicional 255.255.255.0)" \
            "${r}" "${c}" "${CurrentIPv4addr}" \
            3>&1 1>&2 2>&3)"; then
            
            if validIPAndNetmask "${IPv4addr}"; then
              echo "::: [INFO] Entrada válida de IPv4 estática: ${IPv4addr}"
              IPv4AddrValid=true
            else
              echo "::: [AVISO] Formato IPv4 inválido provisto por el usuario: ${IPv4addr}"
              whiptail \
                --backtitle "Configuración Manual de Red - PiVPN" \
                --title "Error: Formato IPv4 No Válido" \
                --ok-button "Volver a Intentar" \
                --msgbox "La dirección IP o máscara introducida no es válida: '${IPv4addr}'\n\nPor favor, verifica que cumpla con los rangos numéricos correctos (0-255) y que finalice con su prefijo CIDR correspondiente (Ej. /24, /22)." \
                "${r}" "${c}"
              IPv4AddrValid=false
            fi
          else
            err "El usuario canceló la introducción manual de la dirección IPv4. Abortando instalación."
            exit 1
          fi
        done

        # Sub-bucle 2: Solicitar y validar la Puerta de Enlace Predeterminada (Gateway / Router IP)
        until [[ "${IPv4gwValid}" == 'true' ]]; do
          if IPv4gw="$(whiptail \
            --backtitle "Configuración Manual de Red - PiVPN" \
            --title "Dirección de Puerta de Enlace (Router)" \
            --ok-button "Guardar" \
            --cancel-button "Cancelar Asistente" \
            --inputbox "Introduce la dirección IP interna correspondiente a tu puerta de enlace predeterminada (La IP de administración local de tu Router).\n\nEste parámetro NO debe llevar máscara de subred.\n\nEjemplo común: 192.168.1.1" \
            "${r}" "${c}" "${CurrentIPv4gw}" \
            3>&1 1>&2 2>&3)"; then
            
            if validIP "${IPv4gw}"; then
              echo "::: [INFO] Entrada válida de Puerta de Enlace IPv4: ${IPv4gw}"
              IPv4gwValid=true
            else
              echo "::: [AVISO] Formato de puerta de enlace inválido provisto por el usuario: ${IPv4gw}"
              whiptail \
                --backtitle "Configuración Manual de Red - PiVPN" \
                --title "Error: Puerta de Enlace No Válida" \
                --ok-button "Volver a Intentar" \
                --msgbox "La dirección de la pasarela no cumple con el estándar IPv4: '${IPv4gw}'\n\nIntroduce una IP limpia de 4 octetos sin barras ni máscaras de subred adicionales." \
                "${r}" "${c}"
              IPv4gwValid=false
            fi
          else
            err "El usuario canceló la introducción manual de la puerta de enlace. Abortando instalación."
            exit 1
          fi
        done

        # Verificación y Cierre: Presentación del balance final de datos para validación visual del administrador
        if whiptail \
          --backtitle "Configuración Manual de Red - PiVPN" \
          --title "Revisión de Parámetros de Red Escritos" \
          --yes-button "Confirmar y Aplicar" \
          --no-button "Corregir Datos" \
          --yesno "¿Confirmas que los siguientes datos estructurados son los correctos para inicializar el despliegue de interfaces?\n\n  • Dirección IPv4 fija (CIDR):  ${IPv4addr}\n  • Puerta de enlace local:     ${IPv4gw}" \
          "${r}" "${c}"; then
          
          # Persistencia final tras validación completa del bloque interactivo
          {
            echo "IPv4addr=${IPv4addr}"
            echo "IPv4gw=${IPv4gw}"
          } >> "${tempsetupVarsFile}"
          
          echo "::: [ÉXITO] Parámetros manuales de red confirmados por el usuario y guardados con éxito."
          ipSettingsCorrect=true
        else
          # El usuario detectó un error en la revisión; reiniciamos los flags para repetir las capturas
          echo "::: [AVISO] El usuario rechazó el resumen de red. Reiniciando bucle de captura manual."
          ipSettingsCorrect=false
          IPv4AddrValid=false
          IPv4gwValid=false
        fi
      done # Fin del bucle principal 'until ipSettingsCorrect'
    fi # Fin de modificación manual vs parámetros DHCP heredados
  fi # Fin de decisión Reserva DHCP vs Configuración local manual
}

setDHCPCD() {
  # ==============================================================================
  #         APLICACIÓN DE DIRECCIÓN IP ESTÁTICA VÍA SUBSISTEMA DHCPCD
  # ==============================================================================
  # Valida la existencia del archivo de configuración global de dhcpcd y añade
  # las directivas estáticas correspondientes si no se encuentran ya registradas.

  echo "::: [INFO] Configurando direccionamiento estático mediante el demonio dhcpcd..."

  if [[ -f "${dhcpcdFile}" ]]; then
    # Evitar duplicaciones redundantes inspeccionando el archivo de configuración
    if grep -q "${IPv4addr}" "${dhcpcdFile}"; then
      echo "::: [INFO] La dirección IP estática ya se encuentra registrada en: ${dhcpcdFile}."
    else
      echo "::: [INFO] Escribiendo nuevas directivas de red en '${dhcpcdFile}'..."
      writeDHCPCDConf

      echo "::: [INFO] Intentando actualizar dinámicamente la IP en la interfaz '${IPv4dev}'..."
      if ${SUDO} ip addr replace dev "${IPv4dev}" "${IPv4addr}"; then
        echo "::: [ÉXITO] Dirección IP local reemplazada en caliente correctamente a ${IPv4addr}."
        echo "::: [AVISO] Nota: Se recomienda realizar un reinicio limpio al finalizar la instalación."
      else
        echo "::: [AVISO] No se pudo aplicar el cambio en caliente. La nueva IP se asentará tras el reinicio."
      fi
    fi
  else
    err "Error crítico: No se localizó el archivo de configuración de red esperado en '${dhcpcdFile}'."
    exit 1
  fi
}

writeDHCPCDConf() {
  # ==============================================================================
  #         ESCRITURA ATÓMICA DE PARÁMETROS EN EL ARCHIVO DHCPCD.CONF
  # ==============================================================================
  # Vuelca las directivas estructuradas de red local mediante elevación de privilegios.

  {
    echo "interface ${IPv4dev}"
    echo "static ip_address=${IPv4addr}"
    echo "static routers=${IPv4gw}"
    echo "static domain_name_servers=${IPv4dns}"
  } | ${SUDO} tee -a "${dhcpcdFile}" > /dev/null

  if [[ "${PIPESTATUS[1]}" -ne 0 ]]; then
    err "Error grave: Falló la escritura persistente en el archivo '${dhcpcdFile}'."
    exit 1
  fi
}

setNetworkManager() {
  # ==============================================================================
  #       APLICACIÓN DE DIRECCIÓN IP ESTÁTICA VÍA NETWORKMANAGER (NMCLI)
  # ==============================================================================
  # Identifica de forma precisa la conexión activa vinculada al dispositivo de red
  # y conmuta su comportamiento de asignación automática (DHCP) a estático/manual.

  echo "::: [INFO] Solicitando identificador único de conexión activa para la interfaz '${IPv4dev}'..."

  # Extracción limpia del UUID de red de la conexión actualmente en uso
  local connectionUUID
  connectionUUID=$(nmcli -t con show --active | awk -v ref="${IPv4dev}" -F: 'match($0, ref){print $2}')

  # Control de Contingencia: Intento de resolución específico por mapeo de dispositivo si el flujo general falla
  if [[ -z "${connectionUUID}" ]]; then
    connectionUUID=$(nmcli -t -f DEVICE,UUID con show --active 2>/dev/null | awk -F: -v dev="${IPv4dev}" '$1==dev {print $2}')
  fi

  if [[ -z "${connectionUUID}" ]]; then
    err "No se pudo identificar una conexión activa de NetworkManager vinculada a la interfaz '${IPv4dev}'."
    exit 1
  fi

  echo "::: [INFO] Conexión activa validada (UUID: ${connectionUUID}). Modificando perfil de red..."

  # Reconfiguración manual del perfil de red mediante nmcli
  if ${SUDO} nmcli con mod "${connectionUUID}" \
    ipv4.addresses "${IPv4addr}" \
    ipv4.gateway "${IPv4gw}" \
    ipv4.dns "${IPv4dns}" \
    ipv4.method "manual"; then
    
    echo "::: [ÉXITO] Los parámetros de NetworkManager se han modificado de forma correcta."
    echo "::: [INFO] El gestor aplicará la configuración estática de forma permanente al reiniciar los servicios."
  else
    err "Error al aplicar las modificaciones IPv4 de NetworkManager sobre la conexión con UUID: ${connectionUUID}."
    exit 1
  fi
}

setStaticIPv4() {
  # ==============================================================================
  #            ORQUESTADOR GENERAL DE ASIGNACIÓN DE RED CONFIGURADA
  # ==============================================================================
  # Evalúa dinámicamente cuál es el motor de red operativo del sistema anfitrión
  # y deriva el flujo hacia el gestor correspondiente.

  echo "::: [INFO] Iniciando el volcado final de la configuración estática de IPv4..."

  if [[ -v useNetworkManager ]]; then
    echo "::: [INFO] Motor de red detectado en las variables: NetworkManager."
    setNetworkManager
    echo "useNetworkManager=${useNetworkManager}" >> "${tempsetupVarsFile}"
  else
    echo "::: [INFO] Motor de red detectado en las variables: Subsistema clásico DHCPCD."
    setDHCPCD
  fi

  echo "::: [ÉXITO] Configuración e inicialización de interfaces fijas IPv4 completada."
}

chooseUser() {
  # ==============================================================================
  #         SELECCIÓN / CREACIÓN DEL USUARIO DE CONFIGURACIÓN VPN
  # ==============================================================================
  # Define o crea el usuario local no privilegiado (no-root) bajo cuya ruta home
  # se almacenarán y custodiarán los perfiles y certificados criptográficos (.ovpn / .conf).

  local numUsers
  local availableUsers
  local install_home

  # ------------------------------------------------------------------------------
  # FLUJO A: GESTIÓN EN MODO DESATENDIDO / AUTOMATIZADO
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: [INFO] Modo desatendido activo. Validando privilegios de usuario..."

    if [[ -z "${install_user}" ]]; then
      # Contar cuántos usuarios reales con UID estándar (1000-60000) existen en el sistema
      numUsers="$(awk -F ':' 'BEGIN {count=0} $3>=1000 && $3<=60000 { count++ } END{ print count }' /etc/passwd)"

      if [[ "${numUsers}" -eq 1 ]]; then
        install_user="$(awk -F ':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd)"
        echo "::: [INFO] No se especificó usuario explícito. Detectado único usuario válido: '${install_user}'. Asignándolo de forma automática."
      else
        err "Error desatendido: No se especificó la variable 'install_user' y existen múltiples o ninguna cuenta de usuario válida en el sistema."
        exit 1
      fi
    else
      # Si el usuario fue provisto, verificar si ya existe en la base de datos de cuentas locales
      if awk -F':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd | grep -qw "${install_user}"; then
        echo "::: [INFO] El usuario especificado '${install_user}' ha sido validado. Alojará las configuraciones de los clientes."
      else
        echo "::: [AVISO] El usuario solicitado '${install_user}' no existe en el sistema anfitrión. Procediendo a su aprovisionamiento..."

        if [[ "${PLAT}" == 'Alpine' ]]; then
          ${SUDO} adduser -s /bin/bash -D "${install_user}"
          ${SUDO} addgroup "${install_user}" wheel
        else
          ${SUDO} useradd -ms /bin/bash "${install_user}"
        fi

        echo "::: [ÉXITO] Usuario '${install_user}' creado de forma correcta sin contraseña asignada."
        echo "::: [AVISO] IMPORTANTE: Recuerda establecer una contraseña segura ejecutando manualmente: 'sudo passwd ${install_user}'"
      fi
    fi

    # Resolver la ruta del directorio HOME asignada al usuario seleccionado
    install_home="$(awk -F: -v user="${install_user}" '$1==user {print $6}' /etc/passwd)"
    install_home="${install_home%/}"

    # Persistencia de variables de entorno del despliegue
    {
      echo "install_user=${install_user}"
      echo "install_home=${install_home}"
    } >> "${tempsetupVarsFile}"
    return
  fi

  # ------------------------------------------------------------------------------
  # FLUJO B: ASISTENTE INTERACTIVO (GRÁFICO - WHIPTAIL)
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Desplegando advertencia informativa sobre privilegios de almacenamiento..."

  # INTERFAZ INTERACTIVA: Cuadro explicativo de roles de seguridad (Corrección de duplicación de flag --msgbox)
  whiptail \
    --backtitle "Gestión de Usuarios del Sistema - PiVPN" \
    --title "Perfil de Almacenamiento VPN" \
    --ok-button "Entendido, Continuar" \
    --msgbox "Por motivos estrictos de seguridad y privilegios mínimos, este instalador requiere asociar las configuraciones y llaves de cifrado (.ovpn o .conf) a una cuenta de usuario estándar del sistema operativo que no sea 'root'.\n\nA continuación, se te presentará la lista de usuarios locales para que selecciones el encargado de custodiar estos perfiles." \
    "${r}" "${c}"

  # Escaneo inicial y conteo formal de cuentas de usuario no root
  numUsers="$(awk -F ':' 'BEGIN {count=0} $3>=1000 && $3<=60000 { count++ } END{ print count }' /etc/passwd)"

  # CONGENCIENCIA INTERACTIVA: Si el sistema está complemente limpio y carece de usuarios estándar
  if [[ "${numUsers}" -eq 0 ]]; then
    echo "::: [AVISO] No se han encontrado cuentas de usuario estándar en el rango UID tradicional. Solicitando creación..."
    
    local userToAdd
    if userToAdd="$(whiptail \
      --backtitle "Gestión de Usuarios del Sistema - PiVPN" \
      --title "Crear Nuevo Usuario Local" \
      --ok-button "Crear Usuario" \
      --cancel-button "Cancelar e Interrumpir" \
      --inputbox "No se ha detectado ninguna cuenta de usuario local válida (no-root) en este sistema operativo.\n\nPor favor, introduce un nombre para crear un nuevo usuario administrador de configuraciones:" \
      "${r}" "${c}" \
      3>&1 1>&2 2>&3)"; then
      
      local PASSWORD
      PASSWORD="$(whiptail \
        --backtitle "Gestión de Usuarios del Sistema - PiVPN" \
        --title "Contraseña del Nuevo Usuario" \
        --ok-button "Asignar Contraseña" \
        --cancel-button "Cancelar" \
        --passwordbox "Establece una contraseña de acceso segura para la cuenta recién introducida ('${userToAdd}'):" \
        "${r}" "${c}" \
        3>&1 1>&2 2>&3)"

      echo "::: [INFO] Registrando usuario '${userToAdd}' en el sistema utilizando mecanismos criptográficos nativos..."

      if [[ "${PLAT}" == 'Alpine' ]]; then
        if ${SUDO} adduser -Ds /bin/bash "${userToAdd}"; then
          ${SUDO} addgroup "${userToAdd}" wheel
          echo "${userToAdd}:${PASSWORD}" | ${SUDO} chpasswd
          ${SUDO} passwd -u "${userToAdd}" > /dev/null 2>&1
          echo "::: [ÉXITO] Usuario '${userToAdd}' creado y configurado correctamente en Alpine Linux."
          ((numUsers += 1))
        else
          err "Fallo crítico al intentar ejecutar 'adduser' en el entorno de Alpine."
          exit 1
        fi
      else
        # OPTIMIZACIÓN DE SEGURIDAD: Sustitución de Perl + Salt estático por chpasswd nativo del sistema
        if ${SUDO} useradd -m -s /bin/bash "${userToAdd}"; then
          echo "${userToAdd}:${PASSWORD}" | ${SUDO} chpasswd
          echo "::: [ÉXITO] Usuario '${userToAdd}' creado y configurado correctamente en el sistema anfitrión."
          ((numUsers += 1))
        else
          err "Fallo crítico al intentar ejecutar 'useradd' en la distribución."
          exit 1
        fi
      fi
    else
      err "El usuario canceló la fase mandatoria de creación de cuenta local. Abortando instalación."
      exit 1
    fi
  fi

  # ------------------------------------------------------------------------------
  # CONSTRUCCIÓN DINÁMICA DE LA LISTA DE RADIOLIST (SELECCIÓN DE USUARIO)
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Construyendo matriz dinámica de selección para la interfaz visual..."
  availableUsers="$(awk -F':' '$3>=1000 && $3<=60000 {print $1}' /etc/passwd)"
  
  local userArray=()
  local firstloop=1
  local mode

  while read -r line; do
    [[ -z "${line}" ]] && continue
    mode="OFF"
    if [[ "${firstloop}" -eq 1 ]]; then
      firstloop=0
      mode="ON" # Pre-marcar por defecto el primer elemento de la lista para facilitar la UX
    fi
    userArray+=("${line}" "Usuario local del sistema" "${mode}")
  done <<< "${availableUsers}"

  # Inicialización estructurada del comando Whiptail Radiolist
  local chooseUserCmd=(
    whiptail
    --backtitle "Gestión de Usuarios del Sistema - PiVPN"
    --title "Selección de Usuario Local"
    --ok-button "Confirmar Selección"
    --cancel-button "Cancelar e Interrumpir"
    --separate-output
    --radiolist "Selecciona la cuenta de usuario encargada de custodiar las llaves y certificados criptográficos de tus clientes VPN:\n(Usa las flechas de dirección para navegar y la barra 'Espacio' para marcar tu opción)"
    "${r}" "${c}" "${numUsers}"
  )

  echo "::: [INFO] Desplegando selector interactivo de cuentas disponibles..."
  local chooseUserOptions
  if chooseUserOptions=$("${chooseUserCmd[@]}" "${userArray[@]}" 2>&1 > /dev/tty); then
    
    local desiredUser
    for desiredUser in ${chooseUserOptions}; do
      install_user="${desiredUser}"
      
      # Extracción optimizada y limpia de la ruta del directorio HOME
      install_home="$(awk -F: -v user="${install_user}" '$1==user {print $6}' /etc/passwd)"
      install_home="${install_home%/}"

      echo "::: [ÉXITO] Usuario del ecosistema seleccionado formalmente: ${install_user} (Ruta base: ${install_home})"

      {
        echo "install_user=${install_user}"
        echo "install_home=${install_home}"
      } >> "${tempsetupVarsFile}"
    done
  else
    err "El usuario interrumpió la pantalla de asignación de perfil local. Abortando proceso."
    exit 1
  fi
}

isRepo() {
  # ==============================================================================
  #       VERIFICACIÓN DE INTEGRIDAD DE REPOSITORIO GIT LOCAL
  # ==============================================================================
  # Evalúa si un directorio específico existe y está inicializado formalmente
  # como un árbol de trabajo válido de Git.

  local target_dir="${1}"
  echo "::: [INFO] Verificando la presencia e integridad del repositorio en: ${target_dir}"

  if [[ ! -d "${target_dir}" ]]; then
    echo "::: [AVISO] El directorio de destino no existe o no es accesible."
    return 1
  fi

  # OPTIMIZACIÓN: Verificación nativa e independiente del directorio de ejecución actual
  if ${SUDO} ${GITBIN} -C "${target_dir}" rev-parse --is-inside-work-tree &>/dev/null; then
    echo "::: [INFO] Estructura Git válida detectada en la ruta objetivo."
    return 0
  else
    echo "::: [AVISO] La ruta existe pero no corresponde a un repositorio Git válido."
    return 1
  fi
}

cloneAndSetupRepo() {
  # ==============================================================================
  #       TRABAJADOR INTERNO: CLONACIÓN, MONITOREO Y CONMUTACIÓN DE RAMAS
  # ==============================================================================
  # Centraliza la lógica de descarga para mitigar la duplicación de código.
  # Garantiza operaciones de limpieza seguras y valida la correcta ejecución en background.

  local target_dir="${1}"
  local repo_url="${2}"
  local parent_dir
  parent_dir="$(dirname "${target_dir}")"

  echo "::: [INFO] Saneando el espacio de trabajo local para evitar colisiones..."
  
  # Medida de protección crítica contra borrados accidentales en la raíz
  if [[ -n "${target_dir}" && "${target_dir}" != "/" && "${target_dir}" != "." ]]; then
    ${SUDO} rm -rf "${target_dir}"
  fi

  echo "::: [INFO] Descargando componentes del repositorio remoto..."
  
  # Posicionarse en el directorio padre antes de clonar para evitar bloqueos de Git
  cd "${parent_dir}" || exit 1

  # Clonación asíncrona optimizada en profundidad (Shallow Clone)
  ${SUDO} ${GITBIN} clone -q \
    --depth 1 \
    --no-single-branch \
    "${repo_url}" \
    "${target_dir}" > /dev/null 2>&1 &
  
  # Invocar el monitor visual de progreso mediante su PID
  spinner $!

  # Validación post-clonación: Asegurar que el proceso asíncrono se consolidó con éxito
  if [[ ! -d "${target_dir}" ]]; then
    err "Fallo crítico: No se pudo clonar el repositorio remoto en la ruta: '${target_dir}'"
    exit 1
  fi

  cd "${target_dir}" || exit 1
  echo "::: [ÉXITO] Sincronización del repositorio base completada."

  # ------------------------------------------------------------------------------
  # GESTIÓN DE RAMAS (PRODUCCIÓN / DESARROLLO CUSTOM / TESTING)
  # ------------------------------------------------------------------------------
  if [[ -n "${pivpnGitBranch}" ]]; then
    echo "::: [INFO] Conmutando a la rama de desarrollo personalizada: '${pivpnGitBranch}'..."
    if ${SUDOE} ${GITBIN} checkout -q "${pivpnGitBranch}"; then
      echo "::: [ÉXITO] Despliegue completado sobre la rama: '${pivpnGitBranch}'."
    else
      err "No se pudo cambiar a la rama solicitada '${pivpnGitBranch}'. Verifica su existencia en el origen."
      exit 1
    fi
  elif [[ -n "${TESTING:-}" ]]; then
    echo "::: [AVISO] Variable de entorno TESTING detectada. Conmutando a la rama 'test'..."
    if ${SUDOE} ${GITBIN} checkout -q test; then
      echo "::: [ÉXITO] Despliegue completado sobre la rama de pruebas: 'test'."
    else
      err "No se pudo conmutar el repositorio a la rama 'test'."
      exit 1
    fi
  fi
}

updateRepo() {
  # ==============================================================================
  #         ACTUALIZACIÓN / REPARACIÓN DE REPOSITORIO EXISTENTE
  # ==============================================================================
  
  if [[ "${UpdateCmd}" == "Repair" ]]; then
    echo "::: [INFO] Modo reparación activo. Preservando el estado del repositorio local actual sin realizar descargas."
  else
    echo "::: [INFO] Iniciando la actualización y sobreescritura controlada del repositorio..."
    cloneAndSetupRepo "${1}" "${2}"
  fi
}

makeRepo() {
  # ==============================================================================
  #         INICIALIZACIÓN LIMPIA DE REPOSITORIO INEXISTENTE
  # ==============================================================================
  
  echo "::: [INFO] Procediendo con una inicialización limpia del repositorio de fuentes..."
  cloneAndSetupRepo "${1}" "${2}"
}

getGitFiles() {
  # ==============================================================================
  #         ORQUESTADOR DE EVALUACIÓN DE ARCHIVOS BASE
  # ==============================================================================
  
  echo "::: [INFO] Evaluando la validez del árbol de directorios de PiVPN..."

  if isRepo "${1}"; then
    updateRepo "${1}" "${2}"
  else
    makeRepo "${1}" "${2}"
  fi
}

cloneOrUpdateRepos() {
  # ==============================================================================
  #         PUNTO DE ENTRADA GLOBAL PARA LA ADQUISICIÓN DE FUENTES
  # ==============================================================================
  
  echo "::: [INFO] Asegurando jerarquía de directorios del sistema en /usr/local/src..."
  
  if ! ${SUDO} mkdir -p /usr/local/src; then
    err "Error de entorno: No se pudo crear o verificar el directorio '/usr/local/src'. Revisa los privilegios del sistema."
    exit 1
  fi

  # Ejecución de la descarga o actualización de archivos Git
  if ! getGitFiles "${pivpnFilesDir}" "${pivpnGitUrl}"; then
    err "Error catastrófico: No se pudo procesar la descarga de '${pivpnGitUrl}' hacia '${pivpnFilesDir}'."
    exit 1
  fi
}

installPiVPN() {
  # ==============================================================================
  #          ORQUESTADOR PRINCIPAL DEL PROCESO DE INSTALACIÓN DE PIVPN
  # ==============================================================================
  # Coordina de forma secuencial la creación de directorios del ecosistema,
  # la recopilación interactiva de parámetros y el despliegue del motor VPN elegido.

  echo "::: [INFO] Iniciando el despliegue formal del ecosistema PiVPN..."

  # Garantizar la existencia de la ruta de configuración con control de errores directo
  if ! ${SUDO} mkdir -p /etc/pivpn/; then
    err "Fallo crítico: No se pudo crear el directorio de configuración persistente en '/etc/pivpn/'."
    exit 1
  fi

  # Selección interactiva del motor de virtualización de red
  echo "::: [INFO] Desplegando asistente de selección de motor VPN..."
  askWhichVPN
  setVPNDefaultVars

  # ------------------------------------------------------------------------------
  # FASE 1: INSTALACIÓN Y PARAMETRIZACIÓN DEL DEMONIO ESPECÍFICO
  # ------------------------------------------------------------------------------
  if [[ "${VPN}" == 'openvpn' ]]; then
    echo "::: [INFO] Inicializando rutina de aprovisionamiento para OpenVPN..."
    setOpenVPNDefaultVars
    askAboutCustomizing
    installOpenVPN
    askCustomProto
  elif [[ "${VPN}" == 'wireguard' ]]; then
    echo "::: [INFO] Inicializando rutina de aprovisionamiento para WireGuard..."
    setWireguardDefaultVars
    installWireGuard
  else
    err "Motor VPN desconocido o no parametrizado: '${VPN}'."
    exit 1
  fi

  # ------------------------------------------------------------------------------
  # FASE 2: CONFIGURACIÓN INTEGRAL DE RED, PUERTOS Y RESOLUCIÓN DNS
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Configurando parámetros de red global y asignación de puertos..."
  askCustomPort
  askClientDNS

  if [[ "${VPN}" == 'openvpn' ]]; then
    askCustomDomain
  fi

  # Definición de la puerta de enlace pública (IP Estática o Nombre de Dominio DNS)
  askPublicIPOrDNS

  # ------------------------------------------------------------------------------
  # FASE 3: CRIPTOGRAFÍA Y CONSOLIDACIÓN DE DIRECTIVAS
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Consolidando archivos de configuración criptográfica..."
  if [[ "${VPN}" == 'openvpn' ]]; then
    askEncryption
    confOpenVPN
    confOVPN
  elif [[ "${VPN}" == 'wireguard' ]]; then
    confWireGuard
  fi

  # Ajustes de enrutamiento del núcleo del sistema (Sysctl, Forwarding, IPTables)
  echo "::: [INFO] Aplicando directivas de red del sistema anfitrión..."
  confNetwork

  # ------------------------------------------------------------------------------
  # FASE 4: PERSISTENCIA DE LOGS Y VOLCADO DE VARIABLES VOLÁTILES
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Volcando variables de entorno para el gestor de perfiles..."
  if [[ "${VPN}" == 'openvpn' ]]; then
    if [[ "${PLAT}" == 'Alpine' ]]; then
      confLogging
    fi
  elif [[ "${VPN}" == 'wireguard' ]]; then
    writeWireguardTempVarsFile
  fi

  writeVPNTempVarsFile
  echo "::: [ÉXITO] Fase de instalación y preconfiguración completada correctamente."
}

decIPv4ToDot() {
  # ==============================================================================
  #          CONVERSIÓN DE ENTERO DECIMAL A NOTACIÓN PUNTO-DECIMAL IPv4
  # ==============================================================================
  # Toma un entero de 32 bits y realiza máscaras de bits dinámicas para extraer
  # los cuatro octetos tradicionales de una dirección IP (A.B.C.D).

  local ip_dec="${1}"
  local a b c d

  a=$(( (ip_dec & 0xFF000000) >> 24 ))
  b=$(( (ip_dec & 0x00FF0000) >> 16 ))
  c=$(( (ip_dec & 0x0000FF00) >> 8 ))
  d=$(( ip_dec & 0x000000FF ))

  printf "%s.%s.%s.%s\n" "${a}" "${b}" "${c}" "${d}"
}

dotIPv4ToDec() {
  # ==============================================================================
  #          CONVERSIÓN DE NOTACIÓN PUNTO-DECIMAL IPv4 A ENTERO DECIMAL
  # ==============================================================================
  # Procesa una cadena de texto IP (A.B.C.D) de forma segura. Se parametriza IFS
  # en línea para evitar la mutación y contaminación del entorno global de la shell.

  local a b c d
  IFS='.' read -r a b c d <<< "${1}"

  printf "%s\n" "$(( (a * 16777216) + (b * 65536) + (c * 256) + d ))"
}

dotIPv4FirstDec() {
  # ==============================================================================
  #          CÁLCULO DEL PRIMER VALOR DECIMAL DE UNA SUBRED (NETWORK ID)
  # ==============================================================================
  local decimal_ip decimal_mask
  
  decimal_ip=$(dotIPv4ToDec "${1}")
  decimal_mask=$(( 0xFFFFFFFF << (32 - ${2}) & 0xFFFFFFFF ))
  
  printf "%s\n" "$(( decimal_ip & decimal_mask ))"
}

dotIPv4LastDec() {
  # ==============================================================================
  #          CÁLCULO DEL ÚLTIMO VALOR DECIMAL DE UNA SUBRED (BROADCAST)
  # ==============================================================================
  local decimal_ip decimal_mask_inv
  
  decimal_ip=$(dotIPv4ToDec "${1}")
  decimal_mask_inv=$(( (1 << (32 - ${2})) - 1 ))
  
  printf "%s\n" "$(( decimal_ip | decimal_mask_inv ))"
}

decIPv4ToHex() {
  # ==============================================================================
  #          CONVERSIÓN DE ENTERO DECIMAL A IDENTIFICADOR HEXADECIMAL
  # ==============================================================================
  # Transforma la dirección en una cadena hexadecimal formateada en dos cuartetos.
  # Corrección crítica: Se declaran todas las variables internas como locales.

  local ip_dec="${1}"
  local hex quartet_hi quartet_lo leading_zeros_hi leading_zeros_lo

  hex="$(printf "%08x\n" "${ip_dec}")"
  quartet_hi=${hex:0:4}
  quartet_lo=${hex:4:4}

  # Limpieza estética de ceros a la izquierda en los bloques resultantes
  leading_zeros_hi="${quartet_hi%%[!0]*}"
  leading_zeros_lo="${quartet_lo%%[!0]*}"
  
  printf "%s:%s\n" "${quartet_hi#"${leading_zeros_hi}"}" "${quartet_lo#"${leading_zeros_lo}"}"
}

cidrToMask() {
  # ==============================================================================
  #          CONVERSIÓN DE PREFIJO CIDR A MÁSCARA DE RED TRADICIONAL
  # ==============================================================================
  # Optimización avanzada: Reemplaza el antiguo volcado posicional por el cálculo
  # matemático nativo de bits de la máscara, reutilizando la función decIPv4ToDot.

  local cidr="${1}"
  local mask_dec

  # Evitar desbordamientos si el prefijo está fuera de los rangos estándar de IPv4
  if [[ "${cidr}" -lt 0 || "${cidr}" -gt 32 ]]; then
    echo "255.255.255.0" # Retorno seguro de contingencia estándar (/24)
    return
  fi

  mask_dec=$(( (0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF ))
  decIPv4ToDot "${mask_dec}"
}

setVPNDefaultVars() {
  # ==============================================================================
  #         CONFIGURACIÓN DE PARÁMETROS Y MÁSCARAS POR DEFECTO DE LA VPN
  # ==============================================================================
  # Inicializa las clases de subred estándar para IPv4 e IPv6 si no han sido
  # preconfiguradas previamente en el archivo de instalación desatendida.

  echo "::: [INFO] Inicializando máscaras y variables de red por defecto..."

  if [[ -z "${subnetClass}" ]]; then
    subnetClass="24"
  fi

  if [[ -z "${subnetClassv6}" ]]; then
    subnetClassv6="64"
  fi
}

generateRandomSubnet() {
  # ==============================================================================
  #       GENERACIÓN AUTOMÁTICA Y SEGURA DE SUBREDES PARA EVITAR CONFLICTOS
  # ==============================================================================
  # Escanea las interfaces de red del sistema y subredes comunes de enrutadores
  # domésticos para encontrar una zona aislada y libre de colisiones IP.
  # Fuente base: https://community.openvpn.net/openvpn/wiki/AvoidRoutingConflicts

  local source_subnet="${1}"
  local target_netmask="${2}"

  echo "::: [INFO] Analizando el mapa de direccionamiento local para prevenir solapamientos..."

  # Declaración explícita con ámbito local para evitar contaminación de variables globales
  local -a excluded_subnets_dec=(
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

  # OPTIMIZACIÓN DE FLUJO: Uso de mapfile y sustitución de procesos para evitar falsos positivos vacíos
  local -a currently_used_subnets=()
  mapfile -t currently_used_subnets < <(ip route show | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\/[0-9]{1,2}' || true)

  local used used_ip used_mask
  for used in "${currently_used_subnets[@]}"; do
    # Protección crítica contra líneas vacías si grep no obtuvo coincidencias
    [[ -z "${used}" ]] && continue
    
    used_ip="${used%/*}"
    used_mask="${used##*/}"

    excluded_subnets_dec+=("$(dotIPv4FirstDec "${used_ip}" "${used_mask}")")
    excluded_subnets_dec+=("$(dotIPv4LastDec "${used_ip}" "${used_mask}")")
  done

  local excluded_subnets_count="${#excluded_subnets_dec[@]}"
  echo "::: [INFO] Se han registrado $((excluded_subnets_count / 2)) rangos de subred IP excluidos."

  local source_ip="${source_subnet%/*}"
  local source_netmask="${source_subnet##*/}"
  
  # Corrección SC2155: Separación estricta de declaración y asignación dinámica
  local source_ip_dec
  source_ip_dec="$(dotIPv4ToDec "${source_ip}")"
  
  # OPTIMIZACIÓN: Sustitución de cálculo exponencial por máscaras de bits aritméticas puras
  local source_netmask_dec=$(( (0xFFFFFFFF << (32 - source_netmask)) & 0xFFFFFFFF ))
  local first_ip_target_subnet_dec=$(( source_ip_dec & source_netmask_dec ))
  local total_ips_target_subnet=$(( 1 << (32 - target_netmask) ))

  # Mapeo y barajado aleatorio para garantizar inspección única por segmento sin repeticiones
  local subnets_count=$(( 1 << (target_netmask - source_netmask) ))
  local -a random_perm=()
  mapfile -t random_perm < <(shuf -i 0-$((subnets_count - 1)) 2>/dev/null || seq 0 $((subnets_count - 1)) | shuf)

  # Mitigación de sobrecarga en CPUs mononúcleo (ej. Raspberry Pi Zero / arquitecturas embebidas)
  local max_tries="${subnets_count}"
  if [[ $((subnets_count * excluded_subnets_count)) -ge 5000 ]]; then
    max_tries=$(( 5000 / (excluded_subnets_count / 2) ))
  fi

  local first_ip_subnet_dec last_ip_subnet_dec
  local first_ip_excluded_subnet_dec last_ip_excluded_subnet_dec
  local overlap
  local i j
  local subnet_encontrada="false"

  for ((i = 0; i < max_tries; i++)); do
    first_ip_subnet_dec=$(( first_ip_target_subnet_dec + (total_ips_target_subnet * random_perm[i]) ))
    last_ip_subnet_dec=$(( first_ip_subnet_dec + total_ips_target_subnet - 1 ))
    overlap="false"

    for ((j = 0; j < excluded_subnets_count; j += 2)); do
      first_ip_excluded_subnet_dec="${excluded_subnets_dec[j]}"
      last_ip_excluded_subnet_dec="${excluded_subnets_dec[j + 1]}"

      # Verificación lógica estructural de solapamiento de segmentos de red
      # Rango Excluido:  |----------- [j] ----------- [j+1] -----------|
      # Rango Candidato:           |------- [first] ------- [last] -------|
      if (( last_ip_excluded_subnet_dec >= first_ip_subnet_dec )) && (( first_ip_excluded_subnet_dec <= last_ip_subnet_dec )); then
        overlap="true"
        break
      fi
    done

    # Corrección estética y de rendimiento: Evaluación de cadena estándar en lugar de ejecución directa de string
    if [[ "${overlap}" == "false" ]]; then
      decIPv4ToDot "${first_ip_subnet_dec}"
      subnet_encontrada="true"
      break
    fi
  done

  # Control de contingencia si el espacio de red está completamente saturado
  if [[ "${subnet_encontrada}" == "false" ]]; then
    err "Error crítico: No se ha podido determinar una subred IPv4 libre de conflictos tras ${max_tries} intentos."
    return 1
  fi
}

allocateVPNSubnet() {
  # ==============================================================================
  #       ASIGNADOR ASISTIDO DE POOL DE SUBREDES PRIVADAS (RFC 1918)
  # ==============================================================================
  # Evalúa secuencialmente los tres bloques principales de direccionamiento privado
  # para mitigar colisiones con la LAN física del servidor o de los clientes.

  if [[ -n "${pivpnNET}" ]]; then
    echo "::: [INFO] Reutilizando subred estática preconfigurada de forma desatendida: ${pivpnNET}/${subnetClass}"
    return 0
  fi

  echo "::: [INFO] Buscando un segmento IPv4 dinámico libre de conflictos de enrutamiento..."

  # Intento 1: Bloque de Clase A (Común en entornos empresariales / Docker vnet)
  echo "::: [INFO] Evaluando disponibilidad en el espacio de direccionamiento 10.0.0.0/8..."
  pivpnNET="$(generateRandomSubnet "10.0.0.0/8" "${subnetClass}")"

  # Intento 2: Bloque de Clase B (Menos común, óptimo para aislamiento de VPN)
  if [[ -z "${pivpnNET}" ]]; then
    echo "::: [AVISO] Espacio 10.0.0.0/8 saturado o en conflicto. Probando bloque 172.16.0.0/12..."
    pivpnNET="$(generateRandomSubnet "172.16.0.0/12" "${subnetClass}")"
  fi

  # Intento 3: Bloque de Clase C (Uso doméstico masivo, última opción de contingencia)
  if [[ -z "${pivpnNET}" ]]; then
    echo "::: [AVISO] Espacio 172.16.0.0/12 no disponible. Probando bloque de contingencia 192.168.0.0/16..."
    pivpnNET="$(generateRandomSubnet "192.168.0.0/16" "${subnetClass}")"
  fi

  # Control de saturación total del entorno de red virtual
  if [[ -z "${pivpnNET}" ]]; then
    err "Error catastrófico: No se ha podido reservar una subred privada. Todos los segmentos RFC 1918 están ocupados."
    exit 1
  fi

  echo "::: [ÉXITO] Subred virtual asignada con éxito al direccionamiento local: ${pivpnNET}/${subnetClass}"
}

calculateVPNEndpoints() {
  # ==============================================================================
  #       CALCULADOR DE PARÁMETROS DE RED Y DIRECCIONES DE ENLACE
  # ==============================================================================
  # Transforma la subred en formato decimal y extrae de forma automática la primera 
  # IP válida para ser utilizada como la interfaz de la pasarela de enlace (Gateway).

  pivpnNETdec="$(dotIPv4ToDec "${pivpnNET}")"
  vpnGwdec="$((pivpnNETdec + 1))"
  vpnGw="$(decIPv4ToDot "${vpnGwdec}")"
  vpnGwhex="$(decIPv4ToHex "${vpnGwdec}")"

  # Tratamiento y aprovisionamiento automático de direccionamiento IPv6 (ULA)
  if [[ "${pivpnenableipv6:-0}" -eq 1 ]]; then
    if [[ -z "${pivpnNETv6}" ]]; then
      pivpnNETv6="fd11:5ee:bad:c0de::"
    fi
    vpnGwv6="${pivpnNETv6}${vpnGwhex}"
    echo "::: [INFO] Direccionamiento IPv6 activo. Pasarela virtual calculada: [${vpnGwv6}]"
  fi
}

setOpenVPNDefaultVars() {
  # ==============================================================================
  #       ESTABLECER CONFIGURACIONES POR DEFECTO PARA EL MOTOR OPENVPN
  # ==============================================================================
  
  echo "::: [INFO] Cargando entorno de variables predeterminadas para OpenVPN..."
  pivpnDEV="tun0"

  # Ejecutar asignación matricial de red y gateways
  allocateVPNSubnet
  calculateVPNEndpoints
}

setWireguardDefaultVars() {
  # ==============================================================================
  #       ESTABLECER CONFIGURACIONES POR DEFECTO PARA EL MOTOR WIREGUARD
  # ==============================================================================
  
  echo "::: [INFO] Cargando entorno de variables predeterminadas para WireGuard..."
  
  # WireGuard opera nativamente de forma exclusiva sobre la capa de transporte UDP
  pivpnPROTO="udp"
  pivpnDEV="wg0"

  # Ejecutar asignación matricial de red y gateways
  allocateVPNSubnet
  calculateVPNEndpoints

  # ------------------------------------------------------------------------------
  # GESTIÓN DE POLÍTICAS DE TRÁFICO PERMITIDO (ALLOWED IPs - SPLIT/FULL TUNNEL)
  # ------------------------------------------------------------------------------
  if [[ -z "${ALLOWED_IPS}" ]]; then
    # Por defecto, se aprovisiona como "Túnel Completo" (Full Tunnel) enrutando todo el tráfico
    ALLOWED_IPS="0.0.0.0/0"

    # Enrutar el tráfico global IPv6 a través del túnel si la pila dual está habilitada
    if [[ "${pivpnenableipv6:-0}" -eq 1 || "${pivpnforceipv6route:-0}" -eq 1 ]]; then
      ALLOWED_IPS="${ALLOWED_IPS}, ::0/0"
    fi
  fi

  # ------------------------------------------------------------------------------
  # OPTIMIZACIÓN DE MTU (MAXIMUM TRANSMISSION UNIT)
  # ------------------------------------------------------------------------------
  # Se establece 1420 por defecto para dejar un margen seguro de 80 bytes (overhead) 
  # evitando la fragmentación de paquetes encapsulados en enlaces WAN estándar de 1500.
  if [[ -z "${pivpnMTU}" ]]; then
    pivpnMTU="1420"
  fi

  # Desactivar bandera de personalización interactiva por defecto
  CUSTOMIZE=0
}

writeVPNTempVarsFile() {
  # ==============================================================================
  #       PERSISTENCIA TEMPORAL DE VARIABLES MATRICIALES DE LA VPN
  # ==============================================================================
  # Centraliza y vuelca el mapa de direccionamiento, interfaces y directivas IPv6
  # principales en el archivo de preconfiguración temporal de la suite.

  echo "::: [INFO] Volcando variables base de configuración al archivo temporal..."

  if ! {
    echo "pivpnDEV=\"${pivpnDEV}\""
    echo "pivpnNET=\"${pivpnNET}\""
    echo "subnetClass=\"${subnetClass}\""
    echo "pivpnenableipv6=${pivpnenableipv6:-0}"

    if [[ "${pivpnenableipv6:-0}" -eq 1 ]]; then
      echo "pivpnNETv6=\"${pivpnNETv6}\""
      echo "subnetClassv6=\"${subnetClassv6}\""
    fi

    echo "ALLOWED_IPS=\"${ALLOWED_IPS}\""
  } >> "${tempsetupVarsFile}"; then
    
    # Notificación visual interactiva si ocurre un fallo físico o de permisos en disco
    whiptail --backtitle "Asistente de Instalación PiVPN" \
             --title "Error Crítico de Almacenamiento" \
             --ok-button "Aceptar" \
             --msgbox "No se ha podido escribir en el archivo de configuración temporal:\n\n${tempsetupVarsFile}\n\nPor favor, comprueba si el almacenamiento interno está lleno o si existen restricciones de escritura." "${r:-14}" "${c:-70}"
             
    echo "::: [ERROR] Fallo catastrófico al intentar anexar variables en '${tempsetupVarsFile}'." >&2
    exit 1
  fi

  echo "::: [ÉXITO] Directivas globales de red consolidadas correctamente."
}

writeWireguardTempVarsFile() {
  # ==============================================================================
  #       PERSISTENCIA TEMPORAL DE DIRECTIVAS PROPIAS DE WIREGUARD
  # ==============================================================================
  # Anexa la configuración del protocolo de transporte, MTU optimizada y las
  # variables persistentes de mantenimiento de enlace (KeepAlive).

  echo "::: [INFO] Volcando parámetros de rendimiento de WireGuard al archivo temporal..."

  if ! {
    echo "pivpnPROTO=\"${pivpnPROTO}\""
    echo "pivpnMTU=\"${pivpnMTU}\""

    # Aprovisionamiento dinámico de KeepAlive si se define mediante entorno desatendido.
    # Ayuda a estabilizar túneles detrás de firewalls restrictivos o NAT simétricos residenciales.
    if [[ -n "${pivpnPERSISTENTKEEPALIVE}" ]]; then
      echo "pivpnPERSISTENTKEEPALIVE=\"${pivpnPERSISTENTKEEPALIVE}\""
    fi
  } >> "${tempsetupVarsFile}"; then
    
    # Notificación visual interactiva específica para el stack de WireGuard
    whiptail --backtitle "Asistente de Instalación PiVPN" \
             --title "Error de Configuración (WireGuard)" \
             --ok-button "Aceptar" \
             --msgbox "Fallo grave de E/S al anexar las directivas de WireGuard en:\n\n${tempsetupVarsFile}" "${r:-12}" "${c:-70}"
             
    echo "::: [ERROR] No se pudieron agregar las configuraciones de rendimiento de WireGuard en '${tempsetupVarsFile}'." >&2
    exit 1
  fi

  echo "::: [ÉXITO] Parámetros del motor criptográfico WireGuard guardados con éxito."
}

askWhichVPN() {
  # ==============================================================================
  #         SELECCIÓN E INSPECCIÓN DEL PROTOCOLO / MOTOR VPN
  # ==============================================================================
  # Determina si el sistema desplegará WireGuard o OpenVPN, validando la
  # compatibilidad de la plataforma tanto en modo interactivo como desatendido.

  local -a chooseVPNCmd=()
  local -a VPNChooseOptions=()
  local wg_support="${WIREGUARD_SUPPORT:-0}"
  local ovpn_support="${OPENVPN_SUPPORT:-0}"

  # Normalizar el protocolo entrante a minúsculas si ya se ha predefinido
  if [[ -n "${VPN}" ]]; then
    VPN="${VPN,,}"
  fi

  # Validación preventiva integral de capacidades de la arquitectura/SO
  if [[ "${wg_support}" -ne 1 && "${ovpn_support}" -ne 1 ]]; then
    err "Error crítico: Esta plataforma (${PLAT:-Desconocida} / ${DPKG_ARCH:-Desconocida}) no admite ningún motor VPN compatible."
    exit 1
  fi

  # ------------------------------------------------------------------------------
  # MODO 1: INSTALACIÓN DESATENDIDA (AUTOMATIZADA / SETUPVARS)
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: [INFO] Detectado modo de instalación desatendida. Procesando parámetros..."

    if [[ -z "${VPN}" ]]; then
      # Selección automática guiada por prioridades técnicas de soporte del host
      if [[ "${wg_support}" -eq 1 ]]; then
        echo "::: [AVISO] No se especificó protocolo VPN. Seleccionando WireGuard por defecto debido a la arquitectura."
        VPN="wireguard"
      else
        echo "::: [AVISO] No se especificó protocolo VPN. Seleccionando OpenVPN por defecto debido a la arquitectura."
        VPN="openvpn"
      fi
    else
      # Validar el protocolo solicitado de forma explícita frente a las capacidades reales
      if [[ "${VPN}" == "wireguard" ]]; then
        if [[ "${wg_support}" -ne 1 ]]; then
          err "Fallo de validación: WireGuard no es compatible con el hardware o entorno actual (${DPKG_ARCH} ${PLAT})."
          exit 1
        fi
        echo "::: [INFO] Protocolo validado: Se procederá con el aprovisionamiento de WireGuard."
      elif [[ "${VPN}" == "openvpn" ]]; then
        if [[ "${ovpn_support}" -ne 1 ]]; then
          err "Fallo de validación: OpenVPN no está disponible o no es compatible con este sistema."
          exit 1
        fi
        echo "::: [INFO] Protocolo validado: Se procederá con el aprovisionamiento de OpenVPN."
      else
        err "Parámetro inválido: El protocolo '${VPN}' no es reconocido. Opciones válidas: 'wireguard' o 'openvpn'."
        exit 1
      fi
    fi

  # ------------------------------------------------------------------------------
  # MODO 2: INSTALACIÓN INTERACTIVA (ASISTIDA POR MENÚS DE DIÁLOGO WHIPTAIL)
  # ------------------------------------------------------------------------------
  else
    if [[ "${wg_support}" -eq 1 && "${ovpn_support}" -eq 1 ]]; then
      # Configuración de comando interactivo con botones de acción traducidos
      chooseVPNCmd=(
        whiptail
        --backtitle "Configuración Inicial del Servidor PiVPN"
        --title "Selección de Protocolo VPN"
        --ok-button "Seleccionar"
        --cancel-button "Cancelar"
        --separate-output
        --radiolist "Selecciona el motor VPN que deseas instalar en tu sistema:\n\n• WireGuard (Recomendado): Criptografía de última generación, máxima velocidad de transferencia, latencia mínima y óptimo consumo de batería en smartphones.\n• OpenVPN: El estándar clásico de la industria. Altamente flexible, robusto y recomendado si necesitas usar transporte TCP para evadir inspecciones de red o firewalls corporativos estrictos.\n\n(Presiona la barra espaciadora para marcar tu opción y pulsa Intro para confirmar):" 
        "${r:-22}" "${c:-78}" 2
      )
      
      VPNChooseOptions=(
        "WireGuard" "Rendimiento avanzado y arquitectura moderna" on
        "OpenVPN" "Estabilidad convencional y máxima compatibilidad" off
      )

      # Captura segura del flujo de la interfaz interactiva tty
      if VPN="$("${chooseVPNCmd[@]}" "${VPNChooseOptions[@]}" 2>&1 >/dev/tty)"; then
        VPN="${VPN,,}"
        echo "::: [INFO] Motor de red seleccionado por el usuario: ${VPN}"
      else
        echo "::: [AVISO] Cancelación detectada en el cuadro de diálogo. Abortando instalación de forma segura..." >&2
        exit 1
      fi
    elif [[ "${ovpn_support}" -eq 1 ]]; then
      echo "::: [INFO] Entorno restrictivo detectado: Solo OpenVPN es viable en esta máquina."
      VPN="openvpn"
    elif [[ "${wg_support}" -eq 1 ]]; then
      echo "::: [INFO] Entorno restrictivo detectado: Solo WireGuard es viable en esta máquina."
      VPN="wireguard"
    fi
  fi

  # ------------------------------------------------------------------------------
  # PERSISTENCIA TRANSACCIONAL DE CONFIGURACIÓN
  # ------------------------------------------------------------------------------
  if ! echo "VPN=${VPN}" >> "${tempsetupVarsFile}"; then
    err "Fallo crítico de E/S: No se pudo volcar la variable del protocolo seleccionado en '${tempsetupVarsFile}'."
    exit 1
  fi
  
  echo "::: [ÉXITO] Configuración de pila consolidada. Servidor asignado a: ${VPN}"
}

askAboutCustomizing() {
  # ==============================================================================
  #         SELECCIÓN DE CONFIGURACIÓN RÁPIDA O PERSONALIZADA
  # ==============================================================================
  # Permite al usuario decidir entre aplicar el perfil de configuración optimizado
  # por defecto o entrar en el asistente iterativo para ajustar cada parámetro.

  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: [INFO] Modo desatendido activo. Omitiendo cuadro de diálogo interactivo."
    CUSTOMIZE=0
    return 0
  fi

  echo "::: [INFO] Solicitando confirmación del modo de instalación al usuario..."

  # Despliegue del menú visual interactivo con botones regionalizados en español
  if whiptail \
    --backtitle "Configuración del Servidor PiVPN" \
    --title "Modo de Instalación y Parámetros" \
    --yes-button "Aceptar y Continuar" \
    --no-button "Personalizar" \
    --yesno "Para la mayoría de los entornos, PiVPN aplica un perfil de configuración optimizado por defecto. Se compone de los siguientes parámetros técnicos:\n\n• Protocolo de Red: UDP (Más rápido y eficiente)\n• Dominio de Búsqueda DNS: Ninguno (Por defecto)\n• Nivel de Seguridad: Perfil Moderno (Certificado de 256 bits + Cifrado TLS Avanzado)\n\n¿Deseas aplicar estos valores recomendados directamente o prefieres personalizar los detalles de la instalación?" \
    "${r:-22}" "${c:-78}"; then
    
    echo "::: [INFO] El usuario ha optado por aplicar el perfil optimizado por defecto."
    CUSTOMIZE=0
  else
    echo "::: [INFO] El usuario ha seleccionado la personalización manual de parámetros."
    CUSTOMIZE=1
  fi
}

installOpenVPN() {
  # ==============================================================================
  #         INSTALACIÓN Y CONFIGURACIÓN DEL MOTOR DE RED OPENVPN
  # ==============================================================================
  # Resuelve las dependencias base e importa de forma segura los llaveros criptográficos
  # oficiales para desplegar la última compilación estable de OpenVPN.

  local -a PIVPN_DEPS=()
  local gpg_path="${pivpnFilesDir}/files/etc/apt/repo-public.gpg"
  local keyring_dir="/usr/share/keyrings"
  local keyring_path

  echo "::: [INFO] Iniciando los procesos de preparación para OpenVPN..."

  if [[ "${NEED_OPENVPN_REPO:-0}" -eq 1 ]]; then
    echo "::: [INFO] Configurando repositorio oficial externo de OpenVPN..."

    # Validación preventiva crítica: Comprobar existencia del recurso origen
    if [[ ! -f "${gpg_path}" ]]; then
      err "Error crítico: No se ha localizado el archivo de clave de origen en: ${gpg_path}"
      exit 1
    fi

    # Instalar gnupg, herramienta necesaria para el procesamiento seguro de llaveros de APT
    PIVPN_DEPS=(gnupg)
    installDependentPackages PIVPN_DEPS[@]

    # Determinar el directorio de llaveros óptimo según los estándares modernos de la distribución
    if [[ ! -d "${keyring_dir}" ]]; then
      keyring_dir="/etc/apt/trusted.gpg.d"
    fi
    keyring_path="${keyring_dir}/openvpn-repo-keyring.gpg"

    echo "::: [INFO] Importando clave pública GPG al llavero del sistema: ${keyring_path}"
    
    # Procesamiento y desarmado seguro (dearmor) según la estructura nativa de la clave
    if grep -q "BEGIN PGP PUBLIC KEY BLOCK" "${gpg_path}"; then
      if ! ${SUDO} gpg --dearmor < "${gpg_path}" | ${SUDO} tee "${keyring_path}" > /dev/null; then
        err "Error de procesamiento: Falló la conversión del bloque de clave ASCII mediante gpg --dearmor."
        exit 1
      fi
    else
      if ! ${SUDO} cp "${gpg_path}" "${keyring_path}"; then
        err "Error de E/S: No se pudo copiar la clave binaria al llavero de destino."
        exit 1
      fi
    fi

    # Validación de integridad física y dimensional del llavero final resultante
    if [[ ! -s "${keyring_path}" ]]; then
      err "Error de validación: El archivo de llavero final se generó vacío o se encuentra corrupto."
      exit 1
    fi

    echo "::: [ÉXITO] Clave criptográfica agregada y validada correctamente."

    # Inserción del repositorio seguro mapeado exclusivamente a su clave firmante (Signed-By)
    echo "::: [INFO] Registrando índice del repositorio firmado en sources.list.d..."
    if ! echo "deb [signed-by=${keyring_path}] https://build.openvpn.net/debian/openvpn/stable ${OSCN} main" \
      | ${SUDO} tee /etc/apt/sources.list.d/pivpn-openvpn-repo.list > /dev/null; then
      err "Error de escritura: No se pudo crear el archivo del repositorio de OpenVPN."
      exit 1
    fi

    echo "::: [INFO] Actualizando la caché local del gestor de paquetes APT..."
    updatePackageCache
  fi

  # Despliegue definitivo del binario del servidor VPN
  echo "::: [INFO] Ejecutando la instalación del paquete binario principal de OpenVPN..."
  PIVPN_DEPS=(openvpn)
  if ! installDependentPackages PIVPN_DEPS[@]; then
    err "Error crítico: Falló la descarga e instalación del paquete 'openvpn'."
    exit 1
  fi

  echo "::: [ÉXITO] El entorno de ejecución de OpenVPN ha sido desplegado correctamente."
}

installWireGuard() {
  # ==============================================================================
  #         INSTALACIÓN Y CONFIGURACIÓN DEL MOTOR CRIPTOGRÁFICO WIREGUARD
  # ==============================================================================
  # Resuelve de forma dinámica las dependencias requeridas según la distribución,
  # gestionando el anclaje (pinning) de repositorios en ramas heredadas si es necesario,
  # e inyectando herramientas complementarias de movilidad como qrencode.

  local -a PIVPN_DEPS=(wireguard-tools)
  local platform="${PLAT:-Desconocida}"
  local builtin_wg="${WIREGUARD_BUILTIN:-0}"

  echo "::: [INFO] Identificando el ecosistema operativo para compilar dependencias..."

  case "${platform}" in
    "Raspbian")
      echo "::: [INFO] Detectado entorno Raspbian. Añadiendo utilidades de renderizado QR móviles..."
      PIVPN_DEPS+=(qrencode)
      ;;
    "Debian")
      echo "::: [INFO] Detectado entorno Debian. Evaluando integración nativa del kernel..."
      PIVPN_DEPS+=(qrencode)
      if [[ "${builtin_wg}" -eq 0 ]]; then
        echo "::: [AVISO] Módulo WireGuard no integrado en el kernel base. Añadiendo cabeceras y soporte DKMS..."
        PIVPN_DEPS+=(linux-headers-amd64 wireguard-dkms)
      fi
      ;;
    "Ubuntu")
      echo "::: [INFO] Detectado entorno Ubuntu. Evaluando integración nativa del kernel..."
      PIVPN_DEPS+=(qrencode)
      if [[ "${builtin_wg}" -eq 0 ]]; then
        echo "::: [AVISO] Módulo WireGuard no integrado en el kernel base. Añadiendo cabeceras y soporte DKMS..."
        PIVPN_DEPS+=(linux-headers-generic wireguard-dkms)
      fi
      ;;
    "Alpine")
      echo "::: [INFO] Detectado entorno Alpine Linux. Preparando dependencias del stack minimalista..."
      PIVPN_DEPS+=(libqrencode)
      ;;
    *)
      echo "::: [AVISO] Plataforma no mapeada explícitamente (${platform}). Se procederá con el lote base genérico."
      ;;
  esac

  # ------------------------------------------------------------------------------
  # GESTIÓN DE RETROCOMPATIBILIDAD Y ANCLAJE DE REPOSITORIOS (APT PINNING)
  # ------------------------------------------------------------------------------
  # Si los paquetes de WireGuard no están consolidados nativamente en los índices del host,
  # se realiza un aprovisionamiento controlado apuntando a espejos estables de contingencia.
  if [[ "${platform}" == "Raspbian" || "${platform}" == "Debian" ]] \
    && [[ -z "${AVAILABLE_WIREGUARD}" ]]; then
    
    echo "::: [AVISO] El motor WireGuard no está disponible de forma nativa en los índices de paquetes activos."
    
    local repo_list="/etc/apt/sources.list.d/pivpn-bullseye-repo.list"
    local pref_file="/etc/apt/preferences.d/pivpn-limit-bullseye"

    if [[ "${platform}" == "Debian" ]]; then
      echo "::: [INFO] Registrando espejo de contingencia oficial: Debian Bullseye..."
      if ! echo "deb https://deb.debian.org/debian/ bullseye main" | ${SUDO} tee "${repo_list}" > /dev/null; then
        err "Fallo crítico de E/S: No se pudo escribir la lista de orígenes de paquetes en '${repo_list}'."
        exit 1
      fi
    else
      echo "::: [INFO] Registrando espejo de contingencia oficial: Raspbian Bullseye..."
      if ! echo "deb http://raspbian.raspberrypi.org/raspbian/ bullseye main" | ${SUDO} tee "${repo_list}" > /dev/null; then
        err "Fallo crítico de E/S: No se pudo escribir la lista de orígenes de paquetes en '${repo_list}'."
        exit 1
      fi
    fi

    # Imponer políticas de Apt-Pinning estratégicas para evitar la contaminación cruzada de paquetes globales
    echo "::: [INFO] Configurando directivas de Apt-Pinning para aislar el árbol de WireGuard..."
    if ! {
      printf 'Package: *\n'
      printf 'Pin: release n=bullseye\n'
      printf 'Pin-Priority: -1\n\n'
      printf 'Package: wireguard wireguard-dkms wireguard-tools\n'
      printf 'Pin: release n=bullseye\n'
      printf 'Pin-Priority: 100\n'
    } | ${SUDO} tee "${pref_file}" > /dev/null; then
      
      whiptail --backtitle "Asistente de Instalación PiVPN" \
               --title "Error de Configuración APT" \
               --ok-button "Aceptar" \
               --msgbox "Fallo de escritura en el almacenamiento local al intentar definir las prioridades del gestor de paquetes en:\n\n${pref_file}\n\nPor favor, comprueba los permisos del sistema de archivos o el espacio en disco." "${r:-14}" "${c:-72}"
      
      echo "::: [ERROR] No se pudieron consolidar las restricciones de prioridad (Apt-Pinning) en el host." >&2
      exit 1
    fi

    echo "::: [INFO] Sincronizando e indexando la nueva caché local del gestor de paquetes..."
    updatePackageCache
  fi

  # ------------------------------------------------------------------------------
  # INSTALACIÓN DEFINITIVA DEL LOGICIAL CRYPTO-NET
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Ejecutando el despliegue del lote de dependencias y herramientas..."
  if ! installDependentPackages PIVPN_DEPS[@]; then
    
    whiptail --backtitle "Asistente de Instalación PiVPN" \
             --title "Fallo en Despliegue de Dependencias" \
             --ok-button "Aceptar" \
             --msgbox "No se han podido descargar o procesar los paquetes requeridos por el sistema:\n\n${PIVPN_DEPS[*]}\n\nPor favor, verifica la conectividad WAN del servidor o la disponibilidad de los mirrors de la distribución." "${r:-14}" "${c:-72}"
    
    err "Fallo catastrófico: La instalación de componentes base de WireGuard ha sido cancelada."
    exit 1
  fi

  echo "::: [ÉXITO] El entorno tecnológico de WireGuard ha sido desplegado y verificado con éxito."
}

askCustomProto() {
  # ==============================================================================
  #       SELECCIÓN DEL PROTOCOLO DE LA CAPA DE TRANSPORTE (UDP / TCP)
  # ==============================================================================
  # Configura el método de transmisión de paquetes para el túnel. Fuerza UDP si
  # el motor seleccionado es WireGuard, permitiendo alternancia en OpenVPN.

  echo "::: [INFO] Evaluando requerimientos del protocolo de transporte..."

  # Normalizar el protocolo entrante a minúsculas preventivamente si ya existe
  if [[ -n "${pivpnPROTO}" ]]; then
    pivpnPROTO="${pivpnPROTO,,}"
  fi

  # GUARDiÁN CRÍTICO: WireGuard no admite TCP de forma nativa como transporte
  if [[ "${VPN}" == "wireguard" ]]; then
    echo "::: [INFO] Motor WireGuard detectado. Forzando el protocolo UDP mandatorio."
    pivpnPROTO="udp"

  # ------------------------------------------------------------------------------
  # MODO 1: INSTALACIÓN DESATENDIDA
  # ------------------------------------------------------------------------------
  elif [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${pivpnPROTO}" ]]; then
      echo "::: [AVISO] No se especificó protocolo de transporte. Usando 'udp' por defecto."
      pivpnPROTO="udp"
    else
      if [[ "${pivpnPROTO}" == "udp" || "${pivpnPROTO}" == "tcp" ]]; then
        echo "::: [INFO] Parámetro desatendido validado con éxito: Usando protocolo ${pivpnPROTO}."
      else
        err "Error de validación: El protocolo '${pivpnPROTO}' no es compatible. Opciones válidas: 'udp' o 'tcp'."
        exit 1
      fi
    fi

  # ------------------------------------------------------------------------------
  # MODO 2: INSTALACIÓN INTERACTIVA (ASISTIDA POR PERFIL ÓPTIMO)
  # ------------------------------------------------------------------------------
  elif [[ "${CUSTOMIZE:-1}" -eq 0 ]]; then
    # Si el usuario eligió la instalación rápida recomendada, se auto-asigna UDP
    if [[ "${VPN}" == "openvpn" ]]; then
      echo "::: [INFO] Aplicando perfil optimizado por defecto: Configurando OpenVPN sobre UDP."
      pivpnPROTO="udp"
    fi

  # ------------------------------------------------------------------------------
  # MODO 3: INSTALACIÓN INTERACTIVA (PERSONALIZACIÓN MANUAL)
  # ------------------------------------------------------------------------------
  else
    # Captura segura de la selección del usuario mediante menú radiolist
    if pivpnPROTO="$(whiptail \
      --backtitle "Configuración de Red - Asistente PiVPN" \
      --title "Selección de Protocolo VPN" \
      --ok-button "Aceptar" \
      --cancel-button "Cancelar" \
      --radiolist "Selecciona el protocolo de la capa de transporte para tu servidor VPN:\n\n• UDP (Altamente Recomendado): Ofrece la mayor velocidad de transferencia, latencia mínima y máxima eficiencia. Es el estándar ideal para streaming, túneles estables y uso general.\n• TCP: Diseñado únicamente si necesitas evadir inspecciones de red profundas o cortafuegos corporativos muy estrictos que bloqueen por completo el tráfico UDP de salida.\n\n(Usa las flechas para moverte, la barra espaciadora para marcar y pulsa Intro):" \
      "${r:-21}" "${c:-78}" 2 \
      "UDP" "Máximo rendimiento, velocidad y eficiencia" ON \
      "TCP" "Mayor capacidad de evasión en redes restrictivas" OFF \
      3>&1 1>&2 2>&3)"; then
      
      pivpnPROTO="${pivpnPROTO,,}"
      echo "::: [INFO] Protocolo de red seleccionado por el usuario: ${pivpnPROTO}"
    else
      echo "::: [AVISO] Cancelación detectada en el cuadro de diálogo. Abortando instalación de forma segura..." >&2
      exit 1
    fi
  fi

  # ------------------------------------------------------------------------------
  # PERSISTENCIA TRANSACCIONAL DE CONFIGURACIÓN
  # ------------------------------------------------------------------------------
  if ! echo "pivpnPROTO=${pivpnPROTO}" >> "${tempsetupVarsFile}"; then
    err "Fallo crítico de E/S: No se pudo volcar la directiva de transporte en '${tempsetupVarsFile}'."
    exit 1
  fi

  echo "::: [ÉXITO] Pila de transporte consolidada correctamente: ${pivpnPROTO^^}"
}

askCustomPort() {
  # ==============================================================================
  #         SELECCIÓN Y VALIDACIÓN DEL PUERTO DE ESCUCHA DEL SERVIDOR
  # ==============================================================================
  # Calcula el puerto predeterminado óptimo según el stack de red elegido y asigna
  # el puerto definitivo controlando el rango de red [1-65535] de forma segura.

  local default_port=51820
  local port_correct="false"
  local input_port

  echo "::: [INFO] Evaluando parámetros para la asignación del puerto de red..."

  # Determinar puerto por defecto de forma centralizada según el motor y protocolo
  if [[ "${VPN}" == "openvpn" ]]; then
    if [[ "${pivpnPROTO}" == "udp" ]]; then
      default_port=1194
    else
      default_port=443
    fi
  fi

  # ------------------------------------------------------------------------------
  # MODO 1: INSTALACIÓN DESATENDIDA
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${pivpnPORT}" ]]; then
      echo "::: [AVISO] No se especificó ningún puerto. Utilizando el valor por defecto de la pila: ${default_port}"
      pivpnPORT="${default_port}"
    else
      # Validar que el puerto inyectado por archivo cumpla el estándar RFC
      if [[ "${pivpnPORT}" =~ ^[0-9]+$ ]] && [[ "${pivpnPORT}" -ge 1 ]] && [[ "${pivpnPORT}" -le 65535 ]]; then
        echo "::: [INFO] Puerto desatendido validado con éxito: ${pivpnPORT}"
      else
        err "Error crítico: El puerto '${pivpnPORT}' especificado en la configuración desatendida no es válido (Rango estricto: 1-65535)."
        exit 1
      fi
    fi

  # ------------------------------------------------------------------------------
  # MODO 2: INSTALACIÓN INTERACTIVA (ASISTIDA POR CUADROS DE DIÁLOGO WHIPTAIL)
  # ------------------------------------------------------------------------------
  else
    until [[ "${port_correct}" == "true" ]]; do
      if input_port="$(whiptail \
        --backtitle "Configuración de Red - Asistente PiVPN" \
        --title "Puerto de Escucha (${VPN^^})" \
        --ok-button "Continuar" \
        --cancel-button "Cancelar" \
        --inputbox "Por defecto, tu servidor ${VPN^^} está configurado para escuchar en el puerto ${default_port}.\n\nSi deseas modificarlo (por ejemplo, para evadir restricciones de red o auditorías de puertos externas), introduce un nuevo valor numérico a continuación. De lo contrario, mantén el valor sugerido:" \
        "${r:-20}" "${c:-78}" "${default_port}" \
        3>&1 1>&2 2>&3)"; then

        # Validación estricta del rango de puertos TCP/UDP válidos
        if [[ "${input_port}" =~ ^[0-9]+$ ]] && [[ "${input_port}" -ge 1 ]] && [[ "${input_port}" -le 65535 ]]; then
          
          # Diálogo interactivo de confirmación explícita
          if whiptail \
            --backtitle "Configuración de Red - Asistente PiVPN" \
            --title "Confirmar Número de Puerto" \
            --yes-button "Sí, es correcto" \
            --no-button "No, modificar" \
            --yesno "¿Estás seguro de que deseas consolidar el siguiente puerto de escucha?\n\n• Puerto seleccionado: ${input_port}\n\nNota: Recuerda que una vez completada la instalación deberás abrir/redireccionar (Port Forwarding) este puerto en tu router hacia la dirección IP local de este servidor." \
            "${r:-16}" "${c:-76}"; then
            
            pivpnPORT="${input_port}"
            port_correct="true"
            echo "::: [INFO] Puerto confirmado por el usuario: ${pivpnPORT}"
          fi
        else
          # Alerta visual ante entradas alfanuméricas o fuera de rango
          whiptail \
            --backtitle "Error de Parámetro" \
            --title "Número de Puerto Inválido" \
            --ok-button "Regresar" \
            --msgbox "El valor introducido ('${input_port}') no corresponde a un puerto válido.\n\nPor favor, introduce un número entero comprendido estrictamente entre el rango 1 y 65535." \
            "${r:-14}" "${c:-72}"
        fi
      else
        echo "::: [AVISO] Cancelación detectada en el cuadro de diálogo. Abortando instalación de forma segura..." >&2
        exit 1
      fi
    done
  fi

  # ------------------------------------------------------------------------------
  # PERSISTENCIA TRANSACCIONAL DE CONFIGURACIÓN
  # ------------------------------------------------------------------------------
  if ! echo "pivpnPORT=${pivpnPORT}" >> "${tempsetupVarsFile}"; then
    err "Fallo crítico de E/S: No se pudo escribir la directiva del puerto en '${tempsetupVarsFile}'."
    exit 1
  fi

  echo "::: [ÉXITO] Puerto de escucha consolidado correctamente: ${pivpnPORT}"
}

setupPiholeDNS() {
  # ==============================================================================
  #       INTEGRACIÓN, CONFIGURACIÓN Y DESPLIEGUE DE DNS CON PI-HOLE
  # ==============================================================================
  # Enlaza la interfaz VPN con el motor dnsmasq/FTL de Pi-hole, genera el mapeo
  # local para la resolución '*.pivpn' y abre de forma segura los puertos de red
  # en la pila del cortafuegos activo (UFW o Netfilter/Iptables).

  local CORE_VERSION=""
  local hosts_file="/etc/pivpn/hosts.${VPN}"

  echo "::: [INFO] Iniciando el aprovisionamiento de la integración con Pi-hole DNS..."

  # 1. Configuración de hosts personalizados para resolución inversa dinámica
  echo "::: [INFO] Registrando ruta de hosts personalizados en el archivo de configuración de dnsmasq..."
  if ! echo "addn-hosts=${hosts_file}" | ${SUDO} tee "${dnsmasqConfig}" > /dev/null; then
    err "Fallo crítico de E/S: No se pudo escribir la directiva addn-hosts en '${dnsmasqConfig}'."
    exit 1
  fi

  echo "::: [INFO] Inicializando/limpiando el archivo de mapeo local en '${hosts_file}'..."
  if ! ${SUDO} bash -c "> ${hosts_file}"; then
    err "Fallo de permisos: No se pudo inicializar o truncar el archivo de hosts '${hosts_file}'."
    exit 1
  fi

  # 2. Determinación de la versión de Pi-hole instalada en el sistema de forma segura
  if [[ -f "${piholeVersions}" ]]; then
    # shellcheck disable=SC1090
    CORE_VERSION="$(source "${piholeVersions}" && echo "${CORE_VERSION}")"
    echo "::: [INFO] Versión de Pi-hole Core detectada en el host: ${CORE_VERSION:-Desconocida}"
  else
    echo "::: [AVISO] No se localizó el archivo '${piholeVersions}'. Asumiendo arquitectura heredada."
  fi

  # Evaluar si se está ejecutando Pi-hole v6 o posterior mediante ordenación semántica
  if [[ -n "${CORE_VERSION}" ]] && [ "$(echo -e "v6.0.0\n${CORE_VERSION}" | sort -V | head -n 1)" = "v6.0.0" ]; then
    echo "::: [INFO] Aplicando directivas modernas de escucha para Pi-hole v6+ (FTL-native)..."
    if ! ${SUDO} pihole-FTL --config dns.listeningMode LOCAL || ! ${SUDO} pihole-FTL --config misc.etc_dnsmasq_d true; then
      echo "::: [AVISO] Error al aplicar parámetros mediante pihole-FTL. Es posible que requiera un reinicio manual del servicio."
    fi
  else
    # Configurar Pi-hole (v5 o inferior) a "Escuchar en todas las interfaces, permitiendo consultas solo de la LAN y VPN"
    echo "::: [INFO] Aplicando directivas de escucha perimetral para Pi-hole v5 o inferior..."
    if ! ${SUDO} pihole -a -i local; then
      err "Error de configuración externa: El subcomando 'pihole -a -i local' falló en su ejecución."
      exit 1
    fi
  fi

  # 3. Asignación del Servidor DNS y volcado transaccional de variables
  pivpnDNS1="${vpnGw}"
  echo "::: [INFO] Vinculando la IP de la puerta de enlace VPN como el servidor DNS primario: ${pivpnDNS1}"

  if ! {
    echo "pivpnDNS1=${pivpnDNS1}"
    echo "pivpnDNS2=${pivpnDNS2}"
  } >> "${tempsetupVarsFile}"; then
    err "Fallo crítico de E/S: No se pudieron persistir las variables DNS en '${tempsetupVarsFile}'."
    exit 1
  fi

  # 4. Aprovisionamiento seguro de reglas de red en el Firewall activo
  if [[ "${USING_UFW:-0}" -eq 1 ]]; then
    echo "::: [INFO] Firewall UFW detectado. Insertando regla de entrada prioritaria para el puerto 53 (DNS)..."
    if ! ${SUDO} ufw insert 1 allow in on "${pivpnDEV}" to any port 53 from "${pivpnNET}/${subnetClass}" > /dev/null; then
      err "Error de Cortafuegos: UFW rechazó la inserción de la regla DNS en la interfaz '${pivpnDEV}'."
      exit 1
    fi
  else
    echo "::: [INFO] Firewall IPTables detectado. Inyectando regla Netfilter con marca de comentario..."
    if ! ${SUDO} iptables -I INPUT -i "${pivpnDEV}" -p udp --dport 53 -j ACCEPT -m comment --comment "pihole-DNS-rule"; then
      err "Error de Cortafuegos: Netfilter rechazó la regla IPTables en la cadena INPUT sobre la interfaz '${pivpnDEV}'."
      exit 1
    fi
  fi

  echo "::: [ÉXITO] La integración y securización de Pi-hole DNS se ha completado correctamente."
}

askClientDNS() {
  # ==============================================================================
  #         CONFIGURACIÓN Y ASIGNACIÓN DE LOS SERVIDORES DNS DE CLIENTE
  # ==============================================================================
  # Gestiona de forma automatizada o interactiva la inyección de resolutores de
  # nombres en la pila de red de los clientes VPN, mitigando fugas (DNS leaks).

  local dns_correct="false"
  local input_dns pivpnDNS

  echo "::: [INFO] Evaluando parámetros para la asignación del servicio DNS..."

  # ------------------------------------------------------------------------------
  # MODO 1: INSTALACIÓN DESATENDIDA
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    # Prioridad 1: Integración directa con Pi-hole local
    if [[ "${usePiholeDNS}" == 'true' ]] && command -v pihole > /dev/null; then
      echo "::: [INFO] Integración automatizada con Pi-hole local detectada y activa."
      setupPiholeDNS
      return
    
    # Prioridad 2: Normalización si solo existe el segundo resolutor
    elif [[ -z "${pivpnDNS1}" && -n "${pivpnDNS2}" ]]; then
      pivpnDNS1="${pivpnDNS2}"
      unset pivpnDNS2
    
    # Prioridad 3: Asignación por defecto en ausencia de parámetros (Quad9 seguro)
    elif [[ -z "${pivpnDNS1}" && -z "${pivpnDNS2}" ]]; then
      pivpnDNS1="9.9.9.9"
      pivpnDNS2="149.112.112.112"
      echo "::: [AVISO] Ningún proveedor DNS especificado. Auto-asignando Quad9 corporativo (${pivpnDNS1}, ${pivpnDNS2})."
    fi

    # Validación estricta de direccionamiento IP sobre parámetros desatendidos
    local invalid_unattended=0
    if ! validIP "${pivpnDNS1}"; then
      echo "::: [ERROR] El valor asignado a pivpnDNS1 ('${pivpnDNS1}') no es una dirección IP válida." >&2
      invalid_unattended=1
    fi
    if [[ -n "${pivpnDNS2}" ]] && ! validIP "${pivpnDNS2}"; then
      echo "::: [ERROR] El valor asignado a pivpnDNS2 ('${pivpnDNS2}') no es una dirección IP válida." >&2
      invalid_unattended=1
    fi

    if [[ "${invalid_unattended}" -ne 0 ]]; then
      err "Fallo de validación: Los parámetros DNS del archivo desatendido contienen errores sintácticos."
      exit 1
    fi

    echo "::: [INFO] Resolutores DNS desatendidos validados: ${pivpnDNS1} ${pivpnDNS2:-(Sin secundario)}"

  # ------------------------------------------------------------------------------
  # MODO 2: INSTALACIÓN INTERACTIVA (ASISTIDA POR PLAN DE RED)
  # ------------------------------------------------------------------------------
  else
    # Intercepción y acoplamiento dinámico con Pi-hole si coexiste en el host
    if command -v pihole > /dev/null; then
      if [[ "${usePiholeDNS}" == 'true' ]] || whiptail \
        --backtitle "Asistente de Configuración - PiVPN" \
        --title "Integración Detectada: Pi-hole" \
        --yes-button "Sí, integrarlos" \
        --no-button "No, usar otros" \
        --yesno "Se ha localizado una instancia activa de Pi-hole en este servidor.\n\n¿Deseas configurar Pi-hole como el servidor DNS primario de tus clientes VPN? Esto habilitará de forma automática el bloqueo perimetral de publicidad y malware en todos tus dispositivos móviles vinculados." \
        "${r:-16}" "${c:-78}"; then
        
        echo "::: [INFO] El usuario ha optado por la consolidación nativa con Pi-hole DNS."
        setupPiholeDNS
        return
      fi
    fi

    # Generación estructurada del menú radiolist principal de proveedores
    local -a DNSChoseCmd=(whiptail \
      --backtitle "Asistente de Configuración - PiVPN" \
      --title "Selección de Proveedor DNS" \
      --ok-button "Seleccionar" \
      --cancel-button "Cancelar" \
      --separate-output \
      --radiolist "Selecciona el servidor DNS que se inyectará en los perfiles de tus clientes VPN:\n\n(Mueve la selección con las flechas y marca tu opción con la barra espaciadora)\n\nSi deseas usar resolutores corporativos o locales privados que no estén en la lista, desplázate y selecciona 'Personalizado'." \
      "${r}" "${c}" 8)

    local -a DNSChooseOptions=(
      "Google" "Resolución global de alta velocidad" ON
      "CloudFlare" "Máxima privacidad y velocidad" OFF
      "OpenDNS" "Protección Web y estabilidad" OFF
      "Quad9" "Seguridad avanzada y antimalware" OFF
      "AdGuard" "Bloqueo publicidad y rastreadores" OFF
      "FamilyShield" "Filtro de protección parental" OFF
      "PiVPN-is-local-DNS" "AdGuard Home o Pihole propio" OFF
      "Personalizado" "Introducir manualmente DNS" OFF
    )

    if DNSchoices="$("${DNSChoseCmd[@]}" "${DNSChooseOptions[@]}" 2>&1 > /dev/tty)"; then
      if [[ "${DNSchoices}" != "Personalizado" ]]; then
        # Mapeo asociativo indexado para la resolución estática de proveedores estándar
        declare -A DNS_MAP=(
          ["Google"]="8.8.8.8 8.8.4.4"
          ["CloudFlare"]="1.1.1.1 1.0.0.1"
          ["OpenDNS"]="208.67.222.222 208.67.220.220"
          ["Quad9"]="9.9.9.9 149.112.112.112"
          ["AdGuard"]="94.140.14.14 94.140.15.15"
          ["FamilyShield"]="208.67.222.123 208.67.220.123"
          ["PiVPN-is-local-DNS"]="${vpnGw}"
        )
        pivpnDNS1=$(echo "${DNS_MAP["${DNSchoices}"]}" | awk '{print $1}')
        pivpnDNS2=$(echo "${DNS_MAP["${DNSchoices}"]}" | awk '{print $2}')
        echo "::: [INFO] Proveedor DNS seleccionado por el usuario: ${DNSchoices} (${pivpnDNS1} ${pivpnDNS2:-(Único)})"
      
      else
        # Bucle transaccional para la validación estricta de IPs personalizadas
        until [[ "${dns_correct}" == "true" ]]; do
          if pivpnDNS="$(whiptail \
            --backtitle "Asistente de Configuración - PiVPN" \
            --title "Servidores DNS Personalizados" \
            --ok-button "Validar" \
            --cancel-button "Cancelar" \
            --inputbox "Introduce las direcciones IP de tus servidores DNS preferidos separadas por una coma.\n\nEjemplo válido: 1.1.1.1, 9.9.9.9" \
            "${r}" "${c}" "" \
            3>&1 1>&2 2>&3)"; then

            # Normalización y extracción limpia eliminando espacios y tabulaciones cruzadas
            local dns_cleaned
            dns_cleaned="$(echo "${pivpnDNS}" | tr -d ' \t')"
            pivpnDNS1="${dns_cleaned%%,*}"
            pivpnDNS2="${dns_cleaned#*,}"
            [[ "${pivpnDNS2}" == "${pivpnDNS1}" ]] && pivpnDNS2="" # Evitar duplicación si no hay coma

            local check_fail="false"
            if ! validIP "${pivpnDNS1}" || [[ -z "${pivpnDNS1}" ]]; then
              check_fail="true"
            fi
            if [[ -n "${pivpnDNS2}" ]] && ! validIP "${pivpnDNS2}"; then
              check_fail="true"
            fi

            if [[ "${check_fail}" == "true" ]]; then
              whiptail \
                --backtitle "Asistente de Configuración - PiVPN" \
                --title "Error: Estructura IP Inválida" \
                --ok-button "Corregir datos" \
                --msgbox "Una o ambas direcciones IP proporcionadas no cumplen el formato estándar IPv4.\n\nDatos procesados:\n  • DNS Primario: ${pivpnDNS1:-(No detectado/Vacío)}\n  • DNS Secundario: ${pivpnDNS2:-(No detectado/Vacío)}\n\nPor favor, verifica la sintaxis e inténtalo de nuevo." \
                "${r}" "${c}"
            else
              # Diálogo interactivo de confirmación y cierre del bucle
              if whiptail \
                --backtitle "Asistente de Configuración - PiVPN" \
                --title "Confirmar Servidores DNS" \
                --yes-button "Sí, aplicar" \
                --no-button "No, modificar" \
                --yesno "¿Deseas fijar la siguiente configuración DNS personalizada para el túnel?\n\n• Servidor Primario: ${pivpnDNS1}\n• Servidor Secundario: ${pivpnDNS2:-(Ninguno reservado)}" \
                "${r}" "${c}"; then
                
                dns_correct="true"
                echo "::: [INFO] DNS personalizado confirmado por el usuario: Primario=${pivpnDNS1}, Secundario=${pivpnDNS2:-(Ninguno)}"
              fi
            fi
          else
            echo "::: [AVISO] Cancelación detectada en la entrada de DNS personalizado. Abortando..." >&2
            exit 1
          fi
        done
      fi
    else
      echo "::: [AVISO] Cancelación detectada en el menú de selección de DNS. Abortando instalación..." >&2
      exit 1
    fi
  fi

  # ------------------------------------------------------------------------------
  # PERSISTENCIA TRANSACCIONAL DE CONFIGURACIÓN
  # ------------------------------------------------------------------------------
  if ! {
    echo "pivpnDNS1=${pivpnDNS1}"
    echo "pivpnDNS2=${pivpnDNS2}"
  } >> "${tempsetupVarsFile}"; then
    err "Fallo crítico de E/S: No se pudieron persistir las variables DNS en '${tempsetupVarsFile}'."
    exit 1
  fi

  echo "::: [ÉXITO] Pila de resolución DNS de cliente consolidada y registrada correctamente."
}

# ==============================================================================
#  VERIFICACIÓN FORMAL DE SINTAXIS DE DOMINIO MEDIANTE EXPRESIÓN REGULAR (PCRE)
# ==============================================================================
# Valida si la cadena de entrada cumple estrictamente con las especificaciones
# del estándar RFC 1035 para nombres de dominio completos (FQDN).
validDomain() {
  local domain="${1}"
  local perl_regexp='(?=^.{4,253}$)'
  perl_regexp="${perl_regexp}(^(?:[a-zA-Z0-9](?:(?:[a-zA-Z0-9\-]){0,61}"
  perl_regexp="${perl_regexp}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$)"
  grep -qP "${perl_regexp}" <<< "${domain}"
}

# ==============================================================================
#         ASIGNACIÓN Y CONFIGURACIÓN DEL SUFIJO DE DOMINIO DE BÚSQUEDA
# ==============================================================================
# Permite al administrador inyectar un sufijo DNS personalizado (Search Domain)
# para la resolución nativa de hosts sin necesidad de especificar el FQDN.
askCustomDomain() {
  local domain_correct="false"
  local input_domain

  echo "::: [INFO] Evaluando requerimientos para el dominio de búsqueda personalizado..."

  # ------------------------------------------------------------------------------
  # MODO 1: INSTALACIÓN DESATENDIDA
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -n "${pivpnSEARCHDOMAIN}" ]]; then
      if validDomain "${pivpnSEARCHDOMAIN}"; then
        echo "::: [INFO] Validando dominio desatendido con éxito: ${pivpnSEARCHDOMAIN}"
      else
        err "Error de validación: El dominio de búsqueda '${pivpnSEARCHDOMAIN}' inyectado no es válido."
        exit 1
      fi
    else
      echo "::: [INFO] Omitiendo dominio de búsqueda personalizado por ausencia de parámetros."
    fi

  # ------------------------------------------------------------------------------
  # MODO 2: INSTALACIÓN INTERACTIVA (ASISTIDA POR PERFIL ÓPTIMO)
  # ------------------------------------------------------------------------------
  elif [[ "${CUSTOMIZE:-1}" -eq 0 ]]; then
    # Si el usuario seleccionó la instalación rápida guiada y el motor es OpenVPN, se hereda vacío
    if [[ "${VPN}" == "openvpn" ]]; then
      echo "::: [INFO] Aplicando perfil optimizado por defecto: Omitiendo dominio de búsqueda personalizado."
    fi

  # ------------------------------------------------------------------------------
  # MODO 3: INSTALACIÓN INTERACTIVA (PERSONALIZACIÓN MANUAL)
  # ------------------------------------------------------------------------------
  else
    if whiptail \
      --backtitle "Asistente de Configuración - PiVPN" \
  --title "Dominio de Búsqueda Personalizado" \
  --yes-button "Sí, configurar" \
  --no-button "Omitir" \
  --defaultno \
  --yesno "¿Deseas configurar un sufijo de dominio de búsqueda personalizado para los clientes?\n\n• ¿Para qué sirve?: Permite resolver nombres de tu red local usando solo el nombre corto del equipo (por ejemplo, escribir 'nas' en lugar de 'nas.mi-red.local').\n\n• Nota: Si no utilizas un esquema de nombres cortos dentro de tu red local, puedes omitirla con total seguridad." "${r}" "${c}"; then
      until [[ "${domain_correct}" == "true" ]]; do
        if input_domain="$(whiptail \
          --backtitle "Asistente de Configuración - PiVPN" \
          --title "Configurar Dominio Personalizado" \
          --ok-button "Continuar" \
          --cancel-button "Cancelar" \
          --inputbox "Introduce el sufijo de dominio personalizado que deseas asociar a la red VPN:\n\nEjemplo estándar: miempresa.local o mired.com" \
          "${r}" "${c}" \
          3>&1 1>&2 2>&3)"; then

          if validDomain "${input_domain}"; then
            # Diálogo interactivo de confirmación explícita
            if whiptail \
              --backtitle "Asistente de Configuración - PiVPN" \
              --title "Confirmar Dominio" \
              --yes-button "Sí, aplicar" \
              --no-button "No, modificar" \
              --yesno "¿Es correcta la nomenclatura del dominio introducido?\n\n• Dominio de búsqueda: ${input_domain}" \
              "${r}" "${c:}"; then
              
              pivpnSEARCHDOMAIN="${input_domain}"
              domain_correct="true"
              echo "::: [INFO] Dominio de búsqueda confirmado por el usuario: ${pivpnSEARCHDOMAIN}"
            fi
          else
            # Alerta visual ante sintaxis de dominio inválida según regex
            whiptail \
              --backtitle "Asistente de Configuración - PiVPN" \
              --title "Error: Estructura de Dominio Inválida" \
              --ok-button "Corregir sintaxis" \
              --msgbox "El texto introducido no cumple con las especificaciones del estándar RFC de nomenclatura de dominios.\n\nTexto procesado:\n  • Dominio: ${input_domain:-(Cadena vacía)}\n\nPor favor, verifica que no contenga caracteres especiales prohibidos ni espacios." \
              "${r}" "${c}"
          fi
        else
          echo "::: [AVISO] Cancelación detectada en la entrada del dominio. Abortando instalación..." >&2
          exit 1
        fi
      done
    else
      echo "::: [INFO] El usuario ha optado por omitir el sufijo de búsqueda personalizado."
      pivpnSEARCHDOMAIN=""
    fi
  fi

  # ------------------------------------------------------------------------------
  # PERSISTENCIA TRANSACCIONAL DE CONFIGURACIÓN
  # ------------------------------------------------------------------------------
  if ! echo "pivpnSEARCHDOMAIN=${pivpnSEARCHDOMAIN}" >> "${tempsetupVarsFile}"; then
    err "Fallo crítico de E/S: No se pudo escribir la directiva del dominio en '${tempsetupVarsFile}'."
    exit 1
  fi

  if [[ -n "${pivpnSEARCHDOMAIN}" ]]; then
    echo "::: [ÉXITO] Sufijo de búsqueda consolidado correctamente: ${pivpnSEARCHDOMAIN}"
  else
    echo "::: [ÉXITO] Finalizada la sección de dominio de búsqueda (Sin asignación)."
  fi
}

askPublicIPOrDNS() {
  # ==============================================================================
  #       SELECCIÓN DEL MÉTODO DE CONEXIÓN EXTERNA (IP PÚBLICA / DNS)
  # ==============================================================================
  # Determina el punto de acceso perimetral que usarán los clientes para negociar
  # el túnel VPN. Permite el uso directo de la IP WAN o de un FQDN/DDNS.

  local IPv4pub=""
  local dns_correct="false"
  local input_meth input_dns

  echo "::: [INFO] Detectando la dirección IP pública actual del servidor..."

  # 1. Obtención optimizada de la IP pública con mecanismos de contingencia (Failover)
  if ! IPv4pub="$(dig +short +time=3 +tries=1 myip.opendns.com @208.67.222.222 2>/dev/null)" || ! validIP "${IPv4pub}"; then
    echo "::: [AVISO] La resolución DNS mediante 'dig' falló o devolvió una IP no válida. Probando vía HTTPS..."
    
    if ! IPv4pub="$(curl -sSf --connect-timeout 4 https://checkip.amazonaws.com 2>/dev/null)" || ! validIP "${IPv4pub}"; then
      err "Error de conectividad: No se pudo determinar la dirección IP pública WAN del host. Verifica la conexión a Internet o los servidores DNS locales."
      exit 1
    fi
  fi

  echo "::: [INFO] Dirección IP pública WAN detectada correctamente: ${IPv4pub}"

  # ------------------------------------------------------------------------------
  # MODO 1: INSTALACIÓN DESATENDIDA
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${pivpnHOST}" ]]; then
      echo "::: [AVISO] No se especificó la variable HOST. Auto-asignando IP WAN detectada: ${IPv4pub}"
      pivpnHOST="${IPv4pub}"
    else
      if validIP "${pivpnHOST}"; then
        echo "::: [INFO] Parámetro desatendido validado con éxito (Estructura IP): ${pivpnHOST}"
      elif validDomain "${pivpnHOST}"; then
        echo "::: [INFO] Parámetro desatendido validado con éxito (Estructura FQDN): ${pivpnHOST}"
      else
        err "Error de validación: El valor HOST '${pivpnHOST}' del archivo de configuración no es una IP ni un FQDN válido."
        exit 1
      fi
    fi

  # ------------------------------------------------------------------------------
  # MODO 2: INSTALACIÓN INTERACTIVA (ASISTIDA POR PLAN DE ACCESO)
  # ------------------------------------------------------------------------------
  else
    if input_meth="$(whiptail \
      --backtitle "Asistente de Configuración - PiVPN" \
      --title "Punto de Acceso Externo" \
      --ok-button "Seleccionar" \
      --cancel-button "Cancelar" \
      --radiolist "Selecciona el método de direccionamiento que usarán tus perfiles de cliente para conectarse al servidor VPN desde el exterior:\n\n(Usa las flechas para moverte y la barra espaciadora para marcar tu opción)" \
      "${r:-16}" "${c:-78}" 2 \
      "${IPv4pub}" "Usar la dirección IP pública actual (Recomendado si es estática/fija)" ON \
      "DNS_Entry" "Usar un nombre de dominio completo o servicio DDNS (No-IP, DuckDNS, etc.)" OFF \
      3>&1 1>&2 2>&3)"; then

      if [[ "${input_meth}" == "${IPv4pub}" ]]; then
        pivpnHOST="${IPv4pub}"
        echo "::: [INFO] El usuario ha optado por usar el direccionamiento IP WAN directo: ${pivpnHOST}"
      else
        # Bucle optimizado de validación y confirmación de dominio lineal
        until [[ "${dns_correct}" == "true" ]]; do
          if input_dns="$(whiptail \
            --backtitle "Asistente de Configuración - PiVPN" \
            --title "Configuración de Dominio / DDNS" \
            --ok-button "Continuar" \
            --cancel-button "Cancelar" \
            --inputbox "Introduce el nombre de dominio público o la dirección de tu servicio DNS dinámico (DDNS) que apunta a tu red residencial o corporativa.\n\nEjemplo: miservidor.duckdns.org o vpn.miempresa.com" \
            "${r:-15}" "${c:-76}" "" \
            3>&1 1>&2 2>&3)"; then
            
            if validDomain "${input_dns}"; then
              # Diálogo de confirmación final dentro del mismo paso lógico
              if whiptail \
                --backtitle "Asistente de Configuración - PiVPN" \
                --title "Confirmar Nombre DNS" \
                --yes-button "Sí, es correcto" \
                --no-button "No, modificar" \
                --yesno "¿Deseas consolidar este nombre de dominio en los perfiles de conexión?\n\n• DNS / DDNS Público: ${input_dns}\n\nNota: Asegúrate de que el dominio apunte correctamente a tu IP pública WAN antes de conectar los clientes." \
                "${r:-15}" "${c:-74}"; then
                
                pivpnHOST="${input_dns}"
                dns_correct="true"
                echo "::: [INFO] Nombre de dominio confirmado por el usuario: ${pivpnHOST}"
              fi
            else
              # Alerta visual ante sintaxis errónea
              whiptail \
                --backtitle "Asistente de Configuración - PiVPN" \
                --title "Error: Sintaxis DNS Inválida" \
                --ok-button "Corregir entrada" \
                --msgbox "El texto introducido no cumple con el formato estándar de un nombre de dominio (FQDN).\n\nTexto detectado:\n  • Entrada: ${input_dns:-(Cadena vacía)}\n\nPor favor, verifica que no contenga esquemas (como http://), barras ni espacios." \
                "${r:-15}" "${c:-72}"
            fi
          else
            echo "::: [AVISO] Cancelación detectada en la entrada de dominio. Abortando instalación..." >&2
            exit 1
          fi
        done
      fi
    else
      echo "::: [AVISO] Cancelación detectada en el menú del método de conexión. Abortando..." >&2
      exit 1
    fi
  fi

  # ------------------------------------------------------------------------------
  # PERSISTENCIA TRANSACCIONAL DE CONFIGURACIÓN
  # ------------------------------------------------------------------------------
  if ! echo "pivpnHOST=${pivpnHOST}" >> "${tempsetupVarsFile}"; then
    err "Fallo crítico de E/S: No se pudo escribir la directiva del HOST en '${tempsetupVarsFile}'."
    exit 1
  fi

  echo "::: [ÉXITO] Parámetro de acceso externo consolidado correctamente: ${pivpnHOST}"
}

askEncryption() {
  # ==============================================================================
  #       CONFIGURACIÓN DE SEGURIDAD, MOTOR DE CIFRADO Y CERTIFICADOS
  # ==============================================================================
  # Define las directivas criptográficas del túnel OpenVPN, permitiendo elegir
  # entre la pila moderna ECDSA (Curvas Elípticas) o la tradicional RSA.

  local crypto_choice
  local menu_exit
  local -i check_fail=0

  # Inicialización estricta por defecto de variables auxiliares
  TWO_POINT_FIVE=${TWO_POINT_FIVE:-1}
  pivpnENCRYPT=${pivpnENCRYPT:-""}
  USE_PREDEFINED_DH_PARAM=0

  echo "::: [INFO] Iniciando el asistente para la selección de la arquitectura criptográfica..."

  # ------------------------------------------------------------------------------
  # MODO 1: INSTALACIÓN DESATENDIDA
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${TWO_POINT_FIVE}" ]] || [[ "${TWO_POINT_FIVE}" -eq 1 ]]; then
      TWO_POINT_FIVE=1
      echo "::: [INFO] Perfil desatendido: Forzando criptografía moderna de OpenVPN 2.5+ (ECDSA)."

      [[ -z "${pivpnENCRYPT}" ]] && pivpnENCRYPT=256

      if [[ "${pivpnENCRYPT}" -eq 256 || "${pivpnENCRYPT}" -eq 384 || "${pivpnENCRYPT}" -eq 521 ]]; then
        echo "::: [INFO] Validando longitud de clave ECDSA: ${pivpnENCRYPT} bits."
      else
        err "Error de validación: '${pivpnENCRYPT}' no es un tamaño de certificado ECDSA válido (Valores: 256, 384 o 521)."
        exit 1
      fi
    else
      TWO_POINT_FIVE=0
      echo "::: [INFO] Perfil desatendido: Forzando criptografía heredada (RSA)."

      [[ -z "${pivpnENCRYPT}" ]] && pivpnENCRYPT=2048

      if [[ "${pivpnENCRYPT}" -eq 2048 || "${pivpnENCRYPT}" -eq 3072 || "${pivpnENCRYPT}" -eq 4096 ]]; then
        echo "::: [INFO] Validando longitud de clave RSA: ${pivpnENCRYPT} bits."
      else
        err "Error de validación: '${pivpnENCRYPT}' no es un tamaño de certificado RSA válido (Valores: 2048, 3072 o 4096)."
        exit 1
      fi

      # Forzar parámetros DH predefinidos si no hay instrucción explícita
      [[ -z "${USE_PREDEFINED_DH_PARAM}" ]] && USE_PREDEFINED_DH_PARAM=1
      
      if [[ "${USE_PREDEFINED_DH_PARAM}" -eq 1 ]]; then
        echo "::: [INFO] Se utilizarán parámetros Diffie-Hellman estáticos estandarizados."
      else
        echo "::: [AVISO] Los parámetros Diffie-Hellman se generarán dinámicamente en el host local."
      fi
    fi

  # ------------------------------------------------------------------------------
  # MODO 2: INSTALACIÓN INTERACTIVA (PERFIL RÁPIDO GUIADO)
  # ------------------------------------------------------------------------------
  elif [[ "${CUSTOMIZE:-1}" -eq 0 ]]; then
    if [[ "${VPN}" == "openvpn" ]]; then
      echo "::: [INFO] Perfil guiado rápido: Aplicando configuración ECDSA estándar (256 bits)."
      TWO_POINT_FIVE=1
      pivpnENCRYPT=256
      USE_PREDEFINED_DH_PARAM=0
    fi

  # ------------------------------------------------------------------------------
  # MODO 3: INSTALACIÓN INTERACTIVA (PERSONALIZACIÓN MANUAL)
  # ------------------------------------------------------------------------------
  else
    # Pantalla 1: Selección del paradigma/algoritmo base
    whiptail \
      --backtitle "Asistente de Configuración - PiVPN" \
      --title "Selección del Motor de Cifrado" \
      --yes-button "Moderno (ECDSA)" \
      --no-button "Tradicional (RSA)" \
      --yesno "OpenVPN permite desplegar dos arquitecturas criptográficas distintas:\n\n• Perfil Moderno (ECDSA): Utiliza criptografía de Curvas Elípticas. Es drásticamente más rápido, consume menos CPU y genera certificados ligeros con seguridad máxima. Cifra además la cabecera mediante 'tls-crypt-v2'.\n• Perfil Tradicional (RSA): Garantiza retrocompatibilidad total con dispositivos u operating systems muy antiguos, requiriendo mayor cómputo y tiempo de inicialización.\n\nSe recomienda encarecidamente utilizar el perfil Moderno (ECDSA)." \
      "${r:-20}" "${c:-78}"
    
    crypto_choice="$?"

    # Control estricto del botón Cancelar / Tecla ESC en pantalla principal
    if [[ "${crypto_choice}" -eq 255 ]]; then
      echo "::: [AVISO] Cancelación o interrupción detectada en el menú criptográfico. Saliendo..." >&2
      exit 1
    fi

    if [[ "${crypto_choice}" -eq 0 ]]; then
      # --- RAMA INTERACTIVA: ECDSA ---
      TWO_POINT_FIVE=1
      USE_PREDEFINED_DH_PARAM=0 # Las curvas elípticas omiten los parámetros DH de factor primo

      pivpnENCRYPT="$(whiptail \
        --backtitle "Asistente de Configuración - PiVPN" \
        --title "Longitud de Clave ECDSA" \
        --ok-button "Seleccionar" \
        --cancel-button "Cancelar" \
        --radiolist "Selecciona el tamaño del certificado basado en curvas elípticas (ECDSA):\n\n(Usa las flechas para moverte y la barra espaciadora para marcar la opción)\n\nNota: Una clave elíptica de 256 bits provee la misma resistencia que una clave RSA de 3072 bits, reduciendo la latencia de conexión." \
        "${r:-18}" "${c:-78}" 3 \
        "256" "ECDSA de 256 bits (Balance idóneo velocidad/seguridad)" ON \
        "384" "ECDSA de 384 bits (Criptografía militar reforzada)" OFF \
        "521" "ECDSA de 521 bits (Máxima seguridad de grado gubernamental)" OFF \
        3>&1 1>&2 2>&3)"
      
      menu_exit="$?"
    else
      # --- RAMA INTERACTIVA: RSA ---
      TWO_POINT_FIVE=0

      pivpnENCRYPT="$(whiptail \
        --backtitle "Asistente de Configuración - PiVPN" \
        --title "Longitud de Clave RSA" \
        --ok-button "Seleccionar" \
        --cancel-button "Cancelar" \
        --radiolist "Selecciona el tamaño del certificado clásico RSA:\n\n[AVISO] Configurar claves superiores a 2048 bits incrementará significativamente el uso de CPU durante el handshake de los clientes." \
        "${r:-16}" "${c:-78}" 3 \
        "2048" "RSA de 2048 bits (Estándar comercial seguro y compatible)" ON \
        "3072" "RSA de 3072 bits (Seguridad avanzada a medio rendimiento)" OFF \
        "4096" "RSA de 4096 bits (Seguridad ultra alta / Procesamiento lento)" OFF \
        3>&1 1>&2 2>&3)"
      
      menu_exit="$?"
    fi

    # Validación de cancelación en los submenús radiolist
    if [[ "${menu_exit}" -ne 0 || -z "${pivpnENCRYPT}" ]]; then
      echo "::: [AVISO] Cancelación detectada en la selección de bits. Abortando instalación..." >&2
      exit 1
    fi

    # --- CONTROL DE INTERCAMBIO DE CLAVES DIFFIE-HELLMAN (Solo RSA) ---
    if [[ "${TWO_POINT_FIVE}" -eq 0 ]]; then
      if whiptail \
        --backtitle "Asistente de Configuración - PiVPN" \
        --title "Configuración de Parámetros Diffie-Hellman" \
        --yes-button "Usar Predefinidos" \
        --no-button "Generar Propios" \
        --yesno "La generación manual de parámetros Diffie-Hellman (DH) requiere un uso exhaustivo de la entropía del sistema y puede demorar horas en hardware limitado como la Raspberry Pi.\n\n¿Deseas utilizar los parámetros estándar precalculados y validados internacionalmente por la IETF (Recomendado)?\n\nSi prefieres obligar al host a calcular un grupo DH único a costa de tiempo de espera, selecciona 'Generar Propios'." \
        "${r:-20}" "${c:-78}"; then
        
        USE_PREDEFINED_DH_PARAM=1
        echo "::: [INFO] El usuario ha seleccionado parámetros DH predefinidos."
      else
        USE_PREDEFINED_DH_PARAM=0
        echo "::: [AVISO] El usuario ha optado por la generación matemática de parámetros DH en local."
      fi
    fi
  fi

  # ------------------------------------------------------------------------------
  # PERSISTENCIA TRANSACCIONAL CENTRALIZADA EN ALMACENAMIENTO SECUNDARIO
  # ------------------------------------------------------------------------------
  if ! {
    echo "TWO_POINT_FIVE=${TWO_POINT_FIVE}"
    echo "pivpnENCRYPT=${pivpnENCRYPT}"
    echo "USE_PREDEFINED_DH_PARAM=${USE_PREDEFINED_DH_PARAM}"
  } >> "${tempsetupVarsFile}"; then
    err "Fallo crítico de E/S: No se pudieron persistir los parámetros criptográficos en '${tempsetupVarsFile}'."
    exit 1
  fi

  echo "::: [ÉXITO] Arquitectura de cifrado consolidada correctamente (Algoritmo: $([[ "${TWO_POINT_FIVE}" -eq 1 ]] && echo "ECDSA" || echo "RSA"), Clave: ${pivpnENCRYPT} bits)."
}

confOpenVPN() {
  local sed_pattern file_pattern host_name NEW_UUID SERVER_NAME
  local OPENVPN_BACKUP CURRENT_UMASK ta_path tc_v2_path tc_v2_cmd_path
  local target_user template_file

  echo "::: [INFO] Iniciando la fase de configuración criptográfica de OpenVPN..."

  # Obtener el nombre de host existente de forma segura
  host_name="$(hostname -s 2>/dev/null || echo "pivpn-server")"

  # Mecanismo robusto de contingencia para la generación del UUID único del servidor
  if [[ -f /proc/sys/kernel/random/uuid ]]; then
    NEW_UUID="$(< /proc/sys/kernel/random/uuid)"
  elif command -v uuidgen &> /dev/null; then
    NEW_UUID="$(uuidgen)"
  else
    NEW_UUID="$(cat /dev/urandom | tr -dc 'a-f0-9' | fold -w 32 | head -n 1)"
  fi

  # Crear un identificador de servidor único e irreversible
  SERVER_NAME="${host_name}_${NEW_UUID}"
  echo "::: [INFO] Identificador único asignado al servidor: ${SERVER_NAME}"

  # Realizar copia de seguridad preventiva solo si existe una configuración previa
  if [[ -d /etc/openvpn ]]; then
    OPENVPN_BACKUP="openvpn_$(date +%Y-%m-%d-%H%M%S).tar.gz"
    echo "::: [INFO] Generando respaldo de la configuración anterior en /etc/${OPENVPN_BACKUP}..."
    CURRENT_UMASK="$(umask)"
    umask 0077
    if ${SUDO} tar -czf "/etc/${OPENVPN_BACKUP}" /etc/openvpn &> /dev/null; then
      echo "::: [ÉXITO] Respaldo de seguridad creado correctamente."
    else
      echo "::: [ADVERTENCIA] No se pudo procesar el empaquetado de respaldo en /etc/${OPENVPN_BACKUP}."
    fi
    umask "${CURRENT_UMASK}"
  else
    echo "::: [INFO] No se localizó ninguna jerarquía previa de OpenVPN. Omitiendo respaldo."
  fi

  echo "::: [INFO] Saneando el espacio de nombres y directorios del sistema..."
  if [[ -f /etc/openvpn/server.conf ]]; then
    ${SUDO} rm -f /etc/openvpn/server.conf
  fi

  if [[ -d /etc/openvpn/ccd ]]; then
    ${SUDO} rm -rf /etc/openvpn/ccd
  fi

  # Crear carpeta para almacenar las directivas específicas de asignación estática de IPs (CCD)
  if ! ${SUDO} mkdir -p /etc/openvpn/ccd; then
    err "Fallo de entorno: No se pudo crear el directorio operativo '/etc/openvpn/ccd'."
    exit 1
  fi

  # Remoción controlada de instancias antiguas de easy-rsa
  if [[ -d /etc/openvpn/easy-rsa/ ]]; then
    ${SUDO} rm -rf /etc/openvpn/easy-rsa/
  fi

  # Adquisición segura del paquete EasyRSA y desempaquetado transaccional en tubería
  echo "::: [INFO] Descargando componentes del motor de certificación EasyRSA (v${easyrsaVer:-3.x})..."
  if ! curl -sSfL "${easyrsaRel}" | ${SUDO} tar -xz --one-top-level=/etc/openvpn/easy-rsa --strip-components 1; then
    err "Error de red: Falló la descarga o la extracción de los binarios de EasyRSA desde: ${easyrsaRel}"
    exit 1
  fi

  if [[ ! -s /etc/openvpn/easy-rsa/easyrsa ]]; then
    err "Fallo de integridad: El ejecutable de EasyRSA no se encuentra operativo o se descargó vacío."
    exit 1
  fi

  # Asignación estricta de permisos de aislamiento del entorno PKI
  echo "::: [INFO] Aplicando restricciones de seguridad y propiedad sobre los binarios PKI..."
  if ! ${SUDO} chown -R root:root /etc/openvpn/easy-rsa; then
    err "No se pudo reasignar la propiedad del directorio /etc/openvpn/easy-rsa a root."
    exit 1
  fi

  if ! ${SUDO} mkdir -p /etc/openvpn/easy-rsa/pki || ! ${SUDO} chmod 700 /etc/openvpn/easy-rsa/pki; then
    err "Fallo de privilegios: No se pudo aislar criptográficamente el directorio pki."
    exit 1
  fi

  if ! cd /etc/openvpn/easy-rsa; then
    err "Fallo de ruta: No se pudo acceder al directorio raíz de EasyRSA."
    exit 1
  fi

  # Determinación de perfiles criptográficos según capacidades del servidor detectadas (OpenVPN v2.5+)
  if [[ "${TWO_POINT_FIVE}" -eq 1 ]]; then
    pivpnCERT="ec"
    pivpnTLSVERS="1.3"
    pivpnTLSPROT="tls-crypt-v2"
    echo "::: [INFO] Perfil optimizado detectado: Configurando suite OpenVPN 2.5+ (ECC / TLS 1.3 / TLS-Crypt-V2)."
  else
    pivpnCERT="rsa"
    pivpnTLSVERS="1.2"
    pivpnTLSPROT="tls-auth"
    echo "::: [INFO] Perfil estándar seleccionado: Configurando suite tradicional (RSA / TLS 1.2 / TLS-Auth)."
  fi

  # Inicialización formal de la infraestructura de clave pública borrando trazas previas
  echo "::: [INFO] Inicializando estructura PKI limpia con EasyRSA..."
  if ! ${SUDOE} ./easyrsa --batch init-pki &> /dev/null; then
    err "Fallo criptográfico: No se pudo inicializar la infraestructura PKI mediante EasyRSA."
    exit 1
  fi

  if ! ${SUDOE} cp vars.example pki/vars; then
    err "Fallo de E/S: No se pudo duplicar la plantilla de directivas 'vars.example'."
    exit 1
  fi

  # Inyección de parámetros específicos en el archivo de variables internas de la CA
  echo "::: [INFO] Aplicando algoritmo '${pivpnCERT^^}' en la matriz de variables..."
  if ! ${SUDOE} sed -i "s/#set_var EASYRSA_ALGO.*/set_var EASYRSA_ALGO ${pivpnCERT}/" pki/vars; then
    err "Error al escribir la directiva EASYRSA_ALGO."
    exit 1
  fi

  echo "::: [INFO] Fijando el ciclo de expiración de la lista de revocación (CRL) en 10 años (3650 días)..."
  if ! ${SUDOE} sed -i 's/#set_var EASYRSA_CRL_DAYS.*/set_var EASYRSA_CRL_DAYS 3650/' pki/vars; then
    err "Error al escribir la directiva EASYRSA_CRL_DAYS."
    exit 1
  fi

  if [[ "${pivpnENCRYPT}" -ge 2048 ]]; then
    echo "::: [INFO] Parametrizando tamaño de clave RSA personalizado a ${pivpnENCRYPT} bits..."
    sed_pattern="s/#set_var EASYRSA_KEY_SIZE.*/set_var EASYRSA_KEY_SIZE ${pivpnENCRYPT}/"
    if ! ${SUDOE} sed -i "${sed_pattern}" pki/vars; then
      err "Error al fijar la longitud de clave EASYRSA_KEY_SIZE."
      exit 1
    fi
  else
    # Mapeo estructurado para la asignación de curvas elípticas homólogas a la longitud elegida
    declare -A ECDSA_MAP=(
      ["256"]="prime256v1"
      ["384"]="secp384r1"
      ["521"]="secp521r1"
    )

    if [[ -n "${ECDSA_MAP["${pivpnENCRYPT}"]}" ]]; then
      echo "::: [INFO] Asignando identificador de curva elíptica: ${ECDSA_MAP["${pivpnENCRYPT}"]}"
      sed_pattern="s/#set_var EASYRSA_CURVE.*/set_var EASYRSA_CURVE ${ECDSA_MAP["${pivpnENCRYPT}"]}/"
      if ! ${SUDOE} sed -i "${sed_pattern}" pki/vars; then
        err "Error al fijar la curva elíptica EASYRSA_CURVE."
        exit 1
      fi
    else
      err "Configuración inválida: Longitud de cifrado de curva elíptica no homologada (${pivpnENCRYPT} bits)."
      exit 1
    fi
  fi

  # Compilación de la Autoridad de Certificación Raíz
  echo "::: [INFO] Generando la Autoridad de Certificación (CA) del servidor de manera automatizada..."
  if ! ${SUDOE} ./easyrsa --batch build-ca nopass &> /dev/null; then
    err "Fallo crítico: La compilación de la entidad de certificación raíz (build-ca) ha sido rechazada."
    exit 1
  fi
  echo "::: [ÉXITO] Autoridad de Certificación (CA) consolidada correctamente."

  # Control de diálogos interactivos informativos según el perfil criptográfico seleccionado
  if [[ "${pivpnCERT}" == "rsa" ]] && [[ "${USE_PREDEFINED_DH_PARAM}" -ne 1 ]]; then
    if [[ "${runUnattended}" == 'true' ]]; then
      echo "::: [PARAM] Modo desatendido: Procediendo con el cálculo de claves RSA, parámetros Diffie-Hellman y HMAC..."
    else
      whiptail \
        --backtitle "Asistente de Configuración - PiVPN" \
        --title "Generación de Llaves Criptográficas (RSA)" --ok-button "Continuar" \
        --msgbox "El asistente procederá a generar la clave de identidad del servidor, los parámetros estructurales Diffie-Hellman y la llave estática HMAC.\n\nEste proceso establece las capas iniciales de protección perimetral del túnel. Por favor, espera un momento mientras se completan las operaciones matemáticas." \
        "${r}" "${c}"
    fi
  elif [[ "${pivpnCERT}" == "ec" ]] || [[ "${pivpnCERT}" == "rsa" && "${USE_PREDEFINED_DH_PARAM}" -eq 1 ]]; then
    if [[ "${runUnattended}" == 'true' ]]; then
      echo "::: [PARAM] Modo desatendido: Procediendo con el cálculo de llaves elípticas y firma de seguridad HMAC..."
    else
      whiptail \
        --backtitle "Asistente de Configuración - PiVPN" \
        --title "Generación de Llaves Criptográficas (Cifrado Rápido)" --ok-button "Continuar" \
        --msgbox "El instalador procederá a generar las llaves de cifrado asimétrico del servidor y la firma de control HMAC.\n\nEste proceso es totalmente automático y garantiza que tu conexión remota sea robusta, privada y ágil. Por favor, espera mientras concluyen las tareas criptográficas." \
        "${r}" "${c}"
    fi
  fi

  # Construcción formal de la identidad del servidor firmada por nuestra CA
  echo "::: [INFO] Generando y firmando el par de certificados de intercambio del servidor OpenVPN..."
  if ! EASYRSA_CERT_EXPIRE=3650 ${SUDOE} ./easyrsa --batch build-server-full "${SERVER_NAME}" nopass &> /dev/null; then
    err "Fallo criptográfico: No se pudo generar la firma estructural del servidor mediante build-server-full."
    exit 1
  fi

  # Gestión y cálculo de parámetros Diffie-Hellman exclusivos para perfiles RSA
  if [[ "${pivpnCERT}" == "rsa" ]]; then
    if [[ "${USE_PREDEFINED_DH_PARAM}" -eq 1 ]]; then
      file_pattern="${pivpnFilesDir}/files/etc/openvpn/easy-rsa/pki/ffdhe${pivpnENCRYPT}.pem"
      echo "::: [INFO] Inyectando parámetros predefinidos optimizados de alta seguridad (RFC 7919 FFDHE${pivpnENCRYPT})..."
      if ! ${SUDOE} install -m 644 "${file_pattern}" "pki/dh${pivpnENCRYPT}.pem"; then
        err "Error de archivos: No se pudo copiar o validar el archivo FFDHE preestablecido en la ruta PKI."
        exit 1
      fi
    else
      echo "::: [INFO] Calculando nuevos parámetros de intercambio Diffie-Hellman (Este proceso puede tardar)..."
      if ! ${SUDOE} ./easyrsa gen-dh &> /dev/null; then
        err "Fallo de cómputo: No se pudieron generar los parámetros Diffie-Hellman de forma nativa."
        exit 1
      fi
      if ! ${SUDOE} mv pki/dh.pem "pki/dh${pivpnENCRYPT}.pem"; then
        err "Error de asignación: No se pudo renombrar el archivo estructurado dh.pem."
        exit 1
      fi
    fi
  fi

  # Generación de la llave simétrica estática adicional para mitigar escaneos de puertos y ataques DDoS
  if [[ "${TWO_POINT_FIVE}" -eq 1 ]]; then
    echo "::: [INFO] Generando firma criptográfica tls-crypt-v2 para protección del canal de control..."
    if ! ${SUDOE} mkdir -p "/etc/openvpn/easy-rsa/pki/tc-v2" || ! ${SUDOE} openvpn --genkey tls-crypt-v2-server pki/tc-v2/server.key; then
      err "Fallo criptográfico: No se pudo inicializar o compilar la directiva de seguridad tls-crypt-v2."
      exit 1
    fi
  else
    echo "::: [INFO] Generando firma criptográfica tls-auth (HMAC) estándar de protección..."
    if ! ${SUDOE} openvpn --genkey tls-auth pki/ta.key; then
      err "Fallo criptográfico: La creación del token estático tls-auth ha sido rechazada."
      exit 1
    fi
  fi

  # Generación e inicialización de la lista de revocación de certificados vacía (CRL)
  echo "::: [INFO] Inicializando una Lista de Revocación de Certificados (CRL) limpia..."
  if ! ${SUDOE} ./easyrsa gen-crl &> /dev/null || ! ${SUDOE} cp pki/crl.pem /etc/openvpn/crl.pem; then
    err "Fallo de publicación: No se pudo compilar o escribir la CRL en /etc/openvpn/crl.pem."
    exit 1
  fi

  # Verificación y aprovisionamiento seguro de las identidades de aislamiento del sistema (sandboxing)
  target_user="${ovpnUserGroup%:*}"
  echo "::: [INFO] Verificando la presencia de la identidad de confinamiento del demonio: '${target_user}'..."
  if ! getent passwd "${target_user}" &> /dev/null; then
    echo "::: [INFO] Cuenta no detectada. Creando usuario de sistema desprivilegiado '${target_user}'..."
    if [[ "${PLAT}" == 'Alpine' ]]; then
      if ! ${SUDOE} adduser -SD -h /var/lib/openvpn/ -s /sbin/nologin "${target_user}"; then
        err "No se pudo crear el usuario desprivilegiado en el ecosistema Alpine Linux."
        exit 1
      fi
    else
      if ! ${SUDOE} useradd --system --home /var/lib/openvpn/ --shell /usr/sbin/nologin "${target_user}"; then
        err "No se pudo estructurar el usuario de confinamiento seguro mediante useradd."
        exit 1
      fi
    fi
  fi

  if ! ${SUDOE} chown "${ovpnUserGroup}" /etc/openvpn/crl.pem; then
    err "Error de privilegios: No se pudo ceder el control de la CRL al grupo del servicio (${ovpnUserGroup})."
    exit 1
  fi

  # Despliegue formal del archivo de configuración maestro del servidor
  template_file="${pivpnFilesDir}/files/etc/openvpn/server_config.txt"
  echo "::: [INFO] Desplegando archivo maestro de configuración 'server.conf' desde la plantilla..."
  if [[ ! -f "${template_file}" ]]; then
    err "Fallo de origen: La plantilla base no se localizó en la ruta esperada: ${template_file}"
    exit 1
  fi

  if ! ${SUDO} install -m 644 "${template_file}" /etc/openvpn/server.conf; then
    err "Fallo de escritura: No se pudo instalar el archivo maestro en /etc/openvpn/server.conf."
    exit 1
  fi

  # ==============================================================================
  #                     FASE DE PARCHEO Y AJUSTE DE DIRECTIVAS
  # ==============================================================================
  echo "::: [INFO] Aplicando directivas DNS de cliente en la topología de red..."
  if ! ${SUDO} sed -i "0,/\(dhcp-option DNS \)/ s/\(dhcp-option DNS \).*/\1${pivpnDNS1}\"/" /etc/openvpn/server.conf; then
    err "Error al escribir el DNS primario."
    exit 1
  fi

  if [[ -z "${pivpnDNS2}" ]]; then
    # Limpieza de líneas sobrantes de DNS secundario si no fue configurado por el usuario
    ${SUDO} sed -i '/\(dhcp-option DNS \)/{n;N;d}' /etc/openvpn/server.conf
  else
    if ! ${SUDO} sed -i "0,/\(dhcp-option DNS \)/! s/\(dhcp-option DNS \).*/\1${pivpnDNS2}\"/" /etc/openvpn/server.conf; then
      err "Error al escribir el DNS secundario."
      exit 1
    fi
  fi

  # Integración condicional exclusiva para cifrado tls-crypt-v2
  if [[ "${pivpnTLSPROT}" == "tls-crypt-v2" ]]; then
    echo "::: [INFO] Configurando encapsulamiento y scripts de verificación de canal tls-crypt-v2..."
    ta_path="/etc/openvpn/easy-rsa/pki/ta.key"
    tc_v2_path="/etc/openvpn/easy-rsa/pki/tc-v2/server.key"
    tc_v2_cmd_path="/opt/pivpn/openvpn/TLSCryptV2Verify.sh"
    sed_pattern='s|tls-auth '"${ta_path}"' 0|tls-crypt-v2 '"${tc_v2_path}"'\ntls-crypt-v2-verify '"${tc_v2_cmd_path}"'\nscript-security 2|'
    if ! ${SUDO} sed -i "${sed_pattern}" /etc/openvpn/server.conf; then
      err "Error al parchear la directiva tls-crypt-v2 en server.conf."
      exit 1
    fi
  fi

  # Ajustes de parámetros específicos en base al algoritmo criptográfico seleccionado
  if [[ "${pivpnCERT}" == "ec" ]]; then
    echo "::: [INFO] Deshabilitando parámetros DH clásicos e inyectando curva elíptica: ${ECDSA_MAP["${pivpnENCRYPT}"]}"
    sed_pattern="s/\(dh \/etc\/openvpn\/easy-rsa\/pki\/dh\).*/dh none\necdh-curve ${ECDSA_MAP["${pivpnENCRYPT}"]}/"
    if ! ${SUDO} sed -i "${sed_pattern}" /etc/openvpn/server.conf; then
      err "Error al inyectar los parámetros ecdh-curve en server.conf."
      exit 1
    fi
  elif [[ "${pivpnCERT}" == "rsa" ]]; then
    echo "::: [INFO] Enlazando archivo maestro de parámetros Diffie-Hellman (${pivpnENCRYPT} bits)..."
    if ! ${SUDO} sed -i "s#\\(dh /etc/openvpn/easy-rsa/pki/dh\\).*#\\1${pivpnENCRYPT}.pem#" /etc/openvpn/server.conf; then
      err "Error al mapear el archivo dh.pem correspondiente en server.conf."
      exit 1
    fi
  fi

  # Endurecimiento de la capa de transporte limitando las suites permitidas exclusivamente a TLS v1.3
  if [[ "${pivpnTLSVERS}" == "1.3" ]]; then
    echo "::: [INFO] Elevando la versión de seguridad mínima permitida a TLS v1.3..."
    ${SUDO} sed -i "s|tls-version-min 1.2|tls-version-min 1.3|" "/etc/openvpn/server.conf"
    if [[ -f "${pivpnFilesDir}/files/etc/openvpn/easy-rsa/pki/Default.txt" ]]; then
      ${SUDO} sed -i "s|tls-version-min 1.2|tls-version-min 1.3|" "${pivpnFilesDir}/files/etc/openvpn/easy-rsa/pki/Default.txt"
    fi
  fi

  # Personalización de los direccionamientos, puertos y protocolos en el archivo operativo
  if [[ "${pivpnNET}" != "10.8.0.0" ]]; then
    echo "::: [INFO] Reasignando segmento de red virtual interna a: ${pivpnNET}..."
    ${SUDO} sed -i "s/10.8.0.0/${pivpnNET}/g" /etc/openvpn/server.conf
  fi

  if [[ "$(cidrToMask "${subnetClass}")" != "255.255.255.0" ]]; then
    echo "::: [INFO] Modificando máscara de subred asignada a: $(cidrToMask "${subnetClass}")..."
    ${SUDO} sed -i "s/255.255.255.0/$(cidrToMask "${subnetClass}")/g" /etc/openvpn/server.conf
  fi

  if [[ "${pivpnPORT}" -ne 1194 ]]; then
    echo "::: [INFO] Reasignando puerto de escucha del servidor a: ${pivpnPORT}..."
    ${SUDO} sed -i "s/1194/${pivpnPORT}/g" /etc/openvpn/server.conf
  fi

  if [[ "${pivpnPROTO}" != "udp" ]]; then
    echo "::: [INFO] Transmutando capa de transporte de red de UDP a TCP..."
    ${SUDO} sed -i "s/proto udp/proto tcp/g" /etc/openvpn/server.conf
  fi

  # Inyección del sufijo del dominio de búsqueda local si corresponde
  if [[ -n "${pivpnSEARCHDOMAIN}" ]]; then
    echo "::: [INFO] Registrando el sufijo de dominio de búsqueda DNS para los clientes: ${pivpnSEARCHDOMAIN}..."
    sed_pattern="0,/\\(.*dhcp-option.*\\)/s//push \"dhcp-option DOMAIN ${pivpnSEARCHDOMAIN}\" \\n&/"
    ${SUDO} sed -i "${sed_pattern}" /etc/openvpn/server.conf
  fi

  # Vinculación final del par de llaves generadas del servidor al archivo estructural
  echo "::: [INFO] Enlazando llaves criptográficas únicas y certificados firmados..."
  ${SUDO} sed -i "s#\\(key /etc/openvpn/easy-rsa/pki/private/\\).*#\\1${SERVER_NAME}.key#" /etc/openvpn/server.conf
  ${SUDO} sed -i "s#\\(cert /etc/openvpn/easy-rsa/pki/issued/\\).*#\\1${SERVER_NAME}.crt#" /etc/openvpn/server.conf

  # Integración adaptativa exclusiva para sistemas basados en OpenRC (Alpine Linux)
  if [[ "${PLAT}" == 'Alpine' ]]; then
    echo "::: [INFO] Entorno Alpine Linux detectado: Inicializando enlace simbólico adaptativo para OpenRC..."
    if ! ${SUDO} ln -sfT /etc/openvpn/server.conf /etc/openvpn/openvpn.conf > /dev/null; then
      echo "::: [ADVERTENCIA] No se pudo generar el enlace simbólico adaptativo en /etc/openvpn/openvpn.conf."
    fi
  fi

  echo "::: [ÉXITO] Arquitectura estructural e identidades de OpenVPN consolidadas de forma exitosa."
}

confOVPN() {
  # TRAZABILIDAD: Registro de inicio de la configuración de OpenVPN
  echo "::: [INFO] Iniciando la configuración de la plantilla base para clientes OpenVPN..."

  local src_template="${pivpnFilesDir}/files/etc/openvpn/easy-rsa/pki/Default.txt"
  local dest_template="/etc/openvpn/easy-rsa/pki/Default.txt"

  # VALIDACIÓN: Verificar la existencia del archivo de plantilla de origen
  if [[ ! -f "${src_template}" ]]; then
    err "Archivo de origen de la plantilla no encontrado en: '${src_template}'"
    exit 1
  fi

  # ESTRUCTURA: Garantizar la presencia del árbol de directorios de destino en el sistema
  if ! ${SUDO} mkdir -p "/etc/openvpn/easy-rsa/pki"; then
    err "No se pudo crear el directorio de destino requerido para la infraestructura PKI."
    exit 1
  fi

  # DESPLIEGUE: Instalar el archivo de configuración base con permisos restrictivos estándar
  if ! ${SUDO} install -m 644 "${src_template}" "${dest_template}"; then
    err "Fallo crítico al desplegar la plantilla base en '${dest_template}'."
    exit 1
  fi

  # CONFIGURACIÓN: Inyección dinámica del host o IP de conexión WAN (usando delimitador alternativo seguro)
  echo "::: [INFO] Asignando dirección IP pública o nombre de host ('${pivpnHOST}') en la plantilla..."
  if ! ${SUDO} sed -i "s|IPv4pub|${pivpnHOST}|" "${dest_template}"; then
    err "Fallo al configurar el Host de acceso WAN en la plantilla del cliente."
    exit 1
  fi

  # CONFIGURACIÓN: Adaptación del puerto de red si difiere del estándar oficial (1194)
  if [[ "${pivpnPORT}" -ne 1194 ]]; then
    echo "::: [INFO] Puerto personalizado detectado. Reasignando de 1194 al puerto: ${pivpnPORT}"
    if ! ${SUDO} sed -i "s|1194|${pivpnPORT}|g" "${dest_template}"; then
      err "Fallo al aplicar el puerto personalizado en la plantilla del cliente."
      exit 1
    fi
  fi

  # CONFIGURACIÓN: Reasignación del protocolo de transporte si se seleccionó TCP sobre UDP
  if [[ "${pivpnPROTO}" != "udp" ]]; then
    echo "::: [INFO] Protocolo alternativo detectado. Cambiando transporte por defecto a: ${pivpnPROTO}"
    if ! ${SUDO} sed -i "s|proto udp|proto tcp|g" "${dest_template}"; then
      err "Fallo al aplicar el protocolo de transporte TCP en la plantilla del cliente."
      exit 1
    fi
  fi

  # SEGURIDAD: Fortalecer la integridad del túnel verificando el identificador único del servidor (Server Name)
  echo "::: [INFO] Configurando el identificador seguro de la instancia del servidor ('${SERVER_NAME}')..."
  if ! ${SUDO} sed -i "s|SRVRNAME|${SERVER_NAME}|" "${dest_template}"; then
    err "Fallo al inyectar la firma identificadora del servidor en la plantilla."
    exit 1
  fi

  # COMPATIBILIDAD: Depuración de directivas heredadas según el nivel de cifrado de control TLS elegido
  if [[ "${pivpnTLSPROT}" == "tls-crypt-v2" ]]; then
    echo "::: [INFO] Protocolo tls-crypt-v2 activo. Removiendo directivas de dirección de clave redundantes..."
    if ! ${SUDO} sed -i "/key-direction 1/d" "${dest_template}"; then
      err "Fallo al realizar el saneamiento de directivas TLSv2 en la plantilla."
      exit 1
    fi
  fi

  echo "::: [ÉXITO] Plantilla de configuración base de OpenVPN consolidada correctamente."
}

confWireGuard() {
  # TRAZABILIDAD: Registro inicial del proceso de aprovisionamiento de WireGuard
  echo "::: [INFO] Iniciando el despliegue y aprovisionamiento del núcleo del motor WireGuard..."

  # COMPATIBILIDAD: Adaptación e instalación de scripts de servicio según la distribución destino
  if [[ "${PLAT}" == 'Alpine' ]]; then
    echo '::: [INFO] Arquitectura Alpine Linux identificada. Desplegando unidad de inicio OpenRC wg-quick...'
    if ! ${SUDO} install -m 0755 "${pivpnFilesDir}/files/etc/init.d/wg-quick" /etc/init.d/wg-quick; then
      err "No se pudo instalar el script de servicio wg-quick para el sistema de inicio de Alpine."
      exit 1
    fi
  else
    # Soporte de recargas en caliente para sistemas systemd antiguos (ej. Ubuntu 20.04 sin ExecReload nativo)
    if ! grep -q 'ExecReload' /lib/systemd/system/wg-quick@.service 2>/dev/null; then
      local wireguard_service_path
      wireguard_service_path="${pivpnFilesDir}/files/etc/systemd/system/wg-quick@.service.d/override.conf"
      
      echo "::: [INFO] Adaptando la unidad de systemd wg-quick con directivas ExecReload adicionales..."
      if ! ${SUDO} install -Dm 644 "${wireguard_service_path}" /etc/systemd/system/wg-quick@.service.d/override.conf; then
        err "No se pudo inyectar el archivo de anulación de configuración para systemd."
        exit 1
      fi
      
      if ! ${SUDO} systemctl daemon-reload; then
        err "Fallo crítico al actualizar la caché de unidades del gestor systemctl."
        exit 1
      fi
    fi
  fi

  # RESPALDO: Inspección defensiva de configuraciones previas para evitar pérdidas de perfiles históricos
  if [[ -d /etc/wireguard ]]; then
    # OPTIMIZACIÓN: Comprobación rápida y limpia de contenidos evitando bifurcaciones pesadas en consola
    if [[ -n "$(${SUDO} find /etc/wireguard -mindepth 1 -print -quit 2>/dev/null)" ]]; then
      local WIREGUARD_BACKUP="wireguard_$(date +%Y-%m-%d-%H%M%S).tar.gz"
      echo "::: [AVISO] Se detectaron archivos existentes. Generando respaldo de seguridad en /etc/${WIREGUARD_BACKUP}..."
      
      local CURRENT_UMASK
      CURRENT_UMASK="$(umask)"
      umask 0077
      if ${SUDO} tar -czf "/etc/${WIREGUARD_BACKUP}" /etc/wireguard &> /dev/null; then
        ${SUDO} chmod 600 "/etc/${WIREGUARD_BACKUP}"
        echo "::: [INFO] Copia de respaldo comprimida y asegurada correctamente bajo privilegios de root."
      else
        echo "::: [ADVERTENCIA] No se pudo consolidar la compresión del directorio histórico de WireGuard."
      fi
      umask "${CURRENT_UMASK}"
    fi

    if [[ -f /etc/wireguard/wg0.conf ]]; then
      echo "::: [INFO] Removiendo archivo de interfaz principal wg0.conf heredado..."
      ${SUDO} rm -f /etc/wireguard/wg0.conf
    fi
  else
    echo "::: [INFO] Creando el directorio base /etc/wireguard en el sistema anfitrión..."
    if ! ${SUDO} mkdir -p /etc/wireguard; then
      err "Incapacidad de E/S al inicializar el directorio maestro '/etc/wireguard'."
      exit 1
    fi
  fi

  # SEGURIDAD: Restricción estricta de acceso al directorio maestro únicamente al usuario administrador (root)
  if ! ${SUDO} chown root:root /etc/wireguard || ! ${SUDO} chmod 700 /etc/wireguard; then
    err "No se pudieron establecer las políticas de permisos restrictivos de privacidad en /etc/wireguard."
    exit 1
  fi

  # INTERFAZ DE USUARIO: Flujo de comunicación visual interactivo o reporte CLI desatendido
  if [[ "${runUnattended}" == 'true' ]]; then
    echo "::: [INFO] Modo desatendido activo. Procediendo a calcular el par de claves simétricas del servidor..."
  else
    whiptail \
      --backtitle "Asistente de Instalación PiVPN" \
      --title "Generación de Llaves Criptográficas" \
      --ok-button "Continuar" \
      --msgbox "El asistente procederá en este momento a calcular y generar de forma segura las claves de cifrado asimétrico del servidor WireGuard." \
      "${r}" \
      "${c}"
  fi

  # SANEAMIENTO: Limpieza integral de subdirectorios para dar espacio a un nuevo despliegue limpio
  echo "::: [INFO] Saneando directorios internos e índices de clientes..."
  ${SUDO} rm -rf /etc/wireguard/configs
  ${SUDO} rm -rf /etc/wireguard/keys

  if ! ${SUDO} mkdir -p /etc/wireguard/configs /etc/wireguard/keys; then
    err "Fallo crítico de E/S al estructurar los subdirectorios internos de claves y perfiles."
    exit 1
  fi

  if ! ${SUDO} touch /etc/wireguard/configs/clients.txt; then
    err "Fallo al inicializar el índice plano de registro de clientes 'clients.txt'."
    exit 1
  fi

  # CRIPTOGRAFÍA: Generación del par de claves del servidor mediante sus utilidades binarias directas
  echo "::: [INFO] Generando clave privada del servidor y derivando su correspondiente clave pública..."
  if ! (wg genkey | ${SUDO} tee /etc/wireguard/keys/server_priv &> /dev/null); then
    err "Fallo crítico de seguridad al procesar la generación de la clave privada ('wg genkey')."
    exit 1
  fi

  if ! (${SUDO} cat /etc/wireguard/keys/server_priv | wg pubkey | ${SUDO} tee /etc/wireguard/keys/server_pub &> /dev/null); then
    err "Fallo crítico de seguridad al procesar la derivación de la clave pública ('wg pubkey')."
    exit 1
  fi

  # OPTIMIZACIÓN: Almacenar la clave en una variable local para evitar subprocesos 'cat' dentro del bloque de texto
  local server_priv_key
  server_priv_key="$(${SUDO} cat /etc/wireguard/keys/server_priv 2>/dev/null)"
  if [[ -z "${server_priv_key}" ]]; then
    err "Error de lectura: La clave privada generada no se pudo extraer o se encuentra vacía."
    exit 1
  fi

  # CONSTRUCCIÓN: Escritura transaccional protegida de la interfaz de red primaria de WireGuard
  echo "::: [INFO] Escribiendo directivas de red y parámetros de rendimiento en '/etc/wireguard/wg0.conf'..."
  if ! {
    echo '[Interface]'
    echo "PrivateKey = ${server_priv_key}"
    echo -n "Address = ${vpnGw}/${subnetClass}"

    if [[ "${pivpnenableipv6}" -eq 1 ]]; then
      echo ",${vpnGwv6}/${subnetClassv6}"
    else
      echo
    fi

    echo "MTU = ${pivpnMTU}"
    echo "ListenPort = ${pivpnPORT}"
  } | ${SUDO} tee /etc/wireguard/wg0.conf &> /dev/null; then
    err "Fallo crítico al guardar los parámetros de red de la interfaz principal en el archivo wg0.conf."
    exit 1
  fi

  echo "::: [ÉXITO] Configuración e interfaz del servidor WireGuard creadas con éxito."
}

confNetwork() {
  # TRAZABILIDAD: Registro de inicio de la optimización y enrutamiento de red
  echo "::: [INFO] Configurando el subsistema de red y políticas de enrutamiento..."

  # PARÁMETROS DEL NÚCLEO: Habilitar el reenvío de tráfico (Forwarding) IPv4 de forma persistente
  echo "::: [INFO] Habilitando el reenvío de paquetes de red IPv4 (IP Forwarding)..."
  if ! echo 'net.ipv4.ip_forward=1' | ${SUDO} tee /etc/sysctl.d/99-pivpn.conf > /dev/null; then
    err "Fallo crítico de E/S: No se pudo escribir la directiva de reenvío IPv4 en sysctl."
    exit 1
  fi

  # PARÁMETROS DEL NÚCLEO: Configuración condicional para pilas IPv6
  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    echo "::: [INFO] Configuración IPv6 activa. Habilitando forwarding e instrumentación RA para la interfaz '${IPv6dev}'..."
    if ! {
      echo "net.ipv6.conf.all.forwarding=1"
      echo "net.ipv6.conf.${IPv6dev}.accept_ra=2"
    } | ${SUDO} tee -a /etc/sysctl.d/99-pivpn.conf > /dev/null; then
      err "Fallo crítico de E/S: No se pudieron consolidar las directivas de reenvío IPv6."
      exit 1
    fi
  fi

  # APLICACIÓN: Forzar la carga inmediata de los parámetros del cortafuegos del núcleo sin reiniciar
  echo "::: [INFO] Aplicando modificaciones dinámicas de sysctl al kernel..."
  ${SUDO} sysctl -p /etc/sysctl.d/99-pivpn.conf > /dev/null 2>&1

  # COMPATIBILIDAD: Persistencia del gestor de red en distribuciones basadas en Alpine Linux
  if [[ "${PLAT}" == 'Alpine' ]]; then
    echo "::: [INFO] Arquitectura Alpine Linux detectada. Asegurando persistencia del servicio sysctl..."
    ${SUDO} rc-update add sysctl > /dev/null 2>&1
  fi

  # ==========================================================================
  # INTEGRACIÓN CON UNCOMPLICATED FIREWALL (UFW)
  # ==========================================================================
  if [[ "${USING_UFW}" -eq 1 ]]; then
    echo "::: [INFO] Cortafuegos UFW (Uncomplicated Firewall) activo detectado en el sistema anfitrión."
    echo "::: [INFO] Preparando e inyectando directivas de enmascaramiento de red..."

    # VALIDACIÓN DEFENSIVA: Verificar la integridad del archivo de reglas IPv4 antes de operar
    if [[ -s /etc/ufw/before.rules ]]; then
      if ! ${SUDO} cp -f /etc/ufw/before.rules /etc/ufw/before.rules.pre-pivpn; then
        err "No se pudo generar la copia de seguridad de las reglas originales de UFW (/etc/ufw/before.rules)."
        exit 1
      fi
    else
      err "Fallo de validación: El archivo crítico de configuración '/etc/ufw/before.rules' está vacío o corrupto."
      exit 1
    fi

    # VALIDACIÓN DEFENSIVA: Verificar la integridad del archivo de reglas IPv6 si aplica
    if [[ -s /etc/ufw/before6.rules ]]; then
      if ! ${SUDO} cp -f /etc/ufw/before6.rules /etc/ufw/before6.rules.pre-pivpn; then
        err "No se pudo generar la copia de seguridad de las reglas IPv6 originales de UFW (/etc/ufw/before6.rules)."
        exit 1
      fi
    else
      err "Fallo de validación: El archivo crítico de configuración IPv6 '/etc/ufw/before6.rules' está vacío o corrupto."
      exit 1
    fi

    local sed_pattern

    # INYECCIÓN NAT IPv4: Determinar si ya existe una sección declarada de Tabla NAT en UFW
    if ${SUDO} grep -q "*nat" /etc/ufw/before.rules; then
      # Insertar regla dentro de la sección NAT preexistente si no ha sido dada de alta antes
      if ! ${SUDO} grep -q "${VPN}-nat-rule" /etc/ufw/before.rules; then
        echo "::: [INFO] Añadiendo regla MASQUERADE dentro del bloque de Tabla NAT existente (IPv4)..."
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
      # Inicializar bloque completo de Tabla NAT e inyectar parámetros de enmascaramiento
      echo "::: [INFO] Inicializando sección *nat dedicada e inyectando regla MASQUERADE (IPv4)..."
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

    # INYECCIÓN NAT IPv6: Ejecutar la misma lógica procedimental sobre la pila IPv6 si está habilitada
    if [[ "${pivpnenableipv6}" -eq 1 ]]; then
      if ${SUDO} grep -q "*nat" /etc/ufw/before6.rules; then
        if ! ${SUDO} grep -q "${VPN}-nat-rule" /etc/ufw/before6.rules; then
          echo "::: [INFO] Añadiendo regla MASQUERADE dentro del bloque de Tabla NAT existente (IPv6)..."
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
        echo "::: [INFO] Inicializando sección *nat dedicada e inyectando regla MASQUERADE (IPv6)..."
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

    # ORQUESTACIÓN DE REGLAS INTERNAS: Inserción prioritarias en la cabecera de las cadenas de UFW
    echo "::: [INFO] Evaluando políticas de prioridad. Insertando excepciones de tráfico al inicio de las cadenas de UFW..."
    if ${SUDO} ufw status numbered | grep -E "\[.[0-9]{1}\]" > /dev/null; then
      echo "::: [INFO] Aplicando regla de entrada de puerto para la VPN (${pivpnPORT}/${pivpnPROTO})..."
      ${SUDO} ufw insert 1 allow "${pivpnPORT}/${pivpnPROTO}" comment "allow-${VPN}" > /dev/null

      echo "::: [INFO] Aplicando regla de reenvío de tráfico de salida WAN (Forward IPv4)..."
      ${SUDO} ufw route insert 1 allow in on "${pivpnDEV}" from "${pivpnNET}/${subnetClass}" out on "${IPv4dev}" to any > /dev/null

      if [[ "${pivpnenableipv6}" -eq 1 ]]; then
        echo "::: [INFO] Aplicando regla de reenvío de tráfico de salida WAN (Forward IPv6)..."
        ${SUDO} ufw route insert 1 allow in on "${pivpnDEV}" from "${pivpnNETv6}/${subnetClassv6}" out on "${IPv6dev}" to any > /dev/null
      fi
    fi

    # REINICIO DEL CORTAFUEGOS: Aplicar de forma efectiva las directivas en caliente
    echo "::: [INFO] Recargando el motor y las directivas de UFW..."
    if ${SUDO} ufw reload > /dev/null; then
      echo "::: [ÉXITO] Configuración de red y reglas sobre UFW completada con éxito."
    else
      echo "::: [AVISO] UFW devolvió advertencias o códigos no estándar durante la recarga."
    fi
    
    # Interfaz visual de cierre de sección para instalaciones interactivas
    if [[ "${runUnattended}" != 'true' ]]; then
      whiptail \
        --backtitle "Asistente de Instalación PiVPN" \
        --title "Configuración Cortafuegos (UFW)" \
        --ok-button "Continuar" \
        --msgbox "Las directivas de red, enmascaramiento NAT y permisos de reenvío de paquetes han sido integrados con éxito en la configuración activa de UFW." \
        "${r}" "${c}"
    fi
    return
  fi

  # ==========================================================================
  # CONFIGURACIÓN DIRECTA MEDIANTE IPTABLES / IP6TABLES
  # ==========================================================================
  echo "::: [INFO] UFW inactivo o no detectado. Gestionando la topología mediante la suite nativa 'iptables'..."

  # REGLA NAT NATIVA (IPv4): Asegurar persistencia de la firma de enmascaramiento
  if ! ${SUDO} iptables -t nat -S | grep -q "${VPN}-nat-rule"; then
    echo "::: [INFO] Inyectando regla de enmascaramiento dinámico MASQUERADE (iptables IPv4)..."
    ${SUDO} iptables -t nat -I POSTROUTING -s "${pivpnNET}/${subnetClass}" -o "${IPv4dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule"
  fi

  # REGLA NAT NATIVA (IPv6): Aplicación paralela sobre la pila de red correspondiente
  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    if ! ${SUDO} ip6tables -t nat -S | grep -q "${VPN}-nat-rule"; then
      echo "::: [INFO] Inyectando regla de enmascaramiento dinámico MASQUERADE (ip6tables IPv6)..."
      ${SUDO} ip6tables -t nat -I POSTROUTING -s "${pivpnNETv6}/${subnetClassv6}" -o "${IPv6dev}" -j MASQUERADE -m comment --comment "${VPN}-nat-rule"
    fi
  fi

  # MÉTRICAS Y ANÁLISIS DEFENSIVO: Auditoría de las políticas por defecto del sistema anfitrión
  echo "::: [INFO] Analizando el recuento de reglas previas y directivas estructurales de las cadenas INPUT y FORWARD..."
  INPUT_RULES_COUNT="$(${SUDO} iptables -S INPUT | grep -vcE '(^-P|ufw-)')"
  FORWARD_RULES_COUNT="$(${SUDO} iptables -S FORWARD | grep -vcE '(^-P|ufw-)')"
  INPUT_POLICY="$(${SUDO} iptables -S INPUT | grep '^-P' | awk '{print $3}')"
  FORWARD_POLICY="$(${SUDO} iptables -S FORWARD | grep '^-P' | awk '{print $3}')"

  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    INPUT_RULES_COUNTv6="$(${SUDO} ip6tables -S INPUT | grep -vcE '(^-P|ufw-)')"
    FORWARD_RULES_COUNTv6="$(${SUDO} ip6tables -S FORWARD | grep -vcE '(^-P|ufw-)')"
    INPUT_POLICYv6="$(${SUDO} ip6tables -S INPUT | grep '^-P' | awk '{print $3}')"
    FORWARD_POLICYv6="$(${SUDO} ip6tables -S FORWARD | grep '^-P' | awk '{print $3}')"
  fi

  # DETERMINACIÓN DE APERTURA (INPUT IPv4): Permitir la conexión entrante al puerto del servidor VPN si el tráfico está restringido
  if [[ "${INPUT_RULES_COUNT}" -ne 0 ]] || [[ "${INPUT_POLICY}" != "ACCEPT" ]]; then
    if ! ${SUDO} iptables -S | grep -q "${VPN}-input-rule"; then
      echo "::: [INFO] Políticas restrictivas detectadas en INPUT (IPv4). Abriendo canal exclusivo para puerto: ${pivpnPORT}..."
      ${SUDO} iptables -I INPUT 1 -i "${IPv4dev}" -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT -m comment --comment "${VPN}-input-rule"
    fi
    INPUT_CHAIN_EDITED=1
  else
    INPUT_CHAIN_EDITED=0
  fi

  # DETERMINACIÓN DE APERTURA (INPUT IPv6)
  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    if [[ "${INPUT_RULES_COUNTv6}" -ne 0 ]] || [[ "${INPUT_POLICYv6}" != "ACCEPT" ]]; then
      if ! ${SUDO} ip6tables -S | grep -q "${VPN}-input-rule"; then
        echo "::: [INFO] Políticas restrictivas detectadas en INPUT (IPv6). Abriendo canal exclusivo para puerto: ${pivpnPORT}..."
        ${SUDO} ip6tables -I INPUT 1 -i "${IPv6dev}" -p "${pivpnPROTO}" --dport "${pivpnPORT}" -j ACCEPT -m comment --comment "${VPN}-input-rule"
      fi
      INPUT_CHAIN_EDITEDv6=1
    else
      INPUT_CHAIN_EDITEDv6=0
    fi
  fi

  # INTEGRIDAD DEL TRÁFICO (FORWARD IPv4): Habilitar la interconexión interna de paquetes aislados
  if [[ "${FORWARD_RULES_COUNT}" -ne 0 ]] || [[ "${FORWARD_POLICY}" != "ACCEPT" ]]; then
    if ! ${SUDO} iptables -S | grep -q "${VPN}-forward-rule"; then
      echo "::: [INFO] Políticas restrictivas detectadas en FORWARD (IPv4). Inyectando reglas de tránsito mutuo..."
      ${SUDO} iptables -I FORWARD 1 -d "${pivpnNET}/${subnetClass}" -i "${IPv4dev}" -o "${pivpnDEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT -m comment --comment "${VPN}-forward-rule"
      ${SUDO} iptables -I FORWARD 2 -s "${pivpnNET}/${subnetClass}" -i "${pivpnDEV}" -o "${IPv4dev}" -j ACCEPT -m comment --comment "${VPN}-forward-rule"
    fi
    FORWARD_CHAIN_EDITED=1
  else
    FORWARD_CHAIN_EDITED=0
  fi

  # INTEGRIDAD DEL TRÁFICO (FORWARD IPv6)
  if [[ "${pivpnenableipv6}" -eq 1 ]]; then
    if [[ "${FORWARD_RULES_COUNTv6}" -ne 0 ]] || [[ "${FORWARD_POLICYv6}" != "ACCEPT" ]]; then
      if ! ${SUDO} ip6tables -S | grep -q "${VPN}-forward-rule"; then
        echo "::: [INFO] Políticas restrictivas detectadas en FORWARD (IPv6). Inyectando reglas de tránsito mutuo..."
        ${SUDO} ip6tables -I FORWARD 1 -d "${pivpnNETv6}/${subnetClassv6}" -i "${IPv6dev}" -o "${pivpnDEV}" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT -m comment --comment "${VPN}-forward-rule"
        ${SUDO} ip6tables -I FORWARD 2 -s "${pivpnNETv6}/${subnetClassv6}" -i "${pivpnDEV}" -o "${IPv6dev}" -j ACCEPT -m comment --comment "${VPN}-forward-rule"
      fi
      FORWARD_CHAIN_EDITEDv6=1
    else
      FORWARD_CHAIN_EDITEDv6=0
    fi
  fi

  # PERSISTENCIA DEL ESTADO: Guardado transaccional según la estructura interna del sistema operativo
  echo "::: [INFO] Consolidando y guardando las nuevas reglas criptográficas y de red en el almacenamiento persistente..."
  case "${PLAT}" in
    Debian | Raspbian | Ubuntu)
      ${SUDO} iptables-save | ${SUDO} tee /etc/iptables/rules.v4 > /dev/null
      ${SUDO} ip6tables-save | ${SUDO} tee /etc/iptables/rules.v6 > /dev/null
      ;;
    Alpine)
      ${SUDO} rc-service iptables save > /dev/null 2>&1
      ${SUDO} rc-service ip6tables save > /dev/null 2>&1
      ${SUDO} rc-update add iptables > /dev/null 2>&1
      ${SUDO} rc-update add ip6tables > /dev/null 2>&1
      ;;
  esac

  # METADATOS: Exportar el mapa relacional de modificaciones realizadas al archivo temporal de variables globales
  {
    echo "INPUT_CHAIN_EDITED=${INPUT_CHAIN_EDITED}"
    echo "FORWARD_CHAIN_EDITED=${FORWARD_CHAIN_EDITED}"
    echo "INPUT_CHAIN_EDITEDv6=${INPUT_CHAIN_EDITEDv6}"
    echo "FORWARD_CHAIN_EDITEDv6=${FORWARD_CHAIN_EDITEDv6}"
  } >> "${tempsetupVarsFile}"

  echo "::: [ÉXITO] Configuración de red nativa mediante iptables completada con éxito."

  # Interfaz visual de cierre de sección para instalaciones interactivas
  if [[ "${runUnattended}" != 'true' ]]; then
    whiptail \
      --backtitle "Asistente de Instalación PiVPN" \
      --title "Configuración Cortafuegos (iptables)" \
      --ok-button "Continuar" \
      --msgbox "Las directivas de red, tablas NAT y enmascaramiento de paquetes con la suite iptables han sido registradas y persistidas correctamente en el almacenamiento del sistema." \
      "${r}" "${c}"
  fi
}

confLogging() {
  # ==============================================================================
  #          CONFIGURACIÓN DE REGISTROS (LOGGING Y LOGROTATE)
  # ==============================================================================
  echo ":::"
  echo "::: [INFO] Configurando la persistencia y rotación de registros del sistema..."

  # Pre-crear directorios de configuración de rsyslog/logrotate si faltan,
  # para asegurar que los registros se manejen como se espera cuando estos se instalen
  if ! ${SUDO} mkdir -p /etc/rsyslog.d /etc/logrotate.d; then
    err "Fallo de entorno: No se pudieron crear los directorios de configuración de rsyslog/logrotate."
    if [[ "${runUnattended}" != 'true' ]]; then
      whiptail --backtitle "Asistente de Configuración - PiVPN" \
               --title "Error de Configuración de Logs" \
               --ok-button "Salir" \
               --msgbox "No se pudieron crear los directorios necesarios en /etc para rsyslog o logrotate.\n\nPor favor, verifica los permisos del sistema." "${r}" "${c}"
    fi
    exit 1
  fi

  # Aplicar configuración específica únicamente si el motor seleccionado es OpenVPN
  if [[ "${VPN}" == "openvpn" ]]; then
    echo "::: [INFO] Escribiendo directivas de enrutamiento rsyslog para OpenVPN..."
    if ! echo "if \$programname == 'openvpn' then /var/log/openvpn.log
if \$programname == 'openvpn' then stop" | ${SUDO} tee /etc/rsyslog.d/30-openvpn.conf > /dev/null; then
      err "Fallo de E/S: No se pudo escribir la regla de rsyslog en /etc/rsyslog.d/30-openvpn.conf."
      exit 1
    fi

    echo "::: [INFO] Escribiendo directivas de rotación logrotate para OpenVPN..."
    if ! echo "/var/log/openvpn.log
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
}" | ${SUDO} tee /etc/logrotate.d/openvpn > /dev/null; then
      err "Fallo de E/S: No se pudo escribir la regla de logrotate en /etc/logrotate.d/openvpn."
      exit 1
    fi
  fi

  # Reiniciar el servicio de registro adaptado a la plataforma detectada
  echo "::: [INFO] Sincronizando el demonio de registros del sistema..."
  case "${PLAT}" in
    Debian | Raspbian | Raspberry | Ubuntu)
      if systemctl is-active --quiet rsyslog 2>/dev/null || systemctl is-enabled --quiet rsyslog 2>/dev/null; then
        if ! ${SUDO} systemctl restart rsyslog.service; then
          echo "::: [ADVERTENCIA] No se pudo reiniciar el servicio rsyslog de forma automática."
        fi
      fi
      ;;
    Alpine)
      # Uso controlado de utilidades de OpenRC para Alpine Linux
      ${SUDO} rc-service -is rsyslog restart &>/dev/null || true
      ${SUDO} rc-service -iN rsyslog start &>/dev/null || true
      ;;
  esac

  echo "::: [ÉXITO] Subsistema de logs y rotación configurado correctamente."
}

restartServices() {
  # ==============================================================================
  #             REINICIO Y HABILITACIÓN DE SERVICIOS VPN
  # ==============================================================================
  echo ":::"
  echo "::: [INFO] Inicializando el aprovisionamiento y arranque de servicios VPN (${VPN^^})..."

  case "${PLAT}" in
    Debian | Raspbian | Raspberry | Ubuntu)
      if [[ "${VPN}" == "openvpn" ]]; then
        echo "::: [INFO] Asegurando persistencia en el arranque: openvpn.service..."
        ${SUDO} systemctl enable openvpn.service &> /dev/null
        
        echo "::: [INFO] Lanzando comando de reinicio del demonio OpenVPN..."
        if ! ${SUDO} systemctl restart openvpn.service; then
          err "Fallo crítico: El sistema no pudo levantar el servicio OpenVPN correctamente."
          if [[ "${runUnattended}" != 'true' ]]; then
            whiptail --backtitle "Asistente de Configuración - PiVPN" \
                     --title "Fallo de Servicio OpenVPN" \
                     --ok-button "Revisar" \
                     --msgbox "El instalador no pudo iniciar el servicio de OpenVPN de forma nativa.\n\nTe sugerimos comprobar el estado detallado ejecutando:\nsudo systemctl status openvpn.service" "${r}" "${c}"
          fi
          exit 1
        fi
      elif [[ "${VPN}" == "wireguard" ]]; then
        echo "::: [INFO] Asegurando persistencia en el arranque: wg-quick@wg0.service..."
        ${SUDO} systemctl enable wg-quick@wg0.service &> /dev/null
        
        echo "::: [INFO] Lanzando comando de reinicio de la interfaz WireGuard..."
        if ! ${SUDO} systemctl restart wg-quick@wg0.service; then
          err "Fallo crítico: El sistema no pudo inicializar la interfaz WireGuard (wg-quick@wg0)."
          if [[ "${runUnattended}" != 'true' ]]; then
            whiptail --backtitle "Asistente de Configuración - PiVPN" \
                     --title "Fallo de Servicio WireGuard" \
                     --ok-button "Revisar" \
                     --msgbox "No se pudo levantar la interfaz criptográfica de WireGuard (wg0).\n\nPor favor, revisa la salida detallada mediante el comando:\nsudo systemctl status wg-quick@wg0.service" "${r}" "${c}"
          fi
          exit 1
        fi
      fi
      ;;

    Alpine)
      if [[ "${VPN}" == 'openvpn' ]]; then
        echo "::: [INFO] Registrando OpenVPN en el nivel de ejecución por defecto (OpenRC)..."
        ${SUDO} rc-update add openvpn default &> /dev/null
        
        echo "::: [INFO] Reiniciando el manejador openvpn de OpenRC..."
        if ! ${SUDO} rc-service -s openvpn restart || ! ${SUDO} rc-service -N openvpn start; then
          err "Fallo crítico de inicialización: No se pudo arrancar el servicio openvpn de OpenRC."
          exit 1
        fi
      elif [[ "${VPN}" == 'wireguard' ]]; then
        echo "::: [INFO] Registrando wg-quick en el nivel de ejecución por defecto (OpenRC)..."
        ${SUDO} rc-update add wg-quick default &> /dev/null
        
        echo "::: [INFO] Reiniciando el manejador wg-quick de OpenRC..."
        if ! ${SUDO} rc-service -s wg-quick restart || ! ${SUDO} rc-service -N wg-quick start; then
          err "Fallo crítico de inicialización: No se pudo arrancar la interfaz wg-quick de OpenRC."
          exit 1
        fi
      fi
      ;;
      
    *)
      err "Error de control: La plataforma actual '${PLAT}' no está mapeada en el módulo de servicios."
      exit 1
      ;;
  esac

  echo "::: [ÉXITO] Los servicios asociados a ${VPN^^} se han desplegado y arrancado correctamente."
}

askUnattendedUpgrades() {
  # ==============================================================================
  #          GESTIÓN DE ACTUALIZACIONES DE SEGURIDAD DESATENDIDAS
  # ==============================================================================
  echo ":::"
  echo "::: [INFO] Evaluando directivas para el subsistema de actualizaciones automáticas..."

  # ------------------------------------------------------------------------------
  # MODO 1: INSTALACIÓN DESATENDIDA (AUTOMATIZADA / SETUPVARS)
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    if [[ -z "${UNATTUPG}" ]]; then
      UNATTUPG=1
      echo "::: [INFO] Modo desatendido: No se especificó preferencia para UNATTUPG. Se habilita por defecto."
    else
      if [[ "${UNATTUPG}" -eq 1 ]]; then
        echo "::: [INFO] Modo desatendido: Directiva explícita detectada para activar actualizaciones automáticas."
      else
        echo "::: [INFO] Modo desatendido: Directiva explícita detectada para omitir actualizaciones automáticas."
      fi
    fi

    # Validación transaccional de escritura en el entorno temporal de instalación
    if ! echo "UNATTUPG=${UNATTUPG}" >> "${tempsetupVarsFile}"; then
      err "Fallo crítico de E/S: No se pudo escribir la variable UNATTUPG en '${tempsetupVarsFile}'."
      exit 1
    fi
    return
  fi

  # ------------------------------------------------------------------------------
  # MODO 2: ASISTENTE INTERACTIVO (GRÁFICO - WHIPTAIL)
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Desplegando panel explicativo sobre mantenimiento preventivo y seguridad..."

  # Cuadro informativo inicial sobre el servicio unattended-upgrades
  whiptail \
    --backtitle "Asistente de Configuración - PiVPN" \
    --title "Actualizaciones de Seguridad Automáticas" \
    --ok-button "Entendido, Continuar" \
    --msgbox "Para salvaguardar la integridad de tu servidor frente a amenazas y brechas de red, el asistente configurará el servicio nativo 'unattended-upgrades'.\n\nEsta utilidad automatiza por completo la descarga e instalación de parches de seguridad críticos diariamente.\n\nNotas de seguridad importantes:\n• Este proceso se limita estrictamente a mitigar fallos de seguridad del sistema.\n• El servicio nunca forzará un reinicio del servidor de manera autónoma.\n• Se recomienda planificar reinicios periódicos de la máquina para asegurar que los parches del kernel surtan efecto." \
    "${r}" "${c}"

  echo "::: [INFO] Solicitando confirmación para el aprovisionamiento de parches desatendidos..."

  # Diálogo interactivo de toma de decisión binaria
  if whiptail \
    --backtitle "Asistente de Configuración - PiVPN" \
    --title "Configurar Actualizaciones Automáticas" \
    --yes-button "Sí, Habilitar (Recomendado)" \
    --no-button "No, Omitir" \
    --yesno "Garantizar la protección continua del servidor es un pilar fundamental de la infraestructura. Al activar esta opción, el sistema operativo aplicará diariamente de forma automatizada, desatendida y segura las correcciones críticas.\n\nEsta función ayuda a prevenir la explotación remota de vulnerabilidades sin requerir mantenimiento humano ni provocar cortes de servicio.\n\n¿Deseas activar las actualizaciones automáticas de seguridad?" \
    "${r}" "${c}"; then
    
    UNATTUPG=1
    echo "::: [INFO] El usuario optó por habilitar las actualizaciones automáticas de seguridad."
  else
    # Captura del estado de salida para identificar interrupciones abruptas del asistente
    local exit_status=$?
    if [[ ${exit_status} -eq 255 ]]; then
      echo "::: [ADVERTENCIA] Cancelación forzada detectada en el diálogo interactivo (tecla ESC)." >&2
    fi
    UNATTUPG=0
    echo "::: [INFO] Se han omitido las actualizaciones automáticas de seguridad por instrucción del usuario."
  fi

  # ------------------------------------------------------------------------------
  # PERSISTENCIA TRANSACCIONAL DE CONFIGURACIÓN
  # ------------------------------------------------------------------------------
  if ! echo "UNATTUPG=${UNATTUPG}" >> "${tempsetupVarsFile}"; then
    err "Fallo crítico de E/S: No se pudieron guardar las directivas de seguridad en '${tempsetupVarsFile}'."
    exit 1
  fi

  echo "::: [ÉXITO] Configuración del subsistema de actualizaciones desatendidas consolidada correctamente."
}

confUnattendedUpgrades() {
  # ==============================================================================
  #       CONFIGURACIÓN DEL SUBSISTEMA DE ACTUALIZACIONES AUTOMÁTICAS
  # ==============================================================================
  local PIVPN_DEPS periodic_file

  # ------------------------------------------------------------------------------
  # RAMAL A: GESTOR DE PAQUETES APT (DEBIAN / UBUNTU / RASPBERRY PI OS)
  # ------------------------------------------------------------------------------
  if [[ "${PKG_MANAGER}" == 'apt-get' ]]; then
    echo ":::"
    echo "::: [INFO] Configurando actualizaciones desatendidas para entornos basados en APT..."
    
    PIVPN_DEPS=(unattended-upgrades)
    installDependentPackages PIVPN_DEPS[@]
    aptConfDir="/etc/apt/apt.conf.d"

    # El paquete unattended-upgrades de Raspberry Pi OS hereda la configuración de Debian,
    # por lo que copiamos y consolidamos la plantilla de orígenes apropiada.
    if [[ "${PLAT}" == "Raspberry" || "${PLAT}" == "Raspbian" ]]; then
      echo "::: [INFO] Entorno Raspberry Pi OS detectado. Desplegando plantilla de orígenes específicos..."
      if ! ${SUDO} install -m 644 \
        "${pivpnFilesDir}/files${aptConfDir}/50unattended-upgrades.Raspbian" \
        "${aptConfDir}/50unattended-upgrades"; then
        err "Fallo crítico de E/S: No se pudo desplegar el archivo de orígenes '50unattended-upgrades.Raspbian'."
        exit 1
      fi
    fi

    # Definición del archivo de directivas periódicas según la distribución destino
    if [[ "${PLAT}" == "Ubuntu" ]]; then
      periodic_file="${aptConfDir}/10periodic"
    else
      periodic_file="${aptConfDir}/02periodic"
    fi

    echo "::: [INFO] Escribiendo directivas de automatización periódica en '${periodic_file}'..."
    
    # Volcado seguro y transaccional de los intervalos de actualización de APT
    if ! {
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
    } | ${SUDO} tee "${periodic_file}" > /dev/null; then
      err "Fallo crítico de E/S: No se pudieron consolidar las directivas de automatización en '${periodic_file}'."
      exit 1
    fi

    # Tratamiento de retrocompatibilidad y actualizaciones automáticas de repositorios externos (WireGuard Bullseye)
    if [[ "${VPN}" == "wireguard" ]]; then
      if [[ -f /etc/apt/sources.list.d/pivpn-bullseye-repo.list ]]; then
        echo "::: [INFO] Repositorio complementario WireGuard detectado. Evaluando directivas de Apt-Pinning..."
        
        if ! grep -q "\"o=${PLAT},n=bullseye\";" "${aptConfDir}/50unattended-upgrades"; then
          echo "::: [INFO] Modificando orígenes permitidos en 50unattended-upgrades para habilitar mantenimiento de WireGuard..."
          local sed_pattern
          sed_pattern="/Unattended-Upgrade::Allowed-Origins/a\\        \"o=${PLAT},n=bullseye\";"
          
          if ! ${SUDO} sed -i "${sed_pattern}" "${aptConfDir}/50unattended-upgrades"; then
            err "::: [ADVERTENCIA] No se pudo inyectar el origen Bullseye mediante patrón de inserción. Intentando fallback..."
            # Alternativa de contingencia segura al final del bloque de orígenes
            ${SUDO} sed -i "s|};|        \"o=${PLAT},n=bullseye\";\n};|g" "${aptConfDir}/50unattended-upgrades"
          fi
        fi
      fi
    fi
    
    echo "::: [ÉXITO] Subsistema 'unattended-upgrades' para APT aprovisionado correctamente."

  # ------------------------------------------------------------------------------
  # RAMAL B: GESTOR DE PAQUETES APK (ALPINE LINUX)
  # ------------------------------------------------------------------------------
  elif [[ "${PKG_MANAGER}" == 'apk' ]]; then
    echo ":::"
    echo "::: [INFO] Configurando actualizaciones desatendidas para entorno Alpine Linux (apk)..."
    local down_dir
    
    echo "::: [INFO] Instalando dependencias necesarias para la compilación del utilitario..."
    if ! ${SUDO} ${PKG_INSTALL} unzip asciidoctor; then
      err "Error de dependencias: No se pudieron instalar las herramientas de compilación requeridas."
      exit 1
    fi

    echo "::: [INFO] Creando espacio aislado de almacenamiento temporal..."
    if ! down_dir="$(mktemp -d)"; then
      err "Fallo crítico de entorno: No se pudo instanciar el directorio temporal para 'apk-autoupdate'."
      exit 1
    fi

    echo "::: [INFO] Descargando código fuente de 'apk-autoupdate' desde repositorio remoto..."
    if ! curl -fLo "${down_dir}/master.zip" https://github.com/jirutka/apk-autoupdate/archive/refs/heads/master.zip; then
      err "Error de red WAN: La descarga del paquete de código fuente ha fallado."
      rm -rf "${down_dir}"
      exit 1
    fi

    echo "::: [INFO] Extrayendo paquete del logicial descargado..."
    if ! unzip -qd "${down_dir}" "${down_dir}/master.zip"; then
      err "Error de integridad: El archivo de código fuente descargado está corrupto o es inválido."
      rm -rf "${down_dir}"
      exit 1
    fi

    echo "::: [INFO] Iniciando subproceso aislado de compilación nativa..."
    (
      cd "${down_dir}/apk-autoupdate-master" || {
        err "Fallo de ruta: Directorio fuente 'apk-autoupdate-master' inalcanzable."
        exit 1
      }

      ## Personalizar Makefile con las rutas base del sistema anfitrión (/usr)
      if ! sed -i -E -e 's/^(prefix\s*:=).*/\1 \/usr/' Makefile; then
        err "Fallo de preparación: No se pudo reconfigurar el prefijo en el Makefile."
        exit 1
      fi

      ## Compilación e instalación definitiva de binarios
      if ! ${SUDO} make install; then
        err "Fallo de compilación: El comando 'make install' devolvió un código de error de salida."
        exit 1
      fi

      ## Validación de accesibilidad en el PATH del sistema
      if ! command -v apk-autoupdate &> /dev/null; then
        err "Fallo de validación post-instalación: El binario 'apk-autoupdate' no responde."
        exit 1
      fi
    )
    
    # Captura del estado de finalización del subproceso para contingencias gráficas
    local subshell_status=$?
    if [[ ${subshell_status} -ne 0 ]]; then
      rm -rf "${down_dir}"
      
      whiptail \
        --backtitle "Asistente de Configuración - PiVPN" \
        --title "Error Crítico de Compilación" \
        --ok-button "Aceptar y Salir" \
        --msgbox "No se pudo compilar, construir ni enlazar el componente de actualización automática 'apk-autoupdate' en este entorno Alpine Linux.\n\nPor favor, comprueba las trazas de error reflejadas en la consola para más información." \
        "${r}" "${c}"
        
      exit 1
    fi

    # Saneamiento y remoción del directorio de descargas temporal
    rm -rf "${down_dir}"

    echo "::: [INFO] Desplegando archivo de configuración maestro 'personal_autoupdate.conf'..."
    if ! ${SUDO} install -m 0755 \
      "${pivpnFilesDir}/files/etc/apk/personal_autoupdate.conf" \
      /etc/apk/personal_autoupdate.conf; then
      err "Fallo crítico de E/S: No se pudo copiar el archivo de configuración en /etc/apk/."
      exit 1
    fi
    
    echo "::: [INFO] Ejecutando sincronización e inicialización inicial del demonio apk-autoupdate..."
    if ! ${SUDO} apk-autoupdate /etc/apk/personal_autoupdate.conf; then
      echo "::: [ADVERTENCIA] La ejecución preliminar de apk-autoupdate reportó advertencias no letales."
    fi
    
    echo "::: [ÉXITO] Subsistema 'apk-autoupdate' para Alpine Linux aprovisionado correctamente."
  fi
}

writeConfigFiles() {
  # ==============================================================================
  #            PERSISTENCIA DE LOS ARCHIVOS DE CONFIGURACIÓN FINALES
  # ==============================================================================
  echo ":::"
  echo "::: [INFO] Consolidando el volcado final de variables de entorno de la instalación..."

  # Inyección segura de los paquetes instalados en el archivo de entorno temporal
  if ! echo "INSTALLED_PACKAGES=(${INSTALLED_PACKAGES[*]})" >> "${tempsetupVarsFile}"; then
    err "Fallo crítico de E/S: No se pudieron anexar los paquetes instalados en el registro temporal."
    exit 1
  fi

  echo "::: [INFO] Generando el directorio destino final de configuración del protocolo..."
  if ! ${SUDO} mkdir -p "${setupConfigDir}/${VPN}/"; then
    err "Fallo de entorno: Imposible crear la ruta estructurada '${setupConfigDir}/${VPN}/'."
    exit 1
  fi

  echo "::: [INFO] Guardando la instantánea de variables definitivas en el almacenamiento..."
  if ! ${SUDO} cp "${tempsetupVarsFile}" "${setupConfigDir}/${VPN}/${setupVarsFile}"; then
    err "Fallo de E/S: Error al mover la configuración definitiva a '${setupConfigDir}/${VPN}/${setupVarsFile}'."
    if [[ "${runUnattended}" != 'true' ]]; then
      whiptail --backtitle "Asistente de Configuración - PiVPN" \
               --title "Error de Almacenamiento" \
               --ok-button "Salir del Instalador" \
               --msgbox "No se pudo guardar la configuración final en el directorio del sistema.\n\nPor favor, verifica los permisos de escritura en la ruta: ${setupConfigDir}" "${r}" "${c}"
    fi
    exit 1
  fi

  echo "::: [ÉXITO] Archivos de configuración consolidados correctamente en: ${setupConfigDir}/${VPN}/${setupVarsFile}"
}

installScripts() {
  # ==============================================================================
  #          ENLACE E INSTALACIÓN DE LOS COMPONENTES Y SCRIPTS OPERATIVOS
  # ==============================================================================
  echo ":::"
  echo "::: [INFO] Iniciando el despliegue y enlazado de scripts del ecosistema PiVPN..."

  # Asegurar que el directorio base de utilidades externas exista (parche histórico para problema #607)
  if ! ${SUDO} mkdir -p /opt; then
    err "Fallo estructural: No se pudo verificar ni crear el directorio base /opt."
    exit 1
  fi

  # Determinación lógica de exclusión binaria del protocolo alternativo
  local othervpn
  if [[ "${VPN}" == 'wireguard' ]]; then
    othervpn='openvpn'
  else
    othervpn='wireguard'
  fi

  echo "::: [INFO] Analizando convivencia de protocolos y configurando accesos CLI..."

  # Caso 1: Coexistencia detectada. Si el archivo del otro protocolo ya existe en el sistema
  if [[ -r "${setupConfigDir}/${othervpn}/${setupVarsFile}" ]]; then
    echo "::: [INFO] Entorno Multiprotocolo detectado (${VPN} y ${othervpn}). Unificando script central de control..."

    # Limpieza silenciosa y segura de enlaces simbólicos específicos para evitar colisiones
    ${SUDO} rm -f /etc/bash_completion.d/pivpn &>/dev/null
    ${SUDO} rm -f /usr/local/bin/pivpn &>/dev/null

    # Enlazar simbólicamente al despachador de comandos comunes/unificados de PiVPN
    if ! ${SUDO} ln -sfT "${pivpnFilesDir}/scripts/pivpn" /usr/local/bin/pivpn; then
      err "Fallo de enlace: No se pudo mapear el despachador común en /usr/local/bin/pivpn."
      exit 1
    fi
  
  # Caso 2: Instalación limpia/Monoprotocolo. Configuración dedicada exclusiva
  else
    echo "::: [INFO] Entorno Monoprotocolo. Creando dependencias de autocompletado y rutas específicas para ${VPN^^}..."

    # Asegurar existencia del directorio de autocompletado interactivo de Bash
    if ! ${SUDO} mkdir -p /etc/bash_completion.d; then
      err "Fallo de entorno: No se pudo instanciar el directorio /etc/bash_completion.d."
      exit 1
    fi

    # Remoción segura de enlaces previos redundantes para evitar conflictos de sobreescritura
    ${SUDO} rm -f /etc/bash_completion.d/pivpn /usr/local/bin/pivpn &>/dev/null

    # Despliegue atómico de la terna de enlaces del entorno (autocompletado, binario CLI y scripts raíz)
    if ! ${SUDO} ln -sfT "${pivpnFilesDir}/scripts/${VPN}/bash-completion" /etc/bash_completion.d/pivpn || \
       ! ${SUDO} ln -sfT "${pivpnFilesDir}/scripts/${VPN}/pivpn.sh" /usr/local/bin/pivpn || \
       ! ${SUDO} ln -sf "${pivpnFilesDir}/scripts/" "${pivpnScriptDir}"; then
      
      err "Fallo de enlace estructural: No se pudieron vincular las herramientas del intérprete de comandos."
      if [[ "${runUnattended}" != 'true' ]]; then
        whiptail --backtitle "Asistente de Configuración - PiVPN" \
                 --title "Fallo de Enlaces Simbólicos" \
                 --ok-button "Revisar Consola" \
                 --msgbox "Ocurrió un error inesperado al intentar enlazar los scripts del entorno CLI de PiVPN en las rutas del sistema.\n\nPor favor, verifica la integridad de los archivos de origen en: ${pivpnFilesDir}/scripts" "${r}" "${c}"
      fi
      exit 1
    fi

    # Carga en caliente del autocompletado para la shell de instalación actual de forma segura
    # shellcheck disable=SC1091
    if [[ -f /etc/bash_completion.d/pivpn ]]; then
      . /etc/bash_completion.d/pivpn 2>/dev/null || true
    fi
  fi

  echo "::: [ÉXITO] Todo el repertorio de scripts operativos y accesos directos se ha instalado correctamente en: ${pivpnScriptDir}"
}

displayFinalMessage() {
  # ==============================================================================
  #         PROCESAMIENTO Y MIGRACIÓN DE DATOS A ALMACENAMIENTO PERSISTENTE
  # ==============================================================================
  echo ":::"
  echo "::: [INFO] Forzando el vaciado de búferes y cachés de escritura ('sync') en el disco..."
  
  # Garantiza que ninguna configuración permanezca volátil en RAM
  sync

  echo "::: [INFO] Sincronización de almacenamiento completada con éxito."

  # ------------------------------------------------------------------------------
  # RAMAL A: MODO DE FINALIZACIÓN DESATENDIDO (AUTOMATIZADO)
  # ------------------------------------------------------------------------------
  if [[ "${runUnattended}" == 'true' ]]; then
    echo ":::"
    echo "::: [ÉXITO] ¡Instalación completada de forma correcta en modo desatendido!"
    echo "::: [INFO] Guía rápida de operaciones post-instalación:"
    echo ":::        • Ejecuta 'pivpn add' para generar perfiles de cliente."
    echo ":::        • Ejecuta 'pivpn help' para inspeccionar el catálogo de comandos CLI."
    echo ":::"
    echo "::: [INFO] Soporte y documentación oficial del proyecto:"
    echo ":::        URL: https://github.com/wfhgdev/pivpn_spanish"
    echo ":::"
    echo "::: [ADVERTENCIA] Se recomienda encarecidamente reiniciar el servidor para aplicar todos los cambios."
    return
  fi

  # ------------------------------------------------------------------------------
  # RAMAL B: MODO DE FINALIZACIÓN INTERACTIVO (ASISTENTE GRÁFICO WHIPTAIL)
  # ------------------------------------------------------------------------------
  echo "::: [INFO] Desplegando panel gráfico de confirmación de fin de despliegue..."

  # Cuadro Informativo de Éxito
  whiptail \
    --backtitle "Asistente de Configuración - PiVPN" \
    --title "¡Configuración Exitosa!" \
    --ok-button "Entendido, Finalizar" \
    --msgbox "¡Enhorabuena! Tu servidor privado de comunicaciones VPN ya se encuentra completamente operativo y listo para su uso.\n\nComandos utilitarios de gestión CLI para comenzar:\n• pivpn add  : Genera y exporta nuevos perfiles criptográficos de usuario.\n• pivpn help : Consulta el manual completo de comandos de administración disponibles.\n\n¿Experimentas alguna incidencia técnico-operativa?\nPor favor, revisa en detalle nuestra documentación oficial antes de abrir un reporte. Esto nos ayuda a mantener un ecosistema de soporte ágil y estructurado.\n\nGracias por depositar tu confianza en PiVPN en Español." \
    "${r}" "${c}"

  echo "::: [INFO] Solicitando confirmación interactiva para reiniciar el sistema anfitrión..."

  # Diálogo de confirmación para el reinicio inmediato de la máquina
  if whiptail \
    --backtitle "Asistente de Configuración - PiVPN" \
    --title "Reinicio del Sistema Recomendado" \
    --yes-button "Sí, reiniciar ahora (Recomendado)" \
    --no-button "No, reiniciar más tarde" \
    --defaultno \
    --yesno "Se aconseja realizar un reinicio completo del servidor tras finalizar el aprovisionamiento de red y las actualizaciones.\n\n¿Deseas programar y ejecutar el reinicio inmediato del sistema?" \
    "${r}" "${c}"; then

    whiptail \
      --backtitle "Asistente de Configuración - PiVPN" \
      --title "Secuencia de Reinicio Activada" \
      --ok-button "Proceder" \
      --msgbox "El sistema procederá a cerrarse y reiniciarse de manera inmediata." \
      "${r}" "${c}"

    printf "\n::: [INFO] Iniciando secuencia controlada de reinicio del servidor en 3 segundos...\n"
    sleep 3

    # Ejecución resiliente del reinicio del sistema operativo
    if ! ${SUDO} reboot; then
      echo ":::" >&2
      err "No se pudo despachar la orden de reinicio automatizado mediante 'reboot'."
      echo "::: [ADVERTENCIA] Por favor, ejecuta el comando 'sudo reboot' de forma manual en la terminal." >&2
      exit 1
    fi
  else
    echo ":::"
    echo "::: [INFO] El usuario pospuso el reinicio del sistema. Retornando control a la terminal anfitriona."
  fi
}

# ==============================================================================
#             PUNTO DE ENTRADA ÚNICO Y DISPARO INICIAL DEL SCRIPT
# ==============================================================================
main "$@"