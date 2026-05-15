#!/bin/bash
# DESCRIPTION: Python 2 (2.7.18 via pyenv, available as python2/pip2)

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

PYTHON2_VERSION="2.7.18"
CLAUDE_HOME="/home/claude"
PYENV_ROOT="$CLAUDE_HOME/.pyenv"

echo "[python2] Installing build dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
    libssl-dev \
    libffi-dev \
    libreadline-dev \
    libbz2-dev \
    libsqlite3-dev \
    liblzma-dev \
    libncurses5-dev \
    libgdbm-dev \
    tk-dev
apt-get clean

echo "[python2] Installing pyenv..."
runuser -u claude -- bash -c "curl -fsSL https://pyenv.run | bash"

echo "[python2] Compiling Python $PYTHON2_VERSION (this takes a few minutes)..."
runuser -u claude -- bash -c "
    export PYENV_ROOT=\"$PYENV_ROOT\"
    export PATH=\"\$PYENV_ROOT/bin:\$PATH\"
    eval \"\$(pyenv init -)\"
    pyenv install $PYTHON2_VERSION
    pyenv global $PYTHON2_VERSION
"

echo "[python2] Bootstrapping pip2..."
runuser -u claude -- bash -c "
    export PYENV_ROOT=\"$PYENV_ROOT\"
    export PATH=\"\$PYENV_ROOT/bin:\$PATH\"
    eval \"\$(pyenv init -)\"
    pyenv global $PYTHON2_VERSION
    curl -fsSL https://bootstrap.pypa.io/pip/2.7/get-pip.py | python
"

echo "[python2] Creating python2/pip2 symlinks..."
ln -sf "$PYENV_ROOT/shims/python" /usr/local/bin/python2
ln -sf "$PYENV_ROOT/shims/pip" /usr/local/bin/pip2

echo "[python2] Configuring shell environments..."
for rc in "$CLAUDE_HOME/.bashrc" "$CLAUDE_HOME/.zshrc"; do
    if [ -f "$rc" ]; then
        cat >> "$rc" << 'EOF'

# pyenv (python2)
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
EOF
    fi
done

echo "[python2] Installation complete."
runuser -u claude -- bash -c "
    export PYENV_ROOT=\"$PYENV_ROOT\"
    export PATH=\"\$PYENV_ROOT/bin:\$PATH\"
    eval \"\$(pyenv init -)\"
    python --version
    pip --version
"
