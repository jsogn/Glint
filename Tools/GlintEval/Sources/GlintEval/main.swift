import GlintCore
import GlintDictionary
import GlintInference

@main
struct GlintEval {
    static func main() async throws {
        let dictionary = DictionaryRouter(routes: [
            DictionaryRoute(
                id: "dict-cedict",
                priority: 0,
                role: .authoritative,
                engine: CedictDictionary()
            ),
            DictionaryRoute(
                id: "dict-ecdict",
                priority: 1,
                role: .fallback,
                engine: ECDICTDictionary()
            ),
        ])
        for word in ["你好", "算法", "计算", "复盘", "中国", "苹果", "打", "计算机", "程序", "开发", "设计", "数据", "内卷", "躺平"] {
            let result = await dictionary.lookup(
                Candidate(text: word, kind: .word)
            )
            print("\(word) -> \(result?.text ?? "<not found>")")
        }
        if let engine = CTranslate2Engine() {
            let sentence = Candidate(text: "今天天气不错", kind: .sentence)
            let result = try await engine.translate(sentence)
            print("今天天气不错 -> \(result?.text ?? "<not found>")")
        } else {
            print("CTranslate2 engine unavailable")
        }
    }
}
