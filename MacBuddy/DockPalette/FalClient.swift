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
        request.timeoutInterval = 180

        let body: [String: Any] = [
            "prompt": prompt,
            "image_url": "data:image/png;base64,\(pngData.base64EncodedString())",
            "strength": strength,
            "num_images": 1,
            "image_size": "square_hd",
            "output_format": "png",
            "sync_mode": true,
            "enable_safety_checker": false,
        ]
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
