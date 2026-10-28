# Seguridad

El modelo de seguridad de Nexo es **secreto compartido mediante PSK**
(pre-shared key), no certificados ni identidad por dispositivo.

## Modelo

Las dos conexiones con cada peer (la de control y la de streams binarios) se
cifran con TLS 1.2 PSK y la suite `TLS_PSK_WITH_AES_128_GCM_SHA256`. La clave se
deriva así:

```
PSK     = HMAC-SHA256(key: appSecret, message: roomCode ?? "")
pskHint = SHA256(PSK).prefix(16)   // identificador público, no secreto
```

- **`appSecret`** lo aporta la app (una constante compilada en su binario).
  Garantiza "solo mi app habla con mi app".
- **`roomCode`** (opcional) aísla el canal por sala: dos peers de la misma app
  pero distinta sala no pueden descifrarse entre sí. El valor previsto es el
  `shortCode` del `RoomID`. Sin `roomCode`, todas las salas de la app comparten
  PSK.

Consecuencia directa: **quien no conoce el secreto no completa el handshake** y no
se conecta. Quien lo conoce está legítimamente en la sala.

## Qué protege el `appSecret` y qué no

El `appSecret` es una constante dentro del binario de la app, y cualquiera que
tenga la app puede extraerlo. Por eso:

- **Sí** garantiza que solo tu app hable con tu app, y cifra el tráfico frente a
  quien escucha la red sin tener la app.
- **No** autentica usuarios. Alguien que extraiga el secreto puede escribir un
  cliente propio, conectarse y hacerse pasar por cualquier dispositivo, porque el
  `DeviceID` lo declara cada peer. Con el secreto también podría descifrar el
  tráfico que capture, porque esta suite PSK no usa claves efímeras.

Lo que sea sensible (datos personales, compras, puntuaciones que importen)
necesita su propia protección por encima de Nexo.

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

Tampoco hay QUIC: QUIC exige TLS 1.3, y con una PSK externa el TLS de Apple solo
negocia TLS 1.2. Los streams binarios van por una segunda conexión TCP con la
misma PSK.

## Identidad

`LocalIdentity` expone un `DeviceID` (UUID) que Nexo genera y persiste en
Keychain. Es una etiqueta estable para identificar y deduplicar peers, **no** una
prueba de identidad: no está firmada y cada peer declara la suya. Trata todo
payload remoto como no confiable: valida sala, emisor y forma antes de usarlo.
