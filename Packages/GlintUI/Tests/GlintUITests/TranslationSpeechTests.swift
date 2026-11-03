import AVFAudio
import XCTest

@testable import GlintUI

@MainActor
private final class FakeTranslationSpeechSynthesizer:
    TranslationSpeechSynthesizing
{
    private(set) var utterances: [AVSpeechUtterance] = []
    private(set) var stopCount = 0
    private(set) var isSpeaking = false

    func speak(_ utterance: AVSpeechUtterance) {
        utterances.append(utterance)
        isSpeaking = true
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stopCount += 1
        isSpeaking = false
        return true
    }
}

@MainActor
final class TranslationSpeechTests: XCTestCase {
    func testSpeechAccentTitlesStaySimple() {
        XCTAssertEqual(
            TranslationSpeechAccent.allCases.map(\.title),
            ["系统默认", "美式英语", "英式英语"]
        )
    }

    func testSpeechRateTitlesStaySimple() {
        XCTAssertEqual(
            TranslationSpeechRate.allCases.map(\.title),
            ["较慢", "标准", "较快"]
        )
    }

    func testSpeechRateConfiguresUtterance() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { _ in
                AVSpeechSynthesisVoice(language: "en-US")
            }
        )

        controller.speak("Slower", accent: .system, rate: .slower)
        controller.speak("Standard", accent: .system, rate: .standard)
        controller.speak("Faster", accent: .system, rate: .faster)

        let defaultRate = AVSpeechUtteranceDefaultSpeechRate
        XCTAssertEqual(
            synthesizer.utterances[0].rate,
            defaultRate * 0.8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            synthesizer.utterances[1].rate,
            defaultRate,
            accuracy: 0.001
        )
        XCTAssertEqual(
            synthesizer.utterances[2].rate,
            defaultRate * 1.2,
            accuracy: 0.001
        )
    }

    func testAmericanAccentUsesUSVoiceAndTrimsText() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        var requestedLanguages: [String] = []
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { language in
                requestedLanguages.append(language)
                return AVSpeechSynthesisVoice(language: "en-US")
            }
        )

        controller.speak("  Hello  ", accent: .american)

        XCTAssertEqual(requestedLanguages, ["en-US"])
        XCTAssertEqual(
            synthesizer.utterances.first?.speechString,
            "Hello"
        )
    }

    func testJapaneseUsesJapaneseVoiceAndDoesNotFallBackToEnglish() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        var requestedLanguages: [String] = []
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { language in
                requestedLanguages.append(language)
                return language == "ja-JP"
                    ? AVSpeechSynthesisVoice(language: "ja-JP")
                    : nil
            }
        )

        controller.speak(
            "学生",
            target: .japanese,
            accent: .british
        )

        XCTAssertEqual(requestedLanguages, ["ja-JP"])
        XCTAssertEqual(synthesizer.utterances.count, 1)
    }

    func testMissingJapaneseVoiceDoesNotUseEnglishFallback() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { _ in nil }
        )

        controller.speak(
            "学生",
            target: .japanese,
            accent: .system
        )

        XCTAssertTrue(synthesizer.utterances.isEmpty)
    }

    func testBritishAccentUsesGBVoice() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        var requestedLanguages: [String] = []
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { language in
                requestedLanguages.append(language)
                return AVSpeechSynthesisVoice(language: "en-US")
            }
        )

        controller.speak("Hello", accent: .british)

        XCTAssertEqual(requestedLanguages, ["en-GB"])
    }

    func testSystemAccentFallsBackToUSEnglish() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        var requestedLanguages: [String] = []
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { language in
                requestedLanguages.append(language)
                return AVSpeechSynthesisVoice(language: "en-US")
            },
            preferredLanguages: { ["zh-Hans-CN"] }
        )

        controller.speak("Hello", accent: .system)

        XCTAssertEqual(requestedLanguages, ["en-US"])
    }

    func testSystemAccentUsesPreferredEnglishLocale() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        var requestedLanguages: [String] = []
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { language in
                requestedLanguages.append(language)
                return AVSpeechSynthesisVoice(language: "en-US")
            },
            preferredLanguages: { ["zh-Hans-CN", "en-GB"] }
        )

        controller.speak("Hello", accent: .system)

        XCTAssertEqual(requestedLanguages, ["en-GB"])
    }

    func testSystemAccentFallsBackWhenPreferredVoiceIsUnavailable() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        var requestedLanguages: [String] = []
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { language in
                requestedLanguages.append(language)
                return language == "en-US"
                    ? AVSpeechSynthesisVoice(language: "en-US")
                    : nil
            },
            preferredLanguages: { ["en-AU"] }
        )

        controller.speak("Hello", accent: .system)

        XCTAssertEqual(requestedLanguages, ["en-AU", "en-US"])
        XCTAssertEqual(synthesizer.utterances.count, 1)
    }

    func testExplicitBritishAccentDoesNotFallBackToAmerican() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { language in
                language == "en-US"
                    ? AVSpeechSynthesisVoice(language: "en-US")
                    : nil
            }
        )

        controller.speak("Hello", accent: .british)

        XCTAssertTrue(synthesizer.utterances.isEmpty)
    }

    func testNewSpeechStopsCurrentUtterance() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { _ in
                AVSpeechSynthesisVoice(language: "en-US")
            }
        )

        controller.speak("One", accent: .system)
        controller.speak("Two", accent: .system)

        XCTAssertEqual(synthesizer.stopCount, 1)
        XCTAssertEqual(
            synthesizer.utterances.map(\.speechString),
            ["One", "Two"]
        )
    }

    func testBlankTextDoesNotStartSpeech() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { _ in
                AVSpeechSynthesisVoice(language: "en-US")
            }
        )

        controller.speak(" \n ", accent: .system)

        XCTAssertTrue(synthesizer.utterances.isEmpty)
    }

    func testMissingEnglishVoiceDoesNotUseSystemLanguage() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { _ in nil }
        )

        controller.speak("Hello", accent: .american)

        XCTAssertTrue(synthesizer.utterances.isEmpty)
    }

    func testStopEndsCurrentSpeech() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { _ in
                AVSpeechSynthesisVoice(language: "en-US")
            }
        )
        controller.speak("Hello", accent: .system)

        controller.stop()

        XCTAssertEqual(synthesizer.stopCount, 1)
    }

    func testStopAutomaticEndsOnlyAutomaticSpeech() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { _ in
                AVSpeechSynthesisVoice(language: "en-US")
            }
        )
        controller.speak(
            "Automatic",
            accent: .system,
            source: .automatic
        )

        controller.stopAutomatic()

        XCTAssertEqual(synthesizer.stopCount, 1)
    }

    func testStopAutomaticLeavesManualSpeechPlaying() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { _ in
                AVSpeechSynthesisVoice(language: "en-US")
            }
        )
        controller.speak(
            "Manual",
            accent: .system,
            source: .manual
        )

        controller.stopAutomatic()

        XCTAssertEqual(synthesizer.stopCount, 0)
        XCTAssertTrue(synthesizer.isSpeaking)
    }

    func testStopManualEndsOnlyManualSpeech() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { _ in
                AVSpeechSynthesisVoice(language: "en-US")
            }
        )
        controller.speak(
            "Manual",
            accent: .system,
            source: .manual
        )

        controller.stopManual()

        XCTAssertEqual(synthesizer.stopCount, 1)
    }

    func testStopManualLeavesAutomaticSpeechPlaying() {
        let synthesizer = FakeTranslationSpeechSynthesizer()
        let controller = TranslationSpeechController(
            synthesizer: synthesizer,
            voiceForLanguage: { _ in
                AVSpeechSynthesisVoice(language: "en-US")
            }
        )
        controller.speak(
            "Automatic",
            accent: .system,
            source: .automatic
        )

        controller.stopManual()

        XCTAssertEqual(synthesizer.stopCount, 0)
        XCTAssertTrue(synthesizer.isSpeaking)
    }
}
