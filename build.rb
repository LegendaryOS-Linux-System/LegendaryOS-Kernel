#!/usr/bin/env ruby
# frozen_string_literal: true

# =============================================================================
#  LegendaryOS Kernel — główny skrypt budowania

$LOAD_PATH.unshift File.join(__dir__, "src")

require "optparse"
require "logger"

require "config_loader"
require "kernel_fetcher"
require "kernel_configurator"
require "kernel_builder"
require "rpm_packager"
require "github_releaser"
require "utils"

# ---------------------------------------------------------------------------
# Logger
# ---------------------------------------------------------------------------
LOG = Logger.new($stdout)
LOG.formatter = proc do |severity, _time, _prog, msg|
  colors = { "DEBUG" => "\e[36m", "INFO" => "\e[32m",
             "WARN"  => "\e[33m", "ERROR" => "\e[31m", "FATAL" => "\e[35m" }
  reset  = "\e[0m"
  "#{colors.fetch(severity, '')}[#{severity}]#{reset} #{msg}\n"
end
LOG.level = Logger::INFO

# ---------------------------------------------------------------------------
# Parsowanie argumentów
# ---------------------------------------------------------------------------
options = {
  config_path:    File.join(__dir__, "config.toml"),
  release:        false,
  skip_download:  false,
  skip_build:     false,
  only_spec:      false,
  cpu_level:      nil
}

OptionParser.new do |opts|
  opts.banner = <<~BANNER
    LegendaryOS Kernel Build System
    Użycie: ruby build.rb [opcje]
  BANNER

  opts.on("--config PATH",       "Ścieżka do config.toml")               { |v| options[:config_path] = v }
  opts.on("--release",           "Utwórz GitHub Release po budowie")      { options[:release] = true }
  opts.on("--skip-download",     "Pomiń pobieranie źródeł")               { options[:skip_download] = true }
  opts.on("--skip-build",        "Pomiń kompilację kernela")              { options[:skip_build] = true }
  opts.on("--only-spec",         "Tylko wygeneruj specfile")               { options[:only_spec] = true }
  opts.on("--cpu-level LEVEL",   "Nadpisz poziom CPU (generic/v2/v3/v4)") { |v| options[:cpu_level] = v }

  opts.on("--list-cpu-levels", "Lista poziomów CPU i obsługiwanych procesorów") do
    puts <<~TABLE
      ┌─────────────────────────────────────────────────────────────────────────────┐
      │               LegendaryOS Kernel — Poziomy CPU (x86-64)                    │
      ├──────────┬──────────────────────────────────────────────────────────────────┤
      │ Poziom   │ Obsługiwane procesory                                            │
      ├──────────┼──────────────────────────────────────────────────────────────────┤
      │ generic  │ Wszystkie 64-bitowe CPU:                                         │
      │ (v1)     │  AMD: K8, K10, Family 10h (Barcelona)                           │
      │          │  Intel: Pentium 4/Xeon Nocona, Core 2 (wszystkie warianty)      │
      ├──────────┼──────────────────────────────────────────────────────────────────┤
      │ v2       │  AMD: Bobcat (Fam14h), Jaguar (Fam16h), Bulldozer (Fam15h),    │
      │          │       Piledriver (Fam15h), Steamroller (Fam15h)                 │
      │          │  Intel: Nehalem (1st Gen), Westmere (1.5 Gen),                  │
      │          │         Sandy Bridge (2nd), Ivy Bridge (3rd),                   │
      │          │         Silvermont (low-power), Goldmont (Apollo/Denverton),    │
      │          │         Goldmont Plus (Gemini Lake)                              │
      ├──────────┼──────────────────────────────────────────────────────────────────┤
      │ v3       │  AMD: Excavator (Fam15h), Zen/Zen+ (Fam17h),                   │
      │          │       Zen 2 (Fam17h), Zen 3 (Fam19h)                           │
      │          │  Intel: Haswell (4th), Broadwell (5th), Skylake (6th),          │
      │          │         Kaby Lake (7th), Coffee Lake (8/9th),                   │
      │          │         Comet Lake (10th), Alder Lake (12th),                   │
      │          │         Raptor Lake (13th/14th), Lunar/Arrow Lake (15th)        │
      ├──────────┼──────────────────────────────────────────────────────────────────┤
      │ v4       │  AMD: Zen 4 / Zen 4c (Fam19h), Zen 5 / Zen 5c (Fam1Ah)       │
      │          │  Intel: Skylake-X, Cannon Lake (8th i3), Ice Lake (Xeon/10th), │
      │          │         Cascade Lake, Cooper Lake, Tiger Lake (3rd 10nm++),     │
      │          │         Sapphire Rapids (4th), Emerald Rapids (5th),            │
      │          │         Rocket Lake (11th)                                      │
      └──────────┴──────────────────────────────────────────────────────────────────┘

      Wybierz najwyższy poziom obsługiwany przez WSZYSTKIE maszyny docelowe.
      Np. jeśli chcesz wspierać Sandy Bridge i Skylake → użyj v2.
      Dla dystrybucji publicznej → generic lub v2.
      Dla własnego systemu z Ryzen 5000 / Intel 12th+ → v3.
    TABLE
    exit 0
  end

  opts.on("--help", "Wyświetl pomoc") { puts opts; exit 0 }
