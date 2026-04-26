// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InfrastructureDependencies",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "InfrastructureDependencies", targets: ["InfrastructureDependencies"])
    ],
    dependencies: [
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "12.7.0"),
        .package(url: "https://github.com/RevenueCat/purchases-ios.git", from: "5.49.2"),
        .package(url: "https://github.com/superwall/Superwall-iOS.git", from: "4.10.6"),
        .package(url: "https://github.com/google/GoogleSignIn-iOS.git", from: "9.0.0")
    ],
    targets: [
        .target(
            name: "InfrastructureDependencies",
            dependencies: [
                .product(name: "FirebaseAnalytics", package: "firebase-ios-sdk"),
                .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
                .product(name: "FirebaseCrashlytics", package: "firebase-ios-sdk"),
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseMessaging", package: "firebase-ios-sdk"),
                .product(name: "FirebaseStorage", package: "firebase-ios-sdk"),
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
                .product(name: "RevenueCat", package: "purchases-ios"),
                .product(name: "SuperwallKit", package: "Superwall-iOS")
            ]
        )
    ]
)
