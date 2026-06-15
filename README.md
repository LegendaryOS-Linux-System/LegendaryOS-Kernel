# LegendaryOS Kernel — Build System

System budowania własnego jądra Linuxa dla dystrybucji **LegendaryOS** (Fedora-based),
zoptymalizowanego pod sterowniki **NVIDIA akmod**.

---

## Struktura projektu

```
legendaryos-kernel/
├── build.rb              ← główny skrypt (entry point)
├── config.toml           ← konfiguracja (wersja, token, opcje)
├── Gemfile               ← zależności Ruby
├── patches/              ← opcjonalne patche *.patch (stosowane po kolei)
│   └── README
└── src/
    ├── config_loader.rb      ← wczytuje config.toml
    ├── kernel_fetcher.rb     ← pobiera źródła z kernel.org + weryfikacja SHA-256
    ├── kernel_configurator.rb← .config (Fedora base, NVIDIA tweaki, optymalizacje)
    ├── kernel_builder.rb     ← kompilacja (make bzImage + modules)
    ├── rpm_packager.rb       ← generuje specfile + rpmbuild → .rpm
    ├── github_releaser.rb    ← tworzy GitHub Release + uploaduje .rpm
    └── utils.rb              ← wspólne helpery
```

---

## Wymagania

### System

- Fedora 39+ (lub dowolna RPM-based dystrybucja z `rpmbuild`)
- Pakiety deweloperskie:

```bash
sudo dnf install -y \
  gcc make bc flex bison openssl-devel \
  elfutils-libelf-devel dwarves pahole \
  rpm-build rpmdevtools \
  curl xz
```

### Ruby

```bash
sudo dnf install -y ruby
gem install bundler
bundle install
```

---

## Konfiguracja

Edytuj `config.toml`:

```toml
[kernel]
version     = "6.12.6"          # wersja kernela do pobrania
localversion = "-legendaryos"   # sufiks w uname -r

[build]
jobs        = 0                  # 0 = auto (nproc)
optimize_o3 = true               # kompilacja -O3

[nvidia]
enable                  = true
disable_module_signing  = true   # wymagane przez akmod bez Secure Boot

[github]
token = ""                       # zostaw puste — użyj zmiennej środowiskowej
owner = "LegendaryOS-Linux-System"
repo  = "LegendaryOS-Kernel"
```

### Token GitHub

Token **nigdy nie powinien być commitowany** do repozytorium.  
Ustaw go przez zmienną środowiskową:

```bash
export LEGENDARYOS_GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"
```

Token musi mieć uprawnienia: `repo` → `write:packages` i `contents`.

---

## Użycie

### Pełny build + RPM

```bash
ruby build.rb
```

### Pełny build + RPM + GitHub Release

```bash
export LEGENDARYOS_GITHUB_TOKEN="ghp_..."
ruby build.rb --release
```

### Tylko wygeneruj specfile (bez kompilacji)

```bash
ruby build.rb --only-spec
```

### Pomiń pobieranie (źródła już są)

```bash
ruby build.rb --skip-download
```

### Własny config.toml

```bash
ruby build.rb --config /ścieżka/do/mojego/config.toml
```

---

## Jak działa instalacja RPM

Po zainstalowaniu paczki `.rpm` na Fedorze:

1. **`%pre`** — usuwa stary LegendaryOS kernel z GRUB (jeśli istnieje)
2. Kopiuje `vmlinuz`, `System.map`, `.config` do `/boot/`
3. Kopiuje moduły do `/lib/modules/<wersja>/`
4. **`%post`** — generuje `initramfs` przez `dracut`
5. Rejestruje kernel w GRUB przez `grubby --add-kernel --make-default`
6. Ustawia go jako **domyślny** (`grubby --set-default`)
7. Aktualizuje `grub.cfg` (EFI + BIOS)

Po `sudo reboot` system uruchomi się z LegendaryOS Kernel.

### Odinstalowanie

```bash
sudo dnf remove legendaryos-kernel
```

`%postun` automatycznie przywróci poprzedni dostępny kernel jako domyślny.

---

## Optymalizacje pod NVIDIA akmod

| Opcja | Wartość | Powód |
|---|---|---|
| `CONFIG_MODULE_SIG` | `n` | akmod nie podpisuje modułów (bez Secure Boot) |
| `CONFIG_KALLSYMS_ALL` | `y` | sterownik NVIDIA potrzebuje pełnej tablicy symboli |
| `CONFIG_DMABUF_HEAPS` | `y` | NVIDIA GSP firmware (nowsze karty RTX) |
| `CONFIG_DRM_NOUVEAU` | `n` | konflikt z proprietary driverem |
| `CONFIG_TRANSPARENT_HUGEPAGE` | `always` | wydajność pamięci GPU |
| `CONFIG_PREEMPT` | `y` | niskie opóźnienia (desktop/gaming) |
| `CONFIG_HZ` | `1000` | wysoka rozdzielczość timera |
| `-O3` | tak | optymalizacja kompilatora |

---

## GitHub Releases

Gotowe pliki `.rpm` są publikowane pod:

```
https://github.com/LegendaryOS-Linux-System/LegendaryOS-Kernel/releases/download/v<wersja>/
```

Format nazwy pliku:
```
legendaryos-kernel-<wersja>-<release>.<arch>.rpm
```

---

## Patche

Umieść pliki `*.patch` w katalogu `patches/`.  
Są stosowane alfabetycznie przez `patch -p1` przed konfiguracją.

Przykład:
```
patches/
  0001-disable-werror.patch
  0002-nvidia-dma-buf-fix.patch
```
