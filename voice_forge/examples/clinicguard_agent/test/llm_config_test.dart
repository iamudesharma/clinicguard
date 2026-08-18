import 'package:test/test.dart';
import 'package:voice_forge/voice_forge.dart';

import '../bin/llm_config.dart';

void main() {
  test('clinicGuardLlmFromEnv chains Cline → OpenCode → Gemini → OpenRouter',
      () {
    final llm = clinicGuardLlmFromEnv(const {
      'CLINE_API_KEY': 'c',
      'CLINE_MODEL': 'my-cline-model',
      'OPENCODE_API_KEY': 'oc',
      'OPENCODE_MODEL': 'deepseek-v4-flash-free',
      'GEMINI_API_KEY': 'g',
      'OPENROUTER_API_KEY': 'or',
    });
    expect(llm, isA<FallbackLlm>());
    final f1 = llm as FallbackLlm;
    final cline = (((f1.primary as FallbackLlm).primary as FallbackLlm)
            .primary as OpenAiCompatibleLlm);
    expect(cline.baseUrl, 'https://api.cline.bot/api/v1');
    expect(cline.model, 'my-cline-model');
    final opencode = ((f1.primary as FallbackLlm).primary as FallbackLlm)
        .fallback as OpenAiCompatibleLlm;
    expect(opencode.baseUrl, 'https://opencode.ai/zen/go/v1');
    expect(opencode.model, 'deepseek-v4-flash-free');
    final gemini = (f1.primary as FallbackLlm).fallback as OpenAiCompatibleLlm;
    expect(
      gemini.baseUrl,
      'https://generativelanguage.googleapis.com/v1beta/openai',
    );
    final openrouter = f1.fallback as OpenAiCompatibleLlm;
    expect(openrouter.baseUrl, 'https://openrouter.ai/api/v1');
  });

  test('clinicGuardLlmFromEnv with only Cline yields a single provider', () {
    final llm = clinicGuardLlmFromEnv(const {'CLINE_API_KEY': 'k'});
    expect(llm, isA<OpenAiCompatibleLlm>());
  });
}
