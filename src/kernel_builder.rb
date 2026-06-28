# frozen_string_literal: true

require "fileutils"
require_relative "utils"

# Kompiluje jądro Linuxa ze skonfigurowanego drzewa źródeł.
# Obsługuje x86_64 (natywnie) i aarch64 (cross-kompilacja z x86_64).
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

    log_build_info
    compile
    install_to_staging
  end

  private

  def log_build_info
    mode = @cfg.cross_compile? ? "cross-compile #{host_arch} → #{@cfg.arch}" : "natywnie"
    @log.info "Kompilacja: #{mode}"
    @log.info "  ARCH=#{@cfg.kernel_arch} CROSS_COMPILE=#{cross_compile_prefix}"
  end

  # Zwraca zmienne środowiskowe make wspólne dla compile i modules_install
  def make_env
    env = "ARCH=#{@cfg.kernel_arch.shellescape}"
    env += " CROSS_COMPILE=#{cross_compile_prefix.shellescape}" if @cfg.cross_compile?

    if @cfg.compiler == "clang"
      env += " CC=clang LLVM=1 LLVM_IAS=1"
    else
      if @cfg.cross_compile?
        # GCC cross-compiler: np. aarch64-linux-gnu-gcc
        env += " CC=#{cross_compile_prefix}gcc"
      else
        env += " CC=gcc"
      end
    end
    env
  end

  def cross_compile_prefix
    @cfg.cross_compile? ? @cfg.cross_compile_prefix : ""
  end

  def host_arch
    `uname -m`.strip
  end

  def compile
    jobs = @cfg.jobs
    # Cel kompilacji zależny od arch:
    #   x86_64  → bzImage modules
    #   aarch64 → Image modules (aarch64 nie ma bzImage — płaski obraz)
    target = case @cfg.arch
             when "x86_64"  then "bzImage modules"
             when "aarch64" then "Image modules"
             else raise Error, "Nieznana arch: #{@cfg.arch}"
             end

    @log.info "Kompilacja jądra (make -j#{jobs} #{target})..."
    Utils.run!(
      "make -C #{@src.shellescape} -j#{jobs} #{make_env} #{target} 2>&1",
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

    # Obraz kernela — ścieżka i nazwa zależne od arch
    image_src  = File.join(@src, @cfg.kernel_image_src)
    image_name = "#{@cfg.kernel_image_name}-#{kver}"
    raise Error, "Brak obrazu kernela po kompilacji: #{image_src}" unless File.exist?(image_src)
    FileUtils.cp(image_src, File.join(boot, image_name))
    @log.info "  → #{image_name}"

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
      "make -C #{@src.shellescape} -j#{@cfg.jobs} #{make_env} modules_install " \
      "INSTALL_MOD_PATH=#{@staging.shellescape} INSTALL_MOD_STRIP=1",
      @log
    )

    # modules_install tworzy symlinki build/ i source/ wskazujące na drzewo
    # źródeł na maszynie buildowej — są dangling na docelowym systemie
    # i powodują błąd rpmbuild "Installed (but unpackaged) file(s) found".
    %w[build source].each do |link|
      path = File.join(modules, link)
      if File.symlink?(path) || File.exist?(path)
        FileUtils.rm_rf(path)
        @log.info "  → usunięto #{link}/ symlink z staging (dangling po modules_install)"
      end
    end

    @log.info "Staging gotowy: #{@staging}"
  end
end
