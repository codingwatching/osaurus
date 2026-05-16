//
//  RemoteProviderModelDiscoveryTests.swift
//  osaurusTests
//
//  Covers OpenAI-compatible model discovery fallbacks for providers whose
//  `/models` endpoint is absent or not OpenAI-schema-compatible.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Remote provider model discovery")
struct RemoteProviderModelDiscoveryTests {

    @Test func openAICompatibleDiscovery_usesManualModelsWhenModelsEndpointIsMissing() throws {
        let provider = makeProvider(
            manualModelIds: [" MiniMax-Text-01 ", "", "minimax-text-01"]
        )
        let body = Data(#"{"error":{"message":"not found"}}"#.utf8)

        let models = try RemoteProviderService.decodeOpenAICompatibleModelsResponse(
            data: body,
            statusCode: 404,
            provider: provider
        )

        #expect(models == ["MiniMax-Text-01"])
    }

    @Test func openResponsesDiscovery_usesManualModelsWhenModelsSchemaIsIncompatible() throws {
        let provider = makeProvider(
            providerType: .openResponses,
            manualModelIds: ["direct-chat"]
        )
        let body = Data(#"{"models":["not-openai-shape"]}"#.utf8)

        let models = try RemoteProviderService.decodeOpenAICompatibleModelsResponse(
            data: body,
            statusCode: 200,
            provider: provider
        )

        #expect(models == ["direct-chat"])
    }

    @Test func openAICompatibleDiscovery_doesNotFallbackForUnauthorizedModelsResponse() {
        let provider = makeProvider(manualModelIds: ["direct-chat"])
        let body = Data(#"{"error":{"message":"bad key"}}"#.utf8)

        #expect(throws: RemoteProviderServiceError.self) {
            try RemoteProviderService.decodeOpenAICompatibleModelsResponse(
                data: body,
                statusCode: 401,
                provider: provider
            )
        }
    }

    @Test func openAICompatibleDiscovery_doesNotFallbackWithoutManualModels() {
        let provider = makeProvider()
        let body = Data(#"{"error":{"message":"not found"}}"#.utf8)

        #expect(throws: RemoteProviderServiceError.self) {
            try RemoteProviderService.decodeOpenAICompatibleModelsResponse(
                data: body,
                statusCode: 404,
                provider: provider
            )
        }
    }

    @Test func nonOpenAICompatibleDiscovery_doesNotUseManualModelsFallback() {
        let provider = makeProvider(providerType: .anthropic, manualModelIds: ["direct-chat"])
        let body = Data(#"{"error":{"message":"not found"}}"#.utf8)

        #expect(throws: RemoteProviderServiceError.self) {
            try RemoteProviderService.decodeOpenAICompatibleModelsResponse(
                data: body,
                statusCode: 404,
                provider: provider
            )
        }
    }

    @Test func lemonadeModelsPath_canBeRepresentedByBasePath() throws {
        let provider = makeProvider(
            providerProtocol: .http,
            port: 8000,
            basePath: "/api/v1"
        )

        #expect(provider.url(for: "/models")?.absoluteString == "http://127.0.0.1:8000/api/v1/models")
    }

    @Test func lemonadeModelsResponse_parsesOpenAIListWithExtraFields() throws {
        let provider = makeProvider(basePath: "/api/v1")
        let body = Data(
            """
            {
              "object": "list",
              "data": [
                {
                  "id": "lemonade-chat",
                  "object": "model",
                  "created": 0,
                  "owned_by": "lemonade",
                  "context_length": 131072,
                  "capabilities": ["chat"]
                }
              ]
            }
            """.utf8
        )

        let models = try RemoteProviderService.decodeOpenAICompatibleModelsResponse(
            data: body,
            statusCode: 200,
            provider: provider
        )

        #expect(models == ["lemonade-chat"])
    }

    private func makeProvider(
        providerProtocol: RemoteProviderProtocol = .https,
        port: Int? = nil,
        basePath: String = "/v1",
        providerType: RemoteProviderType = .openaiLegacy,
        manualModelIds: [String] = []
    ) -> RemoteProvider {
        RemoteProvider(
            name: "Test Provider",
            host: "127.0.0.1",
            providerProtocol: providerProtocol,
            port: port,
            basePath: basePath,
            authType: .none,
            providerType: providerType,
            manualModelIds: manualModelIds
        )
    }
}
