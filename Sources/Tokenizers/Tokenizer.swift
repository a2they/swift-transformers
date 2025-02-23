//
//  Tokenizer.swift
//
//
//  Created by Pedro Cuenca on 6/5/23.
//

import Hub
import Foundation
import Jinja

enum TokenizerError : Error {
    case missingConfig
    case missingTokenizerClassInConfig
    case unsupportedTokenizer(String)
    case missingVocab
    case malformedVocab

    case tooLong(String)
}

public protocol TokenizingModel {
    func tokenize(text: String) -> [String]

    // Alias for `tokenize`
    func callAsFunction(_ text: String) -> [String]

    func convertTokenToId(_ token: String) -> Int?
    func convertTokensToIds(_ tokens: [String]) -> [Int?]

    func convertIdToToken(_ id: Int) -> String?
    func convertIdsToTokens(_ ids: [Int]) -> [String?]

    var bosToken: String? { get }
    var bosTokenId: Int? { get }
    var eosToken: String? { get }
    var eosTokenId: Int? { get }
    var unknownToken: String? { get }
    var unknownTokenId: Int? { get }

    var fuseUnknownTokens: Bool { get }
}

public extension TokenizingModel {
    func callAsFunction(_ text: String) -> [String] {
        tokenize(text: text)
    }

    func convertTokensToIds(_ tokens: [String]) -> [Int?] {
        return tokens.map { convertTokenToId($0) }
    }

    func convertIdsToTokens(_ ids: [Int]) -> [String?] {
        return ids.map { convertIdToToken($0) }
    }
}

/// A tokenizer model that is set up with Hub configuration data
public protocol PreTrainedTokenizerModel: TokenizingModel {
    init(tokenizerConfig: Config, tokenizerData: Config, addedTokens: [String : Int]) throws
}

struct TokenizerModel {
    static let knownTokenizers: [String : PreTrainedTokenizerModel.Type] = [
        "BertTokenizer"      : BertTokenizer.self,
        "CodeGenTokenizer"   : CodeGenTokenizer.self,
        "CodeLlamaTokenizer" : CodeLlamaTokenizer.self,
        "FalconTokenizer"    : FalconTokenizer.self,
        "GemmaTokenizer"     : GemmaTokenizer.self,
        "GPT2Tokenizer"      : GPT2Tokenizer.self,
        "LlamaTokenizer"     : LlamaTokenizer.self,
        "T5Tokenizer"        : T5Tokenizer.self,
        "WhisperTokenizer"   : WhisperTokenizer.self,
        "CohereTokenizer"    : CohereTokenizer.self,
        "PreTrainedTokenizer": BPETokenizer.self
    ]

    static func unknownToken(from tokenizerConfig: Config) -> String? {
        return tokenizerConfig.unkToken?.content?.stringValue ?? tokenizerConfig.unkToken?.stringValue
    }

    public static func from(tokenizerConfig: Config, tokenizerData: Config, addedTokens: [String : Int]) throws -> TokenizingModel {
        guard let tokenizerClassName = tokenizerConfig.tokenizerClass?.stringValue else {
            throw TokenizerError.missingTokenizerClassInConfig
        }

        // Some tokenizer_class entries use a Fast suffix
        let tokenizerName = tokenizerClassName.replacingOccurrences(of: "Fast", with: "")
        guard let tokenizerClass = TokenizerModel.knownTokenizers[tokenizerName] else {
            throw TokenizerError.unsupportedTokenizer(tokenizerName)
        }

        return try tokenizerClass.init(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData, addedTokens: addedTokens)
    }
}

public protocol Tokenizer {
    func tokenize(text: String) -> [String]

    /// Main entry point
    func encode(text: String) -> [Int]
    func encode(text: String, addSpecialTokens: Bool) -> [Int]
    func callAsFunction(_ text: String, addSpecialTokens: Bool) -> [Int]

    /// Decode
    func decode(tokens: [Int]) -> String

    func convertTokenToId(_ token: String) -> Int?
    func convertTokensToIds(_ tokens: [String]) -> [Int?]

    func convertIdToToken(_ id: Int) -> String?
    func convertIdsToTokens(_ ids: [Int]) -> [String?]

    var bosToken: String? { get }
    var bosTokenId: Int? { get }
    var eosToken: String? { get }
    var eosTokenId: Int? { get }
    var unknownToken: String? { get }
    var unknownTokenId: Int? { get }
    
