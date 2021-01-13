//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc
public extension OWSUserProfile {

    // The max bytes for a user's profile name, encoded in UTF8.
    // Before encrypting and submitting we NULL pad the name data to this length.
    static let kMaxNameLengthBytes: UInt = 128

    static let kMaxBioLengthChars: UInt = 100
    static let kMaxBioLengthBytes: UInt = 512

    static let kMaxBioEmojiLengthChars: UInt = 1
    static let kMaxBioEmojiLengthBytes: UInt = 32

    // MARK: - Encryption

    @objc(encryptProfileData:profileKey:)
    class func encrypt(profileData: Data, profileKey: OWSAES256Key) -> Data? {
        assert(profileKey.keyData.count == kAES256_KeyByteLength)
        return Cryptography.encryptAESGCMProfileData(plainTextData: profileData, key: profileKey)
    }

    @objc(decryptProfileData:profileKey:)
    class func decrypt(profileData: Data, profileKey: OWSAES256Key) -> Data? {
        assert(profileKey.keyData.count == kAES256_KeyByteLength)
        return Cryptography.decryptAESGCMProfileData(encryptedData: profileData, key: profileKey)
    }

    @objc(decryptProfileNameData:profileKey:)
    class func decrypt(profileNameData: Data, profileKey: OWSAES256Key) -> PersonNameComponents? {
        guard let decryptedData = decrypt(profileData: profileNameData, profileKey: profileKey) else { return nil }

        // Unpad profile name. The given and family name are stored
        // in the string like "<given name><null><family name><null padding>"
        let nameSegments: [Data] = decryptedData.split(separator: 0x00)

        // Given name is required
        guard nameSegments.count > 0,
            let givenName = String(data: nameSegments[0], encoding: .utf8), !givenName.isEmpty else {
                owsFailDebug("unexpectedly missing first name")
                return nil
        }

        // Family name is optional
        let familyName: String?
        if nameSegments.count > 1 {
            familyName = String(data: nameSegments[1], encoding: .utf8)
        } else {
            familyName = nil
        }

        var nameComponents = PersonNameComponents()
        nameComponents.givenName = givenName
        nameComponents.familyName = familyName
        return nameComponents
    }

    @objc(encryptProfileNameComponents:profileKey:)
    class func encrypt(profileNameComponents: PersonNameComponents, profileKey: OWSAES256Key) -> ProfileValue? {
        guard var paddedNameData = profileNameComponents.givenName?.data(using: .utf8) else { return nil }
        if let familyName = profileNameComponents.familyName {
            // Insert a null separator
            paddedNameData.count += 1
            guard let familyNameData = familyName.data(using: .utf8) else { return nil }
            paddedNameData.append(familyNameData)
        }

        // Two names plus null separator.
        //
        // TODO: Padding constants?
        let totalNameLength = Int(kMaxNameLengthBytes) * 2 + 1
        owsAssertDebug(totalNameLength == 257)
        let paddedLengths = [53, 257 ]
        let validBase64Lengths: [Int] = [108, 380 ]

        // All encrypted profile names should be the same length on the server,
        // so we pad out the length with null bytes to the maximum length.
        return encrypt(stringData: paddedNameData,
                       profileKey: profileKey,
                       paddedLengths: paddedLengths,
                       validBase64Lengths: validBase64Lengths)
    }

    class func encrypt(string: String,
                       profileKey: OWSAES256Key,
                       paddedLengths: [Int],
                       validBase64Lengths: [Int]) -> ProfileValue? {
        guard let stringData = string.data(using: .utf8) else {
            owsFailDebug("Invalid value.")
            return nil
        }
        return encrypt(stringData: stringData,
                       profileKey: profileKey,
                       paddedLengths: paddedLengths,
                       validBase64Lengths: validBase64Lengths)
    }

    class func encrypt(stringData: Data,
                       profileKey: OWSAES256Key,
                       paddedLengths: [Int],
                       validBase64Lengths: [Int]) -> ProfileValue? {

        guard paddedLengths == paddedLengths.sorted() else {
            owsFailDebug("paddedLengths have incorrect ordering.")
            return nil
        }

        guard let paddedData = ({ () -> Data? in
            for paddedLength in paddedLengths {
                owsAssertDebug(paddedLength > 0)

                guard stringData.count <= paddedLength else {
                    continue
                }

                var paddedData = stringData
                let paddingByteCount = paddedLength - paddedData.count
                paddedData.count += paddingByteCount

                assert(paddedData.count == paddedLength)
                return paddedData
            }
            owsFailDebug("Oversize value: \(stringData.count) > \(paddedLengths)")
            return nil
        }()) else {
            owsFailDebug("Could not pad value.")
            return nil
        }

        guard let encrypted = encrypt(profileData: paddedData, profileKey: profileKey) else {
            owsFailDebug("Could not encrypt.")
            return nil
        }
        let value = ProfileValue(encrypted: encrypted, validBase64Lengths: validBase64Lengths)
        guard value.hasValidBase64Length else {
            owsFailDebug("Value has invalid base64 length.")
            return nil
        }
        return value
    }
}

// MARK: -

@objc
public class ProfileValue: NSObject {
    let encrypted: Data

    let validBase64Lengths: [Int]

    required init(encrypted: Data,
                  validBase64Lengths: [Int]) {
        self.encrypted = encrypted
        self.validBase64Lengths = validBase64Lengths
    }

    @objc
    var encryptedBase64: String {
        encrypted.base64EncodedString()
    }

    @objc
    var hasValidBase64Length: Bool {
        validBase64Lengths.contains(encryptedBase64.count)
    }
}
