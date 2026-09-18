// Artifact identities, not weights. Updating these requires the full model differential.
enum SupportedBaseline {
    static let revision = "b1f7ac8282ce060e4ad1374cb9a34750e31723c1"
    static let artifacts: [String: String] = [
        "chat_template.jinja": "273d8e0e683b885071fb17e08d71e5f2a5ddfb5309756181681de4f5a1822d80",
        "config.json": "562a3d5264ec78616357528b4f8095de0d398ce0d25d462df978627c9de75bb0",
        "model.safetensors": "dbe5a5cdc26d383eaf3f7a009d41a746ec2a99ed262095c1ab9146870090240c",
        "model.safetensors.index.json": "d233c6e841b70f564703ddeb69fd6cd7bad07bc8f9974a8a47b9cf5b1edaa313",
        "system_v2.txt": "86ce80cbb40bb02b69cad54d6a48c2b38f5f08ab4fb0c462f615ce02a7fc2d5b",
        "tokenizer.json": "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4",
        "tokenizer_config.json": "253684edcbcae5b893442b7de203b7d48230f6eea05de71f2d8e1a0575007528",
    ]
}
