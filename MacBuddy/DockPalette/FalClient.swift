import CoreGraphics
import Foundation
import ImageIO

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
        guard let url = URL(string: "https://fal.run/\(modelId)") else {
            throw FalError(message: "Invalid model id “\(modelId)”.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // gpt-image at high quality regularly takes 3-5 minutes per icon.
        request.timeoutInterval = 420

        let imageURI = "data:image/png;base64,\(pngData.base64EncodedString())"
        var body: [String: Any] = [
            "prompt": prompt,
            "num_images": 1,
            "output_format": "png",
            "sync_mode": true,
        ]
        if modelId.contains("gpt-image") || modelId.contains("nano-banana") {
            // Instruction-driven editors: image list, no strength knob.
            body["image_urls"] = [imageURI]
            if modelId.contains("gpt-image") {
                body["image_size"] = "auto"
                body["quality"] = "high"
            } else {
                body["resolution"] = "1K"
            }
        } else {
            body["image_url"] = imageURI
            body["strength"] = strength
            body["image_size"] = "square_hd"
            body["enable_safety_checker"] = false
            if modelId.contains("ideogram") {
                body["rendering_speed"] = "QUALITY"
            }
        }
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
