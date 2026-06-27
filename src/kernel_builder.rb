# frozen_string_literal: true

require "fileutils"
require_relative "utils"

# Kompiluje jądro Linuxa ze skonfigurowanego drzewa źródeł.
# Oczekuje że KernelConfigurator już przygotował .config.
# Instaluje skompilowane pliki do staging_dir gotowego pod rpmbuild.
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
    raise Error, "Brak .config w #{@src}" unless File.exist?(File.join(@src, ".config"))

    compile
    install_to_staging
  end

  private

  def compile
    jobs = @cfg.jobs
    @log.info "Kompilacja jądra (make -j#{jobs})..."

    compiler_env = if @cfg.compiler == "clang"
      "CC=clang LLVM=1 LLVM_IAS=1"
    else
      "CC=gcc"
    end

    Utils.run!(
      "make -C #{@src.shellescape} -j#{jobs} #{compiler_env} bzImage modules 2>&1",
      @log
    )
    @log.info "Kompilacja zakończona."
  end

  def install_to_staging
    kver    = @cfg.full_version
    boot    = File.join(@staging, "boot")
    modules = File.join(@staging, "lib", "modules", kver)

    FileUtils.mkdir_p(boot)
    FileUtils.mkdir_p(modules)

    # vmlinuz
    vmlinuz_src = File.join(@src, "arch", "x86", "boot", "bzImage")
    raise Error, "Brak bzImage po kompilacji: #{vmlinuz_src}" unless File.exist?(vmlinuz_src)
    FileUtils.cp(vmlinuz_src, File.join(boot, "vmlinuz-#{kver}"))
    @log.info "  → vmlinuz-#{kver}"

    # System.map
    sysmap_src = File.join(@src, "System.map")
    if File.exist?(sysmap_src)
      FileUtils.cp(sysmap_src, File.join(boot, "System.map-#{kver}"))
      @log.info "  → System.map-#{kver}"
    end

    # .config
    FileUtils.cp(File.join(@src, ".config"), File.join(boot, "config-#{kver}"))
    @log.info "  → config-#{kver}"

    # Moduły
    @log.info "Instalowanie modułów do #{modules}..."
    Utils.run!(
      "make -C #{@src.shellescape} -j#{@cfg.jobs} modules_install INSTALL_MOD_PATH=#{@staging.shellescape} INSTALL_MOD_STRIP=1",
      @log
    )

    @log.info "Staging gotowy: #{@staging}"
  end
end
