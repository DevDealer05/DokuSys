// swift-tools-version: 5.9

// WARNING:
// This file is auto-generated. Do not edit it by hand because the contents will be replaced.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "DigitalesBuero",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "DigitalesBuero",
            targets: ["AppModule"],
            bundleIdentifier: "de.kim.DigitalesBuero",
            teamIdentifier: "",
            displayVersion: "1.0.2",
            bundleVersion: "3",
            appIcon: .placeholder(icon: .coins),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .camera(purposeString: "Kamera zum Scannen von Briefen und Belegen")
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)
