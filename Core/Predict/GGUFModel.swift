import Foundation

/// A local GGUF model, reached through a `llama-server` process the app manages.
///
/// A subprocess rather than a linked library, deliberately. Rule 2 says the model
/// is a commodity: keeping it behind a process boundary means the app has no
/// build-time dependency on any inference stack, any GGUF the user points at
/// works, a wedged model cannot take the app down with it, and swapping models is
/// killing one process and starting another. Embedding llama.cpp would trade all
/// of that for a few milliseconds.
///
/// If `llama-server` is not installed, every method degrades to "no suggestions"
/// and the app runs on memory alone — which rule 2 requires anyway.
/// Where a model's weights come from.
///
/// `huggingFace` hands the job to llama.cpp's own `-hf` downloader rather than
/// fetching the file here. That is not laziness: the hand-rolled download saved
/// *any* HTTP response as a .gguf, so an auth error became a 29-byte file the app
/// then reported as an installed model. llama.cpp resolves the repo, picks the
/// quant, verifies, and caches — and it is the same code path its own users
/// exercise daily.
public enum ModelSource: Equatable {
    case local(path: String)
    case huggingFace(repo: String, file: String)
}

public final class GGUFModel: SuggestionSource {
    public let name: String
    public let source: ModelSource

    /// Why the last `start()` failed, for surfacing to the user instead of
    /// silently degrading to memory-only and leaving a tick beside a dead model.
    public private(set) var lastError: String?

    /// Tokens to ask for. A next-word suggestion needs very few, and each one is
    /// latency the user feels while typing. Measured on Qwen3-0.6B-Q8_0: about
    /// 8ms per token, so eight tokens lands near 65ms.
    private static let tokensToPredict = 8

    /// Hard ceiling on a single request.
    ///
    /// Measured, not guessed: eight tokens takes 48-69ms on an M-series Mac, plus
    /// prompt processing. The previous 120ms ceiling was under the real cost, so
    /// every model suggestion was abandoned in flight — the model appeared to work
    /// and never produced a single visible result.
    private static let requestTimeout: TimeInterval = 0.30

    private let port: Int
    private var process: Process?
    private let session: URLSession

    public init(name: String, source: ModelSource, port: Int = 8177) {
        self.name = name
        self.source = source
        self.port = port

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = GGUFModel.requestTimeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    deinit {
        stop()
    }

    // MARK: - Availability

    /// Where `llama-server` lives, if it is installed at all.
    public static func serverBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/llama-server",
            "/usr/local/bin/llama-server",
            "/opt/homebrew/opt/llama.cpp/bin/llama-server"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var isRuntimeAvailable: Bool { serverBinary() != nil }

    /// True when a llama-server we did not spawn is already serving this port.
    private var isAttached = false

    public var isRunning: Bool { process?.isRunning ?? isAttached }

    /// Attaches to a llama-server already listening on this port instead of
    /// spawning one. Lets the doctor exercise the real suggestion path against a
    /// running model without starting a second copy.
    @discardableResult
    public func attach() -> Bool {
        isAttached = health()
        return isAttached
    }

    // MARK: - Lifecycle

    /// Verifies that a file really is a GGUF before trusting it.
    ///
    /// Four magic bytes. Checking them is what turns "the download produced a
    /// file" into "the download produced a model" — the distinction that let an
    /// HTML error page masquerade as Qwen.
    public static func isValidGGUF(path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }
        return magic == Data("GGUF".utf8)
    }

