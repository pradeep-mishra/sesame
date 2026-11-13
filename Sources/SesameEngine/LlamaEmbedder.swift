import CLlama
import Foundation

/// EmbeddingGemma 2 on llama.cpp (Metal), text model only: the text goes in as `<bos> prompt <eos>`, the model's
/// mean-pooled output is scaled to length 1. Cut down to what `encode` needs.
///
/// Making one loads nothing; `load()` loads the model, `unload()` frees it. One thread at a time.
public final class LlamaEmbedder: Embedder {
    /// Changes only when the vectors do (model files, llama.cpp, prompts); every index embeds again then.
    static let vectorVersion = 1

    /// The `meta.vector_source` text: the two file names, the revision and the vector version.
    /// Known without a model and the same on every read.
    public static var vectorSource: String {
        (ModelFiles.all.map(\.name) + [ModelFiles.revision, "v\(vectorVersion)"]).joined(separator: "|")
    }

    /// One input must fit one micro-batch: 2048 tokens, the reference's cut.
    private static let maxTokens = 2048

    private let textModel: URL
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var batch: OpaquePointer?
    private var vocab: OpaquePointer?
    private var embeddingSize = 0

    public init(textModel: URL) {
        self.textModel = textModel
    }

    deinit { unload() }

    public var isLoaded: Bool { model != nil }

    public func load() throws {
        guard !isLoaded else { return }
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let model = llama_model_load_from_file(textModel.path, modelParams) else {
            throw LlamaEmbedderError.failed("can't load \(textModel.path)")
        }
        var params = llama_context_default_params()
        params.n_ctx = UInt32(Self.maxTokens)
        params.n_batch = UInt32(Self.maxTokens)
        params.n_ubatch = UInt32(Self.maxTokens)
        params.n_seq_max = 1
        params.kv_unified = true
        params.embeddings = true
        params.pooling_type = LLAMA_POOLING_TYPE_MEAN
        guard let context = llama_init_from_model(model, params) else {
            llama_model_free(model)
            throw LlamaEmbedderError.failed("can't create a llama.cpp context")
        }
        self.model = model
        self.context = context
        batch = llama_batch_ext_init(context)
        vocab = llama_model_get_vocab(model)
        embeddingSize = Int(llama_model_n_embd_out(model))
    }

    public func unload() {
        if let batch { llama_batch_ext_free(batch) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        (batch, context, model, vocab) = (nil, nil, nil, nil)
    }

    // MARK: Embedder

    public func embed(_ text: String, role: EmbedRole) throws -> [Float] {
        guard isLoaded else { throw LlamaEmbedderError.notLoaded }
        let prompt: String
        switch role {
        case .query: prompt = "task: search result | query: \(text)"
        case .document: prompt = "title: none | text: \(text)"
        }
        let tokens = tokenize(prompt)
        llama_batch_ext_clear(batch)
        defer { llama_batch_ext_clear(batch) }
        for (position, token) in tokens.enumerated() {
            let index = llama_batch_ext_add_token(batch, 0, token)
            var pos: [llama_pos] = [llama_pos(position), 0, 0, 0]
            guard index >= 0, llama_batch_ext_set_pos(batch, index, &pos),
                  llama_batch_ext_set_output_embd(batch, index, true) else {
                throw LlamaEmbedderError.failed("can't place token \(position)")
            }
        }
        let status = llama_process(context, LLAMA_PROCESS_TYPE_ENCODE, batch)
        guard status == 0 else { throw LlamaEmbedderError.failed("llama_process failed (\(status))") }
        guard let pooled = llama_get_embeddings_seq(context, 0) else {
            throw LlamaEmbedderError.failed("no pooled embedding")
        }
        var sum = 0.0
        for i in 0..<embeddingSize { sum += Double(pooled[i]) * Double(pooled[i]) }
        let scale = sum > 0 ? Float(1 / sum.squareRoot()) : 0
        return (0..<embeddingSize).map { pooled[$0] * scale }
    }

    /// `<bos> text <eos>`, cut to `maxTokens` the way transformers cuts (keeping both special tokens).
    private func tokenize(_ text: String) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        var count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &tokens, Int32(tokens.count), true, true)
        }
        tokens.removeLast(tokens.count - Int(max(count, 0)))
        if tokens.count > Self.maxTokens {
            tokens = Array(tokens[0..<(Self.maxTokens - 1)]) + [llama_vocab_eos(vocab)]
        }
        return tokens
    }

    /// llama.cpp's process-wide setup, once; only warnings and errors are printed (it logs a lot at load time).
    private static let backend: Void = {
        llama_log_set({ level, text, _ in
            guard let text, level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue else { return }
            FileHandle.standardError.write(Data(String(cString: text).utf8))
        }, nil)
        llama_backend_init()
    }()
}

public enum LlamaEmbedderError: Error, Equatable {
    case notLoaded
    case failed(String)
}
