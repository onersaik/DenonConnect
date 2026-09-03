// StateValue.swift
// El servicio StateMap envía cada valor como una cadena JSON embebida en el
// mensaje binario. Engine OS / nowplaying usa {type,string,value,state,color}
// pero a veces omiten `type` o mandan el literal JSON (string/número/bool).

import Foundation

public struct StateValue: Decodable {
    public let type: Int?
    public let string: String?
    public let value: Double?
    public let state: Bool?
    public let color: String?

    public init(type: Int? = nil, string: String? = nil, value: Double? = nil,
                state: Bool? = nil, color: String? = nil) {
        self.type = type
        self.string = string
        self.value = value
        self.state = state
        self.color = color
    }
}

public enum StateValueCodec {
    public static func decode(_ jsonString: String) -> StateValue? {
        let trimmed = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONDecoder().decode(StateValue.self, from: data) {
            return obj
        }

        // Literal JSON: "texto" / 128.0 / true
        if let data = trimmed.data(using: .utf8),
           let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let s = any as? String { return StateValue(string: s) }
            if let b = any as? Bool { return StateValue(state: b) }
            if let d = any as? Double { return StateValue(value: d) }
            if let i = any as? Int { return StateValue(value: Double(i)) }
            if let n = any as? NSNumber {
                // Evitar tratar Bool embebido en NSNumber como 0/1 numérico a ciegas.
                let t = String(cString: n.objCType)
                if t == "B" || t == "c" { return StateValue(state: n.boolValue) }
                return StateValue(value: n.doubleValue)
            }
            if let dict = any as? [String: Any] {
                return StateValue(
                    type: dict["type"] as? Int,
                    string: dict["string"] as? String ?? dict["str"] as? String,
                    value: (dict["value"] as? NSNumber)?.doubleValue
                        ?? (dict["val"] as? NSNumber)?.doubleValue,
                    state: dict["state"] as? Bool ?? dict["bool"] as? Bool,
                    color: dict["color"] as? String
                )
            }
        }

        // Texto plano (raro, pero visto en capturas viejas)
        if trimmed.hasPrefix("\"") == false, !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") {
            return StateValue(string: trimmed)
        }
        return nil
    }

    public static func asString(_ v: StateValue) -> String? {
        if let s = v.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        return nil
    }

    public static func asDouble(_ v: StateValue) -> Double? {
        if let d = v.value, d.isFinite { return d }
        if let s = v.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           let d = Double(s.replacingOccurrences(of: ",", with: ".")), d.isFinite {
            return d
        }
        return nil
    }

    public static func asBool(_ v: StateValue) -> Bool? {
        if let b = v.state { return b }
        if let d = v.value {
            if d == 0 { return false }
            if d == 1 { return true }
        }
        if let s = v.string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if s == "true" || s == "1" || s == "yes" || s == "on" { return true }
            if s == "false" || s == "0" || s == "no" || s == "off" { return false }
        }
        return nil
    }
}
