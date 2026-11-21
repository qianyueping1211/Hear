import Foundation

/// The conversation chooses a route. Engine adapters own the invocation details.
enum SessionSpeechEngine {
    case cloud(CloudClient)
    case senseVoice(SenseVoiceRecognizer)
    case whisper(SpeechRecognizer)

    func recognize(_ samples: [Float], candidates: [String], fallback: String, preview: Bool = false)
        async throws -> (lang: String, text: String, correctionAddress: String?) {
        try Task.checkCancellation()
        switch self {
        case .cloud(let client):
            if preview {
                let (lang, text) = try await client.transcribePreview(
                    samples: samples, candidates: candidates, fallback: fallback)
                return (lang, text, nil)
            }
            return try await client.transcribe(samples: samples, candidates: candidates, fallback: fallback)
        case .senseVoice(let recognizer):
            let (lang, text) = try await recognizer.recognize(samples, candidates: candidates, fallback: fallback)
            return (lang, text, nil)
        case .whisper(let recognizer):
            let (lang, text) = try await recognizer.recognize(
                samples, candidates: candidates, fallback: fallback, preview: preview)
            return (lang, text, nil)
        }
    }
}

enum SessionTextEngine {
    case system(SystemTranslator)
    case cloud(CloudClient)
    case local(LlamaTranslator)

    func translate(text: String, source: Language, target: Language,
                   context: [String], glossary: String,
                   onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        try Task.checkCancellation()
        func prompt() -> String {
            PromptBuilder.build(text: text, from: source, to: target, context: context,
                                glossary: PromptBuilder.parseGlossary(glossary))
        }
        switch self {
        case .system(let engine):
            return try await engine.translate(text, from: source, to: target)
        case .cloud(let engine):
            return try await engine.translate(prompt: prompt(), src: source.id, dst: target.id)
        case .local(let engine):
            return try await engine.translate(prompt: prompt(), onUpdate: onPartial)
        }
    }
}
