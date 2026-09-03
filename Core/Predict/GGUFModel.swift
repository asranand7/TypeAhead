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
    /// Tokens generated per keystroke.
    ///
    /// One, and the number is measured rather than chosen. On an M5 with the
    /// prompt cache warm, a single token comes back in 13.6ms median / 20.6ms
    /// p90 against a 40ms debounce; two costs 27ms median and 41ms p90, and
    /// three costs 38ms / 53ms — past the budget, at which point the Coordinator
    /// drops the result as stale and the work was wasted.
    ///
    /// It was 8, which measured at 72ms and was hidden by a 300ms timeout: the
    /// model tier was three times over budget for as long as it existed, and
    /// since it was also off by default nobody ever saw it miss.
    ///
    /// One token is enough because Qwen3's tokenizer is close to word-level for
    /// common English — across a sample of realistic prefixes the first token was
    /// a complete word 8 times out of 8. Multi-word value comes from the snippet
    /// tier, which recalls phrases verbatim and costs nothing to generate.
    private static let tokensToPredict = 1

    /// How many alternatives to ask for alongside the chosen token.
    ///
    /// This is what turns the model from a source of one guess into a
    /// distribution, which is what `Fusion` needs: interpolating a personal
    /// n-gram against a global model requires the model's probability for *the
    /// n-gram's* candidates, not just for its own favourite. Free — the
    /// probabilities are already computed to sample the token at all.
    static let alternativesToRequest = 10

    /// Hard ceiling on a single request.
    ///
    /// Measured, not guessed: eight tokens takes 48-69ms on an M-series Mac, plus
    /// prompt processing. The previous 120ms ceiling was under the real cost, so
    /// every model suggestion was abandoned in flight — the model appeared to work
    /// and never produced a single visible result.
    /// Measured p90 is 20.6ms, so this is a stall detector, not a budget.
    ///
    /// Was 300ms, which is long enough to hold the prediction queue through four
    /// more keystrokes and guarantee the answer is discarded as stale when it
    /// finally lands. Failing fast and showing nothing is the better trade.
    private static let requestTimeout: TimeInterval = 0.08

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

        guard let prompt = GGUFModel.prompt(for: context) else { return [] }

        guard let answer = complete(prompt: prompt) else { return [] }
        let completion = answer.content

        if !partial.isEmpty {
            return GGUFModel.wordCompletion(from: completion, matching: partial)
        }
        return GGUFModel.candidates(from: completion, context: context)
    }

    /// The model's answer for one prompt: the text it chose, and the alternatives
    /// it considered.
    ///
    /// One round trip serves both jobs. `suggest` wants the chosen token;
    /// `Fusion` wants the whole distribution so it can look up what the model
    /// thought of a word the *n-gram* proposed. Asking twice would double the
    /// latency for a number that was already computed.
    struct Answer {
        let content: String
        /// Next-token probabilities, keyed by the token's text with its leading
        /// space stripped and case folded — the form personal memory stores words
        /// in, so the two can be compared without either side knowing about the
        /// other's tokenizer.
        let distribution: [String: Double]
    }

    func complete(prompt: String) -> Answer? {
        // Raw continuation, not a chat template. The model is being used as a
        // language model, not an assistant: it should continue the sentence, not
        // answer it.
        let body: [String: Any] = [
            "prompt": prompt,
            "n_predict": GGUFModel.tokensToPredict,
            "temperature": 0.0,
            // Reuses the KV cache across keystrokes, so a prompt that grew by one
            // word costs one token of prefill rather than two hundred. Measured:
            // 183ms cold against 13.6ms warm. Without it nothing here fits.
            "cache_prompt": true,
            "n_probs": GGUFModel.alternativesToRequest,
            "stop": ["\n", ".", "!", "?"]
        ]

        guard let url = URL(string: "http://127.0.0.1:\(port)/completion"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload
        request.timeoutInterval = GGUFModel.requestTimeout

        var answer: Answer?
        let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, _, _ in
            defer { semaphore.signal() }
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = object["content"] as? String else { return }
            answer = Answer(content: content,
                            distribution: GGUFModel.distribution(from: object))
        }.resume()
        _ = semaphore.wait(timeout: .now() + GGUFModel.requestTimeout + 0.05)
        return answer
    }

    /// Pulls the next-token distribution out of a llama.cpp completion response.
    ///
    /// Only the *first* generated position is read. Later positions are
    /// conditioned on tokens the user has not accepted and may never see, so
    /// their probabilities do not describe any decision being made now.
    ///
    /// Tokens are folded to the form personal memory uses — leading space
    /// stripped, lower-cased — and probabilities for tokens that fold together
    /// are summed, because "The" and "the" are one word as far as the ranking is
    /// concerned even though the tokenizer keeps them apart.
    static func distribution(from object: [String: Any]) -> [String: Double] {
        let positions = object["completion_probabilities"] as? [[String: Any]]
        guard let first = positions?.first else { return [:] }

        // llama.cpp has spelled this three ways across versions, and the current
        // one reports log probabilities rather than probabilities. Reading only
        // the shape that happened to be current when this was written is how a
        // fusion silently degrades to memory-only after a `brew upgrade` — which
        // is exactly what it did: the distribution parsed empty, `Fusion` took
        // its no-model fallback, and every measurement came out identical to the
        // unfused baseline with no error anywhere.
        let entries = (first["top_logprobs"] as? [[String: Any]])
            ?? (first["probs"] as? [[String: Any]])
            ?? (first["top_probs"] as? [[String: Any]])
            ?? []

        var out: [String: Double] = [:]
        for entry in entries {
            guard let raw = (entry["token"] as? String) ?? (entry["tok_str"] as? String)
            else { continue }

            let probability: Double
            if let p = (entry["prob"] as? Double) ?? (entry["p"] as? Double) {
                probability = p
            } else if let logprob = entry["logprob"] as? Double {
                probability = exp(logprob)
            } else {
                continue
            }
            guard probability > 0 else { continue }

            // A token with no leading space continues the word already being
            // generated rather than starting the next one. Only word-initial
            // tokens answer "what comes next", which is the question being asked.
            guard raw.hasPrefix(" ") else { continue }

            let word = PersonalModel.normalize(raw)
            // A token that folds to nothing is punctuation or whitespace: real
            // signal about what comes next, but not a word anyone can be offered.
            guard !word.isEmpty, word.allSatisfy({ $0.isLetter || $0 == "'" }) else { continue }
            out[word, default: 0] += probability
        }
        return out
    }

    /// The prompt for a context: the surrounding fields, then everything before
    /// the caret, with a half-typed word removed and trailing whitespace trimmed.
    ///
    /// Shared with `Fusion` so both ask the model the same question. A prompt
    /// that ends in a space leaves a BPE tokenizer between tokens and the output
    /// degenerates — "Please find attached the " returns "2023-202" where the
    /// same text without the space returns " data set".
    ///
    /// Ambient fields are prepended as plain labelled lines rather than encoded
    /// some cleverer way, because a base language model reads them as what they
    /// are: a header above a message. It is the achievable version of what Smart
    /// Compose did with averaged field embeddings, and it costs only prefill —
    /// which the KV cache pays once and then reuses for the rest of the message.
    public static func prompt(for context: TypingContext) -> String? {
        var prompt = context.textBeforeCaret
        let partial = context.currentWordPrefix
        if !partial.isEmpty { prompt = String(prompt.dropLast(partial.count)) }
        prompt = prompt.replacingOccurrences(
            of: "\\s+$", with: "", options: .regularExpression)
        guard !prompt.isEmpty else { return nil }

        guard !context.ambientContext.isEmpty else { return prompt }
        // The header goes first and stays byte-identical while the user types, so
        // it sits at the front of the cached prefix and is prefilled once.
        let header = context.ambientContext
            .map { "\($0.label): \($0.value)" }
            .joined(separator: "\n")
        return header + "\n\n" + prompt
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
