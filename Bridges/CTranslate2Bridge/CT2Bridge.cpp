#include "CT2Bridge.h"

#include <absl/types/span.h>
#include <ctranslate2/translator.h>
#include <sentencepiece_processor.h>

#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

struct GlintCT2Handle {
  sentencepiece::SentencePieceProcessor source;
  sentencepiece::SentencePieceProcessor target;
  std::unique_ptr<ctranslate2::Translator> translator;
};

void set_error(char** error, const std::string& message) {
  if (error != nullptr) {
    *error = ::strdup(message.c_str());
  }
}

}  // namespace

extern "C" {

void* glint_ct2_create(const char* model_dir, char** error) {
  if (error != nullptr) {
    *error = nullptr;
  }
  try {
    if (model_dir == nullptr) {
      throw std::runtime_error("model directory is null");
    }

    auto handle = std::make_unique<GlintCT2Handle>();
    const std::string root(model_dir);
    const auto source_status = handle->source.Load(root + "/source.spm");
    if (!source_status.ok()) {
      throw std::runtime_error("source.spm: " + source_status.ToString());
    }
    const auto target_status = handle->target.Load(root + "/target.spm");
    if (!target_status.ok()) {
      throw std::runtime_error("target.spm: " + target_status.ToString());
    }

    handle->translator = std::make_unique<ctranslate2::Translator>(
        root,
        ctranslate2::Device::CPU,
        ctranslate2::ComputeType::INT8);
    return handle.release();
  } catch (const std::exception& exc) {
    set_error(error, exc.what());
    return nullptr;
  }
}

char* glint_ct2_translate(void* raw_handle, const char* text) {
  if (raw_handle == nullptr || text == nullptr) {
    return nullptr;
  }
  auto* handle = static_cast<GlintCT2Handle*>(raw_handle);
  try {
    std::vector<std::string> source_tokens;
    const auto encode_status = handle->source.Encode(text, &source_tokens);
    if (!encode_status.ok()) {
      return nullptr;
    }
    source_tokens.push_back("</s>");

    ctranslate2::TranslationOptions options;
    options.beam_size = 4;
    options.max_decoding_length = 48;
    const auto results = handle->translator->translate_batch({source_tokens}, options);
    if (results.empty()) {
      return nullptr;
    }

    std::string translated;
    const auto decode_status = handle->target.Decode(
        absl::MakeConstSpan(results[0].output()),
        &translated
    );
    if (!decode_status.ok()) {
      return nullptr;
    }
    return ::strdup(translated.c_str());
  } catch (...) {
    return nullptr;
  }
}

void glint_ct2_free_string(char* value) {
  std::free(value);
}

void glint_ct2_destroy(void* raw_handle) {
  delete static_cast<GlintCT2Handle*>(raw_handle);
}

}  // extern "C"
