# frozen_string_literal: true

require "toml-rb"

# Wczytuje config.toml i udostępnia wartości jako metody.
# Token GitHub można nadpisać zmienną środowiskową LEGENDARYOS_GITHUB_TOKEN.
class ConfigLoader
  class Error < StandardError; end

  # CPU levels — mapowanie poziomu na flagę GCC/Clang i opis
  CPU_LEVELS = {
    "generic" => {
      flag:    "-march=x86-64 -mtune=generic",
      clang:   "--target=x86_64-linux-gnu -march=x86_64",
      label:   "x86-64-v1 (generic — K8, Pentium 4, Core 2, wszystkie 64-bit)",
      kconfig: nil   # brak specyficznego CONFIG_ — domyślne jądro
    },
    "v2" => {
      flag:    "-march=x86-64-v2 -mtune=generic",
      clang:   "--target=x86_64-linux-gnu -march=x86-64-v2",
      label:   "x86-64-v2 (Nehalem/Westmere/Sandy/Ivy/Silvermont, Bobcat/Jaguar/Bulldozer/Piledriver/Steamroller)",
      kconfig: "CONFIG_GENERIC_CPU2"
    },
    "v3" => {
      flag:    "-march=x86-64-v3 -mtune=generic",
      clang:   "--target=x86_64-linux-gnu -march=x86-64-v3",
      label:   "x86-64-v3 (Haswell/Broadwell/Skylake/KabyLake/CoffeeLake/CometLake/Alder/Raptor, Excavator/Zen/Zen+/Zen2/Zen3)",
      kconfig: "CONFIG_GENERIC_CPU3"
    },
    "v4" => {
      flag:    "-march=x86-64-v4 -mtune=generic",
      clang:   "--target=x86_64-linux-gnu -march=x86-64-v4",
      label:   "x86-64-v4 (Zen4/Zen5, Skylake-X, Cannon Lake, Ice Lake, Cascade/Cooper Lake, Tiger/Sapphire/Emerald/Rocket Lake, Arrow/Lunar Lake)",
      kconfig: "CONFIG_GENERIC_CPU4"
    }
  }.freeze

  attr_reader :raw

  # --- Kernel ---
  def kernel_version    = @raw.dig("kernel", "version")     || raise(Error, "brak kernel.version")
  def localversion      = @raw.dig("kernel", "localversion") || "-legendaryos"
  def arch              = @raw.dig("kernel", "arch")         || "x86_64"
  def release_tag       = @raw.dig("kernel", "release_tag")  || "1.legendaryos"

  # --- Build ---
  def jobs
    j = @raw.dig("build", "jobs").to_i
    j.zero? ? `nproc`.strip.to_i : j
  end
  def build_dir         = @raw.dig("build", "build_dir")    || "/tmp/legendaryos-kernel-build"
  def output_dir        = @raw.dig("build", "output_dir")   || "./output"
  def patches_dir       = @raw.dig("build", "patches_dir")  || "./patches"
  def base_config       = @raw.dig("build", "base_config")  || "fedora"
  def optimize_o3?      = @raw.dig("build", "optimize_o3")  != false
  def clean_build?      = @raw.dig("build", "clean_build")  != false
  def compiler          = @raw.dig("build", "compiler")     || "gcc"
  def lto_thin?         = @raw.dig("build", "lto_thin")     == true && compiler == "clang"

  # --- CPU level ---
  def cpu_level
    lvl = @raw.dig("build", "cpu_level") || "v3"
    raise Error, "Nieznany cpu_level: #{lvl}. Dozwolone: #{CPU_LEVELS.keys.join(', ')}" unless CPU_LEVELS.key?(lvl)
    lvl
  end
  def cpu_level_info    = CPU_LEVELS[cpu_level]
  def cpu_march_flag    = compiler == "clang" ? cpu_level_info[:clang] : cpu_level_info[:flag]
  def cpu_level_label   = cpu_level_info[:label]
  def cpu_kconfig       = cpu_level_info[:kconfig]

  # --- Gaming optimizations ---
  def bore_scheduler?       = @raw.dig("gaming", "bore_scheduler")    != false
  def sched_ext?            = @raw.dig("gaming", "sched_ext")         != false
  def ntsync?               = @raw.dig("gaming", "ntsync")            != false
  def bbr3?                 = @raw.dig("gaming", "bbr3")              != false
  def valve_vram_patches?   = @raw.dig("gaming", "valve_vram_patches") != false
  def auto_fetch_patches?   = @raw.dig("gaming", "auto_fetch_patches") != false

  # --- NVIDIA ---
  def nvidia_enabled?           = @raw.dig("nvidia", "enable")                != false
  def disable_module_signing?   = @raw.dig("nvidia", "disable_module_signing") != false
  def kallsyms_all?             = @raw.dig("nvidia", "kallsyms_all")           != false
  def dmabuf_heaps?             = @raw.dig("nvidia", "dmabuf_heaps")           != false

  # --- GitHub ---
  def github_token
    ENV["LEGENDARYOS_GITHUB_TOKEN"] ||
      @raw.dig("github", "token")&.then { |t| t.empty? ? nil : t } ||
      raise(Error, "Brak tokenu GitHub. Ustaw LEGENDARYOS_GITHUB_TOKEN lub github.token w config.toml")
  end
  def github_owner      = @raw.dig("github", "owner") || "LegendaryOS-Linux-System"
  def github_repo       = @raw.dig("github", "repo")  || "LegendaryOS-Kernel"
  def download_url_template = @raw.dig("github", "download_url") || ""

  def download_url
    download_url_template
      .gsub("{version}", kernel_version)
      .gsub("{arch}",    arch)
  end

  # Pełna lokalna wersja wg uname -r: np. 6.14.6-legendaryos
  def full_version      = "#{kernel_version}#{localversion}"

  # Katalog ze źródłami po rozpakowaniu
  def source_dir        = File.join(build_dir, "linux-#{kernel_version}")

  # --- Factory ---
  def self.load(path)
    raise Error, "Plik config.toml nie istnieje: #{path}" unless File.exist?(path)

    begin
      raw = TomlRB.load_file(path)
    rescue TomlRB::ParseError => e
      raise Error, "Błąd parsowania TOML: #{e.message}"
    end

    new(raw)
  end

  private

  def initialize(raw)
    @raw = raw
  end
end
