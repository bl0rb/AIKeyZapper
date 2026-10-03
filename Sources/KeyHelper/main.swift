import KeyZapperCore
import Foundation

let output = KeyHelperCommand(metadata: MetadataStore(), store: KeychainCredentialStore(), config: ManagedConfig.load())
    .run(Array(CommandLine.arguments.dropFirst())) {
        String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
FileHandle.standardOutput.write(Data(output.stdout.utf8))
FileHandle.standardError.write(Data(output.stderr.utf8))
exit(output.exitCode.rawValue)
