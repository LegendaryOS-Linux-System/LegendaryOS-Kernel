# frozen_string_literal: true

require "toml-rb"

# Wczytuje config.toml i udostępnia wartości jako metody.
# Token GitHub można nadpisać zmienną środowiskową LEGENDARYOS_GITHUB_TOKEN.
class ConfigLoader
  class Error < StandardError; end

  # CPU levels — x86_64
  CPU_LEVELS_X86 = {
    "generic" => {
      flag:    "-march=x86-64 -mtune=generic",
      clang:   "--target=x86_64-linux-gnu -march=x86_64",
      label:   "x86-64-v1 (generic — K8, Pentium 4, Core 2, wszystkie 64-bit)",
      kconfig: nil
    },
    "v2" => {
      flag:    "-march=x86-64-v2 -mtune=generic",
      clang:   "--target=x86_64-linux-gnu -march=x86-64-v2",
      label:   "x86-64-v2 (Nehalem/Westmere/Sandy/Ivy/Silvermont, Bobcat/Jaguar/Bulldozer)",
      kconfig: "CONFIG_GENERIC_CPU2"
    },
    "v3" => {
      flag:    "-march=x86-64-v3 -mtune=generic",
      clang:   "--target=x86_64-linux-gnu -march=x86-64-v3",
      label:   "x86-64-v3 (Haswell/Broadwell/Skylake/KabyLake/CoffeeLake/CometLake/Alder/Raptor, Zen/Zen+/Zen2/Zen3)",
      kconfig: "CONFIG_GENERIC_CPU3"
    },
    "v4" => {
      flag:    "-march=x86-64-v4 -mtune=generic",
      clang:   "--target=x86_64-linux-gnu -march=x86-64-v4",
      label:   "x86-64-v4 (Zen4/Zen5, Ice Lake, Tiger/Sapphire/Emerald/Rocket Lake, Arrow/Lunar Lake)",
      kconfig: "CONFIG_GENERIC_CPU4"
    }
  }.freeze

  # CPU levels — aarch64 (ARM64)
  # Hierarchia: baseline → armv8.2 → armv8.5 → armv9
  # Odpowiednik x86 v1/v2/v3/v4 — co nowszy poziom tym więcej wymaganych CPU features
  CPU_LEVELS_ARM64 = {
    "generic" => {
      flag:    "-march=armv8-a -mtune=generic",
      clang:   "--target=aarch64-linux-gnu -march=armv8-a",
      label:   "ARMv8.0-A generic (Cortex-A53/A57/A72/A73, Apple M1/M2 compat)",
      kconfig: nil
    },
    "v2" => {
      flag:    "-march=armv8.2-a+crypto+fp16+rcpc+dotprod -mtune=generic",
      clang:   "--target=aarch64-linux-gnu -march=armv8.2-a+crypto+fp16+rcpc+dotprod",
      label:   "ARMv8.2-A (Cortex-A55/A75/A76/A77/A78, Neoverse N1, Snapdragon 845+)",
      kconfig: nil
    },
    "v3" => {
      flag:    "-march=armv8.5-a+crypto+fp16+rcpc+dotprod+sve -mtune=generic",
      clang:   "--target=aarch64-linux-gnu -march=armv8.5-a+crypto+fp16+rcpc+dotprod+sve",
      label:   "ARMv8.5-A+SVE (Neoverse N2/V1, Cortex-A710/X2/X3, Snapdragon 888+)",
      kconfig: nil
    },
    "v4" => {
      flag:    "-march=armv9-a+crypto+fp16+rcpc+dotprod+sve+sve2 -mtune=generic",
      clang:   "--target=aarch64-linux-gnu -march=armv9-a+sve2",
      label:   "ARMv9-A+SVE2 (Cortex-A720/X4, Neoverse V2/V3, Snapdragon 8 Gen 2+)",
      kconfig: nil
    }
  }.freeze

  # Mapowanie arch → zestaw CPU levels
  ARCH_CPU_LEVELS = {
    "x86_64"  => CPU_LEVELS_X86,
    "aarch64" => CPU_LEVELS_ARM64
  }.freeze

  # Mapowanie arch → cross-compiler prefix (gdy budujesz na x86 pod ARM lub odwrotnie)
  CROSS_COMPILE_PREFIX = {
    "x86_64"  => "x86_64-linux-gnu-",
    "aarch64" => "aarch64-linux-gnu-"
  }.freeze

  # Mapowanie arch → nazwa arch w kernelu Linuxa (ARCH= w make)
  KERNEL_ARCH = {
    "x86_64"  => "x86",
    "aarch64" => "arm64"
  }.freeze

  # Mapowanie arch → ścieżka do skompilowanego obrazu jądra
  KERNEL_IMAGE_PATH = {
    "x86_64"  => "arch/x86/boot/bzImage",
    "aarch64" => "arch/arm64/boot/Image"
  }.freeze

  # Mapowanie arch → nazwa obrazu w /boot
  KERNEL_IMAGE_NAME = {
    "x86_64"  => "vmlinuz",
    "aarch64" => "Image"
  }.freeze

  SUPPORTED_ARCHS = ARCH_CPU_LEVELS.keys.freeze

  attr_reader :raw

  # --- Kernel ---
  def kernel_version    = @raw.dig("kernel", "version")     || raise(Error, "brak kernel.version")
  def localversion      = @raw.dig("kernel", "localversion") || "-legendaryos"
  def release_tag       = @raw.dig("kernel", "release_tag")  || "1.legendaryos"

  def arch
    a = @raw.dig("kernel", "arch") || "x86_64"
    raise Error, "Nieznana arch: #{a}. Dozwolone: #{SUPPORTED_ARCHS.join(', ')}" unless SUPPORTED_ARCHS.include?(a)
    a
  end

  # Arch w notacji kernela Linuxa (ARCH= w make)
  def kernel_arch       = KERNEL_ARCH[arch]

  # Prefix cross-compilera
  def cross_compile_prefix = CROSS_COMPILE_PREFIX[arch]

  # Czy budujemy na innej architekturze niż cel (cross-compilation)?
  def cross_compile?
    host_arch = `uname -m`.strip
    # uname -m zwraca "x86_64" lub "aarch64"
    host_arch != arch
  end

  # Ścieżka do skompilowanego obrazu kernela w drzewie źródeł
  def kernel_image_src  = KERNEL_IMAGE_PATH[arch]

  # Nazwa pliku obrazu w /boot
  def kernel_image_name = KERNEL_IMAGE_NAME[arch]

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
  def cpu_levels        = ARCH_CPU_LEVELS[arch]

  def cpu_level
    lvl = @raw.dig("build", "cpu_level") || "v3"
    raise Error, "Nieznany cpu_level: #{lvl} dla arch #{arch}. Dozwolone: #{cpu_levels.keys.join(', ')}" unless cpu_levels.key?(lvl)
    lvl
  end
  def cpu_level_info    = cpu_levels[cpu_level]
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
  # NVIDIA proprietary driver istnieje tylko na x86_64
  def nvidia_enabled?
    return false if arch != "x86_64"
    @raw.dig("nvidia", "enable") != false
  end
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

  # Pełna lokalna wersja wg uname -r: np. 7.1-legendaryos
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
