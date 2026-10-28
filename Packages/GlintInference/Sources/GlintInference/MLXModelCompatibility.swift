import MLXLLM

public enum MLXModelCompatibility {
    public static func supports(modelType: String) async -> Bool {
        await LLMTypeRegistry.shared.contains(modelType)
    }
}
