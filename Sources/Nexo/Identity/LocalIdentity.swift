import Foundation
import Security

// MARK: - LocalIdentity

/// Identidad local del dispositivo.
///
/// El `deviceID` lo genera y persiste Nexo la primera vez y lo recupera en
/// arranques posteriores. El nombre visible lo edita el usuario y se propaga al
/// TXT de Bonjour y a los mensajes salientes. La identidad **no** es
/// criptográfica: el cifrado lo aporta la PSK (`SessionCrypto`).
@NexoActor
public final class LocalIdentity {

    public nonisolated let deviceID: DeviceID
    public var displayName: String
    /// Token de avatar opaco (clave de catálogo o miniatura codificada) publicado
    /// a los peers junto al nombre visible.
    public var avatar: String?

    nonisolated init(deviceID: DeviceID, displayName: String, avatar: String? = nil) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.avatar = avatar
    }

    /// Genera o recupera el `DeviceID` persistido en Keychain. Es síncrono (una
    /// lectura de Keychain), así que la app puede montar la pila en su init.
    public nonisolated static func loadOrCreate(
        displayName: String,
        avatar: String? = nil
    ) throws(IdentityError) -> LocalIdentity {
        let deviceID = try DeviceIDStore.loadOrCreate()
        return LocalIdentity(deviceID: deviceID, displayName: displayName, avatar: avatar)
    }

    /// Identidad válida solo para esta ejecución, sin tocar Keychain.
    ///
    /// Para previews y tests. No la uses para salir a la red cuando
    /// `loadOrCreate` falla: los demás verían un dispositivo distinto en cada
    /// arranque. Lo correcto es no arrancar el transporte y reintentar.
    public nonisolated static func temporary(displayName: String, avatar: String? = nil) -> LocalIdentity {
        LocalIdentity(deviceID: DeviceID(), displayName: displayName, avatar: avatar)
    }

    public func member(role: RoomRole) -> RoomMember {
        RoomMember(
            deviceID: deviceID,
            displayName: displayName,
            role: role,
            avatar: avatar
        )
    }
}

// MARK: - DeviceIDStore

/// Persistencia del `DeviceID` en Keychain. Un único valor por instalación,
/// accesible solo en este dispositivo tras el primer desbloqueo.
enum DeviceIDStore {

    private static let service = "com.nexo.identity.device-id"
    private static let account = "default"

    static func loadOrCreate() throws(IdentityError) -> DeviceID {
        do {
            if let existing = try load() {
                return existing
            }
        } catch .invalidStoredData {
            // Waiting will never fix a corrupt value: replace it once, and the
            // new ID is permanent from then on.
        }
        let created = DeviceID()
        try store(created)
        return created
    }

    static func load() throws(IdentityError) -> DeviceID? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw .keychainReadFailed(status) }
        guard let data = result as? Data,
              let string = String(data: data, encoding: .utf8),
              let deviceID = DeviceID(string: string) else {
            throw .invalidStoredData
        }
        return deviceID
    }

    static func store(_ deviceID: DeviceID) throws(IdentityError) {
        let data = Data(deviceID.description.utf8)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)

        guard status != errSecDuplicateItem else {
            let updateStatus = SecItemUpdate([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account,
            ] as CFDictionary, [kSecValueData: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw .keychainWriteFailed(updateStatus) }
            return
        }
        guard status == errSecSuccess else { throw .keychainWriteFailed(status) }
    }

    /// Borra el `DeviceID` almacenado. Para tests o reseteo de identidad.
    static func reset() throws(IdentityError) {
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw .keychainWriteFailed(status)
        }
    }
}
