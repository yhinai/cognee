import Foundation
import AVFoundation
import os

class ElevenLabsService: ObservableObject {
    private let apiKey: String
    private let scribeURL = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    func transcribe(audioFileURL: URL) async throws -> String {
        Logger.network.info("Sending audio for transcription")
        
        // Check file exists and has content
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: audioFileURL.path)[.size] as? Int) ?? 0
        Logger.network.info("Audio file size: \(fileSize, privacy: .public) bytes")
        
        guard fileSize > 0 else {
            throw NSError(domain: "ElevenLabs", code: -1, userInfo: [NSLocalizedDescriptionKey: "Audio file is empty"])
        }
        
        var request = URLRequest(url: scribeURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        let data = try createMultipartBody(fileURL: audioFileURL, boundary: boundary)
        Logger.network.info("Request body size: \(data.count, privacy: .public) bytes")
        
        let (responseData, response) = try await URLSession.shared.upload(for: request, from: data)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ElevenLabs", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        Logger.network.info("Response status: \(httpResponse.statusCode, privacy: .public)")
        
        if httpResponse.statusCode != 200 {
            let errorMsg = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            Logger.network.error("API error (\(httpResponse.statusCode, privacy: .public)): \(errorMsg, privacy: .private)")
            throw NSError(domain: "ElevenLabs", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "API Error: \(errorMsg)"])
        }
        
        // Parse response
        if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
           let text = json["text"] as? String {
            Logger.network.info("Transcription complete")
            return text
        }
        
        Logger.network.warning("Could not parse JSON response")
        return ""
    }
    
    private func createMultipartBody(fileURL: URL, boundary: String) throws -> Data {
        var data = Data()
        let fileData = try Data(contentsOf: fileURL)

        // Add Model ID param
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"model_id\"\r\n\r\n".utf8))
        data.append(Data("scribe_v1\r\n".utf8))

        // Add File
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"audio.m4a\"\r\n".utf8))
        data.append(Data("Content-Type: audio/m4a\r\n\r\n".utf8))
        data.append(fileData)
        data.append(Data("\r\n".utf8))

        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }
}

// MARK: - Audio Recorder

class AudioRecorder: NSObject, ObservableObject {
    private var audioRecorder: AVAudioRecorder?
    @Published var isRecording = false
    
    func startRecording() -> URL? {
        if #available(macOS 10.14, *) {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: break
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            case .denied, .restricted: return nil
            @unknown default: return nil
            }
        }

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("clippy_voice.m4a")
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 12000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            guard audioRecorder?.prepareToRecord() == true else { return nil }
            
            if audioRecorder?.record() == true {
                isRecording = true
                return fileURL
            }
            return nil
        } catch {
            return nil
        }
    }
    
    func stopRecording() -> URL? {
        guard let recorder = audioRecorder, isRecording else { return nil }
        recorder.stop()
        isRecording = false
        return recorder.url
    }
}
