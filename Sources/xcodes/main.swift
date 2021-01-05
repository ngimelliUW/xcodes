import Foundation
import ArgumentParser
import Version
import PromiseKit
import XcodesKit
import LegibleError
import Path

func getDirectory(possibleDirectory: String?, default: Path = Path.root.join("Applications")) -> Path {
    let directory = possibleDirectory.flatMap(Path.init) ??
        ProcessInfo.processInfo.environment["XCODES_DIRECTORY"].flatMap(Path.init) ?? 
        `default`
    guard directory.isDirectory else {
        Current.logging.log("Directory argument must be a directory, but was provided \(directory.string).")
        exit(1)
    }
    return directory
}

struct GlobalDirectoryOption: ParsableArguments {
    @Option(help: "The directory where your Xcodes are installed. Defaults to /Applications.", 
            completion: .directory)
    var directory: String?
}

struct Xcodes: ParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Manage the Xcodes installed on your Mac",
        shouldDisplay: true,
        subcommands: [Download.self, Install.self, Installed.self, List.self, Select.self, Uninstall.self, Update.self, Version.self]
    )
    
    static var xcodesConfiguration = Configuration()
    static let xcodeList = XcodeList()
    static var installer: XcodeInstaller!

    static func main() {
        try? xcodesConfiguration.load()
        installer = XcodeInstaller(configuration: xcodesConfiguration, xcodeList: xcodeList)
        migrateApplicationSupportFiles()
        
        self.main(nil)
    }
    
    struct Download: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Download a specific version of Xcode",
            discussion: """
                        By default, xcodes will use a URLSession to download the specified version. If aria2 (https://aria2.github.io, available in Homebrew) is installed, either somewhere in PATH or at the path specified by the --aria2 flag, then it will be used instead. aria2 will use up to 16 connections to download Xcode 3-5x faster. If you have aria2 installed and would prefer to not use it, you can use the --no-aria2 flag.

                        EXAMPLES:
                          xcodes download 10.2.1
                          xcodes download 11 Beta 7
                          xcodes download 11.2 GM seed
                          xcodes download 9.0 --directory ~/Archive
                          xcodes download --latest-prerelease
                        """
        )
        
        @Option(help: "The directory to download Xcode to. Defaults to ~/Downloads.", 
                completion: .directory)
        var directory: String?
        
        @Argument(help: "The version to download",
                  completion: .custom { args in xcodeList.availableXcodes.sorted { $0.version < $1.version }.map { $0.version.xcodeDescription } })
        var version: [String] = []
        
        @Flag(help: "Update and then download the latest non-prerelease version available.")
        var latest: Bool = false
        
        @Flag(help: "Update and then download the latest prerelease version available, including GM seeds and GMs.")
        var latestPrerelease = false
        
        @Option(help: "The path to an aria2 executable. Searches $PATH by default.", 
                completion: .file())
        var aria2: String?
        
        @Flag(help: "Don't use aria2 to download Xcode, even if its available.")
        var noAria2: Bool = false
        
        func run() {
            let versionString = version.joined(separator: " ")
            
            let installation: XcodeInstaller.InstallationType
            // Deliberately not using InstallationType.path here as it doesn't make sense to download an Xcode from a .xip that's already on disk
            if latest {
                installation = .latest
            } else if latestPrerelease {
                installation = .latestPrerelease
            } else {
                installation = .version(versionString)
            }
            
            var downloader = XcodeInstaller.Downloader.urlSession
            if let aria2Path = aria2.flatMap(Path.init) ?? Current.shell.findExecutable("aria2c"),
               aria2Path.exists,
               noAria2 == false {
                downloader = .aria2(aria2Path)
            }
            
            let destination = getDirectory(possibleDirectory: directory, default: Path.home.join("Downloads"))

            installer.download(installation, downloader: downloader, destinationDirectory: destination)
                .catch { error in
                    switch error {
                    case Process.PMKError.execution(let process, let standardOutput, let standardError):
                        Current.logging.log("""
                            Failed executing: `\(process)` (\(process.terminationStatus))
                            \([standardOutput, standardError].compactMap { $0 }.joined(separator: "\n"))
                            """)
                    default:
                        Current.logging.log(error.legibleLocalizedDescription)
                    }
                    
                    Install.exit(withError: ExitCode.failure)
                }
            
            RunLoop.current.run()
        }
    }
    
    struct Install: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Download and install a specific version of Xcode",
            discussion: """
                        By default, xcodes will use a URLSession to download the specified version. If aria2 (https://aria2.github.io, available in Homebrew) is installed, either somewhere in PATH or at the path specified by the --aria2 flag, then it will be used instead. aria2 will use up to 16 connections to download Xcode 3-5x faster. If you have aria2 installed and would prefer to not use it, you can use the --no-aria2 flag.

                        EXAMPLES:
                          xcodes install 10.2.1
                          xcodes install 11 Beta 7
                          xcodes install 11.2 GM seed
                          xcodes install 9.0 --path ~/Archive/Xcode_9.xip
                          xcodes install --latest-prerelease
                          xcodes install --latest --directory "/Volumes/Bag Of Holding/"
                        """
        )
        
        @Option(help: "The directory to install Xcode into. Defaults to /Applications.",
                completion: .directory)
        var directory: String?
        
        @Argument(help: "The version to install",
                  completion: .custom { args in xcodeList.availableXcodes.sorted { $0.version < $1.version }.map { $0.version.xcodeDescription } })
        var version: [String] = []
        
        @Option(name: .customLong("path"),
                help: "Local path to Xcode .xip",
                completion: .file(extensions: ["xip"]))
        var pathString: String?
        
        @Flag(help: "Update and then install the latest non-prerelease version available.")
        var latest: Bool = false
        
        @Flag(help: "Update and then install the latest prerelease version available, including GM seeds and GMs.")
        var latestPrerelease = false
        
        @Option(help: "The path to an aria2 executable. Searches $PATH by default.", 
                completion: .file())
        var aria2: String?
        
        @Flag(help: "Don't use aria2 to download Xcode, even if its available.")
        var noAria2: Bool = false
        
        func run() {
            let versionString = version.joined(separator: " ")
            
            let installation: XcodeInstaller.InstallationType
            if latest {
                installation = .latest
            } else if latestPrerelease {
                installation = .latestPrerelease
            } else if let pathString = pathString, let path = Path(pathString) {
                installation = .path(versionString, path)
            } else {
                installation = .version(versionString)
            }
            
            var downloader = XcodeInstaller.Downloader.urlSession
            if let aria2Path = aria2.flatMap(Path.init) ?? Current.shell.findExecutable("aria2c"),
               aria2Path.exists,
               noAria2 == false {
                downloader = .aria2(aria2Path)
            }
            
            let destination = getDirectory(possibleDirectory: directory)
            
            installer.install(installation, downloader: downloader, destination: destination)
                .done { Install.exit() }
                .catch { error in
                    switch error {
                    case Process.PMKError.execution(let process, let standardOutput, let standardError):
                        Current.logging.log("""
                            Failed executing: `\(process)` (\(process.terminationStatus))
                            \([standardOutput, standardError].compactMap { $0 }.joined(separator: "\n"))
                            """)
                    default:
                        Current.logging.log(error.legibleLocalizedDescription)
                    }
                    
                    Install.exit(withError: ExitCode.failure)
                }
            
            RunLoop.current.run()
        }
    }
    
    struct Installed: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "List the versions of Xcode that are installed"
        )
        
        @OptionGroup
        var globalDirectory: GlobalDirectoryOption
        
        func run() {
            let directory = getDirectory(possibleDirectory: globalDirectory.directory)
            
            installer.printInstalledXcodes(directory: directory)
                .done { Installed.exit() }
                .catch { error in Installed.exit(withLegibleError: error) }
            
            RunLoop.current.run()
        }
    }
    
    struct List: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "List all versions of Xcode that are available to install"
        )
        
        @OptionGroup
        var globalDirectory: GlobalDirectoryOption
        
        func run() {
            let directory = getDirectory(possibleDirectory: globalDirectory.directory)
            
            firstly { () -> Promise<Void> in
                if xcodeList.shouldUpdate {
                    return installer.updateAndPrint(directory: directory)
                }
                else {
                    return installer.printAvailableXcodes(xcodeList.availableXcodes, installed: Current.files.installedXcodes(directory))
                }
            }
            .done { List.exit() }
            .catch { error in List.exit(withLegibleError: ExitCode.failure) }
            
            RunLoop.current.run()
        }
    }
    
    struct Select: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Change the selected Xcode",
            discussion: """
                        Run without any arguments to interactively select from a list, or provide an absolute path.

                        EXAMPLES:
                          xcodes select
                          xcodes select 11.4.0
                          xcodes select /Applications/Xcode-11.4.0.app
                          xcodes select -p
                        """
        )
        
        @OptionGroup
        var globalDirectory: GlobalDirectoryOption
        
        @ArgumentParser.Flag(name: [.customShort("p"), .customLong("print-path")], help: "Print the path of the selected Xcode")
        var print: Bool = false
        
        @Argument(help: "Version or path",
                  completion: .custom { _ in Current.files.installedXcodes(getDirectory(possibleDirectory: nil)).sorted { $0.version < $1.version }.map { $0.version.xcodeDescription } })
        var versionOrPath: [String] = []
        
        func run() {
            let directory = getDirectory(possibleDirectory: globalDirectory.directory)
            
            selectXcode(shouldPrint: print, pathOrVersion: versionOrPath.joined(separator: " "), directory: directory)
                .done { Select.exit() }
                .catch { error in Select.exit(withLegibleError: error) }
            
            RunLoop.current.run()
        }
    }
    
    struct Uninstall: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Uninstall a specific version of Xcode",
            discussion: """
                        EXAMPLES:
                          xcodes uninstall 10.2.1
                        """
        )
        
        @OptionGroup
        var globalDirectory: GlobalDirectoryOption

        @Argument(help: "The version to uninstall",
                  completion: .custom { _ in Current.files.installedXcodes(getDirectory(possibleDirectory: nil)).sorted { $0.version < $1.version }.map { $0.version.xcodeDescription } })
        var version: [String] = []
        
        func run() {
            let directory = getDirectory(possibleDirectory: globalDirectory.directory)

            installer.uninstallXcode(version.joined(separator: " "), directory: directory)
                .done { Uninstall.exit() }
                .catch { error in Uninstall.exit(withLegibleError: ExitCode.failure) }
            
            RunLoop.current.run()
        }
    }
    
    struct Update: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Update the list of available versions of Xcode"
        )
        
        @OptionGroup
        var globalDirectory: GlobalDirectoryOption
        
        func run() {
            let directory = getDirectory(possibleDirectory: globalDirectory.directory)
            
            installer.updateAndPrint(directory: directory)
                .done { Update.exit() }
                .catch { error in Update.exit(withLegibleError: error) }
            
            RunLoop.current.run()
        }
    }
    
    struct Version: ParsableCommand {
        static var configuration = CommandConfiguration(
            abstract: "Print the version number of xcodes itself"
        )
        
        func run() {
            Current.logging.log(XcodesKit.version.description)
        }
    }
}

// @main doesn't work yet because of https://bugs.swift.org/browse/SR-12683
Xcodes.main()
