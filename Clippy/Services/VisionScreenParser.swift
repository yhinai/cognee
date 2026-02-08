import Foundation
import Vision
import AppKit
import CoreGraphics
import ScreenCaptureKit
import os

// MARK: - Document Structure Models

struct DocumentObservation {
    let text: String
    let confidence: Float
    let boundingBox: CGRect
    let documentStructure: DocumentStructure?
}

struct DocumentStructure {
    let headers: [DocumentObservation]
    let paragraphs: [DocumentObservation]
    let tables: [DocumentObservation]
    let lists: [DocumentObservation]
}

struct ParsedScreenContent {
    let fullText: String
    let structuredContent: DocumentStructure?
    let confidence: Float
    let processingTime: TimeInterval
    let timestamp: Date
    let imageData: Data? // Added for LFM2 Vision
}

// MARK: - Vision Screen Parser

class VisionScreenParser: ObservableObject {
    
    // MARK: - Published Properties
    @Published var isProcessing = false
    @Published var lastParsedContent: ParsedScreenContent?
    
    // MARK: - Configuration
    private let recognitionLevel: VNRequestTextRecognitionLevel
    private let usesLanguageCorrection: Bool
    private let customWords: [String]
    
    init(
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        usesLanguageCorrection: Bool = true,
        customWords: [String] = []
    ) {
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
        self.customWords = customWords
    }
    
    // MARK: - Main Parsing Function

    func parseCurrentScreen() async -> Result<ParsedScreenContent, Error> {
        await MainActor.run { self.isProcessing = true }

        let startTime = Date()

        // Step 1: Capture screen
        guard let screenImage = await self.captureScreen() else {
            await MainActor.run { self.isProcessing = false }
            return .failure(VisionParserError.screenCaptureFailed)
        }

        // Step 2: Process with Vision framework
        let result = await withCheckedContinuation { continuation in
            self.processImageWithVision(screenImage) { result in
                continuation.resume(returning: result)
            }
        }

        let processingTime = Date().timeIntervalSince(startTime)

        switch result {
        case .success(let parsedContent):
            let finalContent = ParsedScreenContent(
                fullText: parsedContent.fullText,
                structuredContent: parsedContent.structuredContent,
                confidence: parsedContent.confidence,
                processingTime: processingTime,
                timestamp: Date(),
                imageData: screenImage.tiffRepresentation // Store image data
            )

            await MainActor.run {
                self.lastParsedContent = finalContent
                self.isProcessing = false
            }
            return .success(finalContent)

        case .failure(let error):
            await MainActor.run { self.isProcessing = false }
            return .failure(error)
        }
    }
    
    // MARK: - Screen Capture