    func applyChatTemplate(messages: [[String: String]]) throws -> [Int]
    
    func applyChatTemplate(
        messages: [[String: String]],
        chatTemplate: String?,
        addGenerationPrompt: Bool,
        truncation: Bool,
        maxLength: Int?
    ) throws -> [Int]
}

public extension Tokenizer {
    func callAsFunction(_ text: String, addSpecialTokens: Bool = true) -> [Int] {
        encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func convertTokensToIds(_ tokens: [String]) -> [Int?] {
        return tokens.map { convertTokenToId($0) }
    }

    func convertIdsToTokens(_ ids: [Int]) -> [String?] {
        return ids.map { convertIdToToken($0) }
    }
}

let specialTokenAttributes: [String] = [
    "bos_token",
    "eos_token",
    "unk_token",
    "sep_token",
    "pad_token",
    "cls_token",
    "mask_token",
    "additional_special_tokens"
]

public class PreTrainedTokenizer: Tokenizer {
    let model: TokenizingModel

    public var bosToken: String? { model.bosToken }
    public var bosTokenId: Int? { model.bosTokenId }
    public var eosToken: String? { model.eosToken }
    public var eosTokenId: Int? { model.eosTokenId }
    public var unknownToken: String? { model.unknownToken }
    public var unknownTokenId: Int? { model.unknownTokenId }
    public var fuseUnknownTokens: Bool { model.fuseUnknownTokens }

    private let addedTokens: Set<String>
    private let specialTokens: [String: Int]
    private let addedTokensRegex: NSRegularExpression?

    private let preTokenizer: PreTokenizer?
    private let normalizer: Normalizer?
    private let postProcessor: PostProcessor?
    private let decoder: Decoder?
    private let tokenizerConfig: Config

    private let cleanUpTokenizationSpaces: Bool
    
    private let defaultChatTemplate: String = "{% for message in messages %}{{'<|im_start|>' + message['role'] + '\n' + message['content'] + '<|im_end|>' + '\n'}}{% endfor %}{% if add_generation_prompt %}{{ '<|im_start|>assistant\n' }}{% endif %}"

    required public init(tokenizerConfig: Config, tokenizerData: Config) throws {
        var addedTokens: [String : Int] = [:]
        var specialTokens: [String : Int] = [:]
        for addedToken in tokenizerData.addedTokens?.arrayValue ?? [] {
            guard let id = addedToken.id?.intValue else { continue /* malformed: token with no id */ }
            guard let content = addedToken.content?.stringValue else { continue /* malformed: token with no content */ }
            addedTokens[content] = id

            if addedToken.special?.boolValue ?? false {
                specialTokens[content] = id
            }
        }

        // Convert to tuples for easier access, then sort by length (descending) to avoid early partial matches
        // (https://github.com/xenova/transformers.js/commit/c305c3824f628f1f02806a6310bd3b18b0f7f8f5)
        let unwrappedAddedTokens : [(content: String, prefix: Bool, suffix: Bool)] = (tokenizerData.addedTokens?.arrayValue ?? []).compactMap { addedToken in
            guard let content = addedToken.content?.stringValue else { return nil }
            let prefix = addedToken.lstrip?.boolValue ?? false
            let suffix = addedToken.rstrip?.boolValue ?? false
            return (content: content, prefix: prefix, suffix: suffix)
        }.sorted {
            $0.content.count > $1.content.count
        }

        // then concatenate into regular expression
        let addedTokensRegexString = unwrappedAddedTokens.map {
            let token = NSRegularExpression.escapedPattern(for: $0.content)
            let prefix = $0.prefix ? #"\s*"# : ""
            let suffix = $0.suffix ? #"\s*"# : ""
            return "\(prefix)(\(token))\(suffix)"
        }.joined(separator: "|")
        addedTokensRegex = try? NSRegularExpression(pattern: addedTokensRegexString, options: [])

        // TODO: specialTokens are stored but never used
        self.specialTokens = specialTokens
        self.addedTokens = Set(addedTokens.keys)

        self.preTokenizer = PreTokenizerFactory.fromConfig(config: tokenizerData.preTokenizer)
        self.normalizer = NormalizerFactory.fromConfig(config: tokenizerData.normalizer)
        self.postProcessor = PostProcessorFactory.fromConfig(config: tokenizerData.postProcessor)
        self.decoder = DecoderFactory.fromConfig(config: tokenizerData.decoder)
        self.cleanUpTokenizationSpaces = tokenizerConfig.cleanUpTokenizationSpaces?.boolValue ?? true
        self.tokenizerConfig = tokenizerConfig
        
        model = try TokenizerModel.from(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData, addedTokens: addedTokens)
    }

