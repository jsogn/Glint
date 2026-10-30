#include <rime_api.h>

#include <cstdio>
#include <cstdlib>
#include <string>

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(
        stderr,
        "usage: engine_console <shared-data-dir> <user-data-dir> "
        "[key-sequence ...]\n");
    return 2;
  }

  RimeApi* rime = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.app_name = "rime.glint.candidate_lab";
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  rime->setup(&traits);
  rime->initialize(nullptr);

  if (rime->start_maintenance(False)) {
    rime->join_maintenance_thread();
  }

  RimeSessionId session = rime->create_session();
  if (!session) {
    std::fprintf(stderr, "failed to create Rime session\n");
    rime->finalize();
    return 1;
  }
  if (!rime->select_schema(session, "luna_pinyin")) {
    std::fprintf(stderr, "failed to select luna_pinyin\n");
    rime->destroy_session(session);
    rime->finalize();
    return 1;
  }
  const int sequenceCount = argc > 3 ? argc - 3 : 1;
  for (int index = 0; index < sequenceCount; ++index) {
    const char* sequence = argc > 3 ? argv[index + 3] : "nihao";
    if (!rime->simulate_key_sequence(session, sequence)) {
      std::fprintf(stderr, "failed to simulate key sequence: %s\n", sequence);
      rime->destroy_session(session);
      rime->finalize();
      return 1;
    }
  }

  RIME_STRUCT(RimeStatus, status);
  RIME_STRUCT(RimeContext, context);
  const Bool has_status = rime->get_status(session, &status);
  const Bool has_context = rime->get_context(session, &context);
  std::printf(
      "engine-console: simulated composing=%d candidates=%d\n",
      has_status ? status.is_composing : -1,
      has_context ? context.menu.num_candidates : -1);
  if (has_context) {
    rime->free_context(&context);
  }
  if (has_status) {
    rime->free_status(&status);
  }
  rime->destroy_session(session);
  rime->finalize();
  return 0;
}
