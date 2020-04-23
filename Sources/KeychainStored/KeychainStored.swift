import Foundation
import Security

/// A value that is stored in the keychain.
@propertyWrapper
public struct KeychainStored<Value: Codable, ValueEncoder: TopLevelEncoder, ValueDecoder: TopLevelDecoder> where ValueEncoder.Output == Data, ValueDecoder.Input == Data {
    
    /// A closure that can log strings.
    public typealias Logger = ((String) -> Void)
    
    // MARK: State
    
    /// The security class for the item.
    private let securityClass = kSecClassGenericPassword
    
    /// The value for `kSecAttrService`.
    public let service: String
    
    /// The value for `kSecAttrAccessGroup `.
    public let group: String?
    
    /// The value for
    public let synchronizable: Bool
    
    /// The value that is stored in the keychain.
    public var wrappedValue: Value? {
        didSet {
            storeValueInKeychain(wrappedValue)
        }
    }
    
    /// The logger used to log errors.
    private let logger: Logger?
    
    /// The encoder used to encode values.
    private let encoder: ValueEncoder
    
    /// The decoder used to decode values.
    private let decoder: ValueDecoder
    
    // MARK: Init
    
    /// Initialise a keychain stored value.
    /// - parameter service: An identifier for the value, stored in `kSecAttrService`.
    /// - parameter logger: When set, errors are logged using this closure.
    /// - parameter encoder: The encoder to use to encode values. Note that the encoder is not used if the value is a String – they are stored directly as UTF-8 instead.
    /// - parameter decoder: The decoder to use to decode values. Note that the decoder is not used if the value is a String – they are stored directly as UTF-8 instead.
    public init(service: String, group: String? = nil, synchronizable: Bool = false, logger: Logger? = { print($0) }, encoder: ValueEncoder, decoder: ValueDecoder) {
        self.service = service
        self.logger = logger
        self.encoder = encoder
        self.decoder = decoder
        self.group = group
        self.synchronizable = synchronizable
        
        self.wrappedValue = loadValueFromKeychain()
    }
    
    // MARK: - Keychain interactions
    
    // MARK: Query
    
    private var searchQuery: [String: Any] {
        var query = [
            kSecClass as String: securityClass,
            kSecAttrService as String: service,
            kSecAttrSynchronizable: synchronizable
        ] as [String : Any]
        
        if let group = group {
            query[kSecAttrAccessGroup as String] = group
        }
        
        return query
    }
    
    // MARK: Loading the value from the keychain
    
    /// Loads the value from the keychain.
    private func loadValueFromKeychain() -> Value? {
        var searchQuery = self.searchQuery
        searchQuery[kSecReturnAttributes as String] = true
        searchQuery[kSecReturnData as String] = true
        
        var unknownItem: CFTypeRef?
        let status = SecItemCopyMatching(searchQuery as CFDictionary, &unknownItem)
        
        guard status != errSecItemNotFound else {
            return nil // No value isn't an error
        }
        
        guard status == errSecSuccess else {
            reportError(status, operation: "loading")
            return nil
        }
        
        guard let item = unknownItem as? [String: Any], let data = item[kSecValueData as String] as? Data else {
            reportError(KeychainStoredError.unexpectedData, operation: "loading")
            return nil
        }
        
        return decodeValue(from: data)
    }
    
    /// Decodes the value from the given data.
    private func decodeValue(from data: Data) -> Value? {
        if Value.self == String.self {
            return String(data: data, encoding: .utf8) as! Value?
        } else {
            do {
                return try self.decoder.decode(Value.self, from: data)
            } catch {
                reportError(error, operation: "decoding")
                return nil
            }
        }
    }
    
    // MARK: Storing the value in the keychain
    
    /// Stores the given `value` in the keychain.
    private func storeValueInKeychain(_ value: Value?) {
        guard let encoded = encodeValue(value) else {
            deleteFromKeychain()
            return
        }
        
        var attributes: [String: Any] = [
            kSecValueData as String: encoded
        ]
        
        if synchronizable {
            attributes[kSecAttrSynchronizable as String] = true
        }
        
        var status = SecItemUpdate(
            searchQuery as CFDictionary,
            attributes as CFDictionary
        )
        
        if status == errSecItemNotFound {
            /// Add the item if there was nothing to update.
            let addQuery = searchQuery.merging(attributes, uniquingKeysWith: { (_, new) in new })
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        
        guard status == errSecSuccess else {
            reportError(status, operation: "storing")
            return
        }
    }
    
    /// Encodes the given value to data.
    private func encodeValue(_ value: Value?) -> Data? {
        guard let value = value else {
            return nil
        }
        
        if Value.self == String.self {
            let string = value as! String
            return Data(string.utf8)
        } else {
            do {
                return try encoder.encode(value)
            } catch {
                reportError(error, operation: "encoding")
                return nil
            }
        }
    }
    
    // MARK: Deleting the value
    
    /// Deletes the item from the keychain.
    private func deleteFromKeychain() {
        let status = SecItemDelete(self.searchQuery as CFDictionary)
        
        guard status == errSecSuccess || status == errSecItemNotFound else {
            reportError(status, operation: "deleting")
            return
        }
    }
    
    // MARK: - Reporting Errors
    
    /// - parameter status: The error to report.
    /// - parameter operation: Will be used like this: "Error while \(operation) keychain item ..."
    private func reportError(_ status: OSStatus, operation: String) {
        guard let logger = self.logger else { return }
        
        if #available(iOS 11.3, tvOS 11.3, watchOS 4.3, *), let error = SecCopyErrorMessageString(status, nil) {
            logger("Error while \(operation) keychain item for service \(service): \(error)")
        } else {
            logger("Error while \(operation) keychain item for service \(service): \(status)")
        }
    }
    
    /// - parameter status: The error to report.
    /// - parameter operation: Will be used like this: "Error while \(operation) keychain item ..."
    private func reportError(_ error: Error, operation: String) {
        guard let logger = self.logger else { return }
        
        logger("Error while \(operation) keychain item for service \(service): \(error)")
    }
}

extension KeychainStored where ValueEncoder == JSONEncoder, ValueDecoder == JSONDecoder {
    /// This initialiser exists so you can use `@KeychainStored` like this: `@KeychainStored(service: "com.example") var mySecret: String?`.
    /// Therefore, it defaults to using a standard `JSONEncoder` and `JSONDecoder`.
    ///
    /// Initialise a keychain stored value.
    /// - parameter service: An identifier for the value, stored in `kSecAttrService`.
    /// - parameter logger: When set, errors are logged using this closure.
    /// - parameter encoder: The encoder to use to encode values. Note that the encoder is not if the value is a String – they are stored directly as UTF-8 instead.
    /// - parameter decoder: The decoder to use to decode values. Note that the decoder is not if the value is a String – they are stored directly as UTF-8 instead.
    public init(service: String, group: String? = nil, synchronizable: Bool = false, logger: Logger? = { print($0) }, jsonEncoder encoder: ValueEncoder = .init(), jsonDecoder decoder: ValueDecoder = .init()) {
        /// note: The argument labels are `jsonEncoder` / `jsonDecoder` instead of just `encoder` / `decoder` because otherwise this init would call itself.
        self.init(service: service, group: group, synchronizable: synchronizable, logger: logger, encoder: encoder, decoder: decoder)
    }
}

enum KeychainStoredError: Error {
    case unexpectedData
}
