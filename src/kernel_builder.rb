# frozen_string_literal: true

require "fileutils"
require_relative "utils"

# Kompiluje jądro (bzImage + modules) z obsługą GCC i Clang/LTO.
# Instaluje do katalogu staging używanego przez RpmPackager.
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

  def staging_dir = @staging

  private

  # ===========================================================================
  # Sprawdzenie narzędzi
  # ===========================================================================
  GCC_TOOLS   = %w[make gcc ld as strip bc flex bison openssl pahole].freeze
  CLANG_TOOLS = %w[make clang lld llvm-strip bc flex bison openssl pahole].freeze

  def check_dependencies
    tools = @cfg.compiler == "clang" ? CLANG_TOOLS : GCC_TOOLS
    missing = tools.reject { |t| Utils.command_exist?(t) }

    unless missing.empty?
      pkg_hint = missing.map { |t|
        { "pahole" => "dwarves", "openssl" => "openssl-devel" }.fetch(t, t)
      }.join(" ")
      raise Error, "Brakujące narzędzia: #{missing.join(', ')}\n" \
                   "Zainstaluj: sudo dnf install #{pkg_hint}"
    end

    @log.info "Wszystkie narzędzia dostępne (#{@cfg.compiler})."
  end

  # ===========================================================================
  # Flagi kompilatora
  # ===========================================================================
  def compiler_flags
    case @cfg.compiler
    when "clang"
      flags  = "CC=clang CXX=clang++ LD=ld.lld AR=llvm-ar NM=llvm-nm "
      flags += "STRIP=llvm-strip OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump "
      flags += "LLVM=1 LLVM_IAS=1 "
      flags += "KCFLAGS=\"#{@cfg.cpu_march_flag}\" "
      flags
    else
      # GCC — flagi CPU wstrzyknięte do Makefile przez KernelConfigurator
      ""
    end
  end

  # ===========================================================================
  # make helper
  # ===========================================================================
  def make_cmd(target, extra = "")
    "make -C #{@src.shellescape} #{target} " \
      "-j#{@cfg.jobs} " \
      "ARCH=#{@cfg.arch.shellescape} " \
      "#{compiler_flags} " \
      "#{extra}".strip
  end

  # ===========================================================================
  # Kompilacja
  # ===========================================================================
  def compile_kernel
    @log.info "Kompilacja bzImage — #{@cfg.jobs} wątków / #{@cfg.compiler} / CPU #{@cfg.cpu_level}..."
    Utils.run!(make_cmd("bzImage"), @log)
    @log.info "bzImage gotowy."
  end

  def compile_modules
    @log.info "Kompilacja modułów..."
    Utils.run!(make_cmd("modules"), @log)
    @log.info "Moduły gotowe."
  end

  # ===========================================================================
  # Instalacja do staging
  # ===========================================================================
  def install_to_staging
    @log.info "Instalacja do staging: #{@staging}"
    FileUtils.rm_rf(@staging)
    FileUtils.mkdir_p(["#{@staging}/boot", "#{@staging}/lib/modules"])

    # Moduły
    Utils.run!(
      make_cmd("modules_install", "INSTALL_MOD_PATH=#{@staging.shellescape}"),
      @log
    )

    # bzImage → vmlinuz
    bzimage = File.join(@src, "arch", arch_subdir, "boot", "bzImage")
    raise Error, "bzImage nie znaleziony: #{bzimage}" unless File.exist?(bzimage)
    FileUtils.cp(bzimage, "#{@staging}/boot/vmlinuz-#{@cfg.full_version}")

    # System.map
    sysmap = File.join(@src, "System.map")
    FileUtils.cp(sysmap, "#{@staging}/boot/System.map-#{@cfg.full_version}") if File.exist?(sysmap)

    # .config
    FileUtils.cp(File.join(@src, ".config"), "#{@staging}/boot/config-#{@cfg.full_version}")

    # Usuń linki symlink do build/source (nie potrzebne w RPM, zajmują miejsce)
    mod_dir = "#{@staging}/lib/modules/#{@cfg.full_version}"
    ["build", "source"].each do |link|
      path = "#{mod_dir}/#{link}"
      File.unlink(path) if File.symlink?(path)
    end

    @log.info "Staging gotowy: #{@staging}"
  end

  def arch_subdir
    case @cfg.arch
    when "x86_64"  then "x86"
    when "aarch64" then "arm64"
    else @cfg.arch
    end
  end
end
