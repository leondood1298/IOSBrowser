import CommonCrypto
import Foundation

/// Decrypts HLS segments encrypted with METHOD=AES-128: AES-128 in CBC mode with PKCS7 padding.
public enum SegmentDecryptor {
    public enum Failure: Error, Equatable {
        case badKey
        case failed(Int32)
    }

    public static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else { throw Failure.badKey }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inBytes.baseAddress, data.count, outBytes.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw Failure.failed(status) }
        output.count = written
        return output
    }
}
