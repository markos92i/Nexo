# Seguridad

El modelo de seguridad de Nexo es **secreto compartido mediante PSK**
(pre-shared key), no certificados ni identidad por dispositivo.

## Modelo

El canal (TCP y QUIC) se cifra con TLS-PSK. La clave se deriva así:

```
PSK     = HMAC-SHA256(key: appSecret, message: roomCode ?? "")
pskHint = SHA256(PSK).prefix(16)   // identificador público, no secreto
```

- **`appSecret`** lo aporta la app (una constante compilada en su binario).
  Garantiza "solo mi app habla con mi app".
- **`roomCode`** (opcional) aísla el canal por sala: dos peers de la misma app
  pero distinta sala no pueden descifrarse entre sí. Por defecto se usa el
  `shortCode` del `RoomID`.

Consecuencia directa: **quien no conoce el secreto no completa el handshake** y no
se conecta. Quien lo conoce está legítimamente en la sala.

## Qué NO hay (y por qué)

No hay certificados autofirmados, ni identidad criptográfica por dispositivo, ni
TOFU (Trust On First Use), ni huellas visuales (emoji/palabras), ni QR de
verificación. Con PSK todo eso sería ceremonia sin valor: la huella derivada de la
PSK sería idéntica para todos los miembros de una sala, así que no identificaría a
un dispositivo concreto. **Comparar el código de sala en persona es la
verificación** del modelo.

El modelo de certificados autofirmados del diseño anterior, además, quedó
bloqueado por iOS 26 (el sistema rechaza TLS a dispositivos locales con certs
autofirmados por Wi-Fi). PSK lo evita.

## Identidad

`LocalIdentity` expone un `DeviceID` (UUID) que Nexo genera y persiste en
Keychain. Es una etiqueta estable para identificar y deduplicar peers, **no** una
prueba de identidad: no está firmada. Trata todo payload remoto como no confiable.

## Límite técnico conocido

PSK sobre QUIC usa TLS 1.3, y el soporte PSK de Apple fue históricamente TLS 1.2.
El canal principal (TCP) usa TLS 1.2-PSK. El canal QUIC de alta velocidad debe
validarse en hardware; si no negocia, el diseño prevé caer al canal principal.