    private func captureScreen() async -> NSImage? {
        guard NSScreen.main != nil else { return nil }

        // Use ScreenCaptureKit for macOS 12.3+
        if #available(macOS 12.3, *) {
            return await captureWithScreenCaptureKit()
        } else {
            return nil
        }
    }

    @available(macOS 12.3, *)
    private func captureWithScreenCaptureKit() async -> NSImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let display = content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])

            let config = SCStreamConfiguration()
            config.width = Int(display.width * 2)
            config.height = Int(display.height * 2)
            config.showsCursor = false
            config.capturesAudio = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        } catch {
            return nil
        }
    }
    
    // MARK: - Vision Processing
    
    private func processImageWithVision(_ image: NSImage, completion: @escaping (Result<ParsedScreenContent, Error>) -> Void) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion(.failure(VisionParserError.invalidImage))
            return
        }
        
        // Create document segmentation request to detect document regions
        let segmentationRequest = VNDetectDocumentSegmentationRequest { [weak self] request, error in
            guard let self = self else { return }
            
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let rectangleObservations = request.results as? [VNRectangleObservation] else {
                completion(.failure(VisionParserError.noTextFound))
                return
            }
            
            // Process document regions with text recognition
            self.processDocumentRegions(rectangleObservations, cgImage: cgImage) { result in
                completion(result)
            }
        }
        
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        do {
            try handler.perform([segmentationRequest])
        } catch {
            completion(.failure(error))
        }
    }
    
    // MARK: - Document Processing
    
    private func processDocumentRegions(_ rectangleObservations: [VNRectangleObservation], cgImage: CGImage, completion: @escaping (Result<ParsedScreenContent, Error>) -> Void) {
        guard !rectangleObservations.isEmpty else {
            // Fallback to full image text recognition
            let textRequest = VNRecognizeTextRequest { [weak self] request, error in
                guard let self = self else { return }
                
                if let error = error {
                    completion(.failure(error))
                    return
                }
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    completion(.failure(VisionParserError.noTextFound))
                    return
                }
                
                let processedContent = self.processTextObservationsWithStructure(observations)
                completion(.success(processedContent))
            }
            
            textRequest.recognitionLevel = recognitionLevel
            textRequest.usesLanguageCorrection = usesLanguageCorrection
            textRequest.customWords = customWords
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([textRequest])
            } catch {
                completion(.failure(error))
            }
            return
        }
        
        // Process each document region
        var allText = ""
        var totalConfidence: Float = 0
        var regionCount = 0
        
        var headers: [DocumentObservation] = []
        var paragraphs: [DocumentObservation] = []
        var tables: [DocumentObservation] = []
        var lists: [DocumentObservation] = []
        
        let group = DispatchGroup()
        
        for rectangleObservation in rectangleObservations {
            group.enter()
            
            // Crop the image to the document region
            let croppedImage = cropImage(cgImage, to: rectangleObservation.boundingBox)
            
            guard let croppedCGImage = croppedImage else {
                group.leave()
                continue
            }
            
            // Recognize text in this region
            let regionTextRequest = VNRecognizeTextRequest { [weak self] request, error in
                defer { group.leave() }
                
                guard let self = self else { return }
                
                if let error = error {
                    Logger.services.error("Error recognizing text in region: \(error.localizedDescription, privacy: .public)")
                    return
                }
                
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    return
                }
                
                // Process text in this region
                for observation in observations {
                    guard let topCandidate = observation.topCandidates(1).first else { continue }
                    
                    let text = topCandidate.string
                    let confidence = topCandidate.confidence
                    let boundingBox = observation.boundingBox
                    
                    totalConfidence += confidence
                    regionCount += 1
                    
                    allText += text + "\n"
                    
                    let docObservation = DocumentObservation(
                        text: text,
                        confidence: confidence,
                        boundingBox: boundingBox,
                        documentStructure: nil
                    )
                    
                    // Classify based on region characteristics
                    if self.isLikelyHeader(text: text, boundingBox: boundingBox) {
                        headers.append(docObservation)
                    } else if self.isLikelyList(text: text) {
                        lists.append(docObservation)
                    } else if self.isLikelyTable(text: text) {
                        tables.append(docObservation)
                    } else {
                        paragraphs.append(docObservation)
                    }
                }
            }
            
            regionTextRequest.recognitionLevel = recognitionLevel
            regionTextRequest.usesLanguageCorrection = usesLanguageCorrection
            regionTextRequest.customWords = customWords
            
            let handler = VNImageRequestHandler(cgImage: croppedCGImage, options: [:])
            do {
                try handler.perform([regionTextRequest])
            } catch {
                Logger.services.error("Error performing text recognition on region: \(error.localizedDescription, privacy: .public)")
                group.leave()
            }
        }
        
        group.notify(queue: .main) {
            let averageConfidence = regionCount > 0 ? totalConfidence / Float(regionCount) : 0
            
            let documentStructure = DocumentStructure(
                headers: headers,
                paragraphs: paragraphs,
                tables: tables,
                lists: lists
            )
            
            let processedContent = ParsedScreenContent(
                fullText: allText.trimmingCharacters(in: .whitespacesAndNewlines),
                structuredContent: documentStructure,
                confidence: averageConfidence,
                processingTime: 0, // Will be set by caller
                timestamp: Date(),
                imageData: nil
            )
            
            completion(.success(processedContent))
        }
    }
    
    private func cropImage(_ image: CGImage, to boundingBox: CGRect) -> CGImage? {
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        
        // Convert Vision's normalized coordinates to image coordinates
        let x = boundingBox.origin.x * imageWidth
        let y = (1.0 - boundingBox.origin.y - boundingBox.height) * imageHeight
        let width = boundingBox.width * imageWidth
        let height = boundingBox.height * imageHeight
        
        let cropRect = CGRect(x: x, y: y, width: width, height: height)
        
        return image.cropping(to: cropRect)
    }
    
    private func processTextObservationsWithStructure(_ observations: [VNRecognizedTextObservation]) -> ParsedScreenContent {
        var fullText = ""
        var totalConfidence: Float = 0
        var observationCount = 0
        
        var headers: [DocumentObservation] = []
        var paragraphs: [DocumentObservation] = []
        var tables: [DocumentObservation] = []
        var lists: [DocumentObservation] = []
        
        for observation in observations {
            guard let topCandidate = observation.topCandidates(1).first else { continue }
            
            let text = topCandidate.string
            let confidence = topCandidate.confidence
            let boundingBox = observation.boundingBox
            
            totalConfidence += confidence
            observationCount += 1
            
            // Add to full text
            fullText += text + "\n"
            
            // Create document observation
            let docObservation = DocumentObservation(
                text: text,
                confidence: confidence,
                boundingBox: boundingBox,
                documentStructure: nil
            )
            
            // Simple heuristic for document structure classification
            if self.isLikelyHeader(text: text, boundingBox: boundingBox) {
                headers.append(docObservation)
            } else if self.isLikelyList(text: text) {
                lists.append(docObservation)
            } else if self.isLikelyTable(text: text) {
                tables.append(docObservation)
            } else {
                paragraphs.append(docObservation)
            }
        }
        
        let averageConfidence = observationCount > 0 ? totalConfidence / Float(observationCount) : 0
        
        let documentStructure = DocumentStructure(
            headers: headers,
            paragraphs: paragraphs,
            tables: tables,
            lists: lists
        )
        
        return ParsedScreenContent(
            fullText: fullText.trimmingCharacters(in: .whitespacesAndNewlines),
            structuredContent: documentStructure,
            confidence: averageConfidence,
            processingTime: 0, // Will be set by caller
            timestamp: Date(),
            imageData: nil // No image data in this helper method
        )
    }
    
    // MARK: - Document Structure Heuristics
    
    private func isLikelyHeader(text: String, boundingBox: CGRect) -> Bool {
        // Simple heuristic: short text, likely at top of screen
        return text.count < 50 && boundingBox.maxY > 0.8
    }
    
    private func isLikelyList(text: String) -> Bool {
        // Look for list indicators
        let listPatterns = ["•", "-", "*", "1.", "2.", "3.", "a.", "b.", "c."]
        return listPatterns.contains { text.hasPrefix($0) }
    }
    
    private func isLikelyTable(text: String) -> Bool {
        // Look for tabular patterns (multiple spaces, tabs, or separators)
        let tabularPatterns = ["\t", "  ", " | ", " |", "| "]
        return tabularPatterns.contains { text.contains($0) }
    }
    
    // MARK: - Utility Functions
    
    func getLastParsedText() -> String {
        return lastParsedContent?.fullText ?? ""
    }
    
    func getLastParsedStructuredContent() -> DocumentStructure? {
        return lastParsedContent?.structuredContent
    }
}

// MARK: - Error Types

enum VisionParserError: LocalizedError {
    case screenCaptureFailed
    case invalidImage
    case noTextFound
    case processingFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .screenCaptureFailed:
            return "Failed to capture screen image"
        case .invalidImage:
            return "Invalid image for processing"
        case .noTextFound:
            return "No text found in the image"
        case .processingFailed(let message):
            return "Processing failed: \(message)"
        }
    }
}

// MARK: - Extensions for Integration

extension VisionScreenParser {

    /// Convenience method for quick text extraction
    func extractTextFromScreen() async -> String? {
        let result = await parseCurrentScreen()
        switch result {
        case .success(let content):
            return content.fullText
        case .failure(let error):
            Logger.services.error("Vision parsing error: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

}
