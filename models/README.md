# models

`Setup-USB.cmd` downloads `gpt-oss-20b-MXFP4.gguf` (about 12 GB) here from
[ggml-org/gpt-oss-20b-GGUF](https://huggingface.co/ggml-org/gpt-oss-20b-GGUF), the llama.cpp team's
conversion of [openai/gpt-oss-20b](https://huggingface.co/openai/gpt-oss-20b), and checks its SHA-256.

The drive must be **exFAT or NTFS**. FAT32 cannot store files larger than 4 GB.

Want a different model? Drop any `.gguf` file here and set `llm.modelFile` in `config/settings.json`.
