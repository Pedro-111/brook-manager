# Brook Server Manager

Un script de gestión completo para servidores Brook proxy con interfaz de línea de comandos fácil de usar.

## 🚀 Características

- **Instalación automática** de Brook desde GitHub releases
- **Configuración múltiple**: Soporta server, wsserver y wssserver
- **SSL automático**: Certificados Let's Encrypt y auto-firmados
- **Gestión de servicios**: Systemd integration completa
- **Códigos QR**: Generación automática de enlaces y QR codes
- **Logs en tiempo real**: Monitoreo de servicios
- **Interfaz colorida**: Fácil navegación con menús interactivos

## 📋 Modos soportados

- **Server**: SOCKS5 proxy tradicional
- **WSServer**: WebSocket proxy (WS)
- **WSSServer**: WebSocket proxy con SSL (WSS)

## 🛠️ Instalación

### Instalación automática (recomendada):

```bash
curl -sSL https://raw.githubusercontent.com/Pedro-111/brook-manager/main/install.sh | sudo bash
```
## 🎯 Uso rápido
Después de la instalación, ejecuta:
brook-manager
