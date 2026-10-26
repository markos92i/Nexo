import Foundation
import Testing
@testable import Nexo

@Suite("SessionCrypto (PSK)")
struct SessionCryptoTests {

    @Test("Misma app + mismo código producen la misma PSK")
    func samePSKForSameInputs() {
        let a = SessionCrypto(appSecret: "mi-app", roomCode: "ABCD1234")
        let b = SessionCrypto(appSecret: "mi-app", roomCode: "ABCD1234")
        #expect(a.psk == b.psk)
        #expect(a.pskHint == b.pskHint)
        #expect(a == b)
    }

    @Test("Distinto código de sala produce distinta PSK")
    func differentRoomCodeDiffersPSK() {
        let a = SessionCrypto(appSecret: "mi-app", roomCode: "ABCD1234")
        let b = SessionCrypto(appSecret: "mi-app", roomCode: "WXYZ9999")
        #expect(a.psk != b.psk)
        #expect(a.pskHint != b.pskHint)
    }

    @Test("Distinto secreto de app produce distinta PSK")
    func differentAppSecretDiffersPSK() {
        let a = SessionCrypto(appSecret: "app-uno", roomCode: "ABCD1234")
        let b = SessionCrypto(appSecret: "app-dos", roomCode: "ABCD1234")
        #expect(a.psk != b.psk)
    }

    @Test("El canal común (sin código) difiere del canal aislado por sala")
    func appChannelDiffersFromRoomChannel() {
        let common = SessionCrypto(appSecret: "mi-app")
        let room = SessionCrypto(appSecret: "mi-app", roomCode: "ABCD1234")
        #expect(common.psk != room.psk)
    }

    @Test("La PSK es de 32 bytes (HMAC-SHA256)")
    func pskIs32Bytes() {
        let crypto = SessionCrypto(appSecret: "mi-app", roomCode: "sala")
        #expect(crypto.psk.count == 32)
    }

    @Test("El hint es derivado estable de 32 hex (16 bytes)")
    func hintIsStable() {
        let crypto = SessionCrypto(appSecret: "mi-app", roomCode: "sala")
        #expect(crypto.pskHint.count == 32)
        #expect(crypto.pskHint == SessionCrypto.hint(for: crypto.psk))
    }

    @Test("appSecret como Data y como String UTF-8 coinciden")
    func dataAndStringSecretsMatch() {
        let fromString = SessionCrypto(appSecret: "mi-app", roomCode: "sala")
        let fromData = SessionCrypto(appSecret: Data("mi-app".utf8), roomCode: "sala")
        #expect(fromString.psk == fromData.psk)
    }
}
