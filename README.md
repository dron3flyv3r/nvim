# nvim

Neovim configuration with plugins managed by `lazy.nvim`.

## Setup guide

### 1) Install dependencies

#### Ubuntu / Debian

```bash
sudo apt update
sudo apt install -y neovim git curl unzip ripgrep fd-find gcc nodejs npm python3-venv xclip
```

Ubuntu installs `fd` as `fdfind`. If you want the `fd` command:

```bash
mkdir -p ~/.local/bin
ln -sf "$(command -v fdfind)" ~/.local/bin/fd
```

#### Arch Linux

```bash
sudo pacman -S --needed neovim git curl unzip ripgrep fd gcc nodejs npm python python-pynvim xclip
```

### 2) Install this config

```bash
git clone https://github.com/dron3flyv3r/nvim ~/.config/nvim
```

### 3) Start Neovim and install plugins

```bash
nvim
```

Then run:

```vim
:Lazy sync
```

### 4) Validate setup

Run:

```vim
:checkhealth
```

Fix any missing providers/tools reported there and restart Neovim.
