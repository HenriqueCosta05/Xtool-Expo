import Foundation
import Testing
@testable import PackLib

// `.swiftconstvalues` emitted by the Swift compiler (Swift 6.4, iOS SDK 27) for:
//
//     @available(iOS 17.0, *)
//     struct CallWithReasonIntent: AppIntent {
//         static let title: LocalizedStringResource = "Ligar com motivo"
//         static let description = IntentDescription("Liga para um contato informando o motivo.")
//         static let openAppWhenRun = true
//         @Parameter(title: "Motivo", description: "Por que você está ligando") var reason: String
//         @Parameter(title: "Urgente", default: false) var urgent: Bool
//         func perform() async throws -> some IntentResult { .result() }
//     }
//
//     struct DemoShortcuts: AppShortcutsProvider {
//         static var appShortcuts: [AppShortcut] {
//             AppShortcut(
//                 intent: CallWithReasonIntent(),
//                 phrases: ["Ligar com motivo no \(.applicationName)"],
//                 shortTitle: "Ligar com motivo",
//                 systemImageName: "phone"
//             )
//         }
//     }
//
// trimmed to the keys the generator reads.
private let constValues = #"""
[
 {
  "typeName": "Demo.CallWithReasonIntent",
  "mangledTypeName": "4Demo20CallWithReasonIntentV",
  "kind": "struct",
  "conformances": [
   "AppIntents.AppIntent",
   "AppIntents.PersistentlyIdentifiable",
   "AppIntents._SupportsAppDependencies",
   "Swift.Sendable",
   "Swift.SendableMetatype"
  ],
  "properties": [
   {
    "label": "title",
    "type": "Foundation.LocalizedStringResource",
    "mangledTypeName": "n/a - deprecated",
    "isStatic": "true",
    "isComputed": "false",
    "valueKind": "RawLiteral",
    "value": "Ligar com motivo"
   },
   {
    "label": "description",
    "type": "AppIntents.IntentDescription",
    "mangledTypeName": "n/a - deprecated",
    "isStatic": "true",
    "isComputed": "false",
    "valueKind": "RawLiteral",
    "value": "Liga para um contato informando o motivo."
   },
   {
    "label": "openAppWhenRun",
    "type": "Swift.Bool",
    "mangledTypeName": "n/a - deprecated",
    "isStatic": "true",
    "isComputed": "false",
    "valueKind": "RawLiteral",
    "value": "true"
   },
   {
    "label": "reason",
    "type": "Swift.String",
    "mangledTypeName": "n/a - deprecated",
    "isStatic": "false",
    "isComputed": "true",
    "valueKind": "InitCall",
    "value": {
     "type": "AppIntents.IntentParameter<Swift.String>",
     "arguments": [
      {
       "label": "title",
       "type": "Foundation.LocalizedStringResource",
       "valueKind": "RawLiteral",
       "value": "Motivo"
      },
      {
       "label": "description",
       "type": "Swift.Optional<Foundation.LocalizedStringResource>",
       "valueKind": "RawLiteral",
       "value": "Por que você está ligando"
      },
      {
       "label": "default",
       "type": "Swift.Optional<Swift.String>",
       "valueKind": "NilLiteral"
      },
      {
       "label": "inputOptions",
       "type": "Swift.Optional<Swift.String.IntentInputOptions>",
       "valueKind": "NilLiteral"
      },
      {
       "label": "requestValueDialog",
       "type": "Swift.Optional<AppIntents.IntentDialog>",
       "valueKind": "NilLiteral"
      },
      {
       "label": "inputConnectionBehavior",
       "type": "AppIntents.InputConnectionBehavior",
       "valueKind": "Runtime"
      }
     ]
    },
    "propertyWrappers": [
     {
      "type": "AppIntents.IntentParameter",
      "arguments": [
       {
        "label": "title",
        "type": "Foundation.LocalizedStringResource",
        "valueKind": "RawLiteral",
        "value": "Motivo"
       },
       {
        "label": "description",
        "type": "Swift.Optional<Foundation.LocalizedStringResource>",
        "valueKind": "RawLiteral",
        "value": "Por que você está ligando"
       }
      ]
     }
    ]
   },
   {
    "label": "urgent",
    "type": "Swift.Bool",
    "mangledTypeName": "n/a - deprecated",
    "isStatic": "false",
    "isComputed": "true",
    "valueKind": "InitCall",
    "value": {
     "type": "AppIntents.IntentParameter<Swift.Bool>",
     "arguments": [
      {
       "label": "title",
       "type": "Foundation.LocalizedStringResource",
       "valueKind": "RawLiteral",
       "value": "Urgente"
      },
      {
       "label": "description",
       "type": "Swift.Optional<Foundation.LocalizedStringResource>",
       "valueKind": "NilLiteral"
      },
      {
       "label": "default",
       "type": "Swift.Optional<Swift.Bool>",
       "valueKind": "RawLiteral",
       "value": "false"
      },
      {
       "label": "displayName",
       "type": "Swift.Optional<Swift.Bool.IntentDisplayName>",
       "valueKind": "NilLiteral"
      },
      {
       "label": "requestValueDialog",
       "type": "Swift.Optional<AppIntents.IntentDialog>",
       "valueKind": "NilLiteral"
      },
      {
       "label": "inputConnectionBehavior",
       "type": "AppIntents.InputConnectionBehavior",
       "valueKind": "Runtime"
      }
     ]
    },
    "propertyWrappers": [
     {
      "type": "AppIntents.IntentParameter",
      "arguments": [
       {
        "label": "title",
        "type": "Foundation.LocalizedStringResource",
        "valueKind": "RawLiteral",
        "value": "Urgente"
       },
       {
        "label": "default",
        "type": "Swift.Optional<Swift.Bool>",
        "valueKind": "RawLiteral",
        "value": "false"
       }
      ]
     }
    ]
   }
  ],
  "availabilityAttributes": [
   {
    "platform": "iOS",
    "introducedVersion": "17.0",
    "isUnavailable": false,
    "isDeprecated": false
   }
  ]
 },
 {
  "typeName": "Demo.DemoShortcuts",
  "mangledTypeName": "4Demo0A9ShortcutsV",
  "kind": "struct",
  "conformances": [
   "AppIntents.AppShortcutsProvider",
   "Swift.Sendable",
   "Swift.SendableMetatype",
   "Swift.BitwiseCopyable"
  ],
  "properties": [
   {
    "label": "appShortcuts",
    "type": "Swift.Array<AppIntents.AppShortcut>",
    "mangledTypeName": "n/a - deprecated",
    "isStatic": "true",
    "isComputed": "true",
    "valueKind": "Builder",
    "value": {
     "type": "AppIntents.AppShortcutsBuilder",
     "members": [
      {
       "kind": "buildExpression",
       "element": {
        "valueKind": "InitCall",
        "value": {
         "type": "AppIntents.AppShortcut",
         "arguments": [
          {
           "label": "intent",
           "type": "Demo.CallWithReasonIntent",
           "valueKind": "InitCall",
           "value": {
            "type": "Demo.CallWithReasonIntent",
            "arguments": []
           }
          },
          {
           "label": "phrases",
           "type": "Swift.Array<AppIntents.AppShortcutPhrase<Demo.CallWithReasonIntent>>",
           "valueKind": "Array",
           "value": [
            {
             "valueKind": "InterpolatedStringLiteral",
             "value": {
              "segments": [
               {
                "valueKind": "RawLiteral",
                "value": "Ligar com motivo no "
               },
               {
                "valueKind": "Enum",
                "value": {
                 "name": "applicationName"
                }
               },
               {
                "valueKind": "RawLiteral",
                "value": ""
               }
              ]
             }
            }
           ]
          },
          {
           "label": "shortTitle",
           "type": "Foundation.LocalizedStringResource",
           "valueKind": "RawLiteral",
           "value": "Ligar com motivo"
          },
          {
           "label": "systemImageName",
           "type": "Swift.String",
           "valueKind": "RawLiteral",
           "value": "phone"
          }
         ]
        }
       }
      }
     ]
    }
   }
  ]
 }
]
"""#

/// The keys of an action in `extract.actionsdata` as written by Xcode 26.2 (17C529).
private let xcodeActionKeys: Set<String> = [
    "assistantDefinedSchemaTraits", "assistantDefinedSchemas", "authenticationPolicy", "availabilityAnnotations",
    "descriptionMetadata", "effectiveBundleIdentifiers", "fullyQualifiedTypeName", "identifier", "isAuthPolExplicit",
    "isDiscoverable", "mangledTypeName", "mangledTypeNameByBundleIdentifier", "mangledTypeNameByBundleIdentifierV2",
    "mangledTypeNameV2", "openAppWhenRun", "outputFlags", "outputType", "parameters", "presentationStyle",
    "requiredCapabilities", "supportedModes", "systemProtocolMetadata", "systemProtocolMetadataV2", "systemProtocols",
    "title", "typeSpecificMetadata", "visibilityMetadata",
]

private let xcodeParameterKeys: Set<String> = [
    "capabilities", "dynamicOptionsSupport", "inputConnectionBehavior", "isInput", "isOptional", "name",
    "parameterDescription", "resolvableInputTypes", "title", "typeSpecificMetadata", "valueType",
]

private func generate(modules: Set<String> = ["Demo"]) throws -> (AppIntentsMetadata, JSONValue) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("Intents.swiftconstvalues")
    try Data(constValues.utf8).write(to: file)

    let metadata = try AppIntentsMetadata(constValueFiles: [file, file], modules: modules, toolsVersion: "17C529")
    return (metadata, try JSONDecoder().decode(JSONValue.self, from: metadata.extractData()))
}

@Test func appIntentsMetadataDescribesIntents() throws {
    let (metadata, json) = try generate()
    #expect(metadata.warnings.isEmpty)

    let action = try #require(json["actions"]?["CallWithReasonIntent"])
    #expect(action["mangledTypeName"] == "4Demo20CallWithReasonIntentV")
    #expect(action["mangledTypeNameV2"] == "4Demo20CallWithReasonIntentV")
    #expect(action["title"]?["key"] == "Ligar com motivo")
    #expect(action["descriptionMetadata"]?["descriptionText"]?["key"] == "Liga para um contato informando o motivo.")
    #expect(action["openAppWhenRun"] == true)
    #expect(action["supportedModes"] == nil)
    #expect(action["availabilityAnnotations"]?["LNPlatformNameIOS"]?["introducedVersion"] == "17.0")

    let parameters = try #require(action["parameters"]?.arrayValue)
    #expect(parameters.count == 2)
    let reason = parameters[0], urgent = parameters[1]
    #expect(reason["name"] == "reason")
    #expect(reason["title"]?["key"] == "Motivo")
    #expect(reason["parameterDescription"]?["key"] == "Por que você está ligando")
    #expect(reason["valueType"]?["primitive"]?["wrapper"]?["typeIdentifier"] == 0)
    #expect(reason["isOptional"] == false)
    #expect(urgent["valueType"]?["primitive"]?["wrapper"]?["typeIdentifier"] == 1)
    let defaultValue: JSONValue = .object(["int": .object(["wrapper": 0])])
    #expect(urgent["typeSpecificMetadata"] == ["LNValueTypeSpecificMetadataKeyDefaultValue", defaultValue])
}

@Test func appIntentsMetadataMatchesXcodeShape() throws {
    let (_, json) = try generate()
    guard case .object(let action)? = json["actions"]?["CallWithReasonIntent"] else {
        Issue.record("missing action")
        return
    }
    // this intent returns no value and opens the app, so it has neither of these
    #expect(xcodeActionKeys.subtracting(action.keys) == ["outputType", "supportedModes"])
    #expect(Set(action.keys).subtracting(xcodeActionKeys).isEmpty)

    guard case .object(let parameter)? = action["parameters"]?.arrayValue?.first else {
        Issue.record("missing parameter")
        return
    }
    #expect(Set(parameter.keys) == xcodeParameterKeys)

    let topLevel: Set<String> = [
        "actions", "assistantEntities", "assistantIntentNegativePhrases", "assistantIntents",
        "autoShortcutProviderMangledName", "autoShortcuts", "entities", "enums", "generator",
        "negativePhrases", "queries", "shortcutTileColor", "version",
    ]
    if case .object(let root) = json {
        #expect(Set(root.keys) == topLevel)
    }
    #expect(json["generator"] == .object(["name": "xcode-tools", "version": "17C529"]))
}

@Test func appIntentsMetadataDescribesAppShortcuts() throws {
    let (_, json) = try generate()
    #expect(json["autoShortcutProviderMangledName"] == "4Demo0A9ShortcutsV")
    let shortcut = try #require(json["autoShortcuts"]?.arrayValue?.first)
    #expect(shortcut["actionIdentifier"] == "CallWithReasonIntent")
    #expect(shortcut["phraseTemplates"]?.arrayValue?.first?["key"] == "Ligar com motivo no ${applicationName}")
    #expect(shortcut["shortTitle"]?["key"] == "Ligar com motivo")
    #expect(shortcut["systemImageName"] == "phone")
}

@Test func appIntentsMetadataOnlyIncludesProductModules() throws {
    let (metadata, _) = try generate(modules: ["Other"])
    #expect(metadata.isEmpty)
}

@Test func appIntentsMetadataWritesBundle() throws {
    let (metadata, _) = try generate()
    let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: app) }
    try metadata.write(into: app)

    let bundle = app.appendingPathComponent("Metadata.appintents")
    let version = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: bundle.appendingPathComponent("version.json")))
    #expect(version == .object(["toolsVersion": "17C529", "version": "3.0"]))
    #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("extract.actionsdata").path))
}
