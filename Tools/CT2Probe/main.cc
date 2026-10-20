#include <ctranslate2/translator.h>
#include <sentencepiece_processor.h>

#include <iostream>
#include <string>
#include <vector>

int main(int argc, char** argv) {
  if (argc < 3) {
    std::cerr << "usage: ct2probe <model_dir> <text>\n";
    return 1;
  }

  sentencepiece::SentencePieceProcessor processor;
  if (!processor.Load(argv[1] + std::string("/source.spm")).ok()) {
    std::cerr << "failed to load source.spm\n";
    return 2;
  }

  std::vector<std::string> tokens;
  processor.Encode(argv[2], &tokens).IgnoreError();
  tokens.push_back("</s>");

  ctranslate2::Translator translator(
      argv[1],
      ctranslate2::Device::CPU,
      ctranslate2::ComputeType::INT8);

  ctranslate2::TranslationOptions options;
  options.beam_size = 4;
  options.max_decoding_length = 48;
  auto results = translator.translate_batch({tokens}, options);
  for (const auto& token : results[0].output()) {
    std::cout << token << " ";
  }
  std::cout << "\n";
  return 0;
}