    func preTokenize(_ text: String, options: PreTokenizerOptions) -> [String] {
        guard let preTokenizer = preTokenizer else { return [text] }
        return preTokenizer(text: text, options: options)
    }

    func normalize(_ text: String) -> String {
        guard let normalizer = normalizer else { return text }
        return normalizer(text: text)
    }

    func postProcess(_ tokens: [String], addSpecialTokens: Bool = true) -> [String] {
        guard let postProcessor = postProcessor else { return tokens }
        return postProcessor(tokens: tokens, addSpecialTokens: addSpecialTokens)
    }

    func decodeTokens(_ tokens: [String]) -> [String] {
        guard let tokenDecoder = decoder else { return tokens }
        return tokenDecoder(tokens: tokens)
    }

    /// Clean up a list of simple English tokenization artifacts like spaces before punctuations and abbreviated forms
    func cleanUp(text: String) -> String {
        guard cleanUpTokenizationSpaces else { return text }

        return text.replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ?", with: "?")
            .replacingOccurrences(of: " !", with: "!")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " ' ", with: "'")
            .replacingOccurrences(of: " n't", with: "n't")
            .replacingOccurrences(of: " 'm", with: "'m")
            .replacingOccurrences(of: " 's", with: "'s")
            .replacingOccurrences(of: " 've", with: "'ve")
            .replacingOccurrences(of: " 're", with: "'re")
    }

    func fuseUnknown(_ tokens: [String]) -> [String] {
        guard fuseUnknownTokens else { return tokens }
        let (fused, _) = tokens.reduce((fused: [String](), previousIsUnknown: false)) { result, token in
            var (fused, previousIsUnknown) = result
            let isUnknown = model.convertTokenToId(token) == model.unknownTokenId
            if isUnknown {
                if !previousIsUnknown { fused.append(token) }
            } else {
                fused.append(token)
            }
            return (fused, isUnknown)
        }
        return fused
    }

    public func tokenize(text: String) -> [String] {
        // Take care of special tokens first
        let sections: [String]
        if let regex = self.addedTokensRegex {
            sections = text.split(by: regex)
        } else {
            sections = [text]
        }
        return sections.enumerated().map { section, x in
            if addedTokens.contains(x) { return [x] }
            return preTokenize(normalize(x), options: section == 0 ? [.firstSection] : []).flatMap { model($0) }
        }.flatMap { fuseUnknown($0) }
    }

    /// Main entry point
    public func encode(text: String, addSpecialTokens: Bool = true) -> [Int] {
        return postProcess(tokenize(text: text), addSpecialTokens: addSpecialTokens).map { model.convertTokenToId($0)! }
    }

    public func encode(text: String) -> [Int] {
        return encode(text: text, addSpecialTokens: true)
    }

    /// Decode
    public func decode(tokens: [Int]) -> String {
        // IDs to tokens
        let tokenStrings = tokens.compactMap { model.convertIdToToken($0) }
        let decoded = decodeTokens(tokenStrings)
        // At this point we should have a single String
        return cleanUp(text: decoded.joined(separator: ""))
    }

    public func convertTokenToId(_ token: String) -> Int? {
        model.convertTokenToId(token)
    }

    public func convertIdToToken(_ id: Int) -> String? {
        model.convertIdToToken(id)
    }
    
    public func applyChatTemplate(messages: [[String: String]]) throws -> [Int] {
        try applyChatTemplate(messages: messages, chatTemplate: nil, addGenerationPrompt: true, maxLength: nil)
    }
    