    @discardableResult
    public func start() -> Bool {
        guard process == nil else { return true }
        guard let binary = GGUFModel.serverBinary() else {
            lastError = "llama-server is not installed. Try: brew install llama.cpp"
            return false
        }

        var modelArguments: [String]
        switch source {
        case .local(let path):
            guard FileManager.default.fileExists(atPath: path) else {
                lastError = "No file at \(path)"
                return false
            }
            guard GGUFModel.isValidGGUF(path: path) else {
                lastError = "\(URL(fileURLWithPath: path).lastPathComponent) is not a GGUF file "
                    + "(missing the GGUF header). It may be a partial or failed download."
                return false
            }
            modelArguments = ["--model", path]

        case .huggingFace(let repo, let file):
            // llama.cpp downloads and caches this itself on first run.
            modelArguments = ["-hf", repo, "-hff", file]
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = modelArguments + [
            "--port", String(port),
            "--host", "127.0.0.1",
            // Small context: this only ever sees the tail of a sentence, and a
            // large one would cost memory and prefill time for nothing.
            "--ctx-size", "512",
            "--threads", "4",
            // No web UI, no logging noise on the keystroke path.
            "--no-webui",
            "--log-disable"
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            lastError = "Could not launch llama-server: \(error)"
            return false
        }
        process = task

        // A first run from Hugging Face downloads several hundred megabytes, so
        // it gets a far longer budget than a local file that is merely being
        // memory-mapped.
        let budget: TimeInterval = {
            if case .huggingFace = source { return 900 }
            return 60
        }()

        if waitUntilReady(timeout: budget) {
            lastError = nil
            return true
        }
        lastError = "llama-server started but never became ready within \(Int(budget))s."
        stop()
        return false
    }

    public func stop() {
        process?.terminate()
        process = nil
        isAttached = false
    }

    /// Polls the health endpoint until the model finishes loading. A cold start
    /// reads hundreds of megabytes from disk, so this is seconds, not milliseconds
    /// — which is exactly why it happens at swap time and never on a keystroke.
    private func waitUntilReady(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if health() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private func health() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5

        var healthy = false
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, response, _ in
            healthy = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1.0)
        return healthy
    }

    // MARK: - Suggesting

    public func suggest(_ context: TypingContext) -> [Candidate] {
        guard isRunning else { return [] }
        guard !context.textBeforeCaret.isEmpty else { return [] }

        // Mid-word is handled by *removing* the partial word from the prompt and
        // filtering the answer, rather than by asking the model to continue from
        // the middle of a token — which is what made it return Portuguese for
        // "recei" and Python for "attach".
        //
        // This is what makes completion grammatical. The dictionary can only see
        // "conside" and picks by frequency; the model sees "I will conside" and
        // knows the word is "consider", not "considering".
        let partial = context.currentWordPrefix

        // Trailing whitespace has to go. BPE tokenizers attach a leading space to
        // the *following* token, so a prompt ending in a space leaves the model
        // between tokens and the output degenerates — "Please find attached the "
        // returns "2023-202" where "Please find attached the" returns " data set".
        // The caller then re-adds the separator, because the suggestion still has
        // to start with one.
        var prompt = context.textBeforeCaret
        if !partial.isEmpty {
            // Drop the half-typed word so the model is asked a question it can
            // answer: "what word comes next", not "finish this token".
            prompt = String(prompt.dropLast(partial.count))
        }
        prompt = prompt.replacingOccurrences(
            of: "\\s+$", with: "", options: .regularExpression)
        guard !prompt.isEmpty else { return [] }

        // Raw continuation, not a chat template. The model is being used as a
        // language model, not an assistant: it should continue the sentence, not
        // answer it.
        let body: [String: Any] = [
            "prompt": prompt,
            "n_predict": GGUFModel.tokensToPredict,
            "temperature": 0.0,
            "cache_prompt": true,
            "stop": ["\n", ".", "!", "?"]
        ]

        guard let url = URL(string: "http://127.0.0.1:\(port)/completion"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = GGUFModel.requestTimeout

        var completion: String?
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            completion = object["content"] as? String
        }.resume()
        _ = semaphore.wait(timeout: .now() + GGUFModel.requestTimeout + 0.05)

        guard let completion else { return [] }
        if !partial.isEmpty {
            return GGUFModel.wordCompletion(from: completion, matching: partial)
        }
        return GGUFModel.candidates(from: completion, context: context)
    }

