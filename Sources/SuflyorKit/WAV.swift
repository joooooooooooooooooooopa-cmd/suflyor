import Foundation

/// Сборка WAV целиком в памяти: звук не должен попадать на диск даже временно.
public enum WAV {
    /// PCM 16 бит, моно. whisper.cpp сам приводит к float, 16 бит вдвое легче float32 в запросе.
    public static func encode(samples: [Float], sampleRate: Int = 16_000) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = samples.count * blockAlign

        var d = Data(capacity: 44 + dataSize)
        d.append(contentsOf: Array("RIFF".utf8))
        d.appendLE(UInt32(36 + dataSize))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.appendLE(UInt32(16))             // размер fmt-чанка для PCM
        d.appendLE(UInt16(1))              // формат 1 = PCM
        d.appendLE(UInt16(channels))
        d.appendLE(UInt32(sampleRate))
        d.appendLE(UInt32(byteRate))
        d.appendLE(UInt16(blockAlign))
        d.appendLE(UInt16(bitsPerSample))
        d.append(contentsOf: Array("data".utf8))
        d.appendLE(UInt32(dataSize))
        for s in samples {
            let clamped = max(-1, min(1, s))
            d.appendLE(Int16(clamped * Float(Int16.max)))
        }
        return d
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

/// multipart/form-data в памяти: whisper-server принимает файл только так.
public struct Multipart {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "suflyor-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    public mutating func addFile(_ name: String, filename: String, mime: String, data: Data) {
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    public func finalized() -> Data {
        var d = body
        d.append(Data("--\(boundary)--\r\n".utf8))
        return d
    }
}
