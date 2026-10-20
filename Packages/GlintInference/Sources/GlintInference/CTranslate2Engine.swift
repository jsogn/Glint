import Darwin
import Foundation
import GlintCore

public final class CTranslate2Engine: TranslationEngine, @unchecked Sendable {
    private typealias CreateFn = @convention(c) (
        UnsafePointer<CChar>,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> UnsafeMutableRawPointer?
    private typealias TranslateFn = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafePointer<CChar>
    ) -> UnsafeMutablePointer<CChar>?
    private typealias FreeStringFn = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private typealias DestroyFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private let lock = NSLock()
    private var dlHandle: UnsafeMutableRawPointer?
    private var engine: UnsafeMutableRawPointer?
    private var create: CreateFn?
    private var translateFn: TranslateFn?
    private var freeString: FreeStringFn?
    private var destroy: DestroyFn?
    private(set) public var lastError: String?

    public var isAvailable: Bool {
        engine != nil
    }

    public convenience init?() {
        guard let modelURL = Self.locateModel() else {
            return nil
        }
        self.init(modelDirectory: modelURL)
    }

    public init?(
        modelDirectory: URL,
        libraryURL: URL? = nil
    ) {
        guard let libraryURL = libraryURL ?? Self.locateLibrary(),
              FileManager.default.fileExists(atPath: modelDirectory.path) else {
            lastError = "CTranslate2 library or model not found"
            return nil
        }

        guard let dlHandle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            lastError = String(cString: dlerror())
            return nil
        }
        self.dlHandle = dlHandle

        guard let createSymbol = dlsym(dlHandle, "glint_ct2_create"),
              let translateSymbol = dlsym(dlHandle, "glint_ct2_translate"),
              let freeSymbol = dlsym(dlHandle, "glint_ct2_free_string"),
              let destroySymbol = dlsym(dlHandle, "glint_ct2_destroy") else {
            lastError = "CTranslate2 bridge symbols not found"
            dlclose(dlHandle)
            self.dlHandle = nil
            return nil
        }

        let create = unsafeBitCast(createSymbol, to: CreateFn.self)
        let translate = unsafeBitCast(translateSymbol, to: TranslateFn.self)
        let freeString = unsafeBitCast(freeSymbol, to: FreeStringFn.self)
        let destroy = unsafeBitCast(destroySymbol, to: DestroyFn.self)

        var errorPointer: UnsafeMutablePointer<CChar>?
        let engine = modelDirectory.path.withCString { path in
            create(path, &errorPointer)
        }
        if let errorPointer {
            lastError = String(cString: errorPointer)
            free(errorPointer)
        }
        guard let engine else {
            dlclose(dlHandle)
            self.dlHandle = nil
            return nil
        }

        self.engine = engine
        self.create = create
        self.translateFn = translate
        self.freeString = freeString
        self.destroy = destroy
    }

    deinit {
        if let engine {
            destroy?(engine)
        }
        if let dlHandle {
            dlclose(dlHandle)
        }
    }

    public func translate(_ candidate: Candidate) async throws -> TranslationResult? {
        let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        return lock.withLock {
            guard let engine, let translateFn else { return nil }

            let output = text.withCString { pointer in
                translateFn(engine, pointer)
            }
            guard let output else { return nil }
            let translated = String(cString: output)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            freeString?(output)
            guard !translated.isEmpty else { return nil }
            return TranslationResult(
                text: translated,
                source: .translation,
                confidence: 0.85
            )
        }
    }

    private static func locateLibrary() -> URL? {
        if let path = ProcessInfo.processInfo.environment["GLINT_CT2_LIBRARY"] {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent(
            "Glint/plugins/opus-ct2-int8/bin/libglintct2.dylib"
        ), FileManager.default.fileExists(atPath: support.path) {
            return support
        }
        let candidates = [
            Bundle.main.url(forResource: "libglintct2", withExtension: "dylib", subdirectory: "CT2"),
            Bundle.main.url(forResource: "libglintct2", withExtension: "dylib", subdirectory: "Resources/CT2"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/CT2/libglintct2.dylib"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private static func locateModel() -> URL? {
        if let path = ProcessInfo.processInfo.environment["GLINT_CT2_MODEL"] {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent(
            "Glint/plugins/opus-ct2-int8/model",
            isDirectory: true
        ), FileManager.default.fileExists(atPath: support.path) {
            return support
        }
        let candidates = [
            Bundle.main.url(forResource: "opus-ct2-int8", withExtension: nil),
            Bundle.main.url(forResource: "opus-ct2-int8", withExtension: nil, subdirectory: "Models"),
            Bundle.main.url(forResource: "opus-ct2-int8", withExtension: nil, subdirectory: "Resources/Models"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/Models/opus-ct2-int8"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}
