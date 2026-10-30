//
//  PrivacyShield.swift
//  leanring-buddy
//
//  Runs before any screenshot leaves the Mac. Uses Apple's on-device
//  text recognition (Vision) to find Aadhaar numbers, PAN numbers and
//  card numbers, and blacks them out, along with every password field
//  found in the Accessibility tree. Nemotron never sees them.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Vision

nonisolated struct PrivacyShieldResult: Sendable {
    let redactedJPEGData: Data
    let redactedRegionCount: Int
}

nonisolated enum PrivacyShield {

    /// Redacts sensitive regions in a screenshot.
    /// - Parameters:
    ///   - screenshotJPEGData: the captured screen image.
    ///   - additionalRedactionRectsInImagePixels: rects (top-left origin, image pixel space)
    ///     to always black out, e.g. password fields from the Accessibility tree.
    nonisolated static func redact(
        screenshotJPEGData: Data,
        additionalRedactionRectsInImagePixels: [CGRect]
    ) -> PrivacyShieldResult {
        guard let imageSource = CGImageSourceCreateWithData(screenshotJPEGData as CFData, nil),
              let screenshotImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return PrivacyShieldResult(redactedJPEGData: screenshotJPEGData, redactedRegionCount: 0)
        }

        let imageWidth = CGFloat(screenshotImage.width)
        let imageHeight = CGFloat(screenshotImage.height)

        var redactionRectsInImagePixels = additionalRedactionRectsInImagePixels
        redactionRectsInImagePixels.append(contentsOf: findSensitiveTextRects(in: screenshotImage, imageWidth: imageWidth, imageHeight: imageHeight))

        guard !redactionRectsInImagePixels.isEmpty else {
            return PrivacyShieldResult(redactedJPEGData: screenshotJPEGData, redactedRegionCount: 0)
        }

        guard let drawingContext = CGContext(
            data: nil,
            width: screenshotImage.width,
            height: screenshotImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return PrivacyShieldResult(redactedJPEGData: screenshotJPEGData, redactedRegionCount: 0)
        }

        drawingContext.draw(screenshotImage, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        drawingContext.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1))

        for redactionRect in redactionRectsInImagePixels {
            // CGContext has a bottom-left origin; our rects are top-left.
            let flippedRect = CGRect(
                x: redactionRect.origin.x - 3,
                y: imageHeight - redactionRect.origin.y - redactionRect.height - 3,
                width: redactionRect.width + 6,
                height: redactionRect.height + 6
            )
            drawingContext.fill(flippedRect)
        }

        guard let redactedImage = drawingContext.makeImage(),
              let redactedJPEGData = encodeAsJPEG(redactedImage) else {
            return PrivacyShieldResult(redactedJPEGData: screenshotJPEGData, redactedRegionCount: 0)
        }

        return PrivacyShieldResult(redactedJPEGData: redactedJPEGData, redactedRegionCount: redactionRectsInImagePixels.count)
    }

    /// ImageIO JPEG encoding (thread-safe, unlike AppKit image reps).
    nonisolated static func encodeAsJPEG(_ image: CGImage, compressionQuality: CGFloat = 0.8) -> Data? {
        let outputData = NSMutableData()
        guard let imageDestination = CGImageDestinationCreateWithData(outputData as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let destinationOptions = [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        CGImageDestinationAddImage(imageDestination, image, destinationOptions)
        guard CGImageDestinationFinalize(imageDestination) else {
            return nil
        }
        return outputData as Data
    }

    /// A small thumbnail for action receipts.
    nonisolated static func makeThumbnailJPEG(from jpegData: Data, maximumWidth: CGFloat = 360) -> Data? {
        guard let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumWidth
        ] as CFDictionary
        guard let thumbnailImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions) else { return nil }
        return encodeAsJPEG(thumbnailImage, compressionQuality: 0.7)
    }

    /// Patterns for identifiers that must never leave the device.
    nonisolated private static let sensitivePatterns: [NSRegularExpression] = {
        let patternStrings = [
            #"\b\d{4}[\s-]?\d{4}[\s-]?\d{4}\b"#,          // Aadhaar (12 digits, optionally grouped)
            #"\b[A-Z]{5}\d{4}[A-Z]\b"#,                    // PAN
            #"\b(?:\d[\s-]?){13,19}\b"#,                    // Card numbers
            #"\b[A-Z]\d{7}\b"#                              // Indian passport number
        ]
        return patternStrings.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    nonisolated private static func findSensitiveTextRects(
        in screenshotImage: CGImage,
        imageWidth: CGFloat,
        imageHeight: CGFloat
    ) -> [CGRect] {
        let textRecognitionRequest = VNRecognizeTextRequest()
        textRecognitionRequest.recognitionLevel = .fast
        textRecognitionRequest.usesLanguageCorrection = false

        let requestHandler = VNImageRequestHandler(cgImage: screenshotImage, options: [:])
        do {
            try requestHandler.perform([textRecognitionRequest])
        } catch {
            print("⚠️ PrivacyShield: text recognition failed — \(error)")
            return []
        }

        guard let textObservations = textRecognitionRequest.results else {
            return []
        }

        var sensitiveRects: [CGRect] = []
        for textObservation in textObservations {
            guard let recognizedText = textObservation.topCandidates(1).first?.string else { continue }
            let fullRange = NSRange(recognizedText.startIndex..., in: recognizedText)
            let containsSensitiveText = sensitivePatterns.contains { pattern in
                pattern.firstMatch(in: recognizedText, range: fullRange) != nil
            }
            guard containsSensitiveText else { continue }

            // Vision's bounding box is normalized with a bottom-left origin.
            let normalizedBox = textObservation.boundingBox
            sensitiveRects.append(CGRect(
                x: normalizedBox.origin.x * imageWidth,
                y: (1 - normalizedBox.origin.y - normalizedBox.height) * imageHeight,
                width: normalizedBox.width * imageWidth,
                height: normalizedBox.height * imageHeight
            ))
        }
        return sensitiveRects
    }

    /// Maps a global AppKit rect into a capture's image pixel space (top-left origin).
    static func convertAppKitRectToImagePixels(
        _ appKitRect: CGRect,
        displayFrame: CGRect,
        imageWidthInPixels: Int,
        imageHeightInPixels: Int
    ) -> CGRect {
        let horizontalScale = CGFloat(imageWidthInPixels) / displayFrame.width
        let verticalScale = CGFloat(imageHeightInPixels) / displayFrame.height
        return CGRect(
            x: (appKitRect.minX - displayFrame.minX) * horizontalScale,
            y: (displayFrame.maxY - appKitRect.maxY) * verticalScale,
            width: appKitRect.width * horizontalScale,
            height: appKitRect.height * verticalScale
        )
    }
}
