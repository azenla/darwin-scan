import Foundation

nonisolated enum MLModelInspector {
    /// Detect ML model containers by extension and, where possible, peek inside
    /// to extract author / description / IO shapes.
    static func inspect(url: URL) -> MLModelInfo? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mlmodel":     return inspectMLModelFile(url)
        case "mlpackage":   return inspectMLPackage(url)
        case "mlmodelc":    return inspectCompiledMLModel(url)
        case "onnx":        return MLModelInfo(container: .onnx, modelDescription: nil, author: nil, license: nil, modelType: nil, inputs: [], outputs: [], classLabelsCount: nil, inferredPurpose: nil)
        case "tflite":      return MLModelInfo(container: .tflite, modelDescription: nil, author: nil, license: nil, modelType: nil, inputs: [], outputs: [], classLabelsCount: nil, inferredPurpose: nil)
        case "pt", "pth":   return MLModelInfo(container: .pytorch, modelDescription: nil, author: nil, license: nil, modelType: nil, inputs: [], outputs: [], classLabelsCount: nil, inferredPurpose: nil)
        default: return nil
        }
    }

    /// Source `.mlmodel` files are Protocol Buffer encoded. We don't parse the
    /// proto here — that would add a heavy dep — but we still mark the file
    /// and try to pluck description bytes via simple textual search.
    private static func inspectMLModelFile(_ url: URL) -> MLModelInfo? {
        var info = MLModelInfo(
            container: .mlmodel,
            modelDescription: nil,
            author: nil,
            license: nil,
            modelType: nil,
            inputs: [],
            outputs: [],
            classLabelsCount: nil,
            inferredPurpose: nil
        )
        if let head = try? FileHandle(forReadingFrom: url).read(upToCount: 32 * 1024),
           let text = String(data: head, encoding: .utf8) {
            info.modelDescription = grepFirstHumanLine(in: text)
        }
        return info
    }

    /// `.mlpackage` is a directory bundle containing a Manifest.json + a
    /// Data subdirectory with the binary protobuf. The manifest is the easy
    /// metadata source.
    private static func inspectMLPackage(_ url: URL) -> MLModelInfo? {
        let manifestURL = url.appendingPathComponent("Manifest.json")
        var info = MLModelInfo(
            container: .mlpackage,
            modelDescription: nil,
            author: nil,
            license: nil,
            modelType: nil,
            inputs: [],
            outputs: [],
            classLabelsCount: nil,
            inferredPurpose: nil
        )
        if let data = try? Data(contentsOf: manifestURL),
           let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            info.author      = obj["rootModelIdentifier"] as? String
            if let items = obj["itemInfoEntries"] as? [String: Any] {
                info.inputs = items.keys.sorted()
            }
        }
        return info
    }

    /// `.mlmodelc` is the compiled form — what an Xcode build emits. Has a
    /// `model.espresso.shape` and a `metadata.json` describing IO and labels.
    private static func inspectCompiledMLModel(_ url: URL) -> MLModelInfo? {
        var info = MLModelInfo(
            container: .mlmodelc,
            modelDescription: nil,
            author: nil,
            license: nil,
            modelType: nil,
            inputs: [],
            outputs: [],
            classLabelsCount: nil,
            inferredPurpose: nil
        )
        let metaURL = url.appendingPathComponent("metadata.json")
        if let data = try? Data(contentsOf: metaURL),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let dict  = array.first {
            info.modelDescription = (dict["shortDescription"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            info.author    = (dict["author"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            info.license   = (dict["license"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            info.modelType = (dict["modelType"] as? String)
            if let inputs = dict["inputSchema"] as? [[String: Any]] {
                info.inputs = inputs.compactMap { $0["name"] as? String }
            }
            if let outputs = dict["outputSchema"] as? [[String: Any]] {
                info.outputs = outputs.compactMap { $0["name"] as? String }
            }
            if let metadataSpec = dict["userDefinedMetadata"] as? [String: Any],
               let purpose = metadataSpec["purpose"] as? String {
                info.inferredPurpose = purpose
            }
        }
        // Class labels file is a plain newline-delimited list when present.
        let labelsURL = url.appendingPathComponent("classlabel_to_index.json")
        if let data = try? Data(contentsOf: labelsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            info.classLabelsCount = obj.count
        }
        return info
    }

    /// Pulls out the first line of plausibly-human text from a head buffer of
    /// an `.mlmodel` (which is protobuf bytes with description strings interspersed).
    private static func grepFirstHumanLine(in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .controlCharacters)
            if trimmed.count > 8 && trimmed.count < 200 {
                let asciiCount = trimmed.unicodeScalars.filter { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7f }.count
                if asciiCount > trimmed.count - 4 {
                    return trimmed
                }
            }
        }
        return nil
    }
}