    public func applyChatTemplate(
        messages: [[String: String]],
        chatTemplate: String?,
        addGenerationPrompt: Bool = false,
        truncation: Bool = false,
        maxLength: Int?
    ) throws -> [Int] {
        let template = try Template(chatTemplate ?? tokenizerConfig.chatTemplate?.stringValue ?? defaultChatTemplate)
        var context: [String: Any] = [
            "messages": messages,
            "add_generation_prompt": addGenerationPrompt
        ]

        // TODO: maybe keep NSString here
        for (key, value) in tokenizerConfig.dictionary as [String : Any] {
            if specialTokenAttributes.contains(key), !(value is NSNull) {
                context[key] = value
            }
        }

        let rendered = try template.render(context)
        var encodedTokens = encode(text: rendered, addSpecialTokens: false)
        var maxLength = maxLength ?? encodedTokens.count
        maxLength = min(maxLength, tokenizerConfig.modelMaxLength?.intValue ?? maxLength)
        if encodedTokens.count > maxLength {
            if truncation {
                encodedTokens = Array(encodedTokens.prefix(maxLength))
            }
        }

        return encodedTokens
    }
}

// MARK: - Building

public struct AutoTokenizer {}

struct PreTrainedTokenizerClasses {
    /// Class overrides for custom behaviour
    /// Not to be confused with the TokenizerModel classes defined in TokenizerModel
    static let tokenizerClasses: [String : PreTrainedTokenizer.Type] = [
        "LlamaTokenizer": LlamaPreTrainedTokenizer.self
    ]
}

extension AutoTokenizer {
    static func tokenizerClass(for tokenizerConfig: Config) -> PreTrainedTokenizer.Type {
        guard let tokenizerClassName = tokenizerConfig.tokenizerClass?.stringValue else {
            return PreTrainedTokenizer.self
        }

        // Some tokenizer_class entries use a Fast suffix
        let tokenizerName = tokenizerClassName.replacingOccurrences(of: "Fast", with: "")
        if let tokenizerClass = PreTrainedTokenizerClasses.tokenizerClasses[tokenizerName] {
            return tokenizerClass
        }

        return PreTrainedTokenizer.self
    }

    public static func from(tokenizerConfig: Config, tokenizerData: Config) throws -> Tokenizer {
        let tokenizerClass = tokenizerClass(for: tokenizerConfig)
        return try tokenizerClass.init(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)
    }

    public static func from(
        pretrained model: String,
        hubApi: HubApi = .shared
    ) async throws -> Tokenizer {
        let config = LanguageModelConfigurationFromHub(modelName: model, hubApi: hubApi)
        guard let tokenizerConfig = try await config.tokenizerConfig else { throw TokenizerError.missingConfig }
        let tokenizerData = try await config.tokenizerData

        return try AutoTokenizer.from(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)
    }
    
    public static func from(
        modelFolder: URL,
        hubApi: HubApi = .shared
    ) async throws -> Tokenizer {
        let config = LanguageModelConfigurationFromHub(modelFolder: modelFolder, hubApi: hubApi)
        guard let tokenizerConfig = try await config.tokenizerConfig else { throw TokenizerError.missingConfig }
        let tokenizerData = try await config.tokenizerData
        
        return try PreTrainedTokenizer(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)
    }
}

// MARK: - Tokenizer model classes

class GPT2Tokenizer     : BPETokenizer {}
class FalconTokenizer   : BPETokenizer {}
class LlamaTokenizer    : BPETokenizer {}
class CodeGenTokenizer  : BPETokenizer {}
class WhisperTokenizer  : BPETokenizer {}
class GemmaTokenizer    : BPETokenizer {}
class CodeLlamaTokenizer: BPETokenizer {}
class CohereTokenizer   : BPETokenizer {}

class T5Tokenizer       : UnigramTokenizer {}


// MARK: - PreTrainedTokenizer classes

let sentencePieceUnderline = "▁"

// See https://github.com/xenova/transformers.js/blob/1a9964fb09b8f54fcbeac46dc6aae8d76795809d/src/tokenizers.js#L3203 for these exceptions
class LlamaPreTrainedTokenizer: PreTrainedTokenizer {
    let isLegacy: Bool

    required init(tokenizerConfig: Config, tokenizerData: Config) throws {
        isLegacy = tokenizerConfig.legacy?.boolValue ?? true
        var configDictionary = tokenizerData.dictionary
        if !isLegacy {
            configDictionary.removeValue(forKey: "normalizer")
            configDictionary["pre_tokenizer"] = ["type": "Metaspace", "replacement": sentencePieceUnderline, "add_prefix_space": true, "prepend_scheme": "first"]
        }
        let updatedData = Config(configDictionary)

        try super.init(tokenizerConfig: tokenizerConfig, tokenizerData: updatedData)
    }
}
