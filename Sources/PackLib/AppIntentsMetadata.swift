import Foundation

/// Generates the `Metadata.appintents` bundle that iOS reads to discover App Intents
/// (`AppIntent`, `AppShortcutsProvider`), standing in for Xcode's macOS-only
/// `appintentsmetadataprocessor`.
///
/// The input is the `.swiftconstvalues` files that the Swift compiler emits for types
/// conforming to the protocols in the SDK's `SwiftConstantValues/AppIntents.json`.
/// They carry each type's exact mangled name, which is what the system uses to find the
/// intent in the binary, along with the literal values of its static properties and
/// parameter declarations. The output mirrors the format written by Xcode 26.
///
/// Only a subset of App Intents is supported: intents whose parameters are `String` or
/// `Bool` (optional or not), and App Shortcuts built from plain phrases. Anything else
/// is skipped with a warning rather than described incorrectly.
public struct AppIntentsMetadata: Sendable {
    public static let directoryName = "Metadata.appintents"

    /// Shown as the generator in the output. Defaults to the Xcode build that the
    /// reference output was taken from.
    public var toolsVersion = "17C529"

    private var actions: [String: JSONValue] = [:]
    private var autoShortcuts: [JSONValue] = []
    private var autoShortcutProvider = ""
    public private(set) var warnings: [String] = []

    public var isEmpty: Bool { actions.isEmpty }

    public init(toolsVersion: String? = nil) {
        if let toolsVersion { self.toolsVersion = toolsVersion }
    }

    /// Reads the types that belong to `modules` from the given `.swiftconstvalues` files.
    public init(constValueFiles: [URL], modules: Set<String>, toolsVersion: String? = nil) throws {
        self.init(toolsVersion: toolsVersion)
        var seen: Set<String> = []
        var types: [ConstType] = []
        for file in constValueFiles {
            let data = try Data(contentsOf: file)
            guard !data.isEmpty, case .array(let entries) = try JSONDecoder().decode(JSONValue.self, from: data) else {
                continue
            }
            for entry in entries {
                guard let type = ConstType(entry), modules.contains(type.module) else { continue }
                // stale outputs of deleted sources, and one copy per architecture
                if let source = type.file, !FileManager.default.fileExists(atPath: source) { continue }
                guard seen.insert(type.mangledName).inserted else { continue }
                types.append(type)
            }
        }
        add(types: types)
    }

    mutating func add(types: [ConstType]) {
        let sorted = types.sorted { $0.name < $1.name }
        var identifiers: [String: String] = [:]
        for type in sorted where type.conforms(to: "AppIntents.AppIntent") {
            if let action = action(for: type) {
                identifiers[type.name] = type.identifier
                actions[type.identifier] = action
            }
        }
        for type in sorted where type.conforms(to: "AppIntents.AppShortcutsProvider") {
            addShortcuts(from: type, identifiers: identifiers)
        }
    }

