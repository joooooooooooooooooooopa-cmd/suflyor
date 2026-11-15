import Foundation
import SuflyorKit

let args = CommandLine.arguments

/// Значение после флага, если оно не следующий флаг.
func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("--") else { return nil }
    return args[i + 1]
}

if args.contains("--selftest-capture") {
    SelfTest.run()
} else if args.contains("--e2e-call") {
    exit(E2ECall.run(arguments: args))
} else if args.contains("--brain-smoke") {
    exit(BrainSmoke.run(text: value(after: "--brain-smoke"), topic: value(after: "--topic")))
} else {
    SuflyorApp.runApp()
}
