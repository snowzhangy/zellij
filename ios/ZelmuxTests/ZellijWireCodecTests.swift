import XCTest
@testable import Zelmux

final class ZellijWireCodecTests: XCTestCase {
    func testResizeEncodingMatchesWebClientControlEnvelope() throws {
        let json = try ZellijWireCodec.encodeResize(webClientID: "abc", rows: 32, cols: 100)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let root = try XCTUnwrap(object)
        XCTAssertEqual(root["web_client_id"] as? String, "abc")

        let payload = try XCTUnwrap(root["payload"] as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "TerminalResize")
        XCTAssertEqual(payload["rows"] as? Int, 32)
        XCTAssertEqual(payload["cols"] as? Int, 100)
    }

    func testDecodeSetConfigToleratesExtraFields() throws {
        let data = Data("""
        {
          "type": "SetConfig",
          "font": "Menlo",
          "mac_option_is_meta": true,
          "theme": {"background": "#000000"},
          "future_field": "ignored"
        }
        """.utf8)

        let event = try ZellijWireCodec.decodeControlEvent(from: data)
        XCTAssertEqual(event, .setConfig(font: "Menlo", macOptionIsMeta: true))
    }

    func testDecodeQueryTerminalSize() throws {
        let data = Data(#"{"type":"QueryTerminalSize"}"#.utf8)
        let event = try ZellijWireCodec.decodeControlEvent(from: data)
        XCTAssertEqual(event, .queryTerminalSize)
    }

    func testDecodeUnknownControlMessageIsNonFatal() throws {
        let data = Data(#"{"type":"FutureMessage","value":42}"#.utf8)
        let event = try ZellijWireCodec.decodeControlEvent(from: data)
        XCTAssertEqual(event, .unknown("FutureMessage"))
    }

    func testLoginRequestJSONShape() throws {
        let data = try JSONEncoder.zellij.encode(LoginRequest(authToken: "token-123", rememberMe: true))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let root = try XCTUnwrap(object)
        XCTAssertEqual(root["auth_token"] as? String, "token-123")
        XCTAssertEqual(root["remember_me"] as? Bool, true)
    }

    func testSessionResponseDecodingIgnoresExtraFields() throws {
        let data = Data("""
        {
          "web_client_id": "client-1",
          "is_read_only": true,
          "future_field": "ignored"
        }
        """.utf8)

        let response = try JSONDecoder.zellij.decode(SessionResponse.self, from: data)
        XCTAssertEqual(response.webClientID, "client-1")
        XCTAssertTrue(response.isReadOnly)
    }

    func testSessionListResponseDecoding() throws {
        let data = Data("""
        {
          "sessions": [
            {"name": "work", "status": "live"},
            {"name": "agent", "status": "resurrectable"}
          ]
        }
        """.utf8)
        let response = try JSONDecoder.zellij.decode(SessionListResponse.self, from: data)
        XCTAssertEqual(response.sessions[0], SessionListItem(name: "work", status: .live))
        XCTAssertEqual(response.sessions[1], SessionListItem(name: "agent", status: .resurrectable))
    }

    func testLegacySessionListResponseDecoding() throws {
        let data = Data(#"{"sessions":["work","agent","scratch"]}"#.utf8)
        let response = try JSONDecoder.zellij.decode(SessionListResponse.self, from: data)
        XCTAssertEqual(
            response.sessions,
            [
                SessionListItem(name: "work", status: .unknown),
                SessionListItem(name: "agent", status: .unknown),
                SessionListItem(name: "scratch", status: .unknown)
            ]
        )
    }

    func testANSISanitizerStripsEscapeSequences() {
        let raw = "\u{001B}[31mred\u{001B}[0m\r\nplain"
        XCTAssertEqual(ANSITextSanitizer.readableText(from: raw), "red\nplain")
    }

    func testTerminalSelectionCleanerDropsZellijChrome() {
        let raw = """
        Zellij (work)  Tab #1
        actual agent output
        Ctrl + g p t n h s o q
        prompt text
        """

        let cleaned = TerminalSelectionCleaner.pasteboardText(from: Data(raw.utf8))
        XCTAssertEqual(cleaned, "actual agent output\nprompt text")
    }

    func testLastReplyIgnoresTrailingPromptAndAgentChrome() {
        let lines = [
            "Earlier unrelated answer",
            "❯ previous prompt",
            "Item: PhotoPicker HEIC",
            "(PromptComposerView:230)",
            "Current: Raw Data upload, HEIC passes",
            "through",
            "Patch: UIImage.pngData() convert",
            "────────────────────────────────────────",
            "Functional but:",
            "- Spaces in home break agent path parse.",
            "- HEIC from PhotoPicker breaks most agent",
            "CLIs (can't decode).",
            "Apply patches if you want release polish.",
            "Want me to land them?",
            "✻ Brewed for 10s",
            "───────────────────────────────────────────",
            "❯",
            "───────────────────────────────────────────",
            "[CAVEMAN] ok. this is the content of copy last reply."
        ]

        let reply = TerminalSelectionCleaner.lastReplyText(fromCleanedLines: lines)
        XCTAssertEqual(
            reply,
            """
            Item: PhotoPicker HEIC
            (PromptComposerView:230)
            Current: Raw Data upload, HEIC passes
            through
            Patch: UIImage.pngData() convert
            Functional but:
            - Spaces in home break agent path parse.
            - HEIC from PhotoPicker breaks most agent
            CLIs (can't decode).
            Apply patches if you want release polish.
            Want me to land them?
            """
        )
    }

    func testBestLastReplyPrefersTranscriptOverVisibleTail() {
        let visibleTail = [
            "Want me to land them?"
        ]
        let transcript = [
            "Earlier unrelated answer",
            "❯ previous prompt",
            "Item: PhotoPicker HEIC",
            "(PromptComposerView:230)",
            "Current: Raw Data upload, HEIC passes",
            "through",
            "Patch: UIImage.pngData() convert",
            "Functional but:",
            "- Spaces in home break agent path parse.",
            "- HEIC from PhotoPicker breaks most agent",
            "CLIs (can't decode).",
            "Apply patches if you want release polish.",
            "Want me to land them?",
            "✻ Brewed for 10s",
            "❯"
        ]

        let reply = TerminalSelectionCleaner.bestLastReplyText(
            currentLines: visibleTail,
            transcriptLines: transcript
        )
        XCTAssertEqual(
            reply,
            """
            Item: PhotoPicker HEIC
            (PromptComposerView:230)
            Current: Raw Data upload, HEIC passes
            through
            Patch: UIImage.pngData() convert
            Functional but:
            - Spaces in home break agent path parse.
            - HEIC from PhotoPicker breaks most agent
            CLIs (can't decode).
            Apply patches if you want release polish.
            Want me to land them?
            """
        )
    }

    @MainActor
    func testTerminalStreamCoalescesChunksInOrder() {
        let stream = TerminalStream()
        stream.append(Data("one".utf8))
        stream.append(Data("two".utf8))
        stream.append(Data("three".utf8))

        let chunk = String(decoding: stream.drainForFrame(), as: UTF8.self)
        XCTAssertEqual(chunk, "onetwothree")
        XCTAssertTrue(stream.drainForFrame().isEmpty)
    }

    func testCertificatePromptFormatsUntrustedHash() {
        let prompt = CertificatePrompt.untrusted(
            observed: "00112233445566778899aabbccddeeff"
        )

        XCTAssertEqual(prompt.title, "Trust Zellij server?")
        XCTAssertEqual(prompt.actionTitle, "Trust")
        XCTAssertEqual(prompt.message, "00:11:22:33:44:55:66:77\n88:99:aa:bb:cc:dd:ee:ff")
    }

    func testCertificatePromptShowsMismatch() {
        let prompt = CertificatePrompt.mismatch(
            observed: "aaaaaaaaaaaaaaaa",
            expected: "bbbbbbbbbbbbbbbb"
        )

        XCTAssertEqual(prompt.title, "Certificate changed")
        XCTAssertEqual(prompt.actionTitle, "Re-trust")
        XCTAssertTrue(prompt.message.contains("Observed:"))
        XCTAssertTrue(prompt.message.contains("aa:aa:aa:aa:aa:aa:aa:aa"))
        XCTAssertTrue(prompt.message.contains("Expected:"))
        XCTAssertTrue(prompt.message.contains("bb:bb:bb:bb:bb:bb:bb:bb"))
    }

    func testProfileDecodingDefaultsTouchModeForExistingSettings() throws {
        let data = Data("""
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Mac",
          "baseURL": "https://127.0.0.1:8082",
          "sessionName": "zellij",
          "trustedPublicKeyHash": null
        }
        """.utf8)

        let profile = try JSONDecoder().decode(ZellijProfile.self, from: data)
        XCTAssertEqual(profile.touchMode, .scroll)
    }

    func testSettingsMergeNewDefaultSnippets() {
        let settings = AppSettings(
            profiles: [],
            selectedProfileID: nil,
            fontSize: 12,
            promptHistory: [],
            snippets: ["/resume"]
        )

        let merged = settings.mergingDefaultSnippets()
        XCTAssertEqual(merged.snippets.first, "/resume")
        XCTAssertTrue(merged.snippets.contains("/model"))
        XCTAssertTrue(merged.snippets.contains("/status"))
        XCTAssertEqual(merged.snippets.filter { $0 == "/resume" }.count, 1)
    }
}
