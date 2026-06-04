> [!ADVERTENCIA!]
> PiVPN se mantiene con el máximo esfuerzo posible; para obtener más información consulte [aquí](https://github.com/pivpn/pivpn/releases/tag/v4.6.1). La versión anterior se encuentra [aquí](https://github.com/pivpn/pivpn/releases/tag/v4.6.0).

![Pivpn Banner](pivpnbanner.png)

![Logos](logos.jpg)

**[PIVPN.IO](https://pivpn.io)** | **[DOCUMENTACIÓN](https://docs.pivpn.io)**


[![Website shields.io](https://img.shields.io/website-up-down-green-red/https/pivpn.io.svg)](https://pivpn.io/)
[![Maintenance](https://img.shields.io/badge/Maintained%3F-yes-green.svg)](https://github.com/pivpn/pivpn/graphs/commit-activity)
[![Codacy Badge](https://api.codacy.com/project/badge/Grade/452112df3c2c435d93aacc113f546eae)](https://app.codacy.com/gh/pivpn/pivpn?utm_source=github.com&utm_medium=referral&utm_content=pivpn/pivpn&utm_campaign=Badge_Grade_Settings)
[![made-with-bash](https://img.shields.io/badge/Made%20with-Bash-1f425f.svg)](https://www.gnu.org/software/bash/)
[![Generic badge](https://img.shields.io/badge/status-page-blue.svg)](https://stats.uptimerobot.com/8X64yTjrJO)
[![semantic-release: angular](https://img.shields.io/badge/semantic--release-angular-e10079?logo=semantic-release)](https://github.com/semantic-release/semantic-release)

PiVPN es un conjunto de scripts de consola desarrollados para convertir fácilmente su Raspberry Pi (TM) o PC en un servidor VPN utilizando ambos o uno de los siguientes protocolos VPN gratuitos de código abierto:
* [WireGuard](https://www.wireguard.com/)
* [OpenVPN](https://openvpn.net)

La misión principal de este script es permitir que un usuario tenga una VPN lo más económicamente posible en casa sin necesidad de ser un experto en tecnología. Por eso, PiVPN está diseñado para funcionar en una Raspberry Pi (aprox $35 USD), este script es un instalador de un solo comando que le permitirá una gestión sencilla de la VPN con el uso del comando 'pivpn'.

Dicho esto...

PiVPN es, sin duda, la forma más sencilla y rápida de instalar y configurar un servidor **OpenVPN** o **WireGuard** extremadamente seguro en tu Raspberry Pi o PC. No necesitarás una guía ni un tutorial, ya que PiVPN lo hará todo por ti en mucho menos tiempo, con ajustes de seguridad reforzados por defecto.

Recomendamos ejecutar PiVPN en la última imagen disponible de Raspberry Pi OS Lite para la Raspberry Pi de tu casa, para que puedas conectarte a tu red VPN desde ubicaciones remotas no seguras y usar Internet de forma segura. Sin embargo, también puedes usar PiVPN en otras computadoras monoplaca (SBC) que tengan sistema operativo Ubuntu/Debian o si tienes un ISP (Proveedor de Internet) poco fiable (que no permita abrir puertos TCP/UDP) puedes adquirir cualquier VPS (Servidor Privado Virtual) de un proveedor de servicios en la nube que tenga preinstalado Ubuntu o Debian. Al usar una VPN en un servidor externo, puedes conectarte desde casa y dado que tu tráfico saldrá del proveedor de la nube/VPS, tu proveedor de internet solo verá tráfico cifrado.

PiVPN también debería funcionar con la mayoría de las distribuciones basadas en Ubuntu y Debian para PC, incluidas aquellas que usan UFW (Uncomplicated Firewall) por defecto en lugar de IpTables.	

----
## Instalación

### Metodo 1 (Estándar)

```Shell
curl https://raw.githubusercontent.com/Masterwilledu/pivpn/master/auto_install/install.sh | bash
```

### Metodo 2 (Clonación de repositorio)

```Shell
git clone https://github.com/Masterwilledu/pivpn.git
bash pivpn/auto_install/install.sh
```

### Para instalar desde una URL y Rama Git personalizadas (para Desarrolladores)

Esto está pensado para usarse al probar cambios durante el desarrollo y **NO** para instalaciones estándar.
Sin esta opción, el script siempre seleccionará la rama principal (master).

- El repositorio Git puede ser pivpn o cualquier otro repositorio Git (por ejemplo, una bifurcación).
- Se puede especificar la rama Git según sea necesario.

```shell
# Sintaxis
git clone < customgitrepourl >
bash pivpn/auto_install/install.sh --giturl < customgitrepourl > --gitbranch < customgitbranch >

# Ejemplo
git clone https://github.com/userthatforked/pivpn.git
bash pivpn/auto_install/install.sh --giturl https://github.com/userthatforked/pivpn.git --gitbranch myfeaturebranch
```

La configuración de instalación desatendida también admite una rama y un GitHub personalizados.

```shell
pivpnGitUrl="https://github.com/userthatforked/pivpn.git"
pivpnGitBranch="myfeaturebranch"
```
----
## Comentarios y Soporte

PiVPN es un proyecto impulsado exclusivamente por la comunidad y nuestro objetivo es que funcione para la mayor cantidad de personas posible. Agradecemos cualquier comentario sobre tu experiencia.

Por favor, sé respetuoso y ten en cuenta que PiVPN se mantiene gracias al tiempo libre de voluntarios.

### Directrices Generales

* Este proyecto se rige por el Código de Conducta del Colaborador (CODE_OF_CONDUCT.md). Al participar, te comprometes a respetar este código. Informa cualquier comportamiento inaceptable a cualquier responsable del proyecto.

* Puedes encontrar nuestra documentación en https://docs.pivpn.io
* Lee las publicaciones fijadas en los foros de discusión de GitHub (https://github.com/pivpn/pivpn/discussions).
* Busca problemas similares (https://github.com/pivpn/pivpn/issues?q=). Puedes buscar y aplicar filtros para encontrar los problemas que mejor se ajusten a tu situación.
* Por favor, busca discusiones similares en [Github.com/pivpn/pivpn/discussions].
* Si no encuentras la respuesta, abre una incidencia en [Github.com/pivpn/pivpn/issues/new/choose] y haremos todo lo posible por ayudarte.

* Ayúdanos a ayudarte y completa la plantilla con la información solicitada, **aunque no te parezca relevante**.
* El equipo de PiVPN puede cerrar cualquier discusión o incidencia sin previo aviso si no se siguen las directrices.

### Contacto

Nuestro método de contacto preferido es a través de la página de discusiones de GitHub en [Github.com/pivpn/pivpn/discussions].

También puedes contactarnos en:

* #pivpn en [libera.chat](https://libera.chat) (Red IRC)
* #pivpn:matrix.org [matrix.org](https://matrix.org)
* Reddit en [r/pivpn](https://www.reddit.com/r/pivpn/)

### Solicitudes de nuevas funciones

Las solicitudes de nuevas funciones son bienvenidas. Por favor, envíelas a:

* [Solicitudes de nuevas funciones](https://github.com/pivpn/pivpn/discussions/categories/feature-requests)

### Informes de errores

* **Asegúrese de que el error no haya sido reportado previamente** buscando en GitHub en [Problemas](https://github.com/pivpn/pivpn/issues).

* Si no encuentra un problema abierto que aborde el mismo, [abra uno nuevo](https://github.com/pivpn/pivpn/issues/new/choose). * Proporcione todos los datos solicitados en la plantilla, **aunque no le parezcan relevantes**, y, si es posible, un **ejemplo de código** o un **caso de prueba ejecutable** que demuestre el comportamiento esperado que no se está produciendo.

### Solicitudes de extracción

* Abra una nueva solicitud de extracción en GitHub hacia la rama [test](https://github.com/pivpn/pivpn/tree/test).

* Asegúrese de que la descripción de la solicitud de extracción describa claramente el problema y la solución. Incluya el número de incidencia correspondiente, si procede.

* Utilice las siguientes [reglas de confirmación](https://github.com/angular/angular/blob/main/CONTRIBUTING.md#-commit-message-format).

* Utilice las siguientes [reglas de estilo de código](https://google.github.io/styleguide/shellguide.html). * Le sugerimos usar el siguiente comando [shfmt](https://github.com/mvdan/sh): `shfmt -i 2 -ci -sr -w -bn`

## Contribuciones

PiVPN no acepta donaciones, pero si desea mostrar su agradecimiento, puede contribuir o dejar comentarios con sugerencias o mejoras.

¡Las contribuciones pueden ser de muchas maneras! No necesita ser desarrollador para ayudar.

* Consulte los [problemas](https://github.com/pivpn/pivpn/issues) y las [discusiones](https://github.com/pivpn/pivpn/discussions). Quizás pueda ayudar en algo.

* ¡[Documentación](https://github.com/pivpn/docs)! ¡La documentación nunca es suficiente! Siempre falta algo, hay errores tipográficos o se puede mejorar el inglés.

Nuestro sitio web (https://pivpn.io) también es de código abierto. Siéntase libre de sugerir cambios o mejoras aquí (https://github.com/pivpn/pivpn.io).
¡Prueba PiVPN! ¡Ejecuta PiVPN de diferentes maneras, en diferentes sistemas y con diferentes configuraciones! ¡Avísanos si encuentras algún problema!

También agradecemos mucho la ayuda a otros usuarios en cualquiera de nuestros canales oficiales.

Si consideras que PiVPN es útil y prefieres hacer una donación, puedes hacerlo a:

1. [Colaboradores de PiVPN](https://github.com/pivpn/pivpn/graphs/contributors)
2. [OpenVPNSetup](https://github.com/StarshipEngineer/OpenVPN-Setup)
3. [pi-hole.net](https://github.com/pi-hole/pi-hole)
4. [OpenVPN](https://openvpn.net)
5. [WireGuard](https://www.wireguard.com/)
6. [EFF](https://www.eff.org/)