    /// Keeps the model's answer only if it actually continues the word the user
    /// started, and returns the remaining characters.
    ///
    /// The prefix is the constraint that makes a small model safe to use here: it
    /// cannot wander, because anything that does not start with what was already
    /// typed is discarded. What survives is a completion that is both grammatical
    /// *and* the word being typed — which is exactly what the dictionary alone
    /// cannot give.
    static func wordCompletion(from completion: String, matching prefix: String) -> [Candidate] {
        let words = completion
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
        guard let first = words.first else { return [] }

        // Trailing punctuation is the model's, not part of the word.
        let word = String(first).trimmingCharacters(in: CharacterSet.punctuationCharacters)
        guard word.count > prefix.count,
              word.lowercased().hasPrefix(prefix.lowercased()),
              word.allSatisfy({ $0.isLetter || $0 == "'" }) else { return [] }

        // High confidence: the model chose this word knowing the sentence, and it
        // agrees with what the user has already typed. That is far stronger
        // evidence than a frequency-ranked dictionary guess.
        return [Candidate(text: String(word.dropFirst(prefix.count)),
                          probability: 0.7,
                          origin: .model)]
    }

    /// Rejects continuations that are grammatically or contextually wrong,
    /// whatever their probability under the model.
    ///
    /// A 0.6B model asked to continue arbitrary text drifts: it answers English
    /// prompts in Portuguese, turns "attach" into a Python snippet, and echoes the
    /// prompt back. Those are not low-confidence guesses that ranking will sort
    /// out — they are wrong in kind, and no amount of expected-savings arithmetic
    /// makes them worth showing.
    static func isPlausible(_ completion: String, following prompt: String) -> Bool {
        // Script drift. If the user is writing Latin script, a completion in
        // another writing system is the model losing the thread, not a suggestion.
        let promptIsLatin = prompt.unicodeScalars.contains { CharacterSet.letters.contains($0) }
            && !prompt.unicodeScalars.contains { $0.value > 0x0590 }
        if promptIsLatin, completion.unicodeScalars.contains(where: { $0.value > 0x0590 }) {
            return false
        }

        // Code, unless the surrounding text already looks like code. "attach"
        // returned `Question = input("Enter the` — fluent, and completely wrong
        // for someone writing a message.
        let codeMarkers = CharacterSet(charactersIn: "={}[]<>|\\$#@`")
        let promptHasCode = prompt.unicodeScalars.contains { codeMarkers.contains($0) }
        let completionHasCode = completion.unicodeScalars.contains { codeMarkers.contains($0) }
        if completionHasCode, !promptHasCode { return false }

        // Echoing the prompt back. Common when the model has nothing to add, and
        // it reads as a stutter: "kaise ho" → "jou, kaise hojou".
        let tail = prompt.lowercased().split(separator: " ").suffix(3).joined(separator: " ")
        if !tail.isEmpty, completion.lowercased().contains(tail) { return false }

        // A completion made only of punctuation or digits saves nothing worth
        // interrupting for.
        guard completion.contains(where: { $0.isLetter }) else { return false }

        return true
    }

    /// Turns raw continuation text into candidates.
    ///
    /// Two shapes are offered — the next word alone, and a short phrase — so the
    /// ranker can weigh a safe small win against a larger speculative one rather
    /// than being handed a single take-it-or-leave-it string.
    public static func candidates(from completion: String, context: TypingContext) -> [Candidate] {
        let cleaned = completion
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return [] }
        guard isPlausible(cleaned, following: context.textBeforeCaret) else { return [] }

        // Mid-word, the model is finishing the token the user started; after a
        // separator it is starting a new one and needs its own trailing space.
        let isMidWord = !context.currentWordPrefix.isEmpty
        var results: [Candidate] = []

        let words = cleaned.split(separator: " ").map(String.init)
        guard let first = words.first else { return [] }

        let firstText = isMidWord ? first : first + " "
        results.append(Candidate(text: firstText, probability: 0.45, origin: .model))

        if words.count >= 3 {
            let phrase = words.prefix(4).joined(separator: " ")
            let phraseText = isMidWord ? phrase : phrase + " "
            // Lower confidence: more of it has to be right for the user to take it.
            results.append(Candidate(text: phraseText, probability: 0.22, origin: .model))
        }

        return results
    }
}
