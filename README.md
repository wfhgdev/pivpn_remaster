# PiVPN Spanish (por William H.)

Este proyecto es un **fork del repositorio original de PiVPN**. Actualmente, el proyecto oficial [PiVPN](https://pivpn.io) no está recibiendo mantenimiento activo, por lo que este fork surge con el objetivo de preservar su funcionalidad, corregir errores y mejorar la experiencia de usuario para la comunidad hispanohablante.

## 🚀 ¿Qué hace especial a esta versión?

A diferencia de la versión original, este fork ha sido rediseñado para ser más intuitivo, asertivo y amigable para el usuario. Las mejoras principales incluyen:

* **Localización Completa al Español:** Se ha traducido íntegramente la interfaz de línea de comandos (CLI) y todos los diálogos interactivos (`whiptail`). Ya no hay confusiones técnicas por barreras idiomáticas.
* **Redacción Asertiva e Interfaz Mejorada:** He reescrito todos los mensajes del instalador para que sean:
    * **Clarificador:** Eliminamos tecnicismos innecesarios y explicamos el "porqué" de cada opción.
    * **Amigable:** Se eliminó el tono punitivo o intimidatorio de los mensajes originales, reemplazándolo por una guía constructiva.
    * **Profesional:** Mejora en la estructuración de la información, el uso de viñetas y el flujo de los botones de acción para facilitar la toma de decisiones.
* **Logs Consistentes:** La salida en consola (`echo`) ha sido estandarizada para ofrecer un log de instalación limpio, legible y profesional.
* **Compatibilidad Actualizada:** Se han corregido diversos scripts de validación para garantizar la compatibilidad con las versiones más recientes de **Debian/Ubuntu** y sus derivados.

## 📋 Requisitos Previos

Antes de proceder con la instalación, asegúrate de que tu sistema cumpla con las siguientes condiciones:

*   **Equipo para el Servidor (donde instalas PiVPN):**
    *   Aunque fue creado originalmente para la gama de placas Raspberry Pi (modelos 1 al 5, Zero), el instalador funciona en cualquier servidor x86_64 o placa ARM que utilice sistemas operativos basados en Debian o Ubuntu. Cualquier Raspberry Pi, placas tipo SBC (Single Board Computer) con mínimo 1GB de RAM como OrangePi, Odroid, PineA64 o NanoPi, Mini PCs o servidores domésticos, Contenedores, Servidor Privado Virtual (VPS) en la nube o Maquina Virtual local (VirtualBox, VMware).
*   **Sistema Operativo Compatible:** 
    *   Raspberry Pi OS (Lite o Desktop)
    *   Ubuntu Server/Desktop (18.04 LTS o superior)
    *   Debian Server/Desktop (10 o superior)
*   **Acceso Root:** Es necesario contar con privilegios de administrador (`sudo`).
*   **Red Estable:** Una conexión a internet activa para descargar los paquetes necesarios.
*   **IP Local Estática:** Se recomienda encarecidamente configurar una dirección IP local estática o reservada (reservada por DHCP) para tu servidor antes de empezar.
*   **Puerto Abierto (Enrutador):** Necesitarás acceso a tu enrutador para redirigir el trafico entrante del puerto de la VPN (típicamente el puerto UDP `51820` para WireGuard o UDP `1194` para OpenVPN) hacia la IP local de Servidor VPN.
*   **IP Pública accesible:** Es ideal que tu enrutador tenga una IP Fija Publica. Si tu IP pública es dinámica (es decir cambia seguido), necesitarás configurar un servicio de DNS Dinámico (DDNS) como [DuckDNS](https://www.duckdns.org) o [No-IP](https://www.noip.com), el cual PiVPN te permite integrar durante la instalación.

----
## 🛠 Instalación

### :thumbsup: Metodo 1 (Estándar)
Antes de instalar PiVPN, debes usar el siguiente comando en tu terminal para actualizar el sistema operativo: `sudo apt update && sudo apt upgrade -y`, asegúrate de tener **cURL** instalado, verifícalo usando el comando `curl --version`, de lo contrario puedes instalar **cURL** (Cliente para URLs) con el comando: `sudo apt install curl`

```Shell
curl https://raw.githubusercontent.com/wfhgdev/pivpn_spanish/master/auto_install/install.sh | bash
```

### :sheep: Metodo 2 (Clonación de repositorio)
Antes de instalar PiVPN, debes usar el siguiente comando en tu terminal para actualizar el sistema operativo: `sudo apt update && sudo apt upgrade -y`, asegúrate de tener **Git** instalado, verifícalo con el comando `git --version`, de lo contrario puedes instalar **Git** (sistema de control de versiones) con el comando: `sudo apt install git`

```Shell
git clone https://github.com/wfhgdev/pivpn_spanish.git
bash pivpn/auto_install/install.sh
```
