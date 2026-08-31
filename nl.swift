import NaturalLanguage
import Foundation

let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])

func pos(_ sentence: String) -> [(String, String)] {
    tagger.string = sentence
    var out: [(String, String)] = []
    tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex,
                         unit: .word, scheme: .lexicalClass,
                         options: [.omitWhitespace, .omitPunctuation]) { tag, range in
        out.append((String(sentence[range]), tag?.rawValue ?? "?"))
        return true
    }
    return out
}

print("=== part of speech ===")
for s in ["I will consider the offer", "I am considering the offer",
          "the recommendation is clear", "I recommend this"] {
    print("  \(s)")
    print("    \(pos(s).map { "\($0.0)/\($0.1)" }.joined(separator: " "))")
}

print("\n=== lemma (base form) ===")
let lem = NLTagger(tagSchemes: [.lemma])
for w in ["considering", "considered", "recommendation", "appreciated"] {
    lem.string = w
    let t = lem.tag(at: w.startIndex, unit: .word, scheme: .lemma).0
    print("  \(w) → \(t?.rawValue ?? "?")")
}

print("\n=== latency ===")
var times: [Double] = []
for _ in 0..<20 {
    let t0 = DispatchTime.now()
    _ = pos("I will consider the offer carefully today")
    times.append(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds)/1_000_000)
}
times.sort()
print(String(format: "  p50 %.2fms  max %.2fms", times[times.count/2], times.last!))
