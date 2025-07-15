FROM node:20-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    python3 \
    build-essential \
    sudo \
    procps \
    psmisc \
    htop \
    vim \
    nano \
    less \
    && rm -rf /var/lib/apt/lists/*

# Install additional system packages if specified
ARG SYSTEM_PACKAGES=""
RUN if [ -n "$SYSTEM_PACKAGES" ]; then \
    echo "Installing additional system packages: $SYSTEM_PACKAGES" && \
    apt-get update && \
    apt-get install -y $SYSTEM_PACKAGES && \
    rm -rf /var/lib/apt/lists/*; \
    fi

# Create a non-root user with matching host UID/GID
ARG USER_UID=1000
ARG USER_GID=1000
RUN if getent group $USER_GID > /dev/null 2>&1; then \
        GROUP_NAME=$(getent group $USER_GID | cut -d: -f1); \
    else \
        groupadd -g $USER_GID claude-user && GROUP_NAME=claude-user; \
    fi && \
    if getent passwd $USER_UID > /dev/null 2>&1; then \
        USER_NAME=$(getent passwd $USER_UID | cut -d: -f1); \
    else \
        useradd -m -s /bin/bash -u $USER_UID -g $GROUP_NAME claude-user && USER_NAME=claude-user; \
    fi && \
    echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Create necessary directories
RUN mkdir -p /app /workspace /app/.claude /app/templates/.claude && \
    USER_NAME=$(getent passwd $USER_UID | cut -d: -f1) && \
    HOME_DIR=$(getent passwd $USER_UID | cut -d: -f6) && \
    chown -R $USER_UID:$USER_GID /app /workspace && \
    if [ -d "$HOME_DIR" ]; then chown -R $USER_UID:$USER_GID "$HOME_DIR"; fi

# Set working directory
WORKDIR /app

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Install MCP dependencies
RUN npm install -g @modelcontextprotocol/server-filesystem \
    @modelcontextprotocol/server-github \
    @modelcontextprotocol/server-slack

# Copy all files from build context and handle missing files gracefully
COPY . /tmp/build-context/
RUN if [ -f /tmp/build-context/.env ]; then \
        cp /tmp/build-context/.env /app/.env; \
    else \
        touch /app/.env; \
    fi && \
    if [ -d /tmp/build-context/.claude ]; then \
        cp -r /tmp/build-context/.claude/* /app/.claude/; \
    else \
        echo '{"dangerouslySkipPermissions": true, "mcp": {"servers": {"filesystem": {"command": "node", "args": ["/usr/local/lib/node_modules/@modelcontextprotocol/server-filesystem/dist/index.js", "/workspace"]}}}}' > /app/.claude/settings.json; \
    fi && \
    if [ -d /tmp/build-context/templates ]; then \
        cp -r /tmp/build-context/templates/* /app/templates/; \
    else \
        mkdir -p /app/templates/.claude && \
        echo "# Claude Docker Agent Instructions" > /app/templates/.claude/CLAUDE.md && \
        echo "" >> /app/templates/.claude/CLAUDE.md && \
        echo "You are Claude, an AI assistant running in a Docker container with full autonomous permissions." >> /app/templates/.claude/CLAUDE.md && \
        echo "" >> /app/templates/.claude/CLAUDE.md && \
        echo "## Your Environment" >> /app/templates/.claude/CLAUDE.md && \
        echo "- You have full access to the workspace directory" >> /app/templates/.claude/CLAUDE.md && \
        echo "- You can execute any commands without permission prompts" >> /app/templates/.claude/CLAUDE.md && \
        echo "- Git is configured and available" >> /app/templates/.claude/CLAUDE.md && \
        echo "- Python, Node.js, and build tools are installed" >> /app/templates/.claude/CLAUDE.md && \
        echo "" >> /app/templates/.claude/CLAUDE.md && \
        echo "## Your Behavior" >> /app/templates/.claude/CLAUDE.md && \
        echo "- Be proactive and autonomous in task execution" >> /app/templates/.claude/CLAUDE.md && \
        echo "- Document your work in task_log.md" >> /app/templates/.claude/CLAUDE.md && \
        echo "- Read any plan.md file in the project root for task specifications" >> /app/templates/.claude/CLAUDE.md && \
        echo "- Execute tasks faithfully and completely" >> /app/templates/.claude/CLAUDE.md && \
        echo "- Commit your work to git when appropriate" >> /app/templates/.claude/CLAUDE.md && \
        echo "" >> /app/templates/.claude/CLAUDE.md && \
        echo "Remember: You have --dangerously-skip-permissions enabled, so use this power responsibly." >> /app/templates/.claude/CLAUDE.md; \
    fi && \
    rm -rf /tmp/build-context

# Create startup script
RUN printf '#!/bin/bash\nset -e\n\n# Handle signals gracefully\ntrap "echo \\"Received signal, shutting down gracefully...\\"; exit 0" SIGTERM SIGINT\n\n# Source environment variables\nif [ -f /app/.env ]; then\n    export $(grep -v "^#" /app/.env | xargs)\nfi\n\n# Set up Claude home directory\nCLAUDE_HOME=${CLAUDE_HOME:-/workspace/.claude}\nmkdir -p "$CLAUDE_HOME"\n\n# Copy base configuration if it does not exist\nif [ ! -f "$CLAUDE_HOME/settings.json" ] && [ -f "/app/.claude/settings.json" ]; then\n    cp -r /app/.claude/* "$CLAUDE_HOME/"\nfi\n\n# Copy project-specific claude template\nif [ -f "/app/templates/.claude/CLAUDE.md" ]; then\n    mkdir -p "$CLAUDE_HOME"\n    cp "/app/templates/.claude/CLAUDE.md" "$CLAUDE_HOME/"\nfi\n\n# Handle conda environment setup if specified\nif [ -n "$CONDA_PREFIX" ]; then\n    echo "Setting up conda environment: $CONDA_PREFIX"\n    export PATH="$CONDA_PREFIX/bin:$PATH"\n    if [ -n "$CONDA_EXTRA_DIRS" ]; then\n        for dir in $CONDA_EXTRA_DIRS; do\n            if [[ "$dir" == *env* ]]; then\n                export CONDA_ENVS_DIRS="$dir:$CONDA_ENVS_DIRS"\n            elif [[ "$dir" == *pkg* ]]; then\n                export CONDA_PKGS_DIRS="$dir:$CONDA_PKGS_DIRS"\n            fi\n        done\n    fi\nfi\n\n# Change to workspace directory\ncd /workspace\n\n# Start Claude Code with dangerous permissions skipped\nexec claude --dangerously-skip-permissions "$@"\n' > /app/startup.sh

# Set proper permissions
RUN chmod +x /app/startup.sh && \
    chown -R $USER_UID:$USER_GID /app

# Switch to non-root user
USER $USER_UID

# Set environment variables
ENV CLAUDE_HOME=/workspace/.claude
ENV PATH="/app:$PATH"

# Default command
ENTRYPOINT ["/app/startup.sh"]