    /// Writes `Metadata.appintents` into `bundle` (the .app or .appex directory).
    public func write(into bundle: URL) throws {
        let directory = bundle.appendingPathComponent(Self.directoryName, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try extractData().write(to: directory.appendingPathComponent("extract.actionsdata"))
        try versionData().write(to: directory.appendingPathComponent("version.json"))
    }

    func extractData() throws -> Data {
        let root: JSONValue = .object([
            "actions": .object(actions),
            "assistantEntities": .array([]),
            "assistantIntentNegativePhrases": .array([]),
            "assistantIntents": .array([]),
            "autoShortcutProviderMangledName": .string(autoShortcutProvider),
            "autoShortcuts": .array(autoShortcuts),
            "entities": .object([:]),
            "enums": .array([]),
            "generator": .object(["name": "xcode-tools", "version": .string(toolsVersion)]),
            "negativePhrases": .array([]),
            "queries": .object([:]),
            "shortcutTileColor": 14,
            "version": 1,
        ])
        return try Self.encode(root)
    }

    func versionData() throws -> Data {
        try Self.encode(.object(["toolsVersion": .string(toolsVersion), "version": "3.0"]))
    }

    private static func encode(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    // MARK: - Actions

    private mutating func action(for type: ConstType) -> JSONValue? {
        guard let title = type.staticProperty("title")?.string else {
            warn("\(type.name): skipping App Intent without a literal `static let title`")
            return nil
        }

        var parameters: [JSONValue] = []
        for property in type.properties where property.isParameter {
            if let parameter = parameter(for: property, in: type) {
                parameters.append(parameter)
            }
        }

        let openApp = type.staticProperty("openAppWhenRun")?.bool ?? false
        let discoverable = type.staticProperty("isDiscoverable")?.bool ?? true
        var action: [String: JSONValue] = [
            "assistantDefinedSchemaTraits": .array([]),
            "assistantDefinedSchemas": .array([]),
            "authenticationPolicy": 0,
            "availabilityAnnotations": type.availabilityAnnotations,
            "effectiveBundleIdentifiers": .array([]),
            "fullyQualifiedTypeName": .string(type.name),
            "identifier": .string(type.identifier),
            "isAuthPolExplicit": false,
            "isDiscoverable": .bool(discoverable),
            "mangledTypeName": .string(type.mangledName),
            "mangledTypeNameByBundleIdentifier": .object([:]),
            "mangledTypeNameByBundleIdentifierV2": .object([:]),
            "mangledTypeNameV2": .string(type.mangledName),
            "openAppWhenRun": .bool(openApp),
            "outputFlags": 0,
            "parameters": .array(parameters),
            "presentationStyle": 0,
            "requiredCapabilities": .array([]),
            "systemProtocolMetadata": .array([]),
            "systemProtocolMetadataV2": .array([]),
            "systemProtocols": .array([]),
            "title": Self.localized(title),
            "typeSpecificMetadata": .array([]),
            "visibilityMetadata": .object(["assistantOnly": false, "isDiscoverable": .bool(discoverable)]),
        ]
        // Xcode only writes `supportedModes: 1` (background) for intents that don't open the
        // app. Leave it out otherwise, so the system falls back to `openAppWhenRun`.
        if !openApp {
            action["supportedModes"] = 1
        }
        if let description = type.staticProperty("description")?.firstString {
            action["descriptionMetadata"] = .object([
                "descriptionText": Self.localized(description),
                "searchKeywords": .array([]),
            ])
        }
        return .object(action)
    }

    private mutating func parameter(for property: ConstProperty, in type: ConstType) -> JSONValue? {
        var valueTypeName = property.type
        var isOptional = false
        if let wrapped = Self.genericArgument(of: "Swift.Optional", in: valueTypeName) {
            valueTypeName = wrapped
            isOptional = true
        }
        guard let primitive = Primitive(typeName: valueTypeName) else {
            warn("""
            \(type.name).\(property.label): skipping parameter of type '\(property.type)'; \
            only String and Bool parameters are supported
            """)
            return nil
        }

        let arguments = property.initArguments
        var parameter: [String: JSONValue] = [
            "capabilities": 1,
            "dynamicOptionsSupport": 0,
            "inputConnectionBehavior": 0,
            "isInput": false,
            "isOptional": .bool(isOptional),
            "name": .string(property.label),
            "resolvableInputTypes": .array(primitive.resolvableInputTypes),
            "title": Self.localized(arguments["title"]?.string ?? property.label),
            "typeSpecificMetadata": .array([]),
            "valueType": primitive.valueType,
        ]
        if let description = arguments["description"]?.string {
            parameter["parameterDescription"] = Self.localized(description)
        }
        if let defaultValue = arguments["default"].flatMap(primitive.defaultValue) {
            parameter["typeSpecificMetadata"] = .array(["LNValueTypeSpecificMetadataKeyDefaultValue", defaultValue])
        }
        return .object(parameter)
    }

    // MARK: - App Shortcuts

    private mutating func addShortcuts(from provider: ConstType, identifiers: [String: String]) {
        guard let builder = provider.staticProperty("appShortcuts"),
              builder.valueKind == "Builder",
              case .array(let members)? = builder.value?["members"]
        else {
            warn("\(provider.name): skipping App Shortcuts that aren't declared with the result builder")
            return
        }
        guard autoShortcutProvider.isEmpty else {
            warn("\(provider.name): skipping a second AppShortcutsProvider; an app can only have one")
            return
        }
        autoShortcutProvider = provider.mangledName

        for member in members {
            guard member["kind"]?.stringValue == "buildExpression",
                  let element = member["element"].map(ConstExpression.init),
                  element.valueKind == "InitCall"
            else {
                warn("\(provider.name): skipping an App Shortcut inside `if`, `for` or similar")
                continue
            }
            let arguments = element.arguments
            guard let intentType = arguments["intent"]?.value?["type"]?.stringValue,
                  let identifier = identifiers[intentType]
            else {
                warn("\(provider.name): skipping an App Shortcut whose intent wasn't found")
                continue
            }

            var phrases: [JSONValue] = []
            for phrase in arguments["phrases"]?.elements ?? [] {
                if let template = Self.phraseTemplate(phrase) {
                    phrases.append(Self.localized(template))
                } else {
                    warn("\(provider.name): skipping a phrase of '\(identifier)' that isn't a plain string literal")
                }
            }
            guard !phrases.isEmpty else { continue }

            var shortcut: [String: JSONValue] = [
                "actionIdentifier": .string(identifier),
                "availabilityAnnotations": Self.wildcardAvailability,
                "phraseTemplates": .array(phrases),
            ]
            if let shortTitle = arguments["shortTitle"]?.string {
                shortcut["shortTitle"] = Self.localized(shortTitle)
            }
            if let image = arguments["systemImageName"]?.string {
                shortcut["systemImageName"] = .string(image)
            }
            autoShortcuts.append(.object(shortcut))
        }
    }

    /// Turns `"Call \(.applicationName)"` into `"Call ${applicationName}"`.
    private static func phraseTemplate(_ phrase: ConstExpression) -> String? {
        switch phrase.valueKind {
        case "RawLiteral":
            return phrase.string
        case "InterpolatedStringLiteral":
            guard case .array(let segments)? = phrase.value?["segments"] else { return nil }
            var template = ""
            for segment in segments.map(ConstExpression.init) {
                switch segment.valueKind {
                case "RawLiteral":
                    template += segment.string ?? ""
                case "Enum" where segment.value?["name"]?.stringValue == "applicationName":
                    template += "${applicationName}"
                default:
                    return nil
                }
            }
            return template
        default:
            return nil
        }
    }

    // MARK: - Helpers

    private mutating func warn(_ message: String) {
        warnings.append(message)
    }

    static func localized(_ key: String) -> JSONValue {
        .object(["alternatives": .array([]), "key": .string(key)])
    }

    static let wildcardAvailability: JSONValue = .object([
        "LNPlatformNameWildcard": .object(["introducedVersion": "*"]),
    ])

    /// `genericArgument(of: "Swift.Optional", in: "Swift.Optional<Swift.String>") == "Swift.String"`
    static func genericArgument(of generic: String, in type: String) -> String? {
        guard type.hasPrefix("\(generic)<"), type.hasSuffix(">") else { return nil }
        return String(type.dropFirst(generic.count + 1).dropLast())
    }
}

/// Primitive App Intents value types, identified by `typeIdentifier` in the metadata.
private enum Primitive {
    case string
    case bool

    init?(typeName: String) {
        switch typeName {
        case "Swift.String": self = .string
        case "Swift.Bool": self = .bool
        default: return nil
        }
    }

    private static func primitive(_ identifier: Int) -> JSONValue {
        .object(["primitive": .object(["wrapper": .object(["typeIdentifier": .number(Double(identifier))])])])
    }

    var valueType: JSONValue {
        switch self {
        case .string: Self.primitive(0)
        case .bool: Self.primitive(1)
        }
    }

    /// Other kinds of values the system may coerce into this parameter.
    var resolvableInputTypes: [JSONValue] {
        func input(_ valueType: JSONValue) -> JSONValue {
            .object(["kindValue": 0, "valueType": valueType])
        }
        switch self {
        case .string:
            // AttributedString, [AttributedString], String
            let attributed = Self.primitive(2)
            let attributedArray: JSONValue = .object(["array": .object(["wrapper": .object([
                "capabilities": 3,
                "memberValueType": attributed,
            ])])])
            return [input(attributed), input(attributedArray), input(Self.primitive(0))]
        case .bool:
            return [input(Self.primitive(1))]
        }
    }

    func defaultValue(_ expression: ConstExpression) -> JSONValue? {
        guard expression.valueKind == "RawLiteral", let literal = expression.string else { return nil }
        switch self {
        case .string:
            return .object(["string": .object(["wrapper": .string(literal)])])
        case .bool:
            // Xcode stores Bool defaults as integers
            return .object(["int": .object(["wrapper": .number(literal == "true" ? 1 : 0)])])
        }
    }
}

// MARK: - Reading .swiftconstvalues

struct ConstType {
    var name: String
    var mangledName: String
    var file: String?
    var conformances: [String]
    var properties: [ConstProperty]
    var availability: [JSONValue]

    init?(_ json: JSONValue) {
        guard let name = json["typeName"]?.stringValue,
              let mangledName = json["mangledTypeName"]?.stringValue
        else { return nil }
        self.name = name
        self.mangledName = mangledName
        self.file = json["file"]?.stringValue
        self.conformances = json["conformances"]?.arrayValue?.compactMap(\.stringValue) ?? []
        self.properties = json["properties"]?.arrayValue?.map(ConstProperty.init) ?? []
        self.availability = json["availabilityAttributes"]?.arrayValue ?? []
    }

    var module: String { String(name.prefix { $0 != "." }) }

    /// The intent's identifier: its type name without the module (or enclosing types).
    var identifier: String { String(name.split(separator: ".").last ?? Substring(name)) }

    func conforms(to proto: String) -> Bool { conformances.contains(proto) }

    func staticProperty(_ label: String) -> ConstExpression? {
        properties.first { $0.isStatic && $0.label == label }?.expression
    }

    var availabilityAnnotations: JSONValue {
        var annotations: [String: JSONValue] = ["LNPlatformNameWildcard": .object(["introducedVersion": "*"])]
        for attribute in availability {
            guard attribute["isUnavailable"]?.boolValue != true,
                  let version = attribute["introducedVersion"]?.stringValue,
                  let platform = attribute["platform"]?.stringValue
            else { continue }
            let key = switch platform {
            case "iOS": "LNPlatformNameIOS"
            case "macOS": "LNPlatformNameMACOS"
            case "watchOS": "LNPlatformNameWATCHOS"
            case "tvOS": "LNPlatformNameTVOS"
            case "visionOS": "LNPlatformNameVISIONOS"
            default: ""
            }
            if !key.isEmpty {
                annotations[key] = .object(["introducedVersion": .string(version)])
            }
        }
        return .object(annotations)
    }
}

struct ConstProperty {
    var label: String
    var type: String
    var isStatic: Bool
    var expression: ConstExpression
    var wrapperTypes: [String]

    init(_ json: JSONValue) {
        label = json["label"]?.stringValue ?? ""
        type = json["type"]?.stringValue ?? ""
        isStatic = json["isStatic"]?.stringValue == "true"
        expression = ConstExpression(json)
        wrapperTypes = json["propertyWrappers"]?.arrayValue?.compactMap { $0["type"]?.stringValue } ?? []
    }

    /// The user-facing `@Parameter var foo` (rather than its `_foo` storage or `$foo` projection).
    var isParameter: Bool {
        !isStatic && wrapperTypes.contains("AppIntents.IntentParameter")
    }

    /// The labeled arguments of the property's initializer, e.g. `@Parameter(title:)`.
    var initArguments: [String: ConstExpression] { expression.arguments }
}

/// A value in a `.swiftconstvalues` file: `{"valueKind": ..., "value": ...}`.
struct ConstExpression {
    var valueKind: String
    var value: JSONValue?

    init(_ json: JSONValue) {
        valueKind = json["valueKind"]?.stringValue ?? ""
        value = json["value"]
    }

    var string: String? {
        valueKind == "RawLiteral" ? value?.stringValue : nil
    }

    var bool: Bool? {
        string.flatMap { Bool($0) }
    }

    /// The literal string of a value like `IntentDescription("...")`, or the value itself.
    var firstString: String? {
        if let string { return string }
        guard valueKind == "InitCall" else { return nil }
        return value?["arguments"]?.arrayValue?.first.map(ConstExpression.init)?.string
    }

    var arguments: [String: ConstExpression] {
        guard valueKind == "InitCall" else { return [:] }
        var arguments: [String: ConstExpression] = [:]
        for argument in value?["arguments"]?.arrayValue ?? [] {
            if let label = argument["label"]?.stringValue {
                arguments[label] = ConstExpression(argument)
            }
        }
        return arguments
    }

    var elements: [ConstExpression] {
        valueKind == "Array" ? (value?.arrayValue ?? []).map(ConstExpression.init) : []
    }
}

// MARK: - JSON

enum JSONValue: Codable, Sendable, Equatable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let string): try container.encode(string)
        case .number(let number):
            if number == number.rounded(), abs(number) < 1e15 {
                try container.encode(Int(number))
            } else {
                try container.encode(number)
            }
        case .bool(let bool): try container.encode(bool)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var stringValue: String? {
        if case .string(let string) = self { string } else { nil }
    }

    var boolValue: Bool? {
        if case .bool(let bool) = self { bool } else { nil }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let array) = self { array } else { nil }
    }
}
