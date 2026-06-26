import CoreGraphics
import Foundation
import ImageIO

/// Centralizes the fal.ai model differences used by DockPalette generation.
nonisolated struct FalModelProfile: Sendable {
    let modelId: String
    let acceptsAlphaInput: Bool
    let asksForTransparentOutput: Bool

    private let imageInput: ImageInput
    private let sizeParameter: SizeParameter
    private let supportsStrength: Bool
    private let quality: String?
    private let renderingSpeed: String?
    private let disablesSafetyChecker: Bool
    private let backgroundRemoval: BackgroundRemoval

    init(modelId: String) {
        self.modelId = modelId

        switch Self.family(for: modelId) {
        case .gptImage:
            acceptsAlphaInput = true
            asksForTransparentOutput = true
            imageInput = .imageURLs
            sizeParameter = .imageSize("auto")
            supportsStrength = false
            quality = "high"
            renderingSpeed = nil
            disablesSafetyChecker = false
        case .nanoBanana:
            acceptsAlphaInput = true
            asksForTransparentOutput = true
            imageInput = .imageURLs
            sizeParameter = .resolution("1K")
            supportsStrength = false
            quality = nil
            renderingSpeed = nil
            disablesSafetyChecker = false
        case .ideogram:
            acceptsAlphaInput = false
            asksForTransparentOutput = false
            imageInput = .imageURL
            sizeParameter = .imageSize("square_hd")
            supportsStrength = true
            quality = nil
            renderingSpeed = "QUALITY"
            disablesSafetyChecker = true
        case .imageToImage:
            acceptsAlphaInput = false
            asksForTransparentOutput = false
            imageInput = .imageURL
            sizeParameter = .imageSize("square_hd")
            supportsStrength = true
            quality = nil
            renderingSpeed = nil
            disablesSafetyChecker = true
        }

        backgroundRemoval = .fallbackWhenOpaque(minOpaqueCoverage: 0.1)
    }

    func editRequestBody(prompt: String, imageURI: String, strength: Double) -> [String: Any] {
        var body: [String: Any] = [
            "prompt": prompt,
            "num_images": 1,
            "output_format": "png",
            "sync_mode": true,
        ]
        switch imageInput {
        case .imageURL:
            body["image_url"] = imageURI
        case .imageURLs:
            body["image_urls"] = [imageURI]
        }
        if supportsStrength {
            body["strength"] = strength
        }
        sizeParameter.apply(to: &body)
        if let quality {
            body["quality"] = quality
        }
        if let renderingSpeed {
            body["rendering_speed"] = renderingSpeed
        }
        if disablesSafetyChecker {
            body["enable_safety_checker"] = false
        }
        return body
    }

    func shouldAttemptBackgroundRemoval(outputHasMeaningfulTransparency: Bool) -> Bool {
        switch backgroundRemoval {
        case .fallbackWhenOpaque:
            !outputHasMeaningfulTransparency
        }
    }

    func acceptsBackgroundRemovalResult(hasMeaningfulTransparency: Bool, opaqueCoverage: Double) -> Bool {
        switch backgroundRemoval {
        case .fallbackWhenOpaque(let minOpaqueCoverage):
            hasMeaningfulTransparency && opaqueCoverage >= minOpaqueCoverage
        }
    }

    private enum Family: Sendable {
        case gptImage
        case nanoBanana
        case ideogram
        case imageToImage
    }

    private enum ImageInput: Sendable {
        case imageURL
        case imageURLs
    }

    private enum SizeParameter: Sendable {
        case imageSize(String)
        case resolution(String)

        func apply(to body: inout [String: Any]) {
            switch self {
            case .imageSize(let value):
                body["image_size"] = value
            case .resolution(let value):
                body["resolution"] = value
            }
        }
    }

    private enum BackgroundRemoval: Sendable {
        case fallbackWhenOpaque(minOpaqueCoverage: Double)
    }

    private static func family(for modelId: String) -> Family {
        if modelId.contains("gpt-image") {
            return .gptImage
        }
        if modelId.contains("nano-banana") {
            return .nanoBanana
        }
        if modelId.contains("ideogram") {
            return .ideogram
        }
        return .imageToImage
    }
}

/// Minimal client for fal.ai's synchronous inference endpoint
/// (`https://fal.run/<model-id>`).
nonisolated enum FalClient {
    struct FalError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Sends one image-to-image edit and returns the resulting image.
    @concurrent
    static func editImage(
        pngData: Data,
        prompt: String,
        strength: Double,
        apiKey: String,
        modelId: String
    ) async throws -> CGImage {
        let profile = FalModelProfile(modelId: modelId)
        guard let url = URL(string: "https://fal.run/\(profile.modelId)") else {
            throw FalError(message: "Invalid model id “\(modelId)”.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // gpt-image at high quality regularly takes 3-5 minutes per icon.
        request.timeoutInterval = 420

        let imageURI = "data:image/png;base64,\(pngData.base64EncodedString())"
        let body = profile.editRequestBody(prompt: prompt, imageURI: imageURI, strength: strength)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FalError(message: "No HTTP response from fal.ai.")
        }
        guard http.statusCode == 200 else {
            throw FalError(message: errorMessage(status: http.statusCode, body: data))
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [[String: Any]],
              let first = images.first,
              let imageURLString = first["url"] as? String else {
            throw FalError(message: "Unexpected response from fal.ai.")
        }
        let imageData = try await imageData(from: imageURLString)
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FalError(message: "Couldn't decode the generated image.")
        }
        return image
    }

    /// Cuts the background off an image via pixelcut, returning real RGBA —
    /// the image-edit models never return transparency on fal.
    @concurrent
    static func removeBackground(pngData: Data, apiKey: String) async throws -> CGImage {
        guard let url = URL(string: "https://fal.run/pixelcut/background-removal") else {
            throw FalError(message: "Invalid background-removal endpoint.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        let body: [String: Any] = [
            "image_url": "data:image/png;base64,\(pngData.base64EncodedString())",
            "output_format": "rgba",
            "sync_mode": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FalError(message: errorMessage(status: status, body: data))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let imageInfo = json["image"] as? [String: Any],
              let imageURLString = imageInfo["url"] as? String else {
            throw FalError(message: "Unexpected background-removal response.")
        }
        let imageData = try await imageData(from: imageURLString)
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw FalError(message: "Couldn't decode the cut-out image.")
        }
        return image
    }

    private static func imageData(from urlString: String) async throws -> Data {
        if urlString.hasPrefix("data:") {
            guard let comma = urlString.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(urlString[urlString.index(after: comma)...])) else {
                throw FalError(message: "Couldn't decode the generated image payload.")
            }
            return data
        }
        guard let url = URL(string: urlString) else {
            throw FalError(message: "Invalid image URL in fal.ai response.")
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    private static func errorMessage(status: Int, body: Data) -> String {
        if status == 401 || status == 403 {
            return "fal.ai rejected the API key. Check the key in the AI settings."
        }
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let detail = json["detail"] as? String {
                return "fal.ai error \(status): \(detail)"
            }
            if let details = json["detail"] as? [[String: Any]],
               let msg = details.first?["msg"] as? String {
                return "fal.ai error \(status): \(msg)"
            }
        }
        return "fal.ai request failed (HTTP \(status))."
    }
}
