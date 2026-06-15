# frozen_string_literal: true

require "fileutils"
require_relative "utils"

# Tworzy .config dla jądra:
#   1. Pobiera bazową konfigurację Fedory lub kopiuje własną
#   2. Stosuje patche z katalogu patches/
#   3. Nakłada tweaki NVIDIA-friendly
#   4. Ustawia lokalversion
#   5. Odpowiada na nowe symbole (make olddefconfig)
class KernelConfigurator
  class Error < StandardError; end

  def initialize(cfg, log)
    @cfg = cfg
    @log = log
    @src = cfg.source_dir
  end

  def configure
    raise Error, "Katalog źródeł nie istnieje: #{@src}" unless Dir.exist?(@src)

    apply_base_config
    apply_patches
    apply_nvidia_tweaks if @cfg.nvidia_enabled?
    apply_optimization_tweaks
    set_localversion
    finalize_config
  end

  private

  # -------------------------------------------------------------------------
  # Baza konfiguracji
  # -------------------------------------------------------------------------
  def apply_base_config
    if @cfg.base_config == "fedora"
      fetch_fedora_config
    else
      custom = File.expand_path(@cfg.base_config)
      raise Error, "Plik .config nie istnieje: #{custom}" unless File.exist?(custom)

      @log.info "Kopiowanie własnego .config z #{custom}"
      FileUtils.cp(custom, dot_config)
    end
  end

  def fetch_fedora_config
    # Pobierz .config z aktualnie działającego Fedora kernela (jeśli dostępne)
    running_config = "/boot/config-#{`uname -r`.strip}"
    if File.exist?(running_config)
      @log.info "Kopiowanie .config z działającego jądra Fedory: #{running_config}"
      FileUtils.cp(running_config, dot_config)
    else
      @log.warn "Nie znaleziono /boot/config-$(uname -r) — próba pobrania z kojec Fedory..."
      fedora_config_url = "https://src.fedoraproject.org/rpms/kernel/raw/main/f/kernel-#{@cfg.arch}.config"
      Utils.run!("curl -L -s -o #{dot_config.shellescape} #{fedora_config_url.shellescape}", @log)
      raise Error, "Pobieranie .config Fedory nie powiodło się" unless File.exist?(dot_config) && File.size(dot_config) > 1024
    end
    @log.info "Baza .config Fedory gotowa."
  end

  # -------------------------------------------------------------------------
  # Patche
  # -------------------------------------------------------------------------
  def apply_patches
    patches_dir = File.expand_path(@cfg.patches_dir)
    unless Dir.exist?(patches_dir)
      @log.info "Brak katalogu patches/, pomijam patche."
      return
    end

    patches = Dir[File.join(patches_dir, "*.patch")].sort
    if patches.empty?
      @log.info "Brak plików *.patch w #{patches_dir}."
      return
    end

    @log.info "Stosowanie #{patches.size} patch(y)..."
    patches.each do |patch|
      @log.info "  patch: #{File.basename(patch)}"
      Utils.run!(
        "patch -d #{@src.shellescape} -p1 --forward --no-backup-if-mismatch < #{patch.shellescape}",
        @log
      )
    end
  end

  # -------------------------------------------------------------------------
  # Tweaki NVIDIA / akmod
  # -------------------------------------------------------------------------
  NVIDIA_OPTIONS = {
    # Podpisywanie modułów — akmod nie korzysta z podpisanych modułów
    "CONFIG_MODULE_SIG"              => :disable,
    "CONFIG_MODULE_SIG_ALL"          => :disable,
    "CONFIG_MODULE_SIG_FORCE"        => :disable,

    # Symbole wymagane przez sterownik NVIDIA
    "CONFIG_KALLSYMS_ALL"            => :enable,

    # DMA-BUF Heaps — wymagane przez NVIDIA GSP
    "CONFIG_DMABUF_HEAPS"            => :enable,
    "CONFIG_DMABUF_HEAPS_SYSTEM"     => :enable,
    "CONFIG_DMABUF_HEAPS_CMA"        => :enable,

    # Unified Memory (nvidia-uvm)
    "CONFIG_IOMMU_API"               => :enable,

    # Tryb graficzny — wymagany przez nvidia-drm
    "CONFIG_DRM"                     => :enable,
    "CONFIG_DRM_KMS_HELPER"          => :enable,

    # Wyłącz Nouveau — konflikt z NVIDIA proprietary
    "CONFIG_DRM_NOUVEAU"             => :disable,

    # PCIe / ACPI — wymagane dla GPUs
    "CONFIG_HOTPLUG_PCI"             => :enable,
    "CONFIG_ACPI"                    => :enable,
    "CONFIG_PCI_MSI"                 => :enable
  }.freeze

  def apply_nvidia_tweaks
    @log.info "Stosowanie tweaków konfiguracji NVIDIA/akmod..."

    tweaks = NVIDIA_OPTIONS.dup
    tweaks["CONFIG_MODULE_SIG"]     = :disable if @cfg.disable_module_signing?
    tweaks["CONFIG_KALLSYMS_ALL"]   = :enable  if @cfg.kallsyms_all?
    tweaks["CONFIG_DMABUF_HEAPS"]   = :enable  if @cfg.dmabuf_heaps?

    apply_config_options(tweaks)
  end

  # -------------------------------------------------------------------------
  # Optymalizacje
  # -------------------------------------------------------------------------
  OPTIMIZATION_TWEAKS = {
    # Wydajność schedulera
    "CONFIG_HZ_1000"           => :enable,
    "CONFIG_HZ"                => "1000",
    "CONFIG_HZ_300"            => :disable,
    "CONFIG_HZ_250"            => :disable,

    # Preemption — PREEMPT dla desktopa
    "CONFIG_PREEMPT"           => :enable,
    "CONFIG_PREEMPT_VOLUNTARY" => :disable,
    "CONFIG_PREEMPT_NONE"      => :disable,

    # Thin LTO (clang) — pomiń jeśli gcc
    # "CONFIG_LTO_CLANG_THIN"  => :enable,

    # Zbędne debugi (spowalniają kernel)
    "CONFIG_DEBUG_KERNEL"      => :disable,
    "CONFIG_DEBUG_INFO"        => :disable,
    "CONFIG_DEBUG_INFO_DWARF4" => :disable,
    "CONFIG_KASAN"             => :disable,
    "CONFIG_UBSAN"             => :disable,

    # Hugepages — dobre dla sterownika NVIDIA i gier
    "CONFIG_TRANSPARENT_HUGEPAGE"        => :enable,
    "CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS" => :enable
  }.freeze

  def apply_optimization_tweaks
    @log.info "Stosowanie optymalizacji konfiguracji..."
    apply_config_options(OPTIMIZATION_TWEAKS)

    if @cfg.optimize_o3?
      @log.info "Włączanie optymalizacji -O3..."
      # Zamień -O2 na -O3 w Makefile (top-level)
      makefile = File.join(@src, "Makefile")
      content  = File.read(makefile)
      patched  = content.gsub(/\-O2\b/, "-O3")
      File.write(makefile, patched) unless content == patched
    end
  end

  # -------------------------------------------------------------------------
  # LOCALVERSION
  # -------------------------------------------------------------------------
  def set_localversion
    @log.info "Ustawianie LOCALVERSION=#{@cfg.localversion}"
    set_config_option("CONFIG_LOCALVERSION", "\"#{@cfg.localversion}\"")
    set_config_option("CONFIG_LOCALVERSION_AUTO", :disable)
  end

  # -------------------------------------------------------------------------
  # Finalizacja
  # -------------------------------------------------------------------------
  def finalize_config
    @log.info "Uruchamianie make olddefconfig (akceptacja nowych symboli)..."
    Utils.run!("make -C #{@src.shellescape} olddefconfig", @log)
  end

  # -------------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------------
  def dot_config
    File.join(@src, ".config")
  end

  # Stosuje hash opcji do .config
  def apply_config_options(opts)
    opts.each { |key, val| set_config_option(key, val) }
  end

  # Ustawia pojedynczą opcję w .config
  def set_config_option(key, value)
    content = File.read(dot_config)

    new_line = case value
               when :enable  then "#{key}=y"
               when :disable then "# #{key} is not set"
               when :module  then "#{key}=m"
               else               "#{key}=#{value}"
               end

    # Regex dopasowuje zarówno KEY=... jak i # KEY is not set
    pattern = /^(# )?#{Regexp.escape(key)}[= ].*/

    if content.match?(pattern)
      content = content.gsub(pattern, new_line)
    else
      content << "\n#{new_line}\n"
    end

    File.write(dot_config, content)
  end
end
