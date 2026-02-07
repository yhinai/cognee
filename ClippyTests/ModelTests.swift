import XCTest
@testable import Clippy

final class ModelTests: XCTestCase {

    // MARK: - AIServiceType

    func testAIServiceTypeGeminiRawValue() {
        XCTAssertEqual(AIServiceType.gemini.rawValue, "Gemini")
    }

    func testAIServiceTypeLocalRawValue() {
        XCTAssertEqual(AIServiceType.local.rawValue, "Local AI")
    }

    func testAIServiceTypeGeminiDescription() {
        XCTAssertEqual(AIServiceType.gemini.description, "Gemini 2.5 Flash (Cloud)")
    }

    func testAIServiceTypeLocalDescription() {
        XCTAssertEqual(AIServiceType.local.description, "Local Qwen3-4b (On-device)")
    }

    func testAIServiceTypeCaseIterable() {
        XCTAssertEqual(AIServiceType.allCases.count, 6)
        XCTAssertTrue(AIServiceType.allCases.contains(.gemini))
        XCTAssertTrue(AIServiceType.allCases.contains(.local))
        XCTAssertTrue(AIServiceType.allCases.contains(.claude))
        XCTAssertTrue(AIServiceType.allCases.contains(.openai))
        XCTAssertTrue(AIServiceType.allCases.contains(.ollama))
        XCTAssertTrue(AIServiceType.allCases.contains(.backend))
    }

    func testAIServiceTypeClaudeRawValue() {
        XCTAssertEqual(AIServiceType.claude.rawValue, "Claude")
    }

    func testAIServiceTypeOpenAIRawValue() {
        XCTAssertEqual(AIServiceType.openai.rawValue, "OpenAI")
    }

    func testAIServiceTypeOllamaRawValue() {
        XCTAssertEqual(AIServiceType.ollama.rawValue, "Ollama")
    }

    // MARK: - InputMode

    func testInputModeEnumCases() {
        let none = InputMode.none
        let text = InputMode.textCapture
        let voice = InputMode.voiceCapture
        let vision = InputMode.visionCapture

        // Verify all cases are distinct
        XCTAssertFalse(areEqual(none, text))
        XCTAssertFalse(areEqual(text, voice))
        XCTAssertFalse(areEqual(voice, vision))
    }

    // MARK: - ClippyAnimationState

    func testIdleStateProperties() {
        let state = ClippyAnimationState.idle
        XCTAssertEqual(state.gifFileName, "clippy-idle")
        XCTAssertEqual(state.defaultMessage, "Listening...")
    }

    func testWritingStateProperties() {
        let state = ClippyAnimationState.writing
        XCTAssertEqual(state.gifFileName, "clippy-writing")
        XCTAssertEqual(state.defaultMessage, "Got it...")
    }

    func testThinkingStateProperties() {
        let state = ClippyAnimationState.thinking
        XCTAssertEqual(state.gifFileName, "clippy-thinking")
        XCTAssertEqual(state.defaultMessage, "Thinking...")
    }

    func testDoneStateProperties() {
        let state = ClippyAnimationState.done
        XCTAssertEqual(state.gifFileName, "clippy-done")
        XCTAssertEqual(state.defaultMessage, "Done!")
    }

    func testErrorStateProperties() {
        let state = ClippyAnimationState.error
        XCTAssertEqual(state.gifFileName, "clippy-idle") // Uses idle animation for errors
        XCTAssertEqual(state.defaultMessage, "Oops! Something went wrong")
    }

    // MARK: - ClipboardAction Identity

    func testClipboardActionIdUniqueness() {
        let urlAction = ClipboardAction.openURL(URL(string: "https://example.com")!)
        let callAction = ClipboardAction.callNumber("555-1234")
        let emailAction = ClipboardAction.emailTo("test@test.com")
        let mapsAction = ClipboardAction.openMaps("123 Main St")

        let ids = [urlAction.id, callAction.id, emailAction.id, mapsAction.id]
        // All IDs should be unique
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    // Helper to compare InputMode without Equatable conformance
    private func areEqual(_ a: InputMode, _ b: InputMode) -> Bool {
        switch (a, b) {
        case (.none, .none), (.textCapture, .textCapture),
             (.voiceCapture, .voiceCapture), (.visionCapture, .visionCapture):
            return true
        default:
            return false
        }
    }
}
