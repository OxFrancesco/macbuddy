import Foundation

/// One end-to-end generation for a single app, entirely off the main actor:
/// load the pristine original, restyle it remotely, and pre-encode the PNG so
/// the main actor only has to write bytes to disk when it commits.
nonisolated enum AIIconGenerator {
    struct Output: Sendable {
        let bitmap: IconBitmap
        let pngData: Data?
    }

    @concurrent
    static func generate(
        appPath: String,
        appName: String,
        stylePrompt: String,
        strength: Double,
        apiKey: String,
        modelId: String
    ) async throws -> Output {
        guard let source = OriginalIconStore.originalBitmap(
            forAppAt: appPath,
            pixelSize: AIIconStylist.canvasSize
        ) else {
            throw FalClient.FalError(message: "Couldn't read the app's original icon.")
        }
        let bitmap = try await AIIconStylist.restyle(
            source: source,
            appName: appName,
            stylePrompt: stylePrompt,
            strength: strength,
            apiKey: apiKey,
            modelId: modelId
        )
        return Output(bitmap: bitmap, pngData: IconPNG.data(from: bitmap.image))
    }
}
