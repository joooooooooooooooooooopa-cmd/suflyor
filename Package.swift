// swift-tools-version:6.0
import PackageDescription

// Логика вынесена в библиотеку SuflyorKit: её видят тесты и этап 2 (мозг подсказок),
// а исполняемый таргет Suflyor — только точка входа.
let package = Package(
    name: "Suflyor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Suflyor", targets: ["Suflyor"]),
    ],
    targets: [
        .target(
            name: "SuflyorKit",
            path: "Sources/SuflyorKit"
        ),
        .executableTarget(
            name: "Suflyor",
            dependencies: ["SuflyorKit"],
            path: "Sources/Suflyor"
        ),
        .testTarget(
            name: "SuflyorKitTests",
            dependencies: ["SuflyorKit"],
            // Тесты на Swift Testing; без Xcode запускать через scripts/test.sh (там пути к фреймворку из CommandLineTools).
            path: "Tests/SuflyorKitTests"
        ),
    ],
    // Режим Swift 5: колбэки AVAudioEngine/ScreenCaptureKit приходят на своих очередях,
    // строгая проверка Swift 6 тут даёт шум без пользы для этапа 1.
    swiftLanguageModes: [.v5]
)
