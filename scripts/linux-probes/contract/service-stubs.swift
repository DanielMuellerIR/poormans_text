import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
final class Workspace { let instanceID = UUID() }
final class GitCancellationToken { func cancel() {} }
struct GitExecutionPolicy { init(timeout: TimeInterval, terminationGracePeriod: TimeInterval) {} }
enum NSSound { static func beep() {} }
enum GitRunner {
    static func runExecutable(_ executable: URL, arguments: [String], in directory: URL,
                              policy: GitExecutionPolicy, stderrChunkHandler: @escaping (Data) -> Void,
                              completion: @escaping (MarkdownImportProcessOutcome) -> Void) -> GitCancellationToken? {
        fatalError("Test muss den vorgesehenen runProcess-Testhaken verwenden")
    }
}
extension MarkdownImportProcessOutcome { init(_ value: MarkdownImportProcessOutcome) { self = value } }
