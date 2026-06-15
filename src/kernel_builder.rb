# frozen_string_literal: true

require "fileutils"
require_relative "utils"

# Kompiluje jądro (bzImage + modules) i instaluje do staging.
class KernelBuilder
  class Error < StandardError; end

  def initialize(cfg, log)
    @cfg     = cfg
    @log     = log
    @src     = cfg.source_dir
    @staging = File.join(cfg.build_dir, "staging")
  end

  def build
    raise Error, "Katalog źródeł nie istnieje: #{@src}" unless Dir.exist?(@src)

    check_dependencies
    compile_kernel
    compile_modules
    install_to_staging
  end

  # Zwraca ścieżkę do katalogu staging (używane przez RpmPackager)
  def staging_dir = @staging

  private

  # -------------------------------------------------------------------------
  # Sprawdzenie narzędzi
  # -------------------------------------------------------------------------
  REQUIRED_TOOLS = %w[make gcc ld as strip bc flex bison openssl pahole dwarves].freeze

  def check_dependencies
    missing = REQUIRED_TOOLS.reject { |t| Utils.command_exist?(t) }
    unless missing.empty?
      raise Error, "Brakujące narzędzia budowania: #{missing.join(', ')}\n" \
                   "Zainstaluj: sudo dnf install #{missing.join(' ')}"
    end
    @log.info "Wszystkie narzędzia dostępne."
  end

  # -------------------------------------------------------------------------
  # Kompilacja
  # -------------------------------------------------------------------------
  def make_cmd(target, extra_flags = "")
    "make -C #{@src.shellescape} #{target} " \
      "-j#{@cfg.jobs} " \
      "ARCH=#{@cfg.arch.shellescape} " \
      "#{extra_flags}"
  end

  def compile_kernel
    @log.info "Kompilacja jądra (bzImage) — #{@cfg.jobs} wątków..."
    Utils.run!(make_cmd("bzImage"), @log)
    @log.info "Kompilacja jądra zakończona."
  end

  def compile_modules
    @log.info "Kompilacja modułów..."
    Utils.run!(make_cmd("modules"), @log)
    @log.info "Kompilacja modułów zakończona."
  end

  # -------------------------------------------------------------------------
  # Instalacja do staging
  # -------------------------------------------------------------------------
  def install_to_staging
    @log.info "Instalacja do staging: #{@staging}"
    FileUtils.rm_rf(@staging)
    FileUtils.mkdir_p([@staging + "/boot", @staging + "/lib/modules"])

    # Zainstaluj moduły
    Utils.run!(
      make_cmd("modules_install", "INSTALL_MOD_PATH=#{@staging.shellescape}"),
      @log
    )

    # Skopiuj bzImage
    bzimage = File.join(@src, "arch", arch_path, "boot", "bzImage")
    raise Error, "bzImage nie znaleziony: #{bzimage}" unless File.exist?(bzimage)

    FileUtils.cp(bzimage, "#{@staging}/boot/vmlinuz-#{@cfg.full_version}")

    # Skopiuj System.map
    system_map = File.join(@src, "System.map")
    FileUtils.cp(system_map, "#{@staging}/boot/System.map-#{@cfg.full_version}") if File.exist?(system_map)

    # Skopiuj .config
    FileUtils.cp(File.join(@src, ".config"), "#{@staging}/boot/config-#{@cfg.full_version}")

    @log.info "Staging gotowy."
  end

  def arch_path
    case @cfg.arch
    when "x86_64" then "x86"
    when "aarch64" then "arm64"
    else @cfg.arch
    end
  end
end
