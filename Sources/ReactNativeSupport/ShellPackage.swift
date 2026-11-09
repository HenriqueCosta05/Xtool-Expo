import Foundation

struct ShellPackage: Sendable {
    static let deploymentTarget = "16.4"

    var productName: String
    var moduleName: String
    var isExpo: Bool
    var frameworks: [String]
    /// App extension targets, built from the sources mirrored into `Extensions/<name>`.
    var extensions: [String] = []
    /// Load the JavaScript bundle embedded in the app even in Debug builds, instead of from Metro.
    var embedBundle = false

    var manifest: String {
        let frameworkDependencies = frameworks.map { "\"\($0)\"," }
        let binaryTargets = frameworks.map {
            ".binaryTarget(name: \"\($0)\", path: \"Frameworks/\($0).xcframework\"),"
        }
        let extensionProducts = extensions.map {
            ".library(name: \"\($0)\", targets: [\"\($0)\"]),"
        }
        let extensionTargets = extensions.map {
            """
            .target(
                    name: "\($0)",
                    path: "Extensions/\($0)",
                    swiftSettings: [.define("DEBUG", .when(configuration: .debug))]
                ),
            """
        }
        return """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "\(productName)",
            platforms: [.iOS("\(Self.deploymentTarget)")],
            products: [
                .library(name: "\(productName)", targets: ["\(productName)"]),
                \(extensionProducts.joined(separator: "\n        "))
            ],
            dependencies: [
                .package(name: "ReactNative", path: "build/xcframeworks"),
                .package(name: "React-GeneratedCode", path: "build/generated/ios"),
                .package(name: "Autolinked", path: "build/generated/autolinking"),
            ],
            targets: [
                .target(
                    name: "\(productName)",
                    dependencies: [
                        .product(name: "ReactHeaders", package: "ReactNative"),
                        .product(name: "ReactNativeHeaders", package: "ReactNative"),
                        .product(name: "ReactNativeDependenciesHeaders", package: "ReactNative"),
                        .product(name: "ReactCodegen", package: "React-GeneratedCode"),
                        .product(name: "ReactAppDependencyProvider", package: "React-GeneratedCode"),
                        .product(name: "Autolinked", package: "Autolinked"),
                        \(frameworkDependencies.joined(separator: "\n                "))
                    ],
                    path: "App",
                    swiftSettings: [
                        .define("DEBUG", .when(configuration: .debug)),
                        .enableUpcomingFeature("InternalImportsByDefault"),
                    ],
                    linkerSettings: [.unsafeFlags(["-Xlinker", "-ObjC"])]
                ),
                \(binaryTargets.joined(separator: "\n        "))
                \(extensionTargets.joined(separator: "\n        "))
            ],
            swiftLanguageModes: [.v5],
            cxxLanguageStandard: .cxx20
        )

        """
    }

    var appDelegate: String {
        let flavor = isExpo ? AppDelegateFlavor.expo : .bare
        return """
        import UIKit
        \(flavor.imports)import React
        import ReactAppDependencyProvider

        @main
        final class AppDelegate: \(flavor.superclass) {
            var window: UIWindow?
            var reactNativeDelegate: ReactNativeDelegate?
            var reactNativeFactory: RCTReactNativeFactory?

            \(flavor.overrideKeyword)func application(
                _ application: UIApplication,
                didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
            ) -> Bool {
                let delegate = ReactNativeDelegate()
                let factory = \(flavor.factory)(delegate: delegate)
                delegate.dependencyProvider = RCTAppDependencyProvider()
                reactNativeDelegate = delegate
                reactNativeFactory = factory
                window = UIWindow(frame: UIScreen.main.bounds)
                factory.startReactNative(withModuleName: "\(moduleName)", in: window, launchOptions: launchOptions)
                return \(flavor.launchResult)
            }
        }

        final class ReactNativeDelegate: \(flavor.delegateSuperclass) {
            override func sourceURL(for bridge: RCTBridge) -> URL? {
                bridge.bundleURL ?? bundleURL()
            }

            override func bundleURL() -> URL? {
                \(bundleURLBody(flavor: flavor))
            }
        }

        """
    }

    private func bundleURLBody(flavor: AppDelegateFlavor) -> String {
        let embedded = "Bundle.main.url(forResource: \"main\", withExtension: \"jsbundle\")"
        if embedBundle { return embedded }
        return """
        #if DEBUG
                RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "\(flavor.bundleRoot)")
                #else
                \(embedded)
                #endif
        """
    }

