# frozen_string_literal: true

require "toml-rb"

# Wczytuje config.toml i udostępnia wartości jako metody.
# Token GitHub można nadpisać zmienną środowiskową LEGENDARYOS_GITHUB_TOKEN.
class ConfigLoader
  class Error < StandardError; end

  attr_reader :raw

  # --- Kernel ---
  def kernel_version   = @raw.dig("kernel", "version")    || raise(Error, "brak kernel.version")
  def localversion     = @raw.dig("kernel", "localversion") || "-legendaryos"
  def arch             = @raw.dig("kernel", "arch")        || "x86_64"
  def release_tag      = @raw.dig("kernel", "release_tag") || "1.legendaryos"

  # --- Build ---
  def jobs
    j = @raw.dig("build", "jobs").to_i
    j.zero? ? `nproc`.strip.to_i : j
  end
  def build_dir        = @raw.dig("build", "build_dir")    || "/tmp/legendaryos-kernel-build"
  def output_dir       = @raw.dig("build", "output_dir")   || "./output"
  def patches_dir      = @raw.dig("build", "patches_dir")  || "./patches"
  def base_config      = @raw.dig("build", "base_config")  || "fedora"
  def optimize_o3?     = @raw.dig("build", "optimize_o3")  != false
  def clean_build?     = @raw.dig("build", "clean_build")  != false

  # --- NVIDIA ---
  def nvidia_enabled?          = @raw.dig("nvidia", "enable")                != false
  def disable_module_signing?  = @raw.dig("nvidia", "disable_module_signing") != false
  def kallsyms_all?            = @raw.dig("nvidia", "kallsyms_all")           != false
  def dmabuf_heaps?            = @raw.dig("nvidia", "dmabuf_heaps")           != false

  # --- GitHub ---
  def github_token
    ENV["LEGENDARYOS_GITHUB_TOKEN"] ||
      @raw.dig("github", "token")&.then { |t| t.empty? ? nil : t } ||
      raise(Error, "Brak tokenu GitHub. Ustaw LEGENDARYOS_GITHUB_TOKEN lub github.token w config.toml")
  end
  def github_owner     = @raw.dig("github", "owner") || "LegendaryOS-Linux-System"
  def github_repo      = @raw.dig("github", "repo")  || "LegendaryOS-Kernel"
  def download_url_template = @raw.dig("github", "download_url") || ""

  def download_url
    download_url_template
      .gsub("{version}", kernel_version)
      .gsub("{arch}",    arch)
  end

  # Pełna lokalna wersja wg uname -r: np. 6.12.6-legendaryos
  def full_version = "#{kernel_version}#{localversion}"

  # Katalog ze źródłami po rozpakowaniu
  def source_dir = File.join(build_dir, "linux-#{kernel_version}")

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
