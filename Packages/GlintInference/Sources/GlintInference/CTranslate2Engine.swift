import Darwin
import Foundation
import GlintCore

public enum CTranslate2EngineError: LocalizedError {
    case modelNotFound(String)
    case libraryNotFound(String)
    case libraryLoadFailed(String)
    case symbolsMissing
    case modelLoadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            "CTranslate2 模型目录不存在：\(path)"
        case .libraryNotFound(let path):
            "CTranslate2 运行库不存在：\(path)"
        case .libraryLoadFailed(let message):
            "CTranslate2 运行库加载失败：\(message)"
        case .symbolsMissing:
            "CTranslate2 桥接符号不完整"
        case .modelLoadFailed(let message):
            "CTranslate2 模型加载失败：\(message)"
        }
    }
}

public final class CTranslate2Engine: TranslationEngine, @unchecked Sendable {
    private typealias CreateFn =
        @convention(c) (
            UnsafePointer<CChar>,
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        ) -> UnsafeMutableRawPointer?
    private typealias TranslateFn =
        @convention(c) (
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
    private(set) var lastError: String?

    public convenience init?() {
        guard let modelURL = Self.locateInstalledModel() else {
            return nil
        }
        try? self.init(modelDirectory: modelURL)
    }

    public init(
        modelDirectory: URL,
        libraryURL: URL? = nil
    ) throws {
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw CTranslate2EngineError.modelNotFound(modelDirectory.path)
        }
        guard
            let libraryURL = libraryURL
                ?? Self.locateLibrary()
        else {
            throw CTranslate2EngineError.libraryNotFound(
                "CTranslate2Runtime/bin/libglintct2.dylib"
            )
        }

        guard let dlHandle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw CTranslate2EngineError.libraryLoadFailed(
                dlerror().map { String(cString: $0) } ?? "未知错误"
            )
        }
        self.dlHandle = dlHandle

        guard let createSymbol = dlsym(dlHandle, "glint_ct2_create"),
            let translateSymbol = dlsym(dlHandle, "glint_ct2_translate"),
            let freeSymbol = dlsym(dlHandle, "glint_ct2_free_string"),
            let destroySymbol = dlsym(dlHandle, "glint_ct2_destroy")
        else {
            dlclose(dlHandle)
            self.dlHandle = nil
            throw CTranslate2EngineError.symbolsMissing
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
            throw CTranslate2EngineError.modelLoadFailed(
                lastError ?? "未知错误"
            )
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
        try Task.checkCancellation()
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
            return TranslationResult(text: translated)
        }
    }

    private static func locateLibrary() -> URL? {
        if let path = ProcessInfo.processInfo.environment["GLINT_CT2_LIBRARY"] {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        guard
            let runtimeDirectory = Bundle.main.url(
                forResource: "CTranslate2Runtime",
                withExtension: nil
            )
        else {
            return nil
        }
        let library = runtimeDirectory.appendingPathComponent(
            "bin/libglintct2.dylib"
        )
        return FileManager.default.fileExists(atPath: library.path)
            ? library
            : nil
    }

    private static func locateInstalledModel() -> URL? {
        if let path = ProcessInfo.processInfo.environment["GLINT_CT2_MODEL"] {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
