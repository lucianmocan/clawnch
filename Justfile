set shell := ["bash", "-c"]

IMAGE := "safe/opencode"

# Build the Docker image
build:
    docker build --build-arg USER_ID=$(id -u) -t {{IMAGE}} .

# Store API keys in macOS Keychain
setup:
    @for account in OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY DEEPSEEK_API_KEY; do \
        printf "%s: " "$account"; \
        read -r val; \
        [ -z "$val" ] && continue; \
        security add-generic-password -s safe -a "$account" -w "$val" -U 2>/dev/null; \
        echo "  stored"; \
    done; \
    echo "Done. Keys are stored in macOS Keychain (service: safe)."

# List stored API keys (values are masked)
list:
    @for account in OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY DEEPSEEK_API_KEY Together_API_KEY; do \
        value=$(security find-generic-password -s safe -a "$account" -w 2>/dev/null); \
        if [ -n "$value" ]; then \
            echo "$account  $(echo "$value" | sed 's/./*/g')"; \
        fi; \
    done

# Remove a specific key from Keychain (e.g. just remove-key OPENROUTER_API_KEY)
remove-key account:
    @security delete-generic-password -s safe -a "{{account}}" > /dev/null 2>&1 && \
        echo "Removed {{account}}" || \
        echo "Key {{account}} not found"

# Run opencode in a sandboxed Docker container for the given project.
#   net="bridge" (default): full internet, AI provider APIs work normally.
#   net="none":             fully isolated, no network (AI features unavailable).
opencode folder net="bridge" *args:
    @found=0; \
    for account in OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY DEEPSEEK_API_KEY Together_API_KEY; do \
        value=$(security find-generic-password -s safe -a "$account" -w 2>/dev/null); \
        [ -n "$value" ] && found=$((found + 1)); \
    done; \
    if [ "$found" -eq 0 ]; then \
        echo "No API keys found in Keychain. Run 'just setup' first." >&2; \
        exit 1; \
    fi; \
    docker image inspect {{IMAGE}} > /dev/null 2>&1 || docker build --build-arg USER_ID=$(id -u) -t {{IMAGE}} .; \
    f="{{folder}}"; \
    case "$f" in \
        /*) ;; \
        "~") f="$HOME" ;; \
        "~/"*) f="$HOME/${f#\~/}" ;; \
        *) f="$PWD/$f" ;; \
    esac; \
    cd "$f" 2>/dev/null || { echo "Error: directory not found: {{folder}}" >&2; exit 1; }; \
    abs_path="$PWD"; \
    docker run -it --rm \
        -v "$abs_path:/workspace:delegated" \
        --env-file <( \
            for account in OPENROUTER_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY DEEPSEEK_API_KEY Together_API_KEY; do \
                value=$(security find-generic-password -s safe -a "$account" -w 2>/dev/null); \
                [ -n "$value" ] && printf '%s=%s\n' "$account" "$value"; \
            done \
        ) \
        --network {{net}} \
        --cap-drop ALL \
        --security-opt no-new-privileges:true \
        -e TERM \
        -e EDITOR=vi \
        {{IMAGE}} \
        opencode /workspace {{args}}
