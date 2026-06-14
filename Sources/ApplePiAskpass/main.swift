import Foundation

// ApplePiAskpass — invoked by ssh(1) when SSH_ASKPASS_REQUIRE=force is set.
//
// The Apple Pi app sets:
//   SSH_ASKPASS=/path/to/ApplePiAskpass
//   SSH_ASKPASS_REQUIRE=force
//   DISPLAY=:0                  (ssh requires this even when unused)
//   APPLE_PI_ASKPASS_FILE=/path/to/password
//
// We read the password from APPLE_PI_ASKPASS_FILE and print it to stdout.
// ssh picks the answer up from there. The file is created by the main app
// with mode 0600; we never write anything, so there is no risk of the
// helper persisting secrets on its own.

guard let path = ProcessInfo.processInfo.environment["APPLE_PI_ASKPASS_FILE"],
      !path.isEmpty else {
    FileHandle.standardError.write(Data("APPLE_PI_ASKPASS_FILE not set\n".utf8))
    exit(1)
}

let url = URL(fileURLWithPath: path)
do {
    let data = try Data(contentsOf: url)
    guard let password = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write(Data("password is not valid UTF-8\n".utf8))
        exit(1)
    }
    // Trim trailing newline in case the file was edited by hand.
    let trimmed = password.trimmingCharacters(in: .newlines)
    FileHandle.standardOutput.write(Data(trimmed.utf8))
    // OpenSSH reads exactly one line; a trailing newline is not strictly
    // required but mirrors what `sshpass` does and is friendlier to logs.
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("could not read password file: \(error.localizedDescription)\n".utf8))
    exit(1)
}
