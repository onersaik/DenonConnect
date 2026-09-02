// StateValue.swift
// El servicio StateMap envía cada valor como una cadena JSON embebida en el
// mensaje binario. La forma exacta del JSON depende del tipo de estado
// (string, número, booleano o color), así que todos los campos son opcionales.

import Foundation

public struct StateValue: Decodable {
    public let type: Int?
    public let string: String?
    public let value: Double?
    public let state: Bool?
    public let color: String?
}

public enum StateValueCodec {
    public static func decode(_ jsonString: String) -> StateValue? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StateValue.self, from: data)
    }
}
