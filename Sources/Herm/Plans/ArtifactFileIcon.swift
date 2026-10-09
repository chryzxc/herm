import AppKit

/// Language-aware file icons from Material Icon Theme (MIT, bundled under
/// Resources/FileIcons). NSImage renders the SVGs natively on macOS 14+.
@MainActor
enum ArtifactFileIcon {
    /// Exact file names win over extensions (package.json is Node, not JSON).
    static let fileNames: [String: String] = [
        "package.json": "nodejs", "package-lock.json": "npm", "yarn.lock": "yarn",
        "pnpm-lock.yaml": "pnpm", "bun.lockb": "bun", "tsconfig.json": "tsconfig",
        "dockerfile": "docker", "docker-compose.yml": "docker", "docker-compose.yaml": "docker",
        ".gitignore": "git", ".gitattributes": "git", ".env": "tune", ".editorconfig": "editorconfig",
        "makefile": "makefile", "readme.md": "readme", "license": "license", "license.md": "license",
        "changelog.md": "changelog", "gemfile": "gemfile", "build.gradle": "gradle",
        ".eslintrc": "eslint", ".eslintrc.json": "eslint", "eslint.config.js": "eslint",
        ".prettierrc": "prettier", "vite.config.ts": "vite", "vite.config.js": "vite",
        "tailwind.config.js": "tailwindcss", "tailwind.config.ts": "tailwindcss",
        "next.config.js": "next", "next.config.mjs": "next", "vercel.json": "vercel",
        "babel.config.js": "babel", "webpack.config.js": "webpack", "deno.json": "deno",
        "schema.prisma": "prisma", "taskfile.yml": "taskfile", "todo.md": "todo",
    ]

    /// Longest suffix wins, so `.test.ts` and `.d.ts` beat `.ts`.
    static let extensions: [String: String] = [
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "d.ts": "typescript-def",
        "tsx": "react_ts", "jsx": "react", "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "test.ts": "test-ts", "spec.ts": "test-ts", "test.js": "test-js", "spec.js": "test-js",
        "test.tsx": "test-jsx", "test.jsx": "test-jsx", "js.map": "javascript-map", "css.map": "css-map",
        "py": "python", "ipynb": "jupyter", "swift": "swift", "go": "go", "rs": "rust",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "c": "c", "h": "h", "cpp": "cpp", "cc": "cpp",
        "hpp": "hpp", "cs": "csharp", "m": "objective-c", "rb": "ruby", "php": "php", "dart": "dart",
        "lua": "lua", "r": "r", "scala": "scala", "ex": "elixir", "exs": "elixir", "erl": "erlang",
        "hs": "haskell", "zig": "zig", "nix": "nix", "jl": "julia", "pl": "perl", "clj": "clojure",
        "ml": "ocaml", "vue": "vue", "svelte": "svelte", "astro": "astro",
        "html": "html", "htm": "html", "css": "css", "scss": "sass", "sass": "sass", "less": "less",
        "json": "json", "jsonc": "json", "yaml": "yaml", "yml": "yaml", "toml": "toml", "xml": "xml",
        "xaml": "xaml", "md": "markdown", "markdown": "markdown", "mdx": "mdx", "tex": "tex",
        "graphql": "graphql", "gql": "graphql", "prisma": "prisma", "proto": "proto",
        "tf": "terraform", "sql": "database", "db": "database", "sqlite": "database",
        "sh": "console", "bash": "console", "zsh": "console", "fish": "console", "ps1": "powershell",
        "env": "tune", "ini": "settings", "conf": "settings", "cfg": "settings", "lock": "lock",
        "log": "log", "http": "http", "pem": "certificate", "crt": "certificate", "key": "key",
        "pdf": "pdf", "txt": "document", "rtf": "document", "doc": "word", "docx": "word",
        "ppt": "powerpoint", "pptx": "powerpoint", "csv": "table", "tsv": "table", "xls": "table",
        "xlsx": "table", "zip": "zip", "gz": "zip", "tar": "zip", "tgz": "zip", "7z": "zip",
        "svg": "svg", "png": "image", "jpg": "image", "jpeg": "image", "gif": "image", "webp": "image",
        "heic": "image", "ico": "image", "lottie": "lottie", "mp3": "audio", "wav": "audio",
        "m4a": "audio", "mp4": "video", "mov": "video", "webm": "video", "ttf": "font", "otf": "font",
        "woff": "font", "woff2": "font", "dmg": "disc", "iso": "disc", "exe": "exe", "apk": "android",
        "gradle": "gradle", "mat": "matlab",
    ]

    static let fallback = "document"

    static func name(for fileName: String) -> String {
        let lower = fileName.lowercased()
        if let match = fileNames[lower] { return match }
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        // Try ".test.ts" before ".ts"; skip index 0 (the base name).
        for start in parts.indices.dropFirst() {
            if let match = extensions[parts[start...].joined(separator: ".")] { return match }
        }
        if lower.hasPrefix(".env") { return "tune" }
        return fallback
    }

    private static let bundle: Bundle = Bundle.main.resourceURL.flatMap {
        Bundle(url: $0.appendingPathComponent("Herm_Herm.bundle"))
    } ?? Bundle.module

    private static var cache: [String: NSImage] = [:]

    static func image(for fileName: String) -> NSImage? {
        let key = name(for: fileName)
        if let cached = cache[key] { return cached }
        guard let url = bundle.url(forResource: key, withExtension: "svg", subdirectory: "FileIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        cache[key] = image
        return image
    }
}
