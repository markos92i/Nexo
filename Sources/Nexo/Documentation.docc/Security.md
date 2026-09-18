# Seguridad y Cifrado en Nexo

Arquitectura de seguridad para comunicaciones P2P sin servidor central ni autoridad certificadora.

## Visión General

Nexo implementa un modelo de seguridad TOFU (Trust On First Use) similar a SSH, diseñado para funcionar en entornos sin conectividad a Internet:

- **Sin servidor central**: No depende de ningún backend para autenticación
- **Sin CA externa**: Los certificados son autofirmados y generados localmente
- **Cifrado completo**: Todo el tráfico está cifrado con TLS 1.3
- **Verificación opcional**: Los usuarios pueden verificar identidades fuera de banda

## Flujo de Identidad Local

### Generación de Identidad

Cada dispositivo genera su propia identidad TLS la primera vez que usa Nexo:

```swift
let identity = try NexoLocalTLSIdentity.loadOrCreate(applicationID: myAppID)
let tlsConfig = identity.makeTLSConfiguration()
```

Este proceso:
1. Genera una clave privada P-256 (ECDSA) en el Secure Enclave/Keychain
2. Crea un certificado X.509 v3 autofirmado válido por 10 años
3. Almacena ambos en Keychain con protección `afterFirstUnlockThisDeviceOnly`

La clave privada **nunca sale del dispositivo**.

### Fingerprint

El fingerprint es un hash SHA-256 de la clave pública, representado en hexadecimal:

```
a3b5c7d9e1f2...  (64 caracteres hex)
```

Para facilitar la verificación visual, Nexo ofrece formatos alternativos:

```swift
// Emojis (8 iconos)
"🍎🐶🌸⭐🍇🦊🌻🌙"

// Palabras (6 palabras)
"alfa luna mesa sol pez casa"

// Grupos de 4 caracteres
"A3B5 C7D9 E1F2 ..."
```

## Modelo TOFU

### Primera Conexión

Cuando dos dispositivos se conectan por primera vez:

```
Dispositivo A                    Dispositivo B
     |                                |
     |-------- TLS Handshake -------->|
     |<------- TLS Handshake ---------|
     |                                |
     |  [Conexión cifrada establecida]|
     |                                |
     |------ Hello (fingerprint) ---->|
     |<----- Hello (fingerprint) -----|
     |                                |
     |  [UI muestra "Nuevo dispositivo"]
     |  [Usuario decide confiar o no] |
```

El canal ya está cifrado antes de intercambiar fingerprints. Esto significa:
- Un atacante no puede ver los fingerprints en tránsito
- Un atacante tendría que presentar su propio certificado (detectable)

### Estados de Verificación

| Estado | Significado | Seguridad |
|--------|-------------|-----------|
| `unknown` | Primera conexión, sin historial | ⚠️ No verificado |
| `trustedOnFirstUse` | Fingerprint almacenado en primera conexión | 🔒 Cifrado, TOFU |
| `verified` | Usuario verificó fingerprint fuera de banda | ✅ Máxima |
| `identityChanged` | Fingerprint diferente al almacenado | 🚨 Posible MITM |

### Detección de Cambio de Identidad

Si un peer presenta un fingerprint diferente al almacenado:

```swift
let state = verificationService.verify(peer)
if state == .identityChanged {
    // Alertar al usuario: posible ataque o reinstalación
}
```

Causas legítimas:
- El peer reinstaló la app
- El peer cambió de dispositivo
- El peer borró el Keychain

Causa maliciosa:
- Ataque Man-in-the-Middle

## Verificación Fuera de Banda

Para máxima seguridad, los usuarios pueden verificar fingerprints:

### Comparación Visual

```swift
let myInfo = verificationService.identityInfo(for: localPeer)
print("Mi fingerprint: \(myInfo.emojiFingerprint)")
// "🍎🐶🌸⭐🍇🦊🌻🌙"

// El otro usuario lee su fingerprint en voz alta
// Si coinciden, marcar como verificado:
verificationService.markAsVerified(peer)
```

### Código QR

```swift
// Generar QR con mi identidad
let qrData = NexoVerificationQRData(
    applicationID: myAppID,
    displayName: myName,
    fingerprint: myFingerprint
)

// El otro dispositivo escanea y verifica
if scannedData.matches(connectedPeer) {
    verificationService.markAsVerified(peer)
}
```

## Arquitectura TLS

### Configuración del Transporte

```swift
// TCP con TLS para mensajes de control (JSON)
Coder(P2PFrame.self, using: .json) {
    TLS {
        TCP {
            IP()
        }
    }
}

// QUIC con TLS para datos binarios grandes
QUIC(alpn: ["nexo-binary-v1"]) {
    UDP {
        IP()
    }
}
```

### Validador de Certificados

El validador por defecto acepta cualquier certificado autofirmado:

```swift
NexoTLSConfiguration(identity: identity) { trust in
    // Extraer certificado del peer
    let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
    guard let leaf = SecTrustCopyCertificateChain(secTrust)?.first else {
        return false
    }
    
    // Aceptar como ancla y evaluar
    SecTrustSetAnchorCertificates(secTrust, [leaf])
    SecTrustSetAnchorCertificatesOnly(secTrust, true)
    return SecTrustEvaluateWithError(secTrust, nil)
}
```

Para pinning estricto (flotas gestionadas):

```swift
NexoTLSConfiguration(
    identity: identity,
    pinnedPublicKey: expectedPublicKeyData
)
```

## Consideraciones de Seguridad

### Lo que Nexo protege

- ✅ Confidencialidad del tráfico (cifrado TLS 1.3)
- ✅ Integridad de mensajes (AEAD)
- ✅ Detección de cambio de identidad
- ✅ Persistencia segura de claves (Keychain)

### Lo que Nexo NO protege

- ❌ Autenticación inicial (requiere verificación fuera de banda)
- ❌ Identidad del applicationID (autodeclarado)
- ❌ Metadatos de red (quién habla con quién es visible localmente)

### Recomendaciones

1. **Para apps casuales**: TOFU es suficiente. Confía en la primera conexión.

2. **Para datos sensibles**: Implementa verificación de fingerprints antes de compartir información importante.

3. **Para flotas gestionadas**: Usa una CA privada y distribuye certificados por MDM.

```swift
// Ejemplo: verificar antes de enviar datos sensibles
guard verificationService.verify(peer) == .verified else {
    showAlert("Verifica la identidad del destinatario primero")
    return
}
sendSensitiveData(to: peer)
```

## Migración desde Trust Store v1

El nuevo `NexoEnhancedTrustStore` usa un formato diferente. Los peers confiados con la versión anterior deberán ser re-verificados.

Para migrar datos existentes del `NexoPeerTrustStore` original:

```swift
// En el arranque de la app, una sola vez
if !UserDefaults.standard.bool(forKey: "nexo.trust.migrated") {
    // La migración ocurre automáticamente al verificar peers existentes
    UserDefaults.standard.set(true, forKey: "nexo.trust.migrated")
}
```
