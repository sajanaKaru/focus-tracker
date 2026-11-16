import XCTest
@testable import FocusCore

final class CopilotModelTests: XCTestCase {
    private func result(_ json: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    }

    func testKeepsOnlyEnabledModelsAndDropsDuplicates() {
        let models = CopilotModel.enabled(in: result(#"""
        {"models":{"availableModels":[
          {"modelId":"auto","name":"Auto"},
          {"modelId":"auto","name":"Auto","_meta":{"copilotEnablement":"enabled","copilotUsage":"1x"}},
          {"modelId":"gpt-x","name":"GPT X","_meta":{"copilotEnablement":"disabled"}},
          {"modelId":"claude-y","name":"Claude Y","_meta":{"copilotEnablement":"enabled","copilotUsage":"15x"}},
          {"modelId":"claude-y","name":"Claude Y","_meta":{"copilotEnablement":"enabled","copilotUsage":"15x"}}
        ]}}
        """#))
        XCTAssertEqual(models.map(\.id), ["auto", "claude-y"])
        XCTAssertEqual(models[1].label, "Claude Y (15x)")
    }

    func testNoModelsKeyYieldsAnEmptyList() {
        XCTAssertTrue(CopilotModel.enabled(in: result("{}")).isEmpty)
    }

    func testLabelWithoutUsageIsJustTheName() {
        let models = CopilotModel.enabled(in: result(#"{"models":{"availableModels":[{"modelId":"m","name":"M","_meta":{"copilotEnablement":"enabled"}}]}}"#))
        XCTAssertEqual(models.first?.label, "M")
    }

    func testCopilotProviderDoesNotUseAnAPIKey() {
        XCTAssertFalse(AIProvider.copilot.usesAPIKey)
        XCTAssertTrue(AIProvider.openAI.usesAPIKey)
        XCTAssertEqual(AIProvider.copilot.title, "GitHub Copilot")
        XCTAssertEqual(AIProvider.copilot.defaultModel, "auto")
    }

    func testCopilotErrorMessages() {
        XCTAssertEqual(AIError.copilotNotInstalled.errorDescription, "GitHub Copilot CLI not found. Install it or set its path in Settings.")
        XCTAssertEqual(AIError.copilotNotSignedIn.errorDescription, "Run `copilot login` in a terminal, then try again.")
        XCTAssertTrue(AIError.copilotFailed("boom").localizedDescription.contains("boom"))
    }
}