    static var stubProject: String {
        let settings = { (extra: String) in
            """
                        buildSettings = {
                            IPHONEOS_DEPLOYMENT_TARGET = \(deploymentTarget);
                            \(extra);
                        };
            """
        }
        let template = """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            classes = {
            };
            objectVersion = 77;
            objects = {

        /* Begin PBXFileReference section */
                A10000000000000000000001 /* App.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; \
        includeInIndex = 0; path = App.app; sourceTree = BUILT_PRODUCTS_DIR; };
        /* End PBXFileReference section */

        /* Begin PBXFrameworksBuildPhase section */
                A10000000000000000000005 /* Frameworks */ = {
                    isa = PBXFrameworksBuildPhase;
                    buildActionMask = 2147483647;
                    files = (
                    );
                    runOnlyForDeploymentPostprocessing = 0;
                };
        /* End PBXFrameworksBuildPhase section */

        /* Begin PBXGroup section */
                A10000000000000000000002 = {
                    isa = PBXGroup;
                    children = (
                        A10000000000000000000003 /* Products */,
                    );
                    sourceTree = "<group>";
                };
                A10000000000000000000003 /* Products */ = {
                    isa = PBXGroup;
                    children = (
                        A10000000000000000000001 /* App.app */,
                    );
                    name = Products;
                    sourceTree = "<group>";
                };
        /* End PBXGroup section */

        /* Begin PBXNativeTarget section */
                A10000000000000000000006 /* App */ = {
                    isa = PBXNativeTarget;
                    buildConfigurationList = A10000000000000000000009 /* Build configuration list for PBXNativeTarget "App" */;
                    buildPhases = (
                        A10000000000000000000004 /* Sources */,
                        A10000000000000000000005 /* Frameworks */,
                    );
                    buildRules = (
                    );
                    dependencies = (
                    );
                    name = App;
                    productName = App;
                    productReference = A10000000000000000000001 /* App.app */;
                    productType = "com.apple.product-type.application";
                };
        /* End PBXNativeTarget section */

        /* Begin PBXProject section */
                A10000000000000000000007 /* Project object */ = {
                    isa = PBXProject;
                    buildConfigurationList = A1000000000000000000000C /* Build configuration list for PBXProject "App" */;
                    compatibilityVersion = "Xcode 14.0";
                    mainGroup = A10000000000000000000002;
                    productRefGroup = A10000000000000000000003 /* Products */;
                    projectDirPath = "";
                    projectRoot = "";
                    targets = (
                        A10000000000000000000006 /* App */,
                    );
                };
        /* End PBXProject section */

        /* Begin PBXSourcesBuildPhase section */
                A10000000000000000000004 /* Sources */ = {
                    isa = PBXSourcesBuildPhase;
                    buildActionMask = 2147483647;
                    files = (
                    );
                    runOnlyForDeploymentPostprocessing = 0;
                };
        /* End PBXSourcesBuildPhase section */

        /* Begin XCBuildConfiguration section */
                A1000000000000000000000A /* Debug */ = {
                    isa = XCBuildConfiguration;
        \(settings("PRODUCT_NAME = App"))
                    name = Debug;
                };
                A1000000000000000000000B /* Release */ = {
                    isa = XCBuildConfiguration;
        \(settings("PRODUCT_NAME = App"))
                    name = Release;
                };
                A1000000000000000000000D /* Debug */ = {
                    isa = XCBuildConfiguration;
        \(settings("SDKROOT = iphoneos"))
                    name = Debug;
                };
                A1000000000000000000000E /* Release */ = {
                    isa = XCBuildConfiguration;
        \(settings("SDKROOT = iphoneos"))
                    name = Release;
                };
        /* End XCBuildConfiguration section */

        /* Begin XCConfigurationList section */
                A10000000000000000000009 /* Build configuration list for PBXNativeTarget "App" */ = {
                    isa = XCConfigurationList;
                    buildConfigurations = (
                        A1000000000000000000000A /* Debug */,
                        A1000000000000000000000B /* Release */,
                    );
                    defaultConfigurationName = Release;
                };
                A1000000000000000000000C /* Build configuration list for PBXProject "App" */ = {
                    isa = XCConfigurationList;
                    buildConfigurations = (
                        A1000000000000000000000D /* Debug */,
                        A1000000000000000000000E /* Release */,
                    );
                    defaultConfigurationName = Release;
                };
        /* End XCConfigurationList section */
            };
            rootObject = A10000000000000000000007 /* Project object */;
        }

        """
        return template.replacingOccurrences(of: "    ", with: "\t")
    }
}

private struct AppDelegateFlavor {
    var imports: String
    var superclass: String
    var overrideKeyword: String
    var factory: String
    var delegateSuperclass: String
    var bundleRoot: String
    var launchResult: String

    static let bare = Self(
        imports: "",
        superclass: "UIResponder, UIApplicationDelegate",
        overrideKeyword: "",
        factory: "RCTReactNativeFactory",
        delegateSuperclass: "RCTDefaultReactNativeFactoryDelegate",
        bundleRoot: "index",
        launchResult: "true"
    )

    static let expo = Self(
        imports: "import Expo\n",
        superclass: "ExpoAppDelegate",
        overrideKeyword: "override ",
        factory: "ExpoReactNativeFactory",
        delegateSuperclass: "ExpoReactNativeFactoryDelegate",
        bundleRoot: ".expo/.virtual-metro-entry",
        launchResult: "super.application(application, didFinishLaunchingWithOptions: launchOptions)"
    )
}