end.parse!

# ---------------------------------------------------------------------------
# Wczytaj konfigurację i nadpisz opcje z CLI
# ---------------------------------------------------------------------------
begin
  cfg = ConfigLoader.load(options[:config_path])
rescue ConfigLoader::Error => e
  LOG.error "Błąd konfiguracji: #{e.message}"
  exit 1
end

# Nadpisz cpu_level jeśli podany przez CLI
if options[:cpu_level]
  unless ConfigLoader::CPU_LEVELS.key?(options[:cpu_level])
    LOG.error "Nieznany --cpu-level: #{options[:cpu_level]}. Dozwolone: #{ConfigLoader::CPU_LEVELS.keys.join(', ')}"
    exit 1
  end
  # Monkey-patch instancji — nadpisz metodę cpu_level
  cpu_override = options[:cpu_level]
  cfg.define_singleton_method(:cpu_level) { cpu_override }
end

# ---------------------------------------------------------------------------
# Baner startowy
# ---------------------------------------------------------------------------
LOG.info "╔══════════════════════════════════════════════════════════════╗"
LOG.info "║          LegendaryOS Kernel Build System                    ║"
LOG.info "╠══════════════════════════════════════════════════════════════╣"
LOG.info "║  Kernel:    #{cfg.full_version.ljust(49)}║"
LOG.info "║  Arch:      #{cfg.arch.ljust(49)}║"
LOG.info "║  CPU level: #{cfg.cpu_level_label[0..48].ljust(49)}║"
LOG.info "║  Compiler:  #{cfg.compiler.ljust(49)}║"
LOG.info "║  LTO Thin:  #{cfg.lto_thin?.to_s.ljust(49)}║"
LOG.info "║  BORE:      #{cfg.bore_scheduler?.to_s.ljust(49)}║"
LOG.info "║  NTSYNC:    #{cfg.ntsync?.to_s.ljust(49)}║"
LOG.info "║  sched_ext: #{cfg.sched_ext?.to_s.ljust(49)}║"
LOG.info "║  BBR v3:    #{cfg.bbr3?.to_s.ljust(49)}║"
LOG.info "║  Valve VRAM:#{cfg.valve_vram_patches?.to_s.ljust(49)}║"
LOG.info "╚══════════════════════════════════════════════════════════════╝"

# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------
begin
  # 1. Pobierz źródła
  unless options[:skip_download]
    LOG.info "--- [1/5] Pobieranie źródeł kernel.org ---"
    KernelFetcher.new(cfg, LOG).fetch
  end

  if options[:only_spec]
    LOG.info "--- Generowanie specfile (--only-spec) ---"
    RpmPackager.new(cfg, LOG).write_spec
    LOG.info "Gotowe."
    exit 0
  end

  # 2. Konfiguracja (.config + patche + optymalizacje)
  unless options[:skip_build]
    LOG.info "--- [2/5] Konfiguracja jądra ---"
    KernelConfigurator.new(cfg, LOG).configure
  end

  # 3. Kompilacja
  unless options[:skip_build]
    LOG.info "--- [3/5] Kompilacja jądra ---"
    KernelBuilder.new(cfg, LOG).build
  end

  # 4. Pakowanie RPM
  LOG.info "--- [4/5] Pakowanie RPM ---"
  rpms = RpmPackager.new(cfg, LOG).build_rpm

  LOG.info "Gotowe pliki RPM:"
  rpms.each { |r| LOG.info "  #{r}" }

  # 5. GitHub Release
  if options[:release]
    LOG.info "--- [5/5] GitHub Release v#{cfg.kernel_version} ---"
    url = GithubReleaser.new(cfg, LOG).release(rpms)
    LOG.info "Release opublikowany: #{url}"
  end

  LOG.info "╔══════════════════════════════╗"
  LOG.info "║       BUILD SUKCES! 🚀       ║"
  LOG.info "╚══════════════════════════════╝"

rescue KernelFetcher::Error    => e; LOG.error "Pobieranie: #{e.message}";   exit 2
rescue KernelBuilder::Error    => e; LOG.error "Kompilacja: #{e.message}";   exit 3
rescue RpmPackager::Error      => e; LOG.error "RPM: #{e.message}";          exit 4
rescue GithubReleaser::Error   => e; LOG.error "GitHub: #{e.message}";       exit 5
rescue ConfigLoader::Error     => e; LOG.error "Config: #{e.message}";       exit 1
rescue Interrupt
  LOG.warn "Przerwano przez użytkownika."
  exit 130
end
