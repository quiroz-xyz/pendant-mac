import Foundation

/// Paths the app needs. The Python interpreter path is written into
/// Info.plist by build.sh; the sync script ships inside the app bundle.
enum Config {
    static var pythonPath: String {
        if let override = UserDefaults.standard.string(forKey: "pythonPath"), !override.isEmpty {
            return override
        }
        return Bundle.main.object(forInfoDictionaryKey: "PendantPython") as? String ?? ""
    }

    static var driverPath: String {
        Bundle.main.path(forResource: "pendant_drain", ofType: "py") ?? ""
    }

    static var libraryURL: URL {
        if let path = UserDefaults.standard.string(forKey: "libraryPath"), !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let fromPlist = Bundle.main.object(forInfoDictionaryKey: "PendantDefaultLibrary") as? String
        return URL(fileURLWithPath: fromPlist ?? (NSHomeDirectory() + "/Pendant/Library"))
    }

    static var pendantAddress: String? {
        get { UserDefaults.standard.string(forKey: "pendantAddress") }
        set { UserDefaults.standard.set(newValue, forKey: "pendantAddress") }
    }
}
